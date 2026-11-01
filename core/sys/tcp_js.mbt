// TCP 连接：js 侧用 Node 的 node:net。
//
// 形状与 native 一致：connect / read_some / write / close。数据到达先进队列，
// 等待者按序取（与 proc_js 的 OutputPipe 同一套模式）；读走 @js_async 的
// Promise，abort 监听器把取消（Esc）原样传出去，取消语义与 native 一致。
// 连接期与运行期的错误都留在 state 上：写失败当场报，读失败由等待者拿到。

///|
#external
pub type JsTcp

///|
pub(all) struct TcpConn {
  socket : JsTcp
}

///|
extern "js" fn js_tcp_state_new() -> JsTcp =
  #| () => ({ socket: null, queue: [], waiters: [], done: false, error: null })

///|
extern "js" fn js_tcp_connect(
  state : JsTcp,
  host : String,
  port : Int,
) -> @js_async.Promise[String] =
  #| (state, host, port) => new Promise((resolve) => {
  #|   try {
  #|     const net = require('node:net')
  #|     const socket = net.connect(port, host.length > 0 ? host : '127.0.0.1')
  #|     state.socket = socket
  #|     const push = (chunk) => {
  #|       const w = state.waiters.shift()
  #|       if (w) { w.resolve(chunk) } else { state.queue.push(chunk) }
  #|     }
  #|     const fail = (e) => {
  #|       state.error = String((e && e.message) || e)
  #|       while (state.waiters.length > 0) { state.waiters.shift().reject(new Error(state.error)) }
  #|     }
  #|     socket.on('data', (d) => push(new Uint8Array(d)))
  #|     socket.on('error', fail)
  #|     socket.on('close', () => {
  #|       state.done = true
  #|       while (state.waiters.length > 0) { state.waiters.shift().resolve(new Uint8Array(0)) }
  #|     })
  #|     socket.once('connect', () => resolve(''))
  #|     socket.once('error', (e) => resolve(String((e && e.message) || e)))
  #|   } catch (e) { resolve(String((e && e.message) || e)) }
  #| })

///|
extern "js" fn js_tcp_read(
  state : JsTcp,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[Bytes] =
  #| (state, signal) => new Promise((resolve, reject) => {
  #|   if (state.queue.length > 0) { resolve(state.queue.shift()); return }
  #|   if (state.error) { reject(new Error(state.error)); return }
  #|   if (state.done) { resolve(new Uint8Array(0)); return }
  #|   const w = { resolve, reject }
  #|   state.waiters.push(w)
  #|   signal.addEventListener('abort', () => {
  #|     const i = state.waiters.indexOf(w)
  #|     if (i >= 0) { state.waiters.splice(i, 1) }
  #|     const err = new Error('aborted')
  #|     err.name = 'AbortError'
  #|     reject(err)
  #|   }, { once: true })
  #| })

///|
extern "js" fn js_tcp_write(state : JsTcp, text : String) -> String =
  #| (state, text) => {
  #|   try {
  #|     if (!state.socket) { return '连接还没建立' }
  #|     if (state.error) { return state.error }
  #|     state.socket.write(text)
  #|     return ''
  #|   } catch (e) { return String((e && e.message) || e) }
  #| }

///|
extern "js" fn js_tcp_close(state : JsTcp) -> Unit =
  #| (state) => { try { if (state.socket) { state.socket.destroy() } } catch (e) {} }

///|
pub async fn tcp_connect(host : String, port : Int) -> TcpConn raise SysError {
  let state = js_tcp_state_new()
  let error = @js_async.Promise::wait(js_tcp_connect(state, host, port)) catch {
    err => raise SysError(err.to_string())
  }
  if !error.is_empty() {
    raise SysError(error)
  }
  { socket: state }
}

///|
/// 读一块，`None` = 对端关了流（EOF）。与 proc 同口径：取消原样穿透，
/// 不在这里折成 SysError。
pub async fn TcpConn::read_some(
  self : TcpConn,
  max_len? : Int = 8192,
) -> Bytes? raise {
  let _ = max_len
  let chunk = @js_async.run_promise(signal => js_tcp_read(self.socket, signal))
  raise_pending_error()
  if chunk.length() == 0 {
    None
  } else {
    Some(chunk)
  }
}

///|
pub async fn TcpConn::write(self : TcpConn, text : String) -> Unit raise SysError {
  let error = js_tcp_write(self.socket, text)
  if !error.is_empty() {
    raise SysError(error)
  }
}

///|
pub fn TcpConn::close(self : TcpConn) -> Unit {
  js_tcp_close(self.socket)
}
