// 终端与进程退出：native 侧是 tty.c 的 C 边。
//
// `is_tty` 只问 stdin / stdout 本身 —— tui 的 `@io.is_tty()` 在 Windows 上会退到
// CONIN$，管道输入时也返回 true，用它判断「要不要进全屏」会把
// `cat prompt.txt | pi-moon` 变成 TUI。

///|
extern "c" fn pi_stdin_is_tty() -> Int32 = "pi_stdin_is_tty"

///|
extern "c" fn pi_stdout_is_tty() -> Int32 = "pi_stdout_is_tty"

///|
extern "c" fn pi_enable_vt_output() -> Unit = "pi_enable_vt_output"

///|
extern "c" fn pi_restore_vt_output() -> Unit = "pi_restore_vt_output"

///|
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
pub fn stdin_is_tty() -> Bool {
  pi_stdin_is_tty() != 0
}

///|
pub fn stdout_is_tty() -> Bool {
  pi_stdout_is_tty() != 0
}

///|
pub fn enable_vt_output() -> Unit {
  pi_enable_vt_output()
}

///|
pub fn restore_vt_output() -> Unit {
  pi_restore_vt_output()
}

///|
pub fn exit_with(code : Int) -> Unit {
  c_exit(code)
}

///|
/// native 的 argv[0] 是可执行文件本身。
fn args_skip() -> Int {
  1
}
