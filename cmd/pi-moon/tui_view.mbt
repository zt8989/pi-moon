// 把 agent 的状态翻成屏幕上的行，再把行装进 vnode 布局。
//
// 布局只有四块：顶栏、对话区、输入区、底栏。对话区是**自己折行**的纯文本行，
// 不是一堆嵌套组件 —— 折叠/滚动/换宽度都只动这一个行数组，不必和布局引擎
// 的换行规则打架。

///|
/// 对话区宽度：终端宽 - 边框(2) - 左右内边距(2)。
pub fn transcript_width(terminal_width : Int32) -> Int32 {
  let width = terminal_width - 4
  if width < 10 {
    10
  } else {
    width
  }
}

///|
/// 对话区高度：终端高 - 顶栏(1) - 输入区(3) - 底栏(1) - 对话区边框(2)。
pub fn transcript_height(terminal_height : Int32) -> Int32 {
  let height = terminal_height - 7
  if height < 3 {
    3
  } else {
    height
  }
}

///|
/// 状态 → 对话区行。纯函数（`expanded` 是那次渲染的快照）。
pub fn transcript_lines(
  state : @state.AgentState,
  expanded : Bool,
  width : Int32,
) -> Array[StyledLine] {
  let lines : Array[StyledLine] = []
  for message in state.messages {
    message_lines(message, expanded, width, lines)
    lines.push(blank_line())
  }
  // 正在流的那一轮：思考在上、正文在下（与模型说出来之前的顺序一致）。
  if !state.thinking_text.is_empty() && state.phase != @common.Idle {
    push_wrapped(lines, state.thinking_text, width, fn(text) {
      dim_line("… " + text)
    })
  }
  if !state.streaming_text.is_empty() && state.phase != @common.Idle {
    push_wrapped(lines, state.streaming_text + "▌", width, plain_line)
  }
  // 还没开跑 / 正在跑的工具：进度只显示最后一行。
  for call in state.pending_tool_calls {
    let mut started = false
    for tool in state.executing {
      if tool.call.id == call.id {
        started = true
      }
    }
    if started {
      lines.push(styled_line("⚙ " + call.name, "yellow", bold=true))
      match state.tool_progress.get(call.id) {
        Some(progress) => {
          let text = @message.contents_text(progress.content)
          let last = last_line(text)
          if !last.is_empty() {
            lines.push(dim_line("  " + truncate_to(last, width - 4)))
          }
        }
        None => ()
      }
    } else {
      lines.push(dim_line("⚙ " + call.name + "（等待执行）"))
    }
  }
  if state.compacting {
    lines.push(dim_line("… 正在压缩上下文"))
  }
  if state.phase == @common.Idle {
    match state.error {
      Some(error) =>
        for line in wrap_prefixed("! ", error, width) {
          lines.push(styled_line(line, "red"))
        }
      None => ()
    }
  }
  // 结尾多一个空行：最后一句话不必贴着边框。
  lines.push(blank_line())
  lines
}

///|
fn message_lines(
  message : @message.Message,
  expanded : Bool,
  width : Int32,
  out : Array[StyledLine],
) -> Unit {
  match message {
    @message.UserMsg(part) =>
      if part.compaction_summary {
        out.push(
          styled_line(
            "〔上下文压缩摘要 · 原约 " +
            part.tokens_before.to_string() +
            " tokens〕",
            "magenta",
            bold=true,
          ),
        )
        let body = @message.contents_text(part.content)
        for line in first_lines(body, 3) {
          out.push(dim_line("  " + truncate_to(line, width - 2)))
        }
      } else {
        let body = @message.contents_text(part.content)
        for line in wrap_prefixed("› ", body, width) {
          out.push(styled_line(line, "cyan", bold=true))
        }
      }
    @message.AssistantMsg(part) =>
      for line in wrap_prefixed("", assistant_text(part), width) {
        out.push(plain_line(line))
      }
    @message.ToolResultMsg(part) => {
      let body = @message.contents_text(part.content)
      let color = if part.is_error { "red" } else { "green" }
      out.push(
        styled_line("↳ " + part.tool_name + result_suffix(body), color),
      )
      let limit = if expanded { 40 } else { 2 }
      let shown = first_lines(body, limit)
      for line in shown {
        out.push(dim_line("  " + truncate_to(line, width - 2)))
      }
      let total = line_count(body)
      if total > limit {
        out.push(
          dim_line(
            "  … 还有 " +
            (total - limit).to_string() +
            " 行（Ctrl+O 展开）",
          ),
        )
      }
    }
    @message.SystemMsg(part) =>
      // 中途的工具声明是给模型看的，不是给用户看的：界面上只留一个标记。
      if part.source == Some("tools") {
        out.push(dim_line("〔工具集已更新：声明给模型〕"))
      } else {
        out.push(dim_line("〔" + truncate_to(part.content, width - 2) + "〕"))
      }
  }
}

///|
fn result_suffix(body : String) -> String {
  let lines = line_count(body)
  if lines <= 1 {
    ""
  } else {
    "（" + lines.to_string() + " 行）"
  }
}

///|
fn assistant_text(part : @message.AssistantPart) -> String {
  let parts : Array[String] = []
  for block in part.content {
    match block {
      @message.Text(text) => parts.push(text)
      @message.Thinking(_) => ()
      @message.ToolCallBlock(call) =>
        parts.push("\n⚙ " + call.name + " " + call.arguments)
      @message.Image(_) => parts.push("[image]")
    }
  }
  let text = parts.join("\n")
  if text.is_empty() {
    match part.error_message {
      Some(error) => "! " + error
      None => ""
    }
  } else {
    text
  }
}

///|
fn push_wrapped(
  out : Array[StyledLine],
  text : String,
  width : Int32,
  make : (String) -> StyledLine,
) -> Unit {
  for line in wrap_text(text, width) {
    out.push(make(line))
  }
}

///|
fn last_line(text : String) -> String {
  match text.rev_find("\n") {
    Some(index) => text[index + 1:].to_owned()
    None => text
  }
}

///|
/// 从底部取一屏：`scroll` 是「往上翻了几行」，0 = 跟随最新。
pub fn visible_lines(
  lines : Array[StyledLine],
  height : Int32,
  scroll : Int32,
) -> Array[StyledLine] {
  if lines.is_empty() {
    return [blank_line()]
  }
  let visible = max_int(height, 1)
  let max_scroll = max_int(lines.length() - visible, 0)
  let offset = min_int(max_int(scroll, 0), max_scroll)
  let start = lines.length() - visible - offset
  let out : Array[StyledLine] = []
  let mut index = max_int(start, 0)
  while index < lines.length() && out.length() < visible {
    out.push(lines[index])
    index = index + 1
  }
  out
}

///|
fn max_int(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
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

///|
/// 顶栏：谁在跑、跑到哪一步。
pub fn header_text(state : @state.AgentState) -> String {
  let tokens = match state.usage {
    Some(usage) =>
      "  " +
      usage.input_tokens.to_string() +
      "/" +
      usage.output_tokens.to_string() +
      " tok"
    None => ""
  }
  let model = if state.model_id.is_empty() { "?" } else { state.model_id }
  "pi-moon  " +
  state.provider_name +
  "/" +
  model +
  "  " +
  phase_text(state) +
  tokens
}

///|
fn phase_text(state : @state.AgentState) -> String {
  if state.compacting {
    return "压缩中"
  }
  match state.phase {
    @common.Idle =>
      match state.error {
        Some(_) => "已停止"
        None => "就绪"
      }
    @common.Thinking => if state.retrying { "重试中" } else { "生成中" }
    @common.CallingTools => "工具执行中"
  }
}

///|
/// 底栏：状态 + 键位提示。窄屏先丢提示，别把状态挤没。
pub fn footer_text(
  state : @state.AgentState,
  input_empty : Bool,
  notice : String,
  width : Int32,
) -> String {
  let hints = if input_empty {
    "Esc 中断 · Ctrl+C 两次退出 · PgUp/PgDn 翻页 · Ctrl+O 展开工具"
  } else {
    "Enter 发送 · Esc 清空 · PgUp/PgDn 翻页"
  }
  let status = if notice.is_empty() {
    let queued = state.steer_queue.length() + state.follow_up_queue.length()
    if queued > 0 {
      "排队 " + queued.to_string() + " 条  "
    } else {
      ""
    }
  } else {
    notice + "  "
  }
  truncate_to(status + hints, width)
}

///|
/// 整个界面。
pub fn tui_view(tui : TuiState, state : @state.AgentState) -> @vnode.TuiNode {
  let width = tui.width
  let height = tui.height
  let inner_width = transcript_width(width)
  let inner_height = transcript_height(height)
  let lines = transcript_lines(state, tui.expanded, inner_width)
  let shown = visible_lines(lines, inner_height, tui.scroll)
  let rows : Array[@vnode.TuiNode] = []
  for line in shown {
    rows.push(line_node(line))
  }
  if rows.is_empty() {
    rows.push(@vnode.text(" "))
  }
  let editor = if tui.input.is_empty() {
    @vnode.text("说点什么…", fg="rgb(100,100,100)")
  } else {
    @vnode.text(
      render_editor(tui.input, tui.cursor, inner_width - 4),
      fg="white",
      bold=true,
    )
  }
  @vnode.column(width=width.to_double(), height=height.to_double(), [
    @vnode.row(justify="space-between", [
      @vnode.text(header_text(state), fg="yellow", bold=true),
      @vnode.text(if tui.busy { "busy" } else { "" }, fg="rgb(128,128,128)"),
    ]),
    @vnode.view(
      flex_grow=1.0,
      border="rounded",
      border_color="rgb(60,60,80)",
      padding_x=1.0,
      rows,
    ),
    @vnode.view(
      height=3.0,
      border="rounded",
      border_color=if tui.busy { "rgb(120,120,120)" } else { "cyan" },
      padding_x=1.0,
      [@vnode.row([@vnode.text("› ", fg="cyan", bold=true), editor])],
    ),
    @vnode.text(
      footer_text(state, tui.input.is_empty(), tui.notice, width),
      fg="rgb(128,128,128)",
    ),
  ])
}

///|
fn line_node(line : StyledLine) -> @vnode.TuiNode {
  if line.text.is_empty() {
    // 空行也要占一格，否则整块会被布局压扁。
    return @vnode.text(" ")
  }
  match line.fg {
    Some(fg) => @vnode.text(line.text, fg~, bold=line.bold)
    None => @vnode.text(line.text, bold=line.bold)
  }
}
