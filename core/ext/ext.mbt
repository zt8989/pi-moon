// pi 扩展的发现与装载规划。
//
// 一座「启动前」的桥：读磁盘上的扩展源，判断它能不能进沙盒，算出缓存键，
// 给出「这次启动要不要编译」的结论。运行期（沙盒、快照恢复、事件派发）在
// 宿主层，不在这里。
//
// 与 pi 的对应关系：
//   - 位置照 pi 的 `loadExtensions`：`<agent dir>/extensions` 与
//     `<cwd>/.pi/extensions`，单文件或「目录 + index.ts/index.js」；
//   - 与 pi 的刻意差异：pi 用 jiti 在原进程里跑 TS，这里一律编译成快照后
//     进 wasm 沙盒 —— 于是「扩展能做什么」被削到沙盒里那套 API。

///|
/// 扩展从哪儿来。决定诊断信息里的标签，也决定重名时的排序。
pub(all) enum ExtOrigin {
  /// `<agent dir>/extensions`（用户级）。
  User
  /// `<cwd>/.pi/extensions`（项目级）。
  Project
  /// 命令行 `--extension <path>` 显式指定。
  Explicit
} derive(Eq, Debug)

///|
pub fn ExtOrigin::to_string(self : ExtOrigin) -> String {
  match self {
    User => "user"
    Project => "project"
    Explicit => "explicit"
  }
}

///|
/// 一个待装载的扩展：名字 + 入口文件 + 所在目录。
///
/// `dir` 是 `base_dir` 语义 —— 扩展里 `read` 相对路径按它解析，目录式扩展
/// 的 npm 依赖也在这个目录下找。
pub(all) struct ExtSource {
  name : String
  path : String
  dir : String
  origin : ExtOrigin
} derive(Eq, Debug)

///|
/// 扩展被跳过的原因。全是「不装载」而不是「装载失败」：启动照常继续，
/// 只是一条诊断。
pub(all) enum ExtSkip {
  /// 源码依赖了只在 Node 里存在的东西（`node:fs` / `child_process` …）。
  NodeDependency(String)
  /// 源码 import 了相对路径或裸包 —— 沙箱里没有模块加载器，解析不了。
  UnresolvedImport(String)
  /// 目录式扩展缺入口文件。
  MissingEntry
  /// 入口文件读不出来。
  Unreadable(String)
  /// 启动前编译工具链不可用（没有 node / 没有 pi 安装）。
  NoCompiler
} derive(Eq, Debug)

///|
pub fn ExtSkip::to_string(self : ExtSkip) -> String {
  match self {
    NodeDependency(spec) => "依赖 Node 专有模块 \"" + spec + "\"，不加载"
    UnresolvedImport(spec) => "import \"" + spec + "\" 在沙箱里无法解析，不加载"
    MissingEntry => "缺少入口文件（index.ts / index.js）"
    Unreadable(reason) => "读不出来：" + reason
    NoCompiler => "启动前编译工具链不可用（找不到 node 或 pi 安装）"
  }
}

///|
/// 一次启动对某个扩展要做的事。
pub(all) enum ExtStep {
  /// 缓存命中：直接恢复快照，不跑编译器。
  Cached(cache_key~ : String, path~ : String)
  /// 缓存未命中：启动前编译一次，写出缓存。
  Compile(cache_key~ : String, path~ : String, source~ : String)
  /// 不装载。
  Skip(reason~ : ExtSkip)
} derive(Eq, Debug)

///|
pub fn ExtStep::to_string(self : ExtStep) -> String {
  match self {
    Cached(cache_key~, ..) => "Cached(" + cache_key + ")"
    Compile(cache_key~, ..) => "Compile(" + cache_key + ")"
    Skip(reason~) => "Skip(" + reason.to_string() + ")"
  }
}

///|
pub(all) struct ExtEntry {
  source : ExtSource
  step : ExtStep
} derive(Eq, Debug)

///|
/// 一次启动的扩展装载计划。
pub(all) struct ExtPlan {
  entries : Array[ExtEntry]
  /// 诊断（跳过原因、重名提示、缓存目录不可写……）按发现顺序排列。
  diagnostics : Array[String]
} derive(Debug)

///|
pub fn ExtPlan::loaded(self : ExtPlan) -> Array[ExtEntry] {
  self.entries.filter(entry => match entry.step {
    Skip(_) => false
    _ => true
  })
}

///|
pub fn ExtPlan::skipped(self : ExtPlan) -> Array[ExtEntry] {
  self.entries.filter(entry => match entry.step {
    Skip(_) => true
    _ => false
  })
}

///|
/// 缓存目录：`<agent dir>/cache/pi-moon/ext`。放 agent 目录下而不是项目里，
/// 是因为快照与 cwd 无关，跨项目复用同一份。
pub fn ext_cache_dir(agent_dir : String) -> String {
  agent_dir + "/cache/pi-moon/ext"
}

///|
/// 单个扩展的缓存文件：`<cache dir>/<key>.snapshot`。
pub fn ext_cache_path(agent_dir : String, cache_key : String) -> String {
  ext_cache_dir(agent_dir) + "/" + cache_key + ".snapshot"
}

///|
/// 快照旁边的元数据：`<cache dir>/<key>.json`。
///
/// 注册清单（工具名、命令名、钩子事件）活在 JS 堆里，光有快照读不出来；
/// 编译时顺手落一份 JSON，命中缓存时就不用为了拿清单再起一次沙盒。
pub fn ext_meta_path(agent_dir : String, cache_key : String) -> String {
  ext_cache_dir(agent_dir) + "/" + cache_key + ".json"
}

///|
/// 缓存键的构成：扩展源码 + 预置脚本版本 + 沙盒版本。
///
/// 三者任一变化都必须重编译 —— 预置脚本改了（宿主换了 API 形状）、
/// quickjs 换了（快照不跨版本）、扩展源码改了。
pub fn cache_key(
  source : String,
  prelude_version~ : String,
  sandbox_version~ : String,
) -> String {
  let material = prelude_version +
    "\u{0}" +
    sandbox_version +
    "\u{0}" +
    source
  hex64(fnv1a64(material))
}

///|
/// FNV-1a 64。够用的内容指纹：不防碰撞攻击，只用来判断「源码变了没有」。
pub fn fnv1a64(text : String) -> UInt64 {
  let mut hash : UInt64 = 0xCBF29CE484222325UL
  for byte in @utf8.encode(text) {
    hash = hash ^ (byte.to_int().to_uint64())
    hash = hash * 0x100000001B3UL
  }
  hash
}

///|
/// 16 位小写 hex —— 缓存文件名。
pub fn hex64(value : UInt64) -> String {
  let alphabet : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  let nibbles : Array[Int] = []
  let mut rest = value
  for _ in 0..<16 {
    nibbles.push((rest & 0xFUL).to_int())
    rest = rest >> 4
  }
  let mut out = ""
  for index in 0..<16 {
    out = out + alphabet[nibbles[15 - index]]
  }
  out
}
