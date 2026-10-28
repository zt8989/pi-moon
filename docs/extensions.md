# 扩展：pi 的扩展跑在独立 bun 宿主里

pi 的扩展是 TypeScript 模块，在 pi 进程里跑，拿的是完整的 `ExtensionAPI`。
pi-moon 用的也是同一份扩展、同一份 `@earendil-works/*` 包，但不嵌 JS 引擎：
扩展跑在一个 **独立的 bun 进程**里，两边按行说 JSON。

形状照 magpie（Go 主程序 + Bun 插件宿主子进程）：

```text
pi-moon (MoonBit native)                 ext host (bun)
  发现扩展 ─┐                         ┌─ 打包（Bun.build，命中缓存则跳过）
  算缓存键 ─┼──► spawn bun ──────────►├─ 加载（bun 自己转译 TS）
  读注册表 ◄┘   --mode load（一次性） └─ 回传 JSON：工具 / 命令 / 事件钩子
```

## 为什么是宿主进程，不是嵌引擎

一开始试的是「把 pi 的 `quickjs.wasm` 用 wasm3 嵌进 native 二进制、编译产物存
VM 快照」。能跑，但代价很硬：

| | 嵌 wasm 引擎 | 宿主子进程 |
| --- | --- | --- |
| 同一段 JS（2M 次循环） | 1675 ms | 76 ms（bun/V8 级） |
| 自定义 C | ~1000 行（wasm3 + WASI shim + 快照序列化 + `host_call` 桥） | 0 |
| TypeScript | 得先自己转译，且只能跑纯 JS | bun 直接跑 |
| npm 依赖 | 解析不了 | 用 pi 装机里的 node_modules |
| Node API | 全禁（否则等于没沙盒） | 放行，靠路径白名单 |
| 启动成本 | 恢复 1.3MB 快照 | 起 bun（首次打包较慢，之后 ~50–200ms） |

结论：**宿主外置**。magpie 也是这么做的（`the plugin host quit` / `Bun has no
build for %s` 那些字符串就是它的插件宿主逻辑）。

代价说清楚：运行期依赖 `bun` 可执行文件（找不到就整体关闭扩展，并给一条诊断）。
`jiti` 也不再需要 —— bun 自己转译 TS。

## 一次启动的时序

1. **发现**（`discover.mbt`）：`<agent dir>/extensions` 与
   `<cwd>/.pi/extensions`，单文件 `.ts/.mts/.cts/.js/.mjs/.cjs` 或
   「目录 + `index.ts`/`index.js`」；`node_modules` 与点开头的目录不递归。
2. **缓存键**（`ext.mbt`）：`FNV-1a64(prelude_version ∥ host_cache_version ∥ 源码)`。
   产物落在 `<agent dir>/cache/pi-moon/ext/host/build/<key>.mjs`。
3. **装载**（`host.mbt`）：`bun <缓存>/ext_host.mjs --mode load …`，一次性进程：
   打包（缓存未命中才跑）→ 加载 → 回传注册表 → 退出。
4. **汇总**（`prepare.mbt`）：把工具名 / 命令名 / 事件名汇总成 `StartupExt`，
   诊断打到 stderr（`[ext]` 前缀），横幅里出 `[Extensions]` 段。

单个扩展失败只留一条诊断，不影响别的扩展，也不挡启动。

## 文件系统白名单

扩展能自由用 `node:fs`，但路径按**允许根目录**过滤：`cwd`、agent 目录、
`TMPDIR`。越界读写在调用点抛错：

```text
扩展沙盒拒绝读路径 /etc/hosts（只允许 cwd / agent 目录 / 临时目录）
```

实现方式有个坑要说清楚：`Bun.build` 的插件**看不到内置模块**
（`node:fs` 在插件之前就被解析成 external 了），所以策略是在**产物后处理**里做的 ——
把产物中的 `node:fs` / `node:fs/promises` / `node:child_process` 导入改指向
`build/policies/*.mjs` 这几个 sidecar，由它们包一层路径检查再转出真模块。
产物很小（几百字节），import 语句是可枚举的文本。

这是 **JS 层的门禁**：挡得住「顺手读了不该读的文件」，挡不住刻意绕过
（动态拼路径、`process.binding`）。真正的 OS 级隔离要平台支持，macOS 上的
`sandbox-exec` 已经不能用（实测直接 `Abort trap: 6`）。

## 产物里的两个坑（都实测踩过）

1. **不能给产物加 `?v=` 查询串**。产物里的裸包 import 要按**产物路径**向上
   找 node_modules，带查询串会把 importer 变成一个找不到的路径 —— 报
   `Cannot find module … from '<path>?v=…'`。产物名就是内容哈希，源码变了
   键就变，不需要额外破缓存。
2. **裸包 import 要改写成绝对路径**。bun 在**进程启动时**就固定了解析根，
   而 `node_modules` 符号链接是启动后才建的（缓存目录是新建的），于是运行期
   import 找不到包 —— 表现为「同样的命令在 shell 里手动跑却正常」。所以构建时
   标 external，构建后按 `modulesDir` 解析成 `file://` 绝对 URL 写回产物。

另外 `bunfig.toml` 里关掉了自动安装（`[install] auto = "disable"`）：
否则解析不到的包会被悄悄从 npm 下载，「能不能装」取决于网络而不是这台机器
上装了什么。

## 扩展里能用到什么

宿主给一个与 pi 同名同形状的 `pi` 对象，`registerTool` / `registerCommand` /
`on` 是真实现（注册结果回传给 pi-moon），其余宿主 API 走兜底代理：调用会被
记进 `registry.unsupported` 并返回空操作 —— 少一个渲染钩子不该让整个扩展装不进来。

| API | 状态 |
| --- | --- |
| `registerTool(tool)` | ✅ 注册（`defineTool` 是恒等，`typebox` 是真包） |
| `registerCommand(name, def)` | ✅ 注册 |
| `on(event, handler)` | ✅ 注册（派发见「还没接」） |
| `registerEntryRenderer` / `registerFlag` / `registerShortcut` / UI | ⚠️ 兜底空操作，记进 `unsupported` |
| Node API（`fs` / `child_process` / `process` …） | ✅ 可用，路径按白名单 |
| 任意 npm 包 | ✅ 只要 pi 装机的 node_modules 里有 |

**兼容面实测**：pi 官方 `examples/extensions/` 的 70 个单文件示例 **70 个全部
装载成功**（早前「嵌 wasm + 拒绝 Node」的方案是 53 装载 / 17 跳过）。

## 代码地图

```text
core/ext/
  ext.mbt            类型：来源、装载步骤、缓存键（FNV-1a 64）
  discover.mbt       <agent dir>/extensions、<cwd>/.pi/extensions、--extension
  pi_modules.mbt     找 pi 装机里的 node_modules（宿主解析扩展 import 的包）
  prepare.mbt        启动前的计划 + 调宿主装载 + 汇总 StartupExt
  host.mbt           宿主进程：路径准备、spawn bun、解析回传 JSON
  host_script.mbt    宿主脚本（由 scripts/embed-host.mjs 从 host/ext_host.mjs 生成）
  host/ext_host.mjs  宿主脚本源码：Bun.build 缓存、策略 sidecar、JSON-lines RPC
scripts/embed-host.mjs  生成器（改完 .mjs 跑一次）
```

`host_script.mbt` 与 `host/ext_host.mjs` 有同步测试兜底：改了 `.mjs` 忘了重新
生成，`moon test` 会红。

## 还没接

1. **运行期派发**：宿主脚本已经有 `--mode serve`（`call` 工具 / `emit` 事件
   钩子 / `command` 命令），pi-moon 侧还没起常驻宿主并接进环。所以现在扩展
   能「装载并注册」，但 `execute` 与事件钩子还不会被调用。
2. **产物清理**：源码改了会换键，旧产物没人删（`build/` 会缓慢变大）。
3. **沙盒强度**：JS 层白名单，不是 OS 级隔离（见上）。

## 手动试

```bash
mkdir -p .pi/extensions
cat > .pi/extensions/demo.ts <<'TS'
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
const tool = defineTool({
  name: "demo_tool",
  description: "演示工具",
  parameters: Type.Object({ text: Type.String() }),
  async execute(_id: string, params: { text: string }) {
    return { content: [{ type: "text", text: params.text }] };
  },
});
export default function (pi: ExtensionAPI) {
  pi.registerTool(tool);
  pi.on("turn_end", async () => null);
}
TS

pi-moon -p "hi"     # 第一次：打包 + 装载
pi-moon -p "hi"     # 第二次：命中产物缓存
```

诊断走 stderr：

```text
[ext] 已装载：demo
[ext] 扩展 "x" 用了未实现的宿主 API：registerFlag
[ext] 装载扩展 "y" 失败：…
```

`PI_PI_MODULES` 可以显式指定 pi 的 node_modules；默认去
`<agent dir>/install/releases/<版本>/node_modules` 里挑版本号最大的那份。
`PI_MOON_BUN` 可以指定 bun 可执行文件。
