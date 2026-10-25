// 上下文文件（AGENTS.md 一族）的发现与渲染。

///|
/// 一个候选文件名也没找到时的占位 —— 返回值语义与「文件存在但读不出来」区分开。
/// 发现函数对每个目录按 pi 的候选顺序试：override 优先于正式名，AGENTS 优先于 CLAUDE。
let context_candidates : Array[String] = [
  "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD",
]

///|
pub(all) struct ContextFile {
  /// 绝对路径（`/` 分隔）。
  path : String
  /// 去掉 BOM 之后的正文。
  content : String
} derive(Eq, Debug)

///|
/// 去掉 UTF-8 BOM（Windows 记事本写出来的文件常带）。
fn strip_bom(text : String) -> String {
  if text.has_prefix("\u{feff}") {
    text[1:].to_owned()
  } else {
    text
  }
}

///|
/// 在一个目录里找上下文文件，找到就读出来。找不到 / 读不出来都返回 None ——
/// 读失败宁可当没有，也不能把空内容当规则发给模型。
async fn load_context_file_from_dir(directory : String) -> ContextFile? {
  for name in context_candidates {
    let path = directory + "/" + name
    let exists = @fs.exists(path) catch { _ => false }
    if exists {
      let kind = @fs.kind(path) catch { _ => continue }
      if kind != @fs.Regular {
        continue
      }
      let data = @fs.read_file(path) catch { _ => continue }
      return Some({ path, content: strip_bom(@utf8.decode_lossy(data.binary())) })
    }
  }
  None
}

///|
/// 祖先目录链（含自身，从 cwd 往上到根）。
fn ancestor_dirs(cwd : String) -> Array[String] {
  let out : Array[String] = []
  let mut current = cwd.replace_all(old="\\", new="/")
  while true {
    out.push(current)
    let parent = match current.rev_find("/") {
      Some(0) => break
      Some(index) =>
        if current.get_char(1) == Some(':') && index == 2 {
          current[:3].to_owned()
        } else {
          current[:index].to_owned()
        }
      None => break
    }
    if parent == current {
      break
    }
    current = parent
  }
  out
}

///|
/// 全部上下文文件：agent 目录的一份（全局）在前，cwd 沿祖先链的（项目级）
/// 在后；同一层离 cwd 越近越靠后。路径重复时只收第一份。
///
/// elA 的 shadowed-worktree 判定（git worktree 主仓库那份被本目录遮住）不搬：
/// 那需要读 .git 内部结构，收益只在这一个布局上，先不做。
pub async fn load_context_files(
  cwd : String,
  agent_dir : String,
) -> Array[ContextFile] {
  let out : Array[ContextFile] = []
  let seen : Set[String] = Set([])
  match load_context_file_from_dir(agent_dir) {
    Some(file) => {
      out.push(file)
      seen.add(file.path.to_lower())
    }
    None => ()
  }
  // 从最远的祖先收到最近的：渲染时「越近的规则越靠后」，与 pi 的顺序一致。
  let dirs = ancestor_dirs(cwd)
  let found : Array[ContextFile] = []
  let mut index = dirs.length() - 1
  while index >= 0 {
    match load_context_file_from_dir(dirs[index]) {
      Some(file) => {
        let key = file.path.to_lower()
        if !seen.contains(key) {
          found.push(file)
          seen.add(key)
        }
      }
      None => ()
    }
    index = index - 1
  }
  for file in found {
    out.push(file)
  }
  out
}

///|
/// XML 转义（属性值里的引号与尖括号）。与 pi 的 escapeXml 同一套五件。
pub fn escape_xml(text : String) -> String {
  text.replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&apos;")
}

///|
/// `<project_context>` 段的内容：一句引言 + 每份文件一个
/// `<project_instructions path="…">` 块。形状照 pi 的 `renderProjectContext`。
pub fn render_project_context(files : Array[ContextFile]) -> String {
  let parts : Array[String] = ["Project-specific instructions and guidelines:"]
  for file in files {
    parts.push(
      "<project_instructions path=\"" +
      escape_xml(file.path) +
      "\">\n" +
      file.content +
      "\n</project_instructions>",
    )
  }
  parts.join("\n\n")
}

///|
/// `[Context]` 横幅的显示路径：cwd 之下的相对化，其余缩 `~`，分隔符统一 `/`。
pub fn context_display_path(path : String, cwd : String, home : String) -> String {
  let path = path.replace_all(old="\\", new="/")
  let cwd = cwd.replace_all(old="\\", new="/")
  let shown = match relative_under(path, cwd) {
    Some(relative) => relative
    None => {
      let home = home.replace_all(old="\\", new="/")
      if !home.is_empty() && path.has_prefix(home + "/") {
        "~/" + path[home.length() + 1:].to_owned()
      } else if !home.is_empty() && path == home {
        "~"
      } else {
        path
      }
    }
  }
  shown
}

///|
/// path 在 root 之下（含相等）时给出相对路径，否则 None。
fn relative_under(path : String, root : String) -> String? {
  if path == root {
    return Some(".")
  }
  let prefix = if root.has_suffix("/") { root } else { root + "/" }
  if path.has_prefix(prefix) {
    Some(path[prefix.length():].to_owned())
  } else {
    None
  }
}
