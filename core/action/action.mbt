// 一切皆 Action。
//
// Agent 不是一等公民：它只是 `AgentRun` 这一个 action，和 `ToolCall`、
// `UserMessage`、`LlmDone` 完全平级。reducer 里没有任何 `if kind == 'agent'`
// 这类分支 —— 谁来执行 `AgentRun`（自己调 provider，还是别的什么东西）
// 是**接线**的事，由运行时注入的 effect 表决定。
//
// 环（用 action 名写出来就是全部）：
//
//   UserMessage → AgentRun → LlmStarted → LlmDelta* → LlmDone
//                                              ├─ 无工具 ────────────────→ (idle)
//                                              └─ 有工具 → ToolCall → ToolStart*
//                                                 → ToolResult* → ToolBatchDone → AgentRun
//
// 失败与重试也写在环里：
//
//   LlmFailed（可重试且还有次数）→ 相位仍 thinking → AgentRun（同一个 step 容器内重试）

///|
/// 工具的完整定义 —— 落进 state 后回放不必重跑。
///
/// 只留三样：真正进 LLM 请求的就是这三样。`parameters` 是 JSON schema 文本，
/// 原样透传给 provider。
pub(all) struct PromptToolDefinition {
  name : String
  description : String
  parameters : String
} derive(Eq, Debug)

///|
/// 模型能力（pi-ai `Model` 上那几个 supports* 标志）。
///
/// 只收三个**真正影响本项目行为**的：能不能中途插 system/developer、
/// 能不能中途加工具、支不支持 developer role。
pub(all) struct ModelCapabilities {
  mid_convo_system_messages : Bool
  mid_convo_tool_additions : Bool
  developer_role : Bool
} derive(Eq, Debug)

///|
pub let no_capabilities : ModelCapabilities = {
  mid_convo_system_messages: false,
  mid_convo_tool_additions: false,
  developer_role: false,
}

///|
/// 模型侧一整套参数 —— `ModelInit` 与 `ModelChanged` **共用同一形状**。
///
/// 两条 action 的差别只剩**语义**（装载 vs 切换），不再有「一条只带标识、
/// 另一条才带能力」的分裂。
pub(all) struct ModelSpec {
  provider : String
  model_id : String
  thinking_level : String
  reasoning : Bool
  capabilities : ModelCapabilities
  context_window : Int32
} derive(Eq, Debug)

///|
/// 装载 prompt：已经拼好的那一整段 system prompt + 工具的完整定义。
pub(all) struct PromptInitData {
  system_prompt : String
  tools : Array[PromptToolDefinition]
} derive(Eq, Debug)

///|
/// 用户说了什么。带附件时 `content` 是 text / image 块的混合。
pub(all) struct UserInput {
  text : String
  content : Array[@message.Content]
} derive(Eq, Debug)

///|
/// 排队输入（steer / followUp）。两条队列只差**投递时机**。
pub(all) struct QueuedInputAction {
  text : String
  content : Array[@message.Content]
  kind : @common.QueueKind
} derive(Eq, Debug)

///|
/// 关一步（step）的载荷。
///
/// **不带** `step_index` 之外的派生数字：`attempt` 由 reducer 自己从 state 算，
/// 写在这里等于多一份真相。
pub(all) struct StepEndData {
  step_index : Int32
  status : @trace.TraceNodeStatus
  tool_calls : Int32
} derive(Eq, Debug)

///|
/// 一次 LLM 调用完成。
pub(all) struct LlmDoneData {
  message : @message.AssistantPart
  /// 这次尝试对应的轨迹节点 id（effect 若知道就带上）。
  node_id : String?
} derive(Eq, Debug)

///|
/// LLM 调用失败。`kind` 决定要不要重试；`cause` 是给界面的具体原因。
pub(all) struct LlmFailedData {
  error : String
  kind : @common.LlmErrorKind
  node_id : String?
  cause : @common.StopCause?
} derive(Eq, Debug)

///|
/// 工具执行中的流式增量。
///
/// `content` 是「到目前为止的**全部**输出」，不是 diff —— 界面直接整个替换。
/// 终值由 `ToolResult` 写进 messages，这条只是给界面看的中间态。
pub(all) struct ToolProgressData {
  tool_call_id : String
  content : Array[@message.Content]
} derive(Eq, Debug)

///|
/// 恢复一个已落盘的会话：prompt / model 装载 + 消息 + 轨迹 + 落盘游标，
/// **一次性**写进 state。
///
/// 为什么不拆成 `prompt.init` + 一条条 `user.message`：那样会在轨迹树上重放
/// 一遍历史（节点重复、tip 错位），而且 `begin_trace` 会把装载节点补到错误的位置。
pub(all) struct SessionRestoredData {
  prompt : PromptInitData
  model : ModelSpec
  messages : Array[@message.Message]
  trace : @trace.TraceTree
  persisted_seq : Int32
} derive(Eq, Debug)

///|
/// 清空对话（可选换一个新会话 id）。
pub(all) struct ConversationResetData {
  session_id : String?
} derive(Eq, Debug)

///|
pub(all) enum AgentAction {
  PromptInit(PromptInitData)
  ModelInit(ModelSpec)
  ModelChanged(ModelSpec)
  ThinkingChanged(String)
  /// 人说了什么。相位不是 idle 时被忽略（不排队）。
  UserMessage(UserInput)
  /// 运行中的人输入：空闲时直接转成 UserMessage，否则入队。
  QueueInput(QueuedInputAction)
  /// 一条排队的输入已被取出并组装成 user 消息。
  QueueDelivered(QueuedInputAction)
  /// 清空两条队列（不再投递）。
  QueueClear
  /// 一次用户输入引发的整个回合。
  TurnStart
  TurnEnd
  /// 续跑当前回合（`/continue`）：不插 user 消息，直接开一个新回合。
  TurnContinue
  /// 一次 LLM 调用 + 它触发的工具批次。
  StepStart
  StepEnd(StepEndData)
  /// 跑一轮对话（= 调一次 LLM）。谁执行由 effect 表决定。
  AgentRun(String?)
  LlmStarted
  LlmDelta(String)
  LlmThinking(String)
  LlmDone(LlmDoneData)
  LlmFailed(LlmFailedData)
  /// 重试用尽或不该重试：彻底收工，相位回 idle。
  LlmGiveup(LlmFailedData)
  /// 这些工具调用需要执行。
  ToolCall(Array[@message.ToolCall])
  /// 一个工具开始执行。
  ToolStart(@message.ToolCall)
  ToolProgress(ToolProgressData)
  /// 一个工具出结果。
  ToolResult(@message.ToolResultPart)
  /// 一批工具跑完了。
  ToolBatchDone(Int32)
  /// 轨迹节点已落盘（游标推回来）。
  TracePersisted(Int32)
  /// 从 JSONL 恢复出来的会话。
  SessionRestored(SessionRestoredData)
  /// 清空对话 / 开新会话。
  ConversationReset(ConversationResetData)
} derive(Eq, Debug)

///|
/// action 的类型名（与 `TraceNodeKind` 的名字同一套风格）。
pub fn AgentAction::name(self : AgentAction) -> String {
  match self {
    PromptInit(_) => "prompt.init"
    ModelInit(_) => "model.init"
    ModelChanged(_) => "model.changed"
    ThinkingChanged(_) => "thinking.changed"
    UserMessage(_) => "user.message"
    QueueInput(_) => "queue.input"
    QueueDelivered(_) => "queue.delivered"
    QueueClear => "queue.clear"
    TurnStart => "turn.start"
    TurnEnd => "turn.end"
    TurnContinue => "turn.continue"
    StepStart => "step.start"
    StepEnd(_) => "step.end"
    AgentRun(_) => "agent.run"
    LlmStarted => "llm.started"
    LlmDelta(_) => "llm.delta"
    LlmThinking(_) => "llm.thinking"
    LlmDone(_) => "llm.done"
    LlmFailed(_) => "llm.failed"
    LlmGiveup(_) => "llm.giveup"
    ToolCall(_) => "tool.call"
    ToolStart(_) => "tool/start"
    ToolProgress(_) => "tool.progress"
    ToolResult(_) => "tool.result"
    ToolBatchDone(_) => "tool.batch.done"
    TracePersisted(_) => "trace.persisted"
    SessionRestored(_) => "session.restored"
    ConversationReset(_) => "conversation.reset"
  }
}
