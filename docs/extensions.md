# 扩展：pi 的扩展跑在独立 bun 宿主里

pi 的扩展是 TypeScript 模块，在 pi 进程里跑，拿的是完整的 `ExtensionAPI`。
pi-moon 用的也是同一份扩展、同一份 `@earendil-works/*` 包，但不嵌 JS 引擎：
扩展跑在一个 **独立的 bun 进程**里，两边按行说 JSON。

形状照 magpie（Go 主程序 + Bun 插件宿主子进程）：

```text
pi-moon (MoonBit native)                 ext host (bun)
  发现扩展 ─┐                         ┌─ 打包（Bun.build，命中缓存则跳过）
  算缓存键 ─┼──► spawn bun ──────────►├─ 加载（bun 自己转译 TS）
  起常驻宿主┘   --mode serve（常驻）  ├─ 回传 JSON：工具 / 命令 / 事件钩子
                                     └─ 读 stdin：call 工具 / emit 事件
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

**找 bun 有个 Windows 坑**：npm / nvm 装的 bun 在 PATH 上是个 `.cmd` 垫片，而
`CreateProcess` 不认 `PATHEXT`（`.cmd` 得先进 cmd.exe）—— 直接 spawn `bun`
会失败，表现为「`bun --version` 明明能跑，pi-moon 却说找不到 bun」。所以
`find_bun` 会按候选逐个试 `--version`：`bun` → `bun.exe` →
`%USERPROFILE%\.bun\bin\bun.exe` → PATH 里每个目录下的
`node_modules\bun\bin\bun.exe`（垫片旁边的真 exe）。`PI_MOON_BUN` 随时可以
直接指定。

## 一次启动的时序

1. **发现**（`discover.mbt`）：`<agent dir>/extensions` 与
   `<cwd>/.pi/extensions`，单文件 `.ts/.mts/.cts/.js/.mjs/.cjs` 或
   「目录 + `index.ts`/`index.js`」；`node_modules` 与点开头的目录不递归。
2. **缓存键**（`ext.mbt`）：`FNV-1a64(prelude_version ∥ host_cache_version ∥ 源码)`。
   产物落在 `<agent dir>/cache/pi-moon/ext/host/build/<key>.mjs`。
3. **装载**（`serve.mbt`）：`bun <缓存>/ext_host.mjs --mode serve …`。宿主打包
   （缓存未命中才跑）→ 加载 → 把注册表（工具 / 命令 / 事件 / 工具定义）作为
   第一条 `{"event":"ready"}` 行回传，然后**留在那里读 stdin**。
4. **汇总**（`prepare.mbt`）：注册表汇总成 `StartupExt`（工具名 / 命令名 / 事件名 /
   工具定义 + 运行期名册 `ExtRuntime`），诊断打到 stderr（`[ext]` 前缀），横幅
   里出 `[Extensions]` 段。什么都没注的会话当场收掉（不白占一个 bun 进程）。

单个扩展失败只留一条诊断，不影响别的扩展，也不挡启动。
**没有单独的一次性装载步骤**：启动这一下就是装载，宿主随后直接进读循环。

## 运行期：`call` 与 `emit`

一个扩展一个常驻宿主进程。两侧说的话都是一行 JSON：

```jsonc
// 调工具
{"op":"call","id":3,"tool":"demo_tool","toolCallId":"call_7","args":{"text":"hi"}}
{"ok":true,"id":3,"result":{"content":[{"type":"text","text":"hi"}]}}

// 派事件（回执里的 results 目前丢弃：钩子是订阅式的）
{"op":"emit","id":4,"event":"turn_end","payload":{"type":"turn_end","turnIndex":1}}
{"ok":true,"id":4,"results":[null]}
```

三条约束：

- **一次只有一条在途请求**：调用点是 effect 里的 `await`，本来就没有并发；
  `id` 只做自检（对不上说明上一轮的响应有剩，抖掉继续等）。
- **`stdout` 是协议通道**：宿主把 `console.*` 与自己的诊断都写成
  `{"event":"log"}` 行；万一张上还有非 JSON 行（扩展直接 `process.stdout.write`、
  bun 自己报错），读的一侧跳过并留作诊断，而不是把会话判死。
- **宿主报 `{"event":"fatal"}` 或提前退出**：当前调用拿到明确错误，会话标死；
  之后的调用立刻失败，不再写一个已经没人的管道。

### 工具

路由在 `run_tools` effect 里（`core/provider/effect.mbt` 的 `ExternalTools`）：

- 名字归扩展 → 宿主跑 `execute`，返回值折成内核的内容块（`text` → `Text`，
  `image` 的 `data`/`mimeType` → data URL），`isError` 决定 `is_error`；
- 名字不归扩展 → `@tools.execute`，八个内置工具照旧。

扩展工具的**启用检查**读 `state.prompt.tools`，与内置工具同一口径：没声明给
模型的工具即使被硬调也只会拿到「未知工具」。

它们默认是**常开**的（pi 里也是扩展自己把工具挂上去）：`--no-tools` 与
`--exclude-tools <name>` 能关掉，REPL 里的 `/tools <list>` 只换内置那一份，
扩展工具照旧在。

### 事件

`on(event, handler)` 注册的钩子由两侧分别派发：

| 事件 | 谁派发 | 载荷（字段名照 pi，内核没有的不编） |
| --- | --- | --- |
| `turn_start` | 环上的 action 流（`@runtime.EventSink`） | `{type, turnIndex, timestamp}` |
| `turn_end` | 同上 | `{type, turnIndex, timestamp}` |
| `tool_execution_start` | `run_tools` effect，**工具真的跑之前** | `{type, toolCallId, toolName, args}` |
| `tool_execution_end` | 同上，工具跑完 | `{type, toolCallId, toolName, content, isError}` |

`tool_execution_*` **对所有工具都发**（内置的也发）—— pi 就是这个口径，扩展靠它
做审计、脱敏、提醒。`turn_*` 走异步事件汇：归约是同步纯函数，事件在**下一个
effect 边界**按 action 顺序送达（于是 `turn_start` 一定早于它那一回合的 LLM 调用）。

只发给**挂了这个钩子**的会话：没挂的扩展不该为一次空派发付一次往返。
钩子抛错只影响它自己那一格（宿主逐条 try/catch，回执的 `results` 里带
`{error}`），传输错也不掐回合；会话变死之后下一次调用才会报错。

等 `ready` 有 **120s 上限**：首次要跑 `Bun.build`（实测 10s 上下），但宿主卡死
时不该把整个 pi-moon 一起挂在那里。运行期的 `call` 故意**不**设超时 —— 打断
一次工具执行就丢了一条 toolResult，消息序列就不合法了。

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

## 产物里的几个坑（都实测踩过）

1. **不能给产物加 `?v=` 查询串**。产物里的裸包 import 要按**产物路径**向上
   找 node_modules，带查询串会把 importer 变成一个找不到的路径 —— 报
   `Cannot find module … from '<path>?v=…'`。产物名就是内容哈希，源码变了
   键就变，不需要额外破缓存。
2. **裸包 import 要改写成绝对路径**。bun 在**进程启动时**就固定了解析根，
   而 `node_modules` 符号链接是启动后才建的（缓存目录是新建的），于是运行期
   import 找不到包 —— 表现为「同样的命令在 shell 里手动跑却正常」。所以构建时
   标 external，构建后按 `modulesDir` 解析成 `file://` 绝对 URL 写回产物。
3. **入口路径在 Windows 上是 `C:\…`**，既不以 `/` 也不以 `.` 开头。构建插件的
   `onResolve` 如果只认这两种，就把入口当裸包 → 解析成绝对路径又标 external，
   `Bun.build` 直接报 `entry point cannot be marked as external`（Linux / macOS
   的入口以 `/` 开头，所以这个坑只在 Windows 上露）。现在用 `path.isAbsolute`
   判。
4. **裸包的解析起点不止一个**。`typebox` 这类包装在
   `@earendil-works/pi-coding-agent/node_modules` 里（pi 自己的依赖），从
   `node_modules` 根 resolve 不到。pi 的扩展在 pi 进程里能 import 到它，是因为
   解析链从 pi 包开始 —— 宿主现在也把 pi 包目录当成第二个起点。

`node_modules` 那层链接只是**兜底**（给运行期自己 `require` 一个包的扩展）：
Windows 上建目录符号链接要特权（Developer Mode / 管理员），普通用户是 EPERM，
所以那里改用 **junction**。

另外 `bunfig.toml` 里关掉了自动安装（`[install] auto = "disable"`）：否则解析
不到的包会被悄悄从 npm 下载，「能不能装」取决于网络而不是这台机器上装了
什么。

## 扩展里能用到什么

宿主给一个与 pi 同名同形状的 `pi` 对象，`registerTool` / `registerCommand` /
`on` 是真实现（注册结果回传给 pi-moon），其余宿主 API 走兜底代理：调用会被
记进 `registry.unsupported` 并返回空操作 —— 少一个渲染钩子不该让整个扩展装不进来。

| API | 状态 |
| --- | --- |
| `registerTool(tool)` | ✅ 注册 + **执行**（`defineTool` 是恒等，`typebox` 是真包） |
| `registerCommand(name, def)` | ✅ 注册（`/name` 入口还没接，见「还没接」） |
| `on(event, handler)` | ✅ 注册 + **派发**（订阅式：不阻断、不改写） |
| `registerEntryRenderer` / `registerFlag` / `registerShortcut` / UI | ⚠️ 兜底空操作，记进 `unsupported` |
| Node API（`fs` / `child_process` / `process` …） | ✅ 可用，路径按白名单 |
| 任意 npm 包 | ✅ 只要 pi 装机的 node_modules 里有 |

**兼容面实测**：pi 官方 `examples/extensions/` 的 70 个单文件示例 **70 个全部
装载成功**（早前「嵌 wasm + 拒绝 Node」的方案是 53 装载 / 17 跳过）。

## 代码地图

```text
core/ext/
  ext.mbt            类型：来源、装载步骤、缓存键（FNV-1a 64）、工具定义
  discover.mbt       <agent dir>/extensions、<cwd>/.pi/extensions、--extension
  pi_modules.mbt     找 pi 装机里的 node_modules（宿主解析扩展 import 的包）
  prepare.mbt        启动前的计划 + 起常驻宿主 + 汇总 StartupExt
  host.mbt           宿主一次性装载（`--mode load`）：spawn bun、解析回传 JSON
  serve.mbt          常驻宿主（`--mode serve`）：行协议、call / emit、ExtRuntime
  host_script.mbt    宿主脚本（由 scripts/embed-host.mjs 从 host/ext_host.mjs 生成）
  host/ext_host.mjs  宿主脚本源码：Bun.build 缓存、策略 sidecar、JSON-lines RPC
scripts/embed-host.mjs  生成器（改完 .mjs 跑一次）
```

`host_script.mbt` 与 `host/ext_host.mjs` 有同步测试兜底：改了 `.mjs` 忘了重新
生成，`moon test` 会红。`--mode load` 仍然保留（`host_wbtest.mbt` 用它单测
「装载」这一半），产品路径走的是 `--mode serve`。

`serve_wbtest.mbt` 有两类测试：真起 bun + 真扩展（缺 bun 时整组跳过），以及一个
**node 写的假宿主** —— 协议层（跨块拼行、跳过 `log` 噪音、`id` 自检、`fatal`）
与 bun 无关，不该因为「这台机器没装 bun」而完全没有覆盖。

## 还没接

1. **钩子的改写 / 阻断语义**：pi 的 `tool_call` 能改参数甚至拦下调用，
   `tool_result` 能改输出、`context` 能换上下文。这里只做到**通知**（发了事件、
   收了回执就丢），改不了任何东西。要用这些语义得先决定「改谁的状态」——
   那是 reducer 的活，不是事件钩子的活。
2. **斜杠命令**：`registerCommand` 注册了，但 REPL / TUI 还没有 `/name` 入口。
3. **扩展工具的进度流**：`ToolProgress` 只有内置 shell 有；扩展工具的中间输出
   目前只能等最终结果。
4. **宿主日志**：扩展的 `console.*` 走协议 `log` 行收进会话诊断（保留最近几条），
   只有传输失败时才会被带出来 —— 想边跑边看，现在得靠扩展自己写文件。
5. **宿主回收**：没有 kill 通道（native 侧只拿到 pid，不跨平台发信号）。收尾靠
   关 stdin 让宿主自己退；扩展卡死在 `execute` 里时，这一次调用会一直等下去。
6. **产物清理**：源码改了会换键，旧产物没人删（`build/` 会缓慢变大）。
7. **沙盒强度**：JS 层白名单，不是 OS 级隔离（见上）。

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
    return { content: [{ type: "text", text: "扩展现身：" + params.text }] };
  },
});
export default function (pi: ExtensionAPI) {
  pi.registerTool(tool);
  pi.on("turn_end", async (event) => {
    // 钩子跑在宿主进程里：console.log 会以 log 行回到 pi-moon。
    console.log("[demo] turn_end turnIndex=" + String((event as any).turnIndex));
    return null;
  });
}
TS

pi-moon -p "hi"                                  # 第一次：打包 + 装载
pi-moon -p "用 demo_tool 说你好"                  # 第二次：命中产物缓存，工具真被执行
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
