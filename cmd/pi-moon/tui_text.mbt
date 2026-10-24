// TUI 的排版零件：折行、截断、行样式。
//
// 这些是纯函数，和终端、agent 都无关 —— 折行算错只会让界面难看，但算错的
// 原因是「按 char 数折」而不是「按显示宽度折」：CJK 一个字符占两格，
// 按 char 数折会让整行越出边框，右边那一列就再也画不回来了。

///|
/// 屏幕上一行的内容与样式。
///
/// 颜色用 vnode 认的名字（8 色 + `rgb(...)`）；`None` 表示用终端默认色。
pub(all) struct StyledLine {
  text : String
  fg : String?
  bg : String?
  bold : Bool
  /// 行内有多段样式时（markdown 的 code / link / 标题）用这个；`None` 就是
  /// 整行一个样式（工具块、状态行这些）。
  spans : Array[MarkdownSpan]?
} derive(Eq, Debug)

///|
pub fn plain_line(text : String) -> StyledLine {
  { text, fg: None, bg: None, bold: false, spans: None, }
}

///|
pub fn styled_line(
  text : String,
  fg : String,
  bold~ : Bool = false,
  bg? : String,
) -> StyledLine {
  { text, fg: Some(fg), bg, bold, spans: None, }
}

///|
pub fn blank_line() -> StyledLine {
  { text: "", fg: None, bg: None, bold: false, spans: None, }
}

///|
/// 字符串在终端里占几格。
pub fn display_width(text : String) -> Int32 {
  @core.string_display_width(text)
}

///|
/// 按显示宽度折行；`width <= 0` 时不折。
///
/// 贪心折：优先在最后一个空格处断（英文不断词），没有空格时才在宽度边界断
/// （CJK 没有空格可断，只能逐字）。显式换行永远保留 —— 工具输出里的行结构
/// 是有意义的。
pub fn wrap_text(text : String, width : Int32) -> Array[String] {
  if width <= 0 {
    return [text]
  }
  let out : Array[String] = []
  for paragraph in text.split("\n") {
    wrap_paragraph(paragraph.to_owned(), width, out)
  }
  out
}

///|
fn wrap_paragraph(text : String, width : Int32, out : Array[String]) -> Unit {
  if text.is_empty() {
    out.push("")
    return
  }
  let mut line : Array[Char] = []
  let mut line_width = 0
  // 最后一个空格在 line 里的下标；换行时从它**后面**接上余下的字符。
  let mut last_space = -1
  for c in text {
    let char_width = @core.char_display_width(c)
    if line_width + char_width > width && !line.is_empty() {
      if last_space > 0 {
        let head : Array[Char] = []
        for index in 0..<last_space {
          head.push(line[index])
        }
        let tail : Array[Char] = []
        for index in (last_space + 1)..<line.length() {
          tail.push(line[index])
        }
        out.push(String::from_array(head))
        line = tail
        line_width = chars_width(line)
        last_space = last_space_in(line)
      } else {
        out.push(String::from_array(line))
        line = []
        line_width = 0
        last_space = -1
      }
    }
    line.push(c)
    line_width = line_width + char_width
    if c == ' ' {
      last_space = line.length() - 1
    }
  }
  out.push(String::from_array(line))
}

///|
fn chars_width(chars : Array[Char]) -> Int32 {
  let mut total = 0
  for c in chars {
    total = total + @core.char_display_width(c)
  }
  total
}

///|
fn last_space_in(chars : Array[Char]) -> Int32 {
  let mut found = -1
  let mut index = 0
  while index < chars.length() {
    if chars[index] == ' ' {
      found = index
    }
    index = index + 1
  }
  found
}

///|
/// 首行带前缀、后续行按前缀宽度缩进的折行。
///
/// 「这个人说了什么」靠前缀区分；缩进让整块看起来还是一段，而不是下一段
/// 突然换了说话人。
pub fn wrap_prefixed(
  prefix : String,
  text : String,
  width : Int32,
) -> Array[String] {
  let indent = display_width(prefix)
  let body_width = if width > indent { width - indent } else { 1 }
  let body = wrap_text(text, body_width)
  let out : Array[String] = []
  let mut first = true
  for line in body {
    if first {
      out.push(prefix + line)
      first = false
    } else {
      out.push(spaces(indent) + line)
    }
  }
  if out.is_empty() {
    out.push(prefix)
  }
  out
}

///|
/// 若干空格（用于缩进）。
pub fn spaces(count : Int32) -> String {
  let chars : Array[Char] = []
  for _ in 0..<count {
    chars.push(' ')
  }
  String::from_array(chars)
}

///|
/// 截到显示宽度，超出补省略号。
pub fn truncate_to(text : String, width : Int32) -> String {
  if width <= 0 {
    return ""
  }
  if display_width(text) <= width {
    return text
  }
  let chars : Array[Char] = []
  let mut used = 0
  for c in text {
    let char_width = @core.char_display_width(c)
    if used + char_width > width - 1 {
      break
    }
    chars.push(c)
    used = used + char_width
  }
  String::from_array(chars) + "…"
}

///|
/// 取前 `limit` 行（工具输出折叠用）。
pub fn first_lines(text : String, limit : Int32) -> Array[String] {
  let out : Array[String] = []
  for line in text.split("\n") {
    if out.length() >= limit {
      break
    }
    out.push(line.to_owned())
  }
  out
}

///|
/// 行数（空串算 1 行，与 `split` 的行为一致）。
pub fn line_count(text : String) -> Int32 {
  let mut count = 0
  for _ in text.split("\n") {
    count = count + 1
  }
  count
}

///|
/// 补齐到整行宽度（按显示列宽算）。
///
/// pi-tui 是**增量**重绘：行变短时旧字的尾巴不会被擦掉。底栏 / 页签 / 带底色的
/// 块都必须补到全宽，否则下一帧会叠着出现（看起来像重复刷屏）。汉字是双宽，
/// 按 `String::length` 补会少一截。
pub fn pad_to_width(text : String, width : Int32) -> String {
  let used = display_width(text)
  if used >= width {
    text
  } else {
    text + spaces(width - used)
  }
}

///|
/// 一整行横线。
pub fn rule(width : Int32) -> String {
  let chars : Array[Char] = []
  for _ in 0..<width {
    chars.push('─')
  }
  String::from_array(chars)
}

///|
/// `twoColumn(left, right, width)`：左右两段，中间用空格补齐。
///
/// 放不下时右边优先（模型名是定位信息），与 ela 的 `twoColumn` 同一口径。
pub fn two_column(left : String, right : String, width : Int32) -> String {
  let left_width = display_width(left)
  let right_width = display_width(right)
  if left_width + right_width + 1 > width {
    truncate_to(left + " " + right, width)
  } else {
    left + spaces(width - left_width - right_width) + right
  }
}

///|
/// 一位小数（`1.324` → `1.3`，`1.0` 保持 `1.0`）—— pi 的 `toFixed(1)` 同形。
pub fn one_decimal(value : Double) -> String {
  let tenths = (value * 10.0).round().to_int()
  (tenths / 10).to_string() + "." + (tenths % 10).to_string()
}

///|
/// token 数量的短写，与 pi 的 `formatTokens` 逐条一致。
pub fn format_tokens(count : Int32) -> String {
  if count < 1000 {
    count.to_string()
  } else if count < 10000 {
    one_decimal(count.to_double() / 1000.0) + "k"
  } else if count < 1000000 {
    (count.to_double() / 1000.0).round().to_int().to_string() + "k"
  } else if count < 10000000 {
    one_decimal(count.to_double() / 1000000.0) + "M"
  } else {
    (count.to_double() / 1000000.0).round().to_int().to_string() + "M"
  }
}

///|
/// 一位小数的百分比。
pub fn format_percent(value : Double) -> String {
  let tenths = (value * 10.0).round().to_int()
  (tenths / 10).to_string() + "." + (tenths % 10).to_string() + "%"
}

///|
/// 把家目录缩成 `~`（与 pi 的 `formatCwdForFooter` 同一效果）。
pub fn shorten_home(path : String, home : String) -> String {
  if home.is_empty() {
    return path
  }
  if path == home {
    return "~"
  }
  if path.has_prefix(home + "/") {
    return "~/" + path[home.length() + 1:].to_owned()
  }
  if path.has_prefix(home + "\\") {
    return "~\\" + path[home.length() + 1:].to_owned()
  }
  path
}

///|
/// 压成一行（排队消息只占一行，多行会把输入框顶下去）。
pub fn one_line(text : String) -> String {
  let chars : Array[Char] = []
  let mut last_space = false
  for c in text {
    if c == '\n' || c == '\r' || c == '\t' {
      if !last_space {
        chars.push(' ')
        last_space = true
      }
    } else {
      chars.push(c)
      last_space = c == ' '
    }
  }
  String::from_array(chars).trim(chars=" ").to_owned()
}
