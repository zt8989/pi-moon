// 输出截断与文本工具 —— 与 pi 的 `truncate.ts` 同口径。
//
// 两个独立上限，谁先撞上谁生效：行数（默认 2000）与字节数（默认 50KB）。
// 截断**不返回半个行**（bash 的末尾截断有一个例外：最后一行本身超限时取行尾）。

///|
pub let default_max_lines : Int32 = 2000

///|
pub let default_max_bytes : Int32 = 50 * 1024

///|
pub let grep_max_line_length : Int32 = 500

///|
pub(all) struct TruncatedText {
  content : String
  truncated : Bool
  /// "lines" / "bytes" / ""（没截断）。
  truncated_by : String
  total_lines : Int32
  output_lines : Int32
  total_bytes : Int32
  output_bytes : Int32
  last_line_partial : Bool
  first_line_exceeds_limit : Bool
} derive(Debug)

///|
pub fn byte_length(text : String) -> Int32 {
  @utf8.encode(text).length()
}

///|
/// 按 JS 的 `split("\n")` 数行：末尾换行会产生一个空行，但
/// `splitLinesForCounting` 会把它去掉（空内容算 0 行）。
pub fn split_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  if text.is_empty() {
    return out
  }
  let mut start = 0
  let mut index = 0
  while index < text.length() {
    if text.get_char(index) == Some('\n') {
      out.push(text[start:index].to_owned())
      start = index + 1
    }
    index = index + 1
  }
  out.push(text[start:].to_owned())
  if text.has_suffix("\n") {
    let _ = out.pop()
  }
  out
}

///|
/// 从头部截断（read 用：看开头）。
pub fn truncate_head(
  content : String,
  max_lines~ : Int32 = default_max_lines,
  max_bytes~ : Int32 = default_max_bytes,
) -> TruncatedText {
  let lines = split_lines(content)
  let total_lines = lines.length()
  let total_bytes = byte_length(content)
  if total_lines <= max_lines && total_bytes <= max_bytes {
    return {
      content,
      truncated: false,
      truncated_by: "",
      total_lines,
      output_lines: total_lines,
      total_bytes,
      output_bytes: total_bytes,
      last_line_partial: false,
      first_line_exceeds_limit: false,
    }
  }
  if total_lines > 0 && byte_length(lines[0]) > max_bytes {
    return {
      content: "",
      truncated: true,
      truncated_by: "bytes",
      total_lines,
      output_lines: 0,
      total_bytes,
      output_bytes: 0,
      last_line_partial: false,
      first_line_exceeds_limit: true,
    }
  }
  let kept : Array[String] = []
  let mut output_bytes = 0
  let mut truncated_by = "lines"
  let mut index = 0
  while index < lines.length() && index < max_lines {
    let line = lines[index]
    let line_bytes = byte_length(line) + (if index > 0 { 1 } else { 0 })
    if output_bytes + line_bytes > max_bytes {
      truncated_by = "bytes"
      break
    }
    kept.push(line)
    output_bytes = output_bytes + line_bytes
    index = index + 1
  }
  if kept.length() >= max_lines && output_bytes <= max_bytes {
    truncated_by = "lines"
  }
  let output = kept.join("\n")
  {
    content: output,
    truncated: true,
    truncated_by,
    total_lines,
    output_lines: kept.length(),
    total_bytes,
    output_bytes: byte_length(output),
    last_line_partial: false,
    first_line_exceeds_limit: false,
  }
}

///|
/// 从尾部截断（bash 用：看最后的结果 / 报错）。
pub fn truncate_tail(
  content : String,
  max_lines~ : Int32 = default_max_lines,
  max_bytes~ : Int32 = default_max_bytes,
) -> TruncatedText {
  let lines = split_lines(content)
  let total_lines = lines.length()
  let total_bytes = byte_length(content)
  if total_lines <= max_lines && total_bytes <= max_bytes {
    return {
      content,
      truncated: false,
      truncated_by: "",
      total_lines,
      output_lines: total_lines,
      total_bytes,
      output_bytes: total_bytes,
      last_line_partial: false,
      first_line_exceeds_limit: false,
    }
  }
  let kept : Array[String] = []
  let mut output_bytes = 0
  let mut truncated_by = "lines"
  let mut last_line_partial = false
  let mut index = lines.length() - 1
  while index >= 0 && kept.length() < max_lines {
    let line = lines[index]
    let line_bytes = byte_length(line) + (if kept.is_empty() { 0 } else { 1 })
    if output_bytes + line_bytes > max_bytes {
      truncated_by = "bytes"
      if kept.is_empty() {
        // 最后一行本身就超限：取行尾，避免「什么也没留下」。
        let partial = truncate_to_bytes_from_end(line, max_bytes)
        kept.push(partial)
        output_bytes = byte_length(partial)
        last_line_partial = true
      }
      break
    }
    kept.push(line)
    output_bytes = output_bytes + line_bytes
    index = index - 1
  }
  if kept.length() >= max_lines && output_bytes <= max_bytes {
    truncated_by = "lines"
  }
  kept.rev_in_place()
  let output = kept.join("\n")
  {
    content: output,
    truncated: true,
    truncated_by,
    total_lines,
    output_lines: kept.length(),
    total_bytes,
    output_bytes: byte_length(output),
    last_line_partial,
    first_line_exceeds_limit: false,
  }
}

///|
/// 取一行的末尾 `max_bytes` 字节（落在 UTF-8 字符边界上）。
fn truncate_to_bytes_from_end(text : String, max_bytes : Int32) -> String {
  let bytes = @utf8.encode(text)
  let total = bytes.length()
  if total <= max_bytes {
    return text
  }
  let mut start = total - max_bytes
  // 0b10xxxxxx 是 UTF-8 的续字节：跳过它们，别把字符切一半。
  while start < total && (bytes[start].to_int() & 0xC0) == 0x80 {
    start = start + 1
  }
  @utf8.decode_lossy(bytes[start:])
}

///|
pub fn format_size(bytes : Int32) -> String {
  if bytes < 1024 {
    bytes.to_string() + "B"
  } else if bytes < 1024 * 1024 {
    one_decimal(bytes.to_double() / 1024.0) + "KB"
  } else {
    one_decimal(bytes.to_double() / (1024.0 * 1024.0)) + "MB"
  }
}

///|
/// 一位小数（pi 的 `toFixed(1)`）。
fn one_decimal(value : Double) -> String {
  let scaled = (value * 10.0).round().to_int()
  let whole = scaled / 10
  let fraction = scaled % 10
  whole.to_string() + "." + fraction.to_string()
}

///|
/// 单行截断（grep 用）：超长补一个明确的标记。
pub fn truncate_line(
  line : String,
  max_chars~ : Int32 = grep_max_line_length,
) -> (String, Bool) {
  if line.length() <= max_chars {
    (line, false)
  } else {
    (line[:max_chars].to_owned() + "... [truncated]", true)
  }
}
