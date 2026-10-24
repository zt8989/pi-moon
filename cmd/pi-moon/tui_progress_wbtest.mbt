///|
test "chat_lines：执行中的工具显示 tool_progress 尾部输出" {
  let call : @message.ToolCall = {
    id: "c1",
    name: "bash",
    arguments: "{\"command\":\"sleep 5\"}",
  }
  // 助手消息带工具调用，但还没有 toolResult —— 工具正在跑。
  let assistant : @message.Message = @message.AssistantMsg({
    content: [@message.ToolCallBlock(call)],
    stop_reason: "toolUse",
    error_message: None,
    usage: None,
    timestamp: 2L,
  })
  let progress : @ihm.HashMap[String, @state.ToolProgress] = @ihm.HashMap::singleton(
    "c1",
    { tool_call_id: "c1", content: [@message.Text("step1\nstep2\nstep3")], },
  )
  let state = {
    ..test_state(),
    phase: @common.CallingTools,
    messages: [@message.user_message("跑一下", 1L), assistant],
    tool_progress: progress,
  }
  let lines = chat_lines(state, false, 60, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  // 进度尾部应该在块里可见。
  assert_true(text.contains("step3"))
}

///|
async test "端到端：真实 bash 执行产生进度，chat_lines 能画出来" {
  let actions : Array[@action.AgentAction] = []
  let dispatch : @runtime.Dispatch = { emit: action => actions.push(action), }
  // 真实工具执行（非 noop 表）：边跑边发 ToolProgress。
  let outcome = @tools.execute(
    ".",
    {
      id: "call-e2e",
      name: "bash",
      arguments: "{\"command\":\"printf step1; sleep 0.3; printf step2\"}",
    },
    enabled=["bash"],
    on_progress=async fn(blocks) {
      dispatch.send(
        @action.ToolProgress({ tool_call_id: "call-e2e", content: blocks, }),
      )
    },
  ) catch {
    err => {
      assert_true(false)
      abort("execute failed: " + err.to_string())
    }
  }
  assert_false(outcome.is_error)
  let mut saw_progress = false
  for action in actions {
    match action {
      @action.ToolProgress(data) =>
        if @message.contents_text(data.content).contains("step1") {
          saw_progress = true
        }
      _ => ()
    }
  }
  assert_true(saw_progress)
  // 渲染层：执行中途的帧 —— 调用已入 messages、结果未到、进度在 state。
  let progress_state = {
    ..test_state(),
    phase: @common.CallingTools,
    messages: [
      @message.user_message("跑", 1L),
      @message.AssistantMsg({
        content: [
          @message.ToolCallBlock({
            id: "call-e2e",
            name: "bash",
            arguments: "{}",
          }),
        ],
        stop_reason: "toolUse",
        error_message: None,
        usage: None,
        timestamp: 2L,
      }),
    ],
    tool_progress: @ihm.HashMap::singleton("call-e2e", {
      tool_call_id: "call-e2e",
      content: [@message.Text("step1")],
    }),
  }
  let lines = chat_lines(progress_state, false, 60, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("step1"))
}

///|
test "chat_lines：图片块画占位而不是消失" {
  let assistant : @message.Message = @message.AssistantMsg({
    content: [
      @message.Text("读了图"),
      @message.Image("data:image/png;base64,AAA"),
    ],
    stop_reason: "stop",
    error_message: None,
    usage: None,
    timestamp: 2L,
  })
  let state = { ..test_state(), messages: [assistant], }
  let lines = chat_lines(state, false, 60, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("[image image/png]"))
  assert_true(text.contains("读了图"))
}

///|
test "chat_lines：外部 URL 的图片占位带 URL" {
  let assistant : @message.Message = @message.AssistantMsg({
    content: [@message.Image("https://example.com/a.png")],
    stop_reason: "stop",
    error_message: None,
    usage: None,
    timestamp: 2L,
  })
  let state = { ..test_state(), messages: [assistant], }
  let lines = chat_lines(state, false, 60, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("https://example.com/a.png"))
}
