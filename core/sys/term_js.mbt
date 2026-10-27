// 终端与进程退出：js 侧全交给 Node。
//
// VT 输出不用自己开：Node / libuv 在 stdout 是 TTY 时会打开
// ENABLE_VIRTUAL_TERMINAL_PROCESSING，控制台代码页也由 Node 自己按 UTF-16 →
// 控制台 API 处理，所以 `enable_vt_output` 在 js 上是空的。

///|
extern "js" fn js_stdin_tty() -> Bool =
  #| () => !!globalThis.process.stdin.isTTY

///|
extern "js" fn js_stdout_tty() -> Bool =
  #| () => !!globalThis.process.stdout.isTTY

///|
extern "js" fn js_exit(code : Int) -> Unit =
  #| (code) => process.exit(code)

///|
pub fn stdin_is_tty() -> Bool {
  js_stdin_tty()
}

///|
pub fn stdout_is_tty() -> Bool {
  js_stdout_tty()
}

///|
pub fn enable_vt_output() -> Unit {}

///|
pub fn restore_vt_output() -> Unit {}

///|
pub fn exit_with(code : Int) -> Unit {
  js_exit(code)
}

///|
/// node 的 argv 是 [解释器, 脚本, 用户参数...]。
fn args_skip() -> Int {
  2
}
