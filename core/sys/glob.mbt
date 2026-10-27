// glob：两端共用一份实现。
//
// 走 `readdir` / `kind` 递归，只匹配文件名（最后一段只要普通文件）。支持的形状
// 就是 `glob` / `find` 工具会用到的那几种：`*`（段内任意字符）、`?`（单个字符）、
// `[abc]` / `[a-z]` / `[!abc]`（字符集）、`**`（任意层目录，含零层）。
//
// 不用 `@shell.glob` 的原因：shell 包只支持 native + wasm，js 端没有它，而
// 「同一个 API 在两端都能编」是平台层的全部意义。

///|
/// 段内匹配：`*` 任意字符（不含 `/`），`?` 单个字符，`[...]` 字符集。
fn match_segment(pattern : String, name : String) -> Bool {
  match_pattern(pattern, 0, name, 0)
}

///|
/// `[...]`：返回 `(是否匹配, 右括号之后的下标)`。没闭合时按字面量处理。
fn match_class(
  pattern : String,
  start : Int,
  c : UInt16,
) -> (Bool, Int) {
  // start 指向 `[` 后的第一个字符。
  let mut index = start
  let mut negate = false
  if index < pattern.length() && (pattern[index] == '!' || pattern[index] == '^') {
    negate = true
    index = index + 1
  }
  let mut hit = false
  let mut first = true
  while index < pattern.length() {
    let current = pattern[index]
    if current == ']' && !first {
      let matched = if negate { !hit } else { hit }
      return (matched, index + 1)
    }
    first = false
    // `a-z` 区间：只有后面还跟 `-x` 且 `x` 不是 `]` 时才算区间。
    if index + 2 < pattern.length() && pattern[index + 1] == '-' &&
      pattern[index + 2] != ']' {
      let low = current
      let high = pattern[index + 2]
      if c >= low && c <= high {
        hit = true
      }
      index = index + 3
    } else {
      if c == current {
        hit = true
      }
      index = index + 1
    }
  }
  // 没闭合：当字面量 `[` 用。
  (c == '[', start)
}

///|
fn match_pattern(pattern : String, pi : Int, name : String, ni : Int) -> Bool {
  if pi >= pattern.length() {
    return ni >= name.length()
  }
  let c = pattern[pi]
  if c == '*' {
    // 连续 `*` 与单个同义。
    let mut next = pi + 1
    while next < pattern.length() && pattern[next] == '*' {
      next = next + 1
    }
    if next >= pattern.length() {
      return true
    }
    let mut index = ni
    while index <= name.length() {
      if match_pattern(pattern, next, name, index) {
        return true
      }
      index = index + 1
    }
    return false
  }
  if ni >= name.length() {
    return false
  }
  if c == '[' {
    let (hit, next) = match_class(pattern, pi + 1, name[ni])
    if hit {
      return match_pattern(pattern, next, name, ni + 1)
    }
    return false
  }
  if c == '?' || c == name[ni] {
    return match_pattern(pattern, pi + 1, name, ni + 1)
  }
  false
}

///|
fn split_path_segments(path : String) -> Array[String] {
  let segments : Array[String] = []
  for part in path.split("/") {
    let part = part.to_owned()
    if !part.is_empty() && part != "." {
      segments.push(part)
    }
  }
  segments
}

///|
fn join_relative(prefix : String, entry : String) -> String {
  if prefix.is_empty() {
    entry
  } else {
    prefix + "/" + entry
  }
}

///|
async fn walk_glob(
  base : String,
  prefix : String,
  segments : Array[String],
  index : Int,
  out : Array[String],
) -> Unit raise SysError {
  if index >= segments.length() {
    return
  }
  let segment = segments[index]
  let last = index == segments.length() - 1
  let entries = readdir(base + (if prefix.is_empty() { "" } else { "/" + prefix })) catch {
    _ => []
  }
  if segment == "**" {
    // `**` 也匹配零层：原地继续。
    walk_glob(base, prefix, segments, index + 1, out)
    for entry in entries {
      let child = join_relative(prefix, entry)
      let kind = kind(base + "/" + child) catch { _ => continue }
      if kind == Directory {
        walk_glob(base, child, segments, index, out)
      }
    }
    return
  }
  for entry in entries {
    if !match_segment(segment, entry) {
      continue
    }
    let child = join_relative(prefix, entry)
    let kind = kind(base + "/" + child) catch { _ => continue }
    if last {
      if kind == Regular {
        out.push(child)
      }
    } else if kind == Directory {
      walk_glob(base, child, segments, index + 1, out)
    }
  }
}

///|
pub async fn glob(pattern : String, cwd? : String = ".") -> Array[String] raise SysError {
  let out : Array[String] = []
  let segments = split_path_segments(pattern)
  if segments.is_empty() {
    return out
  }
  walk_glob(cwd, "", segments, 0, out)
  out
}
