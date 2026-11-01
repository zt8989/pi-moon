// 行协议 RPC —— 「发一行、收一行」的会话，与传输无关。
//
// 从扩展宿主的 stdio 实现里抽出来（prefactor，issue #2）：协议（跨块攒尾巴、
// log 噪音、一次一条在途、id 自检、fatal 语义）与承载（stdio / TCP / 内存）
// 分开 —— 未来的 TCP 客户端插上同一个会话，不复制第二份协议。
//
// 三条约束（都对应一个具体的坑，见 docs/extensions.md）：
//   1. **协议是行**：请求 / 响应各一行 JSON，一行可能跨多个管道块，读的一侧
//      必须自己攒尾巴（`pending`）。
//   2. **对端只走协议**：`console.*` 与自身诊断都写成 `{"event":"log"}` 行；
//      万一还有非 JSON 行，跳过并留作诊断，而不是把会话判死。
//   3. **一次只有一条在途请求**：调用点是 effect 里的 `await`，本来就没有并发；
//      `id` 只做自检（对不上说明上一轮的响应有剩，抖掉继续等）。

///|
/// 字节双工：协议会话对传输的全部要求。
/// `read` 的 `Ok(None)` 表示对端 EOF；`Err` 带底层错误的可读描述（会话标死）。
/// 传输错误是**值**不是异常；`raise` 只承载取消这类环境错误（与 async 调用
/// 天生携带的一样），协议会话不接它，原样穿透。
pub(all) struct Duplex {
  read : async (Int) -> Result[Bytes?, String] raise
  write : async (String) -> Result[Unit, String] raise
  close : () -> Unit
}

///|
/// 传输层错误。措辞由调用方包装（扩展宿主 / 工具宿主各有各的说法）。
pub suberror RpcError {
  /// 会话已死还来调用。
  SessionClosed
  /// 写失败，带底层错误。
  TransportWrite(String)
  /// 读失败，带底层错误。
  TransportRead(String)
  /// 对端报了 `{"event":"fatal"}`，带原因。
  PeerFatal(String)
  /// 等响应时对端 EOF。
  PeerClosed
}

///|
pub fn RpcError::to_string(self : RpcError) -> String {
  match self {
    SessionClosed => "行协议会话已经退出"
    TransportWrite(reason) => "写行协议会话失败：" + reason
    TransportRead(reason) => "读行协议会话失败：" + reason
    PeerFatal(reason) => "行协议对端报致命错误：" + reason
    PeerClosed => "行协议对端提前退出"
  }
}

///|
/// 一个行协议会话。状态就是「攒尾巴 + 噪音 + id + 死活」—— 协议的全部。
pub struct Session {
  io : Duplex
  /// 还没成行的尾巴。
  mut pending : String
  /// 非协议输出（`log` 行、对端自己写的 stdout），只留最近几条做诊断。
  noise : Array[String]
  mut next_id : Int
  mut dead : Bool
}

///|
pub fn Session::new(io : Duplex) -> Session {
  { io: io, pending: "", noise: [], next_id: 1, dead: false }
}

///|
pub fn Session::is_dead(self : Session) -> Bool {
  self.dead
}

///|
pub fn Session::noise_text(self : Session) -> String {
  self.noise.join("\n")
}

///|
/// 收尾：关传输。对端读到尽头后自己退。
pub fn Session::close(self : Session) -> Unit {
  (self.io.close)()
}

///|
/// 最多留几条噪音行 —— 诊断够用，且不会随会话变长。
let max_noise : Int = 8

///|
fn Session::push_noise(self : Session, line : String) -> Unit {
  if self.noise.length() >= max_noise {
    let _ = self.noise.remove(0)
  }
  self.noise.push(line)
}

///|
pub fn field_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(json) => if json is String(text) { Some(text) } else { None }
    None => None
  }
}

///|
pub fn field_int(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(json) => if json is Number(number, ..) { Some(number.to_int()) } else { None }
    None => None
  }
}

///|
pub fn field_bool(fields : Map[String, Json], key : String) -> Bool? {
  match fields.get(key) {
    Some(json) =>
      if json is True {
        Some(true)
      } else if json is False {
        Some(false)
      } else {
        None
      }
    None => None
  }
}

///|
/// 读一块输出。async 调用天生可能抛环境错误（取消等）——在这里就地折成
/// `Err` 值，调用方只见普通返回（同一帧里 catch 过之后再突变 self 不可靠，
/// 见 rpc_wbtest 的传输失败用例）。
async fn Session::read_chunk(self : Session) -> Result[Bytes?, String] {
  (self.io.read)(8192) catch { e => Err(e.to_string()) }
}

///|
/// 写一行。同 `read_chunk`：环境错误就地折成 `Err` 值。
async fn Session::write_line(
  self : Session,
  line : String,
) -> Result[Unit, String] {
  (self.io.write)(line) catch { e => Err(e.to_string()) }
}

///|
/// 读一行协议（跨块攒尾巴）。传输失败标死会话并交回 `Err`；EOF 交回 `Ok(None)`
/// （也标死）。
async fn Session::next_line(self : Session) -> Result[String?, RpcError] {
  while true {
    match self.pending.find("\n") {
      Some(index) => {
        let line = self.pending[:index].trim(chars="\r \t").to_owned()
        self.pending = self.pending[index + 1:].to_owned()
        break Ok(Some(line))
      }
      None => ()
    }
    let chunk = match self.read_chunk() {
      Err(reason) => {
        self.dead = true
        break Err(TransportRead(reason))
      }
      Ok(chunk) => chunk
    }
    match chunk {
      None => {
        self.dead = true
        break Ok(None)
      }
      Some(bytes) => self.pending = self.pending + @utf8.decode_lossy(bytes)
    }
  } nobreak {
    abort("next_line：循环不会无 break 地结束")
  }
}

///|
/// 收一条协议消息：`log` 行进噪音，其它非 JSON 行也进噪音。
///
/// `Ok(None)` 表示对端已经退出（读到 EOF）。
pub async fn Session::next_message(
  self : Session,
) -> Result[Map[String, Json]?, RpcError] {
  while true {
    let line = match self.next_line() {
      Ok(Some(line)) => line
      Ok(None) => break Ok(None)
      Err(e) => break Err(e)
    }
    if line.is_empty() {
      continue
    }
    let parsed = @json.parse(line) catch { _ => Json::null() }
    let fields = if parsed is Object(fields) {
      fields
    } else {
      self.push_noise(line)
      continue
    }
    match field_string(fields, "event") {
      Some("log") => {
        self.push_noise(field_string(fields, "text").unwrap_or(line))
        continue
      }
      Some("fatal") => {
        self.dead = true
        break Err(
          PeerFatal(field_string(fields, "error").unwrap_or("未知原因")),
        )
      }
      // `ready` 与普通响应一样「是一条消息」——装载那一下的注册表就是它送来的。
      _ => break Ok(Some(fields))
    }
  } nobreak {
    abort("next_message：循环不会无 break 地结束")
  }
}

///|
/// 发一条请求并等它的响应。失败（传输错 / 对端报错 / 对端退出）以 `Err(RpcError)`
/// 交回 —— 错误是值，调用方包装成自己的措辞。
pub async fn Session::request(
  self : Session,
  payload : Map[String, Json],
) -> Result[Map[String, Json], RpcError] {
  if self.dead {
    return Err(SessionClosed)
  }
  let id = self.next_id
  self.next_id = id + 1
  payload["id"] = Json::number(id.to_double(), repr=id.to_string())
  let line = Json::object(payload).stringify() + "\n"
  match self.write_line(line) {
    Err(reason) => {
      self.dead = true
      return Err(TransportWrite(reason))
    }
    Ok(_) => ()
  }
  while true {
    let fields = match self.next_message() {
      Ok(Some(fields)) => fields
      Ok(None) => return Err(PeerClosed)
      Err(e) => return Err(e)
    }
    // 只有一条在途请求，id 对不上说明上次的响应用剩了 —— 抖掉继续等。
    if field_int(fields, "id") == Some(id) {
      return Ok(fields)
    }
  } nobreak {
    abort("request：循环不会无 break 地结束")
  }
}
