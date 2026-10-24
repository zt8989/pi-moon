// 全屏 TUI：终端生命周期、键位、渲染循环与 agent 驱动器。
//
// 三个任务，一个规则：**只有驱动器碰 agent**。
//
//   key loop    读键 → 改输入缓冲 / 往命令队列里放一条 → 标脏
//   render loop 标脏时把 state 画成一帧（渲染是 diff 的，没变时几乎不写终端）
//   driver      await agent.send(...)（模型流、工具、压缩都在这一条 await 里）
//
// 为什么不让按键直接 `agent.send()`：`send` 会一直 await 到整个回合结束，
// 键循环被它卡住，用户连 Esc 都按不进来。命令队列把「用户想干什么」与
// 「环跑到哪一步」解耦，Esc 则走一条更短的路 —— 只把 `tui.abort` 立起来，
// provider effect 在下一个分片边界查它（见 `core/provider/effect.mbt`）。

///|
pub(all) enum TuiPage {
  Chat
  Trace
} derive(Eq, Debug)

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
  Exit
} derive(Debug)

///|
pub(all) enum PickerKind {
  ModelPicker
  ThinkingPicker
} derive(Eq, Debug)

///|
/// 面板里的一项。模型项用 provider / model_id，思考项用 level —— 两者共一个
/// 形状，面板的绘制与选中逻辑就能共用一份。
pub(all) struct PickerItem {
  label : String
  detail : String
  provider : String
  model_id : String
  level : String
} derive(Eq, Debug)

///|
/// 覆盖 composer 的面板（ela 的 selector：整行宽、无左右边框、底边落在
/// composer 的位置）。
pub(all) struct Picker {
  kind : PickerKind
  title : String
  items : Array[PickerItem]
  mut selected : Int32
}

///|
/// 界面自己的可变状态。
///
/// 它不进 `AgentState`：滚动位置、输入缓冲、按过几次 Ctrl+C 都是「界面怎么
/// 显示」，不是「对话是什么」。混进状态树会让 reducer 里多出一堆与模型无关
/// 的迁移。
pub(all) struct TuiState {
  mut width : Int32
  mut height : Int32
  mut input : String
  mut cursor : Int32
  mut history : Array[String]
  mut history_pos : Int32
  mut chat_scroll : Int32
  mut trace_scroll : Int32
  mut page : TuiPage
  mut expanded : Bool
  mut busy : Bool
  mut abort : Bool
  mut quit : Bool
  mut dirty : Bool
  mut notice : String
  mut notice_at : Int64
  mut commands : Array[TuiCommand]
  /// 生成中敲下的话：由 effect 的 `on_tick` 在安全点 dispatch 进环里。
  mut pending_actions : Array[@action.AgentAction]
  /// 请求把队列取回输入框（`Ctrl+U` / 闲时 `Esc`）。
  /// 拿到 agent 状态的时机在 driver / on_tick 那一侧。
  mut take_back : Bool
  /// 打开中的选择面板（模型 / 思考级别）。
  mut picker : Picker?
  /// 面板里按了 Enter：driver 去应用选中的那一项。
  mut picker_confirm : Bool
  mut last_ctrl_c : Int64
  mut writer : @session.SessionWriter?
}

///|
/// 把 agent 的引用交给 effect 钩子。
///
/// hooks 在 agent 之前就建好了（agent 需要 effect 表），而 `on_tick` 要读队列才能
/// 把“取回”变成真的。用一个可后填的格子存引用，避免把 Agent 塞进全局变量：
/// 一次性模式永远不会填它。
pub(all) struct TuiBridge {
  mut agent : @runtime.Agent?
}

///|
pub fn TuiBridge::new() -> TuiBridge {
  { agent: None, }
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
    chat_scroll: 0,
    trace_scroll: 0,
    page: Chat,
    expanded: false,
    busy: false,
    abort: false,
    quit: false,
    dirty: true,
    notice: "",
    notice_at: 0L,
    commands: [],
    pending_actions: [],
    take_back: false,
    picker: None,
    picker_confirm: false,
    last_ctrl_c: 0L,
    writer: None,
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
  pi_stdin_is_tty() != 0 &&
  pi_stdout_is_tty() != 0
}

///|
extern "c" fn pi_stdin_is_tty() -> Int32 = "pi_stdin_is_tty"

///|
extern "c" fn pi_stdout_is_tty() -> Int32 = "pi_stdout_is_tty"

///|
extern "c" fn pi_enable_vt_output() -> Unit = "pi_enable_vt_output"

///|
extern "c" fn pi_restore_vt_output() -> Unit = "pi_restore_vt_output"

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn set_notice(tui : TuiState, text : String) -> Unit {
  tui.notice = text
  tui.notice_at = now_ms()
  tui.dirty = true
}

///|
/// 当前页的滚动位置（两页各归各的，切页不会把另一页的视口带过去）。
fn scroll_get(tui : TuiState) -> Int32 {
  if tui.page == Chat {
    tui.chat_scroll
  } else {
    tui.trace_scroll
  }
}

///|
fn scroll_set(tui : TuiState, value : Int32) -> Unit {
  if tui.page == Chat {
    tui.chat_scroll = value
  } else {
    tui.trace_scroll = value
  }
}

///|
/// 进 TUI。返回时会恢复终端 —— 失败路径也恢复（否则终端留在 raw mode）。
pub async fn run_tui(
  agent : @runtime.Agent,
  tui : TuiState,
  config : @provider.PiConfig,
  compact_enabled : Bool,
  session_label : String,
) -> Unit {
  let (width, height) = @io.get_terminal_size()
  tui.width = width
  tui.height = height
  pi_enable_vt_output()
  let (app, cleanup) = @vnode.init_vnode_terminal(width, height, fn(raw) {
    @io.print_raw(raw)
  })
  let failure = try {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() { tui_render_loop(app, tui, agent) })
      group.spawn_bg(async fn() { tui_key_loop(tui) })
      tui_driver(agent, tui, config, compact_enabled)
    })
    None
  } catch {
    err => Some(err.to_string())
  }
  cleanup()
  // 退出时再 flush 一次：最后一个回合之后状态可能还变过（压缩、工具结果）。
  // 顺序很重要：摘要还写 UTF-8，代码页要在它之后才还原。
  persist_tui(agent, tui)
  let state = agent.state
  let usage = match state.usage {
    Some(usage) => usage.total_tokens.to_string() + " tok"
    None => "0 tok"
  }
  @stdio.stderr.write(
    "[session] " +
    session_label +
    " · " +
    state.messages.length().to_string() +
    " 条消息 · " +
    usage +
    "\n",
  ) catch {
    _ => ()
  }
  match failure {
    Some(error) =>
      @stdio.stderr.write("[tui] " + error + "\n") catch {
        _ => ()
      }
    None => ()
  }
  pi_restore_vt_output()
}

///|
async fn tui_key_loop(tui : TuiState) -> Unit {
  while !tui.quit {
    let key = @io.read_key()
    if key.length() == 0 {
      @async.sleep(10)
      continue
    }
    handle_key(tui, key)
  }
}

///|
fn handle_key(tui : TuiState, key : String) -> Unit {
  tui.dirty = true
  // 面板开着时键盘归面板：Enter 确认、Esc 取消、↑↓ 选项。
  match tui.picker {
    Some(_) => {
      let event = @events.parse_input(key)
      match event {
        @events.InputEvent::Key(key_event) => handle_picker_key(tui, key_event)
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
    @events.InputEvent::Key(key_event) => handle_key_event(tui, key_event)
    _ => ()
  }
}

///|
fn handle_key_event(tui : TuiState, key : @events.KeyEvent) -> Unit {
  match key {
    @events.KeyEvent::Char(c, modifier) =>
      match modifier {
        @events.KeyModifier::None | @events.KeyModifier::Shift =>
          insert_char(tui, c)
        @events.KeyModifier::Ctrl => handle_ctrl(tui, c)
        _ => ()
      }
    @events.KeyEvent::Special(special, modifier) =>
      match modifier {
        @events.KeyModifier::Ctrl =>
          // Ctrl+Home / Ctrl+End：跳到当前页的最顶 / 最底。
          match special {
            @events.SpecialKey::Home => scroll_set(tui, 1000000)
            @events.SpecialKey::End => scroll_set(tui, 0)
            _ => handle_special(tui, special)
          }
        _ => handle_special(tui, special)
      }
  }
}

///|
fn handle_special(tui : TuiState, special : @events.SpecialKey) -> Unit {
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
      scroll_set(tui, scroll_get(tui) + max_int(tui.height / 2, 1))
    @events.SpecialKey::PageDown =>
      scroll_set(tui, max_int(scroll_get(tui) - max_int(tui.height / 2, 1), 0))
    _ => ()
  }
}

///|
fn handle_ctrl(tui : TuiState, c : Char) -> Unit {
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
      tui.expanded = !tui.expanded
      set_notice(
        tui,
        if tui.expanded {
          "工具输出：展开"
        } else {
          "工具输出：折叠"
        },
      )
    }
    'r' => {
      tui.page = if tui.page == Chat { Trace } else { Chat }
      set_notice(tui, if tui.page == Chat { "对话" } else { "轨迹" })
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
  tui.notice = ""
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
        tui.chat_scroll = 0
        tui.notice = ""
        tui.dirty = true
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
        tui.notice = ""
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
      OpenModels => open_model_picker(tui, agent.state, config)
      OpenThinking => open_thinking_picker(tui, agent.state, config)
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
fn handle_picker_key(tui : TuiState, key : @events.KeyEvent) -> Unit {
  match tui.picker {
    None => ()
    Some(picker) =>
      match key {
        @events.KeyEvent::Char('c', @events.KeyModifier::Ctrl) =>
          tui.picker = None
        @events.KeyEvent::Char(_, _) => ()
        @events.KeyEvent::Special(special, _) =>
          match special {
            @events.SpecialKey::Escape => tui.picker = None
            @events.SpecialKey::Enter => tui.picker_confirm = true
            @events.SpecialKey::Up => picker_move(tui, picker, -1)
            @events.SpecialKey::Down => picker_move(tui, picker, 1)
            @events.SpecialKey::PageUp => picker_move(tui, picker, -5)
            @events.SpecialKey::PageDown => picker_move(tui, picker, 5)
            @events.SpecialKey::Home => picker.selected = 0
            @events.SpecialKey::End =>
              picker.selected = max_int(picker.items.length() - 1, 0)
            _ => ()
          }
      }
  }
}

///|
fn picker_move(tui : TuiState, picker : Picker, delta : Int32) -> Unit {
  picker.selected = clamp_int(
    picker.selected + delta,
    0,
    max_int(picker.items.length() - 1, 0),
  )
  tui.dirty = true
}

///|
fn open_model_picker(
  tui : TuiState,
  state : @state.AgentState,
  config : @provider.PiConfig,
) -> Unit {
  let items : Array[PickerItem] = []
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
      })
    }
  }
  if items.is_empty() {
    set_notice(tui, "配置里没有可选的模型（models.json）")
    return
  }
  let mut selected = 0
  for index in 0..<items.length() {
    if items[index].provider == state.provider_name &&
      items[index].model_id == state.model_id {
      selected = index
    }
  }
  tui.picker = Some({
    kind: ModelPicker,
    title: "选择模型",
    items,
    selected,
  })
  tui.dirty = true
}

///|
fn open_thinking_picker(
  tui : TuiState,
  state : @state.AgentState,
  config : @provider.PiConfig,
) -> Unit {
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
  let items : Array[PickerItem] = []
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
    })
  }
  tui.picker = Some({
    kind: ThinkingPicker,
    title: "思考级别",
    items,
    selected,
  })
  tui.dirty = true
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
  let picker = match tui.picker {
    Some(picker) => picker
    None => return
  }
  if agent.state.phase != @common.Idle || agent.state.compacting {
    set_notice(tui, "上一回合还没结束，先按 Esc 中断再改")
    tui.picker = None
    return
  }
  let item = picker.items[picker.selected]
  match picker.kind {
    ModelPicker => {
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
          tui.picker = None
          return
        }
      }
      agent.send(@action.ModelChanged(resolved_model_spec(resolved))) catch {
        err => set_notice(tui, "error: " + err.to_string())
      }
      set_notice(tui, "模型：" + item.label)
      tui.picker = None
      persist_tui(agent, tui)
    }
    ThinkingPicker => {
      agent.send(@action.ThinkingChanged(item.level)) catch {
        err => set_notice(tui, "error: " + err.to_string())
      }
      set_notice(tui, "思考级别：" + item.level)
      tui.picker = None
      persist_tui(agent, tui)
    }
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
