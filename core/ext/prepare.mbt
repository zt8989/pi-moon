// 启动前的准备：把「磁盘上的扩展源」变成「这次启动要交给 bun 宿主哪几个」。
//
// 一个扩展只可能停在三种结局：
//   1. 缓存命中   → 启动时直接把产物交给 bun，不再打包；
//   2. 缓存未命中 → 启动前打包一次（Bun.build），产物落在缓存目录；
//   3. 不加载     → 读不出来（权限 / 不存在 / 是目录却没有入口）。
//
// 装载本身就是起了**常驻**宿主（`--mode serve`）：宿主装完扩展回传注册表，
// 然后留在那里等运行期的 `call` / `emit`。所以这里既是「启动前」，也是
// 「运行期的名册」——`StartupExt.runtime` 就是那一份。

///|
/// 预置脚本版本。宿主脚本改了要加一 —— 缓存键包含它。
pub let prelude_version : String = "pi-moon-ext/3"

///|
/// 沙盒版本（宿主运行时的大版本）。产物不跨版本混用。
pub let sandbox_version : String = "bun-1"

///|
/// 宿主流程的版本串（进缓存键）：宿主脚本 + 沙盒版本一起变。
pub fn host_cache_version() -> String {
  host_version + "+" + sandbox_version
}

///|
/// 对一个扩展源做体检 + 缓存判定。
///
/// 读文件失败收敛成 `Skip`；只有「能装」才继续。
/// 缓存命中与否由宿主自己的 build 目录判断（`ready` 回传 built 标记），
/// 这里只负责算键与路径。
pub async fn plan_source(
  source : ExtSource,
  agent_dir : String,
) -> ExtEntry {
  // 这里只读源码算缓存键：能不能装交给宿主 —— 它跑在 bun 里，Node API
  // 全部可用（路径按白名单卡），模块解析失败会在装载时带着 bun 的诊断回来。
  let raw = @sys.read_text(source.path) catch {
    error => return { source, step: Skip(reason=Unreadable(error.to_string())) }
  }
  let key = cache_key(raw, prelude_version~, sandbox_version=host_cache_version())
  let path = ext_cache_path(agent_dir, key)
  let cached = @sys.exists(path) catch { _ => false }
  let step = if cached {
    Cached(cache_key=key, path~)
  } else {
    Compile(cache_key=key, path~, source=raw)
  }
  { source, step }
}

///|
/// 一次启动的完整计划：先发现，再逐个判定。
pub async fn plan(
  cwd : String,
  agent_dir : String,
  explicit~ : Array[String] = [],
) -> ExtPlan {
  let (sources, diagnostics) = discover(cwd, agent_dir, explicit~)
  let entries : Array[ExtEntry] = []
  for source in sources {
    let entry = plan_source(source, agent_dir)
    match entry.step {
      Skip(reason~) =>
        diagnostics.push(
          "跳过扩展 \"" + entry.source.name + "\"：" + reason.to_string(),
        )
      _ => ()
    }
    entries.push(entry)
  }
  { entries, diagnostics }
}

///|
/// 启动前的一次性准备：发现 → 体检 → 起常驻宿主（bun）→ 汇总。
///
/// 这是 `cmd/pi-moon` 唯一需要调的入口。宿主负责打包（只在缓存未命中时）、
/// 装载，然后**留在那里**等运行期的 `call` / `emit`（见 `serve.mbt`）。
/// 启动这一下同时就是装载，所以不再额外跑一遍一次性宿主。
pub(all) struct StartupExt {
  /// 装载成功的扩展名（顺序即发现顺序）。
  names : Array[String]
  /// 横幅显示标签（与 names 一一对应）：文件带后缀 / 目录名。
  labels : Array[String]
  /// 扩展注册的工具名（全并集，去重保序）。
  tools : Array[String]
  /// 扩展注册的斜杠命令名。
  commands : Array[String]
  /// 扩展挂了钩子的事件名。
  events : Array[String]
  /// 扩展工具的完整定义（模型要看到的那一份）。
  tool_definitions : Array[ExtToolDefinition]
  diagnostics : Array[String]
  /// 每个已就绪扩展的宿主产物路径（诊断用）。
  artifacts : Array[(String, String)]
  /// 运行期名册：`call` 工具、`emit` 事件。
  runtime : ExtRuntime
  /// 宿主是否可用（false 时扩展整体关闭）。
  available : Bool
}

///|
fn empty_startup(diagnostics : Array[String], available : Bool) -> StartupExt {
  {
    names: [],
    labels: [],
    tools: [],
    commands: [],
    events: [],
    tool_definitions: [],
    diagnostics,
    artifacts: [],
    runtime: ExtRuntime::new(),
    available,
  }
}

///|
pub async fn prepare_at_startup(
  cwd : String,
  agent_dir : String,
  explicit~ : Array[String] = [],
) -> StartupExt {
  let planned = plan(cwd, agent_dir, explicit~)
  let diagnostics = planned.diagnostics.copy()
  let ready = planned.loaded()
  if ready.is_empty() {
    return empty_startup(diagnostics, true)
  }
  // 宿主需要 pi 的 node_modules 才能解析扩展 import 的包。
  let modules = match resolve_pi_modules(agent_dir) {
    Some(path) => path
    None => ""
  }
  if modules.is_empty() {
    diagnostics.push("跳过全部扩展：找不到 pi 的 node_modules（宿主无法解析 pi 的包）")
    return empty_startup(diagnostics, false)
  }
  let paths = prepare_host_paths(cwd, agent_dir, modules) catch {
    error => {
      diagnostics.push(error.to_string())
      return empty_startup(diagnostics, false)
    }
  }
  if paths.bun_missing() {
    diagnostics.push(NoBun.to_string())
    return empty_startup(diagnostics, false)
  }
  let names : Array[String] = []
  let labels : Array[String] = []
  let tools : Array[String] = []
  let commands : Array[String] = []
  let events : Array[String] = []
  let tool_definitions : Array[ExtToolDefinition] = []
  let artifacts : Array[(String, String)] = []
  let runtime = ExtRuntime::new()
  for entry in ready {
    let key = match entry.step {
      Cached(cache_key~, ..) => cache_key
      Compile(cache_key~, ..) => cache_key
      Skip(..) => continue
    }
    let session = try ExtSession::start(paths, entry.source, key) catch {
      error => {
        diagnostics.push("装载扩展 \"" + entry.source.name + "\" 失败：" + error.to_string())
        continue
      }
    }
    // 注了工具或事件的会话要活到会话结束（`call` / `emit` 都走它）；
    // 只注了命令的（`/name` 还没有执行入口）现在就收掉，别白占一个 bun 进程。
    let needed = !session.tools.is_empty() || !session.events.is_empty()
    names.push(entry.source.name)
    labels.push(ext_label(entry.source))
    artifacts.push((entry.source.name, paths.root + "/build/" + key + ".mjs"))
    for tool in session.tools {
      if !tools.contains(tool) {
        tools.push(tool)
      }
    }
    for definition in session.tool_definitions {
      if !tool_definitions.any(fn(existing) { existing.name == definition.name }) {
        tool_definitions.push(definition)
      }
    }
    for command in session.commands {
      if !commands.contains(command) {
        commands.push(command)
      }
    }
    for event in session.events {
      if !events.contains(event) {
        events.push(event)
      }
    }
    if !session.unsupported.is_empty() {
      diagnostics.push(
        "扩展 \"" +
        entry.source.name +
        "\" 用了未实现的宿主 API：" +
        session.unsupported.join(", "),
      )
    }
    for denied in session.denied {
      diagnostics.push("扩展 \"" + entry.source.name + "\" 被沙盒拦下：" + denied)
    }
    if !session.built {
      diagnostics.push(
        "扩展 \"" + entry.source.name + "\" 命中产物缓存（" + session.ms.to_string() + "ms）",
      )
    }
    if needed {
      runtime.push(session)
    } else {
      session.close()
    }
  }
  {
    names,
    labels,
    tools,
    commands,
    events,
    tool_definitions,
    diagnostics,
    artifacts,
    runtime,
    available: true,
  }
}
