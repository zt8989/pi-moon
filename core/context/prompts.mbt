// Prompt 模板（pi 的 `<agent dir>/prompts` 与 `<cwd>/.pi/prompts`）。
//
// 一个 Markdown 文件就是一个 `/命令`：文件名是命令名，frontmatter 的
// `description`（缺省时取正文第一个非空行）进补全与横幅。pi-moon 只做发现与
// 展示 —— 模板的展开（$1 / $@ / ${1:-default} 那套替换）发生在输入侧，
// 是 REPL 的事，不在装载层。
//
// 发现口径照 pi 的 prompt-templates.md：只扫目录的直接 `*.md` 子文件，不递归；
// 同名时用户级先装载的获胜，被忽略的记一条诊断（与技能同规）。

///|
pub(all) struct PromptTemplate {
  /// 命令名（文件名去掉 `.md`）。
  name : String
  /// 补全与横幅里的一句话。frontmatter 的 description，退回正文第一个非空行。
  description : String
  /// 模板文件绝对路径。
  path : String
  /// 来自哪一层：user（agent 目录）/ project（工作目录）。
  scope : String
} derive(Eq, Debug)

///|
/// 装载 prompt 模板。目录不存在时静默返回空。
pub async fn load_prompt_templates(
  cwd : String,
  agent_dir : String,
) -> (Array[PromptTemplate], Array[String]) {
  let diagnostics : Array[String] = []
  let templates : Array[PromptTemplate] = []
  let seen : Map[String, String] = Map([])
  let dirs : Array[(String, String)] = [
    (agent_dir + "/prompts", "user"),
    (cwd + "/.pi/prompts", "project"),
  ]
  for dir_scope in dirs {
    let (dir, scope) = dir_scope
    let entries = @sys.readdir(dir) catch { _ => continue }
    let sorted = entries.copy()
    sorted.sort()
    for entry in sorted {
      if !entry.has_suffix(".md") {
        continue
      }
      let path = dir + "/" + entry
      let kind = @sys.kind(path) catch { _ => continue }
      if kind != @sys.Regular {
        continue
      }
      let name = entry[:entry.length() - 3].to_owned()
      if name.is_empty() {
        continue
      }
      let text = @sys.read_text(path) catch { _ => continue }
      let frontmatter = parse_frontmatter(text)
      let description = match frontmatter.fields.get("description") {
        Some(value) if !value.is_empty() => value
        _ => first_body_line(frontmatter.body)
      }
      match seen.get(name) {
        Some(winner) =>
          diagnostics.push(
            "重名：prompt /" +
            name +
            " 已被 " +
            winner +
            " 占用，忽略 " +
            path,
          )
        None => {
          seen.set(name, path)
          templates.push({ name, description, path, scope })
        }
      }
    }
  }
  (templates, diagnostics)
}

///|
/// 正文第一个非空行，截到 80 字符（补全里太长没意义）。
fn first_body_line(body : String) -> String {
  for line in body.split("\n") {
    let trimmed = line.trim().to_owned()
    if !trimmed.is_empty() {
      if trimmed.length() > 80 {
        return trimmed[:80].to_owned()
      }
      return trimmed
    }
  }
  ""
}
