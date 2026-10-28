// 启动前转译：把扩展的 TS / ESM 源码变成沙盒能直接 eval 的 CJS。
//
// 用 pi 装机里的 `jiti`（pi 自己加载扩展就用它），所以语义与 pi 一致：
//   - 类型擦除：`import type { ExtensionAPI }` 整条消失，`(pi: ExtensionAPI)`
//     只剩 `(pi)`；
//   - ESM → CJS：`import { defineTool } from "x"` 变成
//     `var m = require("x")` + `(0, m.defineTool)(…)`；
//   - 顶层 `export default` 变成 `exports.default = …`。
//
// 只发生在**缓存未命中**时：命中快照的扩展连源码都不读。

///|
/// 转译器版本。进缓存键 —— jiti 换了、脚本改了这个键就得变。
pub let transpiler_version : String = "jiti/2.7.0+ts"

///|
/// 在 node 里跑的转译脚本（`node -e <script> <jiti.mjs> <源文件>`）。
///
/// 之所以整段塞在字符串里：它必须与 `transpiler_version` 一起被版本化，
/// 单独一个文件容易忘了同步。
let transpile_script : String =
  #|(async () => {
  #|  const { readFileSync } = require('node:fs')
  #|  const { pathToFileURL } = require('node:url')
  #|  const [jitiPath, file] = process.argv.slice(1)
  #|  const { createJiti } = await import(pathToFileURL(jitiPath).href)
  #|  const jiti = createJiti(process.cwd(), {
  #|    interopDefault: false,
  #|    fsCache: false,
  #|    moduleCache: false
  #|  })
  #|  const source = readFileSync(file, 'utf8')
  #|  const code = await jiti.transform({ source, filename: file, ts: true })
  #|  if (typeof code !== 'string') {
  #|    throw new Error('jiti.transform 没有返回字符串')
  #|  }
  #|  process.stdout.write(code)
  #|})().catch((error) => {
  #|  process.stderr.write(String((error && error.message) || error))
  #|  process.exit(1)
  #|})

///|
/// 转译失败。都收敛成「这个扩展装不进来」，不挡启动。
pub suberror TranspileError {
  /// 找不到 node 或 jiti（没装 pi / 精简环境）。
  NoToolchain
  /// 转译本身报错（语法错误、jiti 内部错误）。
  Failed(String)
}

///|
pub fn TranspileError::to_string(self : TranspileError) -> String {
  match self {
    NoToolchain => "找不到 node 或 jiti，无法转译 TypeScript"
    Failed(reason) => "转译失败：" + reason
  }
}

///|
/// 转译工具链：node 可执行文件 + jiti 入口脚本。
pub(all) struct Transpiler {
  node : String
  jiti : String
}

///|
/// 找工具链。jiti 与 quickjs-wasi 是同一层 node_modules 里的兄弟目录 ——
/// 用 quickjs.wasm 的包目录推出来，不另做一套解析。
pub async fn find_transpiler(quickjs_package_dir : String) -> Transpiler? {
  let jiti = parent_dir(quickjs_package_dir) + "/jiti/lib/jiti.mjs"
  let has_jiti = @sys.exists(jiti) catch { _ => false }
  if !has_jiti {
    return None
  }
  // node 走 PATH：与 pi 的启动脚本同一份。找不到就当没有工具链。
  let probe = @sys.run_capture("node", ["--version"], timeout_ms=10000) catch {
    _ => return None
  }
  if probe.exit_code() != 0 {
    return None
  }
  Some({ node: "node", jiti })
}

///|
/// 转译一个源文件，返回 CJS 代码。
pub async fn transpile(
  transpiler : Transpiler,
  source_path : String,
) -> String raise TranspileError {
  let capture = @sys.run_capture(
    transpiler.node,
    ["-e", transpile_script, transpiler.jiti, source_path],
    timeout_ms=30000,
  ) catch {
    error => raise TranspileError::Failed(error.to_string())
  }
  if capture.exit_code() != 0 {
    raise TranspileError::Failed(capture.stderr())
  }
  let code = capture.stdout()
  if code.is_empty() {
    raise TranspileError::Failed("转译结果为空")
  }
  code
}
