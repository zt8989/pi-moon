// 标准流：js 侧直接写 Node 的 process.stdout / stderr，读 stdin 用同步读。
//
// 同步读是为 REPL 那一档服务：它在 `await` 之外只做「读一行、打印、再读一行」，
// 用同步 readSync 天然阻塞，比把 readline 的事件循环缝进 async 更简单。

///|
extern "js" fn js_write_out(text : String) -> Bool =
  #| (text) => { try { process.stdout.write(text); return true } catch (e) { return false } }

///|
extern "js" fn js_write_err(text : String) -> Bool =
  #| (text) => { try { process.stderr.write(text); return true } catch (e) { return false } }

///|
extern "js" fn js_stdin_all() -> String =
  #| () => {
  #|   try { return require('node:fs').readFileSync(0, 'utf8') }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return '' }
  #| }

///|
extern "js" fn js_stdin_until(delim : String) -> String? =
  #| (delim) => {
  #|   const fs = require('node:fs')
  #|   const state = globalThis
  #|   if (typeof state.__pi_moon_stdin === 'undefined') {
  #|     state.__pi_moon_stdin = ''
  #|   }
  #|   for (;;) {
  #|     const index = state.__pi_moon_stdin.indexOf(delim)
  #|     if (index >= 0) {
  #|       const line = state.__pi_moon_stdin.slice(0, index + delim.length)
  #|       state.__pi_moon_stdin = state.__pi_moon_stdin.slice(index + delim.length)
  #|       return line
  #|     }
  #|     const buffer = Buffer.alloc(4096)
  #|     let read = 0
  #|     try { read = fs.readSync(0, buffer, 0, buffer.length, null) }
  #|     catch (e) {
  #|       if (e && e.code === 'EAGAIN') { continue }
  #|       if (e && e.code === 'EOF') { read = 0 }
  #|       else { globalThis.__pi_moon_error = String((e && e.message) || e); return null }
  #|     }
  #|     if (read === 0) {
  #|       if (state.__pi_moon_stdin.length === 0) { return null }
  #|       const rest = state.__pi_moon_stdin
  #|       state.__pi_moon_stdin = ''
  #|       return rest
  #|     }
  #|     state.__pi_moon_stdin += buffer.slice(0, read).toString('utf8')
  #|   }
  #| }

///|
pub fn write_out(text : String) -> Unit raise SysError {
  if !js_write_out(text) {
    raise SysError("failed to write to stdout")
  }
}

///|
pub fn write_err(text : String) -> Unit raise SysError {
  if !js_write_err(text) {
    raise SysError("failed to write to stderr")
  }
}

///|
pub async fn read_stdin_all() -> String raise SysError {
  let text = js_stdin_all()
  raise_pending_error()
  text
}

///|
pub async fn read_stdin_until(delim : String) -> String? raise SysError {
  let line = js_stdin_until(delim)
  raise_pending_error()
  line
}
