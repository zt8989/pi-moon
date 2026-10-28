// 源码体检：这个扩展能不能进沙盒。
//
// 沙盒里没有 Node（没有 fs / 子进程 / 网络），也没有模块加载器 —— 所以一个
// 扩展只要在**编译后**的 JS 里真的 import 了这些东西，就装不进来。这里只做
// 判定，不做垫片：宁可少装一个扩展，也不给半个 Node。
//
// 判定在「编译后」而不是「源码」上做，是因为 `import type { ExtensionAPI }
// from "@earendil-works/pi-coding-agent"` 这类纯类型导入在编译后不存在。

///|
/// Node 内建模块名单（`node:` 前缀以外的裸名字）。命中即跳过。
let node_builtins : Array[String] = [
  "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
  "crypto", "dgram", "diagnostics_channel", "dns", "domain", "events", "fs", "http",
  "http2", "https", "inspector", "module", "net", "os", "path", "perf_hooks", "process",
  "punycode", "querystring", "readline", "reporter", "repl", "stream", "string_decoder",
  "sys", "timers", "tls", "trace_events", "tty", "url", "util", "v8", "vm", "wasi",
  "worker_threads", "zlib",
]

///|
/// 一个 import / require 的说明符及其判定结果。
pub(all) enum SpecifierKind {
  /// 沙盒里能用的：空说明符（不该出现）或 `data:`/`virtual:` 这类宿主垫的。
  Allowed
  /// Node 内建模块。
  NodeBuiltin
  /// 相对路径 —— 沙盒里没有模块加载器，解析不了。
  Relative
  /// 裸包名 —— 没有 node_modules 解析。
  Package
} derive(Eq, Debug)

///|
/// 说明符分类。顺序要紧：`node:` 前缀优先于内建名单，相对路径优先于裸包。
pub fn classify_specifier(spec : String) -> SpecifierKind {
  if spec.is_empty() {
    return Allowed
  }
  if spec.has_prefix("node:") {
    return NodeBuiltin
  }
  if spec.has_prefix("./") || spec.has_prefix("../") || spec == "." || spec == ".." {
    return Relative
  }
  if spec.has_prefix("/") {
    return Relative
  }
  if node_builtins.contains(spec) {
    return NodeBuiltin
  }
  if spec.has_prefix("http://") || spec.has_prefix("https://") {
    return Package
  }
  Package
}

///|
/// 词法单元：够区分标识符、字符串、标点即可。
priv enum Token {
  Ident(String)
  Str(String)
  Punct(Char)
}

///|
/// 极简词法：跳过注释，收集标识符与字符串字面量。
///
/// 不追求完整 JS 词法 —— 只要不会把注释里的 `import`、或字符串里的括号
/// 当成代码。模板字符串按普通字符串处理（插值里的 import 会被漏掉，接受）。
fn lex(source : String) -> Array[Token] {
  let tokens : Array[Token] = []
  let chars = source.to_array()
  let length = chars.length()
  let mut index = 0
  while index < length {
    let character = chars[index]
    if character == '/' && index + 1 < length && chars[index + 1] == '/' {
      while index < length && chars[index] != '\n' {
        index = index + 1
      }
    } else if character == '/' && index + 1 < length && chars[index + 1] == '*' {
      index = index + 2
      while index + 1 < length && !(chars[index] == '*' && chars[index + 1] == '/') {
        index = index + 1
      }
      index = index + 2
    } else if character == '"' || character == '\'' || character == '`' {
      let quote = character
      index = index + 1
      let buffer = StringBuilder()
      while index < length && chars[index] != quote {
        if chars[index] == '\\' && index + 1 < length {
          buffer.write_char(chars[index + 1])
          index = index + 2
        } else {
          buffer.write_char(chars[index])
          index = index + 1
        }
      }
      index = index + 1
      tokens.push(Str(buffer.to_string()))
    } else if is_ident_start(character) {
      let buffer = StringBuilder()
      while index < length && is_ident_part(chars[index]) {
        buffer.write_char(chars[index])
        index = index + 1
      }
      tokens.push(Ident(buffer.to_string()))
    } else if is_space(character) {
      index = index + 1
    } else {
      tokens.push(Punct(character))
      index = index + 1
    }
  }
  tokens
}

///|
fn is_space(character : Char) -> Bool {
  character == ' ' || character == '\t' || character == '\n' || character == '\r'
}

///|
fn is_ident_start(character : Char) -> Bool {
  (character >= 'a' && character <= 'z') ||
  (character >= 'A' && character <= 'Z') ||
  character == '_' ||
  character == '$'
}

///|
fn is_ident_part(character : Char) -> Bool {
  is_ident_start(character) || (character >= '0' && character <= '9')
}

///|
/// 从 token 流里抽出所有 import / require 的说明符。
pub fn import_specifiers(source : String) -> Array[String] {
  let tokens = lex(source)
  let specs : Array[String] = []
  let mut index = 0
  while index < tokens.length() {
    let next_is_str = index + 1 < tokens.length() && token_str(tokens[index + 1]) is Some(_)
    let next = if next_is_str { token_str(tokens[index + 1]) } else { None }
    match tokens[index] {
      Ident(keyword) =>
        if keyword == "from" || keyword == "import" {
          // `import "x"` / `a from "x"` / `import("x")`
          match next {
            Some(spec) => specs.push(spec)
            None =>
              if keyword == "import" && index + 2 < tokens.length() {
                if is_open_paren(tokens[index + 1]) {
                  match token_str(tokens[index + 2]) {
                    Some(spec) => specs.push(spec)
                    None => ()
                  }
                }
              }
          }
        } else if keyword == "require" {
          if index + 2 < tokens.length() && is_open_paren(tokens[index + 1]) {
            match token_str(tokens[index + 2]) {
              Some(spec) => specs.push(spec)
              None => ()
            }
          }
        }
      _ => ()
    }
    index = index + 1
  }
  specs
}

///|
fn token_str(token : Token) -> String? {
  match token {
    Str(text) => Some(text)
    _ => None
  }
}

///|
fn is_open_paren(token : Token) -> Bool {
  match token {
    Punct(character) => character == '('
    _ => false
  }
}

///|
/// 体检结论：全部说明符都在沙盒里可用时返回 None，否则给出第一个坏说明符。
///
/// 只报第一个，是因为诊断一行一条；坏掉的第二个不影响「不装载」这个结论。
pub fn first_unsupported_import(source : String) -> (SpecifierKind, String)? {
  for spec in import_specifiers(source) {
    let kind = classify_specifier(spec)
    match kind {
      Allowed => continue
      _ => return Some((kind, spec))
    }
  }
  None
}
