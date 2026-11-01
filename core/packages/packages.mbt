// pi 的包（settings.json 的 `packages`）：只消费已安装的包。
//
// pi 把 `packages` 里声明的包装进 `<agent dir>/npm/node_modules`，每个包用
// package.json 的 `"pi"` 字段声明它带来的资源：`extensions` / `skills` /
// `prompts` 三个数组，元素是相对包根的路径（文件或目录）。安装与更新是
// `pi install` 的活，pi-moon 不做 —— 这里只把「已安装的包」解析成三类资源
// 位置，交给技能/模板装载与扩展发现这三条现有缝。
//
// 任何一步失败只产一条诊断、跳过该包：一个坏包不挡启动，也不拖垮别的包。

///|
/// 一个已安装的 pi 包：名字、安装目录与 manifest 声明的三类资源位置
/// （相对包根的路径，`/` 分隔，已去掉 `./` 前缀；只保留磁盘上真实存在的）。
pub(all) struct Package {
  /// 包名（`npm:` 前缀后面的部分）。
  name : String
  /// 包的安装目录：`<agent dir>/npm/node_modules/<名字>`。
  dir : String
  /// `"pi".extensions` 声明的扩展入口。
  extensions : Array[String]
  /// `"pi".skills` 声明的技能目录。
  skills : Array[String]
  /// `"pi".prompts` 声明的 prompt 模板目录。
  prompts : Array[String]
} derive(Debug)

///|
/// 解析 agent 目录下的包清单。
///
/// settings.json 缺失或没有 `packages` 键是常态（这台机器没装任何包），
/// 安静返回空、零诊断；settings.json 本身坏了的诊断归配置层
/// （`load_pi_config` 已经报），这里不重复报。
pub async fn resolve(agent_dir : String) -> (Array[Package], Array[String]) {
  let diagnostics : Array[String] = []
  let text = @sys.read_text_lossy(agent_dir + "/settings.json") catch {
    _ => return ([], diagnostics)
  }
  let parsed = @json.parse(text) catch {
    _ => return ([], diagnostics)
  }
  let entries : Array[Json] = match parsed {
    Object(fields) =>
      match fields.get("packages") {
        Some(Array(items)) => items
        _ => return ([], diagnostics)
      }
    _ => return ([], diagnostics)
  }
  let packages : Array[Package] = []
  for entry in entries {
    match entry {
      String(raw) => {
        if raw.has_prefix("npm:") {
          let name = raw["npm:".length():].to_owned()
          if name.is_empty() {
            diagnostics.push("packages 里有空的 npm: 条目，跳过")
          } else {
            match parse_package(agent_dir, name, diagnostics) {
              Some(resolved) => packages.push(resolved)
              None => ()
            }
          }
        } else {
          diagnostics.push(
            "包 \"" + raw + "\" 不是 npm: 分发方式，跳过（只支持 npm:）",
          )
        }
      }
      _ => diagnostics.push("packages 里有非字符串条目，已跳过")
    }
  }
  (packages, diagnostics)
}

///|
/// 解析一个包：核对安装目录 → 读 package.json 的 `"pi"` manifest →
/// 核对声明的路径在磁盘上存在。任何一步失败返回 None（诊断已记）。
async fn parse_package(
  agent_dir : String,
  name : String,
  diagnostics : Array[String],
) -> Package? {
  let dir = agent_dir + "/npm/node_modules/" + name
  let kind = @sys.kind(dir) catch {
    _ => {
      diagnostics.push("包 " + name + " 未安装（" + dir + "），跳过")
      return None
    }
  }
  if kind != @sys.Directory {
    diagnostics.push("包 " + name + " 的安装位置不是目录（" + dir + "），跳过")
    return None
  }
  let text = @sys.read_text_lossy(dir + "/package.json") catch {
    _ => {
      diagnostics.push("包 " + name + " 的 package.json 读不出来，跳过")
      return None
    }
  }
  let parsed = @json.parse(text) catch {
    _ => {
      diagnostics.push("包 " + name + " 的 package.json 解析失败，跳过")
      return None
    }
  }
  let manifest : Map[String, Json] = match parsed {
    Object(fields) =>
      match fields.get("pi") {
        Some(Object(pi)) => pi
        _ => {
          diagnostics.push("包 " + name + " 没有 \"pi\" 声明，不贡献资源")
          return None
        }
      }
    _ => {
      diagnostics.push("包 " + name + " 的 package.json 不是对象，跳过")
      return None
    }
  }
  // 先读声明（类型核对），再核对存在性：「声明为空」看的是 manifest 本身，
  // 不是过滤后的结果 —— 路径全不存在的包有自己的诊断，不再补一句空声明。
  let declared : Array[(String, Array[String])] = []
  for key in ["extensions", "skills", "prompts"] {
    match manifest.get(key) {
      Some(Array(items)) => {
        let paths : Array[String] = []
        for item in items {
          match item {
            String(raw) => {
              let rel = normalize_entry(raw)
              if rel.is_empty() {
                continue
              }
              if escapes_package(rel) {
                diagnostics.push(
                  "包 " +
                  name +
                  " 的 pi." +
                  key +
                  " 路径越出包目录：" +
                  rel +
                  "，已跳过",
                )
              } else {
                paths.push(rel)
              }
            }
            _ =>
              diagnostics.push(
                "包 " + name + " 的 pi." + key + " 里有非字符串条目，已跳过",
              )
          }
        }
        declared.push((key, paths))
      }
      Some(_) =>
        diagnostics.push("包 " + name + " 的 pi." + key + " 不是数组，忽略该键")
      None => ()
    }
  }
  let declared_any = declared.any(fn(entry) { entry.1.length() > 0 })
  if !declared_any {
    diagnostics.push("包 " + name + " 的 \"pi\" 声明为空，不贡献资源")
    return None
  }
  let extensions : Array[String] = []
  let skills : Array[String] = []
  let prompts : Array[String] = []
  for entry in declared {
    let (key, paths) = entry
    for rel in paths {
      let there = @sys.exists(dir + "/" + rel) catch { _ => false }
      if there {
        match key {
          "extensions" => extensions.push(rel)
          "skills" => skills.push(rel)
          _ => prompts.push(rel)
        }
      } else {
        diagnostics.push(
          "包 " + name + " 声明的 pi." + key + " 路径不存在：" + rel,
        )
      }
    }
  }
  if extensions.is_empty() && skills.is_empty() && prompts.is_empty() {
    return None
  }
  Some({ name, dir, extensions, skills, prompts })
}

///|
/// manifest 条目归一：`\` → `/`、折叠内部的 `/./`、去掉两端斜杠与空白、
/// 剥掉开头的 `./`。（`./skills` → `skills`；`.` → 空串。）
fn normalize_entry(raw : String) -> String {
  let mut rel = raw
    .replace_all(old="\\", new="/")
    .replace_all(old="/./", new="/")
    .trim(chars="/ \t")
    .to_owned()
  while rel.has_prefix("./") {
    rel = rel[2:].to_owned()
  }
  if rel == "." {
    return ""
  }
  rel
}

///|
/// 条目是否越出包目录（任何一段是 `..`）——声明不该往外指。
fn escapes_package(rel : String) -> Bool {
  for part in rel.split("/") {
    if part == ".." {
      return true
    }
  }
  false
}
