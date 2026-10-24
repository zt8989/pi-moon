// 最小 markdown：块级（围栏代码 / 标题 / 列表 / 引用 / 分隔线）+ 行内
// （code / 粗体 / 链接）。
//
// 不追求 CommonMark：对话流里真正影响可读性的就是这几样，剩下的按原文显示
// 比「猜错了把内容吃掉」安全。样式也只用终端给得起的（前景色 + 粗体）——
// 斜体、下划线这些在 vnode 的 text 上没有开关。
//
// 折行必须按**单元格**做，不能先拼成字符串再折：`**加粗**` 拆开之后要保留
// 每一段的样式，先折字符串就等于把样式信息丢了。

///|
pub(all) struct MarkdownSpan {
  text : String
  fg : String?
  bold : Bool
} derive(Eq, Debug)

///|
struct MarkdownCell {
  c : Char
  fg : String?
  bold : Bool
}

///|
let color_md_code : String = "magenta"

///|
let color_md_link : String = "cyan"

///|
let color_md_code_block : String = "rgb(200,200,210)"

///|
/// markdown 文本 → 屏幕行（宽度已经是**内容宽度**：调用方自己把左侧内边距
/// 算进去）。
pub fn markdown_lines(text : String, width : Int32) -> Array[StyledLine] {
  let out : Array[StyledLine] = []
  let mut in_code = false
  for raw in text.split("\n") {
    let line = raw.to_owned()
    let chars = line.to_array()
    let trimmed = trim_start_chars(chars)
    if is_fence(trimmed) {
      out.push(dim_line("  " + chars_to_string(trimmed)))
      in_code = !in_code
      continue
    }
    if in_code {
      for wrapped in wrap_prefixed("  ", line, width) {
        out.push(styled_line(wrapped, color_md_code_block))
      }
      continue
    }
    if is_blank(chars) {
      out.push(blank_line())
      continue
    }
    if is_rule(trimmed) {
      out.push(dim_line(rule(width)))
      continue
    }
    let heading = heading_level(trimmed)
    if heading > 0 {
      let content = drop_chars(trimmed, heading + 1)
      let spans = parse_inline(content, None, true)
      push_wrapped_spans(out, spans, width)
      continue
    }
    let indent = leading_spaces(chars)
    let rest = drop_chars(chars, indent)
    if list_marker(rest) is Some(content_at) {
      let spans : Array[MarkdownSpan] = [
        { text: spaces(indent) + "• ", fg: None, bold: false, },
      ]
      let body = parse_inline(drop_chars(rest, content_at), None, false)
      for span in body {
        spans.push(span)
      }
      push_wrapped_spans(out, spans, width)
      continue
    }
    if rest.length() > 0 && rest[0] == '>' {
      let mut body_at = 1
      if body_at < rest.length() && rest[body_at] == ' ' {
        body_at = body_at + 1
      }
      let spans : Array[MarkdownSpan] = [
        {
          text: spaces(indent) + "│ ",
          fg: Some("rgb(150,152,160)"),
          bold: false,
        },
      ]
      let body = parse_inline(
        drop_chars(rest, body_at),
        Some("rgb(150,152,160)"),
        false,
      )
      for span in body {
        spans.push(span)
      }
      push_wrapped_spans(out, spans, width)
      continue
    }
    let spans = parse_inline(chars, None, false)
    push_wrapped_spans(out, spans, width)
  }
  out
}

///|
fn push_wrapped_spans(
  out : Array[StyledLine],
  spans : Array[MarkdownSpan],
  width : Int32,
) -> Unit {
  for line in wrap_spans(spans, width) {
    out.push(line)
  }
}

///|
fn is_fence(chars : Array[Char]) -> Bool {
  let s = chars_to_string(chars)
  s.has_prefix("```") || s.has_prefix("~~~")
}

///|
fn is_blank(chars : Array[Char]) -> Bool {
  for c in chars {
    if c != ' ' && c != '\t' {
      return false
    }
  }
  true
}

///|
fn is_rule(chars : Array[Char]) -> Bool {
  if chars.length() < 3 {
    return false
  }
  let marker = chars[0]
  if marker != '-' && marker != '*' && marker != '_' {
    return false
  }
  for c in chars {
    if c != marker {
      return false
    }
  }
  true
}

///|
/// 标题级别（`### x` → 3）；不是标题返回 0。
fn heading_level(chars : Array[Char]) -> Int32 {
  let mut hashes = 0
  while hashes < chars.length() && chars[hashes] == '#' {
    hashes = hashes + 1
  }
  if hashes == 0 || hashes > 6 {
    return 0
  }
  if hashes >= chars.length() || chars[hashes] != ' ' {
    return 0
  }
  hashes
}

///|
/// 无序列表标记：返回正文起点（跳过 `- ` / `* ` / `+ `），不是列表返回 None。
fn list_marker(chars : Array[Char]) -> Int32? {
  if chars.length() >= 2 {
    let marker = chars[0]
    if (marker == '-' || marker == '*' || marker == '+') && chars[1] == ' ' {
      return Some(2)
    }
  }
  None
}

///|
fn leading_spaces(chars : Array[Char]) -> Int32 {
  let mut count = 0
  while count < chars.length() && (chars[count] == ' ' || chars[count] == '\t') {
    count = count + 1
  }
  count
}

///|
fn trim_start_chars(chars : Array[Char]) -> Array[Char] {
  drop_chars(chars, leading_spaces(chars))
}

///|
fn drop_chars(chars : Array[Char], count : Int32) -> Array[Char] {
  let out : Array[Char] = []
  let mut index = count
  while index < chars.length() {
    out.push(chars[index])
    index = index + 1
  }
  out
}

///|
fn chars_to_string(chars : Array[Char]) -> String {
  String::from_array(chars)
}

///|
fn slice_text(chars : Array[Char], start : Int32, end : Int32) -> String {
  let out : Array[Char] = []
  let mut index = start
  while index < end && index < chars.length() {
    out.push(chars[index])
    index = index + 1
  }
  String::from_array(out)
}

///|
/// 行内解析：`code` / **bold** / [text](url)。找不到闭合就按原文保留。
fn parse_inline(
  chars : Array[Char],
  base_fg : String?,
  base_bold : Bool,
) -> Array[MarkdownSpan] {
  let spans : Array[MarkdownSpan] = []
  let buffer : Array[Char] = []
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '`' {
      let close = find_char(chars, i + 1, '`')
      if close >= 0 {
        flush_plain(spans, buffer, base_fg, base_bold)
        spans.push({
          text: slice_text(chars, i + 1, close),
          fg: Some(color_md_code),
          bold: false,
        })
        i = close + 1
        continue
      }
    }
    if c == '*' && i + 1 < n && chars[i + 1] == '*' {
      let close = find_seq(chars, i + 2, "*")
      if close >= 0 {
        flush_plain(spans, buffer, base_fg, base_bold)
        spans.push({
          text: slice_text(chars, i + 2, close),
          fg: base_fg,
          bold: true,
        })
        i = close + 2
        continue
      }
    }
    if c == '[' {
      let close_label = find_char(chars, i + 1, ']')
      if close_label >= 0 &&
        close_label + 1 < n &&
        chars[close_label + 1] == '(' {
        let close_url = find_char(chars, close_label + 2, ')')
        if close_url >= 0 {
          flush_plain(spans, buffer, base_fg, base_bold)
          spans.push({
            text: slice_text(chars, i + 1, close_label),
            fg: Some(color_md_link),
            bold: false,
          })
          let url = slice_text(chars, close_label + 2, close_url)
          if !url.is_empty() {
            spans.push({
              text: " (" + url + ")",
              fg: Some("rgb(150,152,160)"),
              bold: false,
            })
          }
          i = close_url + 1
          continue
        }
      }
    }
    buffer.push(c)
    i = i + 1
  }
  flush_plain(spans, buffer, base_fg, base_bold)
  spans
}

///|
fn flush_plain(
  spans : Array[MarkdownSpan],
  buffer : Array[Char],
  fg : String?,
  bold : Bool,
) -> Unit {
  if buffer.is_empty() {
    return
  }
  spans.push({ text: String::from_array(buffer), fg, bold, })
  buffer.clear()
}

///|
fn find_char(chars : Array[Char], start : Int32, needle : Char) -> Int32 {
  let mut index = start
  while index < chars.length() {
    if chars[index] == needle {
      return index
    }
    index = index + 1
  }
  -1
}

///|
fn find_seq(chars : Array[Char], start : Int32, needle : String) -> Int32 {
  let target = needle.to_array()
  let mut index = start
  while index + target.length() <= chars.length() {
    let mut matched = true
    let mut offset = 0
    while offset < target.length() {
      if chars[index + offset] != target[offset] {
        matched = false
        break
      }
      offset = offset + 1
    }
    if matched {
      return index
    }
    index = index + 1
  }
  -1
}

///|
/// 带样式的折行：先铺成单元格，再按显示宽度贪心折，最后按样式合并成 span。
fn wrap_spans(spans : Array[MarkdownSpan], width : Int32) -> Array[StyledLine] {
  let cells : Array[MarkdownCell] = []
  for span in spans {
    for c in span.text {
      cells.push({ c, fg: span.fg, bold: span.bold, })
    }
  }
  if cells.is_empty() {
    return [blank_line()]
  }
  if width <= 0 {
    return [cells_to_line(cells, 0, cells.length())]
  }
  let out : Array[StyledLine] = []
  let mut start = 0
  while start < cells.length() {
    let mut used : Int32 = 0
    let mut index = start
    let mut last_space = -1
    while index < cells.length() {
      let char_width = @core.char_display_width(cells[index].c)
      if used + char_width > width && index > start {
        break
      }
      if cells[index].c == ' ' {
        last_space = index
      }
      used = used + char_width
      index = index + 1
    }
    if index >= cells.length() {
      out.push(cells_to_line(cells, start, cells.length()))
      break
    }
    if last_space > start {
      out.push(cells_to_line(cells, start, last_space))
      start = last_space + 1
    } else {
      out.push(cells_to_line(cells, start, index))
      start = index
    }
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
