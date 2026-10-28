// 子进程：native 侧是 moonbitlang/async 的 process / shell 薄包装。
//
// `OutputPipe` 把「读端 + 写端」收成一个值：调用方只需要把它交给 `spawn`，
// 子进程的 stdout / stderr 就都落到同一根管道上（与 pi 的 merged 输出同形）。

///|
pub(all) struct OutputPipe {
  reader : @process.ReadFromProcess
  writer : &@process.ProcessOutput
}

///|
pub async fn read_from_process() -> OutputPipe raise SysError {
  let (reader, writer) = @process.read_from_process() catch {
    err => raise SysError(err.to_string())
  }
  { reader, writer }
}

///|
pub async fn OutputPipe::read_some(
  self : OutputPipe,
  max_len? : Int = 8192,
) -> Bytes? raise SysError {
  self.reader.read_some(max_len~) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub fn OutputPipe::close(self : OutputPipe) -> Unit {
  self.reader.close()
}

///|
/// 子进程的 stdin：`reader` 交给 `spawn`，`writer` 留给宿主写。
/// 与 `OutputPipe` 对称 —— 「一根管道，两端各一半」。
pub(all) struct InputPipe {
  reader : @pipe.PipeRead
  writer : @pipe.PipeWrite
}

///|
pub async fn write_to_process() -> InputPipe raise SysError {
  let (reader, writer) = @pipe.pipe() catch {
    err => raise SysError(err.to_string())
  }
  { reader, writer }
}

///|
pub async fn InputPipe::write(self : InputPipe, data : String) -> Unit raise SysError {
  self.writer.write(data) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub fn InputPipe::close(self : InputPipe) -> Unit {
  self.writer.close()
}

///|
pub(all) struct Process {
  inner : @process.Process
}

///|
pub fn Process::cancel(self : Process) -> Unit {
  self.inner.cancel()
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
  let process = @process.spawn(
    group,
    program,
    args,
    extra_env~,
    stdin?=stdin.map(fn(pipe) { pipe.reader }),
    stdout?=pipe.map(fn(pipe) { pipe.writer }),
    stderr?=pipe.map(fn(pipe) { pipe.writer }),
    cwd~,
  ) catch {
    err => raise SysError(err.to_string())
  }
  { inner: process }
}

///|
pub async fn Process::wait(self : Process) -> Int {
  self.inner.wait()
}

///|
async fn capture_once(
  program : String,
  args : Array[String],
  cwd : String,
) -> Capture raise SysError {
  let (code, out, err) = @process.collect_output(program, args, cwd~) catch {
    error => raise SysError(error.to_string())
  }
  {
    code,
    out: @utf8.decode_lossy(out.binary()),
    err: @utf8.decode_lossy(err.binary()),
  }
}

///|
/// 一次性命令：stdout / stderr 合并后一起交回（与 shell 的 `output()` 同形）。
///
/// 这里不用 `@shell.Cmd` —— shell 包只支持 native + wasm，js 端根本没有它；
/// 用 `@process.collect_output_merged` 的话，平台层的 import 表在两端都成立。
pub async fn run_capture(
  program : String,
  args : Array[String],
  cwd? : String = ".",
  timeout_ms? : Int,
) -> Capture raise SysError {
  match timeout_ms {
    Some(ms) =>
      @async.with_timeout(ms, async fn() { capture_once(program, args, cwd) }) catch {
        _ => { code: -1, out: "", err: "timeout" }
      }
    None => capture_once(program, args, cwd)
  }
}
