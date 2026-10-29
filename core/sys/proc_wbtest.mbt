// 子进程 stdin 的冒烟测试：宿主（扩展 RPC）依赖「能往子进程里写」。
// 用一个最小程序做对端：`cat` 把 stdin 原样吐回 stdout。

///|
async fn read_until_newline(pipe : OutputPipe, collected : StringBuilder) -> String {
  let mut attempts = 0
  while attempts < 50 {
    let text = collected.to_string()
    if text.contains("\n") {
      return text
    }
    let chunk = pipe.read_some(max_len=4096) catch { _ => None }
    match chunk {
      None => return collected.to_string()
      Some(bytes) => {
        collected.write_string(@utf8.decode_lossy(bytes))
      }
    }
    attempts = attempts + 1
  }
  collected.to_string()
}

///|
async test "#sys.stdin：写进子进程、能从 stdout 读回来" {
  let result = @async.with_task_group(async fn(group) {
    let pipe = read_from_process() catch {
      err => return "pipe 失败：" + err.to_string()
    }
    defer pipe.close()
    let stdin = write_to_process() catch {
      err => return "stdin 失败：" + err.to_string()
    }
    let process = spawn(group, "cat", [], pipe~, stdin~) catch {
      err => return "spawn 失败：" + err.to_string()
    }
    stdin.write("hello from stdin\n") catch {
      err => return "写失败：" + err.to_string()
    }
    stdin.close()
    let collected = StringBuilder()
    let text = read_until_newline(pipe, collected)
    let _ = process.wait()
    text
  })
  assert_true(result.contains("hello from stdin"))
}

///|
/// 常驻子进程：`spawn_session` 的 stdin 必须一直开着（关了宿主就退出了），
/// 输出从同一根管道读。对端还是 `cat`：写进去什么就该读回什么。
async test "#sys.spawn_session：常驻子进程的 stdin 不会立刻 EOF" {
  let result = @async.with_task_group(async fn(_group) {
    let session = spawn_session("cat", [], cwd=".") catch {
      err => return "spawn 失败：" + err.to_string()
    }
    session.write("hello from session\n") catch {
      err => return "写失败：" + err.to_string()
    }
    let collected = StringBuilder()
    let text = read_until_newline(session.output, collected) catch {
      err => return "读失败：" + err.to_string()
    }
    session.close()
    text
  })
  assert_true(result.contains("hello from session"))
}
