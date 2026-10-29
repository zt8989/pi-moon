// 子进程：js 侧用 Node 的 child_process。
//
// 形状与 native 一致：`read_from_process()` 拿一根（逻辑上的）管道，
// `spawn` 把子进程的 stdout / stderr 都接到它上面，`read_some` 逐块读，
// `wait` 拿退出码。取消（Esc）靠 abort signal：监听器里 kill 子进程并把
// 等待者拒掉，于是 `@async` 的取消语义在两端一致。

///|
#external
pub type JsPipe

///|
pub struct OutputPipe {
  pipe : JsPipe
}

///|
extern "js" fn js_pipe_new() -> JsPipe =
  #| () => ({ queue: [], done: false, waiters: [], child: null, code: -1 })

///|
extern "js" fn js_spawn(
  pipe : JsPipe,
  stdin_slot : JsPipe,
  program : String,
  args : Array[String],
  extra_env : String,
  cwd : String,
) -> String =
  #| (pipe, stdinSlot, program, args, extra_env, cwd) => {
  #|   try {
  #|     const { spawn } = require('node:child_process')
  #|     const env = Object.assign({}, process.env,
  #|       extra_env ? JSON.parse(extra_env) : {})
  #|     const child = spawn(program, args, {
  #|       cwd: cwd && cwd.length > 0 ? cwd : process.cwd(),
  #|       env,
  #|       stdio: ['pipe', 'pipe', 'pipe'],
  #|     })
  #|     pipe.child = child
  #|     if (stdinSlot) { stdinSlot.child = child }
  #|     const push = (chunk) => {
  #|       const w = pipe.waiters.shift()
  #|       if (w) { w.resolve(chunk) } else { pipe.queue.push(chunk) }
  #|     }
  #|     child.stdout.on('data', (d) => push(new Uint8Array(d)))
  #|     child.stderr.on('data', (d) => push(new Uint8Array(d)))
  #|     child.on('error', (e) => {
  #|       globalThis.__pi_moon_error = String((e && e.message) || e)
  #|       pipe.done = true
  #|       pipe.code = -1
  #|       while (pipe.waiters.length > 0) {
  #|         pipe.waiters.shift().resolve(new Uint8Array(0))
  #|       }
  #|       if (pipe.codeWaiter) { pipe.codeWaiter(pipe.code); pipe.codeWaiter = null }
  #|     })
  #|     child.on('close', (code) => {
  #|       pipe.done = true
  #|       pipe.code = (code === null || code === undefined) ? -1 : code
  #|       while (pipe.waiters.length > 0) {
  #|         pipe.waiters.shift().resolve(new Uint8Array(0))
  #|       }
  #|       if (pipe.codeWaiter) { pipe.codeWaiter(pipe.code); pipe.codeWaiter = null }
  #|     })
  #|     return ''
  #|   } catch (e) { return String((e && e.message) || e) }
  #| }

///|
extern "js" fn js_next(
  pipe : JsPipe,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[Bytes] =
  #| (pipe, signal) => new Promise((resolve, reject) => {
  #|   if (pipe.queue.length > 0) { resolve(pipe.queue.shift()); return }
  #|   if (pipe.done) { resolve(new Uint8Array(0)); return }
  #|   const w = { resolve, reject }
  #|   pipe.waiters.push(w)
  #|   signal.addEventListener('abort', () => {
  #|     const i = pipe.waiters.indexOf(w)
  #|     if (i >= 0) { pipe.waiters.splice(i, 1) }
  #|     try { if (pipe.child) { pipe.child.kill() } } catch (e) {}
  #|     const err = new Error('aborted')
  #|     err.name = 'AbortError'
  #|     reject(err)
  #|   }, { once: true })
  #| })

///|
extern "js" fn js_wait(pipe : JsPipe) -> @js_async.Promise[Int] =
  #| (pipe) => new Promise((resolve) => {
  #|   if (pipe.done) { resolve(pipe.code) } else { pipe.codeWaiter = resolve }
  #| })

///|
extern "js" fn js_kill(pipe : JsPipe) -> Unit =
  #| (pipe) => { try { if (pipe.child) { pipe.child.kill() } } catch (e) {} }

///|
extern "js" fn js_capture(
  program : String,
  args : Array[String],
  extra_env : String,
  cwd : String,
  timeout_ms : Int,
) -> @js_async.Promise[Array[String]] =
  #| (program, args, extra_env, cwd, timeout_ms) => new Promise((resolve) => {
  #|   const done = (code, out, err) => resolve([String(code), out, err])
  #|   try {
  #|     const { spawn } = require('node:child_process')
  #|     const env = Object.assign({}, process.env,
  #|       extra_env ? JSON.parse(extra_env) : {})
  #|     const child = spawn(program, args, {
  #|       cwd: cwd && cwd.length > 0 ? cwd : process.cwd(),
  #|       env,
  #|       stdio: ['pipe', 'pipe', 'pipe'],
  #|     })
  #|     const out_chunks = []
  #|     const err_chunks = []
  #|     let settled = false
  #|     const finish = (code, err) => {
  #|       if (settled) { return }
  #|       settled = true
  #|       done(
  #|         code,
  #|         Buffer.concat(out_chunks).toString('utf8'),
  #|         err || Buffer.concat(err_chunks).toString('utf8'),
  #|       )
  #|     }
  #|     child.stdout.on('data', (d) => out_chunks.push(d))
  #|     child.stderr.on('data', (d) => err_chunks.push(d))
  #|     child.on('error', (e) => finish(-1, String((e && e.message) || e)))
  #|     child.on('close', (code) => finish((code === null || code === undefined) ? -1 : code, ''))
  #|     if (timeout_ms > 0) {
  #|       setTimeout(() => {
  #|         if (settled) { return }
  #|         try { child.kill() } catch (e) {}
  #|         finish(-1, 'timeout')
  #|       }, timeout_ms)
  #|     }
  #|   } catch (e) { done(-1, '', String((e && e.message) || e)) }
  #| })

///|
fn env_json(extra_env : Map[String, String]) -> String {
  if extra_env.is_empty() {
    return ""
  }
  let object : Map[String, Json] = Map([])
  for key, value in extra_env {
    object[key] = Json::string(value)
  }
  Json::object(object).stringify()
}

///|
fn parse_int(text : String) -> Int {
  let mut sign = 1
  let mut index = 0
  if text.length() > 0 && text[0] == '-' {
    sign = -1
    index = 1
  }
  let mut value = 0
  while index < text.length() {
    let c = text[index]
    if c < '0' || c > '9' {
      break
    }
    value = value * 10 + (c.to_int() - 48)
    index = index + 1
  }
  value * sign
}

///|
pub async fn read_from_process() -> OutputPipe raise SysError {
  { pipe: js_pipe_new() }
}

///|
pub async fn OutputPipe::read_some(
  self : OutputPipe,
  max_len? : Int = 8192,
) -> Bytes? raise {
  let _ = max_len
  // 不 catch：取消（Esc）要原样传出去，让 `@async` 的取消语义与 native 一致
  // （abort 监听器会在 errdefer 里 kill 子进程）。
  let chunk = @js_async.run_promise(signal => js_next(self.pipe, signal))
  raise_pending_error()
  if chunk.length() == 0 {
    None
  } else {
    Some(chunk)
  }
}

///|
pub fn OutputPipe::close(self : OutputPipe) -> Unit {
  js_kill(self.pipe)
}

///|
pub struct Process {
  pipe : JsPipe
}

///|
pub fn Process::cancel(self : Process) -> Unit {
  js_kill(self.pipe)
}

///|
/// 子进程的 stdin。js 侧没有真正的 fd：写的是 node 的 `child.stdin`。
pub(all) struct InputPipe {
  pipe : JsPipe
}

///|
pub async fn write_to_process() -> InputPipe raise SysError {
  { pipe: js_pipe_new() }
}

///|
extern "js" fn js_write_stdin(pipe : JsPipe, data : String) -> String =
  #| (pipe, data) => {
  #|   try {
  #|     if (!pipe.child || !pipe.child.stdin) { return 'stdin 不可用' }
  #|     pipe.child.stdin.write(data)
  #|     return ''
  #|   } catch (e) { return String((e && e.message) || e) }
  #| }

///|
pub async fn InputPipe::write(self : InputPipe, data : String) -> Unit raise SysError {
  let error = js_write_stdin(self.pipe, data)
  if !error.is_empty() {
    raise SysError(error)
  }
}

///|
/// stdin 收尾：`end()` 让宿主的读循环看到 EOF（关掉之后 `write` 不再有效）。
extern "js" fn js_stdin_end(pipe : JsPipe) -> Unit =
  #| (pipe) => { try { if (pipe.child && pipe.child.stdin) { pipe.child.stdin.end() } } catch (e) {} }

///|
pub fn InputPipe::close(self : InputPipe) -> Unit {
  js_stdin_end(self.pipe)
}

///|
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  program : String,
  args : Array[String],
  extra_env? : Map[String, String] = Map([]),
  pipe? : OutputPipe,
  stdin? : InputPipe,
  cwd? : String = ".",
) -> Process raise SysError {
  let _ = group
  let pipe = match pipe {
    Some(pipe) => pipe
    None => { pipe: js_pipe_new() }
  }
  // js 侧 stdout/stderr 走一根队列，stdin 写的是同一个 child 的 stdin：
  // 把 child 也挂到 stdin 的槽上，`InputPipe::write` 才有东西可写。
  let stdin_slot = match stdin {
    Some(stdin) => stdin.pipe
    None => js_pipe_new()
  }
  let error = js_spawn(pipe.pipe, stdin_slot, program, args, env_json(extra_env), cwd)
  if !error.is_empty() {
    raise SysError(error)
  }
  { pipe: pipe.pipe }
}

///|
pub async fn Process::wait(self : Process) -> Int {
  @js_async.Promise::wait(js_wait(self.pipe))
}

///|
/// 常驻子进程（扩展宿主）：形状与 native 一致。
pub(all) struct Session {
  stdin : InputPipe
  output : OutputPipe
}

///|
pub async fn spawn_session(
  program : String,
  args : Array[String],
  extra_env? : Map[String, String] = Map([]),
  cwd? : String = ".",
) -> Session raise SysError {
  let output : OutputPipe = { pipe: js_pipe_new() }
  let stdin : InputPipe = { pipe: js_pipe_new() }
  let error = js_spawn(output.pipe, stdin.pipe, program, args, env_json(extra_env), cwd)
  if !error.is_empty() {
    raise SysError(error)
  }
  { stdin, output }
}

///|
pub fn Session::close(self : Session) -> Unit {
  self.stdin.close()
}

///|
pub async fn Session::write(self : Session, text : String) -> Unit raise SysError {
  self.stdin.write(text)
}

///|
pub async fn Session::read_some(
  self : Session,
  max_len? : Int = 8192,
) -> Bytes? raise SysError {
  self.output.read_some(max_len~)
}

///|
pub async fn run_capture(
  program : String,
  args : Array[String],
  cwd? : String = ".",
  timeout_ms? : Int,
) -> Capture raise SysError {
  let timeout = match timeout_ms {
    Some(value) => value
    None => 0
  }
  let result = @js_async.Promise::wait(
    js_capture(program, args, env_json(Map([])), cwd, timeout),
  ) catch {
    err => raise SysError(err.to_string())
  }
  let error = if result.length() > 2 { result[2] } else { "" }
  {
    code: parse_int(result[0]),
    out: if result.length() > 1 { result[1] } else { "" },
    err: error,
  }
}
