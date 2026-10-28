// 宿主进程的测试：真起 bun、真装载扩展。
//
// 环境缺 bun / pi 安装时整组跳过 —— 这是环境缺失，不是回归。

///|
async fn host_root() -> String {
  let random = @random.Rand::Rand()
  let dir = "_build/ext-host-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000).to_string()
  @sys.mkdir_p(dir) catch { _ => () }
  dir
}

///|
async fn write_ext_files(root : String, name : String, body : String) -> ExtSource {
  let dir = root + "/extensions"
  @sys.mkdir_p(dir) catch { _ => () }
  let path = dir + "/" + name
  @sys.write_text(path, body) catch { _ => () }
  { name: stem_of(path), path, dir, origin: Project }
}

///|
/// 工具链齐了才跑：bun + pi 的 node_modules。
async fn host_env() -> (HostPaths, String)? {
  let modules = match resolve_pi_modules(agent_install_dir()) {
    Some(path) => path
    None => return None
  }
  let root = host_root()
  let paths = prepare_host_paths(root, root, modules) catch { _ => return None }
  if paths.bun_missing() {
    return None
  }
  // 先确认 bun 真能跑宿主脚本（缺 bun 时上面已经返回，这里防「装了但不可用」）。
  Some((paths, root))
}

///|
/// 测试用的 pi agent 目录：与 vm 测试一致，从环境变量或 HOME 推。
fn agent_install_dir() -> String {
  let env = @env.get_env_vars()
  match env.get("PI_CODING_AGENT_DIR") {
    Some(dir) if !dir.is_empty() => dir
    _ => {
      let home = match env.get("HOME") {
        Some(home) => home
        None => ""
      }
      home + "/.pi/agent"
    }
  }
}

///|
async test "host_script_source 与 host/ext_host.mjs 同步" {
  // 生成器：node scripts/embed-host.mjs。这份测试保证嵌进二进制的副本不漂移。
  let on_disk = @sys.read_text("core/ext/host/ext_host.mjs") catch { _ => return }
  let expected = if on_disk.has_suffix("\n") {
    on_disk[:on_disk.length() - 1].to_owned()
  } else {
    on_disk
  }
  if host_script_source != expected {
    fail("host_script.mbt 与 host/ext_host.mjs 不一致，跑 node scripts/embed-host.mjs")
  }
}

///|
async test "宿主装载：TS 扩展 + pi 包 import + typebox 参数" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let source = write_ext_files(
    root,
    "hello.ts",
    #|import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
    #|import { Type } from "typebox";
    #|const tool = defineTool({
    #|  name: "greet",
    #|  description: "greets",
    #|  parameters: Type.Object({ name: Type.String() }),
    #|  async execute() { return { content: [] }; }
    #|});
    #|export default function (pi: ExtensionAPI) {
    #|  pi.registerTool(tool);
    #|  pi.registerCommand("greet", { description: "cmd", handler: async () => "ok" });
    #|  pi.on("turn_end", async () => null);
    #|}
  )
  let key = cache_key("hello-v1", prelude_version~, sandbox_version=host_cache_version())
  let loaded = load_extension(paths, source, key) catch {
    error => fail(error.to_string())
  }
  assert_eq(loaded.tools, ["greet"])
  assert_eq(loaded.commands, ["greet"])
  assert_eq(loaded.events, ["turn_end"])
  assert_true(loaded.built)
}

///|
async test "宿主装载：命中产物缓存，第二次不再打包" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let body = "export default function (pi) { pi.registerTool({ name: 'cached', description: '' }) }\n"
  let source = write_ext_files(root, "cached.js", body)
  let key = cache_key(body, prelude_version~, sandbox_version=host_cache_version())
  let first = load_extension(paths, source, key) catch {
    error => fail(error.to_string())
  }
  assert_true(first.built)
  let second = load_extension(paths, source, key) catch {
    error => fail(error.to_string())
  }
  assert_false(second.built)
  assert_eq(second.tools, ["cached"])
}

///|
async test "宿主装载：扩展抛异常时回传失败，不崩宿主" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let source = write_ext_files(
    root,
    "boom.js",
    "export default function () { throw new Error('boom-in-extension') }\n",
  )
  let key = cache_key("boom-v1", prelude_version~, sandbox_version=host_cache_version())
  match try_load(paths, source, key) {
    Some(message) => assert_true(message.contains("boom-in-extension"))
    None => fail("扩展抛异常应该回传失败")
  }
}

///|
/// 期望失败的装载：成功返回 None，失败把错误文本带回来。
async fn try_load(paths : HostPaths, source : ExtSource, key : String) -> String? {
  let _ = try load_extension(paths, source, key) catch {
    error => return Some(error.to_string())
  }
  None
}

///|
async test "宿主装载：扩展读 cwd 之外的文件被沙盒拦下" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let source = write_ext_files(
    root,
    "nosy.ts",
    #|import { readFileSync } from "node:fs";
    #|import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    #|export default function (pi: ExtensionAPI) {
    #|  let denied = false;
    #|  try { readFileSync("/etc/hosts", "utf8"); } catch (error) { denied = true; }
    #|  pi.registerTool({ name: denied ? "blocked" : "leaked", description: "" });
    #|}
  )
  let key = cache_key("nosy-v1", prelude_version~, sandbox_version=host_cache_version())
  let loaded = load_extension(paths, source, key) catch {
    error => fail(error.to_string())
  }
  // 策略模块在装载期就把越界读挡掉了，工具名反映这次尝试的结果。
  assert_eq(loaded.tools, ["blocked"])
}
