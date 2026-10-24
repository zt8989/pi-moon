// 工具块：按工具各画各的（与 pi 的 core/tools/renderers 同形）。
//
// 这里只把「标题 + 正文行 + 折叠提示」算成纯数据；底色、缩进、Ctrl+O 提示的
// 排版归 tui_view.mbt。折叠预算与 pi 一致，展开后一律 40 行：
//
//   bash / powershell   尾部 5 行（命令输出越靠后越重要），完成附耗时
//   edit                彩色 diff（删红 / 加绿 / 上下文灰），折叠 10 行
//   write               内容预览，折叠 10 行
//   read                折叠时只留标题（pi 同款：标题已说明读了什么）
//   grep 15 / find 20 / ls 20
//   其它工具            前 6 行（扩展工具的兜底）

///|
/// 工具块正文的一行：文本 + 前景色（`None` = 用块默认的 muted）。
struct ToolBodyLine {
  text : String
  fg : String?
} derive(Eq, Debug)

///|
/// 一次工具调用的渲染结果。
struct ToolBlock {
  title : String
  lines : Array[ToolBodyLine]
  /// 折叠提示（`… 还有 N 行（Ctrl+O 展开）`）；空串 = 没有。
  hint : String
} derive(Eq, Debug)

///|
let expanded_preview_lines : Int32 = 40

///|
/// 折叠时每个工具保留几行；出错的结果一律 10 行（错误信息不能被藏起来）。
fn collapsed_budget(name : String, is_error : Bool) -> Int32 {
  if is_error {
    return 10
  }
  match name {
    "bash" | "powershell" => 5
    "edit" | "write" => 10
    "read" => 0
    "grep" => 15
    "find" | "ls" => 20
    _ => 6
  }
}

///|
/// 把一次工具调用 + 结果（或进度）算成块。`progress` 是还在跑时的最新输出，
/// `timing` 是完成的耗时（毫秒），都从 state 里来。
fn tool_render(
  call : @message.ToolCall,
  result : @message.ToolResultPart?,
  progress : String,
  timing : Int64?,
  expanded : Bool,
  cwd : String,
  width : Int32,
  palette : Palette,
) -> ToolBlock {
  let args = tool_args(call.arguments)
  let title = tool_title(call, args, cwd, width)
  let is_error = match result {
    Some(part) => part.is_error
    None => false
  }
  let output = trim_trailing_text(
    match result {
      Some(part) => @message.contents_text(part.content)
      None => progress
    },
  )
  let limit = if expanded {
    expanded_preview_lines
  } else {
    collapsed_budget(call.name, is_error)
  }
  let error_fg : String? = if is_error { Some(palette.error) } else { None }
  match call.name {
    "bash" | "powershell" => {
      // 保留尾部：截断口径与工具实现一致（模型看到的也是尾部）。
      let (shown, hidden) = tail_window(split_owned(output), limit)
      let lines : Array[ToolBodyLine] = []
      for line in shown {
        lines.push({ text: line, fg: None, })
      }
      let hints : Array[String] = []
      if hidden > 0 {
        hints.push(tail_hint(hidden, expanded))
      }
      match timing {
        Some(ms) => hints.push("耗时 " + format_duration(ms))
        None => ()
      }
      { title, lines, hint: join_hints(hints), }
    }
    "edit" =>
      // 成功时块里已经是 diff，不再复读 "Successfully replaced ..."；
      // 失败（或参数解析不出 edits）才显示结果文本。
      if is_error {
        head_block(text_lines(output, error_fg), limit, expanded, title)
      } else {
        let diff = edit_diff_lines(args, palette)
        if diff.is_empty() {
          head_block(text_lines(output, error_fg), limit, expanded, title)
        } else {
          head_block(diff, limit, expanded, title)
        }
      }
    "write" =>
      match tool_arg_string(args, "content") {
        Some(content) if !is_error => {
          let all = text_lines(trim_trailing_text(content), None)
          let (shown, hidden) = head_window(all, limit)
          {
            title,
            lines: shown,
            hint: if hidden > 0 {
              write_hint(hidden, all.length(), expanded)
            } else {
              ""
            },
          }
        }
        _ => head_block(text_lines(output, error_fg), limit, expanded, title)
      }
    _ => head_block(text_lines(output, error_fg), limit, expanded, title)
  }
}

///|
fn head_block(
  lines : Array[ToolBodyLine],
  limit : Int32,
  expanded : Bool,
  title : String,
) -> ToolBlock {
  let (shown, hidden) = head_window(lines, limit)
  { title, lines: shown, hint: head_hint(hidden, expanded), }
}

///|
fn[T] head_window(items : Array[T], limit : Int32) -> (Array[T], Int32) {
  if limit <= 0 {
    return ([], items.length())
  }
  if items.length() <= limit {
    return (items, 0)
  }
  let shown : Array[T] = []
  for i in 0..<limit {
    shown.push(items[i])
  }
  (shown, items.length() - limit)
}

///|
/// 保留尾部（bash 的输出语义：越靠后越重要）。
fn[T] tail_window(items : Array[T], limit : Int32) -> (Array[T], Int32) {
  if limit <= 0 {
    return ([], items.length())
  }
  if items.length() <= limit {
    return (items, 0)
  }
  let start = items.length() - limit
  let shown : Array[T] = []
  for i in start..<items.length() {
    shown.push(items[i])
  }
  (shown, start)
}

///|
fn head_hint(hidden : Int32, expanded : Bool) -> String {
  if hidden <= 0 {
    return ""
  }
  if expanded {
    "… 还有 " + hidden.to_string() + " 行未显示"
  } else {
    "… 还有 " + hidden.to_string() + " 行（Ctrl+O 展开）"
  }
}

///|
fn tail_hint(hidden : Int32, expanded : Bool) -> String {
  if hidden <= 0 {
    return ""
  }
  if expanded {
    "… 前面还有 " + hidden.to_string() + " 行未显示"
  } else {
    "… 前面还有 " + hidden.to_string() + " 行（Ctrl+O 展开）"
  }
}

///|
fn write_hint(hidden : Int32, total : Int32, expanded : Bool) -> String {
  if hidden <= 0 {
    return ""
  }
  if expanded {
    "… 还有 " +
    hidden.to_string() +
    " 行（共 " +
    total.to_string() +
    " 行）"
  } else {
    "… 还有 " +
    hidden.to_string() +
    " 行（共 " +
    total.to_string() +
    " 行，Ctrl+O 展开）"
  }
}

///|
fn join_hints(hints : Array[String]) -> String {
  hints.join(" · ")
}

///|
/// pi 的 bash 渲染器底部那行耗时（`formatDuration` 同口径）。
fn format_duration(ms : Int64) -> String {
  if ms <= 0L {
    return "0.0s"
  }
  let total_seconds = (ms / 1000L).to_int()
  if total_seconds < 60 {
    return one_decimal(ms.to_double() / 1000.0) + "s"
  }
  let minutes = total_seconds / 60
  let seconds = total_seconds % 60
  if minutes < 60 {
    return minutes.to_string() + "m " + seconds.to_string() + "s"
  }
  (minutes / 60).to_string() +
  "h " +
  (minutes % 60).to_string() +
  "m " +
  seconds.to_string() +
  "s"
}

///|
fn split_owned(text : String) -> Array[String] {
  let out : Array[String] = []
  for line in text.split("\n") {
    out.push(line.to_owned())
  }
  out
}

///|
/// 去掉结尾的空行（pi 的渲染前 `trim()` 同效果；开头的空行可能有意义，保留）。
fn trim_trailing_empty(lines : Array[String]) -> Array[String] {
  let mut end = lines.length()
  while end > 0 && lines[end - 1].is_empty() {
    end = end - 1
  }
  let out : Array[String] = []
  for i in 0..<end {
    out.push(lines[i])
  }
  out
}

///|
fn trim_trailing_text(text : String) -> String {
  trim_trailing_empty(split_owned(text)).join("\n")
}

///|
fn text_lines(text : String, fg : String?) -> Array[ToolBodyLine] {
  let out : Array[ToolBodyLine] = []
  for line in split_owned(text) {
    out.push({ text: line, fg, })
  }
  out
}

///|
/// 参数 JSON 解析失败不致命：标题照画，正文退回结果文本。
fn tool_args(arguments : String) -> Map[String, Json] {
  if arguments.trim().is_empty() {
    return Map([])
  }
  let parsed = @json.parse(arguments) catch { _ => return Map([]) }
  match parsed {
    Object(object) => object
    _ => Map([])
  }
}

///|
fn tool_arg_string(args : Map[String, Json], key : String) -> String? {
  match args.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn tool_arg_int(args : Map[String, Json], key : String) -> Int32? {
  match args.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
/// 绝对路径相对化到 cwd，统一 `/` 分隔（pi 的 renderToolPath 同效果）。
fn tool_path_display(raw : String, cwd : String) -> String {
  if raw.is_empty() {
    return ""
  }
  if @tools.is_absolute_path(raw) {
    @tools.display_path(@tools.relative_to(raw, cwd))
  } else {
    @tools.display_path(raw)
  }
}

///|
fn path_arg(args : Map[String, Json], cwd : String) -> String {
  match tool_arg_string(args, "path") {
    Some(path) => tool_path_display(path, cwd)
    None => ""
  }
}

///|
fn tool_title(
  call : @message.ToolCall,
  args : Map[String, Json],
  cwd : String,
  width : Int32,
) -> String {
  let room = if width - 4 > 8 { width - 4 } else { 8 }
  let text = match call.name {
    "bash" => "$ " + shell_command_label(args)
    "powershell" => "PS> " + shell_command_label(args)
    "edit" => "edit " + path_arg(args, cwd)
    "write" => "write " + path_arg(args, cwd)
    "read" => "read " + read_label(args, cwd)
    "grep" => grep_label(args, cwd)
    "find" => find_label(args, cwd)
    "ls" => ls_label(args, cwd)
    _ => call.name + " " + one_line(call.arguments)
  }
  truncate_to(text.trim(chars=" \t\r\n").to_owned(), room)
}

///|
fn shell_command_label(args : Map[String, Json]) -> String {
  let command = match tool_arg_string(args, "command") {
    Some(command) => one_line(command)
    None => ""
  }
  let label = if command.is_empty() { "..." } else { command }
  match tool_arg_int(args, "timeout") {
    Some(timeout) => label + " (timeout " + timeout.to_string() + "s)"
    None => label
  }
}

///|
fn read_label(args : Map[String, Json], cwd : String) -> String {
  let path = path_arg(args, cwd)
  let start = match tool_arg_int(args, "offset") {
    Some(offset) => offset
    None => 1
  }
  match tool_arg_int(args, "limit") {
    Some(limit) =>
      path + ":" + start.to_string() + "-" + (start + limit - 1).to_string()
    None => if start == 1 { path } else { path + ":" + start.to_string() }
  }
}

///|
fn grep_label(args : Map[String, Json], cwd : String) -> String {
  let pattern = match tool_arg_string(args, "pattern") {
    Some(pattern) => pattern
    None => "..."
  }
  let path = match tool_arg_string(args, "path") {
    Some(path) =>
      if path.is_empty() {
        "."
      } else {
        tool_path_display(path, cwd)
      }
    None => "."
  }
  let mut label = "grep /" + pattern + "/ in " + path
  match tool_arg_string(args, "glob") {
    Some(glob) => if !glob.is_empty() { label = label + " (" + glob + ")" }
    None => ()
  }
  match tool_arg_int(args, "limit") {
    Some(limit) => label = label + " limit " + limit.to_string()
    None => ()
  }
  label
}

///|
fn find_label(args : Map[String, Json], cwd : String) -> String {
  let pattern = match tool_arg_string(args, "pattern") {
    Some(pattern) => pattern
    None => "..."
  }
  let path = match tool_arg_string(args, "path") {
    Some(path) =>
      if path.is_empty() {
        "."
      } else {
        tool_path_display(path, cwd)
      }
    None => "."
  }
  let mut label = "find " + pattern + " in " + path
  match tool_arg_int(args, "limit") {
    Some(limit) => label = label + " (limit " + limit.to_string() + ")"
    None => ()
  }
  label
}

///|
fn ls_label(args : Map[String, Json], cwd : String) -> String {
  let path = match tool_arg_string(args, "path") {
    Some(path) =>
      if path.is_empty() {
        "."
      } else {
        tool_path_display(path, cwd)
      }
    None => "."
  }
  match tool_arg_int(args, "limit") {
    Some(limit) => "ls " + path + " (limit " + limit.to_string() + ")"
    None => "ls " + path
  }
}

///|
/// edit 的彩色 diff：从**参数**算（工具结果里没有结构化 diff）。
/// oldText / newText 首尾相同的行折成上下文，各最多留 3 行。
fn edit_diff_lines(
  args : Map[String, Json],
  palette : Palette,
) -> Array[ToolBodyLine] {
  let items : Array[Json] = match args.get("edits") {
    Some(Array(items)) => items
    _ => []
  }
  let out : Array[ToolBodyLine] = []
  let mut index = 0
  for item in items {
    let (old_text, new_text) = match item {
      Object(edit) =>
        (
          match tool_arg_string(edit, "oldText") {
            Some(text) => text
            None => ""
          },
          match tool_arg_string(edit, "newText") {
            Some(text) => text
            None => ""
          },
        )
      _ => ("", "")
    }
    if items.length() > 1 {
      out.push({
        text: "@@ edits[" + index.to_string() + "]",
        fg: Some(palette.dim),
      })
    }
    push_edit_hunk(out, old_text, new_text, palette)
    index = index + 1
  }
  out
}

///|
fn push_edit_hunk(
  out : Array[ToolBodyLine],
  old_text : String,
  new_text : String,
  palette : Palette,
) -> Unit {
  let removed = palette.md.diff_removed
  let added = palette.md.diff_add
  let context = palette.md.diff_context
  let old_lines = trim_trailing_empty(split_owned(old_text))
  let new_lines = trim_trailing_empty(split_owned(new_text))
  let mut prefix = 0
  while prefix < old_lines.length() &&
        prefix < new_lines.length() &&
        old_lines[prefix] == new_lines[prefix] {
    prefix = prefix + 1
  }
  let mut suffix = 0
  while suffix < old_lines.length() - prefix &&
        suffix < new_lines.length() - prefix &&
        old_lines[old_lines.length() - 1 - suffix] ==
        new_lines[new_lines.length() - 1 - suffix] {
    suffix = suffix + 1
  }
  let shown_prefix = min_int(prefix, 3)
  let shown_suffix = min_int(suffix, 3)
  if prefix > shown_prefix {
    out.push({ text: "  …", fg: Some(context), })
  }
  push_context_lines(
    out,
    old_lines,
    prefix - shown_prefix,
    shown_prefix,
    context,
  )
  for i in prefix..<(old_lines.length() - suffix) {
    out.push({ text: "- " + old_lines[i], fg: Some(removed), })
  }
  for i in prefix..<(new_lines.length() - suffix) {
    out.push({ text: "+ " + new_lines[i], fg: Some(added), })
  }
  if suffix > shown_suffix {
    out.push({ text: "  …", fg: Some(context), })
  }
  push_context_lines(
    out,
    new_lines,
    new_lines.length() - shown_suffix,
    shown_suffix,
    context,
  )
}

///|
fn push_context_lines(
  out : Array[ToolBodyLine],
  lines : Array[String],
  start : Int32,
  count : Int32,
  color : String,
) -> Unit {
  for i in start..<(start + count) {
    out.push({ text: "  " + lines[i], fg: Some(color), })
  }
}
