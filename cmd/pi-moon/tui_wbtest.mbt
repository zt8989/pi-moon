// TUI 的纯逻辑测试：折行、输入编辑、可见窗口、键位与命令解析。
//
// 交互本身（raw mode、流式重绘）要在真终端里看；这里锁住的是「算错会很难
// 归因」的那几处：CJK 折行、光标不走字节、翻页越界、Esc 的两种语义。

///|
fn test_state() -> @state.AgentState {
  @state.create_initial_state({
    system_prompt: "test",
    provider_name: "deepseek",
    model_id: "deepseek-chat",
    thinking_level: "off",
    tool_names: [],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 1000L,
    session_id: "s-test",
    cwd: ".",
    trace: None,
  })
}

///|
test "wrap_text 按显示宽度折行：CJK 一个字占两格" {
  let lines = wrap_text("你好世界你好世界", 5)
  assert_eq(lines.length(), 4)
  for line in lines {
    assert_true(display_width(line) <= 5)
  }
  assert_eq(lines[0], "你好")
}

///|
test "wrap_text 优先在空格处断词" {
  let lines = wrap_text("hello world foo bar", 10)
  assert_eq(lines.length(), 3)
  assert_eq(lines[0], "hello")
  assert_eq(lines[1], "world foo")
  assert_eq(lines[2], "bar")
}

///|
test "wrap_text 保留显式换行（工具输出的行结构有意义）" {
  let lines = wrap_text("a\nb", 80)
  assert_eq(lines.length(), 2)
  assert_eq(lines[1], "b")
}

///|
test "wrap_prefixed 后续行按前缀宽度缩进" {
  let lines = wrap_prefixed("› ", "abcdefgh", 6)
  assert_eq(lines[0], "› abcd")
  assert_eq(lines[1], "  efgh")
}

///|
test "insert_text 的光标是字符下标，不是字节下标" {
  let (text, cursor) = insert_text("你好", 1, "世界")
  assert_eq(text, "你世界好")
  assert_eq(cursor, 3)
}

///|
test "退格与 Delete 在两端不越界" {
  let (text, cursor) = backspace("", 0)
  assert_eq(text, "")
  assert_eq(cursor, 0)
  let (text, cursor) = delete_forward("abc", 3)
  assert_eq(text, "abc")
  assert_eq(cursor, 3)
  let (text, _) = backspace("abc", 2)
  assert_eq(text, "ac")
}

///|
test "render_editor 在窄窗口里保证光标可见" {
  let rendered = render_editor("abcdefghij", 10, 5)
  assert_true(rendered.contains("▌"))
  assert_true(display_width(rendered) <= 5)
  assert_true(rendered.contains("j"))
  // 光标在中间时不把左边的字全裁掉（起点只让位给光标本身）。
  let middle = render_editor("abcdefghij", 1, 5)
  assert_true(middle.contains("a"))
}

///|
test "visible_lines 默认贴底，scroll 往上翻" {
  let lines : Array[StyledLine] = []
  for index in 0..<10 {
    lines.push(plain_line("line" + index.to_string()))
  }
  let bottom = visible_lines(lines, 3, 0)
  assert_eq(bottom[0].text, "line7")
  assert_eq(bottom[2].text, "line9")
  let scrolled = visible_lines(lines, 3, 2)
  assert_eq(scrolled[0].text, "line5")
  // 滚过头也只到顶。
  let top = visible_lines(lines, 3, 999)
  assert_eq(top[0].text, "line0")
}

///|
test "chat_lines：工具块折叠与展开" {
  let call : @message.ToolCall = { id: "c1", name: "read", arguments: "{}", }
  let state = {
    ..test_state(),
    messages: [
      @message.user_message("看一下", 1L),
      @message.tool_result_message(
        call, "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9", false, 2L,
      ),
    ],
  }
  let collapsed = chat_lines(state, false, 60, "")
  let mut collapsed_text = ""
  for line in collapsed {
    collapsed_text = collapsed_text + line.text + "\n"
  }
  assert_true(collapsed_text.contains("还有 3 行"))
  assert_true(collapsed_text.contains("看一下"))
  let expanded = chat_lines(state, true, 60, "")
  let mut expanded_text = ""
  for line in expanded {
    expanded_text = expanded_text + line.text + "\n"
  }
  assert_true(expanded_text.contains("l9"))
  assert_false(expanded_text.contains("还有 3 行"))
}

///|
test "chat_lines：流式文本与思考各占一段" {
  let state = {
    ..test_state(),
    phase: @common.Thinking,
    streaming_text: "正在说",
    thinking_text: "想一下",
  }
  let lines = chat_lines(state, false, 60, "")
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("想一下"))
  assert_true(text.contains("正在说▌"))
}

///|
/// 模拟用户敲字：`read_key` 一次只给一个键，测试里也别整段塞。
fn type_text(tui : TuiState, text : String) -> Unit {
  for c in text {
    handle_key(tui, c.to_string())
  }
}

///|
test "键位：Enter 提交、斜杠命令、Esc 两种语义" {
  let tui = TuiState::new()
  type_text(tui, "hello")
  handle_key(tui, "\r")
  assert_eq(tui.commands.length(), 1)
  match tui.commands[0] {
    Submit(text) => assert_eq(text, "hello")
    _ => abort("expected submit")
  }
  assert_eq(tui.history.length(), 1)
  assert_eq(tui.input, "")

  type_text(tui, "/compact")
  handle_key(tui, "\r")
  match tui.commands[1] {
    Compact => ()
    _ => abort("expected compact")
  }

  // 空闲时 Esc 不是直接清输入，而是请求取回排队消息（driver / on_tick 去读队列）。
  type_text(tui, "abc")
  handle_key(tui, "\u{001b}")
  assert_true(tui.take_back)
  assert_eq(tui.input, "abc")
  assert_false(tui.abort)

  // 生成中 Esc = 中断。
  tui.busy = true
  handle_key(tui, "\u{001b}")
  assert_true(tui.abort)
}

///|
test "键位：Ctrl+C 第一次提示、第二次退出" {
  let tui = TuiState::new()
  handle_key(tui, "\u{0003}")
  assert_false(tui.quit)
  assert_true(tui.notice.contains("Ctrl+C"))
  handle_key(tui, "\u{0003}")
  assert_true(tui.quit)
}

///|
test "键位：生成中 Enter = steer，Alt+Enter = followUp" {
  let tui = TuiState::new()
  tui.busy = true
  type_text(tui, "排队一句")
  handle_key(tui, "\r")
  assert_eq(tui.commands.length(), 0)
  assert_eq(tui.pending_actions.length(), 1)
  assert_eq(tui.notice, "")
  match tui.pending_actions[0] {
    @action.QueueInput(input) => {
      assert_eq(input.text, "排队一句")
      assert_eq(input.kind, @common.Steer)
    }
    _ => abort("expected queue.input")
  }
  // Alt+Enter（ESC + CR）走 followUp 队列。
  type_text(tui, "待会儿再说")
  handle_key(tui, "\u{001b}\r")
  assert_eq(tui.pending_actions.length(), 2)
  match tui.pending_actions[1] {
    @action.QueueInput(input) => assert_eq(input.kind, @common.FollowUp)
    _ => abort("expected followUp queue.input")
  }
}

///|
test "键位：Ctrl+U 请求取回排队消息" {
  let tui = TuiState::new()
  handle_key(tui, "\u{0015}")
  assert_true(tui.take_back)
}

///|
test "队列面板：只在有排队时占行，形状与 ela 一致" {
  let empty = queue_lines(test_state(), 80)
  assert_eq(empty.length(), 0)
  let queued = {
    ..test_state(),
    follow_up_queue: [{ text: "待会儿再说", content: [], at: 1L, }],
    steer_queue: [{ text: "顺便看下版本", content: [], at: 2L, }],
  }
  let lines = queue_lines(queued, 80)
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("Steering: 顺便看下版本"))
  assert_true(text.contains("Follow-up: 待会儿再说"))
  assert_true(text.contains("Ctrl+U"))
}

///|
test "键位：上下翻历史" {
  let tui = TuiState::new()
  type_text(tui, "first")
  handle_key(tui, "\r")
  type_text(tui, "second")
  handle_key(tui, "\r")
  handle_key(tui, "\u{001b}[A")
  assert_eq(tui.input, "second")
  handle_key(tui, "\u{001b}[A")
  assert_eq(tui.input, "first")
  handle_key(tui, "\u{001b}[B")
  assert_eq(tui.input, "second")
}

///|
test "顶行是页签 + 统计，底栏是 cwd + 用量/模型" {
  let state = {
    ..test_state(),
    messages: [@message.assistant_message("hi", "stop", 1L)],
  }
  let tab = tab_nodes(state, Chat, 100)
  assert_true(tab.length() > 3)
  let footer = footer_lines(state, 100)
  assert_eq(footer.length(), 2)
  assert_eq(display_width(footer[0].text), 100)
  assert_true(footer[1].text.contains("(deepseek) deepseek-chat"))
  assert_eq(display_width(footer[1].text), 100)
}

///|
test "tui_view 能画出一整帧（顶行 / 对话区 / composer / 底栏）" {
  let tui = TuiState::new()
  tui.width = 80
  tui.height = 24
  let state = {
    ..test_state(),
    messages: [@message.user_message("你好，画一帧", 1L)],
  }
  let frame = @vnode.render_vnode_once(80, 24, tui_view(tui, state))
  assert_true(frame.contains("deepseek"))
  assert_true(frame.contains("你好，画一帧"))
  assert_true(frame.contains("对话"))
  assert_true(frame.contains("轨迹"))
}
