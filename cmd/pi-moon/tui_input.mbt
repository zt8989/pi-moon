// 输入区（composer）的编辑逻辑。
//
// 光标用**字符下标**而不是字节下标：中文输入法送来的是多字节字符，按字节
// 移动光标会切在半个字上 —— 那在终端里是不可恢复的乱码。渲染时再按显示
// 宽度决定窗口，两件事分开算。

///|
/// 在光标处插入一段文本，返回新的文本与光标位置。
pub fn insert_text(
  input : String,
  cursor : Int32,
  text : String,
) -> (String, Int32) {
  let chars = input.to_array()
  let at = clamp_cursor(cursor, chars.length())
  let tail : Array[Char] = []
  for index in at..<chars.length() {
    tail.push(chars[index])
  }
  let next : Array[Char] = []
  for index in 0..<at {
    next.push(chars[index])
  }
  let mut inserted = 0
  for c in text {
    if c != '\n' && c != '\r' && c.to_int() >= 32 {
      next.push(c)
      inserted = inserted + 1
    }
  }
  for c in tail {
    next.push(c)
  }
  (String::from_array(next), at + inserted)
}

///|
/// 退格：删光标前一个字符。
pub fn backspace(input : String, cursor : Int32) -> (String, Int32) {
  let chars = input.to_array()
  let at = clamp_cursor(cursor, chars.length())
  if at == 0 {
    return (input, 0)
  }
  (remove_char_at(chars, at - 1), at - 1)
}

///|
/// Delete：删光标所在字符。
pub fn delete_forward(input : String, cursor : Int32) -> (String, Int32) {
  let chars = input.to_array()
  let at = clamp_cursor(cursor, chars.length())
  if at >= chars.length() {
    return (input, at)
  }
  (remove_char_at(chars, at), at)
}

///|
fn remove_char_at(chars : Array[Char], at : Int32) -> String {
  let out : Array[Char] = []
  let mut index = 0
  while index < chars.length() {
    if index != at {
      out.push(chars[index])
    }
    index = index + 1
  }
  String::from_array(out)
}

///|
pub fn clamp_cursor(cursor : Int32, length : Int32) -> Int32 {
  if cursor < 0 {
    0
  } else if cursor > length {
    length
  } else {
    cursor
  }
}

///|
pub fn cursor_left(cursor : Int32) -> Int32 {
  if cursor > 0 {
    cursor - 1
  } else {
    0
  }
}

///|
pub fn cursor_right(cursor : Int32, length : Int32) -> Int32 {
  if cursor < length {
    cursor + 1
  } else {
    length
  }
}

///|
pub fn char_count(text : String) -> Int32 {
  let mut count = 0
  for _ in text {
    count = count + 1
  }
  count
}

///|
/// 把编辑区画成一行（含光标块）。
///
/// 只有一个可视窗口：光标左边放不下时从左边裁掉，右边放不下时从右边裁掉 ——
/// 光标永远可见，否则用户按了键看不到自己按在哪。
pub fn render_editor(input : String, cursor : Int32, width : Int32) -> String {
  if width <= 0 {
    return ""
  }
  let chars = input.to_array()
  let at = clamp_cursor(cursor, chars.length())
  // 光标块占一格；先保证「光标之前」最多占 width-1。
  let mut start = 0
  let mut before_width = chars_width_between(chars, 0, at)
  while before_width > width - 1 && start < at {
    before_width = before_width - @core.char_display_width(chars[start])
    start = start + 1
  }
  let out : Array[Char] = []
  for index in start..<at {
    out.push(chars[index])
  }
  out.push('█')
  let mut used = before_width + 1
  let mut index = at
  while index < chars.length() {
    let char_width = @core.char_display_width(chars[index])
    if used + char_width > width {
      break
    }
    out.push(chars[index])
    used = used + char_width
    index = index + 1
  }
  String::from_array(out)
}

///|
fn chars_width_between(
  chars : Array[Char],
  start : Int32,
  end : Int32,
) -> Int32 {
  let mut total = 0
  let mut index = start
  while index < end {
    total = total + @core.char_display_width(chars[index])
    index = index + 1
  }
  total
}
