// 两端共用的形状。这里不碰任何平台 API —— 具体的 read/write/spawn 在
// `*_native.mbt` / `*_js.mbt` 里各写一遍。

///|
/// 文件种类：上层只按「文件 / 目录 / 其它」分流，所以只留三类。
pub(all) enum Kind {
  Regular
  Directory
  Other
} derive(Eq, Debug)

///|
/// 平台层的统一错误：native 把 async 的 IOError / ProcessError 折成一句文本，
/// js 把 Node 抛出的异常折成同一形状。上层只关心「失败 + 原因」。
pub suberror SysError {
  SysError(String)
}

///|
pub fn SysError::to_string(self : SysError) -> String {
  let SysError(message) = self
  message
}

///|
/// 用户真正敲的那几个参数。两端 argv 形状不同：native 只有可执行文件占位，
/// node 前面还多一个解释器路径，差量由 `args_skip()` 给出。
pub fn cli_args() -> Array[String] {
  let raw = @env.args()
  let args : Array[String] = []
  for index in args_skip()..<raw.length() {
    args.push(raw[index])
  }
  args
}

///|
/// 毫秒时间戳，与 native 的 `@env.now()` 同一口径。
pub fn now() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// 读文本，非法 UTF-8 用替换字符顶上（轨迹 / 技能里有用不到严格校验的地方）。
pub async fn read_text_lossy(path : String) -> String raise SysError {
  let bytes = read_bytes(path) catch { err => raise err }
  @utf8.decode_lossy(bytes)
}

///|
/// 一次性命令的捕获结果（替代 `@shell.Cmd(..).output()`）。
pub(all) struct Capture {
  code : Int
  out : String
  err : String
}

///|
pub fn Capture::exit_code(self : Capture) -> Int {
  self.code
}

///|
pub fn Capture::stdout(self : Capture) -> String {
  self.out
}

///|
pub fn Capture::stderr(self : Capture) -> String {
  self.err
}
