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
/// 目录式扩展的入口：`dir` 下第一个存在的 index.ts / index.js。
async fn dir_entry(dir : String) -> String? {
  for entry in entry_names {
    let candidate = dir + "/" + entry
    let exists = @sys.exists(candidate) catch { _ => false }
    if exists {
      return Some(candidate)
    }
  }
  None
}

///|
/// 横幅标签：pi 显示的是「装了什么」—— 单文件带后缀（`demo.js`），
/// 目录式扩展是目录名（`demo`）。包来源再加包名前缀，与 pi 的横幅同形：
/// 入口在包根的（`./index.ts`）只剩包名，目录式是 `包名:目录`
/// （`pi-subagents:bundle`），子目录里的源文件是 `包名:相对路径`
/// （`pi-background-tasks:dist/extensions/x.js`）。
pub fn ext_label(source : ExtSource) -> String {
  let file_name = base_name(source.path)
  match source.origin {
    Package(package, pkg_root) => {
      let rel = if entry_names.contains(file_name) {
        relative_to(source.dir, pkg_root)
      } else {
        relative_to(source.path, pkg_root)
      }
      if rel.is_empty() {
        package
      } else {
        package + ":" + rel
      }
    }
    _ =>
      // 本地来源：单文件带后缀（`demo.js`）；目录式（入口是 index.*）用
      // 目录名 —— 与 docs 的横幅口径一致，也和包来源的 `包名:目录` 对齐。
      if is_source_file(file_name) && !entry_names.contains(file_name) {
        file_name
      } else {
        base_name(source.dir)
      }
  }
}

///|
/// path 剥掉 root 前缀后的剩余部分（包来源的标签用）。path 不在 root 之下
/// 时给空串 —— 调用方折回包名。
fn relative_to(path : String, root : String) -> String {
  if root.is_empty() {
    return ""
  }
  let prefix = root + "/"
  if path.has_prefix(prefix) {
    path[prefix.length():].to_owned()
  } else {
    ""
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
      match dir_entry(path) {
        Some(candidate) =>
          out.push({
            name: stem_of(candidate),
            path: candidate,
            dir: path,
            origin,
          })
        None => ()
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
    match dir_entry(path) {
      Some(candidate) =>
        return Some({
          name: stem_of(candidate),
          path: candidate,
          dir: path,
          origin: Explicit,
        })
      None => return None
    }
  }
  Some({
    name: stem_of(path),
    path,
    dir: parent_dir(path),
    origin: Explicit,
  })
}

///|
/// 包来源诊断的统一措辞。
fn package_warning(pkg : PackageExtension, reason : String) -> String {
  "警告：包 " + pkg.package + " 声明的扩展 " + pkg.entry + reason
}

///|
/// 一个包声明的扩展入口 → 待装载的扩展。入口是目录时按目录式解析
/// （有 index.ts / index.js 才算）；入口文件不是可装载的源文件时给诊断。
/// 返回 None = 放弃（诊断已记）。
async fn discover_package_extension(
  pkg : PackageExtension,
  diagnostics : Array[String],
) -> ExtSource? {
  let abs = pkg.dir + "/" + pkg.entry
  let kind = @sys.kind(abs) catch {
    _ => {
      diagnostics.push(package_warning(pkg, " 在磁盘上不存在，跳过"))
      return None
    }
  }
  if kind == @sys.Directory {
    match dir_entry(abs) {
      Some(candidate) =>
        return Some({
          name: stem_of(candidate),
          path: candidate,
          dir: abs,
          origin: Package(pkg.package, pkg.dir),
        })
      None => {
        diagnostics.push(package_warning(pkg, " 缺少入口文件（index.ts / index.js），跳过"))
        return None
      }
    }
  }
  if is_source_file(base_name(abs)) {
    Some({
      name: stem_of(abs),
      path: abs,
      dir: parent_dir(abs),
      origin: Package(pkg.package, pkg.dir),
    })
  } else {
    diagnostics.push(package_warning(pkg, " 不是可装载的源文件，跳过"))
    None
  }
}

///|
/// 一次发现：显式路径优先（同名时覆盖），然后用户级、项目级、最后包声明
/// 的（本地赢重名 —— 与技能/模板的装载顺序同口径）。
///
/// 同名只留第一个：沙盒里同名扩展注册的是同一套 API，冲突时不能「都装载」。
pub async fn discover(
  cwd : String,
  agent_dir : String,
  explicit~ : Array[String] = [],
  packages~ : Array[PackageExtension] = [],
) -> (Array[ExtSource], Array[String]) {
  let diagnostics : Array[String] = []
  let sources : Array[ExtSource] = []
  let seen : Map[String, String] = Map([])
  // 同名只留第一个（含诊断）：显式、本地、包三个来源共用这一条路。
  let try_register = fn(source : ExtSource) {
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
  for path in explicit {
    match discover_explicit(path) {
      Some(source) => try_register(source)
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
      try_register(source)
    }
  }
  // 包声明的扩展：manifest 说什么装什么，重名规则同上（本地赢）。
  for pkg in packages {
    match discover_package_extension(pkg, diagnostics) {
      Some(source) => try_register(source)
      None => ()
    }
  }
  (sources, diagnostics)
}
