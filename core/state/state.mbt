// 内核状态。
//
// 一条规则：**状态只能由 action 改**。reducer 是纯函数，所以这里的每个字段
// 都必须能从「action 序列 + 初始状态」重算出来 —— 不读时钟、不读环境变量。
// 时间与随机数由调用方以参数形式注入（见 `create_initial_state` 与 `reduce`）。

///|
/// 排队的用户输入。
///
/// 入队的是 text 而不是 Message：附件在装载时折成 content 块，
/// 真要发出去时才组装成消息（见 `QueueDelivered` 的迁移）。
pub(all) struct QueuedInput {
  text : String
  content : Array[@message.Content]
  /// 入队时刻（毫秒）。界面显示「排了多久」用，也是 FIFO 的稳定排序依据。
  at : Int64
} derive(Eq, Debug)

///|
/// 一次正在跑的工具。
pub(all) struct ExecutingTool {
  call : @message.ToolCall
  started_at : Int64
} derive(Eq, Debug)

///|
/// 一个正在跑的工具当前的**中间输出**。
///
/// 不提前写进 `messages`：那是**发给模型的那份历史**，只该有终值。
/// 中间态进去会让消息序列在 Ctrl-C 之后留下一个没有结果的工具调用（协议非法），
/// 也会被落盘器一起写进会话文件。所以中间态只放这里（纯展示），终值才进 messages。
pub(all) struct ToolProgress {
  tool_call_id : String
  content : Array[@message.Content]
} derive(Eq, Debug)

///|
/// 打开中的选择面板（模型 / 思考级别 / 会话）。
pub(all) struct UiPicker {
  kind : @action.UiPickerKind
  title : String
  items : Array[@action.UiPickerItem]
  selected : Int32
} derive(Eq, Debug)

///|
/// 界面的**显示**状态。
///
/// 它进 state 是因为渲染是 state 的纯函数（`render(state)` —— TUI 的每一帧
/// 都从 `agent.state` 画出来），「在哪一页、滚到哪、面板开着没有」也得能从
/// state 重算。它不落盘的原因在 `UiAction`：UI 事件的迁移只碰这一块，
/// 树上没有节点，落盘器就没有东西可写。
pub(all) struct UiState {
  /// 当前页：对话 / 轨迹。
  page : @action.UiPane
  /// 工具输出与压缩摘要展开还是折叠（Ctrl+O）。
  expanded : Bool
  /// 对话页离底部的行数（0 = 跟随底部）。
  chat_scroll : Int32
  /// 轨迹页离底部的行数。
  trace_scroll : Int32
  /// 打开中的面板；None = 没有。
  picker : UiPicker?
} derive(Eq, Debug)

///|
pub fn default_ui_state() -> UiState {
  {
    page: @action.UiChat,
    expanded: false,
    chat_scroll: 0,
    trace_scroll: 0,
    picker: None,
  }
}

///|
/// 最近一次压缩的结果（给界面显示「N 条 → M 条，压掉了多少」）。
///
/// 之所以进 state 而不是让界面自己 diff messages.length：界面 diff 出来的
/// 「少了多少条」在**恢复历史之后**没有意义（那条历史本来就没被压缩过）。
pub(all) struct CompactionRecord {
  reason : @compact.CompactReason
  summarized_count : Int32
  kept_count : Int32
  tokens_before : Int32
} derive(Eq, Debug)

///|
/// prompt 侧状态 —— 与 model 分开装载：「跟模型说什么」vs「用哪个模型说」。
pub(all) struct PromptState {
  /// 基础 system prompt（渲染好的整段）。
  system_prompt : String
  /// **当前**可执行的工具定义（原样进 LLM 请求的那三样）。
  ///
  /// 会话中途可以通过 `tools.changed` 改；执行侧的启用检查读的就是这里。
  tools : Array[@action.PromptToolDefinition]
  /// **装载时**那一批工具定义 —— prompt head 里 `toolsAdded` 用它，永不更新。
  ///
  /// 为什么必须留一份「旧的」：head 是**不可变历史**（前缀缓存靠的就是它一个字节
  /// 不动）。工具集变了之后如果 head 也跟着换，前缀立刻作废。
  head_tools : Array[@action.PromptToolDefinition]?
  /// **已经声明给模型**的那一批（transcript 里的现状）。
  ///
  /// `tools.changed` 只改 `tools`，下一次 `AgentRun` 把差额追加成一条 system
  /// 消息后，这里才跟着更新 —— 于是同一份差额不会每轮重发。
  declared_tools : Array[@action.PromptToolDefinition]
  /// 是否已经装载过。回放时据此判断「init 段读到了没有」。
  seeded : Bool
} derive(Eq, Debug)

///|
/// 模型侧状态 —— 由 `ModelInit` 装载。
pub(all) struct ModelState {
  provider : String
  model_id : String
  /// 当前思考级别；`off` 表示不带 reasoning。
  thinking_level : String
  /// 这个模型支不支持 reasoning。底栏据此决定显不显示思考级别。
  reasoning : Bool
  capabilities : @action.ModelCapabilities
  /// 上下文窗口（token）。不知道就是 0，底栏会不画那个百分比。
  context_window : Int32
  seeded : Bool
} derive(Eq, Debug)

///|
pub(all) struct AgentState {
  phase : @common.Phase
  // ── 会话身份 ──
  session_id : String
  cwd : String
  // ── prompt / model 两块 ──
  prompt : PromptState
  model : ModelState
  /// 下面四个是 prompt / model 常用字段的**扁平别名**，真相在两块里。
  system_prompt : String
  provider_name : String
  model_id : String
  thinking_level : String
  // ── 对话 ──
  /// 对话消息（user / assistant / toolResult / system），LLM 的下一轮输入。
  messages : Array[@message.Message]
  /// 已注册工具名（展示用）。
  tool_names : Array[String]
  /// 本轮流式累积的助手文本。
  streaming_text : String
  /// 本轮流式累积的思考文本。
  thinking_text : String
  /// 每开始一次 LLM 尝试就 +1。UI 靠它识别「又发起了一次调用」。
  stream_seq : Int32
  pending_tool_calls : Array[@message.ToolCall]
  executing : Array[ExecutingTool]
  /// 当前回合内已完成的 LLM 轮数（`UserMessage` 时归零）。
  turns : Int32
  /// 单回合 LLM 调用上限；None = 不设上限。
  ///
  /// 默认不设上限：一次提问就是一条 ReAct 循环，模型要查多少轮由它自己说了算。
  /// 设成 25 那类小值时表现为「模型正干着活突然停了」，而用户只发了一条消息。
  max_turns : Int32?
  /// 当前回合序号，从 1 开始；不在回合里时为 0。
  turn_index : Int32
  /// 当前回合在跑的 step 序号，从 1 开始；不在 step 里时为 0。
  step_index : Int32
  /// 已完成的 step 总数（整个会话，不随回合归零）。
  total_steps : Int32
  // ── 队列 ──
  steer_queue : Array[QueuedInput]
  follow_up_queue : Array[QueuedInput]
  /// 已经「决定要发」但还没真正组装成消息的队列头（在途状态）。
  delivering_input : QueuedInput?
  delivering_as : @common.QueueKind?
  // ── 压缩 ──
  /// 压缩是否正在进行中（摘要要打一次网络，可能好几秒）。
  ///
  /// 界面用它：压缩期间不能发新消息（否则压缩完会把那句话一起换掉）。
  compacting : Bool
  /// 这一次 `compact.request` 是否被迁移接受（守卫失败时为 false）。
  ///
  /// 接线靠它区分「这条 action 开启了压缩」与「压缩中又收到一条请求」——
  /// 只看 `compacting` 的话，第二条请求会让 effect 再跑一遍。
  compact_requested : Bool
  /// 这次压缩的理由（节点 label、失败报告都要它）。
  compact_reason : @compact.CompactReason?
  /// 已经算好的切点；None = 没有可压的内容。effect 直接用它，不再算第二遍。
  compact_plan : @compact.CutPlan?
  /// 正在跑的压缩对应的轨迹节点 id；没有则 None。
  open_compact_node_id : String?
  /// 压缩参数（`settings.json` 的 `compaction` 段或默认值）。
  compact_settings : @compact.Settings
  /// 最近一次压缩的结果。
  last_compaction : CompactionRecord?
  /// 压缩替换过几次 messages。落盘器靠它判断「整份历史变了，要写一条 compact 记录」。
  compaction_epoch : Int32
  // ── 用量 / 错误 ──
  usage : @message.Usage?
  total_cost : Double
  error : String?
  /// 最近一次错误对应的轨迹节点 id。
  error_node_id : String?
  error_kind : @common.LlmErrorKind?
  stop_reason : @common.StopReason?
  stop_cause : @common.StopCause?
  stop_cause_detail : String?
  /// 这次失败正在自动重试（UI 显示「重试中…」）。
  retrying : Bool
  aborted : Bool
  // ── 轨迹 ──
  trace : @trace.TraceTree
  /// 轨迹是否**开过**（用户发出过第一句话）。
  trace_begun : Bool
  /// 树开过之后换过模型 / 思考级别，但还没写进树。
  model_trace_dirty : Bool
  open_llm_node_id : String?
  open_step_node_id : String?
  open_turn_node_id : String?
  /// `open_turn_node_id` 那个容器的序号。用来区分「容器开着」与「旧容器待收尾」。
  open_turn_seq : Int32?
  /// 当前回合里**已经结束**的 step 数（写 turn.end 的标签用）。
  turn_steps : Int32
  /// 当前 step 里**已经完成**的工具数（写 step.end 的标签用）。
  step_tool_calls : Int32
  open_tool_node_ids : @ihm.HashMap[String, String]
  tool_progress : @ihm.HashMap[String, ToolProgress]
  /// 已完成工具的耗时（毫秒），key 是 tool_call_id。
  tool_timings : @ihm.HashMap[String, Int64]
  // ── 界面（只由 UI 事件改；不进轨迹、不落盘） ──
  ui : UiState
  // ── 预算 / 超时 / 落盘 ──
  /// 本轮（从 UserMessage 起）已发起的 LLM 尝试次数。
  llm_attempts : Int32
  /// 单轮内最多几次 LLM 尝试（含首次），2 = 失败后重试一次。
  max_llm_attempts : Int32
  /// 一次 LLM 调用的**空闲**超时（毫秒）：流上这么久没有事件就掐。
  llm_timeout_ms : Int64
  /// 已经落盘到 seq 游标的节点数。
  persisted_seq : Int32
} derive(Debug)

///|
/// 空闲语义而非总时长：卡的是「多久没收到数据」，长生成跑多久都不受限
/// （上游 pi 的 undici bodyTimeout 同语义）。总时长闸会把生成时间恰好
/// 超过阈值的请求变成死循环。
pub let default_llm_timeout_ms : Int64 = 120000L

///|
pub(all) struct InitialStateOptions {
  system_prompt : String
  provider_name : String
  model_id : String
  thinking_level : String
  tool_names : Array[String]
  /// None = 不设上限。
  max_turns : Int32?
  max_llm_attempts : Int32
  llm_timeout_ms : Int64
  session_id : String
  cwd : String
  /// 注入已存在的轨迹（从 JSONL 回放时用）。
  trace : @trace.TraceTree?
} derive(Debug)

///|
pub fn InitialStateOptions::defaults(
  session_id : String,
  cwd : String,
) -> InitialStateOptions {
  {
    system_prompt: "",
    provider_name: "",
    model_id: "",
    thinking_level: "off",
    tool_names: [],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: default_llm_timeout_ms,
    session_id,
    cwd,
    trace: None,
  }
}

///|
pub fn create_initial_state(options : InitialStateOptions) -> AgentState {
  let empty_prompt : PromptState = {
    system_prompt: options.system_prompt,
    tools: [],
    head_tools: None,
    declared_tools: [],
    seeded: false,
  }
  let empty_model : ModelState = {
    provider: options.provider_name,
    model_id: options.model_id,
    thinking_level: options.thinking_level,
    // 装载前不知道：保守地算不支持。ModelInit 会补上真值。
    reasoning: false,
    capabilities: @action.no_capabilities,
    context_window: 0,
    seeded: false,
  }
  let trace = match options.trace {
    Some(trace) => trace
    None => @trace.create_trace_tree(options.session_id)
  }
  {
    phase: @common.Idle,
    session_id: options.session_id,
    cwd: options.cwd,
    prompt: empty_prompt,
    model: empty_model,
    system_prompt: options.system_prompt,
    provider_name: options.provider_name,
    model_id: options.model_id,
    thinking_level: empty_model.thinking_level,
    messages: [],
    tool_names: options.tool_names,
    streaming_text: "",
    thinking_text: "",
    stream_seq: 0,
    pending_tool_calls: [],
    executing: [],
    turns: 0,
    max_turns: options.max_turns,
    turn_index: 0,
    step_index: 0,
    total_steps: 0,
    steer_queue: [],
    follow_up_queue: [],
    delivering_input: None,
    delivering_as: None,
    compacting: false,
    compact_requested: false,
    compact_reason: None,
    compact_plan: None,
    open_compact_node_id: None,
    compact_settings: @compact.default_settings(),
    last_compaction: None,
    compaction_epoch: 0,
    usage: None,
    total_cost: 0.0,
    error: None,
    error_node_id: None,
    error_kind: None,
    stop_reason: None,
    stop_cause: None,
    stop_cause_detail: None,
    retrying: false,
    aborted: false,
    trace,
    trace_begun: false,
    model_trace_dirty: false,
    open_llm_node_id: None,
    open_step_node_id: None,
    open_turn_node_id: None,
    open_turn_seq: None,
    turn_steps: 0,
    step_tool_calls: 0,
    open_tool_node_ids: @ihm.HashMap::new(),
    tool_progress: @ihm.HashMap::new(),
    tool_timings: @ihm.HashMap::new(),
    ui: default_ui_state(),
    llm_attempts: 0,
    max_llm_attempts: options.max_llm_attempts,
    llm_timeout_ms: options.llm_timeout_ms,
    persisted_seq: 0,
  }
}
