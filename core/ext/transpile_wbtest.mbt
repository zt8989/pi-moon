// 转译与「pi 风格 import」的端到端测试：真起 node + jiti，真跑沙盒。
//
// 环境没有 node / jiti（精简机器）时整组跳过 —— 这是环境缺失，不是回归。

///|
async fn transpile_root() -> String {
  let random = @random.Rand::Rand()
  let dir = "_build/ext-ts-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000).to_string()
  @sys.mkdir_p(dir) catch { _ => () }
  dir
}

///|
async fn write_ts(directory : String, name : String, body : String) -> String {
  @sys.mkdir_p(directory + "/extensions") catch { _ => () }
  let path = directory + "/extensions/" + name
  @sys.write_text(path, body) catch { _ => () }
  path
}

///|
/// 找到 wasm 与转译器；缺一个就返回 None（测试跳过）。
async fn transpile_env() -> (String, Bytes, String, Transpiler)? {
  let found = quickjs_files()
  let (wasm_path, wasm) = match found {
    Some(found) => found
    None => return None
  }
  let host = quickjs_package_dir(wasm_path)
  let transpiler = match find_transpiler(host) {
    Some(transpiler) => transpiler
    None => return None
  }
  Some((wasm_path, wasm, host, transpiler))
}

///|
/// 一个「像 pi 扩展」的 TS 源：type-only import、defineTool、typebox 参数。
let pi_style_extension : String =
  #|import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent"
  #|import { Type } from "typebox"
  #|
  #|export default function (pi: ExtensionAPI) {
  #|  const tool = defineTool({
  #|    name: "counter",
  #|    description: "计数",
  #|    parameters: Type.Object({
  #|      count: Type.Number(),
  #|      label: Type.Optional(Type.String())
  #|    }),
  #|    execute: async (id: string, params: { count: number }) => ({ ok: true })
  #|  })
  #|  pi.registerTool(tool)
  #|  pi.on("turn_end", async () => null)
  #|}

///|
async test "transpile：类型擦除 + ESM 转成 CJS" {
  let env = transpile_env()
  let (_, _, _, transpiler) = match env {
    Some(env) => env
    None => return
  }
  let root = transpile_root()
  let path = write_ts(root, "counter.ts", pi_style_extension)
  let code = transpile(transpiler, path) catch {
    error => fail(error.to_string())
  }
  // 类型标注与 `import type` 都不该留下。
  assert_true(!code.contains("ExtensionAPI"))
  assert_true(!code.contains(": number"))
  // 剩下的 import 变成 require —— 沙盒据此接 shim。
  assert_true(code.contains("require(\"typebox\")"))
  assert_true(code.contains("require(\"@earendil-works/pi-coding-agent\")"))
  assert_true(code.contains("exports.default"))
}

///|
async test "compile_plan：pi 风格的 TS 扩展能装，TypeBox 参数变成 JSON Schema" {
  let env = transpile_env()
  let (wasm_path, wasm, host, transpiler) = match env {
    Some(env) => env
    None => return
  }
  let root = transpile_root()
  let agent = root + "/agent"
  let cwd = root + "/project"
  let path = write_ts(agent, "counter.ts", pi_style_extension)
  let _ = path
  let planned = plan(cwd, agent, transpiler=Some(transpiler))
  assert_eq(planned.entries.length(), 1)
  match planned.entries[0].step {
    Skip(reason~) => fail("不该被跳过：" + reason.to_string())
    Cached(..) => fail("首次不该命中缓存")
    Compile(cjs~, ..) => assert_true(cjs)
  }
  let (compiled, after) = compile_plan(planned, agent, wasm_path=Some(wasm_path))
  if compiled.length() != 1 {
    fail(after.diagnostics.to_string())
  }
  let entry = compiled[0]
  assert_eq(entry.tools, ["counter"])
  assert_eq(entry.events, ["turn_end"])
  // 参数 schema 活在快照的 JS 堆里：恢复快照再问一次 registry。
  let snapshot = @sys.read_bytes(entry.snapshot_path) catch {
    error => fail("读不到快照：" + error.to_string())
  }
  let vm = ExtVm::restore(wasm, snapshot, host~) catch {
    error => fail(error.to_string())
  }
  defer vm.free()
  let registry = vm.eval("JSON.stringify(__pi_ext_registry)") catch {
    error => fail(error.to_string())
  }
  // Type.Optional 不该进 required；Type.Number/String 变成 JSON Schema 类型。
  assert_true(registry.contains("\"type\":\"object\""))
  assert_true(registry.contains("\"required\":[\"count\"]"))
  assert_true(registry.contains("\"count\":{\"type\":\"number\"}"))
  assert_true(registry.contains("\"label\":{\"type\":\"string\"}"))
}

///|
test "is_shimmed_package：pi 的四个包（含子路径）放行，node 不放行" {
  assert_true(is_shimmed_package("@earendil-works/pi-coding-agent"))
  assert_true(is_shimmed_package("@earendil-works/pi-tui"))
  assert_true(is_shimmed_package("@earendil-works/pi-ai"))
  assert_true(is_shimmed_package("typebox"))
  assert_true(is_shimmed_package("typebox/value"))
  assert_true(is_shimmed_package("@sinclair/typebox"))
  // 子路径照样放行（require 时回落到主模块）。
  assert_true(is_shimmed_package("@earendil-works/pi-coding-agent/other"))
  assert_false(is_shimmed_package("node:fs"))
  assert_false(is_shimmed_package("lodash"))
  // 体检口径：shim 过的包不算坏说明符。
  assert_eq(first_unsupported_import("import { defineTool } from \"@earendil-works/pi-coding-agent\""), None)
  assert_eq(first_unsupported_import("import { Type } from \"typebox\""), None)
  assert_eq(
    first_unsupported_import("import fs from \"node:fs\""),
    Some((NodeBuiltin, "node:fs")),
  )
}
