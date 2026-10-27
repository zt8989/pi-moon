// markdown → 屏幕行：解析交给 @md（CommonMark CST），这里只做
// 「AST → 带样式的行」这一层。
//
// 样式只用终端给得起的（前景色 + 粗体）：斜体 / 下划线在 vnode 的 text 上
// 没有开关，所以 Emphasis 继承外层样式，不假装。表格单元格同理只保留文字。
//
// 折行必须按**单元格**做，不能先拼成字符串再折：`**加粗**` 拆开之后要保留
// 每一段的样式，先折字符串就等于把样式信息丢了。

///|
pub(all) struct MarkdownSpan {
  text : String
  fg : String?
  bold : Bool
  /// 反色（SGR 7）：光标块用 —— fg/bg 互换后块色跟随终端默认前景，
  /// 浅底上是黑块，深底上是亮块，和 pi 的假光标同一套行为。
  inverse : Bool
} derive(Eq, Debug)

///|
struct MarkdownCell {
  c : Char
  fg : String?
  bold : Bool
}

///|
/// markdown 用到的颜色。默认值来自 pi 的 dark 主题（和界面其它部分同一个来源），
/// 主题换了就整套跟着换。
pub(all) struct MarkdownColors {
  code : String
  link : String
  link_url : String
  code_block : String
  code_block_border : String
  heading : String
  quote : String
  quote_border : String
  hr : String
  list_bullet : String
  diff_add : String
  diff_removed : String
  diff_context : String
} derive(Eq, Hash, Debug)

///|
pub fn MarkdownColors::from_theme(theme : Theme) -> MarkdownColors {
  let fallback = builtin_theme("dark", "dark")
  let pick = fn(token : String) {
    theme.color_or(token, fallback.color_or(token, ""))
  }
  {
    code: pick("mdCode"),
    link: pick("mdLink"),
    link_url: pick("mdLinkUrl"),
    code_block: pick("mdCodeBlock"),
    code_block_border: pick("mdCodeBlockBorder"),
    heading: pick("mdHeading"),
    quote: pick("mdQuote"),
    quote_border: pick("mdQuoteBorder"),
    hr: pick("mdHr"),
    list_bullet: pick("mdListBullet"),
    diff_add: pick("toolDiffAdded"),
    diff_removed: pick("toolDiffRemoved"),
    diff_context: pick("toolDiffContext"),
  }
}

///|
pub fn MarkdownColors::defaults() -> MarkdownColors {
  MarkdownColors::from_theme(builtin_theme("dark", "dark"))
}

///|
/// markdown 文本 → 屏幕行（宽度已经是**内容宽度**：调用方自己把左侧内边距
/// 算进去）。首尾的空行会被去掉 —— 调用方在块前后自己留白。
///|
/// 缓存 key：正文、内容宽度、颜色三者任一变化都会重算。
struct MarkdownCacheKey {
  text : String
  width : Int32
  colors : MarkdownColors
} derive(Eq, Hash)

///|
struct MarkdownCacheEntry {
  lines : Array[StyledLine]
  seq : Int64
}

///|
/// 渲染缓存的容量上限。历史消息的条目稳定命中；流式正文每来一个 delta
/// 就换一个新 key，是主要的淘汰来源。满了按插入序淘汰最老的一条。
let markdown_cache_capacity : Int = 256

///|
let markdown_cache : Map[MarkdownCacheKey, MarkdownCacheEntry] = Map([], capacity=64)

///|
let markdown_cache_seq : Ref[Int64] = Ref(0L)

///|
fn cache_markdown_lines(
  key : MarkdownCacheKey,
  lines : Array[StyledLine],
) -> Unit {
  if markdown_cache.length() >= markdown_cache_capacity {
    // Map 无序，用插入序号找最老的一条；扫描 O(cap)，淘汰频率低。
    let mut oldest_key : MarkdownCacheKey? = None
    let mut oldest_seq : Int64 = markdown_cache_seq.val + 1L
    for k, v in markdown_cache {
      if v.seq < oldest_seq {
        oldest_seq = v.seq
        oldest_key = Some(k)
      }
    }
    match oldest_key {
      Some(k) => {
        let _ = markdown_cache.remove(k)
      }
      None => ()
    }
  }
  let seq = markdown_cache_seq.val + 1L
  markdown_cache_seq.val = seq
  markdown_cache.set(key, { lines, seq })
}

///|
/// markdown 文本 → 屏幕行（宽度已经是**内容宽度**：调用方自己把左侧内边距
/// 算进去）。首尾的空行会被去掉 —— 调用方在块前后自己留白。
///
/// 结果按 (text, width, colors) 缓存：对话页每帧全量重画，历史消息的 key
/// 不变，命中后跳过 parse + 渲染，只有正在流的那条每帧真正重算。返回的
/// 数组是缓存共享的，调用方只读。js / native 双端都只是进程内 Map，
/// 不依赖任何平台能力。
pub fn markdown_lines(
  text : String,
  width : Int32,
  colors~ : MarkdownColors = MarkdownColors::defaults(),
) -> Array[StyledLine] {
  let key : MarkdownCacheKey = { text, width, colors }
  match markdown_cache.get(key) {
    Some(entry) => entry.lines
    None => {
      let document = @md.parse(text).document
      let lines = trim_blank_edges(
        render_blocks(document.children, width, document.definitions, colors),
      )
      cache_markdown_lines(key, lines)
      lines
    }
  }
}

///|
/// 流式文本可能以「半截闭合围栏」结尾：闭合的 ```` ``` ```` 逐字符到达时，
/// 末尾先出现 `` 这样的前缀，会被吞进代码块、下一帧又缩回去，代码块看起来
/// 抖一下。pi 在 token 层剪（trimPartialClosingFences），mdparse 不给闭合
/// 标志，这里按行扫一遍围栏状态：还开着、且末行全是同一种围栏字符但比开
/// 围栏短，就把这行先剪掉。对已闭合的完整文本是恒等变换。
pub fn trim_partial_closing_fence(text : String) -> String {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.to_owned())
  }
  // 打开的围栏：marker 字符与长度；None 表示当前不在围栏里。
  let mut open_char : Char? = None
  let mut open_length = 0
  for line in lines {
    match open_char {
      Some(marker) =>
        if is_fence_close(line, marker, open_length) {
          open_char = None
        }
      None =>
        match fence_open(line) {
          Some((marker, length)) => {
            open_char = Some(marker)
            open_length = length
          }
          None => ()
        }
    }
  }
  let last_index = lines.length() - 1
  if last_index >= 0 {
    match open_char {
      Some(marker) => {
        let last = lines[last_index]
        let mut runs = true
        let mut count = 0
        for c in last {
          if c == marker {
            count = count + 1
          } else {
            runs = false
            break
          }
        }
        // 等长或更长已经构成闭合，状态机处理过了；这里只剪「还差几个字符」的。
        if runs && count > 0 && count < open_length {
          let _ = lines.pop()
        }
      }
      None => ()
    }
  }
  lines.join("\n")
}

///|
/// String 下标返回的是码元（UInt16），统一转回 Char 再比较。
fn char_at(line : String, index : Int) -> Char {
  // String 下标取的是 UTF-16 码元，必然落在合法 Char 范围内。
  line[index].to_int().unsafe_to_char()
}

///|
/// 围栏开头：最多 3 格缩进 + 3 个以上 ` 或 ~；info 串里不能出现同字符。
fn fence_open(line : String) -> (Char, Int)? {
  let chars = line.length()
  let mut index = 0
  while index < chars && char_at(line, index) == ' ' {
    index = index + 1
  }
  if index > 3 || index >= chars {
    return None
  }
  let marker = char_at(line, index)
  if marker != '`' && marker != '~' {
    return None
  }
  let start = index
  while index < chars && char_at(line, index) == marker {
    index = index + 1
  }
  let length = index - start
  if length < 3 {
    return None
  }
  while index < chars {
    if char_at(line, index) == marker {
      return None
    }
    index = index + 1
  }
  Some((marker, length))
}

///|
/// 围栏闭合行：最多 3 格缩进 + 不短于开围栏的同字符序列 + 只剩空白。
fn is_fence_close(
  line : String,
  marker : Char,
  open_length : Int,
) -> Bool {
  let chars = line.length()
  let mut index = 0
  while index < chars && char_at(line, index) == ' ' {
    index = index + 1
  }
  if index > 3 || index >= chars {
    return false
  }
  let mut count = 0
  while index < chars && char_at(line, index) == marker {
    index = index + 1
    count = count + 1
  }
  if count < open_length {
    return false
  }
  while index < chars {
    let c = char_at(line, index)
    if c != ' ' && c != '\t' {
      return false
    }
    index = index + 1
  }
  true
}

///|
fn render_blocks(
  blocks : Array[@md.Block],
  width : Int32,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  for block in blocks {
    match block {
      @md.Block::BlankLines(count~, ..) => {
        // 连续空行最多留两行：对话流里三行以上的空白没有信息量。
        let blanks = if count > 2 { 2 } else { count }
        for _ in 0..<blanks {
          out.push(blank_line())
        }
      }
      _ =>
        for line in render_block(block, width, defs, colors) {
          out.push(line)
        }
    }
  }
  out
}

///|
fn render_block(
  block : @md.Block,
  width : Int32,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[StyledLine] {
  match block {
    @md.Block::ThematicBreak(..) => [styled_line(rule(width), colors.hr)]
    @md.Block::Heading(level~, children~, ..) =>
      heading_lines(level, children, width, defs, colors)
    @md.Block::Paragraph(children~, ..) =>
      wrap_spans(inline_spans(children, None, false, defs, colors), width)
    @md.Block::FencedCode(info~, code~, ..) =>
      code_block_lines(info, code, width, colors)
    @md.Block::IndentedCode(code~, ..) =>
      code_block_lines("", code, width, colors)
    @md.Block::MathBlock(value~, ..) =>
      code_block_lines("math", value, width, colors)
    @md.Block::Blockquote(children~, ..) =>
      prefix_lines(
        render_blocks(children, rest_width(width, 2), defs, colors),
        "│ ",
        colors.quote,
      )
    @md.Block::Alert(kind~, children~, ..) => {
      let label = "│ " + alert_label(kind) + " "
      prefix_lines(
        render_blocks(
          children,
          rest_width(width, display_width(label)),
          defs,
          colors,
        ),
        label,
        colors.quote,
      )
    }
    @md.Block::BulletList(items~, ..) =>
      list_lines(items, None, width, defs, colors)
    @md.Block::OrderedList(start~, items~, ..) =>
      list_lines(items, Some(start), width, defs, colors)
    @md.Block::Table(header~, alignments~, rows~, ..) =>
      table_lines(header, alignments, rows, width, colors)
    @md.Block::HtmlBlock(html~, ..) => {
      let out : Array[StyledLine] = []
      for line in split_lines(html) {
        out.push(styled_line("  " + line, colors.code_block_border))
      }
      out
    }
    // 指令块（`:::name`）的元信息对终端读者没意义，只渲染里面的内容。
    @md.Block::Directive(children~, ..) =>
      render_blocks(children, width, defs, colors)
    @md.Block::DefinitionList(items~, ..) =>
      definition_lines(items, width, defs, colors)
    @md.Block::FootnoteDefinition(label~, children~, ..) => {
      let prefix = "[^" + label + "] "
      prefix_lines(
        render_blocks(
          children,
          rest_width(width, display_width(prefix)),
          defs,
          colors,
        ),
        prefix,
        colors.quote,
      )
    }
    @md.Block::Attributed(block~, ..) =>
      render_block(block, width, defs, colors)
    @md.Block::BlankLines(..) => [blank_line()]
  }
}

///|
fn alert_label(kind : @md.AlertKind) -> String {
  match kind {
    Note => "NOTE"
    Tip => "TIP"
    Important => "IMPORTANT"
    Warning => "WARNING"
    Caution => "CAUTION"
  }
}

///|
fn rest_width(width : Int32, used : Int32) -> Int32 {
  if width > used {
    width - used
  } else {
    1
  }
}

///|
/// 标题：整行加粗；h3 以下再用暗色 —— 一轮对话里 h1/h2 通常只有一个，
/// 再往下如果都一样粗，层级反而看不出来。
fn heading_lines(
  level : Int32,
  children : Array[@md.Inline],
  width : Int32,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let base_fg = if level >= 3 { Some(colors.quote) } else { None }
  let spans = inline_spans(children, base_fg, true, defs, colors)
  let bold_spans : Array[MarkdownSpan] = []
  for span in spans {
    bold_spans.push({ text: span.text, fg: span.fg, bold: true, inverse: false })
  }
  wrap_spans(bold_spans, width)
}

///|
/// 围栏代码 / 缩进代码 / 数学块：保留围栏标记与行结构，内容用代码色。
/// ```diff 按行上色 —— 工具产出的补丁没人愿意在单色里找增删。
fn code_block_lines(
  info : String,
  code : String,
  width : Int32,
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  out.push(styled_line("  " + fence_label(info), colors.code_block_border))
  let is_diff = first_word(info).to_lower() == "diff"
  for raw in trim_trailing_newlines(code).split("\n") {
    let line = raw.to_owned()
    if line.is_empty() {
      out.push(blank_line())
      continue
    }
    let fg = if is_diff {
      diff_line_color(line, colors)
    } else {
      colors.code_block
    }
    for wrapped in wrap_prefixed("  ", line, width) {
      out.push(styled_line(wrapped, fg, bold=is_diff_meta(line)))
    }
  }
  out
}

///|
/// 围栏首行：```` ```lang ````。语言为空时仍然画围栏，与原文一致。
fn fence_label(info : String) -> String {
  let trimmed = info.trim(chars=" ").to_owned()
  if trimmed.is_empty() {
    "```"
  } else {
    "```" + trimmed
  }
}

///|
fn is_diff_meta(line : String) -> Bool {
  line.has_prefix("diff ") ||
  line.has_prefix("+++") ||
  line.has_prefix("---") ||
  line.has_prefix("index ")
}

///|
fn diff_line_color(line : String, colors : MarkdownColors) -> String {
  if line.has_prefix("+++") || line.has_prefix("---") {
    colors.quote
  } else if line.has_prefix("@@") {
    colors.link
  } else if line.has_prefix("+") {
    colors.diff_add
  } else if line.has_prefix("-") {
    colors.diff_removed
  } else {
    colors.code_block
  }
}

///|
fn split_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for line in trim_trailing_newlines(text).split("\n") {
    out.push(line.to_owned())
  }
  out
}

///|
fn trim_trailing_newlines(text : String) -> String {
  let mut end = text.length()
  while end > 0 {
    let c = text[end - 1]
    if c == '\n' || c == '\r' {
      end = end - 1
    } else {
      break
    }
  }
  text[:end].to_owned()
}

///|
/// 列表：每个 item 的正文按标记宽度缩进，嵌套列表靠这一层缩进自己叠上去。
fn list_lines(
  items : Array[@md.ListItem],
  ordered_start : Int32?,
  width : Int32,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  let mut index = 0
  for item in items {
    let marker = list_marker(item, ordered_start, index)
    let marker_width = display_width(marker)
    let inner = render_blocks(
      item.children,
      rest_width(width, marker_width),
      defs,
      colors,
    )
    let indent = spaces(marker_width)
    let mut first = true
    for line in inner {
      if line.text.is_empty() {
        out.push(blank_line())
      } else if first {
        out.push(prefixed_line(line, marker, None))
      } else {
        out.push(prefixed_line(line, indent, None))
      }
      first = false
    }
    index = index + 1
  }
  out
}

///|
fn list_marker(
  item : @md.ListItem,
  ordered_start : Int32?,
  index : Int32,
) -> String {
  let bullet = match item.checked {
    Some(true) => "☑ "
    Some(false) => "☐ "
    None => "• "
  }
  match ordered_start {
    Some(start) => (start + index).to_string() + ". "
    None => bullet
  }
}

///|
/// 术语列表：`Term` 一行，定义各自缩进一行。
fn definition_lines(
  items : Array[@md.DefinitionItem],
  width : Int32,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  for item in items {
    let term = inline_spans(item.term, None, true, defs, colors)
    for line in wrap_spans(term, width) {
      out.push(line)
    }
    for definition in item.definitions {
      let spans = inline_spans(definition, None, false, defs, colors)
      for line in wrap_spans(spans, rest_width(width, 2)) {
        if line.text.is_empty() {
          out.push(blank_line())
        } else {
          out.push(prefixed_line(line, "  ", None))
        }
      }
    }
  }
  out
}

///|
/// 表格：列宽按内容算，整体放不下时从最宽的列开始收，直到塞进内容宽度。
/// 单元格里只用纯文字 —— 每个单元格还要对齐补空格，保留行内样式会让
/// `StyledLine` 的宽度算法和 padding 打架。
fn table_lines(
  header : Array[@md.TableCell],
  alignments : Array[@md.TableAlign],
  rows : Array[Array[@md.TableCell]],
  width : Int32,
  colors : MarkdownColors,
) -> Array[StyledLine] {
  let cols = header.length()
  if cols == 0 {
    return []
  }
  let header_texts : Array[String] = []
  let widths : Array[Int32] = []
  for cell in header {
    let text = inline_plain(cell.children)
    header_texts.push(text)
    widths.push(display_width(text))
  }
  let row_texts : Array[Array[String]] = []
  for row in rows {
    let texts : Array[String] = []
    let mut index = 0
    for cell in row {
      let text = inline_plain(cell.children)
      if index < widths.length() && display_width(text) > widths[index] {
        widths[index] = display_width(text)
      }
      texts.push(text)
      index = index + 1
    }
    row_texts.push(texts)
  }
  fit_columns(widths, width)
  let out : Array[StyledLine] = []
  out.push(table_row(header_texts, widths, alignments, true))
  let separator : Array[Char] = []
  let mut column = 0
  for column_width in widths {
    if column > 0 {
      // 列间 2 格（与表头/行的 `  ` 分隔对齐）。
      separator.push('┼')
      separator.push('─')
    }
    for _ in 0..<column_width {
      separator.push('─')
    }
    column = column + 1
  }
  out.push(styled_line(String::from_array(separator), colors.quote_border))
  for texts in row_texts {
    out.push(table_row(texts, widths, alignments, false))
  }
  out
}

///|
fn table_row(
  texts : Array[String],
  widths : Array[Int32],
  alignments : Array[@md.TableAlign],
  bold : Bool,
) -> StyledLine {
  let buf : Array[Char] = []
  let mut index = 0
  for text in texts {
    if index >= widths.length() {
      break
    }
    if index > 0 {
      buf.push(' ')
      buf.push(' ')
    }
    let align = if index < alignments.length() {
      alignments[index]
    } else {
      Left
    }
    for c in fit_cell(text, widths[index], align) {
      buf.push(c)
    }
    index = index + 1
  }
  plain_line(String::from_array(buf)) |> with_bold(bold)
}

///|
fn with_bold(line : StyledLine, bold : Bool) -> StyledLine {
  if !bold {
    return line
  }
  let spans : Array[MarkdownSpan] = [{ text: line.text, fg: None, bold: true, inverse: false }]
  { ..line, bold: true, spans: Some(spans), }
}

///|
fn fit_cell(text : String, width : Int32, align : @md.TableAlign) -> String {
  let clipped = truncate_to(text, width)
  let used = display_width(clipped)
  let pad = if width > used { width - used } else { 0 }
  match align {
    Right => spaces(pad) + clipped
    Center => {
      let left = pad / 2
      spaces(left) + clipped + spaces(pad - left)
    }
    _ => clipped + spaces(pad)
  }
}

///|
fn fit_columns(widths : Array[Int32], budget : Int32) -> Unit {
  if widths.length() == 0 {
    return
  }
  let mut total = 0
  for column_width in widths {
    total = total + column_width
  }
  total = total + 2 * (widths.length() - 1)
  while total > budget {
    let mut widest = 1
    let mut widest_index = 0
    let mut index = 0
    for column_width in widths {
      if column_width > widest {
        widest = column_width
        widest_index = index
      }
      index = index + 1
    }
    if widest <= 1 {
      break
    }
    widths[widest_index] = widest - 1
    total = total - 1
  }
}

///|
/// 给块加前缀（引用、列表项、脚注）：前缀单独一段样式，不抢正文颜色。
fn prefix_lines(
  lines : Array[StyledLine],
  prefix : String,
  fg : String,
) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  for line in lines {
    if line.text.is_empty() {
      out.push(blank_line())
    } else {
      out.push(prefixed_line(line, prefix, Some(fg)))
    }
  }
  out
}

///|
fn prefixed_line(
  line : StyledLine,
  prefix : String,
  fg : String?,
) -> StyledLine {
  let spans : Array[MarkdownSpan] = [{ text: prefix, fg, bold: false, inverse: false }]
  match line.spans {
    Some(inner) =>
      for span in inner {
        spans.push(span)
      }
    None => spans.push({ text: line.text, fg: line.fg, bold: line.bold, inverse: false })
  }
  {
    ..line,
    text: prefix + line.text,
    fg: None,
    bold: false,
    spans: Some(spans),
  }
}

///|
/// 首段（```` ```diff ```` 的 `diff`）：语言名后面可能跟文件名。
fn first_word(text : String) -> String {
  let trimmed = text.trim(chars=" ").to_owned()
  for word in trimmed.split(" ") {
    return word.to_owned()
  }
  ""
}

///|
/// 行内 AST → 带样式的段。相邻同款式的段会合并，界面上少几个 text 节点。
fn inline_spans(
  inlines : Array[@md.Inline],
  base_fg : String?,
  base_bold : Bool,
  defs : Array[@md.LinkDefinition],
  colors : MarkdownColors,
) -> Array[MarkdownSpan] {
  let spans : Array[MarkdownSpan] = []
  for inline in inlines {
    match inline {
      @md.Inline::Text(content~, ..) =>
        push_span(spans, content, base_fg, base_bold)
      @md.Inline::SoftBreak(..) => push_span(spans, " ", base_fg, base_bold)
      // 硬换行落成一个换行单元格，由 wrap_spans 断开。
      @md.Inline::HardBreak(..) => push_span(spans, "\n", base_fg, base_bold)
      // 终端没有斜体开关：强调只保留文字，不假装。
      @md.Inline::Emphasis(children~, ..) =>
        push_all(
          spans,
          inline_spans(children, base_fg, base_bold, defs, colors),
        )
      @md.Inline::Strong(children~, ..) =>
        push_all(spans, inline_spans(children, base_fg, true, defs, colors))
      @md.Inline::Strikethrough(children~, ..) =>
        push_all(
          spans,
          inline_spans(children, base_fg, base_bold, defs, colors),
        )
      @md.Inline::Code(content~, ..) =>
        push_span(spans, content, Some(colors.code), base_bold)
      @md.Inline::Link(children~, url~, ..) =>
        push_link(spans, children, url, base_bold, colors)
      @md.Inline::RefLink(children~, label~, ..) => {
        let url = lookup_definition(defs, label)
        push_link(spans, children, url, base_bold, colors)
      }
      @md.Inline::Autolink(url~, ..) =>
        push_span(spans, url, Some(colors.link), base_bold)
      @md.Inline::Image(alt~, url~, ..) =>
        push_span(
          spans,
          "![" + alt + "](" + url + ")",
          Some(colors.quote),
          base_bold,
        )
      @md.Inline::RefImage(alt~, label~, ..) =>
        push_span(
          spans,
          "![" + alt + "][" + label + "]",
          Some(colors.quote),
          base_bold,
        )
      @md.Inline::WikiLink(target~, label~, ..) => {
        let shown = if label.is_empty() { target } else { label }
        push_span(spans, shown, Some(colors.link), base_bold)
      }
      @md.Inline::HtmlInline(html~, ..) =>
        push_span(spans, html, Some(colors.quote), base_bold)
      @md.Inline::FootnoteReference(label~, ..) =>
        push_span(spans, "[^" + label + "]", Some(colors.quote), base_bold)
      @md.Inline::Directive(name~, label~, ..) =>
        push_span(
          spans,
          ":" + name + "[" + label + "]",
          Some(colors.quote),
          base_bold,
        )
    }
  }
  spans
}

///|
/// 链接：文字用链接色，地址另起一段灰字（与 ela 的渲染一致）。
fn push_link(
  spans : Array[MarkdownSpan],
  children : Array[@md.Inline],
  url : String,
  base_bold : Bool,
  colors : MarkdownColors,
) -> Unit {
  let label = inline_plain(children)
  push_span(spans, label, Some(colors.link), base_bold)
  if !url.is_empty() && url != label {
    push_span(spans, " (" + url + ")", Some(colors.quote), base_bold)
  }
}

///|
fn lookup_definition(
  defs : Array[@md.LinkDefinition],
  label : String,
) -> String {
  for def in defs {
    if def.label.to_lower() == label.to_lower() {
      return def.url
    }
  }
  ""
}

///|
/// 纯文字版本（表格单元格、单行摘要用）：样式会被丢掉。
fn inline_plain(inlines : Array[@md.Inline]) -> String {
  let buf : Array[Char] = []
  append_plain(buf, inlines)
  String::from_array(buf)
}

///|
fn append_plain(buf : Array[Char], inlines : Array[@md.Inline]) -> Unit {
  for inline in inlines {
    match inline {
      @md.Inline::Text(content~, ..) => push_chars(buf, content)
      @md.Inline::Code(content~, ..) => push_chars(buf, content)
      @md.Inline::SoftBreak(..) => buf.push(' ')
      @md.Inline::HardBreak(..) => buf.push(' ')
      @md.Inline::Emphasis(children~, ..) => append_plain(buf, children)
      @md.Inline::Strong(children~, ..) => append_plain(buf, children)
      @md.Inline::Strikethrough(children~, ..) => append_plain(buf, children)
      @md.Inline::Link(children~, ..) => append_plain(buf, children)
      @md.Inline::RefLink(children~, ..) => append_plain(buf, children)
      @md.Inline::Autolink(url~, ..) => push_chars(buf, url)
      @md.Inline::Image(alt~, ..) => push_chars(buf, alt)
      @md.Inline::RefImage(alt~, ..) => push_chars(buf, alt)
      @md.Inline::WikiLink(target~, label~, ..) =>
        if label.is_empty() {
          push_chars(buf, target)
        } else {
          push_chars(buf, label)
        }
      @md.Inline::HtmlInline(html~, ..) => push_chars(buf, html)
      @md.Inline::FootnoteReference(label~, ..) =>
        push_chars(buf, "[^" + label + "]")
      @md.Inline::Directive(name~, label~, ..) =>
        push_chars(buf, ":" + name + "[" + label + "]")
    }
  }
}

///|
fn push_chars(buf : Array[Char], text : String) -> Unit {
  for c in text {
    buf.push(c)
  }
}

///|
fn push_span(
  spans : Array[MarkdownSpan],
  text : String,
  fg : String?,
  bold : Bool,
) -> Unit {
  if text.is_empty() {
    return
  }
  if spans.length() > 0 {
    let index = spans.length() - 1
    let last = spans[index]
    if last.fg == fg && last.bold == bold && !last.text.contains("\n") {
      spans[index] = { text: last.text + text, fg, bold, inverse: false }
      return
    }
  }
  spans.push({ text, fg, bold, inverse: false })
}

///|
fn push_all(dst : Array[MarkdownSpan], src : Array[MarkdownSpan]) -> Unit {
  for span in src {
    push_span(dst, span.text, span.fg, span.bold)
  }
}

///|
/// 带样式的折行：先铺成单元格，再按显示宽度贪心折，最后按样式合并成 span。
/// `\n` 是硬换行，不走宽度判断。
fn wrap_spans(spans : Array[MarkdownSpan], width : Int32) -> Array[StyledLine] {
  let limit = if width > 0 { width } else { 1 }
  let cells : Array[MarkdownCell] = []
  for span in spans {
    for c in span.text {
      if c == '\t' {
        // 代码块里的 tab 按 4 格展开：终端里 tab 的落点不定，先把位置钉死。
        for _ in 0..<4 {
          cells.push({ c: ' ', fg: span.fg, bold: span.bold, })
        }
      } else {
        cells.push({ c, fg: span.fg, bold: span.bold, })
      }
    }
  }
  if cells.is_empty() {
    return [blank_line()]
  }
  let out : Array[StyledLine] = []
  let mut line_start = 0
  let mut used : Int32 = 0
  let mut last_space = -1
  let mut index = 0
  while index < cells.length() {
    let cell = cells[index]
    if cell.c == '\n' {
      out.push(cells_to_line(cells, line_start, index))
      index = index + 1
      line_start = index
      used = 0
      last_space = -1
      continue
    }
    let char_width = @core.char_display_width(cell.c)
    if used + char_width > limit && index > line_start {
      if last_space > line_start {
        out.push(cells_to_line(cells, line_start, last_space))
        line_start = last_space + 1
      } else {
        out.push(cells_to_line(cells, line_start, index))
        line_start = index
      }
      used = 0
      last_space = -1
      let mut scan = line_start
      while scan <= index && scan < cells.length() {
        if cells[scan].c == ' ' {
          last_space = scan
        }
        used = used + @core.char_display_width(cells[scan].c)
        scan = scan + 1
      }
      index = index + 1
      continue
    }
    if cell.c == ' ' {
      last_space = index
    }
    used = used + char_width
    index = index + 1
  }
  if line_start < cells.length() {
    out.push(cells_to_line(cells, line_start, cells.length()))
  }
  if out.is_empty() {
    out.push(blank_line())
  }
  out
}

///|
fn cells_to_line(
  cells : Array[MarkdownCell],
  start : Int32,
  end : Int32,
) -> StyledLine {
  // 行尾空格只是为了折行方便，不该带着底色/样式留在屏幕上。
  let mut last = end
  while last > start && cells[last - 1].c == ' ' {
    last = last - 1
  }
  if last <= start {
    return blank_line()
  }
  let spans : Array[MarkdownSpan] = []
  let text_chars : Array[Char] = []
  let mut index = start
  while index < last {
    let cell = cells[index]
    let run_start = index
    while index < last &&
          cells[index].fg == cell.fg &&
          cells[index].bold == cell.bold {
      text_chars.push(cells[index].c)
      index = index + 1
    }
    spans.push({
      text: slice_cells(cells, run_start, index),
      fg: cell.fg,
      bold: cell.bold,
      inverse: false,
    })
  }
  {
    text: String::from_array(text_chars),
    fg: None,
    bg: None,
    bold: false,
    spans: Some(spans),
  }
}

///|
fn slice_cells(
  cells : Array[MarkdownCell],
  start : Int32,
  end : Int32,
) -> String {
  let out : Array[Char] = []
  let mut index = start
  while index < end {
    out.push(cells[index].c)
    index = index + 1
  }
  String::from_array(out)
}

///|
fn trim_blank_edges(lines : Array[StyledLine]) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  let mut started = false
  for line in lines {
    if !started && line.text.is_empty() {
      continue
    }
    if !line.text.is_empty() {
      started = true
    }
    out.push(line)
  }
  while out.length() > 0 && out[out.length() - 1].text.is_empty() {
    let _ = out.pop()
  }
  if out.is_empty() {
    out.push(blank_line())
  }
  out
}
