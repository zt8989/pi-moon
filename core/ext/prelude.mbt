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
  #|  // ---- 沙盒里的模块系统：只认 pi 自己的那几个包 ----
  #|  //
  #|  // 扩展源码里的 `import { defineTool } from "@earendil-works/pi-coding-agent"`
  //|  // 被 jiti 转成 `require("…")`。这里给同名 shim：能用真实现的给真实现
  //|  // （defineTool 是恒等、typebox 用来描述工具参数），其余给出「没实现」的
  //|  // 可调用桩 —— 装不进来比装进来再炸更糟，桩至少让错误落在真正用到的那一刻。
  #|  var OPTIONAL = typeof Symbol === 'function'
  #|    ? Symbol.for('pi-moon.ext.optional')
  #|    : '__pi_moon_optional__';
  #|  function merge(base, extra) {
  #|    if (extra) { for (var key in extra) { if (Object.prototype.hasOwnProperty.call(extra, key)) { base[key] = extra[key] } } }
  #|    return base;
  #|  }
  #|  var Type = {
  #|    Object: function (properties, options) {
  #|      var source = properties || {};
  #|      var clean = {};
  #|      var required = [];
  #|      for (var key in source) {
  #|        if (!Object.prototype.hasOwnProperty.call(source, key)) { continue }
  #|        var schema = source[key] || {};
  #|        var optional = Boolean(schema[OPTIONAL]);
  #|        var copy = {};
  #|        for (var field in schema) {
  #|          if (Object.prototype.hasOwnProperty.call(schema, field) && field !== String(OPTIONAL)) { copy[field] = schema[field] }
  #|        }
  #|        copy = (typeof copy.type === 'symbol') ? { type: String(copy.type) } : copy;
  #|        clean[key] = copy;
  #|        if (!optional) { required.push(key) }
  #|      }
  #|      var out = { type: 'object', properties: clean };
  #|      if (required.length > 0) { out.required = required }
  #|      return merge(out, options);
  #|    },
  #|    String: function (o) { return merge({ type: 'string' }, o) },
  #|    Number: function (o) { return merge({ type: 'number' }, o) },
  #|    Integer: function (o) { return merge({ type: 'integer' }, o) },
  #|    Boolean: function (o) { return merge({ type: 'boolean' }, o) },
  #|    Null: function (o) { return merge({ type: 'null' }, o) },
  #|    Array: function (items, o) { return merge({ type: 'array', items: items }, o) },
  #|    Tuple: function (items, o) { return merge({ type: 'array', items: items }, o) },
  #|    Union: function (variants, o) { return merge({ anyOf: variants || [] }, o) },
  #|    Literal: function (value) { return { const: value } },
  #|    Enum: function (values) { return { enum: values || [] } },
  #|    Record: function (_key, value, o) { return merge({ type: 'object', additionalProperties: value }, o) },
  #|    Any: function (o) { return merge({}, o) },
  #|    Unknown: function (o) { return merge({}, o) },
  #|    Ref: function (name) { return { '$ref': name } },
  #|    Unsafe: function (schema) { return schema },
  #|    StringEnum: function (values, o) {
  #|      var variants = [];
  #|      var items = values || [];
  #|      for (var index = 0; index < items.length; index++) { variants.push({ const: items[index] }) }
  #|      return merge({ anyOf: variants }, o);
  #|    },
  #|    Optional: function (schema) {
  #|      var copy = merge({}, schema);
  #|      copy[OPTIONAL] = true;
  #|      return copy;
  #|    }
  #|  };
  #|  var typeboxModule = { Type: Type, Kind: {}, Static: {} };
  #|  function stubModule(label, base) {
  #|    var target = base || {};
  #|    if (typeof Proxy !== 'function') { return target }
  #|    return new Proxy(target, {
  #|      get: function (object, key) {
  #|        if (typeof key === 'symbol') { return object[key] }
  #|        if (Object.prototype.hasOwnProperty.call(object, key)) { return object[key] }
  #|        return function () {
  #|          throw new Error('沙盒里没有实现 ' + label + '.' + String(key))
  #|        };
  #|      }
  #|    });
  #|  }
  #|  var modules = {
  #|    '@earendil-works/pi-coding-agent': stubModule('@earendil-works/pi-coding-agent', {
  #|      defineTool: function (tool) { return tool },
  #|      Type: Type,
  #|      VERSION: 'pi-moon-ext'
  #|    }),
  #|    '@earendil-works/pi-tui': stubModule('@earendil-works/pi-tui'),
  #|    // pi-ai 把 typebox 的 Type re-export 出来了（pi 的 examples 直接从
  #|    // 这里拿 Type 描述工具参数），所以它不能是纯桩。
  #|    '@earendil-works/pi-ai': stubModule('@earendil-works/pi-ai', {
  #|      Type: Type,
  #|      StringEnum: Type.StringEnum
  #|    }),
  #|    'typebox': typeboxModule,
  #|    '@sinclair/typebox': typeboxModule
  #|  };
  #|  globalThis.__pi_ext_require = function (specifier) {
  #|    var name = String(specifier)
  #|    if (Object.prototype.hasOwnProperty.call(modules, name)) { return modules[name] }
  #|    // 子路径（`typebox/value`）回落到主模块：shim 只有一个实现。
  #|    var slash = name.indexOf('/')
  #|    while (slash > 0) {
  #|      var head = name.slice(0, slash)
  #|      if (Object.prototype.hasOwnProperty.call(modules, head)) { return modules[head] }
  #|      slash = name.indexOf('/', slash + 1)
  #|    }
  #|    throw new Error('沙盒里没有模块 "' + name + '"');
  #|  };
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
  #|  // pi-moon 只接了「注册工具 / 命令 / 事件」这三类。其余宿主 API（渲染器、
  #|  // 快捷键、flag、UI……）用一个兜底：调用记进 registry.unsupported 并返回
  #|  // 空操作 —— 扩展不会因为少一个渲染钩子就在装载时崩掉。
  #|  registry.unsupported = [];
  #|  globalThis.pi = (typeof Proxy === 'function')
  #|    ? new Proxy(api, {
  #|        get: function (target, key) {
  #|          if (typeof key === 'symbol') { return target[key] }
  #|          if (Object.prototype.hasOwnProperty.call(target, key)) { return target[key] }
  #|          return function () {
  #|            var name = String(key);
  #|            if (registry.unsupported.indexOf(name) < 0) { registry.unsupported.push(name) }
  #|            return function () {};
  #|          };
  #|        }
  #|      })
  #|    : api;
  #|})();
  #|globalThis.__pi_ext_module = { exports: {} };

///|
/// 预置脚本 + 扩展源 + 收尾，拼成一次 eval 的完整脚本。
///
/// 扩展源被包进一个 CJS 形状的函数里：`export default` 已经被
/// `rewrite_exports` 改写成 `module.exports.default =`，于是沙盒不需要模块
/// 加载器也能跑。
///|
/// 扩展初始化（`export default` 的调用）包一层，把 stack 塞进错误消息。
/// 沙盒把异常转成文本时只拿得到 message —— 没有 stack 就只能看到
/// 「TypeError: not a function」这种没头没尾的话。
let install_guard : String =
  #|function __pi_ext_install(factory) {
  #|  try {
  #|    factory(globalThis.pi);
  #|  } catch (error) {
  #|    // QuickJS 的 `stack` 只有帧、没有首行 message，得自己拼。
  #|    var message = (error && error.message) ? String(error.message) : String(error);
  #|    var stack = (error && error.stack) ? String(error.stack) : '';
  #|    throw new Error('扩展初始化失败：' + message + (stack ? '\n' + stack : ''));
  #|  }
  #|}

///|
pub fn wrap_extension(source : String, cjs? : Bool = false) -> String {
  // jiti 转译出来的已经是 CJS（自带 `exports.default = …`），不能再改写；
  // 没工具链时退回「原样源码 + 自己改写 export」。
  let body = if cjs { source } else { rewrite_exports(source) }
  prelude_source +
  "\n" +
  "(function (module, exports, require) {\n" +
  body +
  "\n})(__pi_ext_module, __pi_ext_module.exports, __pi_ext_require);\n" +
  install_guard +
  "\nif (typeof __pi_ext_module.exports.default === 'function') {\n" +
  "  __pi_ext_install(__pi_ext_module.exports.default);\n" +
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
