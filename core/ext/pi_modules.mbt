// 找 pi 的安装目录：扩展 import 的包（`@earendil-works/*` / `typebox` …）
// 都在那里的 node_modules 里。
//
// 刻意不打包一份进 pi-moon 仓库：扩展要的是「与 pi 同一份」的 ExtensionAPI
// 定义与依赖版本，用装机时的那份才不会出现两套 pi。
//
// 搜索顺序：
//   1. `PI_PI_MODULES` 环境变量（显式指定，测试与离线环境用）；
//   2. `<agent dir>/install/releases/<版本>/node_modules` —— 取版本号最大的一个；
//   3. `<agent dir>/npm/node_modules`。

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
/// 一个目录是不是「pi 的 node_modules」：里面得有 coding-agent 的包。
async fn is_pi_modules(path : String) -> Bool {
  let marker = path + "/@earendil-works/pi-coding-agent/package.json"
  @sys.exists(marker) catch { _ => false }
}

///|
/// 解析 pi 的 node_modules 路径。找不到返回 None（扩展整体关闭）。
pub async fn resolve_pi_modules(agent_dir : String) -> String? {
  let env = @env.get_env_vars()
  match env.get("PI_PI_MODULES") {
    Some(path) if !path.is_empty() => {
      let okay = is_pi_modules(path)
      if okay {
        return Some(path)
      }
    }
    _ => ()
  }
  let releases = agent_dir + "/install/releases"
  let names = @sys.readdir(releases) catch { _ => [] }
  let mut best : (UInt64, String)? = None
  for name in names {
    let candidate = releases + "/" + name + "/node_modules"
    let okay = is_pi_modules(candidate)
    if okay {
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
  let fallback = agent_dir + "/npm/node_modules"
  let okay = is_pi_modules(fallback)
  if okay {
    Some(fallback)
  } else {
    None
  }
}
