// 常驻宿主会话：把 `--mode serve` 的 bun 进程包成「发一行、收一行」的 RPC。
//
// 一个会话只服务一个扩展（宿主脚本按 `--path` 装一个）。`ExtRuntime` 是本进程
// 手里的那本名册：按工具名找会话、按事件名广播。
//
// 三条约束（都对应一个具体的坑）：
//   1. **协议是行**：请求 / 响应各一行 JSON，一行可能跨多个管道块，所以读的
//      一侧必须自己攒尾巴（`pending`）。
//   2. **stdout 只走协议**：宿主把 `console.*` 与自身诊断都写成 `{"event":"log"}`
//      行；万一张上还有非 JSON 行（扩展直接 `process.stdout.write`、bun 自己报
//      错），跳过并留作诊断，而不是把整个会话判死。
//   3. **一次只有一条在途请求**：调用点是 effect 里的 `await`，本来就没有并发。
//      所以不需要 id → 等待者的表，`id` 只做自检。

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
  io : @sys.Session
  /// 还没成行的尾巴。
  mut pending : String
  /// 非协议输出（`log` 行、扩展自己写的 stdout），只留最近几条做诊断。
  mut noise : Array[String]
  mut next_id : Int
  mut dead : Bool
}

///|
/// 最多留几条噪音行 —— 诊断够用，且不会随会话变长。
let max_noise : Int = 8

///|
fn push_noise(session : ExtSession, line : String) -> Unit {
  if session.noise.length() >= max_noise {
    let _ = session.noise.remove(0)
  }
  session.noise.push(line)
}

///|
pub fn ExtSession::noise_text(self : ExtSession) -> String {
  self.noise.join("\n")
}

///|
async fn ExtSession::next_line(self : ExtSession) -> String? raise HostError {
  while true {
    match self.pending.find("\n") {
      Some(index) => {
        let line = self.pending[:index].trim(chars="\r \t").to_owned()
        self.pending = self.pending[index + 1:].to_owned()
        break Some(line)
      }
      None => ()
    }
    let chunk = self.io.read_some(max_len=8192) catch {
      error => {
        self.dead = true
        raise HostFailure(
          "读取扩展宿主输出失败：" + error.to_string(),
        )
      }
    }
    match chunk {
      None => {
        self.dead = true
        break None
      }
      Some(bytes) => self.pending = self.pending + @utf8.decode_lossy(bytes)
    }
  } nobreak {
    None
  }
}

///|
/// 收一条协议消息：`log` 行进 noise，其它非 JSON 行也进 noise。
///
/// 返回 `None` 表示宿主已经退出（stdin 那侧读到 EOF）。
async fn ExtSession::next_message(
  self : ExtSession,
) -> Map[String, Json]? raise HostError {
  while true {
    let line = match self.next_line() {
      Some(line) => line
      None => break None
    }
    if line.is_empty() {
      continue
    }
    let parsed = @json.parse(line) catch { _ => Json::null() }
    let fields = match parsed.as_object() {
      Some(fields) => fields
      None => {
        push_noise(self, line)
        continue
      }
    }
    match field_string(fields, "event") {
      Some("log") => {
        push_noise(self, field_string(fields, "text").unwrap_or(line))
        continue
      }
      Some("fatal") => {
        self.dead = true
        let reason = field_string(fields, "error").unwrap_or("未知原因")
        raise HostFailure(
          "扩展宿主报致命错误（" + self.name + "）：" + reason,
        )
      }
      Some("ready") => continue
      _ => break Some(fields)
    }
  } nobreak {
    None
  }
}

///|
fn field_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(value) => value.as_string()
    None => None
  }
}

///|
fn field_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(value) =>
      match value.as_number() {
        Some(number) => Some(number.to_int())
        None => None
      }
    None => None
  }
}

///|
fn field_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(value) => value.as_bool()
    None => None
  }
}

///|
/// 发一条请求并等它的响应。失败（传输错 / 宿主报错）以 `HostError` 上抛，
/// 调用方把它折成一条工具结果。
async fn ExtSession::request(
  self : ExtSession,
  payload : Map[String, Json],
) -> Map[String, Json] raise HostError {
  if self.dead {
    raise HostFailure("扩展宿主已经退出（" + self.name + "）")
  }
  let id = self.next_id
  self.next_id = id + 1
  payload["id"] = Json::number(id.to_double(), repr=id.to_string())
  let line = Json::object(payload).stringify() + "\n"
  self.io.write(line) catch {
    error => {
      self.dead = true
      raise HostFailure(
        "写扩展宿主失败（" + self.name + "）：" + error.to_string(),
      )
    }
  }
  while true {
    let fields = match self.next_message() {
      Some(fields) => fields
      None =>
        raise HostFailure(
          "扩展宿主提前退出（" +
          self.name +
          "）" +
          (match self.noise_text() {
            "" => ""
            noise => "：" + noise
          }),
        )
    }
    // 只有一条在途请求，id 对不上说明上次的响应用剩了 —— 抖掉继续等。
    if field_int(fields, "id") == Some(id) {
      break fields
    }
  } nobreak {
    abort("request：循环不会无 break 地结束")
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
    io,
    pending: "",
    noise: [],
    next_id: 1,
    dead: false,
  }
  // 后面任何一步失败都把宿主收掉 —— 别留一个没人管的 bun 进程。
  errdefer session.io.close()
  let ready = match session.next_message() {
    Some(fields) => fields
    None =>
      raise HostFailure(
        "扩展宿主没有交出注册表就退出了：" + session.name,
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
  match field_bool(response, "ok") {
    Some(true) => ()
    _ =>
      return {
        content: [
          @message.Text(
            "扩展工具失败（" +
            self.name +
            "）：" +
            field_string(response, "error").unwrap_or("未知错误"),
          ),
        ],
        is_error: true,
      }
  }
  match response.get("result") {
    Some(result) => outcome_of(result)
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
/// 把 pi 的工具返回值折成内核的内容块。
///
/// 认的形状：`{ content: [{type:"text"|"image", …}], isError?, details? }`。
/// `details` / 结构化输出先丢掉 —— 内核的 `Content` 只有文本、思考、图片、工具调用。
fn outcome_of(result : Json) -> @tools.ToolOutcome {
  let fields = match result.as_object() {
    Some(fields) => fields
    None =>
      // 有些工具直接返回字符串；不是对象就当作一段文本。
      return {
        content: [
          @message.Text(
            match result.as_string() {
              Some(text) => text
              None => result.stringify()
            },
          ),
        ],
        is_error: false,
      }
  }
  let content : Array[@message.Content] = []
  match fields.get("content") {
    Some(value) =>
      match value.as_array() {
        Some(blocks) =>
          for block in blocks {
            match content_block(block) {
              Some(block) => content.push(block)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  if content.is_empty() {
    content.push(@message.Text("（扩展工具没有输出）"))
  }
  let is_error = match field_bool(fields, "isError") {
    Some(flag) => flag
    None => field_bool(fields, "is_error").unwrap_or(false)
  }
  { content, is_error, }
}

///|
fn content_block(block : Json) -> @message.Content? {
  let fields = match block.as_object() {
    Some(fields) => fields
    None => return None
  }
  match field_string(fields, "type") {
    Some("text") =>
      Some(@message.Text(field_string(fields, "text").unwrap_or("")))
    Some("image") =>
      // pi 的图片块是 `{data, mimeType}`；内核用 data URL 表达同一件事。
      match field_string(fields, "data") {
        Some(data) => {
          let mime = field_string(fields, "mimeType").unwrap_or("image/png")
          Some(@message.Image("data:" + mime + ";base64," + data))
        }
        None => None
      }
    _ => None
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
  self.io.close()
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
/// 吞掉，会话变 `dead` 之后下一次调用会拿到明确的「宿主已经退出」。
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
