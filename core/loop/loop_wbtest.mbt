// 纯函数层的环断言：迁移与接线各自做了什么。
//
// 这些测试不接 effect —— 它们盯的是「表」本身：某个 action 该把状态变成什么、
// 该发哪些 Cmd。真正的整环由 `core/runtime` 的黑盒测试盯。

///|
fn loop_test_state() -> @state.AgentState {
  @state.create_initial_state({
    system_prompt: "你是助手",
    provider_name: "demo",
    model_id: "demo-1",
    thinking_level: "off",
    tool_names: ["read"],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s-test",
    cwd: "/tmp",
    trace: None,
  })
}

///|
fn loop_test_loaded() -> @state.AgentState {
  let state = loop_test_state()
  let (state, _) = reduce(
    state,
    @action.PromptInit({ system_prompt: "你是助手", tools: [], }),
    10L,
  )
  let (state, _) = reduce(
    state,
    @action.ModelInit({
      provider: "demo",
      model_id: "demo-1",
      thinking_level: "off",
      reasoning: false,
      capabilities: @action.no_capabilities,
      context_window: 1000,
    }),
    11L,
  )
  state
}

///|
fn cmd_names(cmds : Array[Cmd]) -> Array[String] {
  let names : Array[String] = []
  for cmd in flatten_cmds(cmds) {
    names.push(
      match cmd {
        Redispatch(action) => "action:" + action.name()
        RunAgent(_) => "run-agent"
        RunTools(calls) => "run-tools:" + calls.length().to_string()
        _ => "?"
      },
    )
  }
  names
}

///|
fn user(text : String) -> @action.AgentAction {
  @action.UserMessage({ text, content: [], })
}

///|
test "user.message 只发 turn.start（再发 agent.run 会把模型调两遍）" {
  let state = loop_test_loaded()
  let (next, cmds) = reduce(state, user("查一下"), 100L)
  assert_eq(next.phase, @common.Thinking)
  assert_eq(next.messages.length(), 1)
  assert_true(next.trace_begun)
  // 装载节点在 user 节点之前补上：prompt.base / prompt.tools / model.init。
  assert_eq(cmd_names(cmds), ["action:turn.start"])
  let kinds : Array[@trace.TraceNodeKind] = []
  for id in next.trace.order {
    match next.trace.nodes.get(id) {
      Some(node) => kinds.push(node.kind)
      None => ()
    }
  }
  assert_eq(kinds, [
    @trace.PromptBase,
    @trace.PromptTools,
    @trace.ModelInit,
    @trace.User,
  ])
}

///|
test "turn.start 发 step.start + agent.run；step.start 开容器" {
  let state = loop_test_loaded()
  let (state, _) = reduce(state, user("查一下"), 100L)
  let (state, cmds) = reduce(state, @action.TurnStart, 101L)
  assert_eq(cmd_names(cmds), ["action:step.start", "action:agent.run"])
  assert_eq(state.turn_index, 1)
  assert_true(state.open_turn_node_id is Some(_))
  let (state, cmds) = reduce(state, @action.StepStart, 102L)
  assert_eq(cmd_names(cmds), [])
  assert_eq(state.step_index, 1)
  assert_true(state.open_step_node_id is Some(_))
  assert_true(state.open_llm_node_id is Some(_))
  // step 容器挂在 turn 容器下面。
  let step_id = state.open_step_node_id.unwrap()
  let step = state.trace.nodes.get(step_id).unwrap()
  assert_eq(step.parent_id, state.open_turn_node_id)
}

///|
test "有工具：llm.done 发 runTools，step 保持开着" {
  let state = loop_test_state()
  let (state, _) = reduce(state, user("查"), 100L)
  let (state, _) = reduce(state, @action.TurnStart, 101L)
  let (state, _) = reduce(state, @action.StepStart, 102L)
  let (state, _) = reduce(state, @action.AgentRun(None), 103L)
  let call : @message.ToolCall = {
    id: "call_1",
    name: "read",
    arguments: "{\"path\":\"a.txt\"}",
  }
  let (state, cmds) = reduce(
    state,
    @action.LlmDone({
      message: {
        content: [@message.Text("我看一下"), @message.ToolCallBlock(call)],
        stop_reason: "toolUse",
        error_message: None,
        usage: None,
        timestamp: 104L,
      },
      node_id: None,
    }),
    105L,
  )
  assert_eq(state.phase, @common.CallingTools)
  assert_true(state.open_step_node_id is Some(_))
  assert_eq(state.pending_tool_calls.length(), 1)
  assert_eq(cmd_names(cmds), ["run-tools:1"])
}

///|
test "无工具：llm.done 关 step、相位回 idle，接线发 turn.end" {
  let state = loop_test_state()
  let (state, _) = reduce(state, user("说句话"), 100L)
  let (state, _) = reduce(state, @action.TurnStart, 101L)
  let (state, _) = reduce(state, @action.StepStart, 102L)
  let (state, _) = reduce(state, @action.AgentRun(None), 103L)
  let (state, cmds) = reduce(
    state,
    @action.LlmDone({
      message: {
        content: [@message.Text("说完了")],
        stop_reason: "stop",
        error_message: None,
        usage: None,
        timestamp: 104L,
      },
      node_id: None,
    }),
    105L,
  )
  assert_eq(state.phase, @common.Idle)
  assert_true(state.open_step_node_id is None)
  assert_eq(state.stop_reason, Some(@common.Completed))
  assert_eq(state.turns, 1)
  assert_eq(cmd_names(cmds), ["action:turn.end"])
  let (state, _) = reduce(state, @action.TurnEnd, 106L)
  assert_true(state.open_turn_node_id is None)
  assert_eq(state.turn_steps, 1)
}

///|
test "超时可重试：容器不重开，第二次失败才收工" {
  let state = loop_test_state()
  let (state, _) = reduce(state, user("查"), 100L)
  let (state, _) = reduce(state, @action.TurnStart, 101L)
  let (state, _) = reduce(state, @action.StepStart, 102L)
  let step_id = state.open_step_node_id.unwrap()
  let (state, _) = reduce(state, @action.AgentRun(None), 103L)
  let (state, cmds) = reduce(
    state,
    @action.LlmFailed({
      error: "request timeout",
      kind: @common.Timeout,
      node_id: None,
      cause: None,
    }),
    104L,
  )
  // 还在同一个容器里重试。
  assert_eq(state.open_step_node_id, Some(step_id))
  assert_eq(state.phase, @common.Thinking)
  assert_true(state.retrying)
  assert_eq(state.llm_attempts, 2)
  assert_eq(cmd_names(cmds), ["action:agent.run"])
  // 第二次失败 = 预算用尽。
  let (state, _) = reduce(state, @action.AgentRun(None), 105L)
  let (state, cmds) = reduce(
    state,
    @action.LlmFailed({
      error: "request timeout",
      kind: @common.Timeout,
      node_id: None,
      cause: None,
    }),
    106L,
  )
  assert_eq(state.phase, @common.Idle)
  assert_eq(state.stop_reason, Some(@common.Errored))
  assert_eq(state.stop_cause, Some(@common.CauseTimeout))
  assert_true(state.open_step_node_id is None)
  assert_true(state.open_turn_node_id is Some(_))
  assert_eq(cmd_names(cmds), ["action:turn.end"])
  // 同一个 step 容器里两个 error 孩子 + 一个 step.end。
  let errors = @trace.children_of(state.trace, Some(step_id)).filter(node => {
    node.kind == @trace.ErrorNode
  })
  assert_eq(errors.length(), 2)
}
