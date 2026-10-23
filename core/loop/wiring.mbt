// 接线表：action → 该发哪些 Cmd（纯数据，没有 if 之外的判断）。
//
// 它与迁移表分开，因为两者回答不同问题：迁移回答「状态变成什么」，
// 接线回答「接下来让谁动」。区分它们之后，`llm.failed` 的重试可以只写一处：
// 迁移算出 `retrying`，接线只需要看这个事实。
//
// **接线读的是迁移之后的状态**（`reduce` 的约定）—— 传旧状态的话，
// 接线永远看不到本次 action 造成的新事实。

///|
/// 从队列里取出一条待投递的输入，组装成 `QueueDelivered`。
///
/// 只在 reducer 说「该投递了」之后才调它 —— 它自己不判时机。
fn deliver_queued(state : @state.AgentState, kind : @common.QueueKind) -> Cmd? {
  let queue = match kind {
    @common.Steer => state.steer_queue
    @common.FollowUp => state.follow_up_queue
  }
  if queue.is_empty() {
    None
  } else {
    let head = queue[0]
    Some(
      redispatch(
        QueueDelivered({ text: head.text, content: head.content, kind, }),
      ),
    )
  }
}

///|
pub fn wiring(
  action : @action.AgentAction,
  state : @state.AgentState,
) -> Array[Cmd] {
  match action {
    // 新的一句用户消息 → 开回合容器 → 开第一步。
    //
    // 顺序要紧：TurnStart 的迁移要先填上 open_turn_node_id，
    // StepStart 才能挂到它下面（而不是挂到 user 节点上）。
    //
    // 这里**只**发 turn.start：turn.start 的接线会发 start_step()。
    // 若两条都发，LLM 会被调两遍，第二遍的结果直接覆盖第一遍 ——
    // 而轨迹树上就是两个 llm.result 兄弟，症状是「模型白答了一遍」。
    @action.UserMessage(_) => [redispatch(TurnStart)]
    @action.TurnStart => [start_step_cmd()]
    @action.TurnEnd =>
      // 关回合之后还有可能继续：followUp 的定义就是「模型说完了接着聊」。
      // 新回合容器与那条 followUp 消息**已经由迁移开好、插好了**，
      // 所以这里只剩「让它跑起来」。
      //
      // 判据必须看 open_turn_node_id，不能看队列 —— 迁移已经把那条 followUp
      // 从队列里取走了，再看队列会在「只有一条」时恒为 None。
      if state.open_turn_node_id is Some(_) {
        [start_step_cmd()]
      } else {
        []
      }
    @action.TurnContinue =>
      // 判据必须同时看三样，与迁移的守卫一一对应。
      // 只看相位会把「跑着时又敲了一次 /continue」当成接受。
      if state.phase == @common.Thinking && state.open_turn_node_id is None {
        [redispatch(TurnStart)]
      } else {
        []
      }
    // step.start 只开容器；调 LLM 的 Cmd 在 start_step_cmd() 里与它一起发出。
    @action.StepStart => []
    // step.end 只改状态（关容器、total_steps+1）。
    @action.StepEnd(_) => []
    @action.AgentRun(text) => [RunAgent(text)]
    // 队列里的消息进来。
    //
    // 迁移已经处理了「空闲 → 直接转成 user.message」那种情况 ——
    // 那种情况下它把相位拉到了 thinking 且回合容器尚未开，所以这里要补一个
    // turn.start（它自己会带起 start_step）。
    //
    // 判据是**回合容器开没开**而不是相位：空闲转 user.message 与真入队
    // 两种情况下相位都是 thinking，只有容器开没开能区分。
    @action.QueueInput(_) =>
      if state.open_turn_node_id is None && state.phase != @common.Idle {
        [redispatch(TurnStart)]
      } else {
        []
      }
    @action.QueueDelivered(input) =>
      // 投递完成后干什么，**取决于它是哪一列**：
      //
      // - steer：投递完**紧接着开下一步**（此刻模型还没看到新的话，必须马上跑一次）；
      // - followUp：投递完**接着开一个新回合**（旧回合收尾 + 新容器 + 那条消息
      //   一起在迁移里做）。若不开新回合，那条消息就成了「说完了又冒出来一句话，
      //   却没人回」。
      if input.kind == @common.Steer {
        [start_step_cmd()]
      } else if state.delivering_input is Some(_) {
        // 被防重入挡住，什么都没发生。
        []
      } else if state.open_turn_node_id is None {
        []
      } else {
        [start_step_cmd()]
      }
    // 流开始前先发一条 action：UI 靠它把「正在生成」点亮，而不是等第一个 delta。
    @action.LlmStarted => []
    @action.LlmDone(data) => {
      // 注意：接线拿到的是**迁移后**的状态，而 llm.done 的迁移已经把相位推到了
      // calling-tools。所以这里不能用 `phase == thinking` 判定（那会永远为假，
      // 工具就永远不跑）。该跑的判据是「这次确实带工具调用」。
      let calls = data.message.tool_calls()
      if calls.is_empty() {
        [close_turn_cmd()]
      } else {
        // 直接发 runTools（不是 redispatch）：工具 attempt 节点由 ToolStart 的迁移开，
        // 而 ToolStart 本来就是 runTools 内部 dispatch 的第一条 action。
        [RunTools(calls)]
      }
    }
    @action.LlmFailed(_) =>
      // reducer 已经判好了：retrying 为真就说明「可重试且还有次数」，
      // 并且它把相位留在了 thinking。重试的 step 容器**已经开着**，
      // 所以这里只补一条 agent.run 让环转起来。
      if state.retrying {
        [redispatch(AgentRun(None))]
      } else {
        [close_turn_cmd()]
      }
    @action.LlmGiveup(_) => [close_turn_cmd()]
    @action.ToolCall(calls) => [RunTools(calls)]
    @action.ToolBatchDone(_) => {
      // 撞轮数上限：迁移里已把相位推到 idle 并留了 stop 节点。收工，关回合。
      if state.phase == @common.Idle {
        return [close_turn_cmd()]
      }
      // 1. steer 队列里有东西 → 投递它并立即开下一步（对齐 pi：当前 step 的
      //    工具跑完后、下一次 LLM 调用前）。顺序要紧：steer 优先于「开下一步」，
      //    否则模型会在没看到新话的情况下先跑一次 LLM。
      match deliver_queued(state, @common.Steer) {
        Some(cmd) => [cmd]
        None => [start_step_cmd()]
      }
    }
    _ => []
  }
}

///|
/// 一次完整的 reducer 步：迁移 → 接线。
///
/// 返回的是**命令数组**而不是单个 Cmd：运行时统一摊平（见 `flatten_cmds`），
/// 所以这里不存在「包一层变成嵌套 LIST 后被吞掉」的陷阱。
pub fn reduce(
  state : @state.AgentState,
  action : @action.AgentAction,
  now : Int64,
) -> (@state.AgentState, Array[Cmd]) {
  let next = transition(state, action, now)
  let cmds = wiring(action, next)
  (next, cmds)
}
