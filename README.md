# pi-moon

用 **MoonBit** 复刻 `event-loop-agent`（TypeScript 原项目）的
**循环核心 + 真实 provider**。

一句话：**没有 while 循环的 agent** —— 循环不是写出来的，是 reducer 与副作用
互相 dispatch 出来的环。

```text
                      dispatch(Action)
  界面 / 测试 ─────────────────────────►  reduce(state, action, now)
       ▲                                        │
       │                                        │ 迁移（纯函数）+ 接线（查表）
       │  Agent.state                           ▼
       │                                 (next_state, Cmd[])
       │                                        │
       └────── Action 回流 ◄────────── Cmd 是**数据**，运行时解释它
                (effect 里 dispatch)              LLM 调用 / 工具执行
```

reducer 里没有一个 `await`、没有一个 `fetch`、也没有 while。真正干活的 effect
把结果（包括 token 增量）作为 action 再送回环上。

这是 Elm Architecture（Model / Msg / update / Cmd）落到
[redux-loop](https://github.com/redux-loop/redux-loop) 的形状：`update` 返回
`(model, Cmd)`，而 `Cmd` 是可检视的数据。

## 现状：v0.7 循环核心 + provider + 工具 + 会话 + 压缩 + 终端界面

- 三张表：**迁移表**（action → 下一个状态）、**接线表**（action → Cmd）、
  **effect 表**（`RunAgent` / `RunTools` / `RunCompact` 的真正实现）；
- turn / step 两层容器；重试在**同一个 step 容器**里进行；
- 轨迹树：`user → turn → step → llm.result / tool.*`，tip 规则与错误节点；
- steer / followUp 两条队列（生成中也能说话）；
- 轮数上限、空闲超时、可重试错误分类、`/continue` 的尾消息修复；
- 轨迹渲染：lazygit 风格的轨道树；
- **真实 provider**：读 pi 的 `models.json` / `auth.json` / `settings.json`，
  走 OpenAI 兼容的流式接口，token 增量逐字到达（见 [docs/provider.md](docs/provider.md)）；
- **真实工具**：read / write / edit / bash / powershell / grep / find / ls 八个内置工具，
  默认开启 read / bash / edit / write（与 pi 的 `DEFAULT_TOOL_NAMES` 一致），
  `settings.json` 的 `defaultTools` 支持 `+name` / `-name`（见 [docs/tools.md](docs/tools.md)）；
- **流式工具输出**：shell 命令边跑边读，`ToolProgress` 每 100ms 回到环上；
  `--show-tool-progress` 能在 stderr 直接看到中间输出；
- **会话落盘 / 恢复**：与 pi 同构的双文件布局 ——
  `sessions/--<cwd>--/<ISO 时间戳>_<UUIDv7>.jsonl`（header + 消息）与
  `traces/--<cwd>--/<同名>.jsonl`（装载段 + add/close 轨迹）；退出提示
  `To resume this session: pi-moon --session <id>`，`-s` / `-c` / `--session <id>` 恢复
  （见 [docs/session.md](docs/session.md)）；
- **会话中途换工具**：`tools.changed` 只改当前集，下一次请求追加一条声明消息
  （REPL 里用 `/tools read,bash`；见 [docs/tools.md](docs/tools.md)）；
- **上下文压缩**：`compact.request / done / failed` 三个 action + pi 的切点算法；
  三种触发（手动 `/compact` / 超阈值 / provider 报溢出），摘要是**一条普通消息**，
  落盘后可恢复（见 [docs/compact.md](docs/compact.md)）；
- **项目上下文与技能**：`AGENTS.md` 一族（家目录 + 祖先链）拼进 system prompt 的
  `<project_context>` 段；`SKILL.md` 扫 `~/.pi/agent/skills`、`~/.agents/skills`、
  `<cwd>/.pi/skills` 与祖先链的 `.agents/skills`（`--skill` 可加），清单进
  `<skills>` 段、正文模型按需自己 read，`/skill:<名字>` 显式展开；启动横幅报
  `[Context]` / `[Skills]` / `[Skill conflicts]`
  （见 [docs/context.md](docs/context.md)）；
- **全屏 TUI**：默认交互模式（不带 `-p`，stdin / stdout 都是终端）。布局与
  ela 同形：顶行页签 + 统计 / 中间页（对话或轨迹，`Ctrl+R`）/ 队列面板 + 空隙 +
  composer（工作状态嵌在上框线）+ 两行底栏；生成中 Enter 进 steer、Alt+Enter
  followUp、Ctrl+U 取回队列，Esc 中断或取回，Ctrl+C×2 退出，工具块折叠；
  **文字默认能拖选 / 复制**（鼠标捕获默认关，Ctrl+T 才接管滚轮翻页）；
  `Ctrl+L` / `/thinking` / `/resume` 的模型、思考级别、会话面板覆盖 composer；
  assistant / user 文本走 markdown（AST 解析 + 终端渲染：标题、列表、任务列表、
  引用、表格、围栏代码、```diff 上色、行内 code/bold/link）；**界面颜色全部来自
  pi 的主题**（`settings.json` 的 `theme`，含 light / 自定义主题），24-bit 终端
  用原值，只有 256 色时面板底色退回 16 色名字。
  一次性与管道行为不变（见 [docs/tui.md](docs/tui.md)）。

- **工具块渲染器**：bash 留尾 5 行、edit 彩色 diff，每工具折叠预算不同（见 [docs/tui.md](docs/tui.md)）。

- **pi 扩展（宿主进程）**：发现 `~/.pi/agent/extensions` 与 `<cwd>/.pi/extensions`，
  交给**独立的 bun 进程**装载（形状照 magpie）：bun 自己转译 TS、用 pi 装机的
  node_modules 解析依赖，`Bun.build` 产物按内容哈希缓存，缓存未命中才打包。
  宿主**常驻**（`--mode serve`）：扩展注册的工具走与内置工具同一条 `run_tools`
  effect 真被执行，`turn_start` / `turn_end` / `tool_execution_*` 钩子按行协议派发。
  Node API 可用，文件系统访问按 cwd / agent 目录 / 临时目录白名单卡。
  pi 官方 70 个单文件示例全部装载成功（见 [docs/extensions.md](docs/extensions.md)）。

**还没有**（下一步逐步接）：Web 界面、扩展钩子的改写 / 阻断语义（现在只能「听见」
不能「插手」）、扩展斜杠命令、TUI 的 POSIX 粘贴丢字 / 图片块占位
（见 [docs/tui.md](docs/tui.md) 的「与 ela 的差距」，以及 [docs/extensions.md](docs/extensions.md)
的「还没接」）。

## 跑起来

```bash
moon test                        # 纯表 + 整环 + 轨迹树 + provider + 工具 + 会话 + 压缩 + TUI

# 真实模型：读 ~/.pi/agent/ 下与 pi 同一份配置
moon run cmd/pi-moon                    # 全屏 TUI（默认落盘，可 -c 恢复）
moon run cmd/pi-moon -- -p "用一句话说明什么是 Elm 架构"   # 一次性模式
moon run cmd/pi-moon -- --list-models
moon run cmd/pi-moon -- -P deepseek -m deepseek-chat --thinking low -p "..."

# 工具开关：与 pi 的 -t / -xt / --no-tools 同一套语义
moon run cmd/pi-moon -- -p "读 README.md 的前 3 行"
moon run cmd/pi-moon -- -t read,grep,ls -p "..."
moon run cmd/pi-moon -- -xt bash,powershell -p "..."
moon run cmd/pi-moon -- --no-tools -p "..."

# 看长命令边跑边输出
moon run cmd/pi-moon -- -t bash --show-tool-progress \
  -p '用 bash 执行：for i in 1 2 3; do printf "step$i "; sleep 0.4; done'

# 会话：新建 / 恢复最新 / 交互
moon run cmd/pi-moon -- -p "记住 42"
moon run cmd/pi-moon -- -c -p "我刚才让你记住什么？"
moon run cmd/pi-moon -- -i -s logs/today.jsonl  # -i 与不带参数同义（TUI）
moon run cmd/pi-moon -- -i        # TUI 里 /tools 换工具；/compact 压缩上下文
moon run cmd/pi-moon -- --no-session -p "..."

# 离线演示：假 provider / 假工具，看两棵轨迹树
moon run cmd/main

# JS 后端：同一份代码，跑在 Node 上（需要 node ≥ 18，V8 的 fetch）
moon build --target js cmd/pi-moon
node _build/js/debug/build/pi-moon/cmd/pi-moon/pi-moon.js --list-models
node _build/js/debug/build/pi-moon/cmd/pi-moon/pi-moon.js -p "用一句话说明什么是 Elm 架构"
moon run cmd/main --target js            # 离线演示也能跑 js
moon test --target js                    # 同一套测试换后端（直接造临目录的夹具仍只跑 native）
moon check --target js                   # js 侧的编译门禁（见下）
```

**`moon test` 不带 `--target` 不会完整类型检查 js 那半边**：它只重编当前目标，
js 那串数字可能来自旧计划（实测：`core/sys` 的 js 签名写错，`moon test` 依旧绿，
`moon test --target js` / `moon check --target js` 才报）。改过 `*_js.mbt` 或任何
跨端共用的代码后，两边都跑：

```bash
moon test --target native && moon test --target js
```

**两个后端，一份代码**：`core/sys` 把 native 与 js 真正不一致的四件事
（文件 / 子进程 / 标准流 / 终端）收成一套 API，`*_native.mbt` 走
`moonbitlang/async`，`*_js.mbt` 走 Node 内建模块（`node:fs`、
`node:child_process`、`process.stdout`）。上层（session / tools / provider / context /
TUI）只认这些函数名，所以 `--target js` 编出来的 CLI 是完整的那一个：真模型、
八个工具（bash / powershell 走 `child_process`）、会话落盘与恢复、全屏 TUI。
细节与坑见 [docs/platform.md](docs/platform.md)。

已知差异：js 端没有 `tty.c` 的 Windows 代码页切换（Node 自己按控制台 API 写
UTF-16，不需要），VT 输出开关也是空操作（libuv 已经打开）；REPL 的逐行读用同步
`readSync(0)`。

`pi-moon` 的 **stdout 只有模型回答**（流式逐字），banner / 轨迹 / tokens 全在 stderr，
所以 `pi-moon -p ... > answer.txt` 拿到的是干净的回答。

工具链：`moon 0.1.20261023`；native 是默认后端（`preferred_target = "native"`），
`--target js` 为第二后端，两端都跑同一套测试。

演示输出（节选）：

```text
○  n1 prompt.base: 你是一个只会读文件的演示助手。 0ms
○  n2 prompt.tools: read 0ms (count=1)
○  n3 model.init: demo/demo-echo 0ms (thinking=off, ...)
○  n4 user: README 里写了什么？ 0ms
○  n5 turn.start: 回合 1
│  ○  n6 step.start: 第 1 步 1.0s (provider=demo, model=demo-echo)
│  │  ○  n7 llm.result: 我先读一下 README。 [调用 read] 0ms
│  │  ○  n8 tool.call: read {"path":"README.md"} 500ms (tool=read)
│  │  ○  n9 tool.result: # pi-moon 演示 0ms (tool=read)
│  └─ n10 step.end: 第 1 步结束（1 个工具调用） 0ms (tools=1)
│  ○  n11 step.start: 第 2 步 1.0s
│  │  ○  n12 llm.result: 读完了。工具返回的是「# pi-moon 演示」。 0ms
│  └─ n13 step.end: 第 2 步结束（0 个工具调用） 0ms (tools=0)
└─ n14 turn.end: 回合 1 结束：模型说完了 0ms (reason=completed, steps=2)
```

超时重试（场景 2）的关键形状：**error 不推进 tip，容器不重开**。

```text
│  ○  n6 step.start: 第 1 步 1.5s
│  │  ○  n7 error: request timeout 0ms (kind=timeout, cause=timeout)
│  │  ○  n8 llm.result: 重试之后成功了。 0ms
│  └─ n9 step.end: 第 1 步结束（0 个工具调用） 0ms
```

## 目录

| 包 | 是什么 |
| --- | --- |
| `core/common` | 标量枚举与纯策略：Phase / 错误分类 / StopCause 文案 |
| `core/message` | 对话消息：user / assistant / toolResult / system + 内容块 |
| `core/compact` | 压缩纯策略：token 估算、切点算法、摘要消息与提示词。纯函数 |
| `core/context` | 上下文文件与技能装载：AGENTS.md 一族发现、SKILL.md 扫描、prompt 段渲染。纯函数 + fs |
| `core/trace` | 轨迹树：节点、tip 规则、统计、lazygit 风格渲染。纯函数 |
| `core/action` | `AgentAction` 全部变体与载荷（一切皆 Action） |
| `core/state` | `AgentState` 与初始状态。状态只能由 action 改 |
| `core/loop` | 两张表：`transition`（迁移）与 `wiring`（接线）；`Cmd` 数据；`reduce` |
| `core/runtime` | 环的驱动者：即时归约 + 延迟 effect（`async`） |
| `core/provider` | pi 配置解析 + OpenAI 兼容请求 / SSE + 真实 effect 表 |
| `core/sys` | 平台层：文件 / 子进程 / 标准流 / 终端，按目标分流（native ↔ js，见 [docs/platform.md](docs/platform.md)） |
| `core/tools` | 八个内置工具：定义 / 执行 / 与 pi 一致的启用状态 |
| `core/session` | JSONL 会话：增量落盘、回放成 messages / trace / 装载段 |
| `cmd/pi-moon` | 命令行 + 全屏 TUI：参数解析、会话落盘、`tui_*.mbt`（输入 / 排版 / 渲染 / 驱动） |
| `cmd/main` | 离线演示（假 provider / 假工具） |

依赖方向是一条直线：

```text
common → message → compact → trace → action → state → loop → runtime → provider → cmd/pi-moon
                                                              └──► cmd/main
```

`core/compact` 只依赖 `message`（切点算法可以脱离环单独测）；`core/context` 只依赖
fs（发现与渲染都不碰环）；`core/tools` 只依赖 `action` / `message`；`core/provider`
额外依赖它（`RunTools` effect 调 `@tools.execute`）。`core/session` 只依赖数据层
（`action` / `message` / `state` / `trace`），CLI 用它落盘与恢复。

没有循环依赖，也没有全局状态。

依赖三个外部包：

- [`moonbitlang/async`](https://github.com/moonbitlang/async) —— HTTP 客户端、文件与
  子进程、事件循环；js 目标下只有 HTTP 客户端与事件循环来自它，其余由
  `core/sys/*_js.mbt` 直接用 Node 内建模块实现；
- [`mizchi/tui`](https://github.com/mizchi/tui.mbt) —— 终端渲染与按键。这里用的是
  **本仓库的 fork**（`vendor/tui` submodule，`zt8989/true-color` 分支，加了 24-bit
  颜色），通过 `moon.work` 当 workspace 成员接进来；`moon.mod` 里那 7 个旧清单
  格式的传递依赖因此仍显式钉着（详见 [docs/tui.md](docs/tui.md)）。


## 环上每一步

| 进来的 Action | 状态迁移 | 接线发出什么 |
| --- | --- | --- |
| `UserMessage` | 追加 user 消息，开 `user` 节点，相位 → thinking | `TurnStart` |
| `TurnStart` | 开 `turn.start` 容器，`turn_index` +1 | `StepStart` + `AgentRun` |
| `StepStart` | 开 `step.start` 容器（parent = 回合容器） | 无 |
| `AgentRun` | 相位 → thinking，清流式缓冲 | `RunAgent`（effect） |
| `LlmStarted` / `LlmDelta` / `LlmThinking` | 累积流式文本 | 无 |
| `LlmDone`（有工具） | 追加 assistant 消息，开 `llm.result`，相位 → calling-tools | `RunTools`（effect） |
| `LlmDone`（无工具） | 追加 assistant 消息，**关掉 step**，相位 → idle | `TurnEnd` |
| `ToolStart` / `ToolResult` | 开 `tool.call` 节点 / 关它、并入 messages | 无 |
| `ToolBatchDone` | **关掉 step**，相位 → thinking（撞上限 → idle + stop 节点） | steer 有货：`QueueDelivered`；否则 `StepStart` + `AgentRun` |
| `LlmFailed`（可重试） | 开 error 节点，**容器保持开着**，尝试 +1，相位留在 thinking | `AgentRun`（同一容器内重试） |
| `LlmFailed`（不可重试 / 用尽） | 开 error 节点，关掉 step，相位 → idle | `TurnEnd` |
| `TurnEnd` | 关回合容器（**推进 tip**）；队列里有话（followUp 优先，其次 steer）就直接开新回合 | 容器开着就 `StepStart` + `AgentRun` |
| `CompactRequest` | 守卫（idle / 未在压）；开 pending `compact` 节点、算好切点 | `RunCompact`（没什么可压时直接 `CompactDone`） |
| `CompactDone` | 整份换 messages、闭合节点（推进 tip）、`compaction_epoch` +1 | 无 |
| `CompactFailed` | 节点标 error、挂 error 子节点，**messages 不动** | 无 |

两张表的完整语义见 [docs/loop.md](docs/loop.md)，压缩的取舍见
[docs/compact.md](docs/compact.md)。

## 与 rabbita 的关系

[rabbita](https://github.com/moonbit-community/rabbita) 是 MoonBit 的 Elm 架构
**Web UI** 框架。本项目没有在核心里直接用它，理由是两者的 `Cmd` 不是同一种东西：

- rabbita 的 `Cmd` 是**不透明**的、给 DOM 运行时用的（`Batch` / `Invoke(Op, Extension)`），
  还带着调度器与渲染宿主；
- 本项目的 `Cmd` 必须是**可检视的数据**：测试要能断言「这个 action 发的是
  `step.start + agent.run`」，而不是真的去调模型。

所以核心里有一个极小的 TEA（`AgentAction` / `AgentState` / `Cmd` /
`reduce` / `Agent`），形状与 rabbita 的 update 循环同构。终端界面已经按这个
形状接上了（`cmd/pi-moon/tui*.mbt` 读 `Agent.state`、把操作变成 action/
命令）；等做 **Web** 界面时同理：

- 界面订阅 `Agent.state`、渲染 `Html`、把用户操作 dispatch 回来；
- `RunAgent` / `RunTools` 这两条 effect 用 rabbita 的异步 Cmd
  （`@cmd.perform` / `@cmd.effect`）或一个原生 provider 适配层实现；
- 渲染层拿到的是同一份 state，不需要第二个环。

## 与原项目的对应

| 原项目（TypeScript） | 这里（MoonBit） |
| --- | --- |
| `packages/core/src/actions.ts` | `core/action/action.mbt` |
| `packages/core/src/state.ts` | `core/state/state.mbt` |
| `packages/core/src/trace.ts` | `core/trace/trace.mbt` |
| `packages/core/src/reducer.ts` 的 `transitions` | `core/loop/transition.mbt` |
| `packages/core/src/reducer.ts` 的 `loopWiring` | `core/loop/wiring.mbt` |
| `packages/core/src/compact.ts` | `core/compact/` + `core/loop/compact_ops.mbt` + provider 的 `RunCompact` |
| `packages/core/src/effects.ts`（接口那一半） | `core/runtime/runtime.mbt` 的 `EffectTable` |
| `packages/core/src/effects.ts`（pi-ai 那一半） | `core/provider/`（配置 + 请求 + SSE） |
| `packages/core/src/tools.ts`（内置工具 + 开关） | `core/tools/`（八个工具 + `resolve_tool_selection`） |
| `packages/core/src/trace-store.ts` + `trace-file.ts` | `core/session/`（JSONL 记录 / 回放） |
| `packages/core/src/session-recorder.ts` + `session-file.ts` | `core/session/` + CLI 的 `--session` / `--continue` |
| `packages/tui/src/app.ts` + `keybindings.ts` | `cmd/pi-moon/tui*.mbt`（tui.mbt 框架；见 [docs/tui.md](docs/tui.md)） |
| `redux-loop` 的 `install()` | `core/runtime/runtime.mbt` 的 `Agent::run` |

语义上刻意保留的几件事：

- **turn / step 两层容器**；重试发生 step 这一层，容器不重开；
- **error 节点不推进 tip**，所以重试的产出与失败平级；
- **装载节点推迟到用户第一句话**（`begin_trace`）；
- **接线读迁移之后的状态**（否则 `retrying` 看不到）；
- **steer 在工具批次结束后投递、followUp 在回合收口时投递**；
- 超时是**空闲超时**（多久没收到数据），不是总时长。

本版本刻意的差异：

| 差异 | 为什么 |
| --- | --- |
| 时间由 `clock` 注入，reducer 不读 `Date.now()` | 纯函数可复现：同一 action 序列 + 同一 now 得到同一棵树 |
| `max_turns : Int?`（`None` = 不限） | MoonBit 没有 `Infinity`；语义与原项目默认值一致 |
| Cmd 摊平在运行时入口做 | 原项目踩过「嵌套 LIST 静默吞 action」的坑，这里从结构上消掉 |
| effect 是 `async`，但 `Dispatch.send()` 同步归约 | 流式 token 到达时 state 立刻更新；只有 effect 边界在 `await` |
| provider 的端点设置 / SSE 解析在 `core/provider/endpoint.mbt`（本地实现） | 消息体 / 工具 / usage / tool_call 分片也在这里补（见 provider 文档） |
| 文件 / 子进程 / 终端走 `core/sys`，按目标分流 native ↔ js | 上层代码不分端；只有 `*_native.mbt` / `*_js.mbt` 两套平台实现 |
| 工具输出里 `edit` 只做严格匹配、`find` 用 rg 代替 fd | 不引模糊匹配与 fd 依赖；差异清单见 [docs/tools.md](docs/tools.md) |
| 会话**一回合 flush 一次**，不是每个 action 都写 | 写盘不参与 reducer，也不打断流式输出；粒度取舍见 [docs/session.md](docs/session.md) |
| `overflow` 只认几条常见报错文案，不像 pi 维护 40+ 家 | 漏判的代价是「该压没压」，下一轮还会失败，不破坏历史；见 [docs/compact.md](docs/compact.md) |

## 下一步（按顺序）

1. **TUI 迭代**：POSIX 粘贴丢字、图片块占位渲染（差距清单见 [docs/tui.md](docs/tui.md)）。
2. **Web 界面**：rabbita 与终端共用同一份 state；跨包只碰 `Agent` 的
   `state` / `send`。
3. **pi 扩展**：钩子的改写 / 阻断语义（`tool_call` 改参数、`tool_result` 改输出、
   `context` 换上下文）、扩展命令、宿主回收（超时 / kill）。
