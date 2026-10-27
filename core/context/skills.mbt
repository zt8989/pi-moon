// 技能（SKILL.md）装载。
// 发现位置照 pi 的 package-manager（见 load_skill_registry 的注释）；目录内的
// 发现规则照 pi 的 `loadSkillsFromDir`：
//   - 目录里有 SKILL.md → 它是技能根，不再往下递归；
//   - 否则递归子目录找 SKILL.md；
//   - 根目录的裸 `*.md` 也算技能（`.agents` 风格），但必须有 description。
//
// frontmatter 是简化版 YAML：只认扁平 `key: value` 的 name / description /
// disable-model-invocation 三个键。值可以带单引号或双引号。

///|
pub(all) struct Skill {
  /// 唯一名。frontmatter 的 name 优先，退回 SKILL.md 的父目录名。
  name : String
  /// 一句话描述 —— 模型靠它决定要不要去读这个文件。必填，空则不装载。
  description : String
  /// SKILL.md 的绝对路径，模型用 read 工具读它。
  file_path : String
  /// 相对路径按哪儿解析（pi 的 baseDir：SKILL.md 的父目录）。
  base_dir : String
  /// true = 不进 prompt 清单，只能显式展开（危险技能的作者自留开关）。
  disable_model_invocation : Bool
  /// 来自哪一层：user（agent 目录）/ project（工作目录）。
  scope : String
} derive(Eq, Debug)

///|
/// 装载结果：清单 + 诊断。坏文件不让整次装载失败，只记一句。
pub(all) struct SkillRegistry {
  skills : Array[Skill]
  diagnostics : Array[String]
} derive(Debug)

///|
fn skill_warning(message : String, path : String) -> String {
  "警告：" + message + "（" + path + "）"
}

///|
fn skill_collision(name : String, winner : String, loser : String) -> String {
  "重名：skill \"" +
  name +
  "\" 冲突，先装载的获胜（" +
  winner +
  "）；被忽略：" +
  loser
}

///|
/// 名字合法性照 pi 的 validateName（小写字母数字连字符，收诊断不拒绝）。
fn validate_name(name : String) -> Array[String] {
  let errors : Array[String] = []
  if name.length() > 64 {
    errors.push("name 超过 64 字符")
  }
  let mut valid = !name.is_empty()
  for character in name {
    let is_ok = (character >= 'a' && character <= 'z') ||
      (character >= '0' && character <= '9') ||
      character == '-'
    if !is_ok {
      valid = false
    }
  }
  if !valid {
    errors.push("name 含非法字符（只允许小写 a-z、0-9、连字符）")
  }
  if name.has_prefix("-") || name.has_suffix("-") {
    errors.push("name 不能以连字符开头或结尾")
  }
  if name.contains("--") {
    errors.push("name 不能有连续连字符")
  }
  errors
}

///|
/// frontmatter 解析结果：键值对 + 正文。
priv struct Frontmatter {
  fields : Map[String, String]
  flags : Set[String]
  body : String
}

///|
/// 扁平 frontmatter：`---` 行开头，下一个 `---` 行结束；行内 `key: value`。
/// 没有开头 `---`、没有闭合 `---` 都当没有 frontmatter，整篇是正文。
fn parse_frontmatter(text : String) -> Frontmatter {
  let normalized = text.replace_all(old="\r\n", new="\n").replace_all(old="\r", new="\n")
  let fields : Map[String, String] = Map([])
  let flags : Set[String] = Set([])
  if !normalized.has_prefix("---") {
    return { fields, flags, body: strip_bom(normalized) }
  }
  let rest = normalized[3:].to_owned()
  let after = match rest.find("\n---") {
    Some(index) => rest[index + 4:].to_owned()
    None => return { fields, flags, body: strip_bom(normalized) }
  }
  let header = rest[:rest.find("\n---").unwrap()].to_owned()
  let header = if header.has_prefix("\n") { header[1:].to_owned() } else { header }
  for line in header.split("\n") {
    let line = line.trim().to_owned()
    if line.is_empty() || line.has_prefix("#") {
      continue
    }
    match line.find(":") {
      Some(index) => {
        let key = line[:index].trim().to_owned()
        let value = line[index + 1:].trim().to_owned()
        if key == "disable-model-invocation" {
          if value == "true" {
            flags.add(key)
          }
        } else if !key.is_empty() {
          let value = strip_quotes(value)
          fields.set(key, value)
        }
      }
      None => ()
    }
  }
  { fields, flags, body: after.trim(chars=" \n").to_owned() }
}

///|
fn strip_quotes(value : String) -> String {
  if value.length() >= 2 &&
    ((value.has_prefix("\"") && value.has_suffix("\"")) ||
    (value.has_prefix("'") && value.has_suffix("'"))) {
    value[1:value.length() - 1].to_owned()
  } else {
    value
  }
}

///|
/// 读一个技能文件。返回装载好的技能（None = 放弃装载）与诊断。
async fn load_skill_file(
  path : String,
  scope : String,
  name_fallback~ : String,
) -> (Skill?, Array[String]) {
  let diagnostics : Array[String] = []
  let text = @sys.read_text_lossy(path) catch {
    err => return (None, [skill_warning("读取失败：" + err.to_string(), path)])
  }
  let frontmatter = parse_frontmatter(text)
  let description = frontmatter.fields.get("description").unwrap_or("")
  if description.is_empty() {
    return (None, [skill_warning("缺少 description", path)])
  }
  let base_dir = match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => "."
  }
  let name = match frontmatter.fields.get("name") {
    Some(name) => name
    None => name_fallback
  }
  for error in validate_name(name) {
    diagnostics.push(skill_warning(error, path))
  }
  let skill : Skill = {
    name,
    description,
    file_path: path,
    base_dir,
    disable_model_invocation: frontmatter.flags.contains("disable-model-invocation"),
    scope,
  }
  (Some(skill), diagnostics)
}

///|
/// 递归扫描一个目录。`include_root_files` 只在最外层为真（pi 的规则：
/// 裸 `*.md` 只认根目录的，子目录里只找 SKILL.md）。
async fn scan_skills_dir(
  directory : String,
  scope : String,
  include_root_files : Bool,
  registry : SkillRegistry,
) -> Unit {
  let entries = @sys.readdir(directory, include_hidden=true) catch {
    _ => return
  }
  // 目录里有 SKILL.md → 它是技能根，收下就走，不再递归。
  for entry in entries {
    if entry == "SKILL.md" {
      let parent = match directory.rev_find("/") {
        Some(index) => directory[index + 1:].to_owned()
        None => directory
      }
      let (skill, diagnostics) = load_skill_file(
        directory + "/" + entry,
        scope,
        name_fallback=parent,
      )
      for diagnostic in diagnostics {
        registry.diagnostics.push(diagnostic)
      }
      match skill {
        Some(skill) => registry.skills.push(skill)
        None => ()
      }
      return
    }
  }
  for entry in entries {
    if entry.has_prefix(".") || entry == "node_modules" {
      continue
    }
    let path = directory + "/" + entry
    let kind = @sys.kind(path) catch { _ => continue }
    match kind {
      @sys.Directory => {
        scan_skills_dir(path, scope, false, registry)
      }
      @sys.Regular =>
        if include_root_files && entry.has_suffix(".md") {
          let (skill, diagnostics) = load_skill_file(
            path,
            scope,
            name_fallback=entry[:entry.length() - 3].to_owned(),
          )
          for diagnostic in diagnostics {
            registry.diagnostics.push(diagnostic)
          }
          match skill {
            Some(skill) => registry.skills.push(skill)
            None => ()
          }
        }
      _ => ()
    }
  }
}

///|
/// 从一个路径装载技能（目录或单个 .md 文件）。路径不存在记诊断不报错。
async fn add_skill_path(
  raw_path : String,
  scope : String,
  registry : SkillRegistry,
) -> Unit {
  let exists = @sys.exists(raw_path) catch { _ => false }
  if !exists {
    registry.diagnostics.push(skill_warning("路径不存在", raw_path))
    return
  }
  let kind = @sys.kind(raw_path) catch {
    err => {
      registry.diagnostics.push(skill_warning(err.to_string(), raw_path))
      return
    }
  }
  match kind {
    @sys.Directory => scan_skills_dir(raw_path, scope, true, registry)
    @sys.Regular =>
      if raw_path.has_suffix(".md") {
        let file_name = match raw_path.rev_find("/") {
          Some(index) => raw_path[index + 1:].to_owned()
          None => raw_path
        }
        let (skill, diagnostics) = load_skill_file(
          raw_path,
          scope,
          name_fallback=file_name[:file_name.length() - 3].to_owned(),
        )
        for diagnostic in diagnostics {
          registry.diagnostics.push(diagnostic)
        }
        match skill {
          Some(skill) => registry.skills.push(skill)
          None => ()
        }
      } else {
        registry.diagnostics.push(skill_warning("不是 markdown 文件", raw_path))
      }
    _ => registry.diagnostics.push(skill_warning("不是文件或目录", raw_path))
  }
}

///|
/// 全部技能：`<agent dir>/skills`（user）→ `<cwd>/.pi/skills`（project）→
/// `--skill` 给的额外路径（path）。先装载的赢家与 pi 一致（项目级后到但
/// user 在前 —— pi 里 user 先扫，重名时 user 赢）。
///|
/// 全部技能。发现位置与顺序照 pi 的 package-manager（先装载的赢家）：
///
/// 1. `<agent dir>/skills`（`~/.pi/agent/skills`，pi 层 user）
/// 2. `<家>/.agents/skills`（agents 层 user —— Claude Code 风格的技能都在这）
/// 3. `<cwd>/.pi/skills`（pi 层 project）
/// 4. cwd 祖先链每层的 `.agents/skills`（离 cwd 越近越靠后）
/// 5. `--skill` 给的额外路径（path）
///
/// 与 pi 的差异：祖先链的 `.agents/skills` pi 只收到 git 仓库根为止，这里
/// 一直收到文件系统根（与本项目 AGENTS.md 祖先链的口径一致）。
pub async fn load_skill_registry(
  cwd : String,
  agent_dir : String,
  home_dir? : String,
  extra_paths? : Array[String],
) -> SkillRegistry {
  let registry : SkillRegistry = { skills: [], diagnostics: [] }
  let taken : Map[String, String] = Map([])
  let add = async fn(skill : Skill) {
    let key = skill.name.to_lower()
    match taken.get(key) {
      Some(winner) =>
        registry.diagnostics.push(skill_collision(skill.name, winner, skill.file_path))
      None => {
        taken.set(key, skill.file_path)
        registry.skills.push(skill)
      }
    }
  }
  let collect = async fn(directory : String, scope : String, root_files : Bool) {
    let scoped : SkillRegistry = { skills: [], diagnostics: [] }
    scan_skills_dir(directory, scope, root_files, scoped)
    for diagnostic in scoped.diagnostics {
      registry.diagnostics.push(diagnostic)
    }
    for skill in scoped.skills {
      add(skill)
    }
  }
  let normalized_cwd = cwd.replace_all(old="\\", new="/")
  collect(agent_dir + "/skills", "user", true)
  match home_dir {
    Some(home) =>
      if !home.is_empty() {
        collect(
          home.replace_all(old="\\", new="/") + "/.agents/skills",
          "user",
          true,
        )
      }
    None => ()
  }
  collect(normalized_cwd + "/.pi/skills", "project", true)
  // 祖先链的 .agents/skills：从最远的祖先到 cwd（近的规则更靠后）。家目录
  // 那层跳过 —— 上面已经作为 user 层收过，否则同一个文件会跟自己重名。
  let dirs : Array[String] = []
  let home_skills = match home_dir {
    Some(home) if !home.is_empty() =>
      Some(home.replace_all(old="\\", new="/") + "/.agents/skills")
    _ => None
  }
  let mut current = normalized_cwd
  while true {
    dirs.push(current + "/.agents/skills")
    match current.rev_find("/") {
      Some(0) => break
      Some(index) => {
        let parent = if current.get_char(1) == Some(':') && index == 2 {
          current[:3].to_owned()
        } else {
          current[:index].to_owned()
        }
        if parent == current {
          break
        }
        current = parent
      }
      None => break
    }
  }
  let mut index = dirs.length() - 1
  while index >= 0 {
    let skip = match home_skills {
      Some(home_skills_dir) => dirs[index] == home_skills_dir
      None => false
    }
    if !skip {
      collect(dirs[index], "project", true)
    }
    index = index - 1
  }
  for raw_path in extra_paths.unwrap_or([]) {
    add_skill_path(raw_path, "path", registry)
  }
  registry
}

///|
/// `<skills>` prompt 段：只列清单（名字 + 描述 + 路径），不装正文。
/// `disable-model-invocation` 的不列。形状照 pi 的 `formatSkillsForPrompt`。
/// `read_tool` 是清单开头那句提示里点的工具名（开了 read 就写 read，否则
/// 写真正能读文件的那个 —— 模型得有一条能读文件的路）。
pub fn render_skills_prompt(skills : Array[Skill], read_tool : String) -> String {
  let visible : Array[Skill] = []
  for skill in skills {
    if !skill.disable_model_invocation {
      visible.push(skill)
    }
  }
  if visible.is_empty() {
    return ""
  }
  let lines : Array[String] = [
    "The following skills provide specialized instructions for specific tasks.",
    "Use the " +
    read_tool +
    " tool to load a skill's file when the task matches its description.",
    "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
    "",
    "<available_skills>",
  ]
  for skill in visible {
    lines.push("  <skill>")
    lines.push("    <name>" + escape_xml(skill.name) + "</name>")
    lines.push("    <description>" + escape_xml(skill.description) + "</description>")
    lines.push("    <location>" + escape_xml(skill.file_path) + "</location>")
    lines.push("  </skill>")
  }
  lines.push("</available_skills>")
  lines.join("\n")
}

///|
/// `/skill:<name> [参数]` → `<skill …>正文</skill>`（+ 参数）。
///
/// 展开成 XML 块而不是当普通文本：模型的语义是「参考资料」，而且后面还能
/// 从消息里认出它来。frontmatter 是给装载器的元数据，发给模型是噪声，剥掉。
/// 未知名字原样返回（静默吞掉会让用户以为命令生效了）。
pub async fn expand_skill_command(
  text : String,
  skills : Array[Skill],
  read_file : async (String) -> String,
) -> String {
  if !text.has_prefix("/skill:") {
    return text
  }
  let rest = text["/skill:".length():].to_owned()
  let (name, args) = match rest.find(" ") {
    Some(index) => (rest[:index].to_owned(), rest[index + 1:].trim().to_owned())
    None => (rest, "")
  }
  let skill_index : Int32? = {
    let mut found : Int32? = None
    let mut index = 0
    while index < skills.length() && found is None {
      if skills[index].name == name {
        found = Some(index)
      }
      index = index + 1
    }
    found
  }
  let skill = match skill_index {
    Some(index) => skills[index]
    None => return text
  }
  let raw = read_file(skill.file_path) catch {
    err => return text + "\n（skill \"" + name + "\" 读取失败：" + err.to_string() + "）"
  }
  let body = parse_frontmatter(raw).body
  let block =
    "<skill name=\"" +
    skill.name +
    "\" location=\"" +
    skill.file_path +
    "\">\n" +
    "References are relative to " +
    skill.base_dir +
    ".\n\n" +
    body +
    "\n</skill>"
  if args.is_empty() {
    block
  } else {
    block + "\n\n" + args
  }
}
