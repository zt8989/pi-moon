// 常驻宿主会话：把 `--mode serve` 的 bun 进程包成「发一行、收一行」的 RPC。
//
// 协议本体在 core/rpc（与传输无关，issue #2 抽出）；这一层只剩：
//   - 扩展注册表（工具 / 命令 / 事件 / 工具定义）；
//   - `call` / `emit` 的载荷拼装与返回值折叠；
//   - 「stdio → 字节双工」的适配，以及传输层错误 → 宿主措辞的映射。
//
// 协议的三条约束（行、一次一条在途、噪音跳过）见 core/rpc，这里不再重复。

///|
/// 一个已就绪的扩展会话。
pub(all) struct ExtSession {
  name : String
  /// 这个扩展注册的工具名。
  mut tools : Array[String]
  /// 工具定义的完整版（名字 / 描述 / 参数 schema）。
  mut tool_definitions : Array[ExtToolDefinition]
  mut commands : Array[String]
  /// 这个扩展挂了钩子的事件名。
  mut events : Array[String]
  /// 用了但 pi-moon 没实现的宿主 API（仅诊断）。
  mut unsupported : Array[String]
  /// 被沙盒拦下的路径访问（仅诊断）。
  mut denied : Array[String]
  /// 这次是不是重新构建的（false = 命中产物缓存）。
  mut built : Bool
  /// 宿主装载耗时（毫秒）。
  mut ms : Int
  /// 行协议会话（传输无关；stdio 由 `start` 经 `duplex_of` 装进来）。
  rpc : @rpc.Session
}

///|
/// stdio 会话 → 字节双工。协议会话对传输的全部要求只有读 / 写 / 关；
/// async 调用天生的环境错误（取消等）在这里就地折成 `Err` 值。
fn duplex_of(io : @sys.Session) -> @rpc.Duplex {
  {
    read: async fn(max) {
      try Ok(io.read_some(max_len=max)) catch { e => Err(e.to_string()) }
    },
    write: async fn(text) {
      try Ok(io.write(text)) catch { e => Err(e.to_string()) }
    },
    close: fn() { io.close() },
  }
}

///|
/// 传输层错误 → 宿主措辞。措辞与抽取前逐字一致。
fn to_host_error(session : ExtSession, error : @rpc.RpcError) -> HostError {
  match error {
    SessionClosed => HostFailure("扩展宿主已经退出（" + session.name + "）")
    TransportWrite(reason) =>
      HostFailure("写扩展宿主失败（" + session.name + "）：" + reason)
    TransportRead(reason) => HostFailure("读取扩展宿主输出失败：" + reason)
    PeerFatal(reason) =>
      HostFailure("扩展宿主报致命错误（" + session.name + "）：" + reason)
    PeerClosed =>
      HostFailure(
        "扩展宿主提前退出（" +
        session.name +
        "）" +
        (match session.rpc.noise_text() {
          "" => ""
          noise => "：" + noise
        }),
      )
  }
}

///|
/// 非协议输出（`log` 行、扩展自己写的 stdout），只留最近几条做诊断。
pub fn ExtSession::noise_text(self : ExtSession) -> String {
  self.rpc.noise_text()
}

///|
/// 等宿主交出注册表的上限（毫秒）。首次装载要跑 Bun.build，实测 10s 上下。
let start_timeout_ms : Int = 120000

///|
/// 发一条请求并等它的响应。失败（传输错 / 宿主报错）以 `HostError` 上抛，
/// 调用方把它折成一条工具结果。协议在 `@rpc.Session::request`，这里只做措辞。
async fn ExtSession::request(
  self : ExtSession,
  payload : Map[String, Json],
) -> Map[String, Json] raise HostError {
  let outcome = self.rpc.request(payload) catch {
    // 运行期到不了：core/rpc 的传输错误按值交回，这里只为穷尽性兜底。
    error => raise HostFailure(error.to_string())
  }
  match outcome {
    Ok(fields) => fields
    Err(error) => raise to_host_error(self, error)
  }
}

///|
/// 起一个常驻宿主，等它把注册表（`ready`）交出来。
///
/// `--mode serve` 自己做「打包（命中缓存则跳过）→ 加载 → 回传注册表 → 进读
/// 循环」，所以启动这一下同时也是一次装载。
pub async fn ExtSession::start(
  paths : HostPaths,
  source : ExtSource,
  cache_key : String,
) -> ExtSession raise HostError {
  if paths.bun_missing() {
    raise NoBun
  }
  let io = @sys.spawn_session(
    paths.bun,
    [
      paths.script,
      "--root",
      paths.root,
      "--modules",
      paths.modules,
      "--cwd",
      paths.cwd,
      "--agent",
      paths.agent_dir,
      "--path",
      absolute(source.path),
      "--key",
      cache_key,
      "--name",
      source.name,
      "--mode",
      "serve",
    ],
    cwd=paths.root,
  ) catch {
    error => raise HostStartup(error.to_string())
  }
  let session : ExtSession = {
    name: source.name,
    tools: [],
    tool_definitions: [],
    commands: [],
    events: [],
    unsupported: [],
    denied: [],
    built: false,
    ms: 0,
    rpc: @rpc.Session::new(duplex_of(io)),
  }
  // 后面任何一步失败都把宿主收掉 —— 别留一个没人管的 bun 进程。
  errdefer session.rpc.close()
  // 等注册表要设上限：首次要跑 Bun.build（实测 10s 上下），但接口卡死时
  // 不该把整个 pi-moon 一起挂在那里（与运行期 call 不同 —— 那里打断就会
  // 丢掉一个工具结果，这里只是启动）。
  let ready_message = @async.with_timeout(start_timeout_ms, async fn() {
    let outcome = session.rpc.next_message() catch {
      // 运行期到不了：core/rpc 的传输错误按值交回，这里只为穷尽性兜底。
      error => raise HostFailure(error.to_string())
    }
    match outcome {
      Ok(fields) => fields
      Err(error) => raise to_host_error(session, error)
    }
  }) catch {
    error =>
      raise HostFailure(
        "等扩展宿主注册表超时（" +
        session.name +
        "，" +
        start_timeout_ms.to_string() +
        "ms）：" +
        error.to_string(),
      )
  }
  let ready = match ready_message {
    Some(fields) => fields
    None =>
      raise HostFailure(
        "扩展宿主没有交出注册表就退出了：" +
        session.name +
        (match session.rpc.noise_text() {
          "" => ""
          noise => "：" + noise
        }),
      )
  }
  let loaded = parse_fields(ready)
  session.tools = loaded.tools
  session.tool_definitions = loaded.tool_definitions
  session.commands = loaded.commands
  session.events = loaded.events
  session.unsupported = loaded.unsupported
  session.denied = loaded.denied
  session.built = loaded.built
  session.ms = loaded.ms
  session
}

///|
/// 调一次扩展工具。任何失败都变成 `is_error` 的结果 —— 与内置工具同口径：
/// 每个 toolCall 都必须落一条结果，否则下一轮请求就是非法消息序列。
pub async fn ExtSession::call(
  self : ExtSession,
  call : @message.ToolCall,
) -> @tools.ToolOutcome raise HostError {
  let args = @json.parse(call.arguments) catch { _ => Json::object(Map([])) }
  let payload : Map[String, Json] = Map([])
  payload["op"] = Json::string("call")
  payload["tool"] = Json::string(call.name)
  payload["toolCallId"] = Json::string(call.id)
  payload["args"] = args
  let response = self.request(payload)
  match @rpc.field_bool(response, "ok") {
    Some(true) => ()
    _ =>
      return {
        content: [
          @message.Text(
            "扩展工具失败（" +
            self.name +
            "）：" +
            @rpc.field_string(response, "error").unwrap_or("未知错误"),
          ),
        ],
        is_error: true,
      }
  }
  match response.get("result") {
    Some(result) => @tools.outcome_of(result)
    None =>
      {
        content: [
          @message.Text("扩展工具没有返回结果：" + call.name),
        ],
        is_error: true,
      }
  }
}

///|
/// 派一次事件给这个会话的钩子。返回值的处理交给调用方决定 —— 这里只保证
/// 「发出去了、宿主收下了」。
pub async fn ExtSession::emit(
  self : ExtSession,
  event : String,
  payload : Json,
) -> Unit raise HostError {
  let request : Map[String, Json] = Map([])
  request["op"] = Json::string("emit")
  request["event"] = Json::string(event)
  request["payload"] = payload
  let _ = self.request(request)
}

///|
pub fn ExtSession::close(self : ExtSession) -> Unit {
  self.rpc.close()
}

///|
/// 本进程手里的全部扩展会话。
pub(all) struct ExtRuntime {
  sessions : Array[ExtSession]
}

///|
pub fn ExtRuntime::new() -> ExtRuntime {
  { sessions: [], }
}

///|
pub fn ExtRuntime::is_empty(self : ExtRuntime) -> Bool {
  self.sessions.is_empty()
}

///|
pub fn ExtRuntime::push(self : ExtRuntime, session : ExtSession) -> Unit {
  self.sessions.push(session)
}

///|
/// 这个工具名归扩展吗。
pub fn ExtRuntime::owns(self : ExtRuntime, tool_name : String) -> Bool {
  for session in self.sessions {
    if session.tools.contains(tool_name) {
      return true
    }
  }
  false
}

///|
/// 有没有哪个会话挂了这个事件的钩子。
pub fn ExtRuntime::listens(self : ExtRuntime, event : String) -> Bool {
  for session in self.sessions {
    if session.events.contains(event) {
      return true
    }
  }
  false
}

///|
/// 工具名 → 注册它的那个会话。
fn ExtRuntime::session_for(
  self : ExtRuntime,
  tool_name : String,
) -> ExtSession? {
  for session in self.sessions {
    if session.tools.contains(tool_name) {
      return Some(session)
    }
  }
  None
}

///|
/// 跑一次扩展工具调用（名字不属于任何扩展时返回错误结果）。
pub async fn ExtRuntime::call_tool(
  self : ExtRuntime,
  call : @message.ToolCall,
) -> @tools.ToolOutcome {
  let session = match self.session_for(call.name) {
    Some(session) => session
    None =>
      return {
        content: [@message.Text("没有扩展注册工具 " + call.name)],
        is_error: true,
      }
  }
  session.call(call) catch {
    error => { content: [@message.Text(error.to_string())], is_error: true, }
  }
}

///|
/// 广播一个事件：只发给挂了该钩子的会话（没挂的会话不该为一次空派发付一次往返）。
///
/// **钩子失败不掐回合**：pi 里同样的钩子抛错也只影响它自己。这里把传输错
/// 吞掉，会话变死之后下一次调用会拿到明确的「宿主已经退出」。
pub async fn ExtRuntime::emit(
  self : ExtRuntime,
  event : String,
  payload : Json,
) -> Unit {
  for session in self.sessions {
    if !session.events.contains(event) {
      continue
    }
    session.emit(event, payload) catch {
      _ => ()
    }
  }
}

///|
pub fn ExtRuntime::close(self : ExtRuntime) -> Unit {
  for session in self.sessions {
    session.close()
  }
  self.sessions.clear()
}
