// 技能装载与 prompt 渲染 —— 离线测试，用 `_build/` 下的临时目录。

///|
fn skills_root() -> String {
  "_build/skills-test"
}

///|
async fn make_dir(name : String) -> String {
  let dir = skills_root() + "/" + name
  @fs.mkdir(dir, recursive=true) catch {
    _ => ()
  }
  dir
}

///|
async fn put(path : String, content : String) -> Unit {
  @fs.mkdir(path[:path.rev_find("/").unwrap()], recursive=true) catch {
    _ => ()
  }
  @fs.write_file(path, content)
}

///|
fn skill_md(name~ : String = "", description~ : String, extra~ : String = "") -> String {
  let name_line = if name == "" { "" } else { "name: " + name + "\n" }
  "---\n" +
  name_line +
  "description: " +
  description +
  "\n" +
  extra +
  "---\n" +
  "正文第一行\n"
}

///|
async test "load_skill_registry：目录技能 + frontmatter 解析" {
  let agent = make_dir("basic-agent")
  put(
    agent + "/skills/demo/SKILL.md",
    skill_md(description="一个演示技能", extra="disable-model-invocation: true\n"),
  )
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  assert_eq(registry.skills.length(), 1)
  let skill = registry.skills[0]
  // frontmatter 没写 name → 退回父目录名。
  assert_eq(skill.name, "demo")
  assert_eq(skill.description, "一个演示技能")
  assert_true(skill.disable_model_invocation)
  assert_eq(skill.base_dir, agent + "/skills/demo")
  assert_eq(skill.scope, "user")
  assert_eq(registry.diagnostics.length(), 0)
}

///|
async test "load_skill_registry：project 层与重名时 user 赢" {
  let agent = make_dir("collision-agent")
  put(agent + "/skills/shared/SKILL.md", skill_md(description="user 版"))
  let cwd = skills_root()
  put(
    cwd + "/.pi/skills/shared/SKILL.md",
    skill_md(description="project 版"),
  )
  put(cwd + "/.pi/skills/only-project/SKILL.md", skill_md(description="项目独有"))
  let registry = load_skill_registry(cwd, agent, home_dir="")
  assert_eq(registry.skills.length(), 2)
  let mut shared : Skill? = None
  for skill in registry.skills {
    if skill.name == "shared" {
      shared = Some(skill)
    }
  }
  assert_eq(shared.unwrap().description, "user 版")
  assert_eq(shared.unwrap().scope, "user")
  // 重名诊断要能看见 —— 静默丢技能是最坏的行为。
  assert_true(
    registry.diagnostics.any(fn(d) { d.contains("重名") && d.contains("shared") }),
  )
}

///|
async test "load_skill_registry：缺 description 的不装载，但别的照常" {
  let agent = make_dir("desc-agent")
  put(agent + "/skills/bad/SKILL.md", "---\nname: bad\n---\n没有描述")
  put(agent + "/skills/good/SKILL.md", skill_md(name="good", description="有描述"))
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  assert_eq(registry.skills.length(), 1)
  assert_eq(registry.skills[0].name, "good")
  assert_true(registry.diagnostics.any(fn(d) { d.contains("description") }))
}

///|
async test "load_skill_registry：目录里没有 SKILL.md 时裸 *.md 也要有 description" {
  let agent = make_dir("flat-agent")
  put(agent + "/skills/notes.md", "---\ndescription: 平铺的技能\n---\n正文")
  put(agent + "/skills/plain.md", "没有 frontmatter 的普通 md")
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  // notes.md 装载（名字取文件名），plain.md 被跳过并记诊断。
  assert_eq(registry.skills.length(), 1)
  assert_eq(registry.skills[0].name, "notes")
  assert_true(registry.diagnostics.length() > 0)
}

///|
async test "load_skill_registry：目录里有 SKILL.md 就不再往下递归" {
  let agent = make_dir("nested-agent")
  put(agent + "/skills/root/SKILL.md", skill_md(name="root", description="根技能"))
  put(
    agent + "/skills/root/inner/SKILL.md",
    skill_md(name="inner", description="不该被扫到"),
  )
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  assert_eq(registry.skills.length(), 1)
  assert_eq(registry.skills[0].name, "root")
}

///|
async test "load_skill_registry：家目录的 .agents/skills 也算 user 层" {
  let agent = make_dir("agents-home-agent")
  put(agent + "/skills/pi-style/SKILL.md", skill_md(description="pi 层"))
  // 家目录：main 传的是 USERPROFILE / HOME，这里是测试专用的一个子目录。
  let home = make_dir("agents-home")
  put(home + "/.agents/skills/agents-style/SKILL.md", skill_md(description="agents 层"))
  // 家目录与 agent 目录的重名：pi 层先扫，pi 层赢。
  put(home + "/.agents/skills/pi-style/SKILL.md", skill_md(description="agents 层的重名"))
  let registry = load_skill_registry(
    make_dir("agents-home-cwd"),
    agent,
    home_dir=home,
  )
  assert_eq(registry.skills.length(), 2)
  let mut agents_style : Skill? = None
  for skill in registry.skills {
    if skill.name == "agents-style" {
      agents_style = Some(skill)
    }
  }
  assert_eq(agents_style.unwrap().description, "agents 层")
  assert_eq(agents_style.unwrap().scope, "user")
  assert_true(
    registry.diagnostics.any(fn(d) { d.contains("重名") && d.contains("pi-style") }),
  )
}

///|
async test "load_skill_registry：额外路径与不存在的路径" {
  let agent = make_dir("extra-agent")
  let extra_dir = make_dir("extra-dir")
  put(extra_dir + "/SKILL.md", skill_md(name="from-path", description="路径进来的"))
  let registry = load_skill_registry(
    make_dir("extra-cwd"),
    agent,
    extra_paths=[extra_dir, "_build/skills-test/not-there"],
  )
  assert_eq(registry.skills.length(), 1)
  assert_eq(registry.skills[0].name, "from-path")
  assert_eq(registry.skills[0].scope, "path")
  assert_true(
    registry.diagnostics.any(fn(d) { d.contains("路径不存在") }),
  )
}

///|
test "render_skills_prompt：清单形状照 pi" {
  let skills = [
    {
      name: "demo",
      description: "一个 <演示> 技能",
      file_path: "C:/x/skills/demo/SKILL.md",
      base_dir: "C:/x/skills/demo",
      disable_model_invocation: false,
      scope: "user",
    },
    {
      name: "hidden",
      description: "不进 prompt",
      file_path: "C:/x/skills/hidden/SKILL.md",
      base_dir: "C:/x/skills/hidden",
      disable_model_invocation: true,
      scope: "user",
    },
  ]
  let text = render_skills_prompt(skills, "read")
  assert_true(text.contains("Use the read tool to load a skill's file"))
  assert_true(text.contains("<name>demo</name>"))
  assert_true(text.contains("<description>一个 &lt;演示&gt; 技能</description>"))
  assert_true(text.contains("<location>C:/x/skills/demo/SKILL.md</location>"))
  assert_false(text.contains("hidden"))
}

///|
test "render_skills_prompt：空清单给空串" {
  assert_eq(render_skills_prompt([], "read"), "")
}

///|
async test "expand_skill_command：展开成 skill 块、frontmatter 剥掉、带参数" {
  let agent = make_dir("expand-agent")
  let path = agent + "/skills/demo/SKILL.md"
  put(path, skill_md(description="演示"))
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  let reader = async fn(p : String) -> String {
    let data = @fs.read_file(p)
    @utf8.decode_lossy(data.binary())
  }
  // 带参数：块在前、参数在后。
  let expanded = expand_skill_command(
    "/skill:demo 帮我照它做",
    registry.skills,
    reader,
  )
  assert_true(expanded.has_prefix("<skill name=\"demo\" location=\"" + path + "\">"))
  assert_true(expanded.contains("References are relative to " + agent + "/skills/demo"))
  assert_true(expanded.contains("正文第一行"))
  assert_false(expanded.contains("description:"))
  assert_true(expanded.has_suffix("</skill>\n\n帮我照它做"))
  // 不带参数：块就是整条。
  let bare = expand_skill_command("/skill:demo", registry.skills, reader)
  assert_true(bare.has_suffix("</skill>"))
}

///|
async test "expand_skill_command：未知名字与普通文本原样返回" {
  let registry : SkillRegistry = { skills: [], diagnostics: [] }
  let reader = async fn(_p : String) -> String { "" }
  assert_eq(
    expand_skill_command("/skill:nope", registry.skills, reader),
    "/skill:nope",
  )
  assert_eq(
    expand_skill_command("普通消息", registry.skills, reader),
    "普通消息",
  )
}

///|
async test "expand_skill_command：读失败把原因留在原地" {
  let agent = make_dir("fail-agent")
  put(agent + "/skills/gone/SKILL.md", skill_md(description="会消失"))
  let registry = load_skill_registry(make_dir("isolated-cwd"), agent, home_dir="")
  // 把文件删掉再展开：装载时还在，读的时候没了。
  @fs.remove(registry.skills[0].file_path)
  let reader = async fn(p : String) -> String {
    let data = @fs.read_file(p)
    @utf8.decode_lossy(data.binary())
  }
  let text = expand_skill_command("/skill:gone", registry.skills, reader)
  assert_true(text.has_prefix("/skill:gone"))
  assert_true(text.contains("读取失败"))
}
