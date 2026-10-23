// 内置工具的执行 —— provider 的 `run_tools` effect 调这里。
//
// 失败**不往上抛**：每个工具调用都必须产生一条 toolResult（否则消息序列非法，
// 模型永远等不到结果）。所以 `execute` 把异常收成 `is_error = true` 的结果，
// 与 pi 的 `runToolCall` 同口径。
//
// 与 pi 的差异（都写进了 docs/tools.md）：
//   - edit 只做严格匹配，不做 pi 的模糊匹配（NFKC / 智能引号归一）；
//   - find 用 `rg --files` + 本项目的 glob 匹配器（pi 用 fd），没有 rg 时退回
//     `@shell.glob`（此时不读 .gitignore）。
//
// shell 工具输出是**边跑边读**的：stdout / stderr 指向同一个管道（因此顺序就是
// 命令实际写的顺序），每 100ms 把尾部截断后的当前全文交给 `on_progress`。

///|
/// 一次工具执行的结果。
pub(all) struct ToolOutcome {
  content : Array[@message.Content]
  is_error : Bool
} derive(Debug)

///|
/// 工具执行里的可预期失败（参数缺失、路径不存在……）。
pub suberror ToolFailure {
  Failed(String)
}

///|
fn ok_text(text : String) -> ToolOutcome {
  { content: [@message.Text(text)], is_error: false, }
}

///|
fn error_text(text : String) -> ToolOutcome {
  { content: [@message.Text(text)], is_error: true, }
}

///|
fn append_status(text : String, status : String) -> String {
  if text.is_empty() {
    status
  } else {
    text + "\n\n" + status
  }
}

///|
/// 执行一次工具调用。未知工具 / 坏参数 / 文件错误都变成错误结果。
///
/// `env?` 是给 shell 工具塞环境变量用的（pi 的 `PI_SESSION_ID` / `PI_PROVIDER` /
/// `PI_MODEL` / `PI_REASONING_LEVEL`）；不传就不加。
///
/// `enabled?` 是本次会话**声明给模型**的工具名。不传则不做启用检查（测试用）；
/// provider 传 `state.prompt.tools` 的名字，于是「关着的工具」就算模型硬调也只会
/// 拿到「未知工具」—— 与 pi 的 `getTool()`（按 `selectedBuiltinToolNames` 过滤）一致。
///
/// `on_progress?` 只在 shell 工具上有意义：命令输出每 100ms 交一份**当前全文**
/// （已按尾部截断），provider 把它变成 `ToolProgress` action。
pub async fn execute(
  cwd : String,
  call : @message.ToolCall,
  env? : Map[String, String],
  enabled? : Array[String],
  on_progress? : async (Array[@message.Content]) -> Unit,
) -> ToolOutcome {
  let on_progress : async (Array[@message.Content]) -> Unit = match
    on_progress {
    Some(callback) => callback
    None => async fn(_blocks) { () }
  }
  try {
    let allowed = match enabled {
      Some(names) => names.contains(call.name)
      None => true
    }
    if !allowed {
      raise Failed("未知工具：" + call.name)
    }
    let args = argument_object(call)
    let env = env.unwrap_or(Map([]))
    match call.name {
      "read" => execute_read(cwd, args)
      "write" => execute_write(cwd, args)
      "edit" => execute_edit(cwd, args)
      "bash" => execute_shell(cwd, args, "bash", env, on_progress)
      "powershell" => execute_shell(cwd, args, "powershell", env, on_progress)
      "grep" => execute_grep(cwd, args)
      "find" => execute_find(cwd, args)
      "ls" => execute_ls(cwd, args)
      _ => raise Failed("未知工具：" + call.name)
    }
  } catch {
    Failed(message) => error_text(message)
    err => error_text(err.to_string())
  }
}

// ─── 参数 ────────────────────────────────────────────────────────────────────

///|
fn argument_object(call : @message.ToolCall) -> Map[String, Json] raise {
  if call.arguments.trim().is_empty() {
    return Map([])
  }
  let parsed = @json.parse(call.arguments) catch {
    _ => raise Failed("工具参数不是合法 JSON：" + call.name)
  }
  match parsed {
    Object(object) => object
    _ => raise Failed("工具参数必须是 JSON 对象：" + call.name)
  }
}

///|
fn arg_string(args : Map[String, Json], key : String) -> String raise {
  match args.get(key) {
    Some(String(value)) => value
    _ => raise Failed("缺少参数 " + key)
  }
}

///|
fn arg_opt_string(args : Map[String, Json], key : String) -> String? {
  match args.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn arg_opt_number(args : Map[String, Json], key : String) -> Double? {
  match args.get(key) {
    Some(Number(value, ..)) => Some(value)
    _ => None
  }
}

///|
fn arg_opt_int(args : Map[String, Json], key : String) -> Int32? {
  match arg_opt_number(args, key) {
    Some(value) => Some(value.to_int())
    None => None
  }
}

///|
fn arg_opt_bool(args : Map[String, Json], key : String) -> Bool? {
  match args.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn arg_edits(args : Map[String, Json]) -> Array[(String, String)] raise {
  let items = match args.get("edits") {
    Some(Array(items)) => items
    _ => raise Failed("缺少参数 edits")
  }
  let edits : Array[(String, String)] = []
  for item in items {
    match item {
      Object(edit) => {
        let old_text = match edit.get("oldText") {
          Some(String(text)) => text
          _ => raise Failed("edits[].oldText 必须是字符串")
        }
        let new_text = match edit.get("newText") {
          Some(String(text)) => text
          _ => raise Failed("edits[].newText 必须是字符串")
        }
        edits.push((old_text, new_text))
      }
      _ => raise Failed("edits[] 必须是对象")
    }
  }
  edits
}

// ─── read ────────────────────────────────────────────────────────────────────

///|
async fn execute_read(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let raw_path = arg_string(args, "path")
  let path = resolve_path(raw_path, cwd)
  let kind = @fs.kind(path) catch { err => raise Failed(err.to_string()) }
  match kind {
    Directory => raise Failed("Path is a directory: " + path)
    _ => ()
  }
  match image_mime(path) {
    Some(mime) => {
      let data = @fs.read_file(path) catch {
        err => raise Failed(err.to_string())
      }
      let encoded = @base64.encode(data.binary())
      {
        content: [
          @message.Text("Read image file [" + mime + "]"),
          @message.Image("data:" + mime + ";base64," + encoded),
        ],
        is_error: false,
      }
    }
    None => read_text_file(raw_path, path, args)
  }
}

///|
async fn read_text_file(
  raw_path : String,
  path : String,
  args : Map[String, Json],
) -> ToolOutcome {
  let data = @fs.read_file(path) catch { err => raise Failed(err.to_string()) }
  let text = @utf8.decode_lossy(data.binary())
  let all_lines = split_all_lines(text)
  let total_lines = all_lines.length()
  let offset = match arg_opt_int(args, "offset") {
    Some(offset) => offset
    None => 0
  }
  let limit = arg_opt_int(args, "limit")
  // pi：offset 是 1-indexed；超出文件末尾是错误。
  let start_line = if offset > 0 { offset - 1 } else { 0 }
  if start_line >= total_lines {
    raise Failed(
      "Offset " +
      offset.to_string() +
      " is beyond end of file (" +
      total_lines.to_string() +
      " lines total)",
    )
  }
  let start_line_display = start_line + 1
  let (selected, user_limited_lines) = match limit {
    Some(limit) => {
      let end_line = if start_line + limit < total_lines {
        start_line + limit
      } else {
        total_lines
      }
      (
        slice_lines(all_lines, start_line, end_line),
        Some(end_line - start_line),
      )
    }
    None => (slice_lines(all_lines, start_line, total_lines), None)
  }
  let truncated = truncate_head(selected)
  let output = if truncated.first_line_exceeds_limit {
    let first_line_size = byte_length(all_lines[start_line])
    "[Line " +
    start_line_display.to_string() +
    " is " +
    format_size(first_line_size) +
    ", exceeds " +
    format_size(default_max_bytes) +
    " limit. Use bash: sed -n '" +
    start_line_display.to_string() +
    "p' " +
    raw_path +
    " | head -c " +
    default_max_bytes.to_string() +
    "]"
  } else if truncated.truncated {
    let end_line_display = start_line_display + truncated.output_lines - 1
    let next_offset = end_line_display + 1
    let notice = if truncated.truncated_by == "lines" {
      "[Showing lines " +
      start_line_display.to_string() +
      "-" +
      end_line_display.to_string() +
      " of " +
      total_lines.to_string() +
      ". Use offset=" +
      next_offset.to_string() +
      " to continue.]"
    } else {
      "[Showing lines " +
      start_line_display.to_string() +
      "-" +
      end_line_display.to_string() +
      " of " +
      total_lines.to_string() +
      " (" +
      format_size(default_max_bytes) +
      " limit). Use offset=" +
      next_offset.to_string() +
      " to continue.]"
    }
    truncated.content + "\n\n" + notice
  } else {
    match user_limited_lines {
      Some(limited) =>
        if start_line + limited < total_lines {
          let remaining = total_lines - (start_line + limited)
          let next_offset = start_line + limited + 1
          truncated.content +
          "\n\n[" +
          remaining.to_string() +
          " more lines in file. Use offset=" +
          next_offset.to_string() +
          " to continue.]"
        } else {
          truncated.content
        }
      None => truncated.content
    }
  }
  ok_text(output)
}

///|
/// 按行切片并拼回（不引入末尾换行）。
fn slice_lines(lines : Array[String], start : Int32, end : Int32) -> String {
  let out : Array[String] = []
  let mut index = start
  while index < end && index < lines.length() {
    out.push(lines[index])
    index = index + 1
  }
  out.join("\n")
}

// ─── write ───────────────────────────────────────────────────────────────────

///|
async fn execute_write(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let raw_path = arg_string(args, "path")
  let content = arg_string(args, "content")
  let path = resolve_path(raw_path, cwd)
  let directory = parent_dir(path)
  let directory_exists = @fs.exists(directory) catch { _ => false }
  if !directory_exists {
    @fs.mkdir(directory, recursive=true) catch {
      err => raise Failed("Could not create directory: " + err.to_string())
    }
  }
  @fs.write_file(path, content) catch {
    err => raise Failed(err.to_string())
  }
  ok_text("Successfully wrote to " + raw_path)
}

// ─── edit ────────────────────────────────────────────────────────────────────

///|
async fn execute_edit(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let raw_path = arg_string(args, "path")
  let edits = arg_edits(args)
  let path = resolve_path(raw_path, cwd)
  let data = @fs.read_file(path) catch {
    err =>
      raise Failed("Could not edit file: " + raw_path + ". " + err.to_string())
  }
  let raw_content = @utf8.decode_lossy(data.binary())
  // BOM 与行尾都先归一：模型看不到 BOM，也不该为 CRLF 背锅。
  let (bom, without_bom) = if raw_content.has_prefix("\u{feff}") {
    ("\u{feff}", raw_content[1:].to_owned())
  } else {
    ("", raw_content)
  }
  let crlf = without_bom.contains("\r\n")
  let content = normalize_lf(without_bom)
  let matched : Array[(Int32, Int32, String)] = []
  let mut edit_index = 0
  for edit in edits {
    let (old_text, new_text) = edit
    let old_text = normalize_lf(old_text)
    let new_text = normalize_lf(new_text)
    if old_text.is_empty() {
      if edits.length() == 1 {
        raise Failed("oldText must not be empty in " + raw_path + ".")
      } else {
        raise Failed(
          "edits[" +
          edit_index.to_string() +
          "].oldText must not be empty in " +
          raw_path +
          ".",
        )
      }
    }
    let occurrences = count_occurrences(content, old_text)
    if occurrences == 0 {
      if edits.length() == 1 {
        raise Failed(
          "Could not find the exact text in " +
          raw_path +
          ". The old text must match exactly including all whitespace and newlines.",
        )
      } else {
        raise Failed(
          "Could not find edits[" +
          edit_index.to_string() +
          "] in " +
          raw_path +
          ". The oldText must match exactly including all whitespace and newlines.",
        )
      }
    }
    if occurrences > 1 {
      if edits.length() == 1 {
        raise Failed(
          "Found " +
          occurrences.to_string() +
          " occurrences of the text in " +
          raw_path +
          ". The text must be unique. Please provide more context to make it unique.",
        )
      } else {
        raise Failed(
          "Found " +
          occurrences.to_string() +
          " occurrences of edits[" +
          edit_index.to_string() +
          "] in " +
          raw_path +
          ". Each oldText must be unique. Please provide more context to make it unique.",
        )
      }
    }
    let at = match content.find(old_text) {
      Some(at) => at
      None => raise Failed("Could not find the exact text in " + raw_path + ".")
    }
    matched.push((at, old_text.length(), new_text))
    edit_index = edit_index + 1
  }
  matched.sort_by(fn(a, b) { a.0 - b.0 })
  let mut index = 1
  while index < matched.length() {
    let previous = matched[index - 1]
    let current = matched[index]
    if previous.0 + previous.1 > current.0 {
      raise Failed(
        "edits[" +
        (index - 1).to_string() +
        "] and edits[" +
        index.to_string() +
        "] overlap in " +
        raw_path +
        ". Merge them into one edit or target disjoint regions.",
      )
    }
    index = index + 1
  }
  let mut updated = content
  let mut reverse_index = matched.length() - 1
  while reverse_index >= 0 {
    let (at, length, replacement) = matched[reverse_index]
    updated = updated[:at].to_owned() +
      replacement +
      updated[at + length:].to_owned()
    reverse_index = reverse_index - 1
  }
  if updated == content {
    raise Failed(
      "No changes made to " +
      raw_path +
      ". The replacement produced identical content.",
    )
  }
  let final_content = if crlf {
    bom + updated.replace_all(old="\n", new="\r\n")
  } else {
    bom + updated
  }
  @fs.write_file(path, final_content) catch {
    err => raise Failed(err.to_string())
  }
  ok_text(
    "Successfully replaced " +
    edits.length().to_string() +
    " block(s) in " +
    raw_path +
    ".",
  )
}

///|
fn normalize_lf(text : String) -> String {
  text.replace_all(old="\r\n", new="\n").replace_all(old="\r", new="\n")
}

///|
/// 不重叠地数出现次数（与 JS 的 `content.split(needle).length - 1` 同口径）。
fn count_occurrences(text : String, needle : String) -> Int32 {
  let mut count = 0
  let mut remaining = text
  while true {
    match remaining.find(needle) {
      Some(at) => {
        count = count + 1
        remaining = remaining[at + needle.length():].to_owned()
      }
      None => break
    }
  }
  count
}

// ─── bash / powershell ───────────────────────────────────────────────────────

///|
/// 最多留存多少原始输出（与之前一次性读取时 `@shell` 的默认上限一致）。
let max_stream_bytes : Int32 = 8 * 1024 * 1024

///|
/// 进度快照只看尾部这么多字节（`ToolProgress` 本来就是尾部截断的展示）。
let progress_snapshot_bytes : Int32 = 200 * 1024

///|
/// 进度节流：最多每 100ms 一条 `ToolProgress`。
let progress_interval_ms : Int64 = 100L

///|
/// 跑一条命令并把输出**边跑边**交出去。
///
/// stdout / stderr 指向同一个管道（与 pi 的 merged 输出同形），于是读到什么顺序
/// 就是命令写的什么顺序。每 100ms 把「当前全文的尾部截断」作为一次进度交给
/// `on_progress`；完整输出累积在 `collected`（上限 8MB），由调用方收尾。
async fn collect_shell_stream(
  program : String,
  arguments : Array[String],
  cwd : String,
  extra_env : Map[String, String],
  collected : Array[Byte],
  on_progress : async (Array[@message.Content]) -> Unit,
) -> Int32 {
  let mut exit_code = -1
  @async.with_task_group(group => {
    let (reader, writer) = @process.read_from_process() catch {
      err => raise Failed("Failed to create output pipe: " + err.to_string())
    }
    defer reader.close()
    let process = @process.spawn(
      group,
      program,
      arguments,
      extra_env~,
      stdout=writer,
      stderr=writer,
      cwd~,
    )
    let mut last_emit = 0L
    let mut emitted = false
    let mut reading = true
    while reading {
      let chunk = reader.read_some(max_len=8192) catch {
        error =>
          if @async.is_cancellation_error(error) {
            raise error
          } else {
            None
          }
      }
      match chunk {
        None => reading = false
        Some(bytes) => {
          for byte in bytes {
            if collected.length() < max_stream_bytes {
              collected.push(byte)
            }
          }
          let now = @async.now()
          if !emitted || now - last_emit >= progress_interval_ms {
            emitted = true
            last_emit = now
            let start = if collected.length() > progress_snapshot_bytes {
              collected.length() - progress_snapshot_bytes
            } else {
              0
            }
            let snapshot = @utf8.decode_lossy(
              Bytes::from_array(collected[start:]),
            )
            let snapshot = truncate_tail(snapshot).content
            if !snapshot.is_empty() {
              on_progress([@message.Text(snapshot)])
            }
          }
        }
      }
    }
    exit_code = process.wait()
  })
  exit_code
}

///|
fn decode_bytes(bytes : Array[Byte]) -> String {
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
async fn execute_shell(
  cwd : String,
  args : Map[String, Json],
  kind : String,
  extra_env : Map[String, String],
  on_progress : async (Array[@message.Content]) -> Unit,
) -> ToolOutcome {
  let command = arg_string(args, "command")
  let timeout_seconds = arg_opt_number(args, "timeout")
  let timeout_ms = match timeout_seconds {
    Some(seconds) =>
      if seconds <= 0.0 {
        raise Failed("Invalid timeout: must be a positive number of seconds")
      } else {
        let milliseconds = (seconds * 1000.0).to_int()
        if milliseconds <= 0 {
          raise Failed("Invalid timeout: too small")
        }
        Some(milliseconds)
      }
    None => None
  }
  let (program, arguments) = if kind == "bash" {
    resolve_bash_shell()
  } else {
    resolve_powershell()
  }
  let arguments = if kind == "powershell" {
    // pi 在 PowerShell 前面垫一行，把输出编码钉成 UTF-8。
    let prefixed = "try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}\n" +
      command
    let with_command = arguments.copy()
    with_command.push(prefixed)
    with_command
  } else {
    let with_command = arguments.copy()
    with_command.push(command)
    with_command
  }
  // 边跑边读：stdout / stderr 走同一个管道，顺序就是命令实际写的顺序（pi 同形）。
  let collected : Array[Byte] = []
  let exit_code = try {
    match timeout_ms {
      Some(milliseconds) =>
        @async.with_timeout(milliseconds, async fn() {
          collect_shell_stream(
            program, arguments, cwd, extra_env, collected, on_progress,
          )
        })
      None =>
        collect_shell_stream(
          program, arguments, cwd, extra_env, collected, on_progress,
        )
    }
  } catch {
    @async.TimeoutError => {
      let partial = decode_bytes(collected)
      let partial_text = if partial.is_empty() {
        ""
      } else {
        truncate_tail(partial).content
      }
      return error_text(
        append_status(
          partial_text,
          "Command timed out after " +
          timeout_seconds.unwrap_or(0.0).to_string() +
          " seconds",
        ),
      )
    }
    err =>
      return error_text("Failed to run " + program + ": " + err.to_string())
  }
  let combined = decode_bytes(collected)
  let truncated = truncate_tail(combined)
  let mut text = if truncated.content.is_empty() {
    "(no output)"
  } else {
    truncated.content
  }
  if truncated.truncated {
    let full_path = save_full_output(combined)
    let start_line = truncated.total_lines - truncated.output_lines + 1
    let end_line = truncated.total_lines
    let location = if full_path.is_empty() {
      ""
    } else {
      " Full output: " + full_path
    }
    let notice = if truncated.last_line_partial {
      "[Showing last " +
      format_size(truncated.output_bytes) +
      " of line " +
      end_line.to_string() +
      "." +
      location +
      "]"
    } else if truncated.truncated_by == "lines" {
      "[Showing lines " +
      start_line.to_string() +
      "-" +
      end_line.to_string() +
      " of " +
      truncated.total_lines.to_string() +
      "." +
      location +
      "]"
    } else {
      "[Showing lines " +
      start_line.to_string() +
      "-" +
      end_line.to_string() +
      " of " +
      truncated.total_lines.to_string() +
      " (" +
      format_size(default_max_bytes) +
      " limit)." +
      location +
      "]"
    }
    text = text + "\n\n" + notice
  }
  if exit_code == 0 {
    ok_text(text)
  } else {
    {
      content: [
        @message.Text(
          append_status(
            text,
            "Command exited with code " + exit_code.to_string(),
          ),
        ),
      ],
      is_error: true,
    }
  }
}

///|
async fn save_full_output(content : String) -> String {
  let directory = @fs.tmpdir(prefix="pi-moon-bash") catch { _ => return "" }
  let path = directory + "/output.log"
  @fs.write_file(path, content) catch {
    _ => return ""
  }
  path
}

///|
/// bash 的解析顺序与 pi 的 `getShellConfig()` 一致：
/// Git Bash 的已知位置 → PATH 上的 `bash.exe` → 报错（Windows）；
/// `/bin/bash` → PATH 上的 `bash` → `sh`（Unix）。
async fn resolve_bash_shell() -> (String, Array[String]) {
  let env = @env.get_env_vars()
  if is_windows_env(env) {
    let candidates : Array[String] = []
    match env_get(env, "ProgramFiles") {
      Some(program_files) =>
        candidates.push(program_files + "\\Git\\bin\\bash.exe")
      None => ()
    }
    match env_get(env, "ProgramFiles(x86)") {
      Some(program_files) =>
        candidates.push(program_files + "\\Git\\bin\\bash.exe")
      None => ()
    }
    for candidate in candidates {
      if (@fs.exists(candidate) catch { _ => false }) {
        return (candidate, ["-c"])
      }
    }
    match command_on_path("bash.exe") {
      Some(shell) => (shell, ["-c"])
      None =>
        raise Failed(
          "No bash shell found. Options:\n" +
          "  1. Install Git for Windows: https://git-scm.com/download/win\n" +
          "  2. Add your bash to PATH (Cygwin, MSYS2, etc.)\n" +
          "  3. Use the powershell tool instead",
        )
    }
  } else if (@fs.exists("/bin/bash") catch { _ => false }) {
    ("/bin/bash", ["-c"])
  } else {
    match command_on_path("bash") {
      Some(shell) => (shell, ["-c"])
      None => ("sh", ["-c"])
    }
  }
}

///|
async fn resolve_powershell() -> (String, Array[String]) {
  let env = @env.get_env_vars()
  if !is_windows_env(env) {
    raise Failed("The powershell tool is only available on Windows.")
  }
  let arguments = [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
  ]
  match command_on_path("pwsh.exe") {
    Some(shell) => (shell, arguments)
    None =>
      match command_on_path("powershell.exe") {
        Some(shell) => (shell, arguments)
        None =>
          raise Failed(
            "No PowerShell executable found. Install PowerShell or add powershell.exe/pwsh.exe to PATH.",
          )
      }
  }
}

///|
/// 在 PATH 上找一个可执行文件（Windows 用 `where`，其余用 `which`）。
async fn command_on_path(executable : String) -> String? {
  let env = @env.get_env_vars()
  let finder = if is_windows_env(env) { "where" } else { "which" }
  let stdout = try {
    let output = @shell.Cmd(finder, [executable]).output(timeout_ms=5000)
    if output.exit_code() == 0 {
      Some(output.stdout())
    } else {
      None
    }
  } catch {
    _ => None
  }
  match stdout {
    None => None
    Some(stdout) => {
      for line in split_all_lines(stdout) {
        let candidate = line.trim().to_owned()
        if !candidate.is_empty() && (@fs.exists(candidate) catch { _ => false }) {
          return Some(candidate)
        }
      }
      None
    }
  }
}

// ─── grep ────────────────────────────────────────────────────────────────────

///|
async fn execute_grep(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let pattern = arg_string(args, "pattern")
  let search_path = resolve_path(
    arg_opt_string(args, "path").unwrap_or("."),
    cwd,
  )
  let kind = @fs.kind(search_path) catch {
    _ => raise Failed("Path not found: " + search_path)
  }
  let is_directory = match kind {
    Directory => true
    _ => false
  }
  let run_cwd = if is_directory { search_path } else { parent_dir(search_path) }
  let target = if is_directory { "." } else { basename(search_path) }
  let limit = {
    let value = match arg_opt_int(args, "limit") {
      Some(value) => value
      None => 100
    }
    if value < 1 {
      1
    } else {
      value
    }
  }
  let context = match arg_opt_int(args, "context") {
    Some(value) => if value > 0 { value } else { 0 }
    None => 0
  }
  let arguments : Array[String] = [
    "--json", "--line-number", "--color=never", "--hidden",
  ]
  if arg_opt_bool(args, "ignoreCase").unwrap_or(false) {
    arguments.push("--ignore-case")
  }
  if arg_opt_bool(args, "literal").unwrap_or(false) {
    arguments.push("--fixed-strings")
  }
  match arg_opt_string(args, "glob") {
    Some(glob) => {
      arguments.push("--glob")
      arguments.push(glob)
    }
    None => ()
  }
  if context > 0 {
    arguments.push("--context")
    arguments.push(context.to_string())
  }
  arguments.push("--")
  arguments.push(pattern)
  arguments.push(target)
  let output = @shell.Cmd("rg", arguments, cwd=run_cwd).output() catch {
    err =>
      raise Failed(
        "ripgrep (rg) is not available and could not be downloaded: " +
        err.to_string(),
      )
  }
  let exit_code = output.exit_code()
  if exit_code != 0 && exit_code != 1 {
    let stderr = output.stderr().trim()
    let message = if stderr.is_empty() {
      "ripgrep exited with code " + exit_code.to_string()
    } else {
      stderr.to_owned()
    }
    raise Failed(message)
  }
  let matches : Array[(String, Int32, String, Bool)] = []
  let mut match_count = 0
  let mut match_limit_reached = false
  let mut lines_truncated = false
  let mut stopped = false
  for line in split_all_lines(output.stdout()) {
    if stopped {
      break
    }
    let line = line.trim()
    if line.is_empty() {
      continue
    }
    let event = @json.parse(line) catch { _ => continue }
    let object = match event {
      Object(object) => object
      _ => continue
    }
    let kind = match object.get("type") {
      Some(String(kind)) => kind
      _ => continue
    }
    if kind != "match" && kind != "context" {
      continue
    }
    let data = match object.get("data") {
      Some(Object(data)) => data
      _ => continue
    }
    let file_path = match data.get("path") {
      Some(Object(path)) =>
        match path.get("text") {
          Some(String(text)) => text
          _ => continue
        }
      _ => continue
    }
    let line_number = match data.get("line_number") {
      Some(Number(value, ..)) => value.to_int()
      _ => continue
    }
    let line_text = match data.get("lines") {
      Some(Object(lines)) =>
        match lines.get("text") {
          Some(String(text)) => text
          _ => ""
        }
      _ => ""
    }
    let is_match = kind == "match"
    if is_match {
      if match_count >= limit {
        match_limit_reached = true
        stopped = true
        break
      }
      match_count = match_count + 1
      if match_count >= limit {
        match_limit_reached = true
      }
    }
    let relative = if is_directory {
      display_path(file_path)
    } else {
      basename(display_path(file_path))
    }
    let sanitized = line_text
      .replace_all(old="\r\n", new="\n")
      .replace_all(old="\r", new="")
    let sanitized = if sanitized.has_suffix("\n") {
      sanitized[:sanitized.length() - 1].to_owned()
    } else {
      sanitized
    }
    let (text, was_truncated) = truncate_line(sanitized)
    if was_truncated {
      lines_truncated = true
    }
    if is_match {
      matches.push((relative, line_number, text, true))
    } else {
      matches.push((relative, line_number, text, false))
    }
  }
  if match_count == 0 {
    return ok_text("No matches found")
  }
  let output_lines : Array[String] = []
  for entry in matches {
    let (path, line_number, text, is_match) = entry
    if is_match {
      output_lines.push(path + ":" + line_number.to_string() + ": " + text)
    } else {
      output_lines.push(path + "-" + line_number.to_string() + "- " + text)
    }
  }
  let raw_output = output_lines.join("\n")
  let truncated = truncate_head(raw_output, max_lines=100000000)
  let notices : Array[String] = []
  if match_limit_reached {
    notices.push(
      limit.to_string() +
      " matches limit reached. Use limit=" +
      (limit * 2).to_string() +
      " for more, or refine pattern",
    )
  }
  if truncated.truncated {
    notices.push(format_size(default_max_bytes) + " limit reached")
  }
  if lines_truncated {
    notices.push(
      "Some lines truncated to " +
      grep_max_line_length.to_string() +
      " chars. Use read tool to see full lines",
    )
  }
  let text = if notices.is_empty() {
    truncated.content
  } else {
    truncated.content + "\n\n[" + notices.join(". ") + "]"
  }
  ok_text(text)
}

// ─── find ────────────────────────────────────────────────────────────────────

///|
async fn execute_find(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let pattern = arg_string(args, "pattern")
  let search_path = resolve_path(
    arg_opt_string(args, "path").unwrap_or("."),
    cwd,
  )
  if !(@fs.exists(search_path) catch { _ => false }) {
    raise Failed("Path not found: " + search_path)
  }
  let kind = @fs.kind(search_path) catch {
    _ => raise Failed("Path not found: " + search_path)
  }
  let search_is_directory = match kind {
    Directory => true
    _ => false
  }
  if !search_is_directory {
    // 传了一个文件：就只看它自己是否命中 pattern（fd 在文件路径上的行为也差不多）。
    let name = basename(search_path)
    if glob_match(pattern, name) {
      return ok_text(name)
    }
    return ok_text("No files found matching pattern")
  }
  let limit = {
    let value = match arg_opt_int(args, "limit") {
      Some(value) => value
      None => 1000
    }
    if value < 1 {
      1
    } else {
      value
    }
  }
  // `rg --files` 读 .gitignore；pattern 的 glob 语义由本项目的匹配器补。
  let candidates = match rg_files(search_path) {
    Some(files) => files
    None => glob_files(pattern, search_path)
  }
  let results : Array[String] = []
  let mut result_limit_reached = false
  for candidate in candidates {
    let relative = display_path(candidate)
    if relative.is_empty() || is_ignored_path(relative) {
      continue
    }
    if !glob_match(pattern, relative) {
      continue
    }
    if results.length() >= limit {
      result_limit_reached = true
      break
    }
    results.push(relative)
  }
  if results.is_empty() {
    return ok_text("No files found matching pattern")
  }
  let raw_output = results.join("\n")
  let truncated = truncate_head(raw_output, max_lines=100000000)
  let notices : Array[String] = []
  if result_limit_reached {
    notices.push(
      limit.to_string() +
      " results limit reached. Use limit=" +
      (limit * 2).to_string() +
      " for more, or refine pattern",
    )
  }
  if truncated.truncated {
    notices.push(format_size(default_max_bytes) + " limit reached")
  }
  let text = if notices.is_empty() {
    truncated.content
  } else {
    truncated.content + "\n\n[" + notices.join(". ") + "]"
  }
  ok_text(text)
}

///|
/// `rg --files` 的清单（相对 search root）。没有 rg 时返回 None。
async fn rg_files(search_path : String) -> Array[String]? {
  let arguments : Array[String] = ["--files", "--hidden", "--color=never", "."]
  try {
    let output = @shell.Cmd("rg", arguments, cwd=search_path).output()
    if output.exit_code() != 0 && output.exit_code() != 1 {
      return None
    }
    let files : Array[String] = []
    for line in split_all_lines(output.stdout()) {
      let path = display_path(line.trim().to_owned())
      if !path.is_empty() {
        files.push(path)
      }
    }
    Some(files)
  } catch {
    _ => None
  }
}

///|
/// 没有 rg 时的退路：`@shell.glob`（不读 .gitignore）。
async fn glob_files(pattern : String, search_path : String) -> Array[String] {
  let effective = if pattern.contains("/") { pattern } else { "**/" + pattern }
  @shell.glob(effective, cwd=search_path) catch {
    err => raise Failed("Failed to expand glob: " + err.to_string())
  }
}

///|
fn is_ignored_path(path : String) -> Bool {
  path.contains("node_modules/") ||
  path.has_prefix("node_modules") ||
  path.contains(".git/") ||
  path.has_prefix(".git")
}

// ─── ls ─────────────────────────────────────────────────────────────────────

///|
async fn execute_ls(cwd : String, args : Map[String, Json]) -> ToolOutcome {
  let raw_path = arg_opt_string(args, "path").unwrap_or(".")
  let directory = resolve_path(raw_path, cwd)
  if !(@fs.exists(directory) catch { _ => false }) {
    raise Failed("Path not found: " + directory)
  }
  let kind = @fs.kind(directory) catch {
    _ => raise Failed("Path not found: " + directory)
  }
  let is_directory = match kind {
    Directory => true
    _ => false
  }
  if !is_directory {
    raise Failed("Not a directory: " + directory)
  }
  let limit = {
    let value = match arg_opt_int(args, "limit") {
      Some(value) => value
      None => 500
    }
    if value < 1 {
      1
    } else {
      value
    }
  }
  let entries = @fs.readdir(directory, include_hidden=true) catch {
    err => raise Failed("Cannot read directory: " + err.to_string())
  }
  entries.sort_by_key(fn(name) { name.to_lower() })
  let results : Array[String] = []
  let mut entry_limit_reached = false
  for entry in entries {
    if results.length() >= limit {
      entry_limit_reached = true
      break
    }
    let entry_kind = @fs.kind(directory + "/" + entry) catch { _ => continue }
    let suffix = match entry_kind {
      Directory => "/"
      _ => ""
    }
    results.push(entry + suffix)
  }
  if results.is_empty() {
    return ok_text("(empty directory)")
  }
  let raw_output = results.join("\n")
  let truncated = truncate_head(raw_output, max_lines=100000000)
  let notices : Array[String] = []
  if entry_limit_reached {
    notices.push(
      limit.to_string() +
      " entries limit reached. Use limit=" +
      (limit * 2).to_string() +
      " for more",
    )
  }
  if truncated.truncated {
    notices.push(format_size(default_max_bytes) + " limit reached")
  }
  let text = if notices.is_empty() {
    truncated.content
  } else {
    truncated.content + "\n\n[" + notices.join(". ") + "]"
  }
  ok_text(text)
}

// ─── 小工具 ──────────────────────────────────────────────────────────────────

///|
/// 与 JS 的 `String.split("\n")` 一致：末尾换行留下一个空元素。
fn split_all_lines(text : String) -> Array[String] {
  let out : Array[String] = []
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
  out
}

///|
fn image_mime(path : String) -> String? {
  let lower = path.to_lower()
  if lower.has_suffix(".png") {
    Some("image/png")
  } else if lower.has_suffix(".jpg") || lower.has_suffix(".jpeg") {
    Some("image/jpeg")
  } else if lower.has_suffix(".gif") {
    Some("image/gif")
  } else if lower.has_suffix(".webp") {
    Some("image/webp")
  } else if lower.has_suffix(".bmp") {
    Some("image/bmp")
  } else {
    None
  }
}
