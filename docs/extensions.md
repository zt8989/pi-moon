# 扩展：pi 的扩展进 wasm 沙盒

pi 的扩展是 TypeScript 模块，在 pi 进程里跑，拿的是完整的 `ExtensionAPI`。
pi-moon 把它们装进 **pi 自己的 quickjs.wasm**（[`quickjs-wasi`](https://github.com/vercel-labs/quickjs-wasi)，
pi 的 codemode 用的就是它），编译产物是一份 **VM 快照**；启动时只是把那份内存
`memcpy` 回去。运行期不碰 Node，也不需要为某个扩展重新解析一次 JS。

```text
启动前（一次）                                   启动后（每次）
  发现扩展 ──► 体检 ──► 打包成一段 JS ──► 沙盒 eval ──► 快照落盘
                            │                              │
                 命中缓存则整段跳过 ─────────────────────────┤
                                                           ▼
                                           恢复快照（memcpy 内存 + 栈指针）
```

## 为什么是 wasm + 快照

因为快照只能这么来。快照要拷的是「VM 的全部状态」，也就是：

- 一整块**线性内存**（JS 堆、字符串、对象图全在里面）；
- wasm 的 `__stack_pointer`；
- quickjs 的 runtime / context 指针。

这三样只有在 wasm 里才是一段「可以整体拷进拷出的字节」。原生 QuickJS 的堆是
malloc 给的地址，落盘就失效 —— 于是「编译一次、启动只 memcpy」这条路只有 wasm 走得通。

宿主是 vendored 的 [wasm3](https://github.com/wasm3/wasm3)（C，MIT，无依赖），
走 `core/ext` 的 `native-stub` 编进可执行文件。`quickjs.wasm` 的 import 面很小，
一共 12 个：6 个 `env.host_*`（时钟、中断、Promise 拒绝、模块加载、宿主函数回调）
加 6 个 WASI（`fd_write` / `clock_time_get` / `random_get` …）。这些全部在
`core/ext/host/ext_host.c` 里实现，文件系统一律 `ENOSYS`：

```text
core/ext/
  ext.mbt          类型：来源、跳过原因、装载步骤、缓存键（FNV-1a 64）
  discover.mbt     <agent dir>/extensions、<cwd>/.pi/extensions、--extension
  scan.mbt         import 说明符体检（node 内建 / 相对路径 / 裸包）
  prepare.mbt      启动前的计划与缓存判定
  compile.mbt      eval → 快照 → 落盘；元数据 JSON
  prelude.mbt      沙盒里的 `pi` 对象（registerTool / registerCommand / on）
  vm.mbt           宿主形状 + 快照头解析
  vm_native.mbt    wasm3 的 MoonBit FFI
  vm_js.mbt        js 后端占位（见「已知缺口」）
  wasm_resolve.mbt 找 pi 装机里的 quickjs.wasm
  host/ext_host.c  实例化 / WASI import / 快照序列化
  host/wasm3/      vendored wasm3
```

## 一次启动的时序

1. **发现**（`discover`）：`<agent dir>/extensions` 与 `<cwd>/.pi/extensions`，
   单文件 `.ts/.mts/.cts/.js/.mjs/.cjs` 或「目录 + `index.ts`/`index.js`」。
   `node_modules` 与点开头的目录不递归。
2. **体检**（`scan`）：在**编译后**的 JS 上扫 `import` / `import()` / `require()`
   的说明符。命中下列任一条就跳过，不装垫片：
   - `node:*` 或 Node 内建名单里的裸名（`fs`、`child_process`、`worker_threads` …）；
   - 相对路径（`./x.js`）与裸包名（`lodash`）—— 沙盒里没有模块加载器。
   在编译后扫是有意的：`import type { ExtensionAPI } from "…"` 这类纯类型导入
   编译后就不存在了，不该被误判。
3. **缓存键**（`cache_key`）：`FNV-1a 64(prelude_version ∥ sandbox_version ∥ 源码)`。
   三者任一变化就重编译。文件在 `<agent dir>/cache/pi-moon/ext/<key>.snapshot`，
   旁边一份 `<key>.json` 存注册清单（工具名、命令名、钩子事件）。
4. **编译**（`compile_extension`）：`prelude + 扩展源 + 收尾` 拼成一段 script，
   在一个刚 `qjs_init` 过的 VM 里 eval；扩展的注册动作往纯数据的 `pi` 对象上累加，
   收尾把清单 `JSON.stringify` 回来，然后整块内存拍成快照落盘。
5. **启动**：命中缓存的扩展直接读快照；未命中的在启动前编译一次。
   单个扩展失败只留一条 `[ext]` 诊断，不挡启动。

运行期的成本因此是「读一个 1.3MB 文件 + memcpy」，与本机 qjs 引擎无关。

## 扩展里能用到什么

沙盒给一个与 pi 同名同形状的 `pi` 对象（`core/ext/prelude.mbt`）：

| API | 沙盒里 | 说明 |
| --- | --- | --- |
| `registerTool(tool)` | ✅ 注册 | 名字/描述/参数 schema 落进清单；`execute` 留在沙盒里 |
| `registerCommand(name, def)` | ✅ 注册 | 同上 |
| `on(event, handler)` | ✅ 注册 | 钩子按 `事件 → handler 序号` 记账 |
| `registerProvider` / `registerMcpServer` | ⚠️ 计数 | 要网络 / 子进程，沙盒给不了；只记「这个扩展要了它」 |
| `appendEntry` / `sendMessage` / `setActiveTools` | ⚠️ 空实现 | 会话与工具集是宿主的事 |

模块形态：扩展源按 pi 的约定 `export default function (pi) { … }`。沙盒没有 ESM
加载器，所以 `rewrite_exports` 把顶层 `export default` 改写成
`module.exports.default = …`，再把源码包进一个带 `module` / `exports` 的函数里。
`export { a }` / `export * from` 整行注掉 —— 宿主用不上具名导出，注册靠的是副作用。

## 与 pi 的差异（有意为之）

| 事项 | pi | pi-moon |
| --- | --- | --- |
| 运行位置 | 同进程，jiti 直接跑 TS | wasm 沙盒（quickjs.wasi + wasm3 宿主） |
| 编译时机 | 每次加载都 jiti 转译 | 只在启动前，之后走快照缓存 |
| Node 依赖 | 随便用 | 一律不装：命中就跳过，记一条诊断 |
| 隔离 | 与 pi 同权限 | 无文件系统、无网络、无子进程 |
| 快照格式 | `serializeSnapshot` | 逐字节同格式（"QJSS" + v2 + 扩展元数据 + 线性内存） |

快照格式对齐的用处：同一份 `.snapshot` 在 pi 的 quickjs-wasi 里也能 `restore`，
反过来也一样 —— 调试时可以直接拿 node 打开看。

## 现在到哪一步了

已验证（`core/ext/*_wbtest.mbt`，18 项）：

- wasm3 上跑起 pi 的 `quickjs.wasm`，eval / 异常 / quickjs 版本串；
- 快照 → 新实例恢复 → 状态还在（`x*2 == 82` 那种跨实例验证）；
- 发现 + 体检 + 缓存键 + 命中/未命中判定；
- 真实编译一个扩展：快照落盘、元数据 JSON、第二次命中缓存；
- 带 `node:fs` 的扩展按 `NodeDependency` 跳过；
- 找不到 `quickjs.wasm` 时按 `NoCompiler` 跳过。

还没接（下一步）：

1. **运行期桥接**：把恢复出来的 VM 接到 pi-moon 的环上 —— `registerTool` 的工具
   进 `core/tools` 的定义表、`execute` 通过 `host_call` 回调沙盒、`on(...)` 的钩子
   在 `tool_call` / `turn_end` 等 action 处派发。C 侧的 `host_call` 现在是「没接住」
   的桩，桥接时改成把 `name + argsJson` 交给 MoonBit 侧。
2. **TS 扩展**：目前只跑纯 JS。`.ts` 需要在启动前用 node + pi 自带的 jiti 转译
   （`NoCompiler` 就是给这条路径留的位置）。
3. **缓存清理**：改了源码会换键，旧快照没人删。需要一个 LRU（按 mtime / 大小）。
4. **js 后端**：`vm_js.mbt` 是占位。node 上可以直接用 `quickjs-wasi` 包，快照格式
   相同，接起来是一段 `import()`。

## 手动试

```bash
# 项目级扩展放这儿
mkdir -p .pi/extensions
cat > .pi/extensions/demo.js <<'JS'
export default function (pi) {
  pi.registerTool({ name: "demo_tool", description: "演示工具" });
  pi.registerCommand("demo", { description: "演示命令" });
  pi.on("turn_end", function () { return null; });
}
JS

pi-moon -p "hi"        # 第一次：启动前编译，落快照
pi-moon -p "hi"        # 第二次：命中缓存，不碰 JS 引擎
```

诊断走 stderr，形如：

```text
[ext] 跳过扩展 "bad"：依赖 Node 专有模块 "node:fs"，不加载
[ext] 已装载：demo
```

`PI_QUICKJS_WASM` 可以显式指定 wasm 路径；默认去
`<agent dir>/install/releases/<版本>/node_modules/quickjs-wasi/quickjs.wasm` 里
挑版本号最大的那份。
