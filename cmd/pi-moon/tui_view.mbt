// 把状态翻成屏幕上的行，再按 ela / pi 的分区拼成一帧。
//
// 布局只有三段（与 ela 的 `applyLayout()` 同形）：
//
//   顶行      页签 + 轨迹统计（一行，兼两职）
//   中间      当前页（对话 / 轨迹），唯一可伸缩的区域，无边框
//   底部     队列面板（0..n 行）→ 空隙(1) → composer(3) → 底栏(2)
//
// **没有自造的对话区边框、也没有单独的标题栏**：ela 把模型名放在底栏第二行，
// 把「我在哪页 / 跑到哪一步」压在顶行，理由是对话区的高度比装饰重要。
//
// 颜色取 pi 的分类（userMessageBg / toolSuccessBg / …）。**底色的具体值跟着
// 终端能力变**：24-bit 终端用 pi dark 主题的原值，只有 256 色时退回 16 色名字
// —— 量化会把 pi 那几块很暗的底色压成同一个格子（详见 `tui_color.mbt`）。

///|
/// 顶行之外的固定高度：空隙(1) + composer(3) + 底栏(2)。
let fixed_bottom_rows : Int32 = 6

///|
/// 中间那块（当前页）能占多少行。
pub fn page_height(height : Int32, queue_rows : Int32) -> Int32 {
  let available = height - 1 - queue_rows - fixed_bottom_rows
  if available < 3 {
    3
  } else {
    available
  }
}

///|
/// 对话页的行。`cards` 是命令反馈卡（ela 的 `statusCards`：钉在对话流里，
/// 不在底栏）；每张卡的 `at` 说它插在第几条消息之后。
pub fn chat_lines(
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
  cards : Array[StatusCard],
  banner : Array[String],
  palette~ : Palette = Palette::ansi256(),
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  // 启动横幅在最前：黄色段落标题 + 灰色内容，随对话一起滚。
  for block in banner {
    let (head, rest) = match block.find(" ") {
      Some(index) => (block[:index].to_owned(), block[index + 1:].to_owned())
      None => (block, "")
    }
    out.push(styled_line(" " + head, palette.warning, bold=true))
    for line in wrap_text(rest, width - 4) {
      out.push(styled_line("   " + line, palette.dim))
    }
  }
  if !banner.is_empty() {
    out.push(blank_line())
  }
  push_cards(out, cards, 0, width, palette)
  let mut index = 0
  for message in state.messages {
    message_lines(message, state, expanded, width, out, palette)
    index = index + 1
    push_cards(out, cards, index, width, palette)
  }
  // 正在流的那一轮：思考在上、正文在下（与模型说出来之前的顺序一致）。
  if state.phase != @common.Idle {
    if !state.thinking_text.is_empty() {
      push_inset_block(out, state.thinking_text, width, palette.muted)
      out.push(blank_line())
    }
    if !state.streaming_text.is_empty() {
      // 流式期间与完成后同一套 markdown 排版：每个 delta 全量重 parse +
      // 渲染（pi 的做法），半截闭合围栏由 trim_partial_closing_fence 压住。
      push_markdown_block(out, state.streaming_text, width, "", palette.md)
      append_streaming_cursor(out)
      out.push(blank_line())
    }
  }
  if state.compacting {
    push_inset_block(out, "压缩中…", width, palette.muted)
    out.push(blank_line())
  }
  // 锚点超过当前消息数的卡（理论上不该有）兜底画在最后，总比消失强。
  push_cards_beyond(out, cards, state.messages.length(), width, palette)
  out
}

///|
/// `at == 当前条数` 的卡已经在消息循环里画过了；这里只补「锚点更靠后」的，
/// 否则消息为空 / 刚结束时同一张卡会画两遍。
fn push_cards_beyond(
  out : Array[StyledLine],
  cards : Array[StatusCard],
  at : Int32,
  width : Int32,
  palette : Palette,
) -> Unit {
  for card in cards {
    if card.at > at {
      for line in wrap_text(card.text, width - 2) {
        out.push(styled_line(" " + line, palette.dim))
      }
      out.push(blank_line())
    }
  }
}

///|
fn push_cards(
  out : Array[StyledLine],
  cards : Array[StatusCard],
  at : Int32,
  width : Int32,
  palette : Palette,
) -> Unit {
  for card in cards {
    if card.at == at {
      for line in wrap_text(card.text, width - 2) {
        out.push(styled_line(" " + line, palette.dim))
      }
      out.push(blank_line())
    }
  }
}

///|
fn message_lines(
  message : @message.Message,
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
  palette : Palette,
) -> Unit {
  match message {
    @message.UserMsg(part) =>
      if part.compaction_summary {
        compaction_block(part, expanded, width, out, palette)
        out.push(blank_line())
      } else {
        let body = @message.contents_text(part.content)
        push_bg_markdown(out, body, width, "", palette.user_bg, palette.md)
        out.push(blank_line())
      }
    @message.AssistantMsg(part) => {
      for block in part.content {
        match block {
          @message.Text(text) =>
            if !text.trim(chars=" \t\r\n").is_empty() {
              push_markdown_block(out, text, width, "", palette.md)
              out.push(blank_line())
            }
          @message.Thinking(text) =>
            if !text.trim(chars=" \t\r\n").is_empty() {
              push_inset_block(out, text, width, palette.muted)
              out.push(blank_line())
            }
          @message.ToolCallBlock(call) => {
            tool_block(
              call,
              find_result(state, call.id),
              state,
              expanded,
              width,
              out,
              palette,
            )
            out.push(blank_line())
          }
          @message.Image(url) => {
            // 终端里画不了图，但不能整块消失：给一行占位（回放带附件的
            // 会话时尤其重要，否则历史里那部分结果看起来像被裁掉）。
            let label = if url.has_prefix("data:") {
              let mime = match url.find(";") {
                Some(at) => url[5:at]
                None => "data"
              }
              "[image " + mime.to_owned() + "]"
            } else {
              "[image " + url + "]"
            }
            push_inset_block(out, label, width, palette.muted)
            out.push(blank_line())
          }
        }
      }
      // 用户中断：ela 的 `stopNoticeLine` 在正文后面补一行错误色。
      // toolCall 已经在 provider 侧剥掉了，这里不必再判。
      if part.stop_reason == "aborted" {
        out.push(blank_line())
        push_inset_block(out, "[已中断]", width, palette.error)
        out.push(blank_line())
      }
      match part.error_message {
        Some(error) => {
          push_inset_block(out, error, width, palette.error)
          out.push(blank_line())
        }
        None => ()
      }
    }
    @message.ToolResultMsg(part) =>
      // 工具块已经在 assistant 消息里连同调用画过了；只有找不到那次调用的
      // 结果（旧会话回放、或调用消息被裁掉）才单独画一块。参数拿不到，
      // 按空参数走通用形状。
      if !call_was_rendered(state, part.tool_call_id) {
        let bg = if part.is_error {
          palette.tool_error_bg
        } else {
          palette.tool_success_bg
        }
        let orphan : @message.ToolCall = {
          id: part.tool_call_id,
          name: part.tool_name,
          arguments: "",
        }
        let render = tool_render(
          orphan,
          Some(part),
          "",
          None,
          expanded,
          state.cwd,
          width,
          palette,
        )
        push_bg_block_lines(out, render, bg, width, palette)
        out.push(blank_line())
      }
    @message.SystemMsg(part) => {
      // 中途的工具声明是给模型看的，不是给用户看的：只留一行标记。
      if part.source == Some("tools") {
        out.push(styled_line(" 〔工具集已更新〕", palette.dim))
      } else {
        out.push(
          styled_line(
            " 〔" + truncate_to(part.content, width - 3) + "〕",
            palette.dim,
          ),
        )
      }
      out.push(blank_line())
    }
  }
}

///|
fn compaction_block(
  part : @message.UserPart,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
  palette : Palette,
) -> Unit {
  let body = @message.contents_text(part.content)
  let head : Array[String] = ["[compaction]"]
  if expanded {
    head.push("")
    for line in wrap_text(body, width - 2) {
      head.push(line)
    }
  } else {
    head.push(
      "Compacted from " +
      part.tokens_before.to_string() +
      " tokens (Ctrl+O to expand)",
    )
  }
  push_bg_block(out, head, width, palette.muted, palette.compaction_bg)
}

///|
/// 一次工具调用的块：标题 + 参数 + 结果。形状照 pi 的 `ToolExecutionComponent`：
/// 前面一个空行、块内左右各留一格、底色按 pending / success / error 切换。
fn tool_block(
  call : @message.ToolCall,
  result : @message.ToolResultPart?,
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
  palette : Palette,
) -> Unit {
  let bg = match result {
    Some(part) =>
      if part.is_error {
        palette.tool_error_bg
      } else {
        palette.tool_success_bg
      }
    None => palette.tool_pending_bg
  }
  // 还在跑：显示进度输出的尾部（与 bash 的保留口径一致）。
  let progress = match state.tool_progress.get(call.id) {
    Some(progress) => @message.contents_text(progress.content)
    None => ""
  }
  let render = tool_render(
    call,
    result,
    progress,
    state.tool_timings.get(call.id),
    expanded,
    state.cwd,
    width,
    palette,
  )
  push_bg_block_lines(out, render, bg, width, palette)
}

///|
/// 把 tool_render 的结果画成带底色的块：标题加粗（pi 的 toolTitle），
/// 正文行可以自带前景色（edit 的 diff 三色），提示行用 dim。
fn push_bg_block_lines(
  out : Array[StyledLine],
  block : ToolBlock,
  bg : String,
  width : Int32,
  palette : Palette,
) -> Unit {
  out.push(pad_line("", palette.muted, Some(bg), width))
  out.push({
    text: pad_to_width(" " + block.title, width),
    fg: Some(palette.muted),
    bg: Some(bg),
    bold: true,
    spans: None,
  })
  for line in block.lines {
    let fg = match line.fg {
      Some(fg) => fg
      None => palette.muted
    }
    out.push(pad_line("  " + line.text, fg, Some(bg), width))
  }
  if !block.hint.is_empty() {
    out.push(pad_line("  " + block.hint, palette.dim, Some(bg), width))
  }
  out.push(pad_line("", palette.muted, Some(bg), width))
}

///|
/// 带底色的块：上下各一条同色空行（pi 的 `Box` padding=1），每行左右各留一格。
fn push_bg_block(
  out : Array[StyledLine],
  lines : Array[String],
  width : Int32,
  fg : String,
  bg : String,
) -> Unit {
  out.push(pad_line("", fg, Some(bg), width))
  for line in lines {
    out.push(pad_line(" " + line, fg, Some(bg), width))
  }
  out.push(pad_line("", fg, Some(bg), width))
}

///|
/// 带 markdown 样式的助手正文：左边留一格（pi 的 Markdown `paddingX=1`）。
fn push_markdown_block(
  out : Array[StyledLine],
  text : String,
  width : Int32,
  fg : String,
  colors : MarkdownColors,
) -> Unit {
  for line in markdown_lines(trim_partial_closing_fence(text), width - 2, colors~) {
    out.push(prefixed_markdown_line(line, " ", fg, None, width))
  }
}

///|
/// 流式光标：接到最后一条内容行行尾。█ 不能再拼进文本里（会干扰解析），
/// 渲染完之后补在行尾。
fn append_streaming_cursor(out : Array[StyledLine]) -> Unit {
  let mut index = out.length() - 1
  while index >= 0 && out[index].text.is_empty() {
    index = index - 1
  }
  if index < 0 {
    return
  }
  let line = out[index]
  let spans : Array[MarkdownSpan] = match line.spans {
    Some(inner) => {
      let copy : Array[MarkdownSpan] = []
      for span in inner {
        copy.push(span)
      }
      copy
    }
    None => [{ text: line.text, fg: line.fg, bold: line.bold, inverse: false }]
  }
  spans.push({ text: "█", fg: None, bold: false, inverse: false })
  out[index] = { ..line, text: line.text + "█", spans: Some(spans) }
}

///|
/// 带底色的 markdown（用户消息）：上下各一条同色空行，内容左留一格。
fn push_bg_markdown(
  out : Array[StyledLine],
  text : String,
  width : Int32,
  fg : String,
  bg : String,
  colors : MarkdownColors,
) -> Unit {
  out.push(pad_line("", fg, Some(bg), width))
  for line in markdown_lines(text, width - 2, colors~) {
    out.push(prefixed_markdown_line(line, " ", fg, Some(bg), width))
  }
  out.push(pad_line("", fg, Some(bg), width))
}

///|
/// 给 markdown 行加前缀与底色：行内 span 保留，前缀自己当一段（不抢正文颜色）。
fn prefixed_markdown_line(
  line : StyledLine,
  prefix : String,
  fg : String,
  bg : String?,
  width : Int32,
) -> StyledLine {
  if line.text.is_empty() {
    return pad_line("", fg, bg, width)
  }
  let spans : Array[MarkdownSpan] = [
    {
      text: prefix,
      fg: if fg.is_empty() {
        None
      } else {
        Some(fg)
      },
      bold: false,
      inverse: false,
    },
  ]
  match line.spans {
    Some(inner) =>
      for span in inner {
        spans.push(span)
      }
    None => spans.push({ text: line.text, fg: line.fg, bold: line.bold, inverse: false })
  }
  { text: prefix + line.text, fg: None, bg, bold: false, spans: Some(spans), }
}

///|
/// composer 输入行：输入文字用主题正文色，光标块单独用 accent 色。
///
/// fg 留空会落到渲染器的默认前景（vendor/tui 的默认是纯白），浅色终端里
/// 白字打在白底上，光标就看不见了 —— 颜色必须显式给。
fn composer_line(
  input : String,
  cursor : Int32,
  width : Int32,
  palette : Palette,
) -> StyledLine {
  let chars = render_editor(input, cursor, width).to_array()
  let before : Array[Char] = []
  let after : Array[Char] = []
  let mut seen_caret = false
  for ch in chars {
    if ch == '█' {
      seen_caret = true
    } else if seen_caret {
      after.push(ch)
    } else {
      before.push(ch)
    }
  }
  let before_text = String::from_array(before)
  let after_text = String::from_array(after)
  let spans : Array[MarkdownSpan] = []
  if before_text.length() > 0 {
    spans.push({ text: before_text, fg: Some(palette.text), bold: false, inverse: false })
  }
  // 光标 = 反色空格（SGR 7）。不用 █：反色会把字形颜色换成原背景色，
  // 满格字形在浅色终端上会和底色融为一体；空格让 cell 只露反色背景 ——
  // 浅底上是黑块，深底上是亮块，与 pi 的假光标同款。
  spans.push({ text: " ", fg: None, bold: false, inverse: true })
  if after_text.length() > 0 {
    spans.push({ text: after_text, fg: Some(palette.text), bold: false, inverse: false })
  }
  {
    text: before_text + " " + after_text,
    fg: None,
    bg: None,
    bold: false,
    spans: Some(spans),
  }
}

///|
fn pad_line(
  text : String,
  fg : String,
  bg : String?,
  width : Int32,
) -> StyledLine {
  {
    text: pad_to_width(text, width),
    fg: if fg.is_empty() {
      None
    } else {
      Some(fg)
    },
    bg,
    bold: false,
    spans: None,
  }
}

///|
fn find_result(
  state : @state.AgentState,
  tool_call_id : String,
) -> @message.ToolResultPart? {
  for message in state.messages {
    match message {
      @message.ToolResultMsg(part) =>
        if part.tool_call_id == tool_call_id {
          return Some(part)
        }
      _ => ()
    }
  }
  None
}

///|
fn call_was_rendered(state : @state.AgentState, tool_call_id : String) -> Bool {
  for message in state.messages {
    for call in message.tool_calls() {
      if call.id == tool_call_id {
        return true
      }
    }
  }
  false
}

///|
/// 轨迹页的行：直接吃 `core/trace` 的结构化行（lazygit 形状是那边定的）。
pub fn trace_lines(
  state : @state.AgentState,
  width : Int32,
  palette~ : Palette = Palette::ansi256(),
) -> Array[StyledLine] {
  let rows = @trace.trace_rows(state.trace, max_width=width - 2)
  let out : Array[StyledLine] = []
  if rows.is_empty() {
    out.push(styled_line(" （轨迹为空）", palette.dim))
    return out
  }
  for row in rows {
    let fg = match row.node.status {
      @trace.Errored => palette.error
      @trace.Aborted => palette.warning
      _ => ""
    }
    out.push(pad_line(" " + row.text, fg, None, width))
  }
  out
}

///|
/// 从底部取一屏：`scroll` 是「往上翻了几行」，0 = 跟随最新。
pub fn visible_lines(
  lines : Array[StyledLine],
  height : Int32,
  scroll : Int32,
) -> Array[StyledLine] {
  if height <= 0 {
    return []
  }
  let max_scroll = if lines.length() > height {
    lines.length() - height
  } else {
    0
  }
  let offset = clamp_int(scroll, 0, max_scroll)
  let start = lines.length() - height - offset
  let out : Array[StyledLine] = []
  let mut index = if start > 0 { start } else { 0 }
  while index < lines.length() && out.length() < height {
    out.push(lines[index])
    index = index + 1
  }
  // 内容不满一屏时补空行：中间那块高度固定，不然上一帧的尾巴会留在屏幕上。
  while out.length() < height {
    out.push(blank_line())
  }
  out
}

///|
fn clamp_int(value : Int32, low : Int32, high : Int32) -> Int32 {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// 队列面板（ela 的 `renderQueuePanel`）：空队列时一行都不占。
pub fn queue_lines(
  state : @state.AgentState,
  width : Int32,
  palette~ : Palette = Palette::ansi256(),
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  if state.steer_queue.is_empty() && state.follow_up_queue.is_empty() {
    return out
  }
  out.push(blank_line())
  for item in state.steer_queue {
    out.push(
      styled_line(queue_row("Steering: ", item.text, width), palette.dim),
    )
  }
  for item in state.follow_up_queue {
    out.push(
      styled_line(queue_row("Follow-up: ", item.text, width), palette.dim),
    )
  }
  out.push(styled_line(" ↳ Ctrl+U 取回排队消息", palette.dim))
  out
}

///|
fn queue_row(prefix : String, text : String, width : Int32) -> String {
  let room = if width - 1 - display_width(prefix) > 8 {
    width - 1 - display_width(prefix)
  } else {
    8
  }
  " " + prefix + truncate_to(one_line(text), room)
}

///|
/// 顶行：页签 + 轨迹统计（与 ela 的 `tabLine` 同形）。
///
/// `对话 │ 轨迹 3轮2步  工具5  重试1  错误1 (Ctrl+R)`
pub fn tab_nodes(
  state : @state.AgentState,
  page : @action.UiPane,
  width : Int32,
  palette~ : Palette = Palette::ansi256(),
) -> Array[@vnode.TuiNode] {
  let stats = @trace.trace_stats(state.trace)
  let nodes : Array[@vnode.TuiNode] = []
  let mut used : Int32 = 0
  if page == @action.UiChat {
    nodes.push(@vnode.text("对话", fg=palette.accent, bold=true))
    used = used + 4
    nodes.push(@vnode.text(" "))
    used = used + 1
    nodes.push(@vnode.text("│ 轨迹", fg=palette.dim))
    used = used + 4
  } else {
    nodes.push(@vnode.text("对话", fg=palette.dim))
    used = used + 4
    nodes.push(@vnode.text(" "))
    used = used + 1
    nodes.push(@vnode.text("│ 轨迹", fg=palette.accent, bold=true))
    used = used + 4
  }
  let bits : Array[(String, String)] = []
  if stats.turns > 0 || stats.steps > 0 {
    bits.push(
      (stats.turns.to_string() + "轮" + stats.steps.to_string() + "步", ""),
    )
  }
  if stats.tool_calls > 0 {
    bits.push(("工具" + stats.tool_calls.to_string(), palette.dim))
  }
  if stats.retries > 0 {
    bits.push(("重试" + stats.retries.to_string(), palette.dim))
  }
  if stats.errors > 0 {
    bits.push(("错误" + stats.errors.to_string(), palette.error))
  }
  let mut bit_index = 0
  for bit in bits {
    let (text, color) = bit
    // ela 的 `tabLine`：第一个统计前一个空格，后面每段两个空格。
    let gap = if bit_index == 0 { " " } else { "  " }
    nodes.push(@vnode.text(gap))
    used = used + display_width(gap)
    nodes.push(color_node(text, color))
    used = used + display_width(text)
    bit_index = bit_index + 1
  }
  let tail_gap = if bits.is_empty() { " " } else { "  " }
  nodes.push(@vnode.text(tail_gap))
  used = used + display_width(tail_gap)
  nodes.push(@vnode.text("(Ctrl+R)", fg=palette.dim))
  used = used + 8
  let filler = if width > used { width - used } else { 0 }
  nodes.push(@vnode.text(spaces(filler)))
  nodes
}

///|
fn color_node(text : String, color : String) -> @vnode.TuiNode {
  if color.is_empty() {
    @vnode.text(text)
  } else {
    @vnode.text(text, fg=color)
  }
}

///|
/// 底栏两行（ela 的 `FOOTER_ROWS = 2`）：
///
/// ```text
/// ~\projects\pi-moon
/// ↑1.3k ↓2  0.1%/1.0M (auto)                 (workbuddy) cn:deepseek-v4.1-flash • thinking off
/// ```
pub fn footer_lines(
  state : @state.AgentState,
  width : Int32,
  palette~ : Palette = Palette::ansi256(),
) -> Array[StyledLine] {
  let cwd = shorten_home(state.cwd, home_dir())
  let model = model_line(state)
  [
    pad_line(cwd, palette.dim, None, width),
    pad_line(
      two_column(stats_line(state), model, width),
      palette.dim,
      None,
      width,
    ),
  ]
}

///|
fn model_line(state : @state.AgentState) -> String {
  let base = "(" + state.provider_name + ") " + state.model_id
  if !state.model.reasoning {
    return base
  }
  let level = if state.thinking_level.is_empty() {
    "off"
  } else {
    state.thinking_level
  }
  if level == "off" {
    base + " • thinking off"
  } else {
    base + " • " + level
  }
}

///|
fn stats_line(state : @state.AgentState) -> String {
  let mut input : Int32 = 0
  let mut output : Int32 = 0
  for message in state.messages {
    match message {
      @message.AssistantMsg(part) =>
        match part.usage {
          Some(usage) => {
            input = input + usage.input_tokens
            output = output + usage.output_tokens
          }
          None => ()
        }
      _ => ()
    }
  }
  let parts : Array[String] = []
  if input > 0 {
    parts.push("↑" + format_tokens(input))
  }
  if output > 0 {
    parts.push("↓" + format_tokens(output))
  }
  if state.total_cost > 0.0 {
    parts.push("$" + three_decimals(state.total_cost))
  }
  let window = state.model.context_window
  if window > 0 {
    match state.usage {
      Some(usage) => {
        let percent = usage.total_tokens.to_double() /
          window.to_double() *
          100.0
        let auto = if state.compact_settings.enabled { " (auto)" } else { "" }
        parts.push(format_percent(percent) + "/" + format_tokens(window) + auto)
      }
      None => ()
    }
  }
  parts.join(" ")
}

///|
fn three_decimals(value : Double) -> String {
  let thousandths = (value * 1000.0).round().to_int()
  let whole = thousandths / 1000
  let frac = thousandths % 1000
  let frac_text = if frac < 10 {
    "00" + frac.to_string()
  } else if frac < 100 {
    "0" + frac.to_string()
  } else {
    frac.to_string()
  }
  whole.to_string() + "." + frac_text
}

///|
fn home_dir() -> String {
  let env = @env.get_env_vars()
  match env.get("USERPROFILE") {
    Some(value) => value
    None =>
      match env.get("HOME") {
        Some(value) => value
        None => ""
      }
  }
}

///|
/// composer 上框线：工作状态嵌在横线里（pi 的 `embedWorkingStatus`）。
///
/// ```text
/// ── ⠋ 思考中… ────────────────────────────────────────────────
/// ```
pub fn editor_top_border(
  state : @state.AgentState,
  width : Int32,
  now : Int64,
  palette~ : Palette = Palette::ansi256(),
) -> StyledLine {
  let color = palette.thinking_color(state.thinking_level)
  let status = working_status_text(state, now)
  match status {
    None => pad_line(rule(width), color, None, width)
    Some(text) => {
      let status_width = display_width(text)
      if width >= status_width + 5 {
        pad_line(
          "── " + text + " " + rule(width - status_width - 4),
          color,
          None,
          width,
        )
      } else {
        pad_line(rule(width), color, None, width)
      }
    }
  }
}

///|
fn working_status_text(state : @state.AgentState, now : Int64) -> String? {
  if state.retrying {
    return Some(
      "↻ 正在重试（第 " +
      (state.llm_attempts + 1).to_string() +
      "/" +
      state.max_llm_attempts.to_string() +
      " 次尝试）",
    )
  }
  if state.compacting {
    return Some("压缩中…")
  }
  if state.phase != @common.Idle {
    return Some(spinner_frame(now) + " 思考中…")
  }
  None
}

///|
fn spinner_frame(now : Int64) -> String {
  let frames = [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
  ]
  let index = (now / 120L % 10L).to_int()
  frames[index]
}

///|
/// 整个界面。
///
/// 面板开着时，它**覆盖 composer 那一块**（ela 的选择器：整行宽、底边落在
/// composer 底边），对话页相应变矮。队列与 composer 都不画。
pub fn tui_view(tui : TuiState, state : @state.AgentState) -> @vnode.TuiNode {
  let width = tui.width
  let height = tui.height
  // 界面显示状态（哪一页、滚到哪、面板开着没有）全在 state.ui：
  // 这一帧是 state 的纯函数，TUI 只贡献终端尺寸与输入缓冲这类本地细节。
  let panel = picker_rows(tui, state, width, height, palette=tui.palette)
  let has_panel = !panel.is_empty()
  let mut queue = if has_panel {
    []
  } else {
    queue_lines(state, width, palette=tui.palette)
  }
  // 太矮的终端：先牺牲队列面板（内容还在环上，不会丢），保证 composer 与
  // 底栏这两块不飞出屏幕。
  let page_budget = height - 1 - fixed_bottom_rows
  if page_budget - queue.length() < 3 {
    queue = []
  }
  let page = if state.ui.page == @action.UiChat {
    chat_lines(
      state,
      state.ui.expanded,
      width,
      tui.cards,
      tui.banner,
      palette=tui.palette,
    )
  } else {
    trace_lines(state, width, palette=tui.palette)
  }
  let scroll = if state.ui.page == @action.UiChat {
    state.ui.chat_scroll
  } else {
    state.ui.trace_scroll
  }
  let page_rows = if has_panel {
    max_int(height - 1 - 2 - panel.length(), 3)
  } else {
    page_height(height, queue.length())
  }
  let shown = visible_lines(page, page_rows, scroll)
  let children : Array[@vnode.TuiNode] = []
  children.push(
    @vnode.row(tab_nodes(state, state.ui.page, width, palette=tui.palette)),
  )
  for line in shown {
    children.push(line_node(line, width))
  }
  if has_panel {
    for line in panel {
      children.push(line_node(line, width))
    }
  } else {
    for line in queue {
      children.push(line_node(line, width))
    }
    children.push(@vnode.text(" "))
    children.push(line_node(editor_top_border(state, width, now_ms()), width))
    children.push(
      line_node(composer_line(tui.input, tui.cursor, width, tui.palette), width),
    )
    children.push(
      line_node(pad_line(rule(width), tui.palette.dim, None, width), width),
    )
  }
  let footer = footer_lines(state, width, palette=tui.palette)
  for line in footer {
    children.push(line_node(line, width))
  }
  @vnode.column(width=width.to_double(), height=height.to_double(), children)
}

///|
/// 选择面板的行（没打开时返回空数组 = 一行不占）。
///
/// 形状：顶边框（带标题）/ 提示行 / 列表 / 底边框 —— 与 pi 的 selector 同构。
fn picker_rows(
  tui : TuiState,
  state : @state.AgentState,
  width : Int32,
  height : Int32,
  palette~ : Palette = Palette::ansi256(),
) -> Array[StyledLine] {
  let picker = match state.ui.picker {
    Some(picker) => picker
    None => return []
  }
  let items = picker.items
  // 顶/底边框 + 提示 = 3 行；中间至少给对话页留 3 行。
  let max_items = max_int(height - 1 - 2 - 3 - 3, 1)
  let visible = min_int(items.length(), max_items)
  let rows : Array[StyledLine] = []
  let title_width = display_width(picker.title)
  rows.push(
    pad_line(
      "── " + picker.title + " " + rule(max_int(width - title_width - 4, 0)),
      palette.dim,
      None,
      width,
    ),
  )
  rows.push(
    styled_line("  ↑/↓ 选择 · Enter 确认 · Esc 取消", palette.dim),
  )
  let start = clamp_int(
    picker.selected - visible / 2,
    0,
    max_int(items.length() - visible, 0),
  )
  let mut index = start
  while index < start + visible {
    let item = items[index]
    let current = match picker.kind {
      @action.ModelPicker =>
        item.provider == state.provider_name && item.model_id == state.model_id
      @action.ThinkingPicker => item.level == state.thinking_level
      @action.SessionPicker => item.path == tui.session_path
    }
    let marker = if index == picker.selected { "› " } else { "  " }
    let suffix = if current { "  ●" } else { "" }
    let detail = if item.detail.is_empty() { "" } else { "  " + item.detail }
    let text = " " + marker + item.label + detail + suffix
    if index == picker.selected {
      rows.push(
        styled_line(truncate_to(text, width), palette.accent, bold=true),
      )
    } else if current {
      rows.push(styled_line(truncate_to(text, width), palette.success))
    } else {
      rows.push(plain_line(truncate_to(text, width)))
    }
    index = index + 1
  }
  // 列表比窗口长时，在提示行里说一声还有多少。
  if items.length() > visible {
    let more = items.length() - visible
    rows[1] = styled_line(
      "  ↑/↓ 选择 · Enter 确认 · Esc 取消 · 还有 " +
      more.to_string() +
      " 项",
      palette.dim,
    )
  }
  rows.push(pad_line(rule(width), palette.dim, None, width))
  rows
}

///|
fn min_int(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn line_node(line : StyledLine, width : Int32) -> @vnode.TuiNode {
  match line.spans {
    Some(spans) =>
      if !spans.is_empty() {
        return span_line_node(line, spans, width)
      }
    None => ()
  }
  let text = if line.text.is_empty() { " " } else { line.text }
  match (line.fg, line.bg) {
    (Some(fg), Some(bg)) =>
      @vnode.row(bg~, [@vnode.text(text, fg~, bold=line.bold)])
    (Some(fg), None) => @vnode.text(text, fg~, bold=line.bold)
    (None, Some(bg)) => @vnode.row(bg~, [@vnode.text(text, bold=line.bold)])
    (None, None) => @vnode.text(text, bold=line.bold)
  }
}

///|
/// 行内多样式的行：每个 span 一个 text 节点，末尾补空格把行铺满（diff 需要）。
fn span_line_node(
  line : StyledLine,
  spans : Array[MarkdownSpan],
  width : Int32,
) -> @vnode.TuiNode {
  let children : Array[@vnode.TuiNode] = []
  for span in spans {
    if !span.text.is_empty() {
      children.push(span_node(span))
    }
  }
  let used = display_width(line.text)
  if width > used {
    children.push(@vnode.text(spaces(width - used)))
  }
  if children.is_empty() {
    return @vnode.text(" ")
  }
  match line.bg {
    Some(bg) => @vnode.row(bg~, children)
    None => @vnode.row(children)
  }
}

///|
fn span_node(span : MarkdownSpan) -> @vnode.TuiNode {
  let bold = span.bold
  match span.fg {
    Some(fg) => @vnode.text(span.text, fg~, bold~, inverse=span.inverse)
    None => @vnode.text(span.text, bold~, inverse=span.inverse)
  }
}

///|
/// 不带样式的缩进文字（思考 / 流式尾巴 / 错误行）：左边留一格。
fn push_inset_block(
  out : Array[StyledLine],
  text : String,
  width : Int32,
  fg : String,
) -> Unit {
  for line in wrap_text(text, width - 2) {
    out.push(pad_line(" " + line, fg, None, width))
  }
}
