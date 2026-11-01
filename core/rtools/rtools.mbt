// 远程工具会话：把一台工具宿主（TCP 行协议）包成「注册表 + 调用」。
//
// 协议在 core/rpc（与传输无关）；这一层的全部状态就是「注册表 + 会话死活」：
//   - `ready`：连接上的第一条消息，注册表（名字 / 描述 / 参数 schema）——
//     与扩展宿主的 ready 同形，模型声明从这里来；
//   - `hello`：握手时把会话元数据（session id / provider / model）发给宿主，
//     宿主把它注入工具环境变量（PI_SESSION_ID 等，与本地执行同口径）；
//   - `call`：一次工具调用，pi 形状的结果折成内核 ToolOutcome
//     （折叠与扩展宿主共用 `@tools.outcome_of`，口径只有一份）。
//
// 三条协议约束（行、一次一条在途、噪音跳过）见 core/rpc，这里不再重复。

///|
/// 远程工具客户端的错误。启动（连接 / 握手）与运行期分开：启动失败是
/// 「这轮远程模式没起来」，调用方的动作是给出诊断；运行期失败折成工具结果。
pub suberror RemoteError {
  /// 连不上 / 握手失败，带 host:port。
  RemoteStartup(String)
  /// 会话运行期失败（对端退出 / fatal / 传输错误）。
  RemoteFailure(String)
}

///|
pub fn RemoteError::to_string(self : RemoteError) -> String {
  match self {
    RemoteStartup(message) => message
    RemoteFailure(message) => message
  }
}

///|
/// 握手时传给宿主的会话元数据。宿主注入工具环境变量（与本地执行同口径）。
pub(all) struct RemoteSessionMeta {
  session_id : String
  provider : String
  model : String
}

///|
/// 一个已就绪的远程工具会话。
pub(all) struct RemoteTools {
  /// host:port（诊断用）。
  address : String
  rpc : @rpc.Session
  /// 注册表：模型声明从这里来。
  mut definitions : Array[@action.PromptToolDefinition]
}

///|
/// TCP 连接 → 字节双工。与扩展宿主的 stdio 适配同一形状；async 调用天生的
/// 环境错误（取消等）在这里就地折成 Err 值。
fn duplex_of(conn : @sys.TcpConn) -> @rpc.Duplex {
  {
    read: async fn(max) {
      try Ok(conn.read_some(max_len=max)) catch { e => Err(e.to_string()) }
    },
    write: async fn(text) {
      try Ok(conn.write(text)) catch { e => Err(e.to_string()) }
    },
    close: fn() { conn.close() },
  }
}

///|
/// 等握手完成的上限（毫秒）。工具宿主不需要构建（对比扩展宿主要跑 Bun.build），
/// 但连一台黑洞地址可能挂到操作系统默认超时 —— 启动必须给出明确诊断。
let startup_timeout_ms : Int = 30000

///|
/// 连上工具宿主并完成握手：读宿主主动发来的 `ready` 注册表，再把会话元数据
/// 以 `hello` 发过去。任何一步失败都抛 `RemoteStartup`（连接由 errdefer 收掉）。
pub async fn RemoteTools::connect(
  host : String,
  port : Int,
  meta : RemoteSessionMeta,
) -> RemoteTools raise RemoteError {
  let address = host + ":" + port.to_string()
  let conn = @sys.tcp_connect(host, port) catch {
    err =>
      raise RemoteStartup(
        "连接工具宿主失败（" + address + "）：" + err.to_string(),
      )
  }
  let session : RemoteTools = {
    address,
    rpc: @rpc.Session::new(duplex_of(conn)),
    definitions: [],
  }
  errdefer session.rpc.close()
  // `ready` 是连接上的第一条消息（宿主 accept 就发）。with_timeout 的 catch
  // 只折措辞；注册表解析与会话突变都发生在值路径上。
  let outcome = @async.with_timeout(startup_timeout_ms, async fn() {
    session.rpc.next_message()
  }) catch {
    @async.TimeoutError =>
      raise RemoteStartup(
        "等工具宿主注册表超时（" +
        address +
        "，" +
        startup_timeout_ms.to_string() +
        "ms）",
      )
    error =>
      raise RemoteStartup(
        "等工具宿主注册表失败（" + address + "）：" + error.to_string(),
      )
  }
  let fields = match outcome {
    Ok(Some(fields)) => fields
    Ok(None) =>
      raise RemoteStartup(
        "工具宿主没有交出注册表就退出了：" +
        address +
        session.noise_suffix(),
      )
    Err(error) =>
      raise RemoteStartup(
        "工具宿主注册表读失败（" + address + "）：" + error.to_string(),
      )
  }
  session.definitions = parse_ready(fields)
  send_hello(session, meta)
  session
}

///|
/// 解析 ready 注册表。形状与扩展宿主一致：
/// `{"event":"ready","ok":true,"tools":[…],"toolDefinitions":[{name,description,parameters}]}`
///
/// `parameters` 宿主回传的是对象，转成 JSON **文本**（与 PromptToolDefinition
/// 同口径：provider 原样塞进请求体的 `function.parameters`）。
fn parse_ready(
  fields : Map[String, Json],
) -> Array[@action.PromptToolDefinition] raise RemoteError {
  match @rpc.field_bool(fields, "ok") {
    Some(true) => ()
    _ =>
      raise RemoteStartup(
        "工具宿主拒绝握手：" +
        @rpc.field_string(fields, "error").unwrap_or("未知错误"),
      )
  }
  let items = match fields.get("toolDefinitions") {
    Some(value) =>
      match value {
        Array(items) => items
        _ => raise RemoteStartup("工具宿主注册表的 toolDefinitions 不是数组")
      }
    None => raise RemoteStartup("工具宿主注册表里没有 toolDefinitions")
  }
  let definitions : Array[@action.PromptToolDefinition] = []
  for item in items {
    let item_fields = match item {
      Object(fields) => fields
      _ => continue
    }
    let name = match @rpc.field_string(item_fields, "name") {
      Some(name) => name
      None => continue
    }
    let description = @rpc.field_string(item_fields, "description").unwrap_or("")
    let parameters = match item_fields.get("parameters") {
      Some(value) =>
        match value {
          String(text) => text
          _ => value.stringify()
        }
      None => "{}"
    }
    definitions.push({ name, description, parameters, })
  }
  definitions
}

///|
/// 发一条请求并等它的响应。失败（传输错 / 宿主报错）以 `RemoteError` 上抛，
/// 调用方把它折成工具结果。协议在 `@rpc.Session::request`（传输错误按值交回），
/// 这里只做措辞与「取消这类环境错误就地折进来」（泛型 raise 的函数体接不住
/// async 调用天生携带的环境错误 —— 与扩展宿主的 `ExtSession::request` 同一坑）。
async fn RemoteTools::request(
  self : RemoteTools,
  payload : Map[String, Json],
) -> Map[String, Json] raise RemoteError {
  let outcome = self.rpc.request(payload) catch {
    error => raise RemoteFailure(error.to_string())
  }
  match outcome {
    Ok(fields) => fields
    Err(error) => raise to_remote_error(self, error)
  }
}

///|
/// 会话元数据握手：`{"op":"hello","session":{…}}`。宿主只回 `ok`，没有别的
/// 可拿 —— 能对上 id 就算送达。
async fn send_hello(
  session : RemoteTools,
  meta : RemoteSessionMeta,
) -> Unit raise RemoteError {
  let content : Map[String, Json] = Map([])
  content["sessionId"] = Json::string(meta.session_id)
  content["provider"] = Json::string(meta.provider)
  content["model"] = Json::string(meta.model)
  let payload : Map[String, Json] = Map([])
  payload["op"] = Json::string("hello")
  payload["session"] = Json::object(content)
  let _ = session.request(payload)
}

///|
/// 最近几条噪音的措辞尾巴（对端退出时带上宿主自己的诊断）。
fn RemoteTools::noise_suffix(self : RemoteTools) -> String {
  match self.rpc.noise_text() {
    "" => ""
    noise => "：" + noise
  }
}

///|
/// 传输层错误 → 客户端措辞。`PeerClosed` 把最近的噪音带上 —— 宿主自己写的
/// 诊断（console 之类）通常就在那里。
fn to_remote_error(session : RemoteTools, error : @rpc.RpcError) -> RemoteError {
  match error {
    @rpc.SessionClosed =>
      RemoteFailure("远程工具宿主已经退出（" + session.address + "）")
    @rpc.TransportWrite(reason) =>
      RemoteFailure(
        "写远程工具宿主失败（" + session.address + "）：" + reason,
      )
    @rpc.TransportRead(reason) =>
      RemoteFailure("读远程工具宿主输出失败：" + reason)
    @rpc.PeerFatal(reason) =>
      RemoteFailure(
        "远程工具宿主报致命错误（" + session.address + "）：" + reason,
      )
    @rpc.PeerClosed =>
      RemoteFailure(
        "远程工具宿主提前退出（" + session.address + "）" + session.noise_suffix(),
      )
  }
}

///|
/// 这个工具名归远程宿主吗。
pub fn RemoteTools::owns(self : RemoteTools, tool_name : String) -> Bool {
  for definition in self.definitions {
    if definition.name == tool_name {
      return true
    }
  }
  false
}

///|
/// 按名字清单从注册表里挑定义 —— 与 `@tools.definitions_for` 同一口径：
/// 输出按**注册表顺序**，选择里多出的未知名字忽略，重复的名字不产生重复
/// 定义。/tools 与启动选择都走这里，开关规则才能「只换声明源」。
pub fn RemoteTools::definitions_for(
  self : RemoteTools,
  names : Array[String],
) -> Array[@action.PromptToolDefinition] {
  let out : Array[@action.PromptToolDefinition] = []
  for definition in self.definitions {
    if names.contains(definition.name) {
      out.push(definition)
    }
  }
  out
}

///|
/// 调一次远程工具。失败折成 `is_error` 的结果 —— 与内置 / 扩展工具同口径：
/// 每个 toolCall 都必须落一条结果，否则下一轮请求就是非法消息序列。
pub async fn RemoteTools::call_tool(
  self : RemoteTools,
  call : @message.ToolCall,
) -> @tools.ToolOutcome {
  self.call(call) catch {
    error => { content: [@message.Text(error.to_string())], is_error: true, }
  }
}

///|
/// 调用的本体：失败以 `RemoteError` 上抛，由 `call_tool` 折成结果。
async fn RemoteTools::call(
  self : RemoteTools,
  call : @message.ToolCall,
) -> @tools.ToolOutcome raise RemoteError {
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
            "远程工具失败（" +
            self.address +
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
        content: [@message.Text("远程工具没有返回结果：" + call.name)],
        is_error: true,
      }
  }
}

///|
pub fn RemoteTools::close(self : RemoteTools) -> Unit {
  self.rpc.close()
}
