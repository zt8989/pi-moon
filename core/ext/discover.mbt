// 扩展发现：用户的 `<agent dir>/extensions` + 项目的 `<cwd>/.pi/extensions`
// + 命令行显式路径。
//
// 规则照 pi 的 `loadExtensions`（见 docs/extensions.md 的 extension-locations）：
//   - 单文件：`.ts` / `.mts` / `.cts` / `.js` / `.mjs` / `.cjs`；
//   - 目录：有 `index.ts` / `index.js` 才算扩展；
//   - 目录下的 `node_modules`、点开头的目录不递归（与 skills 扫描同口径）。

///|
/// 单文件扩展的候选后缀，顺序即优先级。
let source_suffixes : Array[String] = [".ts", ".mts", ".cts", ".js", ".mjs", ".cjs"]

///|
/// 目录式扩展的入口候选。
let entry_names : Array[String] = ["index.ts", "index.js"]

///|
/// 去掉扩展名后的名字（诊断与重名判定用）。
pub fn stem_of(path : String) -> String {
  let file_name = base_name(path)
  let mut best = file_name
  for suffix in source_suffixes {
    if file_name.has_suffix(suffix) && suffix.length() < best.length() {
      best = file_name[:file_name.length() - suffix.length()].to_owned()
    }
  }
  if best == "index" {
    // 目录式扩展：用目录名当扩展名，`demo/index.ts` → `demo`。
    base_name(parent_dir(path))
  } else {
    best
  }
}

///|
/// 路径最后一段。
pub fn base_name(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
}

///|
/// 路径的父目录（`/` 分隔）。
pub fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) if index > 0 => path[:index].to_owned()
    Some(_) => "/"
    None => "."
  }
}

///|
/// 判断一个文件是不是扩展源文件。
pub fn is_source_file(name : String) -> Bool {
  source_suffixes.any(suffix => name.has_suffix(suffix))
}

///|
/// 扫一个目录下的扩展。目录不存在时返回空数组（不是错误）。
async fn discover_in_dir(dir : String, origin : ExtOrigin) -> Array[ExtSource] {
  let out : Array[ExtSource] = []
  let entries = @sys.readdir(dir) catch { _ => return out }
  // 排序保证「同一台机器上两次启动顺序一致」，缓存与诊断都可复现。
  let sorted = entries.copy()
  sorted.sort()
  for name in sorted {
    if name == "node_modules" || name.has_prefix(".") {
      continue
    }
    let path = dir + "/" + name
    if is_source_file(name) {
      out.push({ name: stem_of(path), path, dir, origin })
    } else {
      // 目录式扩展：有入口才算。
      for entry in entry_names {
        let candidate = path + "/" + entry
        let exists = @sys.exists(candidate) catch { _ => false }
        if exists {
          out.push({ name: stem_of(candidate), path: candidate, dir: path, origin })
          break
        }
      }
    }
  }
  out
}

///|
/// 显式给的路径：文件直接用，目录则按目录式扩展解析。
pub async fn discover_explicit(path : String) -> ExtSource? {
  let kind = @sys.kind(path) catch { _ => return None }
  if kind == @sys.Directory {
    for entry in entry_names {
      let candidate = path + "/" + entry
      let exists = @sys.exists(candidate) catch { _ => false }
      if exists {
        return Some({
          name: stem_of(candidate),
          path: candidate,
          dir: path,
          origin: Explicit,
        })
      }
    }
    return None
  }
  Some({ name: stem_of(path), path, dir: parent_dir(path), origin: Explicit })
}

///|
/// 一次发现：显式路径优先（同名时覆盖），然后用户级，最后项目级。
///
/// 同名只留第一个：沙盒里同名扩展注册的是同一套 API，冲突时不能「都装载」。
pub async fn discover(
  cwd : String,
  agent_dir : String,
  explicit~ : Array[String] = [],
) -> (Array[ExtSource], Array[String]) {
  let diagnostics : Array[String] = []
  let sources : Array[ExtSource] = []
  let seen : Map[String, String] = Map([])
  for path in explicit {
    match discover_explicit(path) {
      Some(source) => {
        seen.set(source.name, source.path)
        sources.push(source)
      }
      None => diagnostics.push("警告：--extension " + path + " 不是扩展（缺入口文件）")
    }
  }
  let dirs : Array[(String, ExtOrigin)] = [
    (agent_dir + "/extensions", User),
    (cwd + "/.pi/extensions", Project),
  ]
  for dir_origin in dirs {
    let (dir, origin) = dir_origin
    for source in discover_in_dir(dir, origin) {
      match seen.get(source.name) {
        Some(winner) =>
          diagnostics.push(
            "重名：扩展 \"" +
            source.name +
            "\" 已被 " +
            winner +
            " 占用，忽略 " +
            source.path,
          )
        None => {
          seen.set(source.name, source.path)
          sources.push(source)
        }
      }
    }
  }
  (sources, diagnostics)
}
