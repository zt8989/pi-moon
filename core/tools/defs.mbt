// 内置工具表：名字、描述、参数 schema、启用状态。
//
// 与 pi（`@earendil-works/pi-coding-agent`）的 `BUILTIN_TOOL_NAMES` 同一套拼写，
// 描述与参数 schema 逐字照搬官方工具定义（常量已展开成字面量）。这样模型看到的
// 工具说明、以及网关收到的 schema，与 pi 那边一致。
//
// **默认开关不在这个文件里拍板**：默认集合来自 pi 的 `DEFAULT_TOOL_NAMES`
// （`read` / `bash` / `edit` / `write`），再用 `settings.json` 的 `defaultTools`
// 按 `resolveDefaultTools()` 的规则改写（见 `resolve_tool_selection`）。

///|
/// 官方工具名（与 pi 的 `ToolName` 同一套拼写）。顺序与 pi 的
/// `BUILTIN_TOOL_NAMES` 一致：先四个基本工具，再 powershell / grep / find / ls。
pub let builtin_tool_names : Array[String] = [
  "read", "write", "edit", "bash", "powershell", "grep", "find", "ls",
]

///|
/// pi 的默认开启集合：`DEFAULT_TOOL_NAMES = ["read", "bash", "edit", "write"]`。
///
/// 注意顺序：pi 的默认值是 `["read","bash","edit","write"]`，与
/// `BUILTIN_TOOL_NAMES` 的前四个（read / write / edit / bash）不同。声明顺序按
/// 用户可见的那一份，避免「默认清单」与「全部清单」混为一谈。
pub let pi_default_tool_names : Array[String] = [
  "read", "bash", "edit", "write",
]

///|
/// 与 pi 的 `resolveDefaultTools()` 逐条一致：
///
/// 1. `entries` 为空（或没配）→ 用 `DEFAULT_TOOL_NAMES`；
/// 2. 出现**不带前缀**的名字 → 整份清单被**替换**（不是追加），`+` / `-` 再打补丁；
/// 3. 只有 `+name` / `-name` → 先取默认清单，再按顺序应用增删。
///
/// 未知名字**不报错也不剔除**：用户写错一个名字时的表现与 pi 一样（那个工具不存在，
/// 于是没开成）。执行侧按名字查表，查不到自然跳过。
pub fn resolve_tool_selection(entries : Array[String]?) -> Array[String] {
  let defaults = pi_default_tool_names.copy()
  let entries = match entries {
    Some(entries) => entries
    None => return defaults
  }
  let plain : Array[String] = []
  for entry in entries {
    if !is_modifier(entry) {
      plain.push(entry)
    }
  }
  // 「有 plain 就替换，没有 plain 才用默认」—— 空数组也走默认那一支。
  let tools = if plain.is_empty() { defaults } else { plain.copy() }
  for entry in entries {
    if !is_modifier(entry) {
      continue
    }
    let name = entry[1:].to_owned()
    let index = tools.search(name)
    match index {
      Some(index) => if entry.has_prefix("-") { let _ = tools.remove(index) }
      None => if entry.has_prefix("+") && !name.is_empty() { tools.push(name) }
    }
  }
  tools
}

///|
fn is_modifier(entry : String) -> Bool {
  entry.has_prefix("+") || entry.has_prefix("-")
}

///|
/// 从清单里去掉一批名字（CLI 的 `--exclude-tools`；pi 的 `-xt`）。
pub fn exclude_tools(
  names : Array[String],
  excluded : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for name in names {
    if !excluded.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// 这个名字有没有内置实现。
pub fn is_builtin_tool(name : String) -> Bool {
  builtin_tool_names.contains(name)
}

///|
/// 把名字清单翻成「发给模型的工具定义」。
///
/// 输出按 `builtin_tool_names` 的**声明顺序**排列（与 pi 的 `getTools()` 一致：
/// 它总是遍历 `BUILTIN_TOOL_NAMES` 再按开关过滤，所以声明顺序不随
/// `defaultTools` 的书写顺序变）。未知名字直接跳过。
pub fn definitions_for(
  names : Array[String],
) -> Array[@action.PromptToolDefinition] {
  let out : Array[@action.PromptToolDefinition] = []
  for name in builtin_tool_names {
    if names.contains(name) {
      match builtin_tool_definition(name) {
        Some(definition) => out.push(definition)
        None => ()
      }
    }
  }
  out
}

///|
/// 一个工具的完整定义（名字 / 描述 / JSON schema 文本）。
///
/// `parameters` 是 JSON 文本：provider 原样塞进请求体的 `function.parameters`。
pub fn builtin_tool_definition(name : String) -> @action.PromptToolDefinition? {
  match name {
    "read" =>
      Some({
        name: "read",
        description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        parameters: read_parameters(),
      })
    "write" =>
      Some({
        name: "write",
        description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        parameters: write_parameters(),
      })
    "edit" =>
      Some({
        name: "edit",
        description: "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        parameters: edit_parameters(),
      })
    "bash" =>
      Some({
        name: "bash",
        description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        parameters: shell_parameters(),
      })
    "powershell" =>
      Some({
        name: "powershell",
        description: "Execute a PowerShell command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        parameters: shell_parameters(),
      })
    "grep" =>
      Some({
        name: "grep",
        description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
        parameters: grep_parameters(),
      })
    "find" =>
      Some({
        name: "find",
        description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        parameters: find_parameters(),
      })
    "ls" =>
      Some({
        name: "ls",
        description: "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
        parameters: ls_parameters(),
      })
    _ => None
  }
}

///|
/// system prompt 里的一行摘要（pi 的 `promptSnippet`）。
pub fn prompt_snippet(name : String) -> String? {
  match name {
    "read" => Some("Read file contents")
    "write" => Some("Create or overwrite files")
    "edit" =>
      Some(
        "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
      )
    "bash" => Some("Execute bash commands (ls, grep, find, etc.)")
    "powershell" => Some("Execute PowerShell commands")
    "grep" => Some("Search file contents for patterns (respects .gitignore)")
    "find" => Some("Find files by glob pattern (respects .gitignore)")
    "ls" => Some("List directory contents")
    _ => None
  }
}

///|
/// system prompt 里的使用提示（pi 的 `promptGuidelines`）。
pub fn prompt_guidelines(name : String) -> Array[String] {
  match name {
    "read" => ["Use read to examine files instead of cat or sed."]
    "write" => ["Use write only for new files or complete rewrites."]
    "edit" =>
      [
        "Use edit for precise changes (edits[].oldText must match exactly).", "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls.",
        "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
        "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
      ]
    "bash" =>
      [
        "You can inspect PI_* environment variables for current model and session details.",
      ]
    "powershell" =>
      [
        "You can inspect PI_* environment variables for current model and session details.",
      ]
    _ => []
  }
}

///|
fn read_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"},\"offset\":{\"type\":\"number\",\"description\":\"Line number to start reading from (1-indexed)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of lines to read\"}},\"required\":[\"path\"]}"
}

///|
fn write_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to write (relative or absolute)\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write to the file\"}},\"required\":[\"path\",\"content\"]}"
}

///|
fn edit_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to edit (relative or absolute)\"},\"edits\":{\"type\":\"array\",\"description\":\"One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.\",\"items\":{\"type\":\"object\",\"properties\":{\"oldText\":{\"type\":\"string\",\"description\":\"Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call.\"},\"newText\":{\"type\":\"string\",\"description\":\"Replacement text for this targeted edit.\"}},\"required\":[\"oldText\",\"newText\"]}}},\"required\":[\"path\",\"edits\"]}"
}

///|
fn shell_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"},\"timeout\":{\"type\":\"number\",\"description\":\"Timeout in seconds (optional, no default timeout)\"}},\"required\":[\"command\"]}"
}

///|
fn grep_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Search pattern (regex or literal string)\"},\"path\":{\"type\":\"string\",\"description\":\"Directory or file to search (default: current directory)\"},\"glob\":{\"type\":\"string\",\"description\":\"Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'\"},\"ignoreCase\":{\"type\":\"boolean\",\"description\":\"Case-insensitive search (default: false)\"},\"literal\":{\"type\":\"boolean\",\"description\":\"Treat pattern as literal string instead of regex (default: false)\"},\"context\":{\"type\":\"number\",\"description\":\"Number of lines to show before and after each match (default: 0)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of matches to return (default: 100)\"}},\"required\":[\"pattern\"]}"
}

///|
fn find_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'\"},\"path\":{\"type\":\"string\",\"description\":\"Directory to search in (default: current directory)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of results (default: 1000)\"}},\"required\":[\"pattern\"]}"
}

///|
fn ls_parameters() -> String {
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory to list (default: current directory)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of entries to return (default: 500)\"}}}"
}
