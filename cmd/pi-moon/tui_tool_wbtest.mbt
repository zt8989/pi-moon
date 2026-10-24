// 工具专用渲染器的测试：标题、各工具的折叠预算、bash 留尾、edit 的 diff、
// write 的内容预览。这些算错只会让界面难看，但算错的原因（窗口方向、行数
// 统计、参数解析）值得钉住。

///|
fn render_call(
  name : String,
  arguments : String,
  output : String,
  expanded : Bool,
  is_error~ : Bool = false,
) -> ToolBlock {
  let call : @message.ToolCall = { id: "c1", name, arguments, }
  let result = @message.tool_result_message(call, output, is_error, 2L)
  match result {
    @message.ToolResultMsg(part) =>
      tool_render(
        call,
        Some(part),
        "",
        None,
        expanded,
        "/repo",
        80,
        Palette::ansi256(),
      )
    _ => abort("impossible")
  }
}

///|
fn block_text(block : ToolBlock) -> String {
  let mut text = block.title + "\n"
  for line in block.lines {
    text = text + line.text + "\n"
  }
  if !block.hint.is_empty() {
    text = text + block.hint + "\n"
  }
  text
}

///|
test "标题：每个工具一个形状（pi 的 renderCall 同形）" {
  assert_eq(
    render_call("bash", "{\"command\":\"cargo test\"}", "ok", false).title,
    "$ cargo test",
  )
  assert_eq(
    render_call(
      "powershell", "{\"command\":\"Get-ChildItem\",\"timeout\":30}", "ok", false,
    ).title,
    "PS> Get-ChildItem (timeout 30s)",
  )
  assert_eq(
    render_call("edit", "{\"path\":\"src/a.mbt\",\"edits\":[]}", "ok", false).title,
    "edit src/a.mbt",
  )
  assert_eq(
    render_call(
      "write", "{\"path\":\"out.txt\",\"content\":\"x\"}", "ok", false,
    ).title,
    "write out.txt",
  )
  assert_eq(
    render_call(
      "read", "{\"path\":\"big.log\",\"offset\":10,\"limit\":20}", "ok", false,
    ).title,
    "read big.log:10-29",
  )
  assert_eq(
    render_call(
      "grep", "{\"pattern\":\"todo\",\"glob\":\"*.mbt\"}", "ok", false,
    ).title,
    "grep /todo/ in . (*.mbt)",
  )
  assert_eq(
    render_call(
      "find", "{\"pattern\":\"*.ts\",\"path\":\"src\",\"limit\":50}", "ok", false,
    ).title,
    "find *.ts in src (limit 50)",
  )
  assert_eq(render_call("ls", "{}", "ok", false).title, "ls .")
  // 绝对路径相对化到 cwd，统一 / 分隔。
  assert_eq(
    render_call("read", "{\"path\":\"/repo/src/a.mbt\"}", "ok", false).title,
    "read src/a.mbt",
  )
  // 参数不是 JSON 时标题退回工具名 + 一行参数。
  assert_true(
    render_call("bash", "not json", "ok", false).title.has_prefix("$ ..."),
  )
}

///|
test "bash：折叠保留尾部 5 行，展开到 40 行" {
  let mut output = ""
  for i in 1..<=8 {
    output = output + "line" + i.to_string() + "\n"
  }
  let collapsed = render_call("bash", "{\"command\":\"seq\"}", output, false)
  assert_eq(
    block_text(collapsed),
    "$ seq\nline4\nline5\nline6\nline7\nline8\n… 前面还有 3 行（Ctrl+O 展开）\n",
  )
  let expanded = render_call("bash", "{\"command\":\"seq\"}", output, true)
  assert_eq(
    block_text(expanded),
    "$ seq\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\n",
  )
}

///|
test "bash：完成附耗时（毫秒 → pi 的 formatDuration 口径）" {
  let call : @message.ToolCall = {
    id: "c1",
    name: "bash",
    arguments: "{\"command\":\"sleep\"}",
  }
  let result = @message.tool_result_message(call, "done", false, 2L)
  let part = match result {
    @message.ToolResultMsg(part) => part
    _ => abort("impossible")
  }
  let block = tool_render(
    call,
    Some(part),
    "",
    Some(12300L),
    false,
    "/repo",
    80,
    Palette::ansi256(),
  )
  assert_eq(block_text(block), "$ sleep\ndone\n耗时 12.3s\n")
  assert_eq(format_duration(59000L), "59.0s")
  assert_eq(format_duration(65000L), "1m 5s")
  assert_eq(format_duration(3900000L), "1h 5m 0s")
}

///|
test "edit：从参数画 diff，删红加绿，首尾相同行折成上下文" {
  let block = render_call(
    "edit", "{\"path\":\"a.mbt\",\"edits\":[{\"oldText\":\"keep\\nold\\nend\",\"newText\":\"keep\\nnew\\nend\"}]}",
    "Successfully replaced 1 block(s) in a.mbt.", false,
  )
  assert_eq(block_text(block), "edit a.mbt\n  keep\n- old\n+ new\n  end\n")
  assert_eq(block.lines[0].fg, Some(Palette::ansi256().md.diff_context))
  assert_eq(block.lines[1].fg, Some(Palette::ansi256().md.diff_removed))
  assert_eq(block.lines[2].fg, Some(Palette::ansi256().md.diff_add))
  // 成功时不再复读 "Successfully replaced ..."。
  assert_false(block_text(block).contains("Successfully"))
}

///|
test "edit：多段 edits 用 @@ 分隔；上下文超过 3 行折成省略号" {
  let block = render_call(
    "edit", "{\"path\":\"a.mbt\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"A\"},{\"oldText\":\"b\",\"newText\":\"B\"}]}",
    "ok", false,
  )
  assert_eq(
    block_text(block),
    "edit a.mbt\n@@ edits[0]\n- a\n+ A\n@@ edits[1]\n- b\n+ B\n",
  )
  let wide = render_call(
    "edit", "{\"path\":\"a.mbt\",\"edits\":[{\"oldText\":\"c1\\nc2\\nc3\\nc4\\nc5\\nold\\nd4\\nd5\",\"newText\":\"c1\\nc2\\nc3\\nc4\\nc5\\nnew\\nd4\\nd5\"}]}",
    "ok", false,
  )
  assert_eq(
    block_text(wide),
    "edit a.mbt\n  …\n  c3\n  c4\n  c5\n- old\n+ new\n  d4\n  d5\n",
  )
}

///|
test "edit：失败时显示错误文本（红色），不画 diff" {
  let block = render_call(
    "edit",
    "{\"path\":\"a.mbt\",\"edits\":[{\"oldText\":\"x\",\"newText\":\"y\"}]}",
    "Could not find the exact text in a.mbt.",
    false,
    is_error=true,
  )
  assert_eq(
    block_text(block),
    "edit a.mbt\nCould not find the exact text in a.mbt.\n",
  )
  assert_eq(block.lines[0].fg, Some(Palette::ansi256().error))
}

///|
test "write：预览内容，折叠 10 行带总数提示" {
  let mut content = ""
  for i in 1..<=14 {
    // JSON 字符串里要写 \n 转义，不能塞真换行。
    content = content + "w" + i.to_string() + "\\n"
  }
  let arguments = "{\"path\":\"out.txt\",\"content\":\"" + content + "\"}"
  let collapsed = render_call(
    "write", arguments, "Successfully wrote to out.txt", false,
  )
  let collapsed_text = block_text(collapsed)
  assert_true(collapsed_text.contains("w1\n"))
  assert_false(collapsed_text.contains("w11"))
  assert_true(
    collapsed_text.contains("还有 4 行（共 14 行，Ctrl+O 展开）"),
  )
  let expanded = render_call("write", arguments, "ok", true)
  assert_true(block_text(expanded).contains("w14"))
  // 失败时显示错误文本，不预览内容。
  let failed = render_call(
    "write",
    arguments,
    "Could not write file",
    false,
    is_error=true,
  )
  assert_true(block_text(failed).contains("Could not write file"))
  assert_false(block_text(failed).contains("w1\n"))
}

///|
test "read：折叠只留标题，展开 40 行；grep / find / ls 各有自己的预算" {
  let mut output = ""
  for i in 1..<=30 {
    output = output + "r" + i.to_string() + "\n"
  }
  let read = render_call("read", "{\"path\":\"a\"}", output, false)
  assert_eq(read.lines.length(), 0)
  assert_eq(read.hint, "… 还有 30 行（Ctrl+O 展开）")
  let grep = render_call("grep", "{\"pattern\":\"x\"}", output, false)
  assert_eq(grep.lines.length(), 15)
  assert_eq(grep.hint, "… 还有 15 行（Ctrl+O 展开）")
  let find = render_call("find", "{\"pattern\":\"x\"}", output, false)
  assert_eq(find.lines.length(), 20)
  let ls = render_call("ls", "{}", output, false)
  assert_eq(ls.lines.length(), 20)
  let expanded = render_call("read", "{\"path\":\"a\"}", output, true)
  assert_eq(expanded.lines.length(), 30)
  // 未知工具走 6 行的通用兜底。
  let generic = render_call("mystery", "{}", output, false)
  assert_eq(generic.lines.length(), 6)
}

///|
test "还在跑的工具块：显示进度尾部，附不上耗时" {
  let call : @message.ToolCall = {
    id: "c1",
    name: "bash",
    arguments: "{\"command\":\"sleep\"}",
  }
  let block = tool_render(
    call,
    None,
    "step1\nstep2\nstep3\nstep4\nstep5\nstep6",
    None,
    false,
    "/repo",
    80,
    Palette::ansi256(),
  )
  assert_eq(
    block_text(block),
    "$ sleep\nstep2\nstep3\nstep4\nstep5\nstep6\n… 前面还有 1 行（Ctrl+O 展开）\n",
  )
}

///|
test "块排版：标题加粗、正文可带色、提示用 dim，底色铺满整行" {
  let call : @message.ToolCall = {
    id: "c1",
    name: "bash",
    arguments: "{\"command\":\"ls\"}",
  }
  let state = {
    ..test_state(),
    messages: [
      @message.user_message("hi", 1L),
      @message.AssistantMsg({
        content: [@message.ToolCallBlock(call)],
        stop_reason: "toolUse",
        error_message: None,
        usage: None,
        timestamp: 2L,
      }),
      @message.tool_result_message(call, "ok", false, 3L),
    ],
  }
  let lines = chat_lines(state, false, 40, [])
  let mut found_title = false
  let mut found_blank = false
  for line in lines {
    if line.text.has_prefix(" $ ls") {
      found_title = true
      assert_true(line.bold)
      assert_eq(line.bg, Some(Palette::ansi256().tool_success_bg))
      assert_eq(display_width(line.text), 40)
    }
    if line.text.trim(chars=" ").is_empty() &&
      line.bg == Some(Palette::ansi256().tool_success_bg) {
      found_blank = true
    }
  }
  assert_true(found_title)
  assert_true(found_blank)
}
