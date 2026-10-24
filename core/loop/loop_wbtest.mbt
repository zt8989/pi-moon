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
        RunCompact => "run-compact"
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

///|
test "session.restored：一次性装回 messages / trace / 游标，不重放历史" {
  // 先造一段有历史的状态。
  let (with_history, _) = reduce(loop_test_loaded(), user("第一句"), 100L)
  let messages = with_history.messages
  let trace = with_history.trace
  let tip = trace.tip_id
  let read_tool : @action.PromptToolDefinition = {
    name: "read",
    description: "读",
    parameters: "{\"type\":\"object\"}",
  }
  let grep_tool : @action.PromptToolDefinition = {
    name: "grep",
    description: "搜",
    parameters: "{\"type\":\"object\"}",
  }
  let restored = @action.SessionRestored({
    prompt: { system_prompt: "恢复出来的 prompt", tools: [read_tool], },
    tools: [read_tool, grep_tool],
    model: {
      provider: "other",
      model_id: "other-1",
      thinking_level: "low",
      reasoning: true,
      capabilities: @action.no_capabilities,
      context_window: 2000,
    },
    messages,
    trace,
    persisted_seq: 42,
  })
  let (next, cmds) = reduce(loop_test_state(), restored, 200L)
  assert_eq(cmd_names(cmds), [])
  assert_eq(next.phase, @common.Idle)
  assert_eq(next.messages, messages)
  assert_eq(next.trace.order, trace.order)
  assert_eq(next.trace.tip_id, tip)
  assert_eq(next.trace_begun, true)
  assert_eq(next.prompt.system_prompt, "恢复出来的 prompt")
  assert_eq(next.prompt.seeded, true)
  // head 是装载时那批；当前工具集与已声明的那份是恢复文件里的新一批。
  assert_eq(next.prompt.head_tools, Some([read_tool]))
  assert_eq(next.prompt.tools.length(), 2)
  assert_eq(next.prompt.declared_tools.length(), 2)
  assert_eq(next.tool_names.join(","), "read,grep")
  assert_eq(next.model.provider, "other")
  assert_eq(next.model.thinking_level, "low")
  assert_eq(next.provider_name, "other")
  assert_eq(next.thinking_level, "low")
  assert_eq(next.persisted_seq, 42)
  // 下一句用户输入接在历史后面，而不是从空会话开始。
  let (after, _) = reduce(next, user("第二句"), 300L)
  assert_eq(after.messages.length(), messages.length() + 1)
  assert_eq(after.trace.order.length(), trace.order.length() + 1)
}

///|
test "tools.changed：只改当前集；下一次 agent.run 追加一次声明消息" {
  let read_tool : @action.PromptToolDefinition = {
    name: "read",
    description: "读",
    parameters: "{\"type\":\"object\"}",
  }
  let grep_tool : @action.PromptToolDefinition = {
    name: "grep",
    description: "搜",
    parameters: "{\"type\":\"object\"}",
  }
  let (state, _) = reduce(
    loop_test_state(),
    @action.PromptInit({ system_prompt: "你是助手", tools: [read_tool], }),
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
  let (state, _) = reduce(state, user("第一句"), 12L)
  let (changed, cmds) = reduce(
    state,
    @action.ToolsChanged([read_tool, grep_tool]),
    13L,
  )
  assert_eq(cmd_names(cmds), [])
  assert_eq(changed.prompt.tools.length(), 2)
  assert_eq(changed.prompt.head_tools, Some([read_tool]))
  // 还没声明：declared 仍是 head 那一份。
  assert_eq(changed.prompt.declared_tools, [read_tool])
  assert_eq(changed.tool_names.join(","), "read,grep")
  // 请求即将发起：追加一条 system 消息，并更新 declared。
  // 先 StepStart —— 真实流程里它先把 step 容器打开，AgentRun 会走防重入分支。
  let (stepped, _) = reduce(changed, @action.StepStart, 14L)
  let (running, _) = reduce(stepped, @action.AgentRun(None), 15L)
  assert_eq(running.messages.length(), changed.messages.length() + 1)
  match running.messages[running.messages.length() - 1] {
    @message.SystemMsg(part) => {
      assert_eq(part.source, Some("tools.changed"))
      assert_true(part.content.contains("added:"))
      assert_true(part.content.contains("grep"))
    }
    _ => abort("expected a tools.changed system message")
  }
  assert_eq(running.prompt.declared_tools.length(), 2)
  // 第二次 agent.run（重试 / 下一步）不再重复追加。
  let (again, _) = reduce(running, @action.AgentRun(None), 16L)
  assert_eq(again.messages.length(), running.messages.length())
}

///|
test "tools.changed：同名定义变了 → updated，并且 head 不动" {
  let read_v1 : @action.PromptToolDefinition = {
    name: "read",
    description: "读 v1",
    parameters: "{\"type\":\"object\"}",
  }
  let read_v2 : @action.PromptToolDefinition = {
    name: "read",
    description: "读 v2",
    parameters: "{\"type\":\"object\",\"required\":[\"path\"]}",
  }
  let (state, _) = reduce(
    loop_test_state(),
    @action.PromptInit({ system_prompt: "你是助手", tools: [read_v1], }),
    10L,
  )
  let (state, _) = reduce(state, user("第一句"), 12L)
  let (changed, _) = reduce(state, @action.ToolsChanged([read_v2]), 13L)
  assert_eq(changed.prompt.head_tools, Some([read_v1]))
  let (stepped, _) = reduce(changed, @action.StepStart, 13L)
  let (running, _) = reduce(stepped, @action.AgentRun(None), 14L)
  match running.messages[running.messages.length() - 1] {
    @message.SystemMsg(part) =>
      assert_true(part.content.contains("updated: read"))
    _ => abort("expected a tools.changed system message")
  }
}

// ─── 压缩 ────────────────────────────────────────────────────────────────────

///|
fn compact_history() -> Array[@message.Message] {
  [
    @message.user_message("第一问", 1L),
    @message.assistant_message("第一答", "stop", 2L),
    @message.user_message("第二问", 3L),
    @message.assistant_message("第二答", "stop", 4L),
  ]
}

///|
/// 装好历史，并把 keepRecent 调到 1 —— 测试要的是「切点算得对」，
/// 不是「默认参数下历史够不够长」。
fn compact_ready() -> @state.AgentState {
  let loaded = loop_test_loaded()
  let (state, _) = reduce(
    { ..loaded, messages: compact_history(), },
    @action.CompactSettingsChanged({
      enabled: true,
      reserve_tokens: 200,
      keep_recent_tokens: 1,
    }),
    20L,
  )
  state
}

///|
test "compact.request：开 pending 节点、算好切点、发 run-compact" {
  let state = compact_ready()
  let (next, cmds) = reduce(state, @action.CompactRequest(@compact.Manual), 21L)
  assert_true(next.compacting)
  assert_true(next.compact_requested)
  assert_eq(next.compact_reason, Some(@compact.Manual))
  assert_true(next.compact_plan is Some(_))
  assert_eq(cmd_names(cmds), ["run-compact"])
  // pending 节点已经开好了：中途挂掉也能看出「开始压缩了」。
  let node_id = next.open_compact_node_id.unwrap()
  let node = next.trace.nodes.get(node_id).unwrap()
  assert_eq(node.kind, @trace.CompactNode)
  assert_eq(node.status, @trace.Pending)
}

///|
test "compact.request：环还在跑时不压（消息序列会变成非法的）" {
  let state = compact_ready()
  let (running, _) = reduce(state, user("再说一句"), 22L)
  let (next, cmds) = reduce(
    running,
    @action.CompactRequest(@compact.Threshold),
    23L,
  )
  assert_false(next.compacting)
  assert_false(next.compact_requested)
  assert_eq(cmds, [])
}

///|
test "compact.request：压缩中再来一次被挡住，不会跑第二遍 effect" {
  let state = compact_ready()
  let (running, _) = reduce(state, @action.CompactRequest(@compact.Manual), 21L)
  let (next, cmds) = reduce(
    running,
    @action.CompactRequest(@compact.Manual),
    22L,
  )
  assert_true(next.compacting)
  assert_false(next.compact_requested)
  assert_eq(cmds, [])
}

///|
test "compact.done：整份换掉 messages，节点闭合并推进 tip" {
  let state = compact_ready()
  let (running, _) = reduce(state, @action.CompactRequest(@compact.Manual), 21L)
  let node_id = running.open_compact_node_id.unwrap()
  let summary = @compact.build_summary_message("压缩后的摘要", 100, 22L)
  let (next, cmds) = reduce(
    running,
    @action.CompactDone({
      messages: [summary],
      summary: "压缩后的摘要",
      tokens_before: 100,
      summarized_count: 3,
      kept_count: 1,
      usage: Some({
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
        cost_total: 0.5,
      }),
    }),
    22L,
  )
  assert_eq(cmds, [])
  assert_false(next.compacting)
  assert_eq(next.messages.length(), 1)
  assert_true(@compact.is_summary_message(next.messages[0]))
  // compact 节点推进 tip：之后的历史是从摘要开始长出来的。
  assert_eq(next.trace.tip_id, Some(node_id))
  let node = next.trace.nodes.get(node_id).unwrap()
  assert_eq(node.status, @trace.Ok)
  assert_true(node.label.contains("3 条 → 1 条"))
  assert_eq(next.last_compaction.unwrap().reason, @compact.Manual)
  assert_eq(next.compaction_epoch, 1)
  // 摘要花掉的 token 记进累计用量。
  assert_eq(next.usage.unwrap().total_tokens, 15)
  // 压缩不改「上一轮为什么停」。
  assert_eq(next.stop_cause, None)
}

///|
test "compact.failed：对话一个字不动，但失败要留在树上" {
  let state = compact_ready()
  let (running, _) = reduce(state, @action.CompactRequest(@compact.Manual), 21L)
  let before = running.messages.copy()
  let node_id = running.open_compact_node_id.unwrap()
  let (next, _) = reduce(
    running,
    @action.CompactFailed({ error: "摘要被 token 上限截断", }),
    22L,
  )
  assert_false(next.compacting)
  assert_eq(next.messages.length(), before.length())
  assert_eq(next.messages[0], before[0])
  assert_eq(next.stop_cause, Some(@common.CauseCompactError))
  assert_true(next.error.unwrap().contains("截断"))
  let node = next.trace.nodes.get(node_id).unwrap()
  assert_eq(node.status, @trace.Errored)
  // 失败节点挂在 compact 节点下面，树上能看出是哪一步失败的。
  let error_node = next.trace.nodes.get(next.error_node_id.unwrap()).unwrap()
  assert_eq(error_node.parent_id, Some(node_id))
  assert_eq(error_node.kind, @trace.ErrorNode)
}

///|
test "compact.request：没什么可压时回一条 0 条 → N 条的 done，而不是静默" {
  let state = {
    ..loop_test_loaded(),
    messages: [@message.user_message("只有一问", 1L)],
  }
  let (running, cmds) = reduce(
    state,
    @action.CompactRequest(@compact.Manual),
    21L,
  )
  assert_true(running.compacting)
  assert_eq(cmd_names(cmds), ["action:compact.done"])
  let (next, _) = reduce(
    running,
    @action.CompactDone({
      messages: running.messages,
      summary: "",
      tokens_before: 0,
      summarized_count: 0,
      kept_count: running.messages.length(),
      usage: None,
    }),
    22L,
  )
  assert_false(next.compacting)
  assert_eq(next.messages.length(), 1)
  assert_eq(next.last_compaction.unwrap().summarized_count, 0)
  // 没有换历史，epoch 不动（落盘器不该重写历史）。
  assert_eq(next.compaction_epoch, 0)
  let label = next.trace.nodes
    .get(next.trace.order[next.trace.order.length() - 1])
    .unwrap().label
  assert_true(label.contains("没什么可压"))
}

///|
test "decide_compaction：手动不看 enabled，阈值看占用，溢出看错误文案" {
  let state = compact_ready()
  // 关掉自动：手动仍然该压。
  let disabled = {
    ..state,
    compact_settings: {
      enabled: false,
      reserve_tokens: 200,
      keep_recent_tokens: 1,
    },
  }
  let manual = decide_compaction(disabled, true)
  assert_true(manual.should)
  assert_eq(manual.reason, Some(@compact.Manual))
  assert_false(decide_compaction(disabled, false).should)
  // 阈值：窗口 1000，reserve 夹到 200 → 占用超过 800 就该压。
  let assistant : @message.Message = @message.AssistantMsg({
    content: [@message.Text("答")],
    stop_reason: "stop",
    error_message: None,
    usage: Some({
      input_tokens: 600,
      output_tokens: 300,
      total_tokens: 900,
      cost_total: 0.0,
    }),
    timestamp: 0L,
  })
  let filled = {
    ..state,
    messages: [@message.user_message("问", 0L), assistant],
  }
  let threshold = decide_compaction(filled, false)
  assert_true(threshold.should)
  assert_eq(threshold.reason, Some(@compact.Threshold))
  assert_eq(threshold.context_tokens, Some(900))
  // 溢出：provider 的报错文案就够判了（不必等 usage 露馅）。
  let overflowed = {
    ..state,
    error: Some("This model's maximum context length is 4096 tokens"),
  }
  let overflow = decide_compaction(overflowed, false)
  assert_true(overflow.should)
  assert_eq(overflow.reason, Some(@compact.Overflow))
}
