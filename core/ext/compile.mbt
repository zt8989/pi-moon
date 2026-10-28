// 启动前编译：把扩展源跑进沙盒，抓快照落盘。
//
// 一次编译 = 预置脚本 + 扩展源 + 收尾（把注册结果 JSON 化），在一个**刚
// qjs_init 过的** VM 里 eval，然后整块内存拍成快照。此后这个扩展的装载
// 代价就是「读一个文件 + memcpy 一块内存」，不再碰 JS 引擎。
//
// 落盘的只有快照；注册结果（工具名、命令名、事件钩子个数）跟着一起返回，
// 宿主用它决定运行期怎么调。

///|
/// 编译产物：快照写在哪、扩展注册了什么。
pub(all) struct CompiledExt {
  name : String
  /// 横幅里显示的标签：单文件是文件名（带后缀），目录式扩展是目录名。
  label : String
  /// 快照文件路径。
  snapshot_path : String
  /// 扩展注册的工具名（顺序即注册顺序）。
  tools : Array[String]
  /// 扩展注册的斜杠命令。
  commands : Array[String]
  /// 扩展挂了钩子的事件名。
  events : Array[String]
} derive(Debug)

///|
/// 编译失败的原因。都是「这个扩展装不进来」，不影响启动。
pub suberror CompileError {
  /// 求值失败（语法错误 / 扩展自己抛异常）。
  Evaluation(String)
  /// 快照写不下去（磁盘满、目录不可写）。
  WriteFailed(String)
  /// 宿主 VM 起不来。
  Sandbox(String)
}

///|
pub fn CompileError::to_string(self : CompileError) -> String {
  match self {
    Evaluation(reason) => "编译失败：" + reason
    WriteFailed(reason) => "写缓存失败：" + reason
    Sandbox(reason) => "沙盒不可用：" + reason
  }
}

///|
/// 从注册结果 JSON 里抽三个清单。
///
/// 预置脚本的形状是固定的，这里用宽松解析：缺字段当空数组，不因为宿主与
/// 预置脚本版本错位就把整次编译判死。
pub fn parse_registry(json_text : String) -> (Array[String], Array[String], Array[String]) {
  let empty : (Array[String], Array[String], Array[String]) = ([], [], [])
  let parsed = @json.parse(json_text) catch { _ => return empty }
  let object = match parsed {
    Json::Object(fields) => fields
    _ => return empty
  }
  let tools : Array[String] = []
  let commands : Array[String] = []
  let events : Array[String] = []
  match object.get("tools") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Object(fields) =>
            match fields.get("name") {
              Some(Json::String(name)) => tools.push(name)
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  match object.get("commands") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Object(fields) =>
            match fields.get("name") {
              Some(Json::String(name)) => commands.push(name)
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  match object.get("handlers") {
    Some(Json::Object(fields)) =>
      for name, _ in fields {
        events.push(name)
      }
    _ => ()
  }
  (tools, commands, events)
}

///|
/// 注册清单 → JSON（落盘用）。手写而不是走 Json 编码器：字段固定三个数组，
/// 少一层类型转换，读回来也更宽松。
pub fn registry_json(compiled : CompiledExt) -> String {
  "{\"tools\":" +
  json_string_array(compiled.tools) +
  ",\"commands\":" +
  json_string_array(compiled.commands) +
  ",\"events\":" +
  json_string_array(compiled.events) +
  "}"
}

///|
fn json_string_array(items : Array[String]) -> String {
  let parts : Array[String] = []
  for item in items {
    parts.push("\"" + escape_json(item) + "\"")
  }
  "[" + parts.join(",") + "]"
}

///|
fn escape_json(text : String) -> String {
  let out = StringBuilder()
  for character in text {
    match character {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => out.write_char(character)
    }
  }
  out.to_string()
}

///|
/// 读回元数据。文件缺失或坏掉返回 None（调用方据此重新编译）。
pub async fn load_registry(meta_path : String) -> (Array[String], Array[String], Array[String])? {
  let text = @sys.read_text(meta_path) catch { _ => return None }
  let parsed = @json.parse(text) catch { _ => return None }
  let object = match parsed {
    Json::Object(fields) => fields
    _ => return None
  }
  let read = fn(key : String) -> Array[String] {
    let out : Array[String] = []
    match object.get(key) {
      Some(Json::Array(items)) =>
        for item in items {
          match item {
            Json::String(value) => out.push(value)
            _ => ()
          }
        }
      _ => ()
    }
    out
  }
  Some((read("tools"), read("commands"), read("events")))
}

///|
/// 编译一个扩展：eval → 快照 → 落盘。
pub async fn compile_extension(
  source : ExtSource,
  code : String,
  wasm : Bytes,
  snapshot_path : String,
  host? : String = "",
) -> CompiledExt raise CompileError {
  let vm = ExtVm::new(wasm, host~) catch {
    error => raise Sandbox(error.to_string())
  }
  defer vm.free()
  let script = wrap_extension(code)
  let registry = vm.eval(script, filename=source.path) catch {
    error => {
      let reason = error.to_string()
      // `.ts` 的语法（类型标注、interface、enum）不是 JS：沙盒只能跑转译后的
      // 源码，而转译这一步（node + jiti）还没接。给一句人话，别只丢 SyntaxError。
      let is_typescript = source.path.has_suffix(".ts") ||
        source.path.has_suffix(".mts") ||
        source.path.has_suffix(".cts")
      if is_typescript && reason.contains("SyntaxError") {
        raise Evaluation(
          reason + "（.ts 需要启动前转译成 JS，这条链路还没接；纯 JS 的扩展不受影响）",
        )
      }
      raise Evaluation(reason)
    }
  }
  let snapshot = vm.snapshot() catch {
    error => raise Sandbox(error.to_string())
  }
  let (tools, commands, events) = parse_registry(registry)
  let directory = match snapshot_path.rev_find("/") {
    Some(index) => snapshot_path[:index].to_owned()
    None => "."
  }
  @sys.mkdir_p(directory) catch {
    error => raise WriteFailed(error.to_string())
  }
  @sys.write_bytes(snapshot_path, snapshot) catch {
    error => raise WriteFailed(error.to_string())
  }
  let compiled = {
    name: source.name,
    label: ext_label(source),
    snapshot_path,
    tools,
    commands,
    events,
  }
  // 元数据是可再生的：写不下去只影响下次启动多编译一遍，不影响这次。
  let meta_path = snapshot_path[:snapshot_path.length() - ".snapshot".length()].to_owned() +
    ".json"
  @sys.write_text(meta_path, registry_json(compiled)) catch { _ => () }
  compiled
}

///|
/// 找 wasm：显式路径优先（测试与离线环境），否则从 agent 目录里解析。
async fn resolve_wasm(agent_dir : String, wasm_path : String?) -> (String, Bytes)? {
  match wasm_path {
    Some(path) => {
      let bytes = @sys.read_bytes(path) catch { _ => return None }
      Some((path, bytes))
    }
    None => load_quickjs_wasm(agent_dir)
  }
}

///|
/// 横幅标签：pi 显示的是「装了什么」—— 单文件带后缀（`demo.js`），
/// 目录式扩展是目录名（`demo`）。
pub fn ext_label(source : ExtSource) -> String {
  let file_name = base_name(source.path)
  if is_source_file(file_name) {
    file_name
  } else {
    base_name(source.dir)
  }
}

///|
/// 把「抛异常」收成 Result，好在 match 里分叉（MoonBit 的 match 臂不能直接 catch）。
async fn compile_or_error(
  source : ExtSource,
  code : String,
  wasm : Bytes,
  snapshot_path : String,
  host : String,
) -> Result[CompiledExt, CompileError] {
  let result = try compile_extension(source, code, wasm, snapshot_path, host~) catch {
    error => return Err(error)
  }
  Ok(result)
}

///|
/// 把计划推进到底：需要编译的编译掉，命中的记下来。
///
/// 单个扩展失败不影响别的扩展，也不影响启动 —— 失败原因进 diagnostics。
pub async fn compile_plan(
  plan : ExtPlan,
  agent_dir : String,
  wasm_path? : String? = None,
) -> (Array[CompiledExt], ExtPlan) {
  let diagnostics = plan.diagnostics.copy()
  let entries : Array[ExtEntry] = []
  let wasm = resolve_wasm(agent_dir, wasm_path)
  let compiled_done : Array[CompiledExt] = []
  for entry in plan.entries {
    match entry.step {
      Skip(_) => entries.push(entry)
      Cached(cache_key~, ..) => {
        let snapshot_path = ext_cache_path(agent_dir, cache_key)
        let meta = load_registry(ext_meta_path(agent_dir, cache_key))
        let (tools, commands, events) = match meta {
          Some(meta) => meta
          None => ([], [], [])
        }
        compiled_done.push({
          name: entry.source.name,
          label: ext_label(entry.source),
          snapshot_path,
          tools,
          commands,
          events,
        })
        entries.push(entry)
      }
      Compile(source~, path~, ..) => {
        match wasm {
          None => {
            diagnostics.push(
              "跳过扩展 \"" + entry.source.name + "\"：" + NoCompiler.to_string(),
            )
            entries.push({ source: entry.source, step: Skip(reason=NoCompiler) })
          }
          Some((wasm_path, bytes)) =>
            match compile_or_error(
              entry.source,
              source,
              bytes,
              path,
              quickjs_package_dir(wasm_path),
            ) {
              Ok(result) => {
                compiled_done.push(result)
                entries.push(entry)
              }
              Err(error) => {
                diagnostics.push(
                  "编译扩展 \"" + entry.source.name + "\" 失败：" + error.to_string(),
                )
                entries.push(entry)
              }
            }
        }
      }
    }
  }
  (compiled_done, { entries, diagnostics })
}
