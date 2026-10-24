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
// 颜色取 pi 的分类（userMessageBg / toolSuccessBg / …），但用 **16 色名字**：
// tui.mbt 的渲染器把 `rgb()` 量化到 256 色立方（6×6×6），pi 那些很暗的底色
// （`rgb(41,49,73)` 与 `rgb(37,65,49)`）会双双落到同一个 `#005f5f` —— 用户块与
// 工具块就分不出来了。16 色里的 blue / green / red 在暗色终端上最接近 pi 的观感。

///|
let color_user_bg : String = "blue"

///|
let color_tool_pending_bg : String = "black"

///|
let color_tool_success_bg : String = "green"

///|
let color_tool_error_bg : String = "red"

///|
let color_compaction_bg : String = "magenta"

///|
let color_muted : String = "rgb(150,152,160)"

///|
let color_dim : String = "rgb(128,128,128)"

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
/// 对话页的行。`notice` 是命令反馈卡（ela 的 `statusCards`：钉在对话流里，
/// 不在底栏）。
pub fn chat_lines(
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
  notice : String,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  for message in state.messages {
    message_lines(message, state, expanded, width, out)
  }
  // 正在流的那一轮：思考在上、正文在下（与模型说出来之前的顺序一致）。
  if state.phase != @common.Idle {
    if !state.thinking_text.is_empty() {
      push_inset_block(out, state.thinking_text, width, color_muted)
    }
    if !state.streaming_text.is_empty() {
      push_inset_block(out, state.streaming_text + "▌", width, "")
    }
  }
  if state.compacting {
    push_inset_block(out, "压缩中…", width, color_muted)
  }
  if !notice.is_empty() {
    out.push(blank_line())
    for line in wrap_text(notice, width - 2) {
      out.push(dim_line(" " + line))
    }
  }
  out
}

///|
fn message_lines(
  message : @message.Message,
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
) -> Unit {
  match message {
    @message.UserMsg(part) =>
      if part.compaction_summary {
        compaction_block(part, expanded, width, out)
      } else {
        let body = @message.contents_text(part.content)
        push_bg_block(out, wrap_text(body, width - 2), width, "", color_user_bg)
      }
    @message.AssistantMsg(part) => {
      for block in part.content {
        match block {
          @message.Text(text) =>
            if !text.trim(chars=" \t\r\n").is_empty() {
              out.push(blank_line())
              push_inset_block(out, text, width, "")
            }
          @message.Thinking(text) =>
            if !text.trim(chars=" \t\r\n").is_empty() {
              out.push(blank_line())
              push_inset_block(out, text, width, color_muted)
            }
          @message.ToolCallBlock(call) =>
            tool_block(
              call,
              find_result(state, call.id),
              state,
              expanded,
              width,
              out,
            )
          @message.Image(_) => ()
        }
      }
      // 用户中断：ela 的 `stopNoticeLine` 在正文后面补一行错误色。
      // toolCall 已经在 provider 侧剥掉了，这里不必再判。
      if part.stop_reason == "aborted" {
        out.push(blank_line())
        push_inset_block(out, "[已中断]", width, "red")
      }
      match part.error_message {
        Some(error) => {
          out.push(blank_line())
          push_inset_block(out, error, width, "red")
        }
        None => ()
      }
    }
    @message.ToolResultMsg(part) =>
      // 工具块已经在 assistant 消息里连同调用画过了；只有找不到那次调用的
      // 结果（旧会话回放、或调用消息被裁掉）才单独画一块。
      if !call_was_rendered(state, part.tool_call_id) {
        out.push(blank_line())
        let bg = if part.is_error {
          color_tool_error_bg
        } else {
          color_tool_success_bg
        }
        let body = @message.contents_text(part.content)
        let lines = if expanded {
          first_lines(body, 40)
        } else {
          first_lines(body, 6)
        }
        push_bg_lines(
          out,
          part.tool_name,
          lines,
          line_count(body),
          expanded,
          bg,
          width,
        )
      }
    @message.SystemMsg(part) =>
      // 中途的工具声明是给模型看的，不是给用户看的：只留一行标记。
      if part.source == Some("tools") {
        out.push(dim_line(" 〔工具集已更新〕"))
      } else {
        out.push(
          dim_line(" 〔" + truncate_to(part.content, width - 3) + "〕"),
        )
      }
  }
}

///|
fn compaction_block(
  part : @message.UserPart,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
) -> Unit {
  out.push(blank_line())
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
  push_bg_block(out, head, width, color_muted, color_compaction_bg)
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
) -> Unit {
  out.push(blank_line())
  let bg = match result {
    Some(part) =>
      if part.is_error {
        color_tool_error_bg
      } else {
        color_tool_success_bg
      }
    None => color_tool_pending_bg
  }
  let title = call.name + " " + truncate_to(one_line(call.arguments), width - 4)
  match result {
    Some(part) => {
      let body = @message.contents_text(part.content)
      let limit = if expanded { 40 } else { 6 }
      let lines = first_lines(body, limit)
      push_bg_lines(out, title, lines, line_count(body), expanded, bg, width)
    }
    None => {
      // 还在跑：显示进度最后一行（没有就只画标题）。
      let lines : Array[String] = []
      match state.tool_progress.get(call.id) {
        Some(progress) => {
          let last = last_line(@message.contents_text(progress.content))
          if !last.is_empty() {
            lines.push(last)
          }
        }
        None => ()
      }
      push_bg_lines(out, title, lines, lines.length(), false, bg, width)
    }
  }
}

///|
fn push_bg_lines(
  out : Array[StyledLine],
  title : String,
  body : Array[String],
  total_lines : Int32,
  expanded : Bool,
  bg : String,
  width : Int32,
) -> Unit {
  let lines : Array[String] = [title]
  for line in body {
    lines.push("  " + line)
  }
  if !expanded && total_lines > body.length() {
    lines.push(
      "  … 还有 " +
      (total_lines - body.length()).to_string() +
      " 行（Ctrl+O 展开）",
    )
  }
  push_bg_block(out, lines, width, color_muted, bg)
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
/// 不带底色的助手 / 思考文字：左边留一格（pi 的 Markdown `paddingX=1`）。
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
) -> Array[StyledLine] {
  let rows = @trace.trace_rows(state.trace, max_width=width - 2)
  let out : Array[StyledLine] = []
  if rows.is_empty() {
    out.push(dim_line(" （轨迹为空）"))
    return out
  }
  for row in rows {
    let fg = match row.node.status {
      @trace.Errored => "red"
      @trace.Aborted => "yellow"
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
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  if state.steer_queue.is_empty() && state.follow_up_queue.is_empty() {
    return out
  }
  out.push(blank_line())
  for item in state.steer_queue {
    out.push(dim_line(queue_row("Steering: ", item.text, width)))
  }
  for item in state.follow_up_queue {
    out.push(dim_line(queue_row("Follow-up: ", item.text, width)))
  }
  out.push(dim_line(" ↳ Ctrl+U 取回排队消息"))
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
  page : TuiPage,
  width : Int32,
) -> Array[@vnode.TuiNode] {
  let stats = @trace.trace_stats(state.trace)
  let nodes : Array[@vnode.TuiNode] = []
  let mut used : Int32 = 0
  if page == Chat {
    nodes.push(@vnode.text("对话", fg="cyan", bold=true))
    used = used + 4
    nodes.push(@vnode.text(" "))
    used = used + 1
    nodes.push(@vnode.text("│ 轨迹", fg=color_dim))
    used = used + 4
  } else {
    nodes.push(@vnode.text("对话", fg=color_dim))
    used = used + 4
    nodes.push(@vnode.text(" "))
    used = used + 1
    nodes.push(@vnode.text("│ 轨迹", fg="cyan", bold=true))
    used = used + 4
  }
  let bits : Array[(String, String)] = []
  if stats.turns > 0 || stats.steps > 0 {
    bits.push(
      (stats.turns.to_string() + "轮" + stats.steps.to_string() + "步", ""),
    )
  }
  if stats.tool_calls > 0 {
    bits.push(("工具" + stats.tool_calls.to_string(), color_dim))
  }
  if stats.retries > 0 {
    bits.push(("重试" + stats.retries.to_string(), color_dim))
  }
  if stats.errors > 0 {
    bits.push(("错误" + stats.errors.to_string(), "red"))
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
  nodes.push(@vnode.text("(Ctrl+R)", fg=color_dim))
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
) -> Array[StyledLine] {
  let cwd = shorten_home(state.cwd, home_dir())
  let model = model_line(state)
  [
    pad_line(cwd, color_dim, None, width),
    pad_line(
      two_column(stats_line(state), model, width),
      color_dim,
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
) -> StyledLine {
  let color = border_color(state.thinking_level)
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
/// composer 框线颜色跟思考级别走（pi 的 `getThinkingBorderColor`）。
fn border_color(level : String) -> String {
  match level {
    "off" => "rgb(120,122,132)"
    "minimal" => "rgb(110,120,170)"
    "low" => "rgb(105,125,190)"
    "medium" => "rgb(150,120,200)"
    "high" => "rgb(200,120,210)"
    "xhigh" => "rgb(220,110,180)"
    "max" => "rgb(230,130,90)"
    _ => "rgb(120,122,132)"
  }
}

///|
/// 整个界面。
///
/// 面板开着时，它**覆盖 composer 那一块**（ela 的选择器：整行宽、底边落在
/// composer 底边），对话页相应变矮。队列与 composer 都不画。
pub fn tui_view(tui : TuiState, state : @state.AgentState) -> @vnode.TuiNode {
  let width = tui.width
  let height = tui.height
  let panel = picker_rows(tui, state, width, height)
  let has_panel = !panel.is_empty()
  let mut queue = if has_panel { [] } else { queue_lines(state, width) }
  // 太矮的终端：先牺牲队列面板（内容还在环上，不会丢），保证 composer 与
  // 底栏这两块不飞出屏幕。
  let page_budget = height - 1 - fixed_bottom_rows
  if page_budget - queue.length() < 3 {
    queue = []
  }
  let page = if tui.page == Chat {
    chat_lines(state, tui.expanded, width, tui.notice)
  } else {
    trace_lines(state, width)
  }
  let scroll = if tui.page == Chat { tui.chat_scroll } else { tui.trace_scroll }
  let page_rows = if has_panel {
    max_int(height - 1 - 2 - panel.length(), 3)
  } else {
    page_height(height, queue.length())
  }
  let shown = visible_lines(page, page_rows, scroll)
  let children : Array[@vnode.TuiNode] = []
  children.push(@vnode.row(tab_nodes(state, tui.page, width)))
  for line in shown {
    children.push(line_node(line))
  }
  if has_panel {
    for line in panel {
      children.push(line_node(line))
    }
  } else {
    for line in queue {
      children.push(line_node(line))
    }
    children.push(@vnode.text(" "))
    children.push(line_node(editor_top_border(state, width, now_ms())))
    children.push(
      line_node(
        pad_line(render_editor(tui.input, tui.cursor, width), "", None, width),
      ),
    )
    children.push(line_node(pad_line(rule(width), color_dim, None, width)))
  }
  let footer = footer_lines(state, width)
  for line in footer {
    children.push(line_node(line))
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
) -> Array[StyledLine] {
  let picker = match tui.picker {
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
      color_dim,
      None,
      width,
    ),
  )
  rows.push(dim_line("  ↑/↓ 选择 · Enter 确认 · Esc 取消"))
  let start = clamp_int(
    picker.selected - visible / 2,
    0,
    max_int(items.length() - visible, 0),
  )
  let mut index = start
  while index < start + visible {
    let item = items[index]
    let current = match picker.kind {
      ModelPicker =>
        item.provider == state.provider_name && item.model_id == state.model_id
      ThinkingPicker => item.level == state.thinking_level
      SessionPicker => item.path == tui.session_path
    }
    let marker = if index == picker.selected { "› " } else { "  " }
    let suffix = if current { "  ●" } else { "" }
    let detail = if item.detail.is_empty() { "" } else { "  " + item.detail }
    let text = " " + marker + item.label + detail + suffix
    if index == picker.selected {
      rows.push(styled_line(truncate_to(text, width), "cyan", bold=true))
    } else if current {
      rows.push(styled_line(truncate_to(text, width), "green"))
    } else {
      rows.push(plain_line(truncate_to(text, width)))
    }
    index = index + 1
  }
  // 列表比窗口长时，在提示行里说一声还有多少。
  if items.length() > visible {
    let more = items.length() - visible
    rows[1] = dim_line(
      "  ↑/↓ 选择 · Enter 确认 · Esc 取消 · 还有 " +
      more.to_string() +
      " 项",
    )
  }
  rows.push(pad_line(rule(width), color_dim, None, width))
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
fn line_node(line : StyledLine) -> @vnode.TuiNode {
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
fn last_line(text : String) -> String {
  match text.rev_find("\n") {
    Some(index) => text[index + 1:].to_owned()
    None => text
  }
}
