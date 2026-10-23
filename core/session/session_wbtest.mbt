// 会话 JSONL：编解码、增量 flush、回放、坏行容错。

///|
fn session_test_path(name : String) -> String {
  "_build/session-test/" + name + ".jsonl"
}

///|
async fn remove_file(path : String) -> Unit {
  @fs.remove(path) catch {
    _ => ()
  }
}

///|
fn session_state() -> @state.AgentState {
  @state.create_initial_state({
    system_prompt: "你是助手",
    provider_name: "demo",
    model_id: "demo-1",
    thinking_level: "high",
    tool_names: ["read"],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s-session",
    cwd: ".",
    trace: None,
  })
}

///|
fn session_tool() -> @action.PromptToolDefinition {
  {
    name: "read",
    description: "Read file contents",
    parameters: "{\"type\":\"object\"}",
  }
}

///|
fn session_model() -> @action.ModelSpec {
  {
    provider: "demo",
    model_id: "demo-1",
    thinking_level: "high",
    reasoning: true,
    capabilities: {
      mid_convo_system_messages: false,
      mid_convo_tool_additions: false,
      developer_role: true,
    },
    context_window: 1000,
  }
}

///|
/// 跑到「一问一答完」的状态：prompt.init → model.init → user → llm.done → turn.end。
fn session_state_after_turn() -> @state.AgentState {
  let (state, _) = @loop.reduce(
    session_state(),
    @action.PromptInit({
      system_prompt: "你是助手",
      tools: [session_tool()],
    }),
    1L,
  )
  let (state, _) = @loop.reduce(state, @action.ModelInit(session_model()), 2L)
  let (state, _) = @loop.reduce(
    state,
    @action.UserMessage({ text: "你好", content: [], }),
    3L,
  )
  let (state, _) = @loop.reduce(state, @action.LlmStarted, 4L)
  let (state, _) = @loop.reduce(
    state,
    @action.LlmDone({
      message: {
        content: [@message.Text("你好呀")],
        stop_reason: "stop",
        error_message: None,
        usage: Some({
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          cost_total: 0.01,
        }),
        timestamp: 5L,
      },
      node_id: None,
    }),
    5L,
  )
  let (state, _) = @loop.reduce(state, @action.TurnEnd, 6L)
  state
}

///|
test "消息编解码：四种 role 与全部内容块" {
  let messages : Array[@message.Message] = [
    @message.UserMsg({
      content: [
        @message.Text("看看这个"),
        @message.Thinking("想一下"),
        @message.Image("data:image/png;base64,AAA"),
      ],
      timestamp: 1L,
    }),
    @message.AssistantMsg({
      content: [
        @message.Text("我读一下"),
        @message.ToolCallBlock({
          id: "c1",
          name: "read",
          arguments: "{\"path\":\"a\"}",
        }),
      ],
      stop_reason: "toolUse",
      error_message: Some("boom"),
      usage: Some({
        input_tokens: 1,
        output_tokens: 2,
        total_tokens: 3,
        cost_total: 0.5,
      }),
      timestamp: 2L,
    }),
    @message.ToolResultMsg({
      tool_call_id: "c1",
      tool_name: "read",
      content: [@message.Text("文件内容")],
      is_error: false,
      timestamp: 3L,
    }),
    @message.SystemMsg({
      role: "developer",
      content: "中途加的规则",
      sections: [("rules", "别乱删文件")],
      source: Some("test"),
      timestamp: 4L,
    }),
  ]
  for message in messages {
    let json = encode_message(message)
    let text = json.stringify()
    let parsed = @json.parse(text) catch {
      _ => abort("encode produced invalid JSON")
    }
    assert_eq(decode_message(parsed), Some(message))
  }
}

///|
test "节点编解码：可选字段与 message 一起往返" {
  let tree = @trace.create_trace_tree("s-x")
  let (_tree, node) = @trace.append_node(
    tree,
    None,
    @trace.ToolResultNode,
    @trace.Ok,
    "tool.result: 读完了",
    10L,
    detail="完整内容",
    meta=[("tool", "read")],
    message=@message.tool_result_message(
      { id: "c1", name: "read", arguments: "{}", },
      "内容",
      false,
      10L,
    ),
    ended_at=11L,
  )
  let encoded = encode_node(node)
  let parsed = @json.parse(encoded.stringify()) catch {
    _ => abort("encode produced invalid JSON")
  }
  let decoded = match decode_node(parsed) {
    Some(decoded) => decoded
    None => abort("decode failed")
  }
  assert_eq(decoded, node)
  assert_eq(@trace.node_seq(node.id), 1)
}

///|
async test "flush → load：messages / trace / 装载段都能重建，且重复 flush 不写重复行" {
  let path = session_test_path("basic")
  remove_file(path)
  let state = session_state_after_turn()
  let writer = SessionWriter::new(path)
  let (writer, cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  assert_eq(
    cursor,
    @trace.node_seq(state.trace.order[state.trace.order.length() - 1]),
  )
  let text = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let lines = @utf8.decode_lossy(text).split("\n").count()
  // 第一次 flush 之后：prompt.init + model.init + add 节点 + message 行。
  assert_true(lines > 4)
  // 再 flush 一次：没有新内容 → 行数不变。
  let (_writer, cursor2) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  assert_eq(cursor2, cursor)
  let text2 = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let lines2 = @utf8.decode_lossy(text2).split("\n").count()
  assert_eq(lines2, lines)

  let loaded = match load_session(path, "s-session") {
    Some(loaded) => loaded
    None => abort("load failed")
  }
  assert_eq(loaded.messages, state.messages)
  assert_eq(loaded.trace, state.trace)
  assert_eq(loaded.persisted_seq, cursor)
  match loaded.prompt {
    Some(prompt) => {
      assert_eq(prompt.system_prompt, "你是助手")
      assert_eq(prompt.tools.length(), 1)
      assert_eq(prompt.tools[0].parameters, "{\"type\":\"object\"}")
    }
    None => abort("prompt.init missing")
  }
  match loaded.model {
    Some(model) => {
      assert_eq(model.provider, "demo")
      assert_eq(model.thinking_level, "high")
      assert_eq(model.context_window, 1000)
      assert_true(model.capabilities.developer_role)
    }
    None => abort("model.init missing")
  }
  remove_file(path)
}

///|
async test "pending 节点：先 add 后 close，回放出来是闭合的" {
  let path = session_test_path("pending")
  remove_file(path)
  let state = session_state_after_turn()
  let (tree, pending) = @trace.append_node(
    state.trace,
    state.trace.tip_id,
    @trace.ToolCallNode,
    @trace.Pending,
    "tool.call: read",
    20L,
    detail="{}",
    meta=[("tool", "read")],
  )
  let state = { ..state, trace: tree, }
  let writer = SessionWriter::new(path)
  let (writer, cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  let closed = @trace.patch_node(
    state.trace,
    pending.id,
    status=@trace.Ok,
    ended_at=21L,
  )
  let state = { ..state, trace: closed, }
  let (_writer, cursor2) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  assert_eq(cursor2, cursor)
  let loaded = match load_session(path, "s-session") {
    Some(loaded) => loaded
    None => abort("load failed")
  }
  match loaded.trace.nodes.get(pending.id) {
    Some(node) => {
      assert_eq(node.status, @trace.Ok)
      assert_eq(node.ended_at, Some(21L))
    }
    None => abort("pending node missing")
  }
  remove_file(path)
}

///|
async test "恢复继续写：游标接上，不重写历史" {
  let path = session_test_path("restore")
  remove_file(path)
  let state = session_state_after_turn()
  let writer = SessionWriter::new(path)
  let (_writer, _cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  let before = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let before_lines = @utf8.decode_lossy(before).split("\n").count()
  let loaded = match load_session(path, "s-session") {
    Some(loaded) => loaded
    None => abort("load failed")
  }
  let restored = SessionWriter::restored(path, loaded)
  let (_restored, _cursor) = restored.flush(state) catch {
    err => abort(err.to_string())
  }
  let after = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let after_lines = @utf8.decode_lossy(after).split("\n").count()
  assert_eq(after_lines, before_lines)
  remove_file(path)
}

///|
async test "坏行（崩溃截断）跳过，不影响前面的记录" {
  let path = session_test_path("badline")
  remove_file(path)
  let state = session_state_after_turn()
  let writer = SessionWriter::new(path)
  let (_writer, _cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  @fs.write_file(
    path,
    "{\"op\":\"message\",\"mess",
    append=true,
    create_mode=OpenOrCreate,
  )
  let loaded = match load_session(path, "s-session") {
    Some(loaded) => loaded
    None => abort("load failed")
  }
  assert_eq(loaded.messages, state.messages)
  remove_file(path)
}

///|
async test "会话路径：时间戳命名、--continue 取最新、id 从文件名来" {
  let dir = "_build/session-test/dir"
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
  @fs.mkdir(dir, recursive=true)
  @fs.write_file(dir + "/100.jsonl", "{}\n")
  @fs.write_file(dir + "/200.jsonl", "{}\n")
  assert_eq(latest_session(dir), Some(dir + "/200.jsonl"))
  assert_eq(session_id_from_path(dir + "/200.jsonl"), "200")
  assert_eq(new_session_path(dir, 1234L), dir + "/1234.jsonl")
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "tools.changed 落盘：恢复出当前工具集，head 仍是装载时那批" {
  let path = session_test_path("tools")
  remove_file(path)
  let state = session_state_after_turn()
  let grep_tool : @action.PromptToolDefinition = {
    name: "grep",
    description: "Search file contents",
    parameters: "{\"type\":\"object\"}",
  }
  let current = [session_tool(), grep_tool]
  // 先落一次盘：prompt.init 记的是**装载时**那批（read）。
  let writer = SessionWriter::new(path)
  let (writer, _cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  let (state, _) = @loop.reduce(state, @action.ToolsChanged(current), 30L)
  // 请求发起：把差额声明进消息流（同时写进会话的 message 记录）。
  let (state, _) = @loop.reduce(state, @action.AgentRun(None), 31L)
  let (_writer, _cursor) = writer.flush(state) catch {
    err => abort(err.to_string())
  }
  let loaded = match load_session(path, "s-session") {
    Some(loaded) => loaded
    None => abort("load failed")
  }
  assert_eq(loaded.tools, Some(current))
  match loaded.prompt {
    Some(prompt) => assert_eq(prompt.tools, [session_tool()])
    None => abort("prompt.init missing")
  }
  // 恢复出来的 writer 已经知道当前工具集，不会把 tools.changed 再写一遍。
  let before = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let before_lines = @utf8.decode_lossy(before).split("\n").count()
  let restored = SessionWriter::restored(path, loaded)
  let (_restored, _cursor) = restored.flush(state) catch {
    err => abort(err.to_string())
  }
  let after = (@fs.read_file(path) catch { _ => abort("file missing") }).binary()
  let after_lines = @utf8.decode_lossy(after).split("\n").count()
  assert_eq(after_lines, before_lines)
  remove_file(path)
}
