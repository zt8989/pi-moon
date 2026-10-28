// 找 `quickjs.wasm`：pi 自己的那份。
//
// 刻意不打包一份进 pi-moon 仓库：沙盒语义（快照格式、host 函数签名）是跟
// quickjs-wasi 的版本绑定的，用 pi 装机时的那一份才不会出现「两个 quickjs」。
//
// 搜索顺序：
//   1. `PI_QUICKJS_WASM` 环境变量（显式指定，测试与离线环境用）；
//   2. `<agent dir>/install/releases/<版本>/node_modules/quickjs-wasi/quickjs.wasm`
//      —— 取版本号最大的一个；
//   3. `<agent dir>/npm/node_modules/quickjs-wasi/quickjs.wasm`。

///|
/// 从一组候选路径里挑第一个存在的。
async fn first_existing(candidates : Array[String]) -> String? {
  for path in candidates {
    let exists = @sys.exists(path) catch { _ => false }
    if exists {
      let kind = @sys.kind(path) catch { _ => continue }
      if kind == @sys.Regular {
        return Some(path)
      }
    }
  }
  None
}

///|
/// 版本目录排序键：把 `1.4.0` 变成可比较的整数序列，避免按字典序把
/// `1.10.0` 排在 `1.4.0` 前面。
fn version_key(name : String) -> UInt64 {
  let mut key : UInt64 = 0
  let mut parts = 0
  for segment in name.split(".") {
    let mut value : UInt64 = 0
    let mut seen = false
    for character in segment {
      if character >= '0' && character <= '9' {
        value = value * 10UL + (character.to_int() - '0'.to_int()).to_uint64()
        seen = true
      } else {
        break
      }
    }
    if seen && parts < 4 {
      key = (key << 16) | (value & 0xFFFFUL)
      parts = parts + 1
    }
  }
  key
}

///|
/// 解析 `quickjs.wasm` 的路径。找不到返回 None（扩展装载整体关掉，其余功能不受影响）。
pub async fn resolve_quickjs_wasm(agent_dir : String) -> String? {
  let env = @env.get_env_vars()
  match env.get("PI_QUICKJS_WASM") {
    Some(path) if !path.is_empty() => {
      let exists = @sys.exists(path) catch { _ => false }
      if exists {
        return Some(path)
      }
    }
    _ => ()
  }
  let releases = agent_dir + "/install/releases"
  let names = @sys.readdir(releases) catch { _ => [] }
  let mut best : (UInt64, String)? = None
  for name in names {
    let candidate = releases + "/" + name + "/node_modules/quickjs-wasi/quickjs.wasm"
    let exists = @sys.exists(candidate) catch { _ => false }
    if exists {
      let key = version_key(name)
      match best {
        Some((best_key, _)) =>
          if key > best_key {
            best = Some((key, candidate))
          }
        None => best = Some((key, candidate))
      }
    }
  }
  match best {
    Some((_, path)) => return Some(path)
    None => ()
  }
  first_existing([agent_dir + "/npm/node_modules/quickjs-wasi/quickjs.wasm"])
}

///|
/// 读 wasm 字节。找不到 / 读不出来都返回 None。
pub async fn load_quickjs_wasm(agent_dir : String) -> (String, Bytes)? {
  match resolve_quickjs_wasm(agent_dir) {
    Some(path) => {
      let bytes = @sys.read_bytes(path) catch { _ => return None }
      Some((path, bytes))
    }
    None => None
  }
}
