// 预置脚本：沙盒里那套「看起来像 pi 扩展」的 API。
//
// 扩展在 pi 里拿到的是 `ExtensionAPI`（注册工具、命令、事件钩子）。沙盒里没有
// Node，但扩展的**注册动作**只是往几个数组里塞对象 —— 于是沙盒先给一个纯数据的
// `pi` 对象，把注册结果攒成 JSON，宿主（MoonBit 侧）再读出来接进自己的环。
//
// 两条硬边界：
//   1. 预置脚本只做注册，不做派发。事件什么时候来、handler 怎么被调，都由
//      宿主决定（见 docs/extensions.md 的「一次启动的时序」）。
//   2. 注册结果必须是 JSON 可表达的。函数（handler / execute）留在沙盒里，
//      宿主按「名字 + 序号」引用它们。
//
// 改了这里的 JS 就必须改 `prepare.mbt` 的 `prelude_version`：缓存键含它。

///|
/// 沙盒里的 `pi` 对象。语义与 pi 的 `ExtensionAPI` 对齐到「参数形状」这一层：
/// 扩展源码不用改就能跑，能跑多远取决于宿主接了多少。
let prelude_source : String =
  #|(function () {
  #|  var registry = { tools: [], commands: [], handlers: {}, providers: 0, mcps: [] };
  #|  globalThis.__pi_ext_registry = registry;
  #|  function jsonSafe(value) {
  #|    if (value === undefined) return null;
  #|    try { return JSON.parse(JSON.stringify(value)); } catch (error) { return null; }
  #|  }
  #|  globalThis.__pi_ext_json_safe = jsonSafe;
  #|  var api = {
  #|    registerTool: function (tool) {
  #|      registry.tools.push({
  #|        name: String(tool && tool.name || ''),
  #|        description: String(tool && tool.description || ''),
  #|        parameters: jsonSafe(tool && tool.parameters),
  #|        exposure: (tool && tool.exposure) || 'direct',
  #|        annotations: jsonSafe(tool && tool.annotations)
  #|      });
  #|      globalThis.__pi_ext_tool_impls = globalThis.__pi_ext_tool_impls || {};
  #|      globalThis.__pi_ext_tool_impls[String(tool && tool.name || '')] = tool;
  #|      return function () {};
  #|    },
  #|    registerCommand: function (name, definition) {
  #|      registry.commands.push({
  #|        name: String(name),
  #|        description: String(definition && definition.description || '')
  #|      });
  #|      globalThis.__pi_ext_command_impls = globalThis.__pi_ext_command_impls || {};
  #|      globalThis.__pi_ext_command_impls[String(name)] = definition;
  #|      return function () {};
  #|    },
  #|    on: function (event, handler) {
  #|      registry.handlers[event] = registry.handlers[event] || [];
  #|      registry.handlers[event].push(registry.handlers[event].length);
  #|      globalThis.__pi_ext_handler_impls = globalThis.__pi_ext_handler_impls || {};
  #|      globalThis.__pi_ext_handler_impls[event] = globalThis.__pi_ext_handler_impls[event] || [];
  #|      globalThis.__pi_ext_handler_impls[event].push(handler);
  #|      return function () {};
  #|    },
  #|    // 以下三样沙盒里做不到：注册 provider 要网络，MCP 要子进程，UI 要终端。
  #|    // 保留同名函数并计数，好让宿主在诊断里说清「这个扩展要了什么」。
  #|    registerProvider: function () { registry.providers += 1; },
  #|    registerMcpServer: function (name) { registry.mcps.push(String(name)); },
  #|    appendEntry: function () {},
  #|    sendMessage: function () {},
  #|    sendUserMessage: function () {},
  #|    setActiveTools: function () {},
  #|    getActiveTools: function () { return []; },
  #|    getAllTools: function () { return []; },
  #|    events: { on: function () { return function () {}; }, emit: function () {} }
  #|  };
  #|  globalThis.pi = api;
  #|})();
  #|globalThis.__pi_ext_module = { exports: {} };

///|
/// 预置脚本 + 扩展源 + 收尾，拼成一次 eval 的完整脚本。
///
/// 扩展源被包进一个 CJS 形状的函数里：`export default` 已经被
/// `rewrite_exports` 改写成 `module.exports.default =`，于是沙盒不需要模块
/// 加载器也能跑。
pub fn wrap_extension(source : String) -> String {
  let body = rewrite_exports(source)
  prelude_source +
  "\n" +
  "(function (module, exports) {\n" +
  body +
  "\n})(__pi_ext_module, __pi_ext_module.exports);\n" +
  "if (typeof __pi_ext_module.exports.default === 'function') {\n" +
  "  __pi_ext_module.exports.default(globalThis.pi);\n" +
  "}\n" +
  "JSON.stringify(__pi_ext_registry)"
}

///|
/// 把 ESM 的 `export` 改写成 `module.exports` 上的挂载。
///
/// 只处理顶层（行首无缩进）的三种形态 —— 扩展源里就这三种：
///   - `export default <expr>`  → `module.exports.default = <expr>`
///   - `export <decl>`          → `<decl>` + 事后挂载（函数/常量/类）
///   - `export { a, b }` / `export * from ...` → 丢弃（宿主不收具名导出）
///
/// 不递归、不改写字符串里的 `export`：够用，且失败时扩展自己会报语法错误。
pub fn rewrite_exports(source : String) -> String {
  let out = StringBuilder()
  let pending : Array[String] = []
  for line in source.split("\n") {
    let trimmed = line.trim_start()
    if trimmed.has_prefix("export default") {
      let rest = trimmed[14:].trim_start().to_owned()
      out.write_string("module.exports.default = " + rest + "\n")
    } else if trimmed.has_prefix("export {") || trimmed.has_prefix("export *") {
      // 具名导出宿主用不上：注册走的是 `pi.*` 的副作用。
      out.write_string("// " + trimmed.to_owned() + "\n")
    } else if trimmed.has_prefix("export ") {
      let rest = trimmed[7:].trim_start().to_owned()
      out.write_string(rest + "\n")
      match declared_name(rest) {
        Some(name) => pending.push(name)
        None => ()
      }
    } else {
      out.write_string(line.to_owned() + "\n")
    }
  }
  for name in pending {
    out.write_string("module.exports." + name + " = " + name + ";\n")
  }
  out.to_string()
}

///|
/// 从 `const name =` / `function name(` / `class Name` / `let name` 里取名字。
fn declared_name(decl : String) -> String? {
  let mut rest = decl
  for keyword in ["async function ", "function ", "class ", "const ", "let ", "var "] {
    if rest.has_prefix(keyword) {
      rest = rest[keyword.length():].to_owned()
      break
    }
  }
  let mut name = ""
  for character in rest {
    if (character >= 'a' && character <= 'z') ||
      (character >= 'A' && character <= 'Z') ||
      (character >= '0' && character <= '9') ||
      character == '_' ||
      character == '$' {
      name = name + character.to_string()
    } else {
      break
    }
  }
  if name.is_empty() {
    None
  } else {
    Some(name)
  }
}
