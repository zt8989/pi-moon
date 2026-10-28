// Prompt 模板装载 —— 离线测试，用 `_build/` 下的临时目录。

///|
async fn prompts_root() -> String {
  let random = @random.Rand::Rand()
  let dir = "_build/prompts-test-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000).to_string()
  @fs.mkdir(dir, recursive=true) catch { _ => () }
  dir
}

///|
async fn put_file(path : String, content : String) -> Unit {
  @fs.mkdir(parent_dir_of(path), recursive=true) catch { _ => () }
  @fs.write_file(path, content)
}

///|
fn parent_dir_of(path : String) -> String {
  match path.rev_find("/") {
    Some(index) if index > 0 => path[:index].to_owned()
    _ => "."
  }
}

///|
async test "load_prompt_templates：用户级 + 项目级 + 描述回退" {
  let root = prompts_root()
  let agent = root + "/agent"
  let cwd = root + "/project"
  put_file(
    agent + "/prompts/review.md",
    "---\ndescription: 审查暂存区\nargument-hint: \"[focus]\"\n---\n审查 ${1:-correctness}。\n",
  )
  put_file(agent + "/prompts/no-desc.md", "第一个非空行当描述。\n正文。\n")
  put_file(cwd + "/.pi/prompts/fix.md", "修东西。\n")
  // 非 .md 与子目录都不算（pi 只认直接 .md 子文件）。
  put_file(agent + "/prompts/notes.txt", "不是模板")
  put_file(agent + "/prompts/nested/inner.md", "不递归")
  let (templates, diagnostics) = load_prompt_templates(cwd, agent)
  assert_eq(templates.length(), 3)
  let names = templates.map(template => template.name)
  assert_true(names.contains("review"))
  assert_true(names.contains("no-desc"))
  assert_true(names.contains("fix"))
  let review = templates.filter(template => template.name == "review")[0]
  assert_eq(review.description, "审查暂存区")
  assert_eq(review.scope, "user")
  // 没有 frontmatter 时退回正文第一个非空行。
  let no_desc = templates.filter(template => template.name == "no-desc")[0]
  assert_eq(no_desc.description, "第一个非空行当描述。")
  // 项目级模板 scope 是 project。
  let fix = templates.filter(template => template.name == "fix")[0]
  assert_eq(fix.scope, "project")
  assert_eq(diagnostics.length(), 0)
}

///|
async test "load_prompt_templates：同名用户级获胜并留诊断" {
  let root = prompts_root()
  let agent = root + "/agent"
  let cwd = root + "/project"
  put_file(agent + "/prompts/review.md", "用户级的。\n")
  put_file(cwd + "/.pi/prompts/review.md", "项目级的。\n")
  let (templates, diagnostics) = load_prompt_templates(cwd, agent)
  assert_eq(templates.length(), 1)
  assert_eq(templates[0].description, "用户级的。")
  assert_eq(templates[0].scope, "user")
  assert_true(diagnostics.any(line => line.contains("重名") && line.contains("/review")))
}

///|
async test "load_prompt_templates：目录不存在时静默为空" {
  let (templates, diagnostics) = load_prompt_templates(
    "_build/prompts-nope-cwd",
    "_build/prompts-nope-agent",
  )
  assert_eq(templates.length(), 0)
  assert_eq(diagnostics.length(), 0)
}
