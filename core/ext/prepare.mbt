// 启动前的准备：把「磁盘上的扩展源」变成「这次启动要恢复哪几个快照」。
//
// 一个扩展只可能停在三种结局：
//   1. 缓存命中   → 启动时直接恢复快照，JS 引擎不参与；
//   2. 缓存未命中 → 启动前编译一次（宿主跑 prelude + 扩展源，抓快照落盘）；
//   3. 不加载     → 体检没过（Node 依赖 / 不可解析的 import / 读不出来）。
//
// 这里的代码全在「启动前」这一侧，唯一的运行期输入是已有的缓存文件。

///|
/// 预置脚本版本。改了 prelude 里的 JS 就必须加一 —— 缓存键包含它，
/// 否则老快照会被继续用，宿主调一个已经不存在的函数。
pub let prelude_version : String = "pi-moon-ext/1"

///|
/// 沙盒版本：`quickjs.wasm` 的发布版本。快照不跨版本，所以进缓存键。
pub let sandbox_version : String = "quickjs-wasi/3.6.2"

///|
/// 对一个扩展源做体检 + 缓存判定。
///
/// 读文件失败、import 体检不过都收敛成 `Skip`；只有「能装且缺缓存」才给
/// `Compile` —— 调用方据此决定要不要在启动前拉起编译器。
pub async fn plan_source(
  source : ExtSource,
  agent_dir : String,
  compiled~ : String? = None,
) -> ExtEntry {
  // 纯 JS 源不需要转译；TS 源由调用方先转译好传进来。
  let text = match compiled {
    Some(compiled) => compiled
    None => {
      let raw = @sys.read_text(source.path) catch {
        error => return { source, step: Skip(reason=Unreadable(error.to_string())) }
      }
      raw
    }
  }
  // Node 全局先查：`process.env` 这类没有 import，光看说明符会漏过去，
  // 结果是「装上了，一调 handler 就 ReferenceError」。
  match first_node_global(text) {
    Some(name) => return { source, step: Skip(reason=NodeDependency(name)) }
    None => ()
  }
  match first_unsupported_import(text) {
    Some((kind, spec)) =>
      match kind {
        SpecifierKind::NodeBuiltin =>
          return { source, step: Skip(reason=NodeDependency(spec)) }
        _ => return { source, step: Skip(reason=UnresolvedImport(spec)) }
      }
    None => ()
  }
  let key = cache_key(text, prelude_version~, sandbox_version~)
  let path = ext_cache_path(agent_dir, key)
  let cached = @sys.exists(path) catch { _ => false }
  let step = if cached {
    Cached(cache_key=key, path~)
  } else {
    Compile(cache_key=key, path~, source=text)
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
/// 启动前的一次性准备：发现 → 体检 → 编译缺缓存的 → 汇总。
///
/// 这是 `cmd/pi-moon` 唯一需要调的入口。返回的名字与注册清单供横幅与运行期
/// 桥接使用；诊断直接打到 stderr（与 `[config]` / `[skills]` 同一风格）。
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
  diagnostics : Array[String]
  /// 每个已就绪扩展的快照路径（运行期恢复用）。
  snapshots : Array[(String, String)]
}

///|
pub async fn prepare_at_startup(
  cwd : String,
  agent_dir : String,
  explicit~ : Array[String] = [],
) -> StartupExt {
  let planned = plan(cwd, agent_dir, explicit~)
  let (compiled, final_plan) = compile_plan(planned, agent_dir)
  let names : Array[String] = []
  let labels : Array[String] = []
  let tools : Array[String] = []
  let commands : Array[String] = []
  let events : Array[String] = []
  let snapshots : Array[(String, String)] = []
  for entry in compiled {
    names.push(entry.name)
    labels.push(entry.label)
    snapshots.push((entry.name, entry.snapshot_path))
    for tool in entry.tools {
      if !tools.contains(tool) {
        tools.push(tool)
      }
    }
    for command in entry.commands {
      if !commands.contains(command) {
        commands.push(command)
      }
    }
    for event in entry.events {
      if !events.contains(event) {
        events.push(event)
      }
    }
  }
  {
    names,
    labels,
    tools,
    commands,
    events,
    diagnostics: final_plan.diagnostics,
    snapshots,
  }
}
