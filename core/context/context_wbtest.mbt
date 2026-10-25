// 上下文文件发现与渲染 —— 离线测试，用 `_build/` 下的临时目录。

///|
fn context_root() -> String {
  "_build/context-test"
}

///|
async fn ctx_make_dir(name : String) -> String {
  let dir = context_root() + "/" + name
  @fs.mkdir(dir, recursive=true) catch {
    _ => ()
  }
  dir
}

///|
async fn ctx_put(path : String, content : String) -> Unit {
  @fs.mkdir(path[:path.rev_find("/").unwrap()], recursive=true) catch {
    _ => ()
  }
  @fs.write_file(path, content)
}

///|
test "render_project_context：每份文件一个 project_instructions 块" {
  let text = render_project_context(
    [
      { path: "C:/repo/AGENTS.md", content: "# 规则\n用中文回复" },
      { path: "C:/repo/sub/CLAUDE.md", content: "子目录规则" },
    ],
  )
  assert_true(text.has_prefix("Project-specific instructions and guidelines:"))
  assert_true(
    text.contains(
      "<project_instructions path=\"C:/repo/AGENTS.md\">\n# 规则\n用中文回复\n</project_instructions>",
    ),
  )
  assert_true(
    text.contains(
      "<project_instructions path=\"C:/repo/sub/CLAUDE.md\">\n子目录规则\n</project_instructions>",
    ),
  )
}

///|
test "escape_xml：五个保留字符" {
  assert_eq(
    escape_xml("<a b=\"c\" d='e'>&"),
    "&lt;a b=&quot;c&quot; d=&apos;e&apos;&gt;&amp;",
  )
}

///|
test "context_display_path：cwd 之下相对化，其余缩 ~" {
  assert_eq(
    context_display_path("C:/repo/AGENTS.md", "C:/repo", "C:/Users/me"),
    "AGENTS.md",
  )
  assert_eq(
    context_display_path("C:/repo/sub/AGENTS.md", "C:/repo", "C:/Users/me"),
    "sub/AGENTS.md",
  )
  assert_eq(
    context_display_path(
      "C:/Users/me/.pi/agent/AGENTS.md",
      "C:/repo",
      "C:/Users/me",
    ),
    "~/.pi/agent/AGENTS.md",
  )
  assert_eq(
    context_display_path("D:/elsewhere/AGENTS.md", "C:/repo", "C:/Users/me"),
    "D:/elsewhere/AGENTS.md",
  )
}

///|
async test "load_context_files：agent 目录一份在前，cwd 沿祖先链从远到近" {
  let agent = ctx_make_dir("agent")
  ctx_put(agent + "/AGENTS.md", "全局规则")
  let repo = ctx_make_dir("repo")
  ctx_put(repo + "/AGENTS.md", "仓库规则")
  ctx_put(repo + "/CLAUDE.md", "不该被读到（AGENTS 优先）")
  let sub = ctx_make_dir("repo/sub")
  ctx_put(sub + "/AGENTS.override.md", "子目录规则")
  let files = load_context_files(sub, agent)
  assert_eq(files.length(), 3)
  assert_eq(files[0].path, agent + "/AGENTS.md")
  assert_eq(files[0].content, "全局规则")
  // 祖先链从最远（repo）到最近（sub）。
  assert_eq(files[1].path, repo + "/AGENTS.md")
  assert_eq(files[2].path, sub + "/AGENTS.override.md")
  // cwd 本身没有、祖先也没有时只剩全局那份。
  let lonely = ctx_make_dir("lonely")
  assert_eq(load_context_files(lonely, agent).length(), 1)
}

///|
async test "load_context_files：BOM 去掉，读失败当没有" {
  let agent = ctx_make_dir("bom-agent")
  ctx_put(agent + "/AGENTS.md", "\u{feff}带 BOM 的规则")
  let cwd = ctx_make_dir("bom-cwd")
  let files = load_context_files(cwd, agent)
  assert_eq(files.length(), 1)
  assert_eq(files[0].content, "带 BOM 的规则")
}

///|
async test "load_context_files：同名路径只收一份" {
  let agent = ctx_make_dir("dup-agent")
  let cwd = ctx_make_dir("dup-cwd")
  ctx_put(agent + "/AGENTS.md", "A")
  // agent 目录同时是 cwd：全局与祖先链撞路径，只收第一份。
  let files = load_context_files(agent, agent)
  assert_eq(files.length(), 1)
  let _ = cwd
}
