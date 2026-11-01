// TCP 连接：native 侧是 moonbitlang/async/socket 的薄包装。
//
// 与 proc_native 的 `Session` 同一角色：把平台能力收成 connect / read_some /
// write / close 四个动作，上层（core/rtools 的远程工具客户端）把它适配成行
// 协议的字节双工。读上的取消（Esc）**原样穿透**，不折成 SysError —— 在这里
// 收窄错误类型等于把取消变成普通错误，cancel 再也掐不断（与 proc 同一坑）。

///|
pub(all) struct TcpConn {
  conn : @socket.Tcp
}

///|
/// 连一台 TCP 服务。失败（地址解析不了 / 拒绝连接 / 网络不可达）折成 SysError。
pub async fn tcp_connect(host : String, port : Int) -> TcpConn raise SysError {
  let conn = @socket.Tcp::connect_to_host(host, port~) catch {
    err => raise SysError(err.to_string())
  }
  { conn, }
}

///|
/// 读一块。`None` = 对端关了流（EOF）。
pub async fn TcpConn::read_some(
  self : TcpConn,
  max_len? : Int = 8192,
) -> Bytes? raise {
  self.conn.read_some(max_len~)
}

///|
pub async fn TcpConn::write(self : TcpConn, text : String) -> Unit raise SysError {
  self.conn.write(text) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub fn TcpConn::close(self : TcpConn) -> Unit {
  self.conn.close()
}
