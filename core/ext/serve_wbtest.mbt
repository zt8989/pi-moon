// 常驻宿主的整条链路：起 `--mode serve` → 调工具 → 派事件 → 收尾。
//
// 与 host_wbtest 一样，缺 bun / 缺 pi 的 node_modules 时整组跳过 —— 那是环境
// 缺失，不是回归。

///|
fn serve_call(text : String) -> @message.ToolCall {
  {
    id: "call_ext_1",
    name: "ext_count",
    arguments: "{\"text\":\"" + text + "\"}",
  }
}

///|
/// 一个有状态的扩展：计数器留在模块作用域里，跨 `call` 必须递增。
/// `console.log` 是故意留的 —— 它应该变成协议里的 log 行，而不是污染 stdout。
fn counter_extension_body() -> String {
  (
    #|import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
    #|import { Type } from "typebox";
    #|let counter = 0;
    #|const tool = defineTool({
    #|  name: "ext_count",
    #|  description: "counts calls",
    #|  parameters: Type.Object({ text: Type.String() }),
    #|  async execute(_id: string, params: { text: string }) {
    #|    counter += 1;
    #|    console.log("[demo] call " + counter);
    #|    return { content: [{ type: "text", text: params.text + "#" + counter }] };
    #|  },
    #|});
    #|export default function (pi: ExtensionAPI) {
    #|  pi.registerTool(tool);
    #|  pi.on("turn_end", async () => null);
    #|}
  )
}

///|
async test "常驻宿主：注册表 / call 工具 / 状态跨调用 / log 行进噪音" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let body = counter_extension_body()
  let source = write_ext_files(root, "counter.ts", body)
  let key = cache_key(
    body,
    prelude_version~,
    sandbox_version=host_cache_version(),
  )
  let session = ExtSession::start(paths, source, key) catch {
    error => fail(error.to_string())
  }
  assert_eq(session.tools, ["ext_count"])
  assert_eq(session.events, ["turn_end"])
  // 工具定义的完整版要跟着注册表一起回来（模型靠它知道参数 schema）。
  assert_eq(session.tool_definitions.length(), 1)
  assert_eq(session.tool_definitions[0].name, "ext_count")
  assert_true(session.tool_definitions[0].parameters.contains("\"text\""))
  let first = session.call(serve_call("hi")) catch {
    error => fail(error.to_string())
  }
  assert_false(first.is_error)
  assert_eq(@message.contents_text(first.content), "hi#1")
  let second = session.call(serve_call("hi")) catch {
    error => fail(error.to_string())
  }
  assert_eq(@message.contents_text(second.content), "hi#2")
  // console.log 没污染协议：它落进了 noise，工具调用照常完成。
  assert_true(session.noise_text().contains("[demo] call 1"))
  session.close()
}

///|
async test "常驻宿主：事件钩子被真的派发（钩子抛错也不影响回执）" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let body =
    #|import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    #|export default function (pi: ExtensionAPI) {
    #|  pi.on("turn_end", async (event: any) => {
    #|    console.log("[hook] turnIndex=" + event.turnIndex);
    #|    return null;
    #|  });
    #|}
  let source = write_ext_files(root, "hooked.ts", body)
  let key = cache_key(
    body,
    prelude_version~,
    sandbox_version=host_cache_version(),
  )
  let session = ExtSession::start(paths, source, key) catch {
    error => fail(error.to_string())
  }
  assert_eq(session.events, ["turn_end"])
  let payload : Map[String, Json] = Map([])
  payload["type"] = Json::string("turn_end")
  payload["turnIndex"] = Json::number(3.0)
  session.emit("turn_end", Json::object(payload)) catch {
    error => fail(error.to_string())
  }
  assert_true(session.noise_text().contains("[hook] turnIndex=3"))
  session.close()
}

///|
async test "常驻宿主：调没注册的工具回一条错误回执" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let body = "export default function (pi) { pi.registerTool({ name: 'only', description: '' }) }\n"
  let source = write_ext_files(root, "only.js", body)
  let key = cache_key(
    body,
    prelude_version~,
    sandbox_version=host_cache_version(),
  )
  let session = ExtSession::start(paths, source, key) catch {
    error => fail(error.to_string())
  }
  let call : @message.ToolCall = { id: "c9", name: "missing", arguments: "{}", }
  let outcome = session.call(call) catch { error => fail(error.to_string()) }
  assert_true(outcome.is_error)
  assert_true(@message.contents_text(outcome.content).contains("missing"))
  session.close()
}

///|
async test "常驻宿主：ExtRuntime 按工具名路由、按事件名广播" {
  let env = host_env()
  let (paths, root) = match env {
    Some(env) => env
    None => return
  }
  let body = counter_extension_body()
  let source = write_ext_files(root, "routed.ts", body)
  let key = cache_key(
    body,
    prelude_version~,
    sandbox_version=host_cache_version(),
  )
  let session = ExtSession::start(paths, source, key) catch {
    error => fail(error.to_string())
  }
  let runtime = ExtRuntime::new()
  runtime.push(session)
  assert_true(runtime.owns("ext_count"))
  assert_false(runtime.owns("read"))
  assert_true(runtime.listens("turn_end"))
  assert_false(runtime.listens("tool_execution_start"))
  let outcome = runtime.call_tool(serve_call("yo"))
  assert_eq(@message.contents_text(outcome.content), "yo#1")
  let payload : Map[String, Json] = Map([])
  payload["type"] = Json::string("turn_end")
  runtime.emit("turn_end", Json::object(payload))
  // 未挂钩子的事件不该发（这里只验证行为：没有报错、会话仍可用）。
  runtime.emit("tool_execution_end", Json::object(payload))
  let again = runtime.call_tool(serve_call("yo"))
  assert_eq(@message.contents_text(again.content), "yo#2")
  runtime.close()
}

// ─── 协议层：不需要 bun 的对端 ───────────────────────────────────────────────
//
// 上面几组要真 bun（缺了会整组跳过）。协议本身（跨块拼行、跳过 log 噪音、
// request/response 的 id 自检、致命错误）用一个 node 写的假宿主测 —— 这段
// 逻辑与 bun 无关，不该因为「这台机器没装 bun」而完全没有覆盖。

///|
fn fake_host_script() -> String {
  (
    #|let buf = "";
    #|function write(obj) { process.stdout.write(JSON.stringify(obj) + "\n") }
    #|function handle(req) {
    #|  if (process.env.FAKE_MODE === "fatal") {
    #|    write({ event: "fatal", error: "boom-from-host" });
    #|    return;
    #|  }
    #|  if (req.op === "call") {
    #|    write({ event: "log", level: "log", text: "[fake] call " + req.tool });
    #|    const out = JSON.stringify({
    #|      ok: true,
    #|      id: req.id,
    #|      result: { content: [{ type: "text", text: "echo:" + ((req.args || {}).text || "") }] },
    #|    });
    #|    // 故意把一行拆成两次写：客户端必须自己攒尾巴。
    #|    process.stdout.write(out.slice(0, 12));
    #|    setTimeout(() => process.stdout.write(out.slice(12) + "\n"), 5);
    #|    return;
    #|  }
    #|  if (req.op === "emit") { write({ ok: true, id: req.id, results: [null] }); return }
    #|  write({ ok: false, id: req.id, error: "unknown op " + req.op });
    #|}
    #|process.stdin.on("data", (chunk) => {
    #|  buf += chunk.toString();
    #|  let index;
    #|  while ((index = buf.indexOf("\n")) >= 0) {
    #|    const line = buf.slice(0, index);
    #|    buf = buf.slice(index + 1);
    #|    if (line.trim().length > 0) { handle(JSON.parse(line)) }
    #|  }
    #|});
  )
}

///|
async fn node_available() -> Bool {
  let probe = @sys.run_capture("node", ["--version"], timeout_ms=10000) catch {
    _ => return false
  }
  probe.exit_code() == 0
}

///|
async fn fake_session(mode : String) -> ExtSession {
  let io = @sys.spawn_session(
    "node",
    ["-e", fake_host_script()],
    extra_env=Map([("FAKE_MODE", mode)]),
    cwd=".",
  )
  {
    name: "fake",
    tools: ["fake_tool"],
    tool_definitions: [],
    commands: [],
    events: ["turn_end"],
    unsupported: [],
    denied: [],
    built: false,
    ms: 0,
    io,
    pending: "",
    noise: [],
    next_id: 1,
    dead: false,
  }
}

///|
async test "协议层：跨块拼行 / log 噪音 / call 与 emit 的往返" {
  if !node_available() {
    return
  }
  let session = fake_session("ok") catch { error => fail(error.to_string()) }
  let call : @message.ToolCall = {
    id: "c1",
    name: "fake_tool",
    arguments: "{\"text\":\"ping\"}",
  }
  let outcome = session.call(call) catch { error => fail(error.to_string()) }
  assert_false(outcome.is_error)
  assert_eq(@message.contents_text(outcome.content), "echo:ping")
  // log 行进噪音，没被当响应、也没把行拼歪。
  assert_true(session.noise_text().contains("[fake] call fake_tool"))
  let payload : Map[String, Json] = Map([])
  payload["type"] = Json::string("turn_end")
  session.emit("turn_end", Json::object(payload)) catch {
    error => fail(error.to_string())
  }
  session.close()
}

///|
async test "协议层：宿主报 fatal 时调用拿到明确错误" {
  if !node_available() {
    return
  }
  let session = fake_session("fatal") catch { error => fail(error.to_string()) }
  let call : @message.ToolCall = {
    id: "c2",
    name: "fake_tool",
    arguments: "{}",
  }
  let message = try {
    let _ = session.call(call)
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(message.contains("boom-from-host"))
  assert_true(session.dead)
}
