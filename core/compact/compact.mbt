// 上下文压缩（compact）—— 长会话撑爆窗口时，把老对话换成一段结构化摘要。
//
// 本文件只做**纯**的事：估 token、找切点、拼摘要消息。判定「该不该压」由
// `core/loop` 的 `decide_compaction` 做，真正打网络写摘要的是 provider 的
// `RunCompact` effect。
//
// 为什么切点算法要照着 pi 写：规则不是我们定的，是踩坑定下来的。
//
//   - **绝不切在 toolResult 上**：它必须跟在它的 toolCall 后面，切错了消息序列
//     就是非法的，provider 直接报错；
//   - 切在一轮中间（切到某轮的 assistant 而不是它的 user）时，另做一段
//     turn-prefix 摘要 —— 否则模型会丢掉「这一轮是谁问的」；
//   - 往回累积到超过 `keep_recent_tokens` 才停，且取离切点最近的合法切点。
//
// 自己另发明一套，症状会是「压缩之后模型突然不知道自己在干嘛」—— 极难归因。

///|
/// 压缩参数。与 pi 的 `compaction` 段同一组键名（两边共用 settings.json）。
pub(all) struct Settings {
  enabled : Bool
  /// 给后续输出留的余量：占用超过 `window - reserve` 就该压了。
  reserve_tokens : Int32
  /// 压缩后要保留的最近多少 token。
  keep_recent_tokens : Int32
} derive(Eq, Debug)

///|
/// pi 的默认值（`DEFAULT_COMPACTION_SETTINGS`）。
pub fn default_settings() -> Settings {
  { enabled: true, reserve_tokens: 16384, keep_recent_tokens: 20000, }
}

///|
/// 按**当前模型的窗口**把参数夹紧。
///
/// 必须夹：判据是 `tokens > window - reserve`，而 pi 的默认 reserve 是 16384，
/// 它面向的模型窗口都在 64k 以上。窗口 1000 时阈值变成 -15384，于是**任何一次
/// 调用都判定为「该压了」**，每轮压一次，白花钱还把对话越压越碎。
///
/// - reserve ≤ 窗口的 20%；
/// - keepRecent ≤ 窗口的 50%（保留的部分必须装得下，否则「压了还是超」死循环）。
///
/// 窗口为 0（不知道）时不夹，沿用配置原值。
pub fn effective_settings(
  settings : Settings,
  context_window : Int32,
) -> Settings {
  if context_window <= 0 {
    return settings
  }
  {
    ..settings,
    reserve_tokens: min_int(settings.reserve_tokens, context_window * 20 / 100),
    keep_recent_tokens: min_int(
      settings.keep_recent_tokens,
      context_window * 50 / 100,
    ),
  }
}

///|
fn min_int(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

// ─── token 估算 ──────────────────────────────────────────────────────────────

///|
/// 一张图按多少字符估（pi 的 `ESTIMATED_IMAGE_CHARS`）。
let estimated_image_chars : Int32 = 4800

///|
fn content_chars(blocks : Array[@message.Content]) -> Int32 {
  let mut chars = 0
  for block in blocks {
    match block {
      @message.Text(text) => chars = chars + text.length()
      @message.Image(_) => chars = chars + estimated_image_chars
      _ => ()
    }
  }
  chars
}

///|
fn assistant_chars(blocks : Array[@message.Content]) -> Int32 {
  let mut chars = 0
  for block in blocks {
    match block {
      @message.Text(text) => chars = chars + text.length()
      @message.Thinking(text) => chars = chars + text.length()
      @message.ToolCallBlock(call) =>
        chars = chars + call.name.length() + call.arguments.length()
      @message.Image(_) => chars = chars + estimated_image_chars
    }
  }
  chars
}

///|
fn system_chars(part : @message.SystemPart) -> Int32 {
  let mut chars = part.content.length()
  for section in part.sections {
    let (key, value) = section
    chars = chars + key.length() + value.length()
  }
  chars
}

///|
/// 一条消息的 token 估算：chars / 4，向上取整（**保守高估**，与 pi 一致）。
///
/// 换一种估法切点就与 pi 不一致 —— 而切点差一条，压缩后模型看到的历史就不同。
pub fn estimate_tokens(message : @message.Message) -> Int32 {
  let chars = match message {
    @message.UserMsg(part) => content_chars(part.content)
    @message.AssistantMsg(part) => assistant_chars(part.content)
    @message.ToolResultMsg(part) => content_chars(part.content)
    @message.SystemMsg(part) => system_chars(part)
  }
  (chars + 3) / 4
}

///|
pub fn estimate_messages_tokens(messages : Array[@message.Message]) -> Int32 {
  let mut total = 0
  for message in messages {
    total = total + estimate_tokens(message)
  }
  total
}

///|
/// 最后一次**有效**调用占掉的上下文 token 数；没有就 None。
///
/// 三个过滤条件照抄 pi 的 `getAssistantUsage`：token>0、非 aborted、非 error
/// （被中断 / 失败那轮的 usage 描述的不是最终请求，用它算占用会得到错的数）。
pub fn last_context_tokens(messages : Array[@message.Message]) -> Int32? {
  let mut index = messages.length() - 1
  while index >= 0 {
    match messages[index] {
      @message.AssistantMsg(part) => {
        let usable = part.stop_reason != "aborted" &&
          part.stop_reason != "error"
        if usable {
          match part.usage {
            Some(usage) => {
              let total = if usage.total_tokens > 0 {
                usage.total_tokens
              } else {
                usage.input_tokens + usage.output_tokens
              }
              if total > 0 {
                return Some(total)
              }
            }
            None => ()
          }
        }
      }
      _ => ()
    }
    index = index - 1
  }
  None
}

// ─── 判定 ────────────────────────────────────────────────────────────────────

///|
/// 为什么这次要压。三条路径与 pi 的 `_checkCompaction` 同一套语义。
pub(all) enum CompactReason {
  /// 用户按了 `/compact`，不看阈值。
  Manual
  /// 占用超过 `window - reserve`。
  Threshold
  /// provider 报了上下文溢出（含「静默溢出」）。
  Overflow
} derive(Eq, Debug)

///|
pub fn CompactReason::name(self : CompactReason) -> String {
  match self {
    Manual => "manual"
    Threshold => "threshold"
    Overflow => "overflow"
  }
}

///|
/// 一个短词（节点 label、界面提示共用，避免两处各写一份文案）。
pub fn CompactReason::text(self : CompactReason) -> String {
  match self {
    Manual => "手动"
    Threshold => "超阈值"
    Overflow => "provider 报溢出"
  }
}

///|
pub fn should_compact(
  context_tokens : Int32,
  context_window : Int32,
  settings : Settings,
) -> Bool {
  if !settings.enabled {
    return false
  }
  context_tokens > context_window - settings.reserve_tokens
}

// ─── 切点 ────────────────────────────────────────────────────────────────────

///|
/// 切点算完了：这次压缩要摘掉前面哪些、留哪些。
pub(all) struct CutPlan {
  /// 摘要覆盖的消息（会被摘掉，换成一条摘要）。
  summarized : Array[@message.Message]
  /// 「被切开的那一轮」开头那几条（另做一段 turn-prefix 摘要）。
  turn_prefix : Array[@message.Message]
  /// 保留的尾巴（从 `first_kept` 开始）。
  kept : Array[@message.Message]
  /// 切点落在轮次中间（于是有 turn_prefix）。
  is_split_turn : Bool
  /// 压缩前的估算 token 数。
  tokens_before : Int32
} derive(Eq, Debug)

///|
fn is_cut_point(message : @message.Message) -> Bool {
  match message {
    @message.UserMsg(_) | @message.AssistantMsg(_) => true
    _ => false
  }
}

///|
fn is_turn_start(message : @message.Message) -> Bool {
  match message {
    @message.UserMsg(_) => true
    _ => false
  }
}

///|
fn copy_range(
  items : Array[@message.Message],
  start : Int32,
  end : Int32,
) -> Array[@message.Message] {
  let out : Array[@message.Message] = []
  let mut index = start
  while index < end {
    out.push(items[index])
    index = index + 1
  }
  out
}

///|
fn first_point_at_or_after(points : Array[Int32], index : Int32) -> Int32 {
  for point in points {
    if point >= index {
      return point
    }
  }
  points[points.length() - 1]
}

///|
/// 算切点：保留最近约 `keep_recent_tokens`，前面交给摘要。
///
/// 算法（pi 的 `findCutPoint`，退化到消息序列）：从最新往回累积估算大小，
/// 攒够预算就停在**离它最近的合法切点**上。在 toolResult 之前停不下 ——
/// 它不是合法切点。
///
/// @returns None = 没有值得压的东西（消息太少 / 切点找不到 / 会留下孤儿 toolResult）。
pub fn plan_cut(
  messages : Array[@message.Message],
  keep_recent_tokens : Int32,
) -> CutPlan? {
  let count = messages.length()
  if count == 0 {
    return None
  }
  let points : Array[Int32] = []
  for index in 0..<count {
    if is_cut_point(messages[index]) {
      points.push(index)
    }
  }
  if points.is_empty() {
    return None
  }
  // 默认从第一条合法切点开始保留。
  let mut cut_index = points[0]
  let mut accumulated = 0
  let mut index = count - 1
  while index >= 0 {
    let tokens = estimate_tokens(messages[index])
    if tokens > 0 {
      accumulated = accumulated + tokens
      if accumulated >= keep_recent_tokens {
        cut_index = first_point_at_or_after(points, index)
        break
      }
    }
    index = index - 1
  }
  let starts_turn = is_turn_start(messages[cut_index])
  let mut turn_start = -1
  if !starts_turn {
    let mut cursor = cut_index
    while cursor >= 0 {
      if is_turn_start(messages[cursor]) {
        turn_start = cursor
        break
      }
      cursor = cursor - 1
    }
  }
  let is_split_turn = !starts_turn && turn_start >= 0
  let history_end = if is_split_turn { turn_start } else { cut_index }
  // 没有历史可摘（整个会话就等于要保留的那点尾巴）：压了等于没压，还白花一次 token。
  if history_end <= 0 {
    return None
  }
  let kept = copy_range(messages, cut_index, count)
  // 摘要之后不能留一个孤儿 toolResult：它的 toolCall 已经被摘进摘要里了。
  if !kept.is_empty() {
    match kept[0] {
      @message.ToolResultMsg(_) => return None
      _ => ()
    }
  }
  let summarized = copy_range(messages, 0, history_end)
  let turn_prefix = if is_split_turn {
    copy_range(messages, turn_start, cut_index)
  } else {
    []
  }
  // 被摘的那一段里得真有对话。否则（比如头一条就是中途插入的 system 声明）
  // 压了只会得到一条空摘要：对话没变短，还白花一次调用。
  if !has_conversation(summarized) && !has_conversation(turn_prefix) {
    return None
  }
  Some({
    summarized,
    turn_prefix,
    kept,
    is_split_turn,
    tokens_before: estimate_messages_tokens(messages),
  })
}

///|
fn has_conversation(messages : Array[@message.Message]) -> Bool {
  for message in messages {
    match message {
      @message.UserMsg(_) | @message.AssistantMsg(_) => return true
      _ => ()
    }
  }
  false
}

// ─── 摘要消息 ────────────────────────────────────────────────────────────────

///|
/// 摘要消息的包裹标记（与 pi 逐字一致：下游靠它认出「这是压缩点」）。
pub let summary_prefix : String = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"

///|
pub let summary_suffix : String = "\n</summary>"

///|
/// 拼出那条摘要消息。
///
/// 做成**一条消息**而不是 `state.summary`：对话历史只有一条真相 —— 下一轮
/// 请求就是把 `messages` 交给 provider。另开字段就得同时改请求、落盘、回放
/// 三处，各留一条「别忘了带上摘要」的隐式约定。
pub fn build_summary_message(
  summary : String,
  tokens_before : Int32,
  timestamp : Int64,
) -> @message.Message {
  @message.UserMsg({
    content: [@message.Text(summary_prefix + summary + summary_suffix)],
    timestamp,
    compaction_summary: true,
    tokens_before,
  })
}

///|
/// 一条消息是不是压缩摘要。
///
/// 用结构标记，不靠「内容长得像 `<summary>`」去猜 —— 用户完全可能手打一段
/// 一模一样的文本，而把那句当成压缩点会让回放丢掉真历史。
pub fn is_summary_message(message : @message.Message) -> Bool {
  match message {
    @message.UserMsg(part) => part.compaction_summary
    _ => false
  }
}

///|
/// 摘要正文（去掉包裹标记）。不是摘要消息返回 None。
pub fn summary_body(message : @message.Message) -> String? {
  match message {
    @message.UserMsg(part) =>
      if !part.compaction_summary {
        None
      } else {
        let text = @message.contents_text(part.content)
        if text.has_prefix(summary_prefix) && text.has_suffix(summary_suffix) {
          Some(
            text[summary_prefix.length():text.length() - summary_suffix.length()].to_owned(),
          )
        } else {
          Some(text)
        }
      }
    _ => None
  }
}

///|
/// 尾巴里已经有过摘要就把它当 previous-summary（迭代压缩，不从零开始）。
pub fn last_summary_text(messages : Array[@message.Message]) -> String? {
  let mut index = messages.length() - 1
  while index >= 0 {
    match summary_body(messages[index]) {
      Some(text) => return Some(text)
      None => ()
    }
    index = index - 1
  }
  None
}

// ─── 摘要里附带的文件清单 ────────────────────────────────────────────────────

///|
/// 从一条工具调用的 arguments 里取 `path`（read / write / edit 都用这个键）。
fn tool_call_path(call : @message.ToolCall) -> String? {
  let json = @json.parse(call.arguments) catch { _ => return None }
  match json {
    Object(obj) =>
      match obj.get("path") {
        Some(String(path)) => Some(path)
        _ => None
      }
    _ => None
  }
}

///|
/// 摘出「读过哪些文件、改过哪些文件」。
///
/// 这两张清单附在摘要末尾，是 pi 的摘要格式的一部分：压缩之后模型仍要知道
/// 「这个会话碰过什么文件」，否则它接手时得把所有文件再读一遍。
pub fn file_lists(
  messages : Array[@message.Message],
) -> (Array[String], Array[String]) {
  let read : Array[String] = []
  let modified : Array[String] = []
  for message in messages {
    for call in message.tool_calls() {
      let path = match tool_call_path(call) {
        Some(path) => path
        None => continue
      }
      if path.is_empty() {
        continue
      }
      match call.name {
        "read" => if !read.contains(path) { read.push(path) }
        "write" | "edit" => if !modified.contains(path) { modified.push(path) }
        _ => ()
      }
    }
  }
  // 只读清单要扣掉改过的文件（pi 的 `computeFileLists` 同口径）：
  // 既读过又改过的文件，模型该当成「改过」，而不是「只读过」。
  let read_only : Array[String] = []
  for path in read {
    if !modified.contains(path) {
      read_only.push(path)
    }
  }
  (read_only, modified)
}

///|
/// 把文件清单拼成 pi 的 `<read-files>` / `<modified-files>` 段。
pub fn format_file_operations(
  read : Array[String],
  modified : Array[String],
) -> String {
  let sections : Array[String] = []
  if !read.is_empty() {
    sections.push("<read-files>\n" + read.join("\n") + "\n</read-files>")
  }
  if !modified.is_empty() {
    sections.push(
      "<modified-files>\n" + modified.join("\n") + "\n</modified-files>",
    )
  }
  if sections.is_empty() {
    ""
  } else {
    "\n\n" + sections.join("\n\n")
  }
}
