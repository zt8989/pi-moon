// TCP 连接：native 走 moonbitlang/async/socket，js 走 Node 的 node:net。
// 两端跑同一组测试：连一个 node 写的 echo 服务，写、读、关；对端关流后读到
// 尽头；连不上的端口给明确错误。缺 node 时整组跳过 —— 环境缺失，不是回归。

///|
async fn tcp_node_available() -> Bool {
  let probe = run_capture("node", ["--version"], timeout_ms=10000) catch {
    _ => return false
  }
  probe.exit_code() == 0
}

///|
/// 起一个 node 脚本；端口写到哪个文件由 argv[1] 传入（`-e` 模式下
/// `process.argv` 是 `[node, 其后的参数…]`）。端口不能固定 —— 测试并行时
/// 会撞，只有让内核分配（`listen(0)`）再回传才稳。
async fn tcp_spawn(script : String, port_file : String) -> Session {
  spawn_session("node", ["-e", script, port_file], cwd=".")
}

///|
/// 等端口文件出现并读出端口号（脚本在 `listen` 回调里写文件）。
async fn tcp_wait_port(port_file : String) -> Int? {
  for _i in 0..<100 {
    let there = exists(port_file) catch { _ => false }
    if there {
      let text = read_text_lossy(port_file) catch { _ => return None }
      let parsed = @json.parse(text.trim().to_owned()) catch { _ => Json::null() }
      return match parsed {
        Number(n, ..) => Some(n.to_int())
        _ => None
      }
    }
    @async.sleep(50)
  }
  None
}

///|
async fn tcp_port_from(script : String, tag : String) -> (Session, Int) {
  // 端口文件放 `_build/` 下（tools_wbtest 同款）：%TEMP% 在部分 Windows 环境
  // 里 mkdtemp 会 Access denied，仓库内目录没有这个问题。文件名唯一化：文件
  // 是端口就绪的信号，读到旧文件等于连一个已经死掉的服务。目录由 node 脚本
  // 自己建（async/fs 的 js 后端没有 mkdir）。
  let dir = "_build/tcp-e2e"
  let port_file = dir + "/port-" + tag + "-" + now().to_string()
  let io = tcp_spawn(script, port_file) catch { error => fail(error.to_string()) }
  let port = match tcp_wait_port(port_file) {
    Some(port) => port
    None => {
      io.close()
      fail("node 服务没有在 5s 内报出端口")
    }
  }
  (io, port)
}

///|
/// echo 服务：连上就把收到的字节原样写回。TCP server 会一直撑着事件循环，
/// 所以挂在 stdin 上：父进程关掉 stdin（`Session::close`）它就退出 —— 否则
/// 测试进程等子进程的管道 EOF 等到天荒地老。
fn tcp_echo_script() -> String {
  (
    #|const net = require("node:net");
    #|const fs = require("node:fs");
    #|fs.mkdirSync(require("node:path").dirname(process.argv[1]), { recursive: true });
    #|const server = net.createServer((socket) => {
    #|  socket.on("data", (d) => socket.write(d));
    #|  socket.on("error", () => {});
    #|});
    #|server.listen(0, "127.0.0.1", () => {
    #|  fs.writeFileSync(process.argv[1], String(server.address().port));
    #|});
    #|process.stdin.resume();
    #|process.stdin.on("end", () => process.exit(0));
  )
}

///|
async test "TCP：连接 / 写 / 读回显 / 关闭" {
  if !tcp_node_available() {
    return
  }
  let (io, port) = tcp_port_from(tcp_echo_script(), "echo")
  defer io.close()
  let conn = tcp_connect("127.0.0.1", port) catch { error => fail(error.to_string()) }
  conn.write("ping-1\nping-2\n") catch { error => fail(error.to_string()) }
  let chunk = conn.read_some() catch { error => fail(error.to_string()) }
  let text = match chunk {
    Some(bytes) => @utf8.decode_lossy(bytes)
    None => fail("echo 服务应该先回一段数据")
  }
  assert_true(text.contains("ping-1"))
  assert_true(text.contains("ping-2"))
  conn.close()
}

///|
/// 对端回一段就关流：客户端读到数据，再读就是尽头。EOF（`None`）是行协议
/// 会话里「对端提前退出」的来源，这里钉住它的传输语义。
fn tcp_eof_script() -> String {
  (
    #|const net = require("node:net");
    #|const fs = require("node:fs");
    #|fs.mkdirSync(require("node:path").dirname(process.argv[1]), { recursive: true });
    #|const server = net.createServer((socket) => {
    #|  socket.end("bye");
    #|});
    #|server.listen(0, "127.0.0.1", () => {
    #|  fs.writeFileSync(process.argv[1], String(server.address().port));
    #|});
    #|process.stdin.resume();
    #|process.stdin.on("end", () => process.exit(0));
  )
}

///|
async test "TCP：对端关流后读到尽头（None）" {
  if !tcp_node_available() {
    return
  }
  let (io, port) = tcp_port_from(tcp_eof_script(), "eof")
  defer io.close()
  let conn = tcp_connect("127.0.0.1", port) catch { error => fail(error.to_string()) }
  let first = conn.read_some() catch { error => fail(error.to_string()) }
  assert_true(match first {
    Some(bytes) => @utf8.decode_lossy(bytes).contains("bye")
    None => false
  })
  let eof = conn.read_some() catch { error => fail(error.to_string()) }
  assert_true(eof is None)
  conn.close()
}

///|
/// 报完端口立刻停止监听：随后去连就是一个没人听的端口。
fn tcp_refused_script() -> String {
  (
    #|const net = require("node:net");
    #|const fs = require("node:fs");
    #|fs.mkdirSync(require("node:path").dirname(process.argv[1]), { recursive: true });
    #|const server = net.createServer(() => {});
    #|server.listen(0, "127.0.0.1", () => {
    #|  fs.writeFileSync(process.argv[1], String(server.address().port));
    #|  server.close();
    #|});
    #|process.stdin.resume();
    #|process.stdin.on("end", () => process.exit(0));
  )
}

///|
async test "TCP：连接被拒给明确错误" {
  if !tcp_node_available() {
    return
  }
  let (io, port) = tcp_port_from(tcp_refused_script(), "refused")
  defer io.close()
  let message = try {
    let _ = tcp_connect("127.0.0.1", port)
    ""
  } catch {
    error => error.to_string()
  }
  assert_false(message.is_empty())
}
