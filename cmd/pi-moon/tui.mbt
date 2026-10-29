// 全屏 TUI：终端生命周期、键位、渲染循环与 agent 驱动器。
//
// 三个任务，两条碰 agent 的路：
//
//   key loop    读键 → 改输入缓冲 / 往命令队列里放一条 → 标脏；
//               界面显示类按键（翻页 / 滚动 / 面板）经 `ui_dispatch` 发 `Ui`
//               事件，`Agent::dispatch_ui` 同步归约 —— 无 await，生成中也能用
//   render loop 标脏时把 state 画成一帧（渲染是 diff 的，没变时几乎不写终端）
//   driver      await agent.send(...)（模型流、工具、压缩都在这一条 await 里）
//
// 为什么不让按键直接 `agent.send()`：`send` 会一直 await 到整个回合结束，
// 键循环被它卡住，用户连 Esc 都按不进来。命令队列把「用户想干什么」与
// 「环跑到哪一步」解耦，Esc 则走一条更短的路 —— 只把 `tui.abort` 立起来，
// provider effect 在下一个分片边界查它（见 `core/provider/effect.mbt`）。

///|
pub(all) enum TuiCommand {
  Submit(String)
  Continue
  Compact
  Tools(Array[String])
  ListTools
  /// `/thinking <级别>`：直接切一档（不开面板）。
  ThinkingLevel(String)
  /// Ctrl+L / `/model`：开模型面板。
  OpenModels
  /// `/thinking`：开思考级别面板。
  OpenThinking
  /// `/resume`：开会话面板。
  OpenSessions
  Exit
} derive(Debug)

///|
/// 面板里的一项、面板本体都在 core（`state.ui.picker`）：渲染是 state 的
/// 纯函数，「面板开着没有、选中是哪行」也得能从 state 重算。

///|
/// 界面自己的可变状态。
///
/// 「界面怎么显示」里能从环上状态重算的部分（哪一页、滚到哪、面板开着没有）
/// 已经搬进了 `state.ui`，由 `Ui` 事件驱动；这里只剩环表达不了的本地细节：
/// 输入缓冲与历史、终端尺寸、命令队列、反馈卡。键循环改这里的字段不走环，
/// 改界面显示则发 `Ui` 事件（见 `ui_dispatch`）。
pub(all) struct TuiState {
  mut width : Int32
  mut height : Int32
  mut input : String
  mut cursor : Int32
  mut history : Array[String]
  mut history_pos : Int32
  mut busy : Bool
  mut abort : Bool
  mut quit : Bool
  mut dirty : Bool
  /// 上次画过的 spinner 帧号（now / 120）。渲染循环用它做时间心跳：working
  /// 期间帧号变了才标脏 —— 动画匀速推进，不绑 token 事件的到达节奏。
  mut last_spinner_frame : Int64
  /// 钉在对话流里的命令反馈卡（ela 的 `statusCards`）。
  mut cards : Array[StatusCard]
  /// 启动横幅：`[Context]` / `[Skills]` / `[Skill conflicts]`，画在对话页
  /// 顶部、随对话滚走（elA 的 startup banner，只是不在底部常驻）。
  mut banner : Array[String]
  /// 当前 messages 条数 —— 反馈卡的锚点用它（`at` = 创建时的条数）。
  mut message_count : Int32
  mut commands : Array[TuiCommand]
  /// 生成中敲下的话：由 effect 的 `on_tick` 在安全点 dispatch 进环里。
  mut pending_actions : Array[@action.AgentAction]
  /// 请求把队列取回输入框（`Ctrl+U` / 闲时 `Esc`）。
  /// 拿到 agent 状态的时机在 driver / on_tick 那一侧。
  mut take_back : Bool
  /// 面板里按了 Enter：driver 去应用选中的那一项。
  /// 面板本体在 `state.ui.picker`，这里只是「确认过」的标志。
  mut picker_confirm : Bool
  /// 当前会话文件（空 = 不落盘）。`/resume` 换会话时跟着变。
  mut session_path : String
  mut session_label : String
  /// 会话 id（退出提示 `--session <id>` 用）。
  mut session_id : String
  mut last_ctrl_c : Int64
  mut writer : @session.SessionWriter?
  /// 鼠标捕获（`\e[?1000h`）开着没有。
  ///
  /// 开着滚轮能翻页，代价是终端拿不回拖选 —— 拖拽被当成鼠标事件送到 app。
  /// 所以默认**关**（终端自己的选择/复制照旧能用），要滚轮就按一下 Ctrl+T。
  mut mouse : Bool
  /// 下一帧之前要写出去的转义（比如切换鼠标捕获）。
  ///
  /// 不能就地写：渲染循环一帧一次 `print_raw`，插进帧中间会把画面撕开。
  mut prelude : String
  /// 底色：24-bit 终端用 pi 的原值，否则退回 16 色名字（见 `tui_color.mbt`）。
  mut palette : Palette
}

///|
/// 一张命令反馈卡。`at` 是创建时的消息条数：渲染时插在第 `at` 条消息之后，
/// 于是新消息会把它往上顶 —— 与 ela 的 `statusCards` 同一个形状。
pub(all) struct StatusCard {
  text : String
  at : Int32
} derive(Eq, Debug)

///|
/// 把 agent 的引用交给 effect 钩子。
///
/// hooks 在 agent 之前就建好了（agent 需要 effect 表），而 `on_tick` 要读队列才能
/// 把“取回”变成真的。用一个可后填的格子存引用，避免把 Agent 塞进全局变量：
/// 一次性模式永远不会填它。
pub(all) struct TuiBridge {
  mut agent : @runtime.Agent?
  /// 本次装载的技能清单：`/skill:<name>` 展开用。agent 建好后由 main 填。
  mut skills : Array[@context.Skill]
}

///|
pub fn TuiBridge::new() -> TuiBridge {
  { agent: None, skills: [], }
}

///|
/// 输入里的 `/skill:<name>` 展开成 XML 块（只在开头匹配时才读文件）。
async fn expand_skill_input(
  text : String,
  skills : Array[@context.Skill],
) -> String {
  if !text.has_prefix("/skill:") {
    return text
  }
  @context.expand_skill_command(text, skills, async fn(path : String) -> String {
    @sys.read_text_lossy(path) catch {
      err => abort("read: " + err.to_string())
    }
  })
}

///|
pub fn TuiState::new() -> TuiState {
  {
    width: 80,
    height: 24,
    input: "",
    cursor: 0,
    history: [],
    history_pos: -1,
    busy: false,
    abort: false,
    quit: false,
    dirty: true,
    last_spinner_frame: -1L,
    cards: [],
    banner: [],
    message_count: 0,
    commands: [],
    pending_actions: [],
    take_back: false,
    picker_confirm: false,
    session_path: "",
    session_label: "",
    session_id: "",
    last_ctrl_c: 0L,
    writer: None,
    mouse: false,
    prelude: "",
    palette: Palette::ansi256(),
  }
}

///|
/// 是不是该起 TUI：没给 `-p`，且 stdin / stdout 都是终端。
///
/// 管道输入必须继续走「整段当 prompt」的老路；管道输出（`pi-moon > out.txt`）
/// 也不能进 TUI —— 全屏转义序列会整段落进文件。终端存在不等于用户在跟界面
/// 交互（`ci | pi-moon` 里 CONIN$ 照样存在）。
pub fn wants_tui(args : CliArgs) -> Bool {
  args.prompt is None &&
  !args.list_models &&
  !args.help &&
  @sys.stdin_is_tty() &&
  @sys.stdout_is_tty()
}

///|
fn now_ms() -> Int64 {
  @sys.now()
}

///|
/// 鼠标捕获的开关序列。用 1000（按下 / 抬起 / 滚轮）而不是 1003（全动作）：
/// 我们只认滚轮，没必要让每个 mousemove 都往 stdin 里灌一条事件。
/// 1006 是 SGR 坐标编码（1000 的旧坐标编码在超过 223 列时会溢出）。
fn mouse_sequence(on : Bool) -> String {
  if on {
    "\u{1b}[?1000h\u{1b}[?1006h"
  } else {
    "\u{1b}[?1006l\u{1b}[?1000l"
  }
}

///|
/// 切鼠标捕获。开着滚轮能翻页，但终端就选不中文字了（拖拽变成 app 的鼠标
/// 事件）—— 所以默认关，要复制就直接拖，要滚轮就 Ctrl+T 开一下。
///
/// 序列不就地写，攒在 `prelude` 里等下一帧开头发，避免插进一帧中间。
fn set_mouse_capture(tui : TuiState, on : Bool) -> Unit {
  if tui.mouse == on {
    return
  }
  tui.mouse = on
  tui.prelude = tui.prelude + mouse_sequence(on)
  tui.dirty = true
}

///|

///|
/// 一张反馈卡：尾部还是同一位置那张就**就地替换**（连续提示不刷屏），否则
/// 新开一张。卡不过期 —— 它随对话滚走，不在底栏抢位置。
fn set_notice(tui : TuiState, text : String) -> Unit {
  if !tui.cards.is_empty() {
    let last = tui.cards[tui.cards.length() - 1]
    if last.at == tui.message_count {
      tui.cards[tui.cards.length() - 1] = { text, at: last.at, }
      tui.dirty = true
      return
    }
  }
  tui.cards.push({ text, at: tui.message_count, })
  // 长会话里的上限：旧卡已经滚得很远了，没必要全留着。
  if tui.cards.length() > 50 {
    tui.cards = tui.cards[25:].to_owned()
  }
  tui.dirty = true
}

///|
/// UI 事件 → 环。键循环唯一碰 agent 的地方，且只碰 UI 事件：
/// `dispatch_ui` 同步归约、无 await，生成中按键也能立即生效。
fn ui_dispatch(
  agent : @runtime.Agent,
  tui : TuiState,
  event : @action.UiAction,
) -> Unit {
  agent.dispatch_ui(@action.Ui(event)) catch {
    err => set_notice(tui, "error: " + err.to_string())
  }
}

///|
/// 当前页的相对滚动（两页各归各的，切页不会把另一页的视口带过去）。
fn ui_scroll(agent : @runtime.Agent, tui : TuiState, delta : Int32) -> Unit {
  ui_dispatch(agent, tui, @action.Scrolled(agent.state.ui.page, delta))
}

///|
/// 进 TUI。返回时会恢复终端 —— 失败路径也恢复（否则终端留在 raw mode）。
pub async fn run_tui(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
  compact_enabled : Bool,
  session_path : String,
  session_id : String,
  skills : Array[@context.Skill],
) -> Unit {
  let (width, height) = @io.get_terminal_size()
  tui.width = width
  tui.height = height
  tui.session_path = session_path
  tui.session_label = if session_path.is_empty() {
    "(不落盘)"
  } else {
    session_id
  }
  tui.session_id = session_id
  @sys.enable_vt_output()
  let color_mode = tui_color_mode()
  let theme = load_theme(config.agent_dir)
  tui.palette = Palette::from_theme(theme, color_mode)
  let (app, cleanup) = @vnode.init_vnode_terminal(
    width,
    height,
    fn(raw) { @io.print_raw(raw) },
    // 鼠标捕获不在那里开：它默认开的是 1003（全动作），拖选/复制就没了。
    // 改由 `set_mouse_capture` 按需开 1000（只要滚轮），见 Ctrl+T。
    mouse=false,
    color_mode~,
  )
  let failure = try {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() { tui_render_loop(app, tui, agent) })
      group.spawn_bg(async fn() { tui_key_loop(agent, tui) })
      tui_driver(agent, tui, config, compact_enabled, skills)
    })
    None
  } catch {
    err => Some(err.to_string())
  }
  cleanup()
  // `cleanup` 只关它自己开的东西（这里传的是 `mouse=false`），鼠标是我们在
  // Ctrl+T 里自己开的，退出时得自己关 —— 不然退出来终端还把拖选当成 app 事件。
  if tui.mouse {
    @io.print_raw(mouse_sequence(false))
  }
  // 退出时再 flush 一次：最后一个回合之后状态可能还变过（压缩、工具结果）。
  // 顺序很重要：摘要还写 UTF-8，代码页要在它之后才还原。
  persist_tui(agent, tui)
  let state = agent.state
  // 恢复提示（elA 的 printResumeOnExit 同形）：只有真的落过盘、接过话才提
  // —— 那条命令要能真的跑起来；没说过话的空会话恢复出来也是空的。
  if !tui.session_id.is_empty() &&
    !tui.session_path.is_empty() &&
    state.messages.length() > 0 {
    @sys.write_err(
      "To resume this session: pi-moon --session " + tui.session_id + "\n",
    ) catch {
      _ => ()
    }
  }
  match failure {
    Some(error) =>
      @sys.write_err("[tui] " + error + "\n") catch {
        _ => ()
      }
    None => ()
  }
  @sys.restore_vt_output()
}

///|
async fn tui_key_loop(agent : @runtime.Agent, tui : TuiState) -> Unit {
  while !tui.quit {
    let key = @io.read_key()
    if key.length() == 0 {
      @async.sleep(10)
      continue
    }
    handle_key(agent, tui, key)
  }
}

///|
fn handle_key(agent : @runtime.Agent, tui : TuiState, key : String) -> Unit {
  tui.dirty = true
  // 面板开着时键盘归面板：Enter 确认、Esc 取消、↑↓ 选项。
  match agent.state.ui.picker {
    Some(_) => {
      let event = @events.parse_input(key)
      match event {
        @events.InputEvent::Key(key_event) =>
          handle_picker_key(agent, tui, key_event)
        _ => ()
      }
      return
    }
    None => ()
  }
  // Alt+Enter 在 Windows 终端上是 ESC + CR；`parse_input` 只把它当未知序列。
  // ela 的默认键位：Enter = steer，Option+Enter = followUp。
  if key == "\u{001b}\r" || key == "\u{001b}\n" {
    submit_input(tui, @common.FollowUp)
    return
  }
  let event = @events.parse_input(key)
  match event {
    @events.InputEvent::Key(key_event) =>
      handle_key_event(agent, tui, key_event)
    @events.InputEvent::Mouse(mouse) => handle_mouse(agent, tui, mouse)
    _ => ()
  }
}

///|
/// 滚轮翻页（±3 行）：与 PgUp / PgDn 同一条路。点击不处理 —— 界面上没有
/// 可点的东西，面板选中靠键盘。
fn handle_mouse(
  agent : @runtime.Agent,
  tui : TuiState,
  mouse : @events.MouseEvent,
) -> Unit {
  match mouse.button {
    @events.MouseButton::ScrollUp => ui_scroll(agent, tui, 3)
    @events.MouseButton::ScrollDown => ui_scroll(agent, tui, -3)
    _ => ()
  }
}

///|
fn handle_key_event(
  agent : @runtime.Agent,
  tui : TuiState,
  key : @events.KeyEvent,
) -> Unit {
  match key {
    @events.KeyEvent::Char(c, modifier) =>
      match modifier {
        @events.KeyModifier::None | @events.KeyModifier::Shift =>
          insert_char(tui, c)
        @events.KeyModifier::Ctrl => handle_ctrl(agent, tui, c)
        _ => ()
      }
    @events.KeyEvent::Special(special, modifier) =>
      match modifier {
        @events.KeyModifier::Ctrl =>
          // Ctrl+Home / Ctrl+End：跳到当前页的最顶 / 最底。
          match special {
            @events.SpecialKey::Home =>
              ui_dispatch(agent, tui, @action.ScrollHome(agent.state.ui.page))
            @events.SpecialKey::End =>
              ui_dispatch(agent, tui, @action.ScrollEnd(agent.state.ui.page))
            _ => handle_special(agent, tui, special)
          }
        _ => handle_special(agent, tui, special)
      }
  }
}

///|
fn handle_special(
  agent : @runtime.Agent,
  tui : TuiState,
  special : @events.SpecialKey,
) -> Unit {
  match special {
    @events.SpecialKey::Enter => submit_input(tui, @common.Steer)
    @events.SpecialKey::Escape =>
      if tui.busy {
        tui.abort = true
        set_notice(tui, "正在中断…")
      } else {
        // 闲时的 Esc = ela 的 `app.interrupt`：有队列就把队列还回编辑器，
        // 没有就清空输入。取回要读 agent 状态，交给 driver / on_tick。
        tui.take_back = true
      }
    @events.SpecialKey::Backspace => {
      let (input, cursor) = backspace(tui.input, tui.cursor)
      tui.input = input
      tui.cursor = cursor
    }
    @events.SpecialKey::Delete => {
      let (input, cursor) = delete_forward(tui.input, tui.cursor)
      tui.input = input
      tui.cursor = cursor
    }
    @events.SpecialKey::Left => tui.cursor = cursor_left(tui.cursor)
    @events.SpecialKey::Right =>
      tui.cursor = cursor_right(tui.cursor, char_count(tui.input))
    @events.SpecialKey::Home => tui.cursor = 0
    @events.SpecialKey::End => tui.cursor = char_count(tui.input)
    @events.SpecialKey::Up => history_prev(tui)
    @events.SpecialKey::Down => history_next(tui)
    @events.SpecialKey::PageUp =>
      ui_scroll(agent, tui, max_int(tui.height / 2, 1))
    @events.SpecialKey::PageDown =>
      ui_scroll(agent, tui, -max_int(tui.height / 2, 1))
    _ => ()
  }
}

///|
fn handle_ctrl(agent : @runtime.Agent, tui : TuiState, c : Char) -> Unit {
  match c {
    'c' => {
      let now = now_ms()
      if tui.busy {
        tui.abort = true
        set_notice(tui, "正在中断（Ctrl+C 再按一次退出）")
      } else if !tui.input.is_empty() {
        clear_input(tui)
      } else if now - tui.last_ctrl_c < 600L {
        tui.quit = true
      } else {
        tui.last_ctrl_c = now
        set_notice(tui, "再按一次 Ctrl+C 退出")
      }
    }
    'd' => {
      tui.abort = true
      tui.quit = true
    }
    'o' => {
      ui_dispatch(agent, tui, @action.ExpandToggled)
      set_notice(
        tui,
        if agent.state.ui.expanded {
          "工具输出：展开"
        } else {
          "工具输出：折叠"
        },
      )
    }
    'r' => { ui_dispatch(agent, tui, @action.PageToggled) }
    // Ctrl+T：鼠标捕获开关。默认关（终端能拖选复制），开了才能用滚轮翻页。
    't' => {
      set_mouse_capture(tui, !tui.mouse)
      set_notice(
        tui,
        if tui.mouse {
          "鼠标：滚轮翻页（要复制请 Shift+拖选，或 Ctrl+T 关掉捕获）"
        } else {
          "鼠标：可拖选复制（Ctrl+T 打开滚轮翻页）"
        },
      )
    }
    // pi 的 `app.model.select`（Ctrl+L）：覆盖 composer 的面板。
    'l' =>
      if tui.busy {
        set_notice(
          tui, "上一回合还没结束：先按 Esc 中断再换模型",
        )
      } else {
        tui.commands.push(OpenModels)
      }
    // ela 的取回是 Option+Up；Windows 控制台的 `_getch` 拿不到 Alt+方向键
    // （`translate_special_key` 只留下方向键本身），所以这里改用 Ctrl+U。
    'u' => {
      tui.take_back = true
      tui.dirty = true
    }
    _ => ()
  }
}

///|
fn insert_char(tui : TuiState, c : Char) -> Unit {
  let (input, cursor) = insert_text(tui.input, tui.cursor, c.to_string())
  tui.input = input
  tui.cursor = cursor
}

///|
fn clear_input(tui : TuiState) -> Unit {
  tui.input = ""
  tui.cursor = 0
  tui.history_pos = -1
}

///|
fn history_prev(tui : TuiState) -> Unit {
  if tui.history.is_empty() {
    return
  }
  let next = if tui.history_pos < 0 {
    tui.history.length() - 1
  } else {
    max_int(tui.history_pos - 1, 0)
  }
  tui.history_pos = next
  tui.input = tui.history[next]
  tui.cursor = char_count(tui.input)
}

///|
fn history_next(tui : TuiState) -> Unit {
  if tui.history_pos < 0 {
    return
  }
  let next = tui.history_pos + 1
  if next >= tui.history.length() {
    tui.history_pos = -1
    clear_input(tui)
  } else {
    tui.history_pos = next
    tui.input = tui.history[next]
    tui.cursor = char_count(tui.input)
  }
}

///|
fn submit_input(tui : TuiState, kind : @common.QueueKind) -> Unit {
  let text = tui.input.trim(chars=" \t\r\n").to_owned()
  if text.is_empty() {
    return
  }
  tui.history.push(text)
  tui.history_pos = -1
  clear_input(tui)
  if text.has_prefix("/") {
    submit_command(tui, text)
    return
  }
  if tui.busy {
    // 生成中不打断：按 Enter 进 steer 队列（工具批次结束就投递）、
    // Alt+Enter 进 followUp（回合收口再投递）。真正入环靠 effect 的 `on_tick` ——
    // 按键任务不碰 agent（见文件头）。
    // 不另发通知：队列面板本身就在 composer 上方显示它。
    tui.pending_actions.push(@action.QueueInput({ text, content: [], kind, }))
  } else {
    tui.commands.push(Submit(text))
  }
}

///|
fn submit_command(tui : TuiState, text : String) -> Unit {
  if text == "/exit" || text == "/quit" {
    tui.commands.push(Exit)
  } else if text == "/compact" {
    tui.commands.push(Compact)
  } else if text == "/continue" {
    tui.commands.push(Continue)
  } else if text == "/tools" {
    tui.commands.push(ListTools)
  } else if text.has_prefix("/tools ") {
    let names = split_tool_list(text[7:].trim().to_owned())
    tui.commands.push(Tools(names))
  } else if text == "/model" {
    tui.commands.push(OpenModels)
  } else if text == "/thinking" {
    tui.commands.push(OpenThinking)
  } else if text.has_prefix("/thinking ") {
    tui.commands.push(ThinkingLevel(text[10:].trim().to_owned()))
  } else if text == "/resume" {
    tui.commands.push(OpenSessions)
  } else {
    set_notice(tui, "未知命令：" + text)
  }
}

///|
async fn tui_driver(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
  compact_enabled : Bool,
  skills : Array[@context.Skill],
) -> Unit {
  while !tui.quit {
    if tui.take_back {
      take_back_now(agent, tui)
    }
    if tui.picker_confirm {
      apply_picker(agent, tui, config)
    }
    if tui.commands.is_empty() {
      @async.sleep(15)
      continue
    }
    let command = tui.commands.remove(0)
    match command {
      Submit(text) => {
        tui.busy = true
        tui.abort = false
        ui_dispatch(agent, tui, @action.ScrollEnd(@action.UiChat))
        tui.dirty = true
        let text = expand_skill_input(text, skills) catch {
          err => {
            set_notice(tui, "[skill] " + err.to_string())
            tui.busy = false
            continue
          }
        }
        agent.send(@action.UserMessage({ text, content: [], })) catch {
          err => set_notice(tui, "error: " + err.to_string())
        }
        drain_pending(agent, tui)
        tui.abort = false
        tui.busy = false
        tui_auto_compact(agent, tui, compact_enabled)
        persist_tui(agent, tui)
        tui.dirty = true
      }
      Continue => {
        tui.busy = true
        tui.abort = false
        tui.dirty = true
        agent.send(@action.TurnContinue) catch {
          err => set_notice(tui, "error: " + err.to_string())
        }
        drain_pending(agent, tui)
        tui.abort = false
        tui.busy = false
        tui_auto_compact(agent, tui, compact_enabled)
        persist_tui(agent, tui)
        tui.dirty = true
      }
      Compact => {
        tui_compact(agent, tui, @compact.Manual)
        persist_tui(agent, tui)
      }
      Tools(names) => {
        let definitions = @tools.definitions_for(names)
        agent.send(@action.ToolsChanged(definitions)) catch {
          err => set_notice(tui, "error: " + err.to_string())
        }
        let applied : Array[String] = []
        for definition in definitions {
          applied.push(definition.name)
        }
        set_notice(
          tui,
          "tools -> " +
          (if applied.is_empty() { "(none)" } else { applied.join(",") }),
        )
        persist_tui(agent, tui)
        tui.dirty = true
      }
      ListTools => {
        let names = agent.state.tool_names
        set_notice(
          tui,
          "tools: " +
          (if names.is_empty() { "(none)" } else { names.join(",") }),
        )
      }
      OpenModels => open_model_picker(agent, tui, config)
      OpenThinking => open_thinking_picker(agent, tui, config)
      OpenSessions => open_session_picker(agent, tui, config, agent.state.cwd)
      ThinkingLevel(level) => apply_thinking(agent, tui, config, level)
      Exit => tui.quit = true
    }
  }
}

///|
async fn tui_auto_compact(
  agent : @runtime.Agent,
  tui : TuiState,
  enabled : Bool,
) -> Unit {
  if !enabled {
    return
  }
  let state = agent.state
  if state.phase != @common.Idle || state.compacting {
    return
  }
  let decision = @loop.decide_compaction(state, false)
  if !decision.should {
    return
  }
  match decision.reason {
    Some(reason) => tui_compact(agent, tui, reason)
    None => ()
  }
}

///|
async fn tui_compact(
  agent : @runtime.Agent,
  tui : TuiState,
  reason : @compact.CompactReason,
) -> Unit {
  let before = compact_snapshot(agent.state)
  agent.send(@action.CompactRequest(reason)) catch {
    err => {
      set_notice(tui, "error: " + err.to_string())
      return
    }
  }
  let after = agent.state
  if after.compaction_epoch > before.epoch {
    match after.last_compaction {
      Some(record) =>
        set_notice(
          tui,
          reason.text() +
          "压缩：" +
          record.summarized_count.to_string() +
          " 条 → " +
          record.kept_count.to_string() +
          " 条（原约 " +
          record.tokens_before.to_string() +
          " tokens）",
        )
      None => set_notice(tui, reason.text() + "压缩完成")
    }
  } else if after.last_compaction != before.record {
    set_notice(tui, "没什么可压的")
  } else {
    set_notice(tui, "压缩失败：" + after.error.unwrap_or("未知错误"))
  }
  tui.dirty = true
}

///|
async fn persist_tui(agent : @runtime.Agent, tui : TuiState) -> Unit {
  match tui.writer {
    None => ()
    Some(writer) => {
      let flushed = writer.flush(agent.state) catch {
        err => {
          set_notice(tui, "[session] " + err.to_string())
          return
        }
      }
      let (next, cursor) = flushed
      tui.writer = Some(next)
      agent.send(@action.TracePersisted(cursor)) catch {
        _ => ()
      }
    }
  }
}

///|
async fn tui_render_loop(
  app : @vnode.VNodeApp,
  tui : TuiState,
  agent : @runtime.Agent,
) -> Unit {
  while !tui.quit {
    // 原生后端没有 resize 回调，靠轮询；每次渲染都读一次代价不高。
    let (width, height) = @io.get_terminal_size()
    if width != tui.width || height != tui.height {
      tui.width = width
      tui.height = height
      app.resize(width, height)
      tui.dirty = true
    }
    // spinner 心跳：working 期间 spinner 帧号变了才标脏。动画由时间驱动
    // （120ms 一帧），不绑 token 事件的到达节奏 —— 否则思考期没有事件、
    // spinner 冻结，token 突发时又跳帧，看起来就是「loading 卡顿」。
    // 帧内容只依赖当前 state，这一帧丢掉下一帧补上，丢帧是安全的。
    if agent.state.phase != @common.Idle || agent.state.compacting {
      let frame = @sys.now() / 120L
      if frame != tui.last_spinner_frame {
        tui.last_spinner_frame = frame
        tui.dirty = true
      }
    } else {
      tui.last_spinner_frame = -1L
    }
    if !tui.prelude.is_empty() {
      @io.print_raw(tui.prelude)
      tui.prelude = ""
      // 切换本身不用重画，但底栏的提示跟着变了。
      tui.dirty = true
    }
    if tui.dirty {
      tui.dirty = false
      @io.print_raw(app.render_frame(tui_view(tui, agent.state)))
    }
    @async.sleep(16)
  }
}

///|
/// 把生成中敲的话 / 取回请求送进环里。**只在 effect 的安全点被调用**
/// （`ProviderHooks::on_tick`）：driver 此刻正在这条 effect 里 await，这个 dispatch
/// 与它同上下文。
pub fn flush_ui_actions(
  tui : TuiState,
  dispatch : @runtime.Dispatch,
  bridge : TuiBridge,
) -> Unit {
  if tui.take_back {
    take_back_in_effect(tui, dispatch, bridge)
  }
  while !tui.pending_actions.is_empty() {
    let action = tui.pending_actions.remove(0)
    dispatch.send(action) catch {
      err => set_notice(tui, "error: " + err.to_string())
    }
    tui.dirty = true
  }
}

///|
/// driver 自己（没有 effect 在跑时）把待发 action 送进去。
///
/// 生成结束时在途的那几条（例如刚好在 `llm.done` 之后才按的 Enter）没人 tick 到
/// 它们，这里兜底 —— 否则它们会永远挂在界面上。
async fn drain_pending(agent : @runtime.Agent, tui : TuiState) -> Unit {
  while !tui.pending_actions.is_empty() {
    let action = tui.pending_actions.remove(0)
    agent.send(action) catch {
      err => set_notice(tui, "error: " + err.to_string())
    }
    tui.dirty = true
  }
}

///|
/// 队列里的文本 → 输入框。返回取回了几条（0 = 没有排队的）。
fn take_back_from_state(state : @state.AgentState, tui : TuiState) -> Int32 {
  let texts : Array[String] = []
  for item in state.steer_queue {
    texts.push(item.text)
  }
  for item in state.follow_up_queue {
    texts.push(item.text)
  }
  if texts.is_empty() {
    clear_input(tui)
    return 0
  }
  tui.input = texts.join(" ")
  tui.cursor = char_count(tui.input)
  texts.length()
}

///|
fn take_back_notice(tui : TuiState, count : Int32) -> Unit {
  // 空队列时只是「Esc 清输入」，不必多说一句；有东西拿回来才值得一张卡。
  if count > 0 {
    set_notice(tui, "已取回 " + count.to_string() + " 条排队消息")
  }
  tui.dirty = true
}

///|
/// 空闲时由 driver 处理取回（它直接拿着 agent）。
async fn take_back_now(agent : @runtime.Agent, tui : TuiState) -> Unit {
  tui.take_back = false
  let count = take_back_from_state(agent.state, tui)
  agent.send(@action.QueueClear) catch {
    err => set_notice(tui, "error: " + err.to_string())
  }
  take_back_notice(tui, count)
}

///|
/// 生成中由 `on_tick` 处理取回：此时 driver 卡在 effect 里，只能从 effect
/// 里拿状态与 dispatch，清队列走同一条泵。
fn take_back_in_effect(
  tui : TuiState,
  dispatch : @runtime.Dispatch,
  bridge : TuiBridge,
) -> Unit {
  tui.take_back = false
  match bridge.agent {
    Some(agent) => {
      let count = take_back_from_state(agent.state, tui)
      dispatch.send(@action.QueueClear) catch {
        err => set_notice(tui, "error: " + err.to_string())
      }
      take_back_notice(tui, count)
    }
    None => ()
  }
}

///|
fn max_int(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

// ─── 面板：模型 / 思考级别 ──────────────────────────────────────────────────
//
// ela 的面板是「覆盖 composer 矩形」的选择器（顶边框 + 提示行 + 列表 + 底边框），
// 不是居中浮窗。这里只做列表与选中：Enter 确认、Esc 取消、↑↓ 移动。

///|
fn handle_picker_key(
  agent : @runtime.Agent,
  tui : TuiState,
  key : @events.KeyEvent,
) -> Unit {
  match agent.state.ui.picker {
    None => ()
    Some(_) =>
      match key {
        @events.KeyEvent::Char('c', @events.KeyModifier::Ctrl) =>
          ui_dispatch(agent, tui, @action.PickerClosed)
        @events.KeyEvent::Char(_, _) => ()
        @events.KeyEvent::Special(special, _) =>
          match special {
            @events.SpecialKey::Escape =>
              ui_dispatch(agent, tui, @action.PickerClosed)
            @events.SpecialKey::Enter => tui.picker_confirm = true
            @events.SpecialKey::Up =>
              ui_dispatch(agent, tui, @action.PickerMoved(-1))
            @events.SpecialKey::Down =>
              ui_dispatch(agent, tui, @action.PickerMoved(1))
            @events.SpecialKey::PageUp =>
              ui_dispatch(agent, tui, @action.PickerMoved(-5))
            @events.SpecialKey::PageDown =>
              ui_dispatch(agent, tui, @action.PickerMoved(5))
            @events.SpecialKey::Home =>
              ui_dispatch(agent, tui, @action.PickerMoved(-2147483647))
            @events.SpecialKey::End =>
              ui_dispatch(agent, tui, @action.PickerMoved(2147483647))
            _ => ()
          }
      }
  }
}

///|
fn open_model_picker(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
) -> Unit {
  let items : Array[@action.UiPickerItem] = []
  for provider in config.providers {
    for model in provider.models {
      let mut detail = ""
      if model.reasoning {
        detail = "reasoning"
      }
      if model.context_window > 0 {
        let ctx = "ctx " + format_tokens(model.context_window)
        detail = if detail.is_empty() { ctx } else { detail + " · " + ctx }
      }
      items.push({
        label: provider.name + " / " + model.id,
        detail,
        provider: provider.name,
        model_id: model.id,
        level: "",
        path: "",
      })
    }
  }
  if items.is_empty() {
    set_notice(tui, "配置里没有可选的模型（models.json）")
    return
  }
  let mut selected = 0
  for index in 0..<items.length() {
    if items[index].provider == agent.state.provider_name &&
      items[index].model_id == agent.state.model_id {
      selected = index
    }
  }
  ui_dispatch(
    agent,
    tui,
    @action.PickerOpened({
      kind: @action.ModelPicker,
      title: "选择模型",
      items,
      selected,
    }),
  )
}

///|
fn open_thinking_picker(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
) -> Unit {
  let state = agent.state
  let model = match find_model(config, state.provider_name, state.model_id) {
    Some(model) => model
    None => {
      set_notice(tui, "当前模型不在目录里，改不了思考级别")
      return
    }
  }
  if !model.reasoning {
    set_notice(tui, "当前模型不支持思考级别")
    return
  }
  let levels = thinking_levels(model)
  if levels.is_empty() {
    set_notice(tui, "当前模型不支持思考级别")
    return
  }
  let items : Array[@action.UiPickerItem] = []
  let mut selected = 0
  for index in 0..<levels.length() {
    let level = levels[index]
    if level == state.thinking_level {
      selected = index
    }
    items.push({
      label: level,
      detail: if level == "off" {
        "不思考"
      } else {
        "思考预算：" + level
      },
      provider: state.provider_name,
      model_id: state.model_id,
      level,
      path: "",
    })
  }
  ui_dispatch(
    agent,
    tui,
    @action.PickerOpened({
      kind: @action.ThinkingPicker,
      title: "思考级别",
      items,
      selected,
    }),
  )
}

///|
fn find_model(
  config : @provider.PiConfig,
  provider_name : String,
  model_id : String,
) -> @provider.PiModelInfo? {
  for provider in config.providers {
    if provider.name == provider_name {
      for model in provider.models {
        if model.id == model_id {
          return Some(model)
        }
      }
    }
  }
  None
}

///|
fn thinking_levels(model : @provider.PiModelInfo) -> Array[String] {
  let all = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
  let out : Array[String] = []
  for level in all {
    // 显式 null = 这家不支持这一档；没有映射项 = 按原级别发。
    match model.thinking_level_map.get(level) {
      Some(None) => ()
      _ => out.push(level)
    }
  }
  out
}

///|
fn clamp_thinking(
  config : @provider.PiConfig,
  provider_name : String,
  model_id : String,
  level : String,
) -> String {
  match find_model(config, provider_name, model_id) {
    None => "off"
    Some(model) =>
      if !model.reasoning {
        "off"
      } else {
        match model.thinking_level_map.get(level) {
          Some(None) => "off"
          _ => level
        }
      }
  }
}

///|
/// Enter 确认后由 driver 调用：改模型 / 改思考级别，然后落盘。
async fn apply_picker(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
) -> Unit {
  tui.picker_confirm = false
  let picker = match agent.state.ui.picker {
    Some(picker) => picker
    None => return
  }
  if agent.state.phase != @common.Idle || agent.state.compacting {
    set_notice(tui, "上一回合还没结束，先按 Esc 中断再改")
    ui_dispatch(agent, tui, @action.PickerClosed)
    return
  }
  let item = picker.items[picker.selected]
  match picker.kind {
    @action.ModelPicker => {
      let level = clamp_thinking(
        config,
        item.provider,
        item.model_id,
        agent.state.thinking_level,
      )
      let resolved = config.resolve(
        provider=item.provider,
        model=item.model_id,
        thinking=level,
      ) catch {
        err => {
          set_notice(tui, "换模型失败：" + err.to_string())
          ui_dispatch(agent, tui, @action.PickerClosed)
          return
        }
      }
      agent.send(@action.ModelChanged(resolved_model_spec(resolved))) catch {
        err => set_notice(tui, "error: " + err.to_string())
      }
      set_notice(tui, "模型：" + item.label)
      ui_dispatch(agent, tui, @action.PickerClosed)
      persist_tui(agent, tui)
    }
    @action.ThinkingPicker => {
      agent.send(@action.ThinkingChanged(item.level)) catch {
        err => set_notice(tui, "error: " + err.to_string())
      }
      set_notice(tui, "思考级别：" + item.level)
      ui_dispatch(agent, tui, @action.PickerClosed)
      persist_tui(agent, tui)
    }
    @action.SessionPicker => restore_session(agent, tui, item.path)
  }
  tui.dirty = true
}

///|
/// `/thinking <级别>`：不开面板，直接切（与 ela 的 handleThinkingCommand 同形）。
async fn apply_thinking(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
  wanted : String,
) -> Unit {
  if agent.state.phase != @common.Idle || agent.state.compacting {
    set_notice(
      tui, "上一回合还没结束：先按 Esc 中断再改思考级别",
    )
    return
  }
  let model = match
    find_model(config, agent.state.provider_name, agent.state.model_id) {
    Some(model) => model
    None => {
      set_notice(tui, "当前模型不在目录里，改不了思考级别")
      return
    }
  }
  if !model.reasoning {
    set_notice(tui, "当前模型不支持思考级别")
    return
  }
  let levels = thinking_levels(model)
  let mut matched = ""
  for level in levels {
    if level.to_lower() == wanted.to_lower() {
      matched = level
    }
  }
  if matched.is_empty() {
    set_notice(
      tui,
      "未知思考级别 \"" + wanted + "\"；可选：" + levels.join(", "),
    )
    return
  }
  agent.send(@action.ThinkingChanged(matched)) catch {
    err => set_notice(tui, "error: " + err.to_string())
  }
  set_notice(tui, "思考级别：" + matched)
  persist_tui(agent, tui)
  tui.dirty = true
}

// ─── 会话面板（/resume） ───────────────────────────────────────────────────

///|
struct SessionFile {
  name : String
  path : String
  mtime : Int64
  size : Int64
}

///|
async fn open_session_picker(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
  cwd : String,
) -> Unit {
  // 与 pi 同布局：扫 cwd 对应目录，再扫其余 --<cwd>-- 目录（别的目录里的会话
  // 也能恢复 —— 文件头里带 cwd，恢复后接着那份写）。
  let root = session_directory(config)
  let encoded = @session.encode_cwd(cwd)
  let names = @sys.readdir(root) catch {
    _ => {
      set_notice(tui, "没有会话目录：" + root)
      return
    }
  }
  let files : Array[SessionFile] = []
  let add_dir = async fn(directory : String) -> Unit {
    let entries = @sys.readdir(directory) catch {
      _ => return
    }
    for name in entries {
      if name.has_suffix(".jsonl") {
        let path = directory + "/" + name
        let mtime = @sys.mtime(path) catch { _ => 0L }
        let size = @sys.file_size(path) catch { _ => 0L }
        files.push({ name, path, mtime, size, })
      }
    }
  }
  add_dir(root + "/" + encoded)
  for name in names {
    if name.has_prefix("--") && name.has_suffix("--") && name != encoded {
      add_dir(root + "/" + name)
    }
  }
  if files.is_empty() {
    set_notice(tui, "还没有历史会话")
    return
  }
  // 新的在上面（文件数通常几十，插入排序足够）。
  let mut index = 1
  while index < files.length() {
    let current = files[index]
    let mut at = index
    while at > 0 && files[at - 1].mtime < current.mtime {
      files[at] = files[at - 1]
      at = at - 1
    }
    files[at] = current
    index = index + 1
  }
  let now = @sys.now() / 1000L
  let items : Array[@action.UiPickerItem] = []
  let mut selected = 0
  for at in 0..<files.length() {
    let file = files[at]
    let stem = if file.name.has_suffix(".jsonl") {
      file.name[:file.name.length() - 6].to_owned()
    } else {
      file.name
    }
    if file.path == tui.session_path {
      selected = at
    }
    // 展示 id（退出提示里 `--session <id>` 用的就是它），时间戳部分不占地方。
    let shown = @session.session_id_from_path(stem)
    items.push({
      label: relative_time(file.mtime, now),
      detail: shown + " · " + size_text(file.size),
      provider: "",
      model_id: "",
      level: "",
      path: file.path,
    })
  }
  ui_dispatch(
    agent,
    tui,
    @action.PickerOpened({
      kind: @action.SessionPicker,
      title: "恢复会话",
      items,
      selected,
    }),
  )
}

///|
fn relative_time(seconds : Int64, now_seconds : Int64) -> String {
  let diff = if now_seconds > seconds { now_seconds - seconds } else { 0L }
  if diff < 60L {
    "刚刚"
  } else if diff < 3600L {
    (diff / 60L).to_string() + " 分钟前"
  } else if diff < 86400L {
    (diff / 3600L).to_string() + " 小时前"
  } else {
    (diff / 86400L).to_string() + " 天前"
  }
}

///|
fn size_text(bytes : Int64) -> String {
  if bytes < 1024L {
    bytes.to_string() + " B"
  } else if bytes < 1024L * 1024L {
    (bytes / 1024L).to_string() + " KB"
  } else {
    (bytes / (1024L * 1024L)).to_string() + " MB"
  }
}

///|
/// 把选中的会话整体装回环上：messages / 轨迹 / 装载段 / 模型，然后把落盘器
/// 换成「接着这个文件写」的游标 —— 不能继续往旧文件里追加当前会话的历史。
async fn restore_session(
  agent : @runtime.Agent,
  tui : TuiState,
  path : String,
) -> Unit {
  let session_id = @session.session_id_from_path(path)
  let loaded_opt = @session.load_session(path, session_id) catch {
    err => {
      set_notice(tui, "[session] " + err.to_string())
      ui_dispatch(agent, tui, @action.PickerClosed)
      tui.dirty = true
      return
    }
  }
  let loaded = match loaded_opt {
    Some(loaded) => loaded
    None => {
      set_notice(tui, "[session] 没有可恢复的内容：" + path)
      ui_dispatch(agent, tui, @action.PickerClosed)
      tui.dirty = true
      return
    }
  }
  let state = agent.state
  let prompt = match loaded.prompt {
    Some(prompt) => prompt
    None =>
      { system_prompt: state.prompt.system_prompt, tools: state.prompt.tools, }
  }
  let tools = match loaded.tools {
    Some(tools) => tools
    None => state.prompt.tools
  }
  let model = match loaded.model {
    Some(model) => model
    None =>
      {
        provider: state.provider_name,
        model_id: state.model_id,
        thinking_level: state.thinking_level,
        reasoning: state.model.reasoning,
        capabilities: state.model.capabilities,
        context_window: state.model.context_window,
      }
  }
  agent.send(
    @action.SessionRestored({
      prompt,
      tools,
      model,
      messages: loaded.messages,
      trace: loaded.trace,
      persisted_seq: loaded.persisted_seq,
    }),
  ) catch {
    err => {
      set_notice(tui, "[session] " + err.to_string())
      ui_dispatch(agent, tui, @action.PickerClosed)
      tui.dirty = true
      return
    }
  }
  let session_id = loaded.session_id
  tui.writer = Some(
    @session.SessionWriter::restored(path, path + ".trace", loaded),
  )
  tui.session_path = path
  tui.session_label = session_id
  tui.session_id = session_id
  // 面板由 SessionRestored 的迁移关掉（顺带把滚动归零）；这里再发一次是幂等的。
  ui_dispatch(agent, tui, @action.PickerClosed)
  ui_dispatch(agent, tui, @action.ScrollEnd(@action.UiChat))
  tui.busy = false
  tui.abort = false
  // 旧会话的反馈卡属于旧对话，不能跟着漂到刚恢复的会话里（ela 换会话时也清）。
  tui.cards = []
  set_notice(
    tui,
    "已恢复：" +
    path +
    "（" +
    loaded.messages.length().to_string() +
    " 条消息）",
  )
  persist_tui(agent, tui)
  tui.dirty = true
}
