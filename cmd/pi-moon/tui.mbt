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
pub(all) enum TuiCommand {
  Submit(String)
  Continue
  Compact
  Tools(Array[String])
  ListTools
  Exit
} derive(Debug)

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
  mut scroll : Int32
  mut expanded : Bool
  mut busy : Bool
  mut abort : Bool
  mut quit : Bool
  mut dirty : Bool
  mut notice : String
  mut notice_at : Int64
  mut commands : Array[TuiCommand]
  mut last_ctrl_c : Int64
  mut writer : @session.SessionWriter?
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
    scroll: 0,
    expanded: false,
    busy: false,
    abort: false,
    quit: false,
    dirty: true,
    notice: "",
    notice_at: 0L,
    commands: [],
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
/// 进 TUI。返回时会恢复终端 —— 失败路径也恢复（否则终端留在 raw mode）。
pub async fn run_tui(
  agent : @runtime.Agent,
  tui : TuiState,
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
      tui_driver(agent, tui, compact_enabled)
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
  // Alt+Enter 在 Windows 终端上是 ESC + CR；`parse_input` 只把它当未知序列。
  if key == "\u{001b}\r" || key == "\u{001b}\n" {
    submit_input(tui)
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
          // Ctrl+Home / Ctrl+End：跳到对话的最顶 / 最底。
          match special {
            @events.SpecialKey::Home => tui.scroll = 1000000
            @events.SpecialKey::End => tui.scroll = 0
            _ => handle_special(tui, special)
          }
        _ => handle_special(tui, special)
      }
  }
}

///|
fn handle_special(tui : TuiState, special : @events.SpecialKey) -> Unit {
  match special {
    @events.SpecialKey::Enter => submit_input(tui)
    @events.SpecialKey::Escape =>
      if tui.busy {
        tui.abort = true
        set_notice(tui, "正在中断…")
      } else {
        clear_input(tui)
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
      tui.scroll = tui.scroll + max_int(tui.height / 2, 1)
    @events.SpecialKey::PageDown =>
      tui.scroll = max_int(tui.scroll - max_int(tui.height / 2, 1), 0)
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
fn submit_input(tui : TuiState) -> Unit {
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
  tui.commands.push(Submit(text))
  if tui.busy {
    set_notice(tui, "已排队：本回合结束后发送")
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
  } else {
    set_notice(tui, "未知命令：" + text)
  }
}

///|
async fn tui_driver(
  agent : @runtime.Agent,
  tui : TuiState,
  compact_enabled : Bool,
) -> Unit {
  while !tui.quit {
    if tui.commands.is_empty() {
      @async.sleep(15)
      continue
    }
    let command = tui.commands.remove(0)
    match command {
      Submit(text) => {
        tui.busy = true
        tui.abort = false
        tui.scroll = 0
        tui.dirty = true
        agent.send(@action.UserMessage({ text, content: [], })) catch {
          err => set_notice(tui, "error: " + err.to_string())
        }
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
    if !tui.notice.is_empty() && now_ms() - tui.notice_at > 5000L {
      tui.notice = ""
      tui.dirty = true
    }
    if tui.dirty {
      tui.dirty = false
      @io.print_raw(app.render_frame(tui_view(tui, agent.state)))
    }
    @async.sleep(16)
  }
}
