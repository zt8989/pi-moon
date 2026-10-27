// 整环测试：接上假的 effect 表，从一条用户消息跑到 idle。
//
// 这里看的是「环自己转起来」这件事 —— reducer 没有 while，effect 也不调用
// 下一个 effect；它们只发 action，环由运行时接起来。

///|
fn runtime_test_state() -> @state.AgentState {
  @state.create_initial_state({
    system_prompt: "你是助手",
    provider_name: "fake",
    model_id: "fake-1",
    thinking_level: "off",
    tool_names: ["read"],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s-rt",
    cwd: "/tmp",
    trace: None,
  })
}

///|
fn runtime_test_clock() -> () -> Int64 {
  let tick = Ref(1000L)
  fn() {
    let now = tick.val
    tick.val = now + 100L
    now
  }
}

///|
fn read_call() -> @message.ToolCall {
  { id: "call_1", name: "read", arguments: "{\"path\":\"a.txt\"}", }
}

///|
/// 假模型：第一次调用发工具调用，看到工具结果后给最终回答。
/// 假工具：直接返回一段文本。
fn tool_agent_table() -> EffectTable {
  {
    run_agent: async fn(state, dispatch) {
      dispatch.send(@action.LlmStarted)
      let last_role = match state.messages.last() {
        Some(message) => message.role()
        None => ""
      }
      if last_role == "toolResult" {
        dispatch.send(@action.LlmDelta("文件里有两行。"))
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("文件里有两行。")],
              stop_reason: "stop",
              error_message: None,
              usage: None,
              timestamp: 0L,
            },
            node_id: None,
          }),
        )
      } else {
        dispatch.send(@action.LlmDelta("我先读一下。"))
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [
                @message.Text("我先读一下。"),
                @message.ToolCallBlock(read_call()),
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
    run_tools: async fn(_state, calls, dispatch) {
      for call in calls {
        dispatch.send(@action.ToolStart(call))
        dispatch.send(
          @action.ToolProgress({
            tool_call_id: call.id,
            content: [@message.Text("reading...")],
          }),
        )
        dispatch.send(
          @action.ToolResult({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [@message.Text("line1\nline2")],
            is_error: false,
            timestamp: 0L,
          }),
        )
      }
      dispatch.send(@action.ToolBatchDone(calls.length()))
    },
    run_compact: async fn(_, _) { () },
  }
}

///|
async fn seed_agent(table : EffectTable) -> Agent {
  let agent = Agent::new(runtime_test_state(), table, runtime_test_clock())
  agent.send(
    @action.PromptInit({
      system_prompt: "你是助手",
      tools: [{ name: "read", description: "读文件", parameters: "{}", }],
    }),
  )
  agent.send(
    @action.ModelInit({
      provider: "fake",
      model_id: "fake-1",
      thinking_level: "off",
      reasoning: false,
      capabilities: @action.no_capabilities,
      context_window: 1000,
    }),
  )
  agent
}

///|
async test "一条用户消息 → 工具 → 最终回答 → idle，全环闭合" {
  let agent = seed_agent(tool_agent_table())
  agent.send(@action.UserMessage({ text: "看看 a.txt", content: [], }))
  let state = agent.state
  assert_eq(state.phase, @common.Idle)
  assert_eq(state.stop_reason, Some(@common.Completed))
  assert_true(state.open_turn_node_id is None)
  assert_true(state.open_step_node_id is None)
  // user / assistant(工具调用) / toolResult / assistant(最终) 四条消息。
  assert_eq(state.messages.length(), 4)
  assert_eq(state.messages[0].role(), "user")
  assert_eq(state.messages[1].role(), "assistant")
  assert_eq(state.messages[2].role(), "toolResult")
  assert_eq(state.messages[3].text(), "文件里有两行。")
  // 两步：工具调用那一步 + 最终回答那一步。
  let stats = @trace.trace_stats(state.trace)
  assert_eq(stats.turns, 1)
  assert_eq(stats.steps, 2)
  assert_eq(stats.tool_calls, 1)
  assert_eq(stats.errors, 0)
  // 环真的转了两圈 LLM（turns 是当前回合内的调用数）。
  assert_eq(state.turns, 2)
  // 工具中间输出在结束时清掉，终值在 messages 里。
  assert_eq(state.tool_progress.length(), 0)
  assert_true(state.tool_timings.length() == 1)
  // 渲染出来的树里有回合闭合点。
  let rendered = @trace.render_tree(state.trace, max_width=0)
  assert_true(rendered.contains("turn.start: 回合 1"))
  assert_true(rendered.contains("turn.end: 回合 1 结束：模型说完了"))
  assert_true(rendered.contains("tool.result: line1"))
}

///|
/// 第一次调用超时、第二次成功：同一个 step 容器里重试。
fn retry_table(attempts : Ref[Int32]) -> EffectTable {
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      if attempts.val == 0 {
        attempts.val = 1
        dispatch.send(
          @action.LlmFailed({
            error: "request timeout",
            kind: @common.Timeout,
            node_id: None,
            cause: None,
          }),
        )
      } else {
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("好了")],
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
    run_tools: async fn(_state, _calls, _dispatch) { () },
    run_compact: async fn(_, _) { () },
  }
}

///|
async test "超时重试在同一个 step 容器里，树上不留兄弟 step" {
  let attempts = Ref(0)
  let agent = seed_agent(retry_table(attempts))
  agent.send(@action.UserMessage({ text: "查", content: [], }))
  let state = agent.state
  assert_eq(state.phase, @common.Idle)
  assert_eq(state.stop_reason, Some(@common.Completed))
  let stats = @trace.trace_stats(state.trace)
  assert_eq(stats.steps, 1)
  assert_eq(stats.errors, 1)
  assert_eq(stats.retries, 1)
}

///|
/// 假模型：回合里中途被 steer 打断一次，之后的回答里看得到那句话。
fn steer_table() -> EffectTable {
  let calls = Ref(0)
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      if calls.val == 0 {
        calls.val = 1
        // 第一次：带工具，steer 会在工具批次结束时插进来。
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [
                @message.Text("我读一下。"),
                @message.ToolCallBlock(read_call()),
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
        // 第二次：应当已经看得到那条插话。
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("收到插话。")],
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
    run_tools: async fn(_state, calls, dispatch) {
      // 用户趁工具在跑时插一句。
      dispatch.send(
        @action.QueueInput({
          text: "换个方向",
          content: [],
          kind: @common.Steer,
        }),
      )
      for call in calls {
        dispatch.send(@action.ToolStart(call))
        dispatch.send(
          @action.ToolResult({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [@message.Text("ok")],
            is_error: false,
            timestamp: 0L,
          }),
        )
      }
      dispatch.send(@action.ToolBatchDone(calls.length()))
    },
    run_compact: async fn(_, _) { () },
  }
}

///|
async test "steer：工具跑完、下一次 LLM 调用前插入，不新开回合" {
  let agent = seed_agent(steer_table())
  agent.send(@action.UserMessage({ text: "看看文件", content: [], }))
  let state = agent.state
  assert_eq(state.phase, @common.Idle)
  // 回合只有一个：steer 属于当前回合。
  let stats = @trace.trace_stats(state.trace)
  assert_eq(stats.turns, 1)
  let steer_texts : Array[String] = []
  for id in state.trace.order {
    match state.trace.nodes.get(id) {
      Some(node) =>
        if node.kind == @trace.User &&
          @trace.meta_get(node, "queued") == Some("steer") {
          steer_texts.push(node.label)
        }
      None => ()
    }
  }
  assert_eq(steer_texts.length(), 1)
  assert_true(steer_texts[0].contains("steer: 换个方向"))
  // 插进来的那句话进了消息流，模型看得到。
  let texts : Array[String] = []
  for message in state.messages {
    texts.push(message.text())
  }
  assert_true(texts.contains("换个方向"))
}

///|
/// 假模型：一轮里没有工具；在生成过程中排一条 followUp。
fn follow_up_table() -> EffectTable {
  let first = Ref(true)
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      if first.val {
        first.val = false
        dispatch.send(
          @action.QueueInput({
            text: "接着问一句",
            content: [],
            kind: @common.FollowUp,
          }),
        )
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [@message.Text("第一轮答完。")],
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
              content: [@message.Text("第二轮答完。")],
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
    run_tools: async fn(_state, _calls, _dispatch) { () },
    run_compact: async fn(_, _) { () },
  }
}

///|
async test "followUp：回合收工后开新回合，而不是躺在队列里" {
  let agent = seed_agent(follow_up_table())
  agent.send(@action.UserMessage({ text: "开始", content: [], }))
  let state = agent.state
  assert_eq(state.phase, @common.Idle)
  let stats = @trace.trace_stats(state.trace)
  // 两个回合、两步（每回合一次 LLM）。
  assert_eq(stats.turns, 2)
  assert_eq(stats.steps, 2)
  assert_eq(state.turn_index, 2)
  assert_eq(state.follow_up_queue.length(), 0)
  let texts : Array[String] = []
  for message in state.messages {
    texts.push(message.text())
  }
  assert_true(texts.contains("接着问一句"))
  assert_true(texts.contains("第二轮答完。"))
}

///|
async test "轮数上限：撞上限收工，树上留 stop 节点" {
  let table : EffectTable = {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      dispatch.send(
        @action.LlmDone({
          message: {
            content: [
              @message.Text("再读一次"),
              @message.ToolCallBlock(read_call()),
            ],
            stop_reason: "toolUse",
            error_message: None,
            usage: None,
            timestamp: 0L,
          },
          node_id: None,
        }),
      )
    },
    run_tools: async fn(_state, calls, dispatch) {
      for call in calls {
        dispatch.send(@action.ToolStart(call))
        dispatch.send(
          @action.ToolResult({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [@message.Text("ok")],
            is_error: false,
            timestamp: 0L,
          }),
        )
      }
      dispatch.send(@action.ToolBatchDone(calls.length()))
    },
    run_compact: async fn(_, _) { () },
  }
  let state = @state.create_initial_state({
    system_prompt: "",
    provider_name: "fake",
    model_id: "fake-1",
    thinking_level: "off",
    tool_names: ["read"],
    max_turns: Some(2),
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s-cap",
    cwd: "/tmp",
    trace: None,
  })
  let agent = Agent::new(state, table, runtime_test_clock())
  agent.send(@action.UserMessage({ text: "读到死", content: [], }))
  let state = agent.state
  assert_eq(state.phase, @common.Idle)
  assert_eq(state.stop_reason, Some(@common.MaxTurns))
  assert_eq(state.stop_cause, Some(@common.CauseMaxTurns))
  let stops = @trace.children_of(state.trace, state.open_turn_node_id).filter(node => {
    node.kind == @trace.StopNode
  })
  // 回合已经关掉了，所以按整棵树找 stop 节点。
  let mut stop_count = 0
  for id in state.trace.order {
    match state.trace.nodes.get(id) {
      Some(node) =>
        if node.kind == @trace.StopNode {
          stop_count = stop_count + 1
        }
      None => ()
    }
  }
  assert_eq(stop_count, 1)
  assert_eq(stops.length(), 0)
}

///|
async test "compact：RunCompact 真的被 await，done 回来了整份换历史" {
  let base = runtime_test_state()
  let state = {
    ..base,
    messages: [
      @message.user_message("第一问", 1L),
      @message.assistant_message("第一答", "stop", 2L),
      @message.user_message("第二问", 3L),
      @message.assistant_message("第二答", "stop", 4L),
    ],
  }
  let table : EffectTable = {
    run_agent: async fn(_, _) { () },
    run_tools: async fn(_, _, _) { () },
    run_compact: async fn(state, dispatch) {
      dispatch.send(
        @action.CompactDone({
          messages: [@compact.build_summary_message("摘要", 100, 90L)],
          summary: "摘要",
          tokens_before: 100,
          summarized_count: state.messages.length() - 1,
          kept_count: 1,
          usage: None,
        }),
      )
    },
  }
  let agent = Agent::new(state, table, runtime_test_clock())
  // 默认 keepRecent 大于整段历史 → 没东西可压，effect 不会被调用。
  agent.send(
    @action.CompactSettingsChanged({
      enabled: true,
      reserve_tokens: 100,
      keep_recent_tokens: 1,
    }),
  )
  agent.send(@action.CompactRequest(@compact.Manual))
  let next = agent.state
  assert_false(next.compacting)
  assert_eq(next.phase, @common.Idle)
  assert_eq(next.messages.length(), 1)
  assert_true(@compact.is_summary_message(next.messages[0]))
  assert_eq(next.compaction_epoch, 1)
  assert_eq(next.last_compaction.unwrap().reason, @compact.Manual)
}

///|
async test "dispatch_ui 同步归约 UI 事件：不排队、不耗预算、observer 照常触发" {
  let agent = seed_agent(noop_effect_table())
  let seen : Array[String] = []
  agent.observe(fn(action : @action.AgentAction) { seen.push(action.name()) })
  let budget_before = agent.budget
  agent.dispatch_ui(@action.Ui(@action.PageToggled))
  agent.dispatch_ui(@action.Ui(@action.Scrolled(@action.UiTrace, 7)))
  assert_eq(agent.state.ui.page, @action.UiTrace)
  assert_eq(agent.state.ui.trace_scroll, 7)
  // 外部队列没有被 UI 事件占过：后续 send 的 action 还在队头等着。
  assert_false(agent.pending())
  assert_eq(seen, ["ui.page", "ui.scroll"])
  // 防死循环预算是环自己的保险丝，用户按键不该消耗它。
  assert_eq(agent.budget, budget_before)
  // 生成中（deferred 里有 effect 等着）也能改界面：dispatch_ui 不碰 deferred。
  agent.enqueue(@action.UserMessage({ text: "跑一轮", content: [], }))
  agent.dispatch_ui(@action.Ui(@action.ExpandToggled))
  assert_true(agent.state.ui.expanded)
}
