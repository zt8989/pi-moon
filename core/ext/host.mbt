// 宿主进程：bun 那边的 ext_host.mjs（见 host/ext_host.mjs）。
//
// 形状照 magpie：主程序不嵌 JS 引擎，扩展跑在独立进程里，两边按行说 JSON。
//
// 这个文件只管「起进程、说话、收结果」：
//   - 启动前：一次性 `--mode load`，构建（命中缓存则跳过）后回传注册表；
//   - 运行期：`--mode serve` 常驻，`call` 工具、`emit` 事件钩子。
//
// 为什么不再嵌 wasm：宿主是解释器（wasm3）时同一段 JS 慢 22 倍，且要自己维护
// WASI shim、快照序列化和 host_call 桥；换成独立 bun 进程后这些全部消失。

///|
/// 宿主脚本版本。改 `host/ext_host.mjs` 就要加一 —— 缓存键含它。
pub let host_version : String = "pi-moon-host/1"

///|
/// 宿主进程需要的路径。全部在启动时算一次。
pub(all) struct HostPaths {
  /// bun 可执行文件。
  bun : String
  /// 写到缓存目录里的宿主脚本。
  script : String
  /// 宿主根目录（里面放 node_modules 符号链接与 build/）。
  root : String
  /// pi 装机里的 node_modules（扩展 import 的包都从这里来）。
  modules : String
  cwd : String
  agent_dir : String
}

///|
/// 找不到 bun：扩展整体关掉，其余功能不受影响。
pub fn HostPaths::bun_missing(self : HostPaths) -> Bool {
  self.bun.is_empty()
}

///|
/// 找一个可用的 bun。`PI_MOON_BUN` 可以显式指定。
pub async fn find_bun() -> String {
  let env = @env.get_env_vars()
  match env.get("PI_MOON_BUN") {
    Some(path) if !path.is_empty() => return path
    _ => ()
  }
  let probe = @sys.run_capture("bun", ["--version"], timeout_ms=10000) catch {
    _ => return ""
  }
  if probe.exit_code() == 0 {
    "bun"
  } else {
    ""
  }
}

///|
/// 相对路径转绝对：宿主进程的工作目录是缓存目录，参数里带相对路径会解错。
fn absolute(path : String) -> String {
  if path.is_empty() || path.has_prefix("/") || path[1:].has_prefix(":") {
    return path
  }
  match @env.current_dir() {
    Some(dir) => dir + "/" + path
    None => path
  }
}

///|
/// 算一次宿主路径，并把脚本落到缓存目录（内容变了才重写）。
pub async fn prepare_host_paths(
  cwd : String,
  agent_dir : String,
  modules : String,
) -> HostPaths raise HostError {
  let bun = find_bun() catch {
    _ => ""
  }
  let root = ext_cache_dir(agent_dir) + "/host"
  let script = root + "/ext_host.mjs"
  @sys.mkdir_p(root) catch {
    error => raise HostStartup(error.to_string())
  }
  let existing = @sys.read_text(script) catch { _ => "" }
  if existing != host_script_source {
    @sys.write_text(script, host_script_source) catch {
      error => raise HostStartup(error.to_string())
    }
  }
  {
    bun,
    script: absolute(script),
    root: absolute(root),
    modules: absolute(modules),
    cwd: absolute(cwd),
    agent_dir: absolute(agent_dir),
  }
}

///|
/// 宿主相关失败。
pub suberror HostError {
  /// 进程起不来 / 脚本写不下去。
  HostStartup(String)
  /// 宿主回了错误（装载失败、调用失败）。
  HostFailure(String)
  /// 找不到 bun。
  NoBun
}

///|
pub fn HostError::to_string(self : HostError) -> String {
  match self {
    HostStartup(reason) => "宿主启动失败：" + reason
    HostFailure(reason) => reason
    NoBun => "找不到 bun（扩展需要它；可用 PI_MOON_BUN 指定路径）"
  }
}

///|
/// 一次 `--mode load` 的结果。
pub(all) struct HostLoad {
  tools : Array[String]
  commands : Array[String]
  events : Array[String]
  /// 扩展调了但 pi-moon 没实现的宿主 API（仅诊断）。
  unsupported : Array[String]
  /// 沙盒拦下的路径访问（仅诊断）。
  denied : Array[String]
  /// 扩展起过的子进程（仅诊断）。
  child_calls : Array[String]
  /// 这次是不是重新构建的（false = 命中缓存）。
  built : Bool
  /// 宿主耗时（毫秒）。
  ms : Int
}

///|
/// 一次 `--mode load`：起 bun、装载扩展、拿回注册表，进程随之退出。
pub async fn load_extension(
  paths : HostPaths,
  source : ExtSource,
  cache_key : String,
) -> HostLoad raise HostError {
  if paths.bun_missing() {
    raise NoBun
  }
  let output = paths.root + "/load-" + cache_key + ".json"
  let capture = @sys.run_capture(
    paths.bun,
    [
      paths.script,
      "--root",
      paths.root,
      "--modules",
      paths.modules,
      "--cwd",
      paths.cwd,
      "--agent",
      paths.agent_dir,
      "--path",
      absolute(source.path),
      "--key",
      cache_key,
      "--name",
      source.name,
      "--mode",
      "load",
      "--out",
      output,
    ],
    cwd=paths.root,
    timeout_ms=120000,
  ) catch {
    error => raise HostStartup(error.to_string())
  }
  let text = @sys.read_text(output) catch {
    _ => capture.stdout()
  }
  if text.is_empty() {
    raise HostStartup(
      "宿主没有输出（exit " +
      capture.exit_code().to_string() +
      "）：" +
      capture.stderr(),
    )
  }
  // 失败时把宿主 stderr 一起带上：bun 的诊断（解析/语法）只在那里。
  let stderr = capture.stderr()
  let result = try parse_load(text) catch {
    error => raise HostFailure(error.to_string() + (if stderr.is_empty() { "" } else { "\n" + stderr }))
  }
  result
}

///|
/// 解析宿主回传的 JSON。
pub fn parse_load(text : String) -> HostLoad raise HostError {
  let parsed = @json.parse(text) catch {
    _ => raise HostFailure("宿主输出不是合法 JSON：" + text[:200].to_owned())
  }
  let object = match parsed.as_object() {
    Some(fields) => fields
    None => raise HostFailure("宿主输出不是对象")
  }
  let ok = match object.get("ok") {
    Some(value) =>
      match value.as_bool() {
        Some(flag) => flag
        None => false
      }
    None => false
  }
  if !ok {
    let reason = match object.get("error") {
      Some(value) =>
        match value.as_string() {
          Some(text) => text
          None => "未知错误"
        }
      None => "未知错误"
    }
    raise HostFailure(reason)
  }
  let registry = match object.get("registry") {
    Some(value) =>
      match value.as_object() {
        Some(fields) => fields
        None => Map([])
      }
    None => Map([])
  }
  let policy = match object.get("policy") {
    Some(value) =>
      match value.as_object() {
        Some(fields) => fields
        None => Map([])
      }
    None => Map([])
  }
  let read_strings = fn(fields : Map[String, Json], key : String) -> Array[String] {
    let out : Array[String] = []
    match fields.get(key) {
      Some(value) =>
        match value.as_array() {
          Some(items) =>
            for item in items {
              match item.as_string() {
                Some(text) => out.push(text)
                None => ()
              }
            }
          None => ()
        }
      None => ()
    }
    out
  }
  let number = fn(fields : Map[String, Json], key : String) -> Int {
    match fields.get(key) {
      Some(value) =>
        match value.as_number() {
          Some(text) => text.to_int()
          None => 0
        }
      None => 0
    }
  }
  let flag = fn(fields : Map[String, Json], key : String) -> Bool {
    match fields.get(key) {
      Some(value) =>
        match value.as_bool() {
          Some(actual) => actual
          None => false
        }
      None => false
    }
  }
  {
    tools: read_strings(registry, "tools"),
    commands: read_strings(registry, "commands"),
    events: read_strings(registry, "events"),
    unsupported: read_strings(registry, "unsupported"),
    denied: read_strings(policy, "denied"),
    child_calls: read_strings(policy, "childCalls"),
    built: flag(object, "built"),
    ms: number(object, "ms"),
  }
}
