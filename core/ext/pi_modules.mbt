// 找 pi 的安装目录：扩展 import 的包（`@earendil-works/*` / `typebox` …）
// 都在那里的 node_modules 里。
//
// 刻意不打包一份进 pi-moon 仓库：扩展要的是「与 pi 同一份」的 ExtensionAPI
// 定义与依赖版本，用装机时的那份才不会出现两套 pi。
//
// 搜索顺序：
//   1. `PI_PI_MODULES` 环境变量（显式指定，测试与离线环境用）；
//   2. `<agent dir>/install/releases/<版本>/node_modules` —— 取版本号最大的一个；
//   3. `<agent dir>/npm/node_modules`；
//   4. PATH 里全局 bin 反推出的 npm 全局 node_modules（`npm i -g` / nvm / scoop
//      装的 pi 只在这里，前三条一个都命中不了）。

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
pub async fn resolve_pi_modules(
  agent_dir : String,
  env? : Map[String, String],
) -> String? {
  let vars = match env {
    Some(vars) => vars
    None => @env.get_env_vars()
  }
  match vars.get("PI_PI_MODULES") {
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
    return Some(fallback)
  }
  for candidate in global_modules_candidates(vars) {
    let okay = is_pi_modules(candidate)
    if okay {
      return Some(candidate)
    }
  }
  None
}

///|
/// 从 PATH 反推「npm 全局装机的 node_modules 根」。
///
/// 全局装机的包不在 agent 目录下面，唯一能用的线索是 PATH 上的全局 bin ——
/// 每种装法的前缀形状不一样：
///   - Windows / nvm / `%APPDATA%\npm`：bin 目录本身就是前缀，包在同级 `node_modules`；
///   - POSIX 前缀布局（`/usr/local`、homebrew、nvm 的 `bin`）：包在 `<前缀>/lib/node_modules`；
///   - bun 的全局装机：`<前缀>/install/global/node_modules`。
///
/// 只给候选、不判存在性 —— 判定的口径统一在 `is_pi_modules`（得有 pi 的包，
/// 于是「PATH 上任何一段都能当候选」不会误判成找到了 pi）。
fn global_modules_candidates(env : Map[String, String]) -> Array[String] {
  let out : Array[String] = []
  let raw = @tools.env_get(env, "PATH").unwrap_or("")
  // 分隔符先看平台（Windows 的盘符里也有 `:`，按 `;` 切才对），再看 PATH
  // 自己 —— POSIX 的 PATH 里不会出现 `;`，真出现了也是「这一份是 Windows 形状」。
  let separator = if @tools.is_windows_env(env) || raw.contains(";") {
    ";"
  } else {
    ":"
  }
  for entry in raw.split(separator) {
    let trimmed = entry.trim().to_owned()
    if trimmed.is_empty() {
      continue
    }
    let dir = if trimmed.has_suffix("/") || trimmed.has_suffix("\\") {
      trimmed[:trimmed.length() - 1].to_owned()
    } else {
      trimmed
    }
    let prefix = parent_dir(dir)
    let candidates = [
      dir + "/node_modules",
      prefix + "/lib/node_modules",
      prefix + "/install/global/node_modules",
      dir + "/install/global/node_modules",
    ]
    for candidate in candidates {
      if !out.contains(candidate) {
        out.push(candidate)
      }
    }
  }
  out
}
