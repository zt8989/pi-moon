// 路径与 glob —— 工具的工作目录语义。
//
// pi 的 `path-utils.ts` 做三件事：展开 `~`、把 `@path` 去掉 `@`、相对路径按 cwd
// 解析。这里照同一套，另外补一个 `**` 能跨目录的 glob 匹配器（`find` 在没有
// ripgrep 时用它过滤 `rg --files` 的清单）。

///|
/// 环境变量查找（大小写不敏感）。
///
/// `@env.get_env_vars()` 在 Windows 上把键返回成大写（`SYSTEMROOT`），而 pi 的配置
/// 与文档写的是 `SystemRoot` / `ProgramFiles`。不归一的话，Windows 分支永远走不到。
pub fn env_get(env : Map[String, String], name : String) -> String? {
  match env.get(name) {
    Some(value) => Some(value)
    None => {
      let lower = name.to_lower()
      for key, value in env {
        if key.to_lower() == lower {
          return Some(value)
        }
      }
      None
    }
  }
}

///|
pub fn env_contains(env : Map[String, String], name : String) -> Bool {
  match env_get(env, name) {
    Some(_) => true
    None => false
  }
}

///|
/// 日志 / 渲染用的平台判断。
///
/// 不依赖编译期 target：Windows 的标识是 `SystemRoot`（Unix 没有这个变量）。
pub fn is_windows_env(env : Map[String, String]) -> Bool {
  env_contains(env, "SystemRoot")
}

///|
pub fn home_dir(env : Map[String, String]) -> String {
  match env_get(env, "USERPROFILE") {
    Some(home) =>
      if !home.is_empty() {
        home
      } else {
        env_get(env, "HOME").unwrap_or(".")
      }
    None => env_get(env, "HOME").unwrap_or(".")
  }
}

///|
/// 把用户写的路径解析成绝对路径（`/` 分隔，折叠 `.` / `..`）。
pub fn resolve_path(raw : String, cwd : String) -> String {
  let env = @env.get_env_vars()
  let mut path = raw.trim().to_owned()
  // pi 允许 @path 指文件（终端里 @ 是补全前缀），工具参数里也照收。
  if path.has_prefix("@") {
    path = path[1:].to_owned()
  }
  path = path.replace_all(old="\\", new="/")
  if path.has_prefix("~") {
    path = home_dir(env) + path[1:].to_owned()
  }
  if !is_absolute_path(path) {
    path = cwd.replace_all(old="\\", new="/") + "/" + path
  }
  normalize_segments(path)
}

///|
pub fn is_absolute_path(path : String) -> Bool {
  if path.has_prefix("/") || path.has_prefix("\\") {
    return true
  }
  // Windows 盘符：C:/... / C:\...
  match (path.get_char(0), path.get_char(1)) {
    (Some(_), Some(':')) => true
    _ => false
  }
}

///|
fn is_drive_segment(segment : String) -> Bool {
  segment.length() == 2 && segment.get_char(1) == Some(':')
}

///|
/// 折叠 `.` / `..` / 重复分隔符，保留根（POSIX 的 `/` 与 Windows 的盘符）。
pub fn normalize_segments(path : String) -> String {
  let rooted = path.has_prefix("/")
  let stack : Array[String] = []
  for segment in path.split("/") {
    let segment = segment.to_owned()
    if segment.is_empty() || segment == "." {
      continue
    }
    if segment == ".." {
      let at_root = stack.is_empty() ||
        (stack.length() == 1 && is_drive_segment(stack[0]))
      if !at_root {
        let _ = stack.pop()
      }
      continue
    }
    stack.push(segment)
  }
  let joined = stack.join("/")
  if rooted {
    "/" + joined
  } else {
    joined
  }
}

///|
/// 父目录（`/a/b/c` → `/a/b`；`/a` → `/`；`C:/a` → `C:/`）。
pub fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) =>
      if index == 0 {
        "/"
      } else if index == 2 && path.get_char(1) == Some(':') {
        path[:3].to_owned()
      } else {
        path[:index].to_owned()
      }
    None => "."
  }
}

///|
/// 最后一段（`/a/b/c.txt` → `c.txt`）。
pub fn basename(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
/// 把绝对路径相对化（不在 root 下面时原样返回）。
pub fn relative_to(path : String, root : String) -> String {
  let path = path.replace_all(old="\\", new="/")
  let root = root.replace_all(old="\\", new="/")
  let prefix = if root.has_suffix("/") { root } else { root + "/" }
  if path.has_prefix(prefix) {
    path[prefix.length():].to_owned()
  } else if path == root {
    "."
  } else {
    path
  }
}

///|
/// 输出里的路径统一成 `/` 分隔，并去掉 `./` 前缀。
pub fn display_path(path : String) -> String {
  let normalized = path.replace_all(old="\\", new="/")
  if normalized.has_prefix("./") {
    normalized[2:].to_owned()
  } else {
    normalized
  }
}

///|
/// glob 匹配。语义贴着 `fd --glob` / shell glob：
///
/// - 不含 `/` 的 pattern 只匹配**文件名**（fd 默认就是按 basename 匹配）；
/// - 含 `/` 时按段匹配，`**` 作为整段可以跨任意层；
/// - `*` / `?` 不出本段；`[...]` 支持字符集合与区间。
pub fn glob_match(pattern : String, path : String) -> Bool {
  let pattern = display_path(pattern)
  let path = display_path(path)
  if !pattern.contains("/") {
    return match_segment(pattern, basename(path))
  }
  let pattern_segments : Array[String] = []
  for segment in pattern.split("/") {
    if !segment.is_empty() {
      pattern_segments.push(segment.to_owned())
    }
  }
  let path_segments : Array[String] = []
  for segment in path.split("/") {
    if !segment.is_empty() {
      path_segments.push(segment.to_owned())
    }
  }
  match_segments(pattern_segments, 0, path_segments, 0)
}

///|
fn match_segments(
  pattern : Array[String],
  pattern_index : Int32,
  path : Array[String],
  path_index : Int32,
) -> Bool {
  if pattern_index >= pattern.length() {
    return path_index >= path.length()
  }
  if pattern[pattern_index] == "**" {
    // `**` 吞掉 0..=剩余段数，逐个试。
    let mut next = path_index
    while next <= path.length() {
      if match_segments(pattern, pattern_index + 1, path, next) {
        return true
      }
      next = next + 1
    }
    return false
  }
  if path_index >= path.length() {
    return false
  }
  if !match_segment(pattern[pattern_index], path[path_index]) {
    return false
  }
  match_segments(pattern, pattern_index + 1, path, path_index + 1)
}

///|
fn match_segment(pattern : String, text : String) -> Bool {
  match_segment_at(pattern, 0, text, 0)
}

///|
fn match_segment_at(
  pattern : String,
  pattern_index : Int32,
  text : String,
  text_index : Int32,
) -> Bool {
  if pattern_index >= pattern.length() {
    return text_index >= text.length()
  }
  match pattern.get_char(pattern_index) {
    Some('*') => {
      // 连续的 `*` 等价于一个。
      let mut next_pattern = pattern_index
      while pattern.get_char(next_pattern) == Some('*') {
        next_pattern = next_pattern + 1
      }
      let mut next_text = text_index
      while next_text <= text.length() {
        if match_segment_at(pattern, next_pattern, text, next_text) {
          return true
        }
        next_text = next_text + 1
      }
      false
    }
    Some('?') =>
      if text_index >= text.length() {
        false
      } else {
        match_segment_at(pattern, pattern_index + 1, text, text_index + 1)
      }
    Some('[') => match_character_class(pattern, pattern_index, text, text_index)
    Some('\\') =>
      // 转义：`\*` 匹配字面 `*`。
      if pattern_index + 1 < pattern.length() {
        if text.get_char(text_index) == pattern.get_char(pattern_index + 1) {
          match_segment_at(pattern, pattern_index + 2, text, text_index + 1)
        } else {
          false
        }
      } else {
        false
      }
    Some(character) =>
      if text.get_char(text_index) == Some(character) {
        match_segment_at(pattern, pattern_index + 1, text, text_index + 1)
      } else {
        false
      }
    None => false
  }
}

///|
/// `[...]`：支持 `!` / `^` 取反与 `a-z` 区间。
fn match_character_class(
  pattern : String,
  pattern_index : Int32,
  text : String,
  text_index : Int32,
) -> Bool {
  let character = match text.get_char(text_index) {
    Some(character) => character
    None => return false
  }
  let mut index = pattern_index + 1
  let negated = match pattern.get_char(index) {
    Some('!') | Some('^') => {
      index = index + 1
      true
    }
    _ => false
  }
  let ranges : Array[(Char, Char)] = []
  while index < pattern.length() && pattern.get_char(index) != Some(']') {
    let start = match pattern.get_char(index) {
      Some(character) => character
      None => return false
    }
    if pattern.get_char(index + 1) == Some('-') &&
      index + 2 < pattern.length() &&
      pattern.get_char(index + 2) != Some(']') {
      let end = match pattern.get_char(index + 2) {
        Some(character) => character
        None => return false
      }
      ranges.push((start, end))
      index = index + 3
    } else {
      ranges.push((start, start))
      index = index + 1
    }
  }
  if index >= pattern.length() {
    // 没有闭合的 `[`：不匹配（把它当成普通字符的宽容处理会掩盖用户写错）。
    return false
  }
  let mut contained = false
  let value = character.to_int()
  for range in ranges {
    let (start, end) = range
    if value >= start.to_int() && value <= end.to_int() {
      contained = true
    }
  }
  if negated {
    contained = !contained
  }
  if contained {
    match_segment_at(pattern, index + 1, text, text_index + 1)
  } else {
    false
  }
}

///|
/// `path` 的祖先目录链（含自身），用于找 `.git` 往上走。
pub fn ancestors(path : String) -> Array[String] {
  let out : Array[String] = []
  let mut current = path.replace_all(old="\\", new="/")
  while true {
    out.push(current)
    let parent = parent_dir(current)
    if parent == current {
      break
    }
    current = parent
  }
  out
}
