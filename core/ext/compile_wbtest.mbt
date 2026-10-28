// 启动前编译的端到端测试：真的把扩展跑进沙盒、抓快照、落盘、再命中缓存。

///|
async fn quickjs_wasm_path() -> String? {
  let found = quickjs_bytes_with_path()
  match found {
    Some((path, _)) => Some(path)
    None => None
  }
}

///|
async fn quickjs_bytes_with_path() -> (String, Bytes)? {
  let env = @env.get_env_vars()
  let agent_dir = match env.get("PI_CODING_AGENT_DIR") {
    Some(dir) if !dir.is_empty() => dir
    _ => {
      let home = match env.get("HOME") {
        Some(home) => home
        None => return None
      }
      home + "/.pi/agent"
    }
  }
  load_quickjs_wasm(agent_dir)
}

///|
/// 每个测试独占一个目录：只按 `now()` 取名会在并行测试里撞（同一毫秒），
/// 于是两个扩展源挤进同一个 `extensions/`，断言就飘了。
async fn compile_root() -> String {
  let random = @random.Rand::Rand()
  let dir = "_build/ext-compile-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000).to_string()
  @fs.mkdir(dir, recursive=true) catch { _ => () }
  dir
}

///|
async fn write_source(path : String, body : String) -> Unit {
  @fs.mkdir(parent_dir(path), recursive=true) catch { _ => () }
  @fs.write_file(path, body)
}

///|
test "rewrite_exports：三种 export 形态" {
  let rewritten = rewrite_exports(
    #|import { x } from 'y'
    #|export default function (pi) { pi.registerTool({ name: 'demo' }) }
    #|export const extra = 1
    #|export { a, b }
  )
  assert_true(rewritten.contains("module.exports.default = function (pi)"))
  assert_true(rewritten.contains("const extra = 1"))
  assert_true(rewritten.contains("module.exports.extra = extra;"))
  // 具名导出整行被注掉，不会变成非法语法。
  assert_true(rewritten.contains("// export { a, b }"))
}

///|
test "parse_registry：抽工具名、命令名、事件名" {
  let json =
    #|{"tools":[{"name":"alpha"},{"name":"beta"}],"commands":[{"name":"hello"}],"handlers":{"turn_end":[0],"input":[0]}}
  let (tools, commands, events) = parse_registry(json)
  assert_eq(tools, ["alpha", "beta"])
  assert_eq(commands, ["hello"])
  assert_eq(events.length(), 2)
  assert_true(events.contains("turn_end"))
  // 坏 JSON 不炸，按空处理。
  let (tools2, commands2, events2) = parse_registry("not json")
  assert_eq(tools2.length() + commands2.length() + events2.length(), 0)
}

///|
async test "compile_plan：编译 → 落盘 → 第二次命中缓存" {
  let found = quickjs_wasm_path()
  let wasm_path = match found {
    Some(path) => path
    None => return
  }
  let root = compile_root()
  let agent = root + "/agent"
  let cwd = root + "/project"
  write_source(
    agent + "/extensions/demo.js",
    #|export default function (pi) {
    #|  pi.registerTool({ name: "demo_tool", description: "演示工具" });
    #|  pi.registerCommand("demo", { description: "演示命令" });
    #|  pi.on("turn_end", function () { return null; });
    #|}
  )
  let planned = plan(cwd, agent)
  let (compiled, after) = compile_plan(planned, agent, wasm_path=Some(wasm_path))
  assert_eq(after.entries.length(), 1)
  if compiled.length() != 1 { fail(after.diagnostics.to_string()) }
  let entry = compiled[0]
  assert_eq(entry.name, "demo")
  assert_eq(entry.tools, ["demo_tool"])
  assert_eq(entry.commands, ["demo"])
  assert_eq(entry.events, ["turn_end"])
  // 快照真的落盘了，而且是 QJSS 头。
  let snapshot = @sys.read_bytes(entry.snapshot_path) catch {
    error => fail("读不到快照：" + error.to_string())
  }
  match read_snapshot_header(snapshot) {
    Some(header) => assert_true(header.memory_size > 0)
    None => fail("快照头不合法")
  }
  // 第二次计划应该命中缓存，不再编译。
  let second = plan(cwd, agent)
  match second.entries[0].step {
    Cached(..) => ()
    other => fail("第二次应为 Cached，实际 " + other.to_string())
  }
}

///|
async test "compile_plan：扩展抛异常时留诊断、不落盘" {
  match quickjs_wasm_path() {
    Some(_) => ()
    None => return
  }
  let root = compile_root()
  let agent = root + "/agent"
  let cwd = root + "/project"
  write_source(agent + "/extensions/boom.js", "export default function () { throw new Error('boom') }")
  let planned = plan(cwd, agent)
  let (compiled, after) = compile_plan(planned, agent)
  assert_eq(compiled.length(), 0)
  assert_true(after.diagnostics.any(line => line.contains("boom")))
}

///|
async test "compile_plan：找不到 quickjs.wasm 时按 NoCompiler 跳过" {
  let root = compile_root()
  let agent = root + "/empty-agent"
  let cwd = root + "/project"
  write_source(agent + "/extensions/plain.js", "export default function () {}")
  let planned = plan(cwd, agent)
  // 用一个不存在的 agent 目录，强制解析不到 wasm。
  let (compiled, after) = compile_plan(planned, agent + "-nope")
  assert_eq(compiled.length(), 0)
  match after.entries[0].step {
    Skip(reason~) => assert_eq(reason, NoCompiler)
    other => fail("期望 NoCompiler 跳过，实际 " + other.to_string())
  }
}
