// 远程工具客户端的协议层测试：node 假宿主监听真实 localhost TCP，脚本化扮演
// 注册表与工具执行（与 core/ext 的假宿主同一技术，只是承载从 stdio 换成 TCP）。
//
// 缺 node 时整组跳过 —— 环境缺失，不是回归。

///|
async fn rtools_node_available() -> Bool {
  let probe = @sys.run_capture("node", ["--version"], timeout_ms=10000) catch {
    _ => return false
  }
  probe.exit_code() == 0
}

///|
/// 假宿主：accept 就发 `ready` 注册表，然后按行处理 `hello` / `call`。
/// 工具名分派剧本：echo 演「log 噪音 + 响应拆两次写」，stale 演多出来的旧
/// id 响应，image / error / plain 演 pi 形状的三种折叠；FAKE_MODE=fatal / drop
/// 演对端致命与提前退出。端口写到 argv[1]（内核分配，测试从文件里拿）；收到
/// `hello` 后把会话元数据写到 argv[2]。挂在 stdin 上：父进程关掉 stdin 它就退出。
fn fake_host_script() -> String {
  (
    #|const net = require("node:net");
    #|const fs = require("node:fs");
    #|fs.mkdirSync(require("node:path").dirname(process.argv[1]), { recursive: true });
    #|const MODE = process.env.RTOOLS_FAKE_MODE || "ok";
    #|let sessionMeta = null;
    #|function send(socket, obj) { socket.write(JSON.stringify(obj) + "\n") }
    #|function handle(socket, req) {
    #|  if (req.op === "hello") {
    #|    sessionMeta = req.session || {};
    #|    fs.writeFileSync(process.argv[2], JSON.stringify(sessionMeta));
    #|    send(socket, { ok: true, id: req.id });
    #|    return;
    #|  }
    #|  if (req.op !== "call") {
    #|    send(socket, { ok: false, id: req.id, error: "unknown op " + req.op });
    #|    return;
    #|  }
    #|  if (MODE === "fatal") {
    #|    send(socket, { event: "fatal", error: "boom-from-host" });
    #|    socket.destroy();
    #|    return;
    #|  }
    #|  if (MODE === "drop") {
    #|    // 断线前留一行宿主自己的话 —— 客户端要把它当噪音收进诊断措辞。
    #|    send(socket, { event: "log", level: "log", text: "[fake] dying" });
    #|    socket.destroy();
    #|    return;
    #|  }
    #|  const reply = (result) => ({ ok: true, id: req.id, result });
    #|  if (req.tool === "stale") {
    #|    socket.write(JSON.stringify({ ok: true, id: 999, stale: true }) + "\n");
    #|    send(socket, reply({ content: [{ type: "text", text: "fresh" }] }));
    #|    return;
    #|  }
    #|  if (req.tool === "image") {
    #|    send(socket, reply({ content: [
    #|      { type: "text", text: "看图：" },
    #|      { type: "image", data: "aGVsbG8=", mimeType: "image/gif" },
    #|    ] }));
    #|    return;
    #|  }
    #|  if (req.tool === "error") {
    #|    send(socket, reply({ content: [{ type: "text", text: "boom" }], isError: true }));
    #|    return;
    #|  }
    #|  if (req.tool === "plain") {
    #|    send(socket, reply("just text"));
    #|    return;
    #|  }
    #|  // echo：log 行在响应前（客户端要把它当噪音跳过），响应故意拆成两次写
    #|  // （客户端要自己攒尾巴）。
    #|  send(socket, { event: "log", level: "log", text: "[fake] call " + req.tool });
    #|  const out = JSON.stringify(
    #|    reply({ content: [{ type: "text", text: "echo:" + ((req.args || {}).text || "") }] }),
    #|  );
    #|  socket.write(out.slice(0, 12));
    #|  setTimeout(() => socket.write(out.slice(12) + "\n"), 5);
    #|}
    #|const server = net.createServer((socket) => {
    #|  send(socket, { event: "ready", ok: true, tools: ["fake_tool"],
    #|    toolDefinitions: [
    #|      { name: "fake_tool", description: "a fake remote tool",
    #|        parameters: { type: "object", properties: { text: { type: "string" } } } },
    #|    ] });
    #|  let buf = "";
    #|  socket.on("data", (chunk) => {
    #|    buf += chunk.toString();
    #|    let index;
    #|    while ((index = buf.indexOf("\n")) >= 0) {
    #|      const line = buf.slice(0, index);
    #|      buf = buf.slice(index + 1);
    #|      if (line.trim().length > 0) { handle(socket, JSON.parse(line)) }
    #|    }
    #|  });
    #|  socket.on("error", () => {});
    #|});
    #|server.listen(0, "127.0.0.1", () => {
    #|  fs.writeFileSync(process.argv[1], String(server.address().port));
    #|});
    #|process.stdin.resume();
    #|process.stdin.on("end", () => process.exit(0));
  )
}

///|
/// 起假宿主，等它报出端口。端口文件放 `_build/` 下（tools_wbtest 同款），
/// 文件名带时间戳**与随机分量** —— 只有时间戳的话，两个测试进程同一毫秒
/// 起同模式的宿主会拿到同一个文件，借到对方的连接，宿主一退调用就被掐断
/// （跨包并行时真闪失败过）。交回（进程、端口、元数据文件路径）—— 元数据
/// 路径由这里生成，测试原样去读。
async fn fake_host(mode~ : String = "ok") -> (@sys.Session, Int, String) {
  let dir = "_build/rtools-e2e"
  let random = @random.Rand::Rand()
  let stamp = mode +
    "-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000000).to_string()
  let port_file = dir + "/port-" + stamp
  let meta_file = dir + "/meta-" + stamp
  let io = @sys.spawn_session(
    "node",
    ["-e", fake_host_script(), port_file, meta_file],
    extra_env=Map([("RTOOLS_FAKE_MODE", mode)]),
    cwd=".",
  ) catch { error => fail(error.to_string()) }
  let port = match wait_port(port_file) {
    Some(port) => port
    None => {
      io.close()
      fail("假宿主没有在 5s 内报出端口")
    }
  }
  (io, port, meta_file)
}

///|
async fn wait_port(port_file : String) -> Int? {
  for _i in 0..<100 {
    let there = @sys.exists(port_file) catch { _ => false }
    if there {
      let text = @sys.read_text_lossy(port_file) catch { _ => return None }
      let parsed = @json.parse(text.trim().to_owned()) catch { _ => Json::null() }
      return match parsed {
        Number(n, ..) => Some(n.to_int())
        _ => None
      }
    }
    @async.sleep(50)
  }
  None
}

///|
/// 等一个文件出现并读出内容（端口回执 / 元数据落盘都靠它）。
async fn wait_text(path : String) -> String? {
  for _i in 0..<100 {
    let there = @sys.exists(path) catch { _ => false }
    if there {
      let text = @sys.read_text_lossy(path) catch { _ => return None }
      return Some(text)
    }
    @async.sleep(50)
  }
  None
}

///|
async test "握手：ready 注册表成为模型声明，hello 把会话元数据送到宿主" {
  if !rtools_node_available() {
    return
  }
  let (io, port, meta_file) = fake_host(mode="ok")
  defer io.close()
  let session = RemoteTools::connect(
    "127.0.0.1",
    port,
    { session_id: "s-r1", provider: "prov", model: "mod" },
  ) catch { error => fail(error.to_string()) }
  assert_eq(session.definitions.length(), 1)
  assert_eq(session.definitions[0].name, "fake_tool")
  assert_eq(session.definitions[0].description, "a fake remote tool")
  // 参数 schema 原样进声明（provider 把它塞进请求体的 function.parameters）。
  assert_true(session.definitions[0].parameters.contains("\"text\""))
  assert_true(session.owns("fake_tool"))
  assert_false(session.owns("read"))
  // 会话元数据（sessionId / provider / model）真的到了宿主。
  let meta = wait_text(meta_file).unwrap_or("")
  assert_true(meta.contains("\"sessionId\":\"s-r1\""))
  assert_true(meta.contains("\"provider\":\"prov\""))
  assert_true(meta.contains("\"model\":\"mod\""))
  session.close()
}

///|
fn fake_call(name~ : String = "fake_tool") -> @message.ToolCall {
  {
    id: "c1",
    name,
    arguments: "{\"text\":\"ping\"}",
  }
}

///|
async fn fake_session(mode~ : String = "ok") -> (@sys.Session, RemoteTools) {
  let (io, port, _meta_file) = fake_host(mode=mode)
  let session = RemoteTools::connect(
    "127.0.0.1",
    port,
    { session_id: "s-r", provider: "prov", model: "mod" },
  ) catch { error => fail(error.to_string()) }
  (io, session)
}

///|
async test "call 往返：log 行进噪音，拆成两块的响应自己拼回来" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session()
  defer io.close()
  let outcome = session.call_tool(fake_call())
  assert_false(outcome.is_error)
  assert_eq(@message.contents_text(outcome.content), "echo:ping")
  // log 行没被当响应，也没把行拼歪 —— 落进了噪音。
  assert_true(session.rpc.noise_text().contains("[fake] call fake_tool"))
  session.close()
}

///|
async test "id 自检：上一轮剩下的响应抖掉，等匹配的那条" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session()
  defer io.close()
  let outcome = session.call_tool(fake_call(name="stale"))
  assert_false(outcome.is_error)
  assert_eq(@message.contents_text(outcome.content), "fresh")
  session.close()
}

///|
async test "折叠：pi 形状的 text / image / isError / 裸字符串" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session()
  defer io.close()
  // image 块折成 data URL（text 块保留在前）。
  let image = session.call_tool(fake_call(name="image"))
  assert_false(image.is_error)
  assert_eq(image.content.length(), 2)
  match image.content[1] {
    @message.Image(url) => assert_eq(url, "data:image/gif;base64,aGVsbG8=")
    _ => fail("图片块应该折成 data URL")
  }
  // isError 折成 is_error，正文照带。
  let failure = session.call_tool(fake_call(name="error"))
  assert_true(failure.is_error)
  assert_eq(@message.contents_text(failure.content), "boom")
  // 不是对象的返回值当作一段文本。
  let plain = session.call_tool(fake_call(name="plain"))
  assert_false(plain.is_error)
  assert_eq(@message.contents_text(plain.content), "just text")
  session.close()
}

///|
async test "fatal：当前调用拿到带原因的错误，之后调用立刻失败" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session(mode="fatal")
  defer io.close()
  let message = try {
    let _ = session.call(fake_call())
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(message.contains("boom-from-host"))
  assert_true(session.rpc.is_dead())
  // 之后的调用不再往没人听的管道里写 —— 立刻拿到错误结果。
  let again = session.call_tool(fake_call())
  assert_true(again.is_error)
  assert_true(@message.contents_text(again.content).contains("已经退出"))
}

///|
async test "对端提前退出：调用拿到明确错误而不是挂死" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session(mode="drop")
  defer io.close()
  let message = try {
    let _ = session.call(fake_call())
    ""
  } catch {
    error => error.to_string()
  }
  assert_true(message.contains("提前退出"))
  let again = session.call_tool(fake_call())
  assert_true(again.is_error)
  assert_true(@message.contents_text(again.content).contains("已经退出"))
}

///|
async test "连接被拒：启动诊断带上地址" {
  if !rtools_node_available() {
    return
  }
  // 先借一个真端口，再把服务退掉，然后连一个确认没人听的端口。进程退出是
  // 异步的 —— 中途还会撞上「TCP 握手成功、随即被 RST」的垂死窗口，所以轮询
  // 到**干净的被拒**为止（最多 4s）。
  let (io, port, _meta_file) = fake_host(mode="drop")
  io.close()
  let mut message = ""
  for _i in 0..<20 {
    let attempt = try {
      let session = RemoteTools::connect(
        "127.0.0.1",
        port,
        { session_id: "s-x", provider: "p", model: "m" },
      )
      session.close()
      ""
    } catch {
      error => error.to_string()
    }
    if attempt.contains("连接工具宿主失败") {
      message = attempt
      break
    }
    @async.sleep(200)
  }
  assert_true(message.contains("连接工具宿主失败"))
  assert_true(message.contains("127.0.0.1:" + port.to_string()))
}

// ─── 路由链：扩展名册 → 远程名册 → 本地 ─────────────────────────────────────
//
// 不碰 TCP：三个执行位置用假 runner 假 LLM 走真 effect（`run_tools_with_hooks`），
// 钉住「名字归谁就谁执行」与「启用检查口径不变」。

///|
fn fake_ext_runner() -> @provider.ExternalTools {
  fn ext_outcome(name : String) -> @tools.ToolOutcome {
    { content: [@message.Text("EXT:" + name)], is_error: false, }
  }
  {
    owns: fn(name) { name == "ext_tool" },
    run: async fn(call) { ext_outcome(call.name) },
    emit: async fn(_, _) { () },
  }
}

///|
fn fake_remote_runner() -> @provider.RemoteExecutor {
  fn remote_outcome(name : String) -> @tools.ToolOutcome {
    { content: [@message.Text("REMOTE:" + name)], is_error: false, }
  }
  {
    owns: fn(name) { name == "remote_tool" },
    run: async fn(call) { remote_outcome(call.name) },
  }
}

///|
/// 假 LLM：第一批发一串工具调用（`names`），看到工具结果就收工。
fn routing_table(names : Array[String]) -> @runtime.EffectTable {
  let round = Ref(0)
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      if round.val == 0 {
        round.val = 1
        let content : Array[@message.Content] = [@message.Text("调工具。")]
        for index, name in names {
          content.push(
            @message.ToolCallBlock({
              id: "c-" + index.to_string(),
              name,
              arguments: if name == "read" { "{\"path\":\"routing.txt\"}" } else { "{}" },
            }),
          )
        }
        dispatch.send(
          @action.LlmDone({
            message: {
              content,
              stop_reason: "toolUse",
              error_message: None,
              usage: None,
              timestamp: 0L,
            },
            node_id: None,
          }),
        )
      } else {
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("收工。")],
              stop_reason: "stop",
              error_message: None,
              usage: None,
              timestamp: 0L,
            },
            node_id: None,
          }),
        )
      }
    },
    run_tools: async fn(state, calls, dispatch) {
      @provider.run_tools_with_hooks(
        state,
        calls,
        dispatch,
        @provider.noop_hooks(),
        external=fake_ext_runner(),
        remote=fake_remote_runner(),
      )
    },
    run_compact: async fn(_, _) { () },
  }
}

///|
async fn run_routing(
  names : Array[String],
  declared : Array[@action.PromptToolDefinition],
) -> (@runtime.Agent, Array[@message.ToolResultPart]) {
  let tool_results : Array[@message.ToolResultPart] = []
  let agent = @runtime.Agent::new(
    @state.create_initial_state({
      system_prompt: "路由测试",
      provider_name: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      tool_names: [],
      max_turns: None,
      max_llm_attempts: 2,
      llm_timeout_ms: 120000L,
      session_id: "s-route",
      cwd: "_build/rtools-e2e",
      trace: None,
    }),
    routing_table(names),
    fn() { 0L },
  )
  agent.observe(action => {
    match action {
      @action.ToolResult(part) => tool_results.push(part)
      _ => ()
    }
  })
  agent.send(@action.PromptInit({ system_prompt: "路由测试", tools: declared, }))
  // 本地 read 的证据：真读一个写好的文件。目录要自己建 —— 不能指望并行的
  // 假宿主测试顺手 mkdirSync（那是竞态，跨包并行跑时write会静默失败）。
  @fs.mkdir("_build/rtools-e2e", recursive=true) catch { _ => () }
  @sys.write_text("_build/rtools-e2e/routing.txt", "本地执行的证据") catch { _ => () }
  agent.send(@action.UserMessage({ text: "跑", content: [], }))
  (agent, tool_results)
}

///|
async test "路由链：扩展名册 → 远程名册 → 本地，各归各位" {
  let (agent, results) = run_routing(
    ["ext_tool", "remote_tool", "read"],
    [
      { name: "ext_tool", description: "扩展的", parameters: "{}", },
      { name: "remote_tool", description: "远程的", parameters: "{}", },
      { name: "read", description: "本地的", parameters: "{}", },
    ],
  )
  assert_eq(results.length(), 3)
  assert_eq(@message.contents_text(results[0].content), "EXT:ext_tool")
  assert_eq(@message.contents_text(results[1].content), "REMOTE:remote_tool")
  // 本地 read：既不是 EXT 也不是 REMOTE，是文件内容本身。
  let local = @message.contents_text(results[2].content)
  assert_false(local.contains("EXT:") || local.contains("REMOTE:"))
  assert_true(local.contains("本地执行的证据"))
  assert_eq(agent.state.phase, @common.Idle)
}

///|
async test "启用口径：名册拥有但没声明给模型的，硬调得「未知工具」" {
  // 什么都没声明：remote 名册拥有 remote_tool、扩展名册拥有 ext_tool，
  // no_such_tool 谁都不拥有 —— 三个都只该拿到「未知工具」。
  let (_agent, results) = run_routing(
    ["remote_tool", "ext_tool", "no_such_tool"],
    [],
  )
  assert_eq(results.length(), 3)
  for result in results {
    assert_true(result.is_error)
    assert_true(@message.contents_text(result.content).contains("未知工具"))
  }
}

// ─── 整环：假 LLM + 真路由 + 假 TCP 宿主 ────────────────────────────────────
//
// 从一条用户消息跑到 idle：注册表成为模型声明、工具调用经 RPC 往返、批次收口。
// 只有 LLM 是假的 —— 路由与远程执行都是真的。

///|
async test "整环：send(用户消息) → 工具经 RPC 执行 → tool.batch.done → idle" {
  if !rtools_node_available() {
    return
  }
  let (io, port, _meta_file) = fake_host(mode="ok")
  defer io.close()
  let remote = RemoteTools::connect(
    "127.0.0.1",
    port,
    { session_id: "s-loop", provider: "fake", model: "fake-1" },
  ) catch { error => fail(error.to_string()) }
  // 模型声明来自注册表（cmd 里 seed 发的就是这一份）。
  let declared : Array[@action.PromptToolDefinition] = []
  for definition in remote.definitions {
    declared.push(definition)
  }
  assert_eq(declared.length(), 1)
  let batch_done = Ref(0)
  let agent = @runtime.Agent::new(
    @state.create_initial_state({
      system_prompt: "整环测试",
      provider_name: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      tool_names: [],
      max_turns: None,
      max_llm_attempts: 2,
      llm_timeout_ms: 120000L,
      session_id: "s-loop",
      cwd: ".",
      trace: None,
    }),
    {
      run_agent: async fn(state, dispatch) {
        dispatch.send(@action.LlmStarted)
        let last_role = match state.messages.last() {
          Some(message) => message.role()
          None => ""
        }
        if last_role == "toolResult" {
          dispatch.send(
            @action.LlmDone({
              message: {
                content: [@message.Text("远端说：" + state.messages[2].text())],
                stop_reason: "stop",
                error_message: None,
                usage: None,
                timestamp: 0L,
              },
              node_id: None,
            }),
          )
        } else {
          dispatch.send(
            @action.LlmDone({
              message: {
                content: [
                  @message.Text("我调一下远程工具。"),
                  @message.ToolCallBlock({
                    id: "call_1",
                    name: "fake_tool",
                    arguments: "{\"text\":\"远端\"}",
                  }),
                ],
                stop_reason: "toolUse",
                error_message: None,
                usage: None,
                timestamp: 0L,
              },
              node_id: None,
            }),
          )
        }
      },
      run_tools: async fn(state, calls, dispatch) {
        @provider.run_tools_with_hooks(
          state,
          calls,
          dispatch,
          @provider.noop_hooks(),
          remote={
            owns: fn(name) { remote.owns(name) },
            run: async fn(call) { remote.call_tool(call) },
          },
        )
      },
      run_compact: async fn(_, _) { () },
    },
    fn() { 0L },
  )
  agent.observe(action => {
    match action {
      @action.ToolBatchDone(_) => batch_done.val = batch_done.val + 1
      _ => ()
    }
  })
  agent.send(@action.PromptInit({ system_prompt: "整环测试", tools: declared, }))
  agent.send(@action.ModelInit({
    provider: "fake",
    model_id: "fake-1",
    thinking_level: "off",
    reasoning: false,
    capabilities: @action.no_capabilities,
    context_window: 1000,
  }))
  agent.send(@action.UserMessage({ text: "看一眼远端", content: [], }))
  // 回合闭合：消息序列合法（user / assistant(工具调用) / toolResult / assistant）。
  assert_eq(agent.state.phase, @common.Idle)
  assert_eq(agent.state.stop_reason, Some(@common.Completed))
  assert_eq(agent.state.messages.length(), 4)
  assert_eq(agent.state.messages[0].role(), "user")
  assert_eq(agent.state.messages[1].role(), "assistant")
  assert_eq(agent.state.messages[2].role(), "toolResult")
  // 工具结果真的是 RPC 往返拿回来的（假宿主的 echo）。
  assert_eq(@message.contents_text(agent.state.messages[2].content()), "echo:远端")
  assert_eq(agent.state.messages[3].text(), "远端说：echo:远端")
  // 批次收口恰好一次。
  assert_eq(batch_done.val, 1)
  remote.close()
}

// ─── 开关语义：注册表查表与本地 definitions_for 同口径 ──────────────────────
//
// 选择规则（-t 替换 / defaultTools 的 +/- / none 全关）在 resolve_tool_selection，
// 已有本地口径测试；这层只钉「拿名字清单查远程注册表」的口径 —— 必须与
// @tools.definitions_for 逐条一致，/tools 与启动选择才能只换声明源。

///|
fn definition_names(definitions : Array[@action.PromptToolDefinition]) -> Array[String] {
  let out : Array[String] = []
  for definition in definitions {
    out.push(definition.name)
  }
  out
}

///|
/// 不联网的注册表会话：字段是 pub(all)，直接手造 —— 选择规则与 RPC 无关，
/// 不值得为此起 node。
fn registry_session() -> RemoteTools {
  let dead : @rpc.Duplex = {
    read: async fn(_max) { Ok(None) },
    write: async fn(_text) { Ok(()) },
    close: fn() { () },
  }
  {
    address: "registry:test",
    rpc: @rpc.Session::new(dead),
    definitions: [
      { name: "read", description: "读", parameters: "{}", },
      { name: "bash", description: "跑", parameters: "{}", },
      { name: "grep", description: "搜", parameters: "{}", },
    ],
  }
}

///|
test "definitions_for：注册表顺序 / 未知忽略 / none 全关 / 前缀按未知" {
  let registry = registry_session()
  // 替换：只留选中的，顺序跟注册表走（与本地 definitions_for 一致）。
  assert_eq(
    definition_names(registry.definitions_for(["grep", "read"])),
    ["read", "grep"],
  )
  // 未知名字忽略。
  assert_eq(
    definition_names(registry.definitions_for(["bash", "nope"])),
    ["bash"],
  )
  // none 全关。
  assert_eq(registry.definitions_for([]).length(), 0)
  // +/- 前缀不在这层处理（那是 resolve_tool_selection 的事）：带前缀的名字
  // 按未知处理 —— 与本地 definitions_for 行为一致。
  assert_eq(registry.definitions_for(["+read"]).length(), 0)
  assert_eq(registry.definitions_for(["-bash"]).length(), 0)
}

///|
async test "tools.changed：换集后执行侧立刻生效，远程吃同一套启用检查" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session()
  defer io.close()
  // 假 LLM：第 0 / 2 轮发工具调用，第 1 / 3 轮收工 —— 两批之间换一次集。
  let round = Ref(0)
  let tool_results : Array[@message.ToolResultPart] = []
  let remote_runner : @provider.RemoteExecutor = {
    owns: fn(name) { session.owns(name) },
    run: async fn(call) { session.call_tool(call) },
  }
  let agent = @runtime.Agent::new(
    @state.create_initial_state({
      system_prompt: "换集测试",
      provider_name: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      tool_names: [],
      max_turns: None,
      max_llm_attempts: 2,
      llm_timeout_ms: 120000L,
      session_id: "s-switch",
      cwd: ".",
      trace: None,
    }),
    {
      run_agent: async fn(_state, dispatch) {
        dispatch.send(@action.LlmStarted)
        let this_round = round.val
        round.val = round.val + 1
        if this_round % 2 == 0 {
          dispatch.send(
            @action.LlmDone({
              message: {
                content: [
                  @message.Text("调。"),
                  @message.ToolCallBlock({
                    id: "call-" + this_round.to_string(),
                    name: "fake_tool",
                    arguments: "{\"text\":\"第" + this_round.to_string() + "批\"}",
                  }),
                ],
                stop_reason: "toolUse",
                error_message: None,
                usage: None,
                timestamp: 0L,
              },
              node_id: None,
            }),
          )
        } else {
          dispatch.send(
            @action.LlmDone({
              message: {
                content: [@message.Text("收工。")],
                stop_reason: "stop",
                error_message: None,
                usage: None,
                timestamp: 0L,
              },
              node_id: None,
            }),
          )
        }
      },
      run_tools: async fn(state, calls, dispatch) {
        @provider.run_tools_with_hooks(
          state,
          calls,
          dispatch,
          @provider.noop_hooks(),
          remote=remote_runner,
        )
      },
      run_compact: async fn(_, _) { () },
    },
    fn() { 0L },
  )
  agent.observe(action => {
    match action {
      @action.ToolResult(part) => tool_results.push(part)
      _ => ()
    }
  })
  // 声明来自注册表（经 definitions_for 的选择口径）。
  agent.send(
    @action.PromptInit({
      system_prompt: "换集测试",
      tools: session.definitions_for(["fake_tool"]),
    }),
  )
  agent.send(@action.UserMessage({ text: "第一批", content: [], }))
  assert_eq(tool_results.length(), 1)
  // assert_eq 而不是 assert_false：失败时能看到宿主折回来的实际错误文本。
  assert_eq(@message.contents_text(tool_results[0].content), "echo:第0批")
  assert_false(tool_results[0].is_error)
  // REPL /tools none 的等价动作：当前声明清空 —— 注册表还拥有这个名字，
  // 但没声明给模型，硬调只得「未知工具」。
  agent.send(@action.ToolsChanged([]))
  assert_eq(agent.state.prompt.tools.length(), 0)
  agent.send(@action.UserMessage({ text: "第二批", content: [], }))
  // 收工轮不产生 ToolResult：两批各一条，第二条是「未知工具」。
  assert_eq(tool_results.length(), 2)
  assert_true(tool_results[1].is_error)
  assert_true(@message.contents_text(tool_results[1].content).contains("未知工具"))
  session.close()
}

// ─── 整环故障：连接死在会话中途 ─────────────────────────────────────────────
//
// 行为契约（票 #4）：当前调用折成 is_error 的 toolResult，之后调用立刻失败，
// 环照常走到 idle，会话不判死、不重连、无超时；路由链其余部分（本地 / 扩展）
// 照常。假 LLM 假装看到工具错误后自己收尾 —— 消息序列保持合法。

///|
/// 声明清单带一个扩展工具（故障测试里断言它不受宿主故障影响）。
fn with_ext(
  definitions : Array[@action.PromptToolDefinition],
) -> Array[@action.PromptToolDefinition] {
  definitions.push({ name: "ext_tool", description: "扩展的", parameters: "{}", })
  definitions
}

///|
/// 故障剧本的假 LLM：偶数轮发一批工具调用，奇数轮照着工具结果收工。
fn failure_table(
  batches~ : Array[Array[String]] = [[], []],
  remote~ : @provider.RemoteExecutor,
  external~ : @provider.ExternalTools?,
) -> @runtime.EffectTable {
  let round = Ref(0)
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      let this_round = round.val
      round.val = round.val + 1
      if this_round % 2 == 0 {
        let names = match batches.get(this_round / 2) {
          Some(names) => names
          None => []
        }
        let content : Array[@message.Content] = [@message.Text("调工具。")]
        for index, name in names {
          content.push(
            @message.ToolCallBlock({
              id: "f-" + this_round.to_string() + "-" + index.to_string(),
              name,
              arguments: if name == "read" { "{\"path\":\"fallback.txt\"}" } else { "{}" },
            }),
          )
        }
        dispatch.send(
          @action.LlmDone({
            message: {
              content,
              stop_reason: "toolUse",
              error_message: None,
              usage: None,
              timestamp: 0L,
            },
            node_id: None,
          }),
        )
      } else {
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("收工。")],
              stop_reason: "stop",
              error_message: None,
              usage: None,
              timestamp: 0L,
            },
            node_id: None,
          }),
        )
      }
    },
    run_tools: async fn(state, calls, dispatch) {
      @provider.run_tools_with_hooks(
        state,
        calls,
        dispatch,
        @provider.noop_hooks(),
        external?,
        remote=remote,
      )
    },
    run_compact: async fn(_, _) { () },
  }
}

///|
async test "整环故障：宿主报 fatal，当前调用折错误、环到 idle，下一轮立刻失败" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session(mode="fatal")
  defer io.close()
  let remote_runner : @provider.RemoteExecutor = {
    owns: fn(name) { session.owns(name) },
    run: async fn(call) { session.call_tool(call) },
  }
  let tool_results : Array[@message.ToolResultPart] = []
  let agent = @runtime.Agent::new(
    @state.create_initial_state({
      system_prompt: "故障测试",
      provider_name: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      tool_names: [],
      max_turns: None,
      max_llm_attempts: 2,
      llm_timeout_ms: 120000L,
      session_id: "s-fatal",
      cwd: ".",
      trace: None,
    }),
    failure_table(
      batches=[
        ["fake_tool"],
        ["fake_tool"],
      ],
      remote=remote_runner,
      external=None,
    ),
    fn() { 0L },
  )
  agent.observe(action => {
    match action {
      @action.ToolResult(part) => tool_results.push(part)
      _ => ()
    }
  })
  agent.send(
    @action.PromptInit({
      system_prompt: "故障测试",
      tools: session.definitions_for(["fake_tool"]),
    }),
  )
  // 第一轮：调用正撞上宿主报 fatal —— 折成 is_error，环照常走到 idle。
  agent.send(@action.UserMessage({ text: "第一批", content: [], }))
  assert_eq(agent.state.phase, @common.Idle)
  assert_eq(agent.state.messages.length(), 4)
  assert_eq(agent.state.messages[2].role(), "toolResult")
  assert_eq(tool_results.length(), 1)
  assert_true(tool_results[0].is_error)
  assert_true(@message.contents_text(tool_results[0].content).contains("boom-from-host"))
  // 第二轮：对已死会话再调用 —— 立刻失败（不挂死、不重连），环照样 idle。
  agent.send(@action.UserMessage({ text: "第二批", content: [], }))
  assert_eq(agent.state.phase, @common.Idle)
  assert_eq(tool_results.length(), 2)
  assert_true(tool_results[1].is_error)
  assert_true(@message.contents_text(tool_results[1].content).contains("已经退出"))
  assert_true(session.rpc.is_dead())
  session.close()
}

///|
async test "整环故障：宿主断线后，远程失败而本地与扩展工具照常" {
  if !rtools_node_available() {
    return
  }
  let (io, session) = fake_session(mode="drop")
  defer io.close()
  let remote_runner : @provider.RemoteExecutor = {
    owns: fn(name) { session.owns(name) },
    run: async fn(call) { session.call_tool(call) },
  }
  let ext_runner : @provider.ExternalTools = {
    owns: fn(name) { name == "ext_tool" },
    run: async fn(call) {
      { content: [@message.Text("EXT:" + call.name)], is_error: false, }
    },
    emit: async fn(_, _) { () },
  }
  let tool_results : Array[@message.ToolResultPart] = []
  let agent = @runtime.Agent::new(
    @state.create_initial_state({
      system_prompt: "故障测试",
      provider_name: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      tool_names: [],
      max_turns: None,
      max_llm_attempts: 2,
      llm_timeout_ms: 120000L,
      session_id: "s-drop",
      cwd: "_build/rtools-e2e",
      trace: None,
    }),
    failure_table(
      batches=[
        ["fake_tool"],
        ["fake_tool", "read", "ext_tool"],
      ],
      remote=remote_runner,
      external=Some(ext_runner),
    ),
    fn() { 0L },
  )
  agent.observe(action => {
    match action {
      @action.ToolResult(part) => tool_results.push(part)
      _ => ()
    }
  })
  // read 不在假宿主注册表里（宿主只报 fake_tool）——本地执行位要真的能跑，
  // 就得像「恢复的旧会话」那样把它声明进来。
  let declared = with_ext(session.definitions_for(["fake_tool"]))
  declared.push({ name: "read", description: "本地的", parameters: "{}", })
  agent.send(@action.PromptInit({ system_prompt: "故障测试", tools: declared, }))
  // 本地 read 的证据文件：目录自建（不能指望并行的测试顺手建）。
  @fs.mkdir("_build/rtools-e2e", recursive=true) catch { _ => () }
  @sys.write_text("_build/rtools-e2e/fallback.txt", "本地照常") catch { _ => () }
  // 第一轮：调用中途对端断开 —— 折成 is_error（诊断带宿主噪音行），环到 idle。
  agent.send(@action.UserMessage({ text: "第一批", content: [], }))
  assert_eq(agent.state.phase, @common.Idle)
  // 消息序列合法：user / assistant(工具调用) / toolResult / assistant。
  assert_eq(agent.state.messages.length(), 4)
  assert_eq(agent.state.messages[2].role(), "toolResult")
  assert_eq(tool_results.length(), 1)
  assert_true(tool_results[0].is_error)
  assert_true(@message.contents_text(tool_results[0].content).contains("提前退出"))
  // 宿主断线前自己说的那行话进了诊断措辞（噪音行跟着 PeerClosed 走）。
  assert_true(@message.contents_text(tool_results[0].content).contains("[fake] dying"))
  // 第二轮：已死远程立刻失败，本地 read 与扩展工具照常 —— 路由链其余部分不受影响。
  agent.send(@action.UserMessage({ text: "第二批", content: [], }))
  assert_eq(agent.state.phase, @common.Idle)
  // 第二轮消息：user / assistant(3 个调用) / toolResult×3 / assistant —— 序列合法。
  assert_eq(agent.state.messages.length(), 10)
  assert_eq(agent.state.messages[4].role(), "user")
  assert_eq(agent.state.messages[5].role(), "assistant")
  assert_eq(agent.state.messages[6].role(), "toolResult")
  assert_eq(agent.state.messages[7].role(), "toolResult")
  assert_eq(agent.state.messages[8].role(), "toolResult")
  assert_eq(agent.state.messages[9].role(), "assistant")
  assert_eq(tool_results.length(), 4)
  assert_true(tool_results[1].is_error)
  assert_true(@message.contents_text(tool_results[1].content).contains("已经退出"))
  let local_text = @message.contents_text(tool_results[2].content)
  // assert_eq 打头：失败时能看到 read 折回来的实际错误文本。
  assert_eq(local_text, "本地照常")
  assert_false(tool_results[2].is_error)
  assert_eq(@message.contents_text(tool_results[3].content), "EXT:ext_tool")
  assert_false(tool_results[3].is_error)
  session.close()
}
