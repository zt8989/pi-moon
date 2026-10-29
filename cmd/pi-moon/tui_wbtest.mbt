// TUI 的纯逻辑测试：折行、输入编辑、可见窗口、键位与命令解析。
//
// 交互本身（raw mode、流式重绘）要在真终端里看；这里锁住的是「算错会很难
// 归因」的那几处：CJK 折行、光标不走字节、翻页越界、Esc 的两种语义。

///|
fn test_agent(state : @state.AgentState) -> @runtime.Agent {
  @runtime.Agent::new(state, @runtime.noop_effect_table(), fn() { 0L })
}

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
  assert_true(rendered.contains("█"))
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
test "chat_lines：工具块折叠与展开（read 折叠时只留标题，pi 同款）" {
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
  let collapsed = chat_lines(state, false, 60, [], [])
  let mut collapsed_text = ""
  for line in collapsed {
    collapsed_text = collapsed_text + line.text + "\n"
  }
  assert_true(collapsed_text.contains("read"))
  assert_false(collapsed_text.contains("l1\n"))
  assert_true(collapsed_text.contains("还有 9 行"))
  let expanded = chat_lines(state, true, 60, [], [])
  let mut expanded_text = ""
  for line in expanded {
    expanded_text = expanded_text + line.text + "\n"
  }
  assert_true(expanded_text.contains("l9"))
  assert_false(expanded_text.contains("还有 9 行"))
}

///|
test "chat_lines：流式文本与思考各占一段" {
  let state = {
    ..test_state(),
    phase: @common.Thinking,
    streaming_text: "正在说",
    thinking_text: "想一下",
  }
  let lines = chat_lines(state, false, 60, [], [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_true(text.contains("想一下"))
  assert_true(text.contains("正在说█"))
}

///|
/// 最后一张反馈卡的文本（没有卡就是空串）。
fn last_card_text(tui : TuiState) -> String {
  if tui.cards.is_empty() {
    ""
  } else {
    tui.cards[tui.cards.length() - 1].text
  }
}

///|
/// 模拟用户敲字：`read_key` 一次只给一个键，测试里也别整段塞。
fn type_text(agent : @runtime.Agent, tui : TuiState, text : String) -> Unit {
  for c in text {
    handle_key(agent, tui, c.to_string())
  }
}

///|
test "键位：Enter 提交、斜杠命令、Esc 两种语义" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  type_text(agent, tui, "hello")
  handle_key(agent, tui, "\r")
  assert_eq(tui.commands.length(), 1)
  match tui.commands[0] {
    Submit(text) => assert_eq(text, "hello")
    _ => abort("expected submit")
  }
  assert_eq(tui.history.length(), 1)
  assert_eq(tui.input, "")

  type_text(agent, tui, "/compact")
  handle_key(agent, tui, "\r")
  match tui.commands[1] {
    Compact => ()
    _ => abort("expected compact")
  }

  // 空闲时 Esc 不是直接清输入，而是请求取回排队消息（driver / on_tick 去读队列）。
  type_text(agent, tui, "abc")
  handle_key(agent, tui, "\u{001b}")
  assert_true(tui.take_back)
  assert_eq(tui.input, "abc")
  assert_false(tui.abort)

  // 生成中 Esc = 中断。
  tui.busy = true
  handle_key(agent, tui, "\u{001b}")
  assert_true(tui.abort)
}

///|
test "键位：Ctrl+C 第一次提示、第二次退出" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  handle_key(agent, tui, "\u{0003}")
  assert_false(tui.quit)
  assert_true(last_card_text(tui).contains("Ctrl+C"))
  handle_key(agent, tui, "\u{0003}")
  assert_true(tui.quit)
}

///|
test "键位：生成中 Enter = steer，Alt+Enter = followUp" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  tui.busy = true
  type_text(agent, tui, "排队一句")
  handle_key(agent, tui, "\r")
  assert_eq(tui.commands.length(), 0)
  assert_eq(tui.pending_actions.length(), 1)
  assert_eq(tui.cards.length(), 0)
  match tui.pending_actions[0] {
    @action.QueueInput(input) => {
      assert_eq(input.text, "排队一句")
      assert_eq(input.kind, @common.Steer)
    }
    _ => abort("expected queue.input")
  }
  // Alt+Enter（ESC + CR）走 followUp 队列。
  type_text(agent, tui, "待会儿再说")
  handle_key(agent, tui, "\u{001b}\r")
  assert_eq(tui.pending_actions.length(), 2)
  match tui.pending_actions[1] {
    @action.QueueInput(input) => assert_eq(input.kind, @common.FollowUp)
    _ => abort("expected followUp queue.input")
  }
}

///|
test "键位：Ctrl+U 请求取回排队消息" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  handle_key(agent, tui, "\u{0015}")
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
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  type_text(agent, tui, "first")
  handle_key(agent, tui, "\r")
  type_text(agent, tui, "second")
  handle_key(agent, tui, "\r")
  handle_key(agent, tui, "\u{001b}[A")
  assert_eq(tui.input, "second")
  handle_key(agent, tui, "\u{001b}[A")
  assert_eq(tui.input, "first")
  handle_key(agent, tui, "\u{001b}[B")
  assert_eq(tui.input, "second")
}

///|
test "顶行是页签 + 统计，底栏是 cwd + 用量/模型" {
  let state = {
    ..test_state(),
    messages: [@message.assistant_message("hi", "stop", 1L)],
  }
  let tab = tab_nodes(state, @action.UiChat, 100)
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

///|
fn test_model(
  id : String,
  reasoning : Bool,
  disabled : Array[String],
) -> @provider.PiModelInfo {
  let levels : Map[String, String?] = Map([])
  for level in disabled {
    levels[level] = None
  }
  {
    id,
    name: id,
    api: "openai-completions",
    base_url: None,
    reasoning,
    context_window: 1000,
    max_tokens: None,
    thinking_level_map: levels,
    cost_input: 0.0,
    cost_output: 0.0,
    compat: @provider.default_compat,
  }
}

///|
fn test_pi_config() -> @provider.PiConfig {
  {
    providers: [
      {
        name: "demo",
        base_url: "http://localhost/v1",
        api: "openai-completions",
        api_key: None,
        models: [
          test_model("demo-1", true, ["xhigh"]),
          test_model("plain", false, []),
        ],
      },
    ],
    default_provider: Some("demo"),
    default_model: Some("demo-1"),
    default_thinking_level: "off",
    default_tools: None,
    compaction: @compact.default_settings(),
    auth: Map([]),
    env: Map([]),
    agent_dir: "/tmp/pi",
    diagnostics: [],
  }
}

///|
test "面板：Ctrl+L 打开模型列表，上下移动、Enter 确认、Esc 取消" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  let state = test_state()
  let config = test_pi_config()
  // Ctrl+L 在按键层只排队；driver 打开面板。
  handle_key(agent, tui, "\u{000c}")
  match tui.commands[0] {
    OpenModels => ()
    _ => abort("expected open-models command")
  }
  open_model_picker(agent, tui, config)
  let picker = agent.state.ui.picker.unwrap()
  assert_eq(picker.kind, @action.ModelPicker)
  assert_eq(picker.items.length(), 2)
  assert_eq(picker.selected, 0)
  handle_key(agent, tui, "\u{001b}[B")
  assert_eq(agent.state.ui.picker.unwrap().selected, 1)
  handle_key(agent, tui, "\r")
  assert_true(tui.picker_confirm)
  // Esc 关面板；确认标志留着也没关系（driver 会清）。
  handle_key(agent, tui, "\u{001b}")
  assert_true(agent.state.ui.picker is None)
  // 重开一次，检查列表渲染。
  tui.picker_confirm = false
  open_model_picker(agent, tui, config)
  let rows = picker_rows(tui, agent.state, 80, 30)
  let mut text = ""
  for row in rows {
    text = text + row.text + "\n"
  }
  assert_true(text.contains("选择模型"))
  assert_true(text.contains("demo / plain"))
}

///|
test "面板：思考级别只列模型支持的档位" {
  let state = {
    ..test_state(),
    provider_name: "demo",
    model_id: "demo-1",
    thinking_level: "high",
    model: {
      ..test_state().model,
      provider: "demo",
      model_id: "demo-1",
      thinking_level: "high",
      reasoning: true,
      context_window: 1000,
    },
  }
  let agent = test_agent(state)
  let tui = TuiState::new()
  open_thinking_picker(agent, tui, test_pi_config())
  let picker = agent.state.ui.picker.unwrap()
  assert_eq(picker.kind, @action.ThinkingPicker)
  assert_eq(picker.items.length(), 6)
  let mut levels = ""
  for item in picker.items {
    levels = levels + item.level + ","
  }
  assert_false(levels.contains("xhigh"))
  assert_eq(picker.items[picker.selected].level, "high")
  // 不支持的模型：不开面板，只给一句通知。
  let plain = {
    ..state,
    model_id: "plain",
    model: { ..state.model, model_id: "plain", reasoning: false, },
  }
  let agent2 = test_agent(plain)
  let tui2 = TuiState::new()
  open_thinking_picker(agent2, tui2, test_pi_config())
  assert_true(agent2.state.ui.picker is None)
  assert_true(last_card_text(tui2).contains("不支持"))
}

///|
test "面板：换模型时思考级别按新模型夹紧" {
  let config = test_pi_config()
  assert_eq(clamp_thinking(config, "demo", "plain", "high"), "off")
  assert_eq(clamp_thinking(config, "demo", "demo-1", "xhigh"), "off")
  assert_eq(clamp_thinking(config, "demo", "demo-1", "high"), "high")
}

///|
test "斜杠命令：/model 与 /thinking [级别]" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  type_text(agent, tui, "/model")
  handle_key(agent, tui, "\r")
  match tui.commands[0] {
    OpenModels => ()
    _ => abort("expected open-models")
  }
  type_text(agent, tui, "/thinking high")
  handle_key(agent, tui, "\r")
  match tui.commands[1] {
    ThinkingLevel(level) => assert_eq(level, "high")
    _ => abort("expected thinking-level")
  }
}

///|
test "时间与会话大小的人话格式" {
  assert_eq(relative_time(1000L, 1030L), "刚刚")
  assert_eq(relative_time(1000L, 1000L + 120L), "2 分钟前")
  assert_eq(relative_time(1000L, 1000L + 7200L), "2 小时前")
  assert_eq(relative_time(1000L, 1000L + 172800L), "2 天前")
  assert_eq(size_text(512L), "512 B")
  assert_eq(size_text(2048L), "2 KB")
  assert_eq(size_text(3L * 1024L * 1024L), "3 MB")
}

///|
test "斜杠命令：/resume 开会话面板" {
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  type_text(agent, tui, "/resume")
  handle_key(agent, tui, "\r")
  match tui.commands[0] {
    OpenSessions => ()
    _ => abort("expected open-sessions")
  }
}

///|
async test "会话面板：列出 sessions 目录，新的在前，当前会话打点" {
  let root = @sys.tmpdir("pi-moon-tui-sessions-")
  let dir = root + "/sessions/--C--test--"
  @sys.mkdir_p(dir) catch {
    _ => abort("mkdir sessions failed")
  }
  let path_old = dir + "/1000.jsonl"
  let path_new = dir + "/2000.jsonl"
  let message_state = {
    ..test_state(),
    messages: [@message.user_message("旧会话", 1L)],
  }
  let (_, _) = @session.SessionWriter::new(
    path_old,
    path_old + ".trace",
    "s-old",
  ).flush(message_state) catch {
    _ => abort("write old session failed")
  }
  // mtime 的分辨率到秒；等一秒才能保证「新的在前」稳定。
  @async.sleep(1100)
  let newer_state = {
    ..test_state(),
    messages: [@message.user_message("新会话", 2L)],
  }
  let (_, _) = @session.SessionWriter::new(
    path_new,
    path_new + ".trace",
    "s-new",
  ).flush(newer_state) catch {
    _ => abort("write new session failed")
  }
  let config = { ..test_pi_config(), agent_dir: root, }
  let agent = test_agent(test_state())
  let tui = TuiState::new()
  tui.session_path = path_old
  open_session_picker(agent, tui, config, "C:/test")
  match agent.state.ui.picker {
    Some(picker) => {
      assert_eq(picker.kind, @action.SessionPicker)
      assert_eq(picker.items.length(), 2)
      assert_true(picker.items[0].path.has_suffix("2000.jsonl"))
      assert_eq(picker.items[0].label, "刚刚")
      assert_eq(picker.items[picker.selected].path, path_old)
    }
    None => abort("picker not opened")
  }
  @sys.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "反馈卡钉在创建时的消息位置，同位置就地替换" {
  let tui = TuiState::new()
  tui.message_count = 1
  set_notice(tui, "第一条提示")
  tui.message_count = 3
  set_notice(tui, "第二条提示")
  assert_eq(tui.cards.length(), 2)
  // 尾部还在同一位置 → 替换，不新开一张。
  set_notice(tui, "第二条提示（改）")
  assert_eq(tui.cards.length(), 2)
  assert_eq(tui.cards[1].text, "第二条提示（改）")
  // 渲染位置：第 1 张在第 1 条消息后，第 2 张在第 3 条消息后。
  let state = {
    ..test_state(),
    messages: [
      @message.user_message("甲", 1L),
      @message.assistant_message("乙", "stop", 2L),
      @message.user_message("丙", 3L),
    ],
  }
  let lines = chat_lines(state, false, 60, tui.cards, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  let first = match text.find("第一条提示") {
    Some(index) => index
    None => abort("first card missing")
  }
  let second = match text.find("第二条提示") {
    Some(index) => index
    None => abort("second card missing")
  }
  let jia = match text.find("甲") {
    Some(index) => index
    None => abort("first message missing")
  }
  let bing = match text.find("丙") {
    Some(index) => index
    None => abort("third message missing")
  }
  assert_true(jia < first)
  assert_true(first < second)
  assert_true(bing < second)
}

///|
/// 一段文本里出现 needle 的次数（反馈卡不能被画两遍）。
fn occurrences(text : String, needle : String) -> Int32 {
  text.split(needle).collect().length() - 1
}

///|
test "反馈卡不会因为「锚点等于消息数」被画两遍" {
  // 没有消息时，卡锚定在 0：消息循环里画一次，兜底不能再画。
  let tui = TuiState::new()
  tui.message_count = 0
  set_notice(tui, "空的会话也有一张卡")
  let empty = chat_lines(test_state(), false, 60, tui.cards, [])
  let mut empty_text = ""
  for line in empty {
    empty_text = empty_text + line.text + "\n"
  }
  assert_eq(occurrences(empty_text, "空的会话也有一张卡"), 1)
  // 有消息时，锚点等于消息数（卡在最后一条消息之后）也只画一次。
  let state = { ..test_state(), messages: [@message.user_message("甲", 1L)], }
  tui.message_count = 1
  set_notice(tui, "最后一条之后")
  let lines = chat_lines(state, false, 60, tui.cards, [])
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  assert_eq(occurrences(text, "最后一条之后"), 1)
}

///|
fn spans_of(line : StyledLine) -> Array[MarkdownSpan] {
  match line.spans {
    Some(spans) => spans
    None => []
  }
}

///|
fn line_texts(lines : Array[StyledLine]) -> String {
  let mut text = ""
  for line in lines {
    text = text + line.text + "\n"
  }
  text
}

///|
test "markdown：标题去井号、列表换圆点" {
  let lines = markdown_lines("## 小标题\n\n- 一项\n- 二项", 40)
  let text = line_texts(lines)
  assert_false(text.contains("##"))
  assert_true(text.contains("小标题"))
  assert_true(text.contains("• 一项"))
  // 标题整行加粗。
  let heading = lines[0]
  for span in spans_of(heading) {
    assert_true(span.bold)
  }
}

///|
test "markdown：行内 code / 粗体 / 链接各带自己的样式" {
  let lines = markdown_lines(
    "`code` 和 **粗体** 以及 [链接](https://example.com)", 60,
  )
  let mut found_code = false
  let mut found_bold = false
  let mut found_link = false
  let mut found_url = false
  for line in lines {
    for span in spans_of(line) {
      if span.text == "code" && span.fg == Some("rgb(167,152,215)") {
        found_code = true
      }
      if span.text == "粗体" && span.bold {
        found_bold = true
      }
      if span.text == "链接" && span.fg == Some("rgb(105,173,208)") {
        found_link = true
      }
      if span.text.contains("https://example.com") {
        found_url = true
      }
    }
  }
  assert_true(found_code)
  assert_true(found_bold)
  assert_true(found_link)
  assert_true(found_url)
}

///|
test "markdown：围栏代码保留标记、内容用代码色" {
  let lines = markdown_lines("```\nlet x = 1\n```", 40)
  assert_true(lines[0].text.contains("```"))
  let mut found = false
  for line in lines {
    if line.text.contains("let x = 1") {
      found = true
      assert_eq(line.fg, Some("rgb(104,183,141)"))
    }
  }
  assert_true(found)
}

///|
test "markdown：带样式的行按显示宽度折行，样式不丢" {
  let lines = markdown_lines(
    "`aaaaaaaaaaaaaaaaaaaa` bbbbbbbbbbbbbbbbbbbb cccccccccccccccccccc", 12,
  )
  assert_true(lines.length() > 1)
  for line in lines {
    assert_true(display_width(line.text) <= 12)
  }
  let mut has_code = false
  for span in spans_of(lines[0]) {
    if span.fg == Some("rgb(167,152,215)") {
      has_code = true
    }
  }
  assert_true(has_code)
}

///|
test "markdown：用户块整段铺底色，首尾各一条空白底色行" {
  let state = {
    ..test_state(),
    messages: [@message.user_message("# 标题\n正文", 1L)],
  }
  let lines = chat_lines(state, false, 40, [], [])
  let mut bg_count = 0
  let mut found_heading = false
  let mut found_body = false
  for line in lines {
    if line.bg == Some("blue") {
      bg_count = bg_count + 1
    }
    if line.text.contains("标题") && !line.text.contains("#") {
      found_heading = true
    }
    if line.text.contains("正文") {
      found_body = true
    }
  }
  assert_true(found_heading)
  assert_true(found_body)
  // 顶/底空白 + 两行内容。
  assert_eq(bg_count, 4)
}

///|
test "markdown：有序列表、嵌套列表与任务列表" {
  let lines = markdown_lines(
    "1. 第一\n   - 子项\n2. 第二\n\n- [x] 完成\n- [ ] 未完成", 40,
  )
  let text = line_texts(lines)
  assert_true(text.contains("1. 第一"))
  assert_true(text.contains("2. 第二"))
  // 嵌套项的缩进 = 外层标记宽度，叠出来的层级才看得见。
  assert_true(text.contains("   • 子项"))
  assert_true(text.contains("☑ 完成"))
  assert_true(text.contains("☐ 未完成"))
}

///|
test "markdown：表格按列宽对齐，分隔线用 ─ 与 ┼" {
  let lines = markdown_lines(
    "| 名 | 值 |\n| --- | ---: |\n| a | 1 |\n| longer | 22 |", 40,
  )
  assert_true(lines.length() >= 4)
  assert_true(lines[0].text.contains("名"))
  assert_true(lines[1].text.contains("┼"))
  assert_true(lines[3].text.contains("longer"))
  // 右对齐列：个位数也贴着右边界。
  assert_true(lines[2].text.has_suffix("1"))
  for line in lines {
    assert_true(display_width(line.text) <= 40)
  }
}

///|
test "markdown：引用带灰竖线前缀" {
  let lines = markdown_lines("> 引用一行", 20)
  assert_eq(lines[0].text, "│ 引用一行")
  let mut muted_prefix = false
  for span in spans_of(lines[0]) {
    if span.text == "│ " && span.fg == Some("rgb(157,165,169)") {
      muted_prefix = true
    }
  }
  assert_true(muted_prefix)
}

///|
test "markdown：```diff 按行上色（增 / 删 / 区块头）" {
  let lines = markdown_lines(
    "```diff\n@@ -1 +1 @@\n- 旧\n+ 新\n 原样\n```", 40,
  )
  let mut added = false
  let mut removed = false
  let mut hunk = false
  for line in lines {
    if line.text.contains("+ 新") {
      added = true
      assert_eq(line.fg, Some("rgb(104,183,141)"))
    }
    if line.text.contains("- 旧") {
      removed = true
      assert_eq(line.fg, Some("rgb(234,127,129)"))
    }
    if line.text.contains("@@") {
      hunk = true
      assert_eq(line.fg, Some("rgb(105,173,208)"))
    }
  }
  assert_true(added)
  assert_true(removed)
  assert_true(hunk)
}

///|
test "markdown：硬换行断行、实体解码" {
  let lines = markdown_lines("a &amp; b  \nc", 40)
  assert_eq(lines.length(), 2)
  assert_eq(lines[0].text, "a & b")
  assert_eq(lines[1].text, "c")
}

///|
test "markdown：引用式链接能解析出地址，定义本身不画" {
  let lines = markdown_lines("[文档][d]\n\n[d]: https://example.com/doc", 60)
  let text = line_texts(lines)
  assert_true(text.contains("文档"))
  assert_true(text.contains("https://example.com/doc"))
  assert_false(text.contains("[d]:"))
}

///|
test "markdown：空串得到一个空行，窄宽度不炸" {
  let empty = markdown_lines("", 40)
  assert_eq(empty.length(), 1)
  assert_eq(empty[0].text, "")
  let narrow = markdown_lines("`aaaaaaaa` bbbbbbbb", 3)
  assert_true(narrow.length() > 0)
  for line in narrow {
    assert_true(display_width(line.text) <= 3)
  }
}

///|
test "markdown：没有围栏标记的正文不会被当成代码" {
  let lines = markdown_lines("#hashtag 保持原样\n\n正文 `x` 结束", 40)
  assert_true(lines[0].text.contains("#hashtag"))
  let mut inline_code = false
  for line in lines {
    for span in spans_of(line) {
      if span.text == "x" && span.fg == Some("rgb(167,152,215)") {
        inline_code = true
      }
    }
  }
  assert_true(inline_code)
}

///|
test "颜色：COLORTERM / TERM 广告 24-bit 时用 TrueColor" {
  assert_true(
    color_mode_from_env("xterm-256color", "truecolor", "", "", "", "").is_true_color(),
  )
  assert_true(
    color_mode_from_env("xterm-direct", "", "", "", "", "").is_true_color(),
  )
}

///|
test "颜色：Windows Terminal / VS Code / ConEmu 也算 24-bit" {
  assert_true(
    color_mode_from_env("", "", "6f1a-...", "", "", "").is_true_color(),
  )
  assert_true(
    color_mode_from_env("", "", "", "Windows_Terminal", "", "").is_true_color(),
  )
  assert_true(color_mode_from_env("", "", "", "vscode", "", "").is_true_color())
  assert_true(color_mode_from_env("", "", "", "", "ON", "").is_true_color())
  // 什么都不广告 → 退回 256 色（宁可量化，也别把底色送成默认色）。
  assert_false(
    color_mode_from_env("xterm-256color", "", "", "", "", "").is_true_color(),
  )
  assert_false(color_mode_from_env("", "", "", "", "", "").is_true_color())
}

///|
test "颜色：24-bit 终端用 pi dark 主题的原值，256 色退回 16 色名字" {
  let true_color = Palette::true_color()
  assert_eq(true_color.user_bg, "rgb(33,59,73)")
  assert_eq(true_color.tool_success_bg, "rgb(37,65,49)")
  assert_eq(true_color.tool_error_bg, "rgb(91,40,42)")
  assert_eq(true_color.tool_pending_bg, "rgb(52,56,58)")
  let ansi = Palette::ansi256()
  assert_eq(ansi.user_bg, "blue")
  assert_eq(ansi.tool_success_bg, "green")
}

///|
test "颜色：对话页的底色跟着调色板走" {
  let call : @message.ToolCall = { id: "c1", name: "read", arguments: "{}", }
  let state = {
    ..test_state(),
    messages: [
      @message.user_message("你好", 1L),
      @message.tool_result_message(call, "ok", false, 2L),
    ],
  }
  let fallback = chat_lines(state, false, 60, [], [])
  assert_true(fallback.any(fn(line) { line.bg == Some("blue") }))
  let true_color = chat_lines(
    state,
    false,
    60,
    [],
    [],
    palette=Palette::true_color(),
  )
  assert_true(true_color.any(fn(line) { line.bg == Some("rgb(33,59,73)") }))
  // 找不到调用的孤儿结果块：成功底色走 pi 的深绿。
  assert_true(true_color.any(fn(line) { line.bg == Some("rgb(37,65,49)") }))
}

///|
test "颜色：TrueColor 下整帧真的发出 48;2 序列，256 色下不发" {
  let state = {
    ..test_state(),
    messages: [@message.user_message("你好", 1L)],
  }
  let tui = {
    ..TuiState::new(),
    width: 80,
    height: 24,
    palette: Palette::true_color(),
  }
  let node = tui_view(tui, state)
  let true_color = @vnode.render_vnode_once(
    80,
    24,
    node,
    color_mode=@render.ColorMode::TrueColor,
  )
  assert_true(true_color.contains("48;2;33;59;73"))
  let fallback = @vnode.render_vnode_once(80, 24, node)
  assert_false(fallback.contains("48;2;33;59;73"))
  // 256 色退路：底色走调色板（48;5;n），不是 24-bit 的 48;2。
  assert_true(fallback.contains("48;5;"))
  assert_false(fallback.contains("48;2;"))
}

///|
test "chat_lines：启动横幅画在对话页顶部，标题黄、内容灰" {
  let palette = Palette::ansi256()
  let banner : Array[String] = ["[Context] AGENTS.md", "[Skills] demo, other"]
  let lines = chat_lines(test_state(), false, 60, [], banner, palette~)
  // 横幅在最前面：第 0 行是 [Context] 标题，第 1 行是内容。
  let mut joined = ""
  for line in lines {
    joined = joined + line.text + "|"
  }
  assert_true(joined.contains(" [Context]|   AGENTS.md|"))
  // 空横幅时不占任何行：无消息无卡片时什么都不画。
  let bare = chat_lines(test_state(), false, 60, [], [], palette~)
  assert_true(bare.is_empty())
}

///|
test "帧成本量化：多条消息的对话区全量重算耗时" {
  let body = "# 标题\n\n一段**加粗**与`行内代码`、[链接](https://example.com)。\n\n- 列表项一\n- 列表项二\n- 列表项三\n\n```moonbit\nfn main() { println(\"hi\") }\n```\n\n再一段正文,足够长到需要折行的程度,看看折行与样式的开销大概在一个什么量级上。"
  let messages : Array[@message.Message] = []
  for index in 0..<20 {
    if index % 2 == 0 {
      messages.push(@message.user_message(body, index.to_int64()))
    } else {
      messages.push(@message.assistant_message("assistant \{index} 的回答正文,也带一点**markdown**与 `code`。", "stop", index.to_int64()))
    }
  }
  let state = {
    ..test_state(),
    messages,
    phase: @common.Thinking,
    streaming_text: "正在流式输出的文本,长度中等,模拟生成中的状态。",
  }
  let tui = TuiState::new()
  tui.width = 100
  tui.height = 30
  let start = @sys.now()
  let runs = 20L
  for _ in 0..<20 {
    let _node = tui_view(tui, state)
  }
  let cost = @sys.now() - start
  println("tui_view x\{runs} (20 msgs) = \{cost}ms, per-frame \{cost / runs}ms")
  assert_true(cost >= 0L)
}

///|
test "markdown：流式半截闭合围栏被剪掉" {
  // 闭合 ``` 逐字符到达时，末尾先出现 `` —— 应该剪掉，代码块先按
  // 「未闭合」渲染，等下一帧闭合行到齐再恢复。
  assert_eq(
    trim_partial_closing_fence("```rust\nlet x = 1\n``"),
    "```rust\nlet x = 1",
  )
  // 三个字符凑齐就是真闭合，不剪。
  assert_eq(
    trim_partial_closing_fence("```rust\nlet x = 1\n```"),
    "```rust\nlet x = 1\n```",
  )
  // 半截行不带换行的情况（delta 正好停在围栏字符中间）。
  assert_eq(trim_partial_closing_fence("```\ncode\n`"), "```\ncode")
  // ~~~ 围栏同样处理。
  assert_eq(trim_partial_closing_fence("~~~\ncode\n~~"), "~~~\ncode")
  // 闭合之后的内容不属于围栏，末行是普通文字时不动。
  assert_eq(
    trim_partial_closing_fence("```\ncode\n```\n正文"),
    "```\ncode\n```\n正文",
  )
  // 完整文本（无未闭合围栏）是恒等变换。
  assert_eq(
    trim_partial_closing_fence("# 标题\n\n正文 **粗体**。"),
    "# 标题\n\n正文 **粗体**。",
  )
}

///|
test "markdown：流式正文走 markdown 渲染且末行带光标" {
  let tui = TuiState::new()
  tui.width = 80
  tui.height = 24
  let state = {
    ..test_state(),
    phase: @common.Thinking,
    streaming_text: "正文段落，带 **粗体**。",
  }
  let frame = @vnode.render_vnode_once(80, 24, tui_view(tui, state))
  // 纯文本渲染会保留 "**"；走 markdown 渲染后只剩粗体样式，字面星号消失。
  assert_false(frame.contains("**"))
  assert_true(frame.contains("正文段落"))
  // 假光标接在最后一行行尾。
  assert_true(frame.contains("█"))
}

///|
test "markdown：相同 (text, width, colors) 命中缓存" {
  let colors = MarkdownColors::defaults()
  markdown_cache.clear()
  let first = markdown_lines("## 缓存标题\n\n- 一项", 40, colors~)
  let size_after_first = markdown_cache.length()
  let second = markdown_lines("## 缓存标题\n\n- 一项", 40, colors~)
  // 命中：不再新增条目，内容一致。
  assert_eq(markdown_cache.length(), size_after_first)
  assert_eq(first.length(), second.length())
  assert_eq(first[0].text, second[0].text)
  // 宽度或颜色变化是不同的 key。
  let _ = markdown_lines("## 缓存标题\n\n- 一项", 60, colors~)
  let other_colors = { ..colors, heading: "#123456" }
  let _ = markdown_lines("## 缓存标题\n\n- 一项", 40, colors=other_colors)
  assert_eq(markdown_cache.length(), size_after_first + 2)
}

///|
test "markdown：缓存超上限按插入序淘汰" {
  markdown_cache.clear()
  let colors = MarkdownColors::defaults()
  for i in 0..<markdown_cache_capacity {
    let _ = markdown_lines("淘汰测试 \{i}", 40, colors~)
  }
  assert_eq(markdown_cache.length(), markdown_cache_capacity)
  // 再插一条：总量封顶，最老的 "淘汰测试 0" 被挤出去。
  let _ = markdown_lines("淘汰测试 溢出", 40, colors~)
  assert_eq(markdown_cache.length(), markdown_cache_capacity)
  // 被淘汰的 key 再查会重算，结果仍然正确。
  let lines = markdown_lines("淘汰测试 0", 40, colors~)
  assert_true(lines[0].text.contains("淘汰测试 0"))
  assert_eq(markdown_cache.length(), markdown_cache_capacity)
}

///|
test "build_banner：四段顺序、字典序、段间空行（pi 的启动画面同形）" {
  let files : Array[@context.ContextFile] = [
    { path: "/tmp/proj/AGENTS.md", content: "规则" },
  ]
  let skills : Array[@context.Skill] = [
    {
      name: "zzz",
      description: "",
      file_path: "/s/zzz/SKILL.md",
      base_dir: "/s/zzz",
      disable_model_invocation: false,
      scope: "user",
    },
    {
      name: "aaa",
      description: "",
      file_path: "/s/aaa/SKILL.md",
      base_dir: "/s/aaa",
      disable_model_invocation: false,
      scope: "user",
    },
  ]
  let prompts : Array[@context.PromptTemplate] = [
    { name: "review", description: "", path: "/p/review.md", scope: "user" },
    { name: "fix-loop", description: "", path: "/p/fix-loop.md", scope: "project" },
  ]
  let banner = build_banner(
    "/tmp/proj",
    files,
    skills,
    prompts,
    ["demo.js"],
    [],
    "<project_context path=\"/tmp/proj/AGENTS.md\">" +
    "<name>aaa</name><name>zzz</name>",
  )
  // 段顺序照 pi：Context → Skills → Prompts → Extensions，段间一个空行。
  assert_eq(
    banner,
    [
      "[Context] AGENTS.md",
      "",
      "[Skills] aaa, zzz",
      "",
      "[Prompts] /fix-loop, /review",
      "",
      "[Extensions] demo.js",
    ],
  )
}

///|
test "build_banner：没有扩展与 prompt 时不出现对应段" {
  let banner = build_banner(
    "/tmp/proj",
    [],
    [],
    [],
    [],
    ["重名：skill \"x\""],
    "",
  )
  assert_eq(banner, ["[Skill conflicts] 重名：skill \"x\""])
}

///|
/// 鼠标捕获：默认关（这样终端自己的拖选/复制还能用），Ctrl+T 才开。
/// 序列一律攒在 `prelude` 里由渲染循环发送 —— 就地写会插进一帧中间。
test "鼠标捕获默认关，切换只改状态并把序列攒进 prelude" {
  let tui = TuiState::new()
  assert_false(tui.mouse)
  assert_eq(tui.prelude, "")
  set_mouse_capture(tui, true)
  assert_true(tui.mouse)
  // 1000（按下/抬起/滚轮）+ 1006（SGR 坐标），不是 1003（全动作）。
  assert_eq(tui.prelude, "\u{1b}[?1000h\u{1b}[?1006h")
  assert_true(tui.dirty)
  // 已经开着再开一次：不重复发序列。
  tui.prelude = ""
  set_mouse_capture(tui, true)
  assert_eq(tui.prelude, "")
  set_mouse_capture(tui, false)
  assert_false(tui.mouse)
  assert_eq(tui.prelude, "\u{1b}[?1006l\u{1b}[?1000l")
}
