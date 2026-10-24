// 演示：不接真实 provider，用假的 effect 表把环跑通。
//
// 输出是两段轨迹树 —— 它比任何日志都更能说明「环长什么样」：
//   - 场景 1：一条消息 → 调模型 → 工具 → 再调模型 → 收工；
//   - 场景 2：第一次调用超时，重试在**同一个 step 容器**里进行。
//
// 真正要看的不是终端刷了什么，而是：reducer 里没有 while、没有 await，
// 所有步骤都是 action 进、Cmd 出。

///|
fn demo_clock() -> () -> Int64 {
  let tick = Ref(1000L)
  fn() {
    let now = tick.val
    tick.val = now + 250L
    now
  }
}

///|
fn initial(session_id : String, max_turns : Int32?) -> @state.AgentState {
  @state.create_initial_state({
    system_prompt: "你是一个只会读文件的演示助手。",
    provider_name: "demo",
    model_id: "demo-echo",
    thinking_level: "off",
    tool_names: ["read"],
    max_turns,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id,
    cwd: ".",
    trace: None,
  })
}

///|
async fn seed(agent : @runtime.Agent) -> Unit {
  agent.send(
    @action.PromptInit({
      system_prompt: "你是一个只会读文件的演示助手。",
      tools: [
        {
          name: "read",
          description: "读一个文件",
          parameters: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
      ],
    }),
  )
  agent.send(
    @action.ModelInit({
      provider: "demo",
      model_id: "demo-echo",
      thinking_level: "off",
      reasoning: false,
      capabilities: @action.no_capabilities,
      context_window: 128000,
    }),
  )
}

///|
fn read_call() -> @message.ToolCall {
  { id: "call_1", name: "read", arguments: "{\"path\":\"README.md\"}", }
}

///|
/// 假 provider：第一次说「我先读一下」并请求工具，第二次给最终回答。
fn demo_table() -> @runtime.EffectTable {
  let calls = Ref(0)
  {
    run_agent: async fn(_state, dispatch) {
      dispatch.send(@action.LlmStarted)
      if calls.val == 0 {
        calls.val = 1
        dispatch.send(@action.LlmDelta("我先读一下 README。"))
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [
                @message.Text("我先读一下 README。"),
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
        dispatch.send(@action.LlmDelta("读完了。回答："))
        dispatch.send(
          @action.LlmDone({
            message: {
              content: [
                @message.Text(
                  "读完了。工具返回的是「# pi-moon 演示」。",
                ),
              ],
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
      for call in calls {
        dispatch.send(@action.ToolStart(call))
        dispatch.send(
          @action.ToolProgress({
            tool_call_id: call.id,
            content: [@message.Text("reading README.md ...")],
          }),
        )
        dispatch.send(
          @action.ToolResult({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [@message.Text("# pi-moon 演示\n第二行")],
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
/// 第一次调用超时，第二次成功：同一个 step 容器内重试。
fn flaky_table() -> @runtime.EffectTable {
  let attempts = Ref(0)
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
              content: [@message.Text("重试之后成功了。")],
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
fn print_report(title : String, agent : @runtime.Agent) -> Unit {
  let state = agent.state
  let stats = @trace.trace_stats(state.trace)
  println("")
  println("══ " + title + " ══")
  println("")
  println(@trace.render_tree(state.trace, max_width=0))
  println("")
  println(
    "统计: 回合=" +
    stats.turns.to_string() +
    " 步=" +
    stats.steps.to_string() +
    " 工具=" +
    stats.tool_calls.to_string() +
    " 错误=" +
    stats.errors.to_string() +
    " 重试=" +
    stats.retries.to_string(),
  )
  let stop_text = match state.stop_cause {
    Some(cause) => cause.name()
    None => "-"
  }
  println(
    "状态: phase=" +
    state.phase.name() +
    " stop=" +
    stop_text +
    " 消息=" +
    state.messages.length().to_string() +
    " 处理 action=" +
    agent.processed.to_string(),
  )
  println("")
  println("消息流:")
  for message in state.messages {
    println("  [" + message.role() + "] " + message.text())
  }
}

///|
async fn main {
  run_demo() catch {
    err => println("error: " + err.to_string())
  }
}

///|
async fn run_demo() -> Unit {
  // 场景 1：正常的 ReAct 环。
  let agent = @runtime.Agent::new(
    initial("demo-normal", None),
    demo_table(),
    demo_clock(),
  )
  seed(agent)
  agent.send(
    @action.UserMessage({ text: "README 里写了什么？", content: [], }),
  )
  print_report(
    "场景 1：消息 → 模型 → 工具 → 模型 → 收工", agent,
  )

  // 场景 2：超时重试。
  let flaky = @runtime.Agent::new(
    initial("demo-retry", None),
    flaky_table(),
    demo_clock(),
  )
  seed(flaky)
  flaky.send(
    @action.UserMessage({ text: "先失败一次再成功", content: [], }),
  )
  print_report("场景 2：超时重试，同一个 step 容器里", flaky)
}
