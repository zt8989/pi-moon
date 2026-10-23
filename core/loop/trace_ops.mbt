// 轨迹小工具 —— 全部是纯函数，只是为了让下面两张表读起来像业务而不是像 XML。
//
// 它们对应原项目 reducer.ts 顶部的同名辅助函数。放在单独文件里是为了让
// 「动作迁移表」与「状态变更细节」分开读。

///|
/// 新回合的计数器重置包。三个新回合入口（user.message / queue.delivered 的 followUp /
/// turn.end 里的 followUp）共用这一份 —— 写三遍必然漂移，而漂移的症状是
/// 「第二个回合的计数从 1 开始」。
pub(all) struct TurnCounters {
  turns : Int32
  llm_attempts : Int32
  retrying : Bool
  step_index : Int32
  turn_steps : Int32
} derive(Eq, Debug)

///|
pub fn new_turn_counters() -> TurnCounters {
  { turns: 0, llm_attempts: 0, retrying: false, step_index: 0, turn_steps: 0, }
}

///|

///|
/// 开一个新的 step 容器（一次 LLM 调用 + 它的工具批次）。
///
/// ## parent 为什么是 turn 容器
///
/// 这是整个分叉语义的所在地。step 挂到 **turn 节点**下面（而不是 tip）：
/// 工具结果会推进 tip（`ToolResultNode` 在集合里），若 step 也挂 tip，
/// 第二个 step 就会挂到第一个 step 的 tool.result 底下，层数无法控制。
///
/// 重试**不**走这里（容器一直开着），所以走到这里的永远是「新的一步」。
pub fn open_step_node(
  state : @state.AgentState,
  now : Int64,
) -> (@state.AgentState, @trace.TraceNode) {
  let parent_id = match state.open_turn_node_id {
    Some(id) => Some(id)
    None => state.trace.tip_id
  }
  let step_index = state.step_index + 1
  let (tree, node) = @trace.append_node(
    state.trace,
    parent_id,
    @trace.StepStart,
    @trace.Pending,
    "第 " + step_index.to_string() + " 步",
    now,
    meta=[("provider", state.provider_name), ("model", state.model_id)],
  )
  let next : @state.AgentState = {
    ..state,
    trace: tree,
    open_llm_node_id: Some(node.id),
    open_step_node_id: Some(node.id),
    step_index,
    // 尝试计数从 1 起步：这是这个容器里的第一次尝试。重试由 LlmFailed
    // 在**同一个容器**上 +1 —— 重试预算因此是「每个 step 各自的预算」。
    llm_attempts: 1,
    retrying: false,
    step_tool_calls: 0,
  }
  (next, node)
}

///|
/// 成功：在 step 下挂 `llm.result` 节点（它才是推进 tip 的那个）。
pub fn close_llm_success(
  state : @state.AgentState,
  now : Int64,
  detail : String,
  message : @message.Message,
) -> @state.AgentState {
  let open_id = match state.open_step_node_id {
    Some(id) => Some(id)
    None => state.open_llm_node_id
  }
  let mut trace = state.trace
  match open_id {
    Some(id) =>
      trace = @trace.patch_node(trace, id, status=@trace.Ok, ended_at=now)
    None => ()
  }
  let (tree, _node) = @trace.append_node(
    trace,
    open_id,
    @trace.LlmResult,
    @trace.Ok,
    @common.summarize(detail),
    now,
    detail~,
    message~,
    ended_at=now,
  )
  { ..state, trace: tree, open_llm_node_id: None, retrying: false, }
}

///|
/// 关掉当前 step 容器（`step.end` 节点）。它**不推进 tip** —— tip 由里面的 result 推进。
pub fn close_step_node(
  state : @state.AgentState,
  now : Int64,
  status : @trace.TraceNodeStatus,
) -> @state.AgentState {
  let open_id = match state.open_step_node_id {
    Some(id) => id
    None => return { ..state, open_llm_node_id: None, }
  }
  // `step_tool_calls` **先**取出来写进标签，**然后**才在返回值里归零。
  // 顺序反了的话标签会永远写 0。
  let tool_calls = state.step_tool_calls
  let (tree, _node) = @trace.append_node(
    state.trace,
    Some(open_id),
    @trace.StepEnd,
    status,
    "第 " +
    state.step_index.to_string() +
    " 步结束（" +
    tool_calls.to_string() +
    " 个工具调用）",
    now,
    meta=[("tools", tool_calls.to_string())],
    ended_at=now,
  )
  {
    ..state,
    trace: tree,
    open_step_node_id: None,
    open_llm_node_id: None,
    total_steps: state.total_steps + 1,
    step_tool_calls: 0,
    // **`turn_steps` 在这里加，而不是在各个调用点加。**
    // 调它的地方有四处，少一处就少算一步 —— 而 turn.end 的标签会写「1 步」
    // 而树上明明有两个 step.end。那种错误不报错，只是数字对不上。
    turn_steps: state.turn_steps + 1,
  }
}

///|
/// 关掉整个回合（`turn.end` 节点，**推进 tip**）。
///
/// 与 step 不同，回合容器闭合时**要**推进 tip —— 后面发生的事（下一回合、
/// 用户消息）都从它下面长出来。
pub fn close_turn_node(
  state : @state.AgentState,
  now : Int64,
  reason : @common.TurnEndReason,
  reason_text : String,
) -> @state.AgentState {
  let open_id = match state.open_turn_node_id {
    Some(id) => id
    None => return state
  }
  let status = match reason {
    @common.TurnCompleted => @trace.Ok
    @common.TurnAborted => @trace.Aborted
    _ => @trace.Errored
  }
  let (tree, _node) = @trace.append_node(
    state.trace,
    Some(open_id),
    @trace.TurnEnd,
    status,
    "回合 " + state.turn_index.to_string() + " 结束：" + reason_text,
    now,
    meta=[("reason", reason.name()), ("steps", state.turn_steps.to_string())],
    ended_at=now,
  )
  { ..state, trace: tree, open_turn_node_id: None, open_turn_seq: None, }
}

///|
/// 失败：在 attempt 下挂一个 `error` 节点。
///
/// error 节点**不推进 tip** —— 所以下一次重试的产出仍然挂在同一个 step 容器里，
/// 而不是「错误的子节点才是正史」。
pub fn close_llm_failure(
  state : @state.AgentState,
  now : Int64,
  error : String,
  kind : @common.LlmErrorKind,
  node_id : String?,
  cause : @common.StopCause,
  will_retry : Bool,
) -> @state.AgentState {
  let open_id = match node_id {
    Some(id) => Some(id)
    None => state.open_step_node_id
  }
  let status = if kind == @common.Aborted {
    @trace.Aborted
  } else {
    @trace.Errored
  }
  // 容器的闭合标记只在**真的收工**时打：重试时容器还开着，打了 status/ended_at
  // 树就会把还开着的容器画成已闭合，时长也停在第一次失败的那一刻。
  let mut trace = state.trace
  if !will_retry {
    match open_id {
      Some(id) => trace = @trace.patch_node(trace, id, status~, ended_at=now)
      None => ()
    }
  }
  let (tree, node) = @trace.append_node(
    trace,
    open_id,
    @trace.ErrorNode,
    status,
    error,
    now,
    detail=error,
    meta=[("kind", kind.name()), ("cause", cause.name())],
    ended_at=now,
  )
  {
    ..state,
    trace: tree,
    open_llm_node_id: if will_retry {
      open_id
    } else {
      None
    },
    error_node_id: Some(node.id),
    error_kind: Some(kind),
  }
}

///|

///|
pub fn apply_model_spec(
  state : @state.AgentState,
  spec : @action.ModelSpec,
) -> @state.AgentState {
  let model : @state.ModelState = {
    provider: spec.provider,
    model_id: spec.model_id,
    thinking_level: spec.thinking_level,
    reasoning: spec.reasoning,
    capabilities: spec.capabilities,
    context_window: spec.context_window,
    seeded: true,
  }
  {
    ..state,
    model,
    provider_name: spec.provider,
    model_id: spec.model_id,
    thinking_level: spec.thinking_level,
  }
}

///|
/// 把 prompt 那半（base / tools）追加到树上。parent 取此刻的 tip。
///
/// 节点内容从 state 读：补出来的必然是**这一刻生效**的那一版，
/// 与模型真正看到的一致。不推进 tip —— 上下文不是「发生过的事」。
pub fn append_prompt_nodes(
  tree : @trace.TraceTree,
  prompt : @state.PromptState,
  now : Int64,
) -> @trace.TraceTree {
  let (after_base, base_node) = @trace.append_node(
    tree,
    tree.tip_id,
    @trace.PromptBase,
    @trace.Ok,
    @common.summarize(prompt.system_prompt),
    now,
    detail=prompt.system_prompt,
    ended_at=now,
  )
  let tool_names : Array[String] = []
  let tool_details : Array[String] = []
  for tool in prompt.tools {
    tool_names.push(tool.name)
    tool_details.push(tool.name + ": " + tool.description)
  }
  let label = if tool_names.is_empty() {
    "（无）"
  } else {
    tool_names.join(", ")
  }
  let (after_tools, _tools_node) = @trace.append_node(
    after_base,
    // parent 用 base 节点的 **id**（不是它的 tip —— prompt.base 不推进 tip，
    // 那样取会拿到装载前的 tip，两兄弟就散了）。
    Some(base_node.id),
    @trace.PromptTools,
    @trace.Ok,
    label,
    now,
    detail=tool_details.join("\n"),
    meta=[("count", prompt.tools.length().to_string())],
    ended_at=now,
  )
  after_tools
}

///|
/// 把 model 那半（provider / model / 思考级别 / 能力）追加到树上。
pub fn append_model_node(
  tree : @trace.TraceTree,
  model : @state.ModelState,
  now : Int64,
  kind : @trace.TraceNodeKind,
) -> @trace.TraceTree {
  let caps = model.capabilities
  let (next, _node) = @trace.append_node(
    tree,
    tree.tip_id,
    kind,
    @trace.Ok,
    model.provider + "/" + model.model_id,
    now,
    meta=[
      ("thinking", model.thinking_level),
      ("reasoning", model.reasoning.to_string()),
      ("midConvoSystem", caps.mid_convo_system_messages.to_string()),
      ("midConvoTools", caps.mid_convo_tool_additions.to_string()),
      ("developerRole", caps.developer_role.to_string()),
    ],
    ended_at=now,
  )
  next
}

///|
/// 补上装载段的轨迹节点 —— **用户发出第一句话的那一刻**。
///
/// 装载（prompt / model）必须立刻可用（开场报清单、底栏要显示模型），所以它们
/// 只改 state、不进轨迹树；而在树上留痕应该等到**真的有对话**。
///
/// 幂等：`trace_begun` 守卫，已经补过就原样返回。
pub fn begin_trace(state : @state.AgentState, now : Int64) -> @trace.TraceTree {
  if state.trace_begun {
    return state.trace
  }
  let mut tree = state.trace
  if state.prompt.seeded {
    tree = append_prompt_nodes(tree, state.prompt, now)
  }
  if state.model.seeded {
    tree = append_model_node(tree, state.model, now, @trace.ModelInit)
  }
  tree
}

///|
/// 把「模型 / 思考级别变了」补成**一个** `model.changed` 节点 —— 推迟到下次真要发消息时补。
///
/// 不在 `ModelChanged` / `ThinkingChanged` 里当场补：那两个是**界面动作**，而轨迹树
/// 要回答的是「这一轮实际发出去的是什么」。所以来回切三次 = 树上**一个**节点。
pub fn flush_model_change(
  state : @state.AgentState,
  now : Int64,
) -> @state.AgentState {
  if !state.model_trace_dirty {
    return state
  }
  let trace = append_model_node(
    state.trace,
    state.model,
    now,
    @trace.ModelChanged,
  )
  { ..state, trace, model_trace_dirty: false, }
}

///|
/// 给重复的 tool call id 改名，保证一轮里的 id 唯一。
///
/// 协议要求一个 assistant 消息里有几个 toolCall 就有几个对应的 toolResult、
/// 且靠 id 配对。模型偶尔会返回**重复的 id**，于是 toolResult 的判重会把第二个
/// 结果丢掉（消息流变成「2 个 call、1 个 result」，协议非法）。
///
/// 去重是错的（丢掉模型真要执行的调用），必须把 id 变唯一：id 在会话里出现过
/// 就加 `#2`、`#3` 后缀（对模型只是占位符，改写是安全的）。
pub fn dedupe_tool_call_ids(
  state : @state.AgentState,
  part : @message.AssistantPart,
) -> (@message.AssistantPart, Array[@message.ToolCall]) {
  let calls = part.tool_calls()
  if calls.is_empty() {
    return (part, calls)
  }
  // 已用过的 id：历史 toolResult 里的 + 历史 assistant 消息里的。
  let used : Array[String] = []
  for message in state.messages {
    match message {
      @message.ToolResultMsg(result) => used.push(result.tool_call_id)
      @message.AssistantMsg(previous) =>
        for call in previous.tool_calls() {
          used.push(call.id)
        }
      _ => ()
    }
  }
  let claimed : Array[String] = []
  let rewritten : Array[@message.ToolCall] = []
  let mut renamed = false
  for call in calls {
    if !used.contains(call.id) && !claimed.contains(call.id) {
      claimed.push(call.id)
      rewritten.push(call)
    } else {
      renamed = true
      let mut n = 2
      let mut candidate = call.id + "#" + n.to_string()
      while used.contains(candidate) || claimed.contains(candidate) {
        n = n + 1
        candidate = call.id + "#" + n.to_string()
      }
      claimed.push(candidate)
      rewritten.push({ ..call, id: candidate, })
    }
  }
  if !renamed {
    return (part, rewritten)
  }
  // 改写后的 toolCall 必须放回 content —— messages 里要用新 id，
  // 否则后面 toolResult 回来的 id 与消息里的对不上（那正是要避免的病）。
  let content : Array[@message.Content] = []
  let mut index = 0
  for block in part.content {
    match block {
      @message.ToolCallBlock(_) => {
        content.push(@message.ToolCallBlock(rewritten[index]))
        index = index + 1
      }
      other => content.push(other)
    }
  }
  ({ ..part, content, }, rewritten)
}

///|
/// 请求即将发起时，把**工具集的变化**声明进消息流。
///
/// `state.prompt.tools` 是「当前可执行什么」，`declared_tools` 是「transcript 里
/// 已经声明过什么」。不一致时追加一条 system 消息（只追加，不改已有消息 ——
/// 前缀缓存靠的就是历史一个字节不动），并返回新的「已声明」集合。
///
/// 返回的第二个值由调用方写回 `state.prompt.declared_tools`：于是同一份差额
/// 不会在每次 `AgentRun`（包括重试、下一步）重复追加。
pub fn with_tool_declarations(
  state : @state.AgentState,
  now : Int64,
) -> (Array[@message.Message], Array[@action.PromptToolDefinition]) {
  let current = state.prompt.tools
  let declared = state.prompt.declared_tools
  let added : Array[@action.PromptToolDefinition] = []
  let updated : Array[String] = []
  let removed : Array[String] = []
  for tool in current {
    match find_tool(declared, tool.name) {
      None => added.push(tool)
      Some(previous) => if previous != tool { updated.push(tool.name) }
    }
  }
  for tool in declared {
    match find_tool(current, tool.name) {
      Some(_) => ()
      None => removed.push(tool.name)
    }
  }
  if added.is_empty() && updated.is_empty() && removed.is_empty() {
    return (state.messages, declared)
  }
  let lines : Array[String] = ["[toolset changed]"]
  let sections : Array[(String, String)] = []
  if !added.is_empty() {
    let names : Array[String] = []
    lines.push("added:")
    for tool in added {
      names.push(tool.name)
      lines.push("- " + tool.name + ": " + tool.description)
    }
    sections.push(("tools_added", names.join(",")))
  }
  if !updated.is_empty() {
    lines.push("updated: " + updated.join(","))
    sections.push(("tools_updated", updated.join(",")))
  }
  if !removed.is_empty() {
    lines.push("removed: " + removed.join(","))
    sections.push(("tools_removed", removed.join(",")))
  }
  let message = @message.SystemMsg({
    role: "system",
    content: lines.join("\n"),
    sections,
    source: Some("tools.changed"),
    timestamp: now,
  })
  (state.messages.add([message]), current)
}

///|
fn find_tool(
  tools : Array[@action.PromptToolDefinition],
  name : String,
) -> @action.PromptToolDefinition? {
  for tool in tools {
    if tool.name == name {
      return Some(tool)
    }
  }
  None
}

///|
/// 续跑前把「停在工具调用中途」的那一刻补完整。
///
/// 进程被外部超时杀掉时，最后一条消息很可能是一条带 `toolCall` 的 assistant
/// （工具结果还没回来）—— 这是消息序列里**非法**的形状：provider 要求每个
/// toolCall 后面紧跟一个 toolResult。不补的话，`/continue` 第一次请求就会被拒。
///
/// 只在**末尾**追加，不往中间插：会话写入器的游标是「已写条数」，
/// 中插会让它把末尾几条当成新消息重写一遍。
pub fn repair_tail_tool_calls(
  messages : Array[@message.Message],
  now : Int64,
) -> Array[@message.Message]? {
  let mut index = messages.length() - 1
  let answered : Array[String] = []
  while index >= 0 {
    match messages[index] {
      @message.ToolResultMsg(result) => {
        answered.push(result.tool_call_id)
        index = index - 1
      }
      _ => break
    }
  }
  if index < 0 {
    return None
  }
  match messages[index] {
    @message.AssistantMsg(part) => {
      let missing : Array[@message.ToolCall] = []
      for call in part.tool_calls() {
        if !answered.contains(call.id) {
          missing.push(call)
        }
      }
      if missing.is_empty() {
        return None
      }
      let repaired = messages.copy()
      for call in missing {
        repaired.push(
          @message.ToolResultMsg({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [
              @message.Text(
                "（上次运行在这里被中断，工具没有返回结果）",
              ),
            ],
            is_error: true,
            timestamp: now,
          }),
        )
      }
      Some(repaired)
    }
    _ => None
  }
}
