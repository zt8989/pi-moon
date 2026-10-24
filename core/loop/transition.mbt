// 状态迁移表：action → 下一个状态（纯函数，不产生 Cmd）。
//
// 每个 action 一个 handler，写在同一个 `match` 里 —— 与接线表分开，
// 但两者由 `reduce()` 串起来：**接线读的是迁移之后的状态**。
// 原因：像 LlmFailed 判出的 `retrying` 正是它的迁移刚算出来的；传旧状态的话，
// 接线永远看不到本次 action 造成的新事实，重试就发不出去。

///|
fn[T] drop_first(items : Array[T]) -> Array[T] {
  let out : Array[T] = []
  for index in 1..<items.length() {
    out.push(items[index])
  }
  out
}

///|
fn queue_head(items : Array[@state.QueuedInput]) -> @state.QueuedInput? {
  if items.is_empty() {
    None
  } else {
    Some(items[0])
  }
}

///|
fn max_turns_reached(state : @state.AgentState) -> Bool {
  match state.max_turns {
    Some(limit) => state.turns >= limit
    None => false
  }
}

///|
/// 用户真正说出了一句话：补装载节点、补模型变更、开 user 节点、归零计数器。
///
/// 被 `UserMessage` 与 `QueueInput`（空闲时）共用 —— 写两遍必然漂移，
/// 而漂移的后果是「第二个回合的计数从 1 开始」。
fn transition_user_message(
  state : @state.AgentState,
  input : @action.UserInput,
  now : Int64,
) -> @state.AgentState {
  if state.phase != @common.Idle {
    return state
  }
  // 压缩中不接受新话：压缩会整份换掉 messages，那句新话要是先进去了，
  // 摘要回来时会连同它一起被换掉。
  if state.compacting {
    return state
  }
  let content = if input.content.is_empty() {
    [@message.Text(input.text)]
  } else {
    input.content
  }
  let message : @message.Message = @message.UserMsg({
    content,
    timestamp: now,
    compaction_summary: false,
    tokens_before: 0,
  })
  // 顺序就是它们在树上的顺序：装载节点 → 换过模型那一笔 → user 节点。
  let begun = begin_trace(state, now)
  let with_model = flush_model_change({ ..state, trace: begun, }, now)
  let (tree, _node) = @trace.append_node(
    with_model.trace,
    with_model.trace.tip_id,
    @trace.User,
    @trace.Ok,
    @common.summarize(input.text),
    now,
    detail=input.text,
    message~,
    ended_at=now,
  )
  let counters = new_turn_counters()
  {
    ..with_model,
    trace: tree,
    trace_begun: true,
    phase: @common.Thinking,
    error: None,
    error_node_id: None,
    error_kind: None,
    stop_reason: None,
    stop_cause: None,
    stop_cause_detail: None,
    aborted: false,
    turns: counters.turns,
    llm_attempts: counters.llm_attempts,
    retrying: counters.retrying,
    step_index: counters.step_index,
    turn_steps: counters.turn_steps,
    streaming_text: "",
    thinking_text: "",
    pending_tool_calls: [],
    executing: [],
    messages: state.messages.add([message]),
    open_llm_node_id: None,
    open_step_node_id: None,
    // **不填 open_turn_node_id**：回合容器由 TurnStart 开（它才是「回合开始」
    // 这件事）。这里抢先填上会让 TurnStart 的防重入守卫直接返回，
    // 于是树上永远没有 turn 节点。
    open_turn_node_id: None,
  }
}

///|
pub fn transition(
  state : @state.AgentState,
  action : @action.AgentAction,
  now : Int64,
) -> @state.AgentState {
  match action {
    // ── 装载 ──
    @action.PromptInit(data) => {
      let prompt : @state.PromptState = {
        system_prompt: data.system_prompt,
        tools: data.tools,
        // 装载时那一批**单独留一份**：prompt head 的 toolsAdded 用它，
        // 之后工具集再变也不动。
        head_tools: Some(data.tools),
        declared_tools: data.tools,
        seeded: true,
      }
      let tool_names : Array[String] = []
      for tool in data.tools {
        tool_names.push(tool.name)
      }
      {
        ..state,
        // **已经开过树**的话（热重载），立刻追加新节点 —— 旧节点不改写。
        // 开局那次不走这里：树还没开，由第一条 user.message 统一补。
        trace: if state.trace_begun {
          append_prompt_nodes(state.trace, prompt, now)
        } else {
          state.trace
        },
        prompt,
        system_prompt: prompt.system_prompt,
        tool_names,
      }
    }
    @action.ModelInit(spec) => apply_model_spec(state, spec)
    @action.ModelChanged(spec) => {
      let next = apply_model_spec(state, spec)
      {
        ..next,
        // 树开着才置标记；关着的话 begin_trace 会从 state 读出那一刻生效的那一版。
        model_trace_dirty: if state.trace_begun {
          true
        } else {
          state.model_trace_dirty
        },
      }
    }
    @action.ThinkingChanged(level) => {
      let model : @state.ModelState = { ..state.model, thinking_level: level, }
      {
        ..state,
        model,
        thinking_level: level,
        model_trace_dirty: if state.trace_begun {
          true
        } else {
          state.model_trace_dirty
        },
      }
    }
    // ── 用户输入 ──
    @action.UserMessage(input) => transition_user_message(state, input, now)
    @action.QueueInput(input) =>
      // 空闲时收到队列消息 = 用户在等一个回合，直接变成正常输入：
      // 那不是「打断」，是「接着说」。相位 idle 时既不会有 tool.batch.done
      // 也不会有 llm.done 来触发投递。
      if state.phase == @common.Idle {
        transition_user_message(
          state,
          { text: input.text, content: input.content, },
          now,
        )
      } else {
        let item : @state.QueuedInput = {
          text: input.text,
          content: input.content,
          at: now,
        }
        match input.kind {
          @common.Steer =>
            { ..state, steer_queue: state.steer_queue.add([item]), }
          @common.FollowUp =>
            { ..state, follow_up_queue: state.follow_up_queue.add([item]), }
        }
      }
    @action.QueueDelivered(input) => {
      // 防重入：一条已经在途时不接新的一条。
      // 否则连按两次「取队列」会把同一条消息发两遍。
      if state.delivering_input is Some(_) {
        return state
      }
      let is_steer = input.kind == @common.Steer
      let content = if input.content.is_empty() {
        [@message.Text(input.text)]
      } else {
        input.content
      }
      let message : @message.Message = @message.UserMsg({
        content,
        timestamp: now,
        compaction_summary: false,
        tokens_before: 0,
      })
      let with_model = flush_model_change(state, now)
      // steer 的 user 节点挂在**当前回合容器**下面（它是这回合里的一个额外输入）；
      // followUp 的则是**新回合的起点**，所以要挂在 tip 下面。
      let parent_id = if is_steer {
        match state.open_turn_node_id {
          Some(id) => Some(id)
          None => with_model.trace.tip_id
        }
      } else {
        with_model.trace.tip_id
      }
      let queued_label = if is_steer { "steer: " } else { "followUp: " }
      let (tree, _node) = @trace.append_node(
        with_model.trace,
        parent_id,
        @trace.User,
        @trace.Ok,
        queued_label + @common.summarize(input.text),
        now,
        detail=input.text,
        message~,
        meta=[("queued", input.kind.name())],
        ended_at=now,
      )
      let base : @state.AgentState = {
        ..with_model,
        trace: tree,
        messages: state.messages.add([message]),
        delivering_input: None,
        delivering_as: None,
        steer_queue: if is_steer {
          drop_first(state.steer_queue)
        } else {
          state.steer_queue
        },
        follow_up_queue: if is_steer {
          state.follow_up_queue
        } else {
          drop_first(state.follow_up_queue)
        },
      }
      if is_steer {
        // steer 不碰回合容器：它属于**当前**回合。但相位要离开 idle ——
        // 「接着往下走」这件事本身说明还有活要干。
        { ..base, phase: @common.Thinking, }
      } else {
        // **followUp 开新回合 —— 所以必须先把旧容器收尾。**
        // 不先关旧容器的话，新容器一开就会撞上 StepStart 的防重入守卫，
        // 而且树上会看到一个永远不闭合的回合。
        let closed = close_turn_node(
          base,
          now,
          @common.TurnCompleted,
          @common.turn_reason_text(@common.TurnCompleted),
        )
        let (opened_tree, opened_node) = @trace.append_node(
          closed.trace,
          closed.trace.tip_id,
          @trace.TurnStart,
          @trace.Pending,
          "回合 " + (closed.turn_index + 1).to_string(),
          now,
        )
        let counters = new_turn_counters()
        {
          ..closed,
          trace: opened_tree,
          open_turn_node_id: Some(opened_node.id),
          open_turn_seq: Some(closed.turn_index + 1),
          turn_index: closed.turn_index + 1,
          turns: counters.turns,
          llm_attempts: counters.llm_attempts,
          retrying: counters.retrying,
          step_index: counters.step_index,
          turn_steps: counters.turn_steps,
        }
      }
    }
    @action.QueueClear =>
      if state.steer_queue.is_empty() && state.follow_up_queue.is_empty() {
        state
      } else {
        { ..state, steer_queue: [], follow_up_queue: [], }
      }
    // ── 回合 / 步 ──
    @action.TurnStart => {
      // 回合已经在跑就别再开一个。
      if state.open_turn_node_id is Some(_) {
        return state
      }
      let turn_index = state.turn_index + 1
      // 「换过模型 / 档位」那一笔要在容器**之前**落下 ——
      // 树上的 model.init 说的是「这一轮用的是这个」，所以必须在 turn.start 上面。
      let with_model = flush_model_change(state, now)
      let (tree, node) = @trace.append_node(
        with_model.trace,
        with_model.trace.tip_id,
        @trace.TurnStart,
        @trace.Pending,
        "回合 " + turn_index.to_string(),
        now,
      )
      {
        ..with_model,
        trace: tree,
        open_turn_node_id: Some(node.id),
        turn_index,
        // 新回合从头数 step（而 turn_index 是会话级的，不归零）。
        step_index: 0,
        turn_steps: 0,
      }
    }
    @action.TurnEnd => {
      if state.open_turn_node_id is None {
        return state
      }
      // 结局由 state 推：stop_reason 说出「哪一类停下」，stop_cause 说得更准。
      let reason = match state.stop_cause {
        Some(@common.CauseMaxTurns) => @common.TurnMaxTurns
        Some(@common.CauseCompleted) => @common.TurnCompleted
        _ =>
          match state.stop_reason {
            Some(@common.Completed) => @common.TurnCompleted
            Some(@common.StopReason::Aborted) => @common.TurnAborted
            _ =>
              if state.aborted {
                @common.TurnAborted
              } else {
                @common.TurnError
              }
          }
      }
      let closed = close_turn_node(
        state,
        now,
        reason,
        @common.turn_reason_text(reason),
      )
      // **关回合后 followUp 直接开新回合 —— 在这条迁移里做，不是接线里。**
      // 这条路是被 llm.done / llm.failed / tool.batch.done 触发的，
      // 从那几个 effect 回来的时刻，从这里 redispatch 出去的 action 没人冲刷。
      // followUp 优先；**没有 followUp 时也要投递 steer**：steer 的正常时机是
      // `tool.batch.done`，但模型可能直接说完（没有工具批次），那条话就永远卡在
      // 队列里。对用户来说它是「生成中说的下一句」，与 followUp 同一个落点。
      let kind = match queue_head(state.follow_up_queue) {
        Some(_) => @common.FollowUp
        None => @common.Steer
      }
      let next = match queue_head(state.follow_up_queue) {
        Some(queued) => Some(queued)
        None => queue_head(state.steer_queue)
      }
      match next {
        None => { ..closed, step_index: 0, turn_steps: state.turn_steps, }
        Some(queued) => {
          let flushed = flush_model_change(closed, now)
          let content = if queued.content.is_empty() {
            [@message.Text(queued.text)]
          } else {
            queued.content
          }
          let message : @message.Message = @message.UserMsg({
            content,
            timestamp: now,
            compaction_summary: false,
            tokens_before: 0,
          })
          let label = if kind == @common.Steer {
            "steer: "
          } else {
            "followUp: "
          }
          // 先把那句话作为 user 消息插进去（它开启新回合），再开回合容器 ——
          // 于是 user 节点在树上排在 turn.start 之前。
          let (user_tree, _user_node) = @trace.append_node(
            flushed.trace,
            flushed.trace.tip_id,
            @trace.User,
            @trace.Ok,
            label + @common.summarize(queued.text),
            now,
            detail=queued.text,
            message~,
            meta=[("queued", kind.name())],
            ended_at=now,
          )
          let (opened_tree, opened_node) = @trace.append_node(
            user_tree,
            user_tree.tip_id,
            @trace.TurnStart,
            @trace.Pending,
            "回合 " + (closed.turn_index + 1).to_string(),
            now,
          )
          let counters = new_turn_counters()
          {
            ..flushed,
            trace: opened_tree,
            open_turn_node_id: Some(opened_node.id),
            open_turn_seq: Some(closed.turn_index + 1),
            turn_index: closed.turn_index + 1,
            turns: counters.turns,
            llm_attempts: counters.llm_attempts,
            retrying: counters.retrying,
            step_index: counters.step_index,
            turn_steps: counters.turn_steps,
            messages: closed.messages.add([message]),
            follow_up_queue: if kind == @common.FollowUp {
              drop_first(closed.follow_up_queue)
            } else {
              closed.follow_up_queue
            },
            steer_queue: if kind == @common.Steer {
              drop_first(closed.steer_queue)
            } else {
              closed.steer_queue
            },
            // 新的一句话 = 上一回合的收工理由作废。
            stop_reason: None,
            stop_cause: None,
            stop_cause_detail: None,
            // 相位得离开 idle，否则 waitForIdle 会以为已经收工而提前返回。
            phase: @common.Thinking,
          }
        }
      }
    }
    @action.TurnContinue => {
      // 三条守卫：跑着不续（会开第二条并行的环）、压缩中不续、一条消息都没有不续。
      if state.phase != @common.Idle {
        return state
      }
      if state.compacting {
        return state
      }
      if state.messages.is_empty() {
        return state
      }
      let begun = begin_trace(state, now)
      let with_model = flush_model_change({ ..state, trace: begun, }, now)
      // 停在工具调用中途（进程被砍的典型现场）：补一条「工具没返回结果」，
      // 否则下一个请求就是非法消息序列。
      let repaired = match repair_tail_tool_calls(with_model.messages, now) {
        Some(messages) => messages
        None => with_model.messages
      }
      let counters = new_turn_counters()
      {
        ..with_model,
        trace_begun: true,
        phase: @common.Thinking,
        messages: repaired,
        error: None,
        error_node_id: None,
        error_kind: None,
        stop_reason: None,
        stop_cause: None,
        stop_cause_detail: None,
        aborted: false,
        turns: counters.turns,
        llm_attempts: counters.llm_attempts,
        retrying: counters.retrying,
        step_index: counters.step_index,
        turn_steps: counters.turn_steps,
        streaming_text: "",
        thinking_text: "",
        pending_tool_calls: [],
        executing: [],
        open_llm_node_id: None,
        open_step_node_id: None,
        open_turn_node_id: None,
      }
    }
    @action.StepStart => {
      // 防重入：上一个 step 还开着时不要又开一个。
      // 重试不走这里（容器一直开着，接线只补 agent.run）。
      if state.open_step_node_id is Some(_) {
        return state
      }
      let mut base = state
      // **先把上一个回合收尾（幂等）。**
      //
      // 「开了新回合但上一个还没关」是一种真实存在的中间态 —— followUp 到达时
      // reducer 直接开新容器，而给旧回合发 turn.end 在那条路上发不出去。
      // 把收尾挂在「新回合之后下一步一定是 step.start」这条必然到来的边上。
      let stale_turn = match state.open_turn_node_id {
        Some(_) =>
          match state.open_turn_seq {
            Some(seq) => seq < state.turn_index
            None => false
          }
        None => false
      }
      if stale_turn {
        base = close_turn_node(
          base,
          now,
          @common.TurnCompleted,
          @common.turn_reason_text(@common.TurnCompleted),
        )
      }
      let (opened, _node) = open_step_node(base, now)
      // 新的一步从干净状态开始（上一条失败的红字不该带进新容器）。
      {
        ..opened,
        error: None,
        error_node_id: None,
        error_kind: None,
        aborted: false,
      }
    }
    @action.StepEnd(data) => {
      let closed = close_step_node(state, now, data.status)
      { ..closed, turn_steps: state.turn_steps, }
    }
    @action.AgentRun(_text) => {
      // 请求即将发起 —— 工具集的变化要**在这一刻**声明出去（只追加消息）。
      //
      // 这一步必须在防重入守卫**之前**：真实流程里 `StepStart` 刚把 step 容器
      // 打开，`open_step_node_id` 是 Some，守卫会把下面的状态重置整个跳过 ——
      // 而工具声明不能跳（否则 tools.changed 永远到不了模型）。
      let (messages, declared_tools) = with_tool_declarations(state, now)
      let with_declarations = {
        ..state,
        messages,
        prompt: { ..state.prompt, declared_tools, },
      }
      // 防重入：上一次 step 还开着时不要再重开（声明已经补上）。
      if state.phase == @common.Thinking && state.open_step_node_id is Some(_) {
        return with_declarations
      }
      {
        ..with_declarations,
        phase: @common.Thinking,
        error: None,
        error_node_id: None,
        error_kind: None,
        aborted: false,
        streaming_text: "",
        thinking_text: "",
        pending_tool_calls: [],
        executing: [],
      }
    }
    // ── 流式 ──
    @action.LlmStarted => {
      if state.phase != @common.Thinking {
        return state
      }
      {
        ..state,
        stream_seq: state.stream_seq + 1,
        streaming_text: "",
        thinking_text: "",
      }
    }
    @action.LlmDelta(delta) => {
      if state.phase != @common.Thinking {
        return state
      }
      { ..state, streaming_text: state.streaming_text + delta, }
    }
    @action.LlmThinking(delta) => {
      if state.phase != @common.Thinking {
        return state
      }
      { ..state, thinking_text: state.thinking_text + delta, }
    }
    @action.LlmDone(data) => {
      if state.phase == @common.Idle {
        return state
      }
      let (part, tool_calls) = dedupe_tool_call_ids(state, data.message)
      let text = @message.contents_text(part.content)
      let message : @message.Message = @message.AssistantMsg(part)
      // 成功：在当前 step 下面挂 llm.result，由它推进 tip。
      // **这一步不开 step.end**：有工具时 step 还没完（工具批次也算在这个 step 里）。
      let closed = close_llm_success(state, now, text, message)
      let has_tools = !tool_calls.is_empty()
      // **用户按了停止**（pi-ai 把那份部分消息以 stop_reason = 'aborted' 交回来）。
      // 超时不算这一支：超时要在 effect 侧就拦住、报成可重试错误。
      let aborted = part.stop_reason == "aborted"
      // 中止时**不接手那些工具调用**：用户都喊停了，再跑 `rm -rf` 就很离谱。
      let continues = has_tools && !aborted
      // 无工具 = 模型自己说完了 —— 这是整个回合的终点，所以现在就把 step 关掉。
      let with_step = if continues {
        closed
      } else {
        close_step_node(
          closed,
          now,
          if aborted {
            @trace.Aborted
          } else {
            @trace.Ok
          },
        )
      }
      let cost = match part.usage {
        Some(usage) => usage.cost_total
        None => 0.0
      }
      let usage = match part.usage {
        Some(usage) => Some(usage)
        None => with_step.usage
      }
      let error = if aborted {
        None
      } else {
        match part.error_message {
          Some(message) => Some(message)
          None => with_step.error
        }
      }
      let stop_reason = if continues {
        None
      } else if aborted {
        Some(@common.StopReason::Aborted)
      } else {
        Some(@common.Completed)
      }
      let stop_cause = if continues {
        None
      } else if aborted {
        Some(@common.CauseUser)
      } else {
        Some(@common.CauseCompleted)
      }
      let stop_detail = match stop_cause {
        Some(cause) => Some(@common.stop_cause_text(cause))
        None => None
      }
      {
        ..with_step,
        messages: with_step.messages.add([message]),
        streaming_text: "",
        thinking_text: "",
        turns: with_step.turns + 1,
        usage,
        total_cost: with_step.total_cost + cost,
        pending_tool_calls: if aborted {
          []
        } else {
          tool_calls
        },
        error,
        phase: if continues {
          @common.CallingTools
        } else {
          @common.Idle
        },
        stop_reason,
        stop_cause,
        stop_cause_detail: stop_detail,
      }
    }
    @action.LlmFailed(data) => {
      let kind = data.kind
      let cause = @common.cause_from_kind(kind, data.cause)
      // 只有一个确实在跑的 step 才谈得上「重试」；工具批次的失败走这里时
      // open_step_node_id 已是 None。
      let was_llm_attempt = state.open_step_node_id is Some(_)
      let can_retry = was_llm_attempt &&
        @common.is_retryable(kind) &&
        state.llm_attempts < state.max_llm_attempts
      let closed = close_llm_failure(
        state,
        now,
        data.error,
        kind,
        data.node_id,
        cause,
        can_retry,
      )
      if can_retry {
        // **重试不开新容器**：error 已经作为孩子挂进当前 step 容器，容器保持开着。
        // 尝试计数在这里 +1 —— 下一次失败时判据才能数对。
        {
          ..closed,
          llm_attempts: closed.llm_attempts + 1,
          phase: @common.Thinking,
          error: None,
          error_node_id: None,
          error_kind: None,
          retrying: true,
          streaming_text: "",
          thinking_text: "",
          executing: [],
          aborted: false,
          // 还要重试 = 这一轮**没停**，别让界面以为收工了。
          stop_reason: None,
          stop_cause: None,
          stop_cause_detail: None,
        }
      } else {
        // 不重试（重试用尽 / 不可重试 / 工具批次失败）= 这一步真的结束，关掉容器。
        let with_step = close_step_node(
          closed,
          now,
          if kind == @common.LlmErrorKind::Aborted {
            @trace.Aborted
          } else {
            @trace.Errored
          },
        )
        {
          ..with_step,
          phase: @common.Idle,
          error: Some(data.error),
          error_kind: Some(kind),
          error_node_id: closed.error_node_id,
          retrying: false,
          streaming_text: "",
          thinking_text: "",
          executing: [],
          aborted: kind == @common.LlmErrorKind::Aborted,
          stop_reason: if kind == @common.LlmErrorKind::Aborted {
            Some(@common.StopReason::Aborted)
          } else {
            Some(@common.Errored)
          },
          stop_cause: Some(cause),
          stop_cause_detail: Some(@common.stop_cause_text(cause)),
        }
      }
    }
    @action.LlmGiveup(data) => {
      let cause = @common.cause_from_kind(data.kind, data.cause)
      // stop 节点挂在 **turn 容器**下面（与 step 同理：回合是它们共同的父）。
      let parent_id = match state.open_turn_node_id {
        Some(id) => Some(id)
        None => state.trace.tip_id
      }
      let (tree, _node) = @trace.append_node(
        state.trace,
        parent_id,
        @trace.StopNode,
        @trace.Ok,
        data.error,
        now,
        detail=data.error,
        // 跟错误节点一样把 cause 记进 meta：树上就能看出「用户主动停了」
        // 而不是「模型坏了」。
        meta=[("kind", data.kind.name()), ("cause", cause.name())],
        ended_at=now,
      )
      // 重试已经用尽 = 这一步真的结束了，把 step 容器也关上。
      let with_step = close_step_node(
        { ..state, trace: tree, },
        now,
        if data.kind == @common.LlmErrorKind::Aborted {
          @trace.Aborted
        } else {
          @trace.Errored
        },
      )
      {
        ..with_step,
        phase: @common.Idle,
        error: Some(data.error),
        error_kind: Some(data.kind),
        retrying: false,
        streaming_text: "",
        thinking_text: "",
        executing: [],
        stop_reason: if data.kind == @common.LlmErrorKind::Aborted {
          Some(@common.StopReason::Aborted)
        } else {
          Some(@common.Errored)
        },
        stop_cause: Some(cause),
        stop_cause_detail: Some(@common.stop_cause_text(cause)),
      }
    }
    // ── 工具 ──
    @action.ToolCall(calls) => {
      // llm.done 的迁移已经把相位推到 calling-tools 了，所以这里**不能**再要求 idle。
      // 空闲时来的 tool.call 是过期消息，忽略。
      if state.phase == @common.Idle {
        return state
      }
      { ..state, phase: @common.CallingTools, pending_tool_calls: calls, }
    }
    @action.ToolStart(call) => {
      let (tree, node) = @trace.append_node(
        state.trace,
        state.trace.tip_id,
        @trace.ToolCallNode,
        @trace.Pending,
        call.name + " " + call.arguments,
        now,
        detail=call.arguments,
        meta=[("tool", call.name)],
      )
      {
        ..state,
        trace: tree,
        open_tool_node_ids: state.open_tool_node_ids.add(call.id, node.id),
        executing: state.executing.add([{ call, started_at: now, }]),
      }
    }
    @action.ToolProgress(data) => {
      // 工具不在跑时的 progress 丢弃：那是过期消息。
      if !state.open_tool_node_ids.contains(data.tool_call_id) {
        return state
      }
      {
        ..state,
        tool_progress: state.tool_progress.add(data.tool_call_id, {
          tool_call_id: data.tool_call_id,
          content: data.content,
        }),
      }
    }
    @action.ToolResult(result) => {
      // 重复的 toolResult 静默忽略：正常情况下不该走到这里（llm.done 已经
      // 把重复 id 改掉了）。丢了工具结果消息序列就非法，所以判重要在这一层。
      let mut duplicate = false
      for message in state.messages {
        match message.tool_result_id() {
          Some(id) => if id == result.tool_call_id { duplicate = true }
          None => ()
        }
      }
      if duplicate {
        return state
      }
      let open_id = state.open_tool_node_ids.get(result.tool_call_id)
      let text = @message.contents_text(result.content)
      let mut trace = state.trace
      // **失败时 attempt 节点本身要标成 error**，不是 ok：轨迹渲染靠兄弟节点的
      // status 判断要不要画分叉，失败时它是 error 节点挂在 attempt 下面，
      // 若父节点还显示 ok，两边自相矛盾。
      match open_id {
        Some(id) =>
          trace = @trace.patch_node(
            trace,
            id,
            status=if result.is_error { @trace.Errored } else { @trace.Ok },
            ended_at=now,
          )
        None => ()
      }
      // 工具失败也是一个 error 节点（同样不推进 tip），成功才是 tool.result。
      let (tree, node) = if result.is_error {
        @trace.append_node(
          trace,
          open_id,
          @trace.ErrorNode,
          @trace.Errored,
          @message.contents_text(result.content),
          now,
          detail=text,
          message=@message.ToolResultMsg(result),
          meta=[("tool", result.tool_name)],
          ended_at=now,
        )
      } else {
        @trace.append_node(
          trace,
          open_id,
          @trace.ToolResultNode,
          @trace.Ok,
          @common.summarize(text),
          now,
          detail=text,
          message=@message.ToolResultMsg(result),
          meta=[("tool", result.tool_name)],
          ended_at=now,
        )
      }
      // 耗时：`ToolStart` 打的点在 trace 节点上，这是唯一同时拿到
      // 「开始时刻」与「结束时刻」的地方。取完再删。
      let started_at = match open_id {
        Some(id) =>
          match state.trace.nodes.get(id) {
            Some(node) => Some(node.created_at)
            None => None
          }
        None => None
      }
      let tool_timings = match started_at {
        Some(start) =>
          if now >= start {
            state.tool_timings.add(result.tool_call_id, now - start)
          } else {
            state.tool_timings
          }
        None => state.tool_timings
      }
      {
        ..state,
        trace: tree,
        open_tool_node_ids: state.open_tool_node_ids.remove(result.tool_call_id),
        tool_progress: state.tool_progress.remove(result.tool_call_id),
        // 工具数加一：step.end 的标签要写「这一步跑了几个工具」，
        // 而 tool.batch.done 到来时容器已经关了 —— 所以得在每个 result 上累积。
        step_tool_calls: state.step_tool_calls + 1,
        tool_timings,
        error_node_id: if result.is_error {
          Some(node.id)
        } else {
          state.error_node_id
        },
        executing: state.executing.filter(tool => {
          tool.call.id != result.tool_call_id
        }),
        pending_tool_calls: state.pending_tool_calls.filter(call => {
          call.id != result.tool_call_id
        }),
        messages: state.messages.add([@message.ToolResultMsg(result)]),
      }
    }
    @action.ToolBatchDone(_count) => {
      if state.phase != @common.CallingTools {
        return state
      }
      // 工具跑完 = 这个 step 的区间结束了（LLM 调用 + 它的工具批次都齐了）。
      let closed = close_step_node(state, now, @trace.Ok)
      if max_turns_reached(state) {
        // 撞上限：留一个 stop 节点（推进 tip），这样「为什么停了」也在树上。
        let parent_id = match state.open_turn_node_id {
          Some(id) => Some(id)
          None => state.trace.tip_id
        }
        let (tree, _node) = @trace.append_node(
          closed.trace,
          parent_id,
          @trace.StopNode,
          @trace.Ok,
          "已达单回合上限（" + state.turns.to_string() + " 轮）",
          now,
          ended_at=now,
        )
        let detail = "已达单回合轮数上限（" +
          state.turns.to_string() +
          " 轮 LLM 调用），停止。"
        {
          ..closed,
          trace: tree,
          phase: @common.Idle,
          error: Some(detail),
          error_kind: None,
          stop_reason: Some(@common.MaxTurns),
          stop_cause: Some(@common.CauseMaxTurns),
          stop_cause_detail: Some(
            @common.stop_cause_text(@common.CauseMaxTurns),
          ),
          llm_attempts: 0,
        }
      } else {
        // 工具批次结束 = 这一步结束，重试计数归零（下一步又从第 1 次尝试开始）。
        // 相位留在 thinking：接线看到它会发 step.start（然后 agent.run）。
        {
          ..closed,
          phase: @common.Thinking,
          streaming_text: "",
          thinking_text: "",
          llm_attempts: 0,
        }
      }
    }
    // ── 落盘游标 ──
    @action.TracePersisted(up_to_seq) =>
      {
        ..state,
        persisted_seq: if up_to_seq > state.persisted_seq {
          up_to_seq
        } else {
          state.persisted_seq
        },
      }
    // ── 会话恢复 ──
    @action.SessionRestored(data) => {
      let tool_names : Array[String] = []
      for tool in data.tools {
        tool_names.push(tool.name)
      }
      // 用 create_initial_state 重建一份「干净的」state（流式缓冲 / 队列 /
      // 打开中的容器 / 临时 hashmap 全是新的），再把恢复出来的字段盖上去。
      let base = @state.create_initial_state({
        system_prompt: data.prompt.system_prompt,
        provider_name: data.model.provider,
        model_id: data.model.model_id,
        thinking_level: data.model.thinking_level,
        tool_names,
        max_turns: state.max_turns,
        max_llm_attempts: state.max_llm_attempts,
        llm_timeout_ms: state.llm_timeout_ms,
        session_id: data.trace.session_id,
        cwd: state.cwd,
        trace: Some(@trace.recompute_tip(data.trace)),
      })
      let restored = {
        ..base,
        prompt: {
          system_prompt: data.prompt.system_prompt,
          tools: data.tools,
          head_tools: Some(data.prompt.tools),
          // transcript 里已经声明过「当前」这份（中途变更的 system 消息也在 messages 里）。
          declared_tools: data.tools,
          seeded: true,
        },
        messages: data.messages.copy(),
        trace_begun: true,
        compact_settings: state.compact_settings,
        persisted_seq: data.persisted_seq,
        total_steps: @trace.trace_stats(data.trace).steps,
      }
      apply_model_spec(restored, data.model)
    }
    // ── 工具集变更 ──
    @action.ToolsChanged(tools) => {
      let tool_names : Array[String] = []
      for tool in tools {
        tool_names.push(tool.name)
      }
      // 老状态（没有 head_tools）首次变更时，把**变更前**那批留作 head；
      // 否则 head 会跟着新工具集走，前缀立刻作废。
      let head_tools = match state.prompt.head_tools {
        Some(head) => Some(head)
        None => Some(state.prompt.tools)
      }
      { ..state, prompt: { ..state.prompt, tools, head_tools, }, tool_names, }
    }
    // ── 会话 ──
    @action.ConversationReset(data) => {
      let session_id = match data.session_id {
        Some(id) => id
        None => state.trace.session_id
      }
      let tool_names : Array[String] = []
      for tool in state.prompt.tools {
        tool_names.push(tool.name)
      }
      let options : @state.InitialStateOptions = {
        system_prompt: state.prompt.system_prompt,
        provider_name: state.model.provider,
        model_id: state.model.model_id,
        thinking_level: state.model.thinking_level,
        tool_names,
        max_turns: state.max_turns,
        max_llm_attempts: state.max_llm_attempts,
        llm_timeout_ms: state.llm_timeout_ms,
        session_id,
        cwd: state.cwd,
        trace: None,
      }
      let fresh = @state.create_initial_state(options)
      {
        ..fresh,
        // 保留装载好的两块（会话级的，不是对话级的）。
        prompt: state.prompt,
        model: state.model,
        compact_settings: state.compact_settings,
        persisted_seq: state.persisted_seq,
      }
    }
    // ── 压缩 ──
    @action.CompactRequest(reason) => {
      // 守卫一：压缩期间不能再来一次 —— 两条摘要基于同一份历史生成，
      // 后写的覆盖先写的，白花钱还丢信息。
      // 守卫二：环在跑时不许压 —— 压缩整份换掉 messages，而正在流的那条请求
      // 回来时看到的已经不是它请求的那份历史，`tool.result` 更会找不到它的 id。
      if state.compacting || state.phase != @common.Idle {
        return { ..state, compact_requested: false, }
      }
      let settings = @compact.effective_settings(
        state.compact_settings,
        state.model.context_window,
      )
      let plan = @compact.plan_cut(state.messages, settings.keep_recent_tokens)
      // **先开 pending 再等结果**，而不是等压缩完才开：那样中途挂掉就什么都没有，
      // 而「开始压缩了」这个事实本身就该留在树上。
      let (tree, node) = @trace.append_node(
        state.trace,
        state.trace.tip_id,
        @trace.CompactNode,
        @trace.Pending,
        reason.text(),
        now,
        meta=[("reason", reason.name())],
      )
      {
        ..state,
        trace: tree,
        compacting: true,
        compact_requested: true,
        compact_reason: Some(reason),
        compact_plan: plan,
        open_compact_node_id: Some(node.id),
      }
    }
    @action.CompactDone(data) => {
      if !state.compacting {
        return state
      }
      let reason = state.compact_reason.unwrap_or(@compact.Manual)
      let why = reason.text()
      let nothing = data.summarized_count == 0
      let label = if nothing {
        why + "压缩：没什么可压的"
      } else {
        why +
        "压缩：" +
        data.summarized_count.to_string() +
        " 条 → " +
        data.kept_count.to_string() +
        " 条"
      }
      // **就地改写**那个 pending 节点（不另开一个）：压缩从头到尾就是一个节点。
      // 它从 pending 变成 ok，于是推进 tip —— 压缩之后的那条线是从摘要开始的。
      let mut trace = state.trace
      match state.open_compact_node_id {
        Some(id) =>
          trace = @trace.patch_node(
            trace,
            id,
            status=@trace.Ok,
            label~,
            detail=data.summary,
            meta=[
              ("reason", reason.name()),
              ("summarized", data.summarized_count.to_string()),
              ("kept", data.kept_count.to_string()),
              ("tokensBefore", data.tokens_before.to_string()),
            ],
            ended_at=now,
          )
        None => ()
      }
      let (usage, cost) = match data.usage {
        Some(usage) => (Some(usage), usage.cost_total)
        None => (state.usage, 0.0)
      }
      {
        ..state,
        trace,
        compacting: false,
        compact_requested: false,
        compact_reason: None,
        compact_plan: None,
        open_compact_node_id: None,
        messages: data.messages,
        usage,
        total_cost: state.total_cost + cost,
        last_compaction: Some({
          reason,
          summarized_count: data.summarized_count,
          kept_count: data.kept_count,
          tokens_before: data.tokens_before,
        }),
        // 只有真的换过历史才推进 epoch：落盘器据此写一条 `compact` 记录。
        compaction_epoch: if nothing {
          state.compaction_epoch
        } else {
          state.compaction_epoch + 1
        },
        // 压缩成功**不碰** error / stop_reason / stop_cause：它不是「一轮对话的结果」。
      }
    }
    @action.CompactFailed(data) => {
      if !state.compacting {
        return state
      }
      let node_id = state.open_compact_node_id
      let mut trace = state.trace
      match node_id {
        Some(id) =>
          trace = @trace.patch_node(
            trace,
            id,
            status=@trace.Errored,
            ended_at=now,
          )
        None => ()
      }
      let (tree, error_node) = @trace.append_node(
        trace,
        node_id,
        @trace.ErrorNode,
        @trace.Errored,
        data.error,
        now,
        detail=data.error,
        meta=[("kind", "compact-error"), ("cause", "compact-error")],
        ended_at=now,
      )
      {
        ..state,
        trace: tree,
        compacting: false,
        compact_requested: false,
        compact_reason: None,
        compact_plan: None,
        open_compact_node_id: None,
        // messages 一个字都不动：半截摘要进历史比不压糟糕得多。
        error: Some(data.error),
        error_node_id: Some(error_node.id),
        error_kind: None,
        stop_reason: None,
        stop_cause: Some(@common.CauseCompactError),
        stop_cause_detail: Some(
          @common.stop_cause_text(@common.CauseCompactError),
        ),
      }
    }
    @action.CompactSettingsChanged(settings) =>
      { ..state, compact_settings: settings, }
  }
}
