# 全屏 TUI

`pi-moon` 在终端上不带 `-p` 启动时进全屏界面（stdin / stdout 都得是终端；
重定向到文件或管道会退回一次性模式）。界面照着 `event-loop-agent` 的
`packages/tui` 做（那一版建在 pi-tui 上），这里用
[`mizchi/tui`](https://github.com/mizchi/tui.mbt) 重画，**只做终端，不做 Web**。

## 布局：与 ela 的三段同形

ela 的 `applyLayout()` 是「顶行 / 中间页 / 底部区」三段，这里逐块对应：

```text
┌ 顶行：页签 + 轨迹统计（1 行，兼两职） ─────────────────────────────┐
  对话 │ 轨迹 3轮2步  工具5  重试1  错误1 (Ctrl+R)
┌ 中间：当前页（唯一可伸缩的区域，无边框） ──────────────────────────┐
  对话页：用户蓝底块 / 助手正文 / 思考灰字 / 工具块（按成败换底色）
  轨迹页：core/trace 的 lazygit 轨道树（Ctrl+R 切换）
┌ 底部（自下而上） ─────────────────────────────────────────────────┐
  队列面板   0..n 行（Steering / Follow-up + 取回提示；空队列不占行）
  空隙       1 行（ela 的 dockGap）
  composer   3 行：上框线（工作状态嵌在里面）/ 输入行 / 下框线
  底栏       2 行：cwd；用量 + 模型
```

几处容易走样的细节，都是按 ela 的形状来的：

- **没有自造的对话区边框 / 标题栏**。ela 把「我在哪页、跑到哪一步」压在顶
  行，把模型放到**底栏第二行右侧**，对话高度留给内容；
- **composer 只有上下两条横线**（pi 的 `Editor` 注释原话是 “no side borders,
  just horizontal lines above and below”），没有左右竖线、没有 `>` 前缀；
- **工作状态嵌在上框线里**：`── ⠋ 思考中… ─────────`，文案与 ela 的
  `workingStatusText()` 一致（重试 / 压缩中 / 思考中），不额外占一行；
- **底栏固定两行**：第一行 cwd（家目录缩成 `~`），第二行
  `↑1.3k ↓49 0.1%/1.0M (auto)` + `(provider) model • thinking` 左右对齐；
- **`(auto)`** 只在自动压缩开着、且知道窗口大小时出现（与 ela 同一个判定）；
- **队列面板在 composer 上方**：空队列一行不占，非空时每行缩进一格。

底色用 16 色名字（`blue` / `green` / `red` / `magenta`），不用 `rgb()`：tui.mbt
的渲染器把 rgb 量化到 256 色立方（6×6×6），pi 那些很暗的底色
（`rgb(41,49,73)` 与 `rgb(37,65,49)`）会双双落成同一个 `#005f5f`，用户块与
工具块就分不出来了。

**命令反馈卡**（ela 的 `statusCards`）不在底栏，而是钉在**对话流里**：锚点是
创建时的 messages 条数，新消息把它往上顶；同一位置连续提示就地替换（不刷屏），
换会话（`/resume`）时整批清掉，最多留 50 张。

## 三个任务，一条规则

```text
key loop     read_key → 改输入缓冲 / 命令队列 → 标脏
render loop  标脏时把 agent.state 画成一帧（vnode diff，只写变化的格子）
driver       await agent.send(...)：模型流、工具、压缩都在这条 await 里
```

规则：**只有 driver 碰 agent**。

原因不抽象：`Agent::send()` 会一直 await 到整个回合结束（流式调用、工具
批次、重试都在这条链上）。按键如果直接调它，生成期间连 Esc 都按不进来 ——
而 Esc 恰恰是生成期间最需要按的键。

所以键循环只做两件事：改自己的状态、往队列里放一条命令。命令是
`Submit` / `Continue` / `Compact` / `Tools` / `ListTools` / `Dequeue` /
`Exit`，driver 按顺序消费。

生成中敲的话走另一条更短的路：`TuiState.pending_actions` 里放一条
`QueueInput`，由 provider effect 的 `ProviderHooks::on_tick` 在**流分片边界 /
每条工具之前** dispatch 进环里。那条路与 driver 同上下文，不会在别人 await
时把 deferred 队列里的 effect 拉起来并发跑。

## 队列与取回（键位照 ela）

- 空闲时 Enter：`UserMessage`，开新回合；
- **生成中 Enter：steer** —— 当前 step 的工具批次结束后投递，模型下一步就能看到；
  若模型直接说完（没有工具批次），`TurnEnd` 会投递它并开新回合；
- **生成中 Alt+Enter：followUp** —— 回合收口后再投递；
- 队列面板分别显示 `Steering:` / `Follow-up:` 行；
- **Ctrl+U：把排队消息取回输入框**（生成中也能用）；
- 空闲时 Esc：同样取回；没有队列就是清空输入；
- 生成中 Esc：中断当前回合。

取回在生成中能用，靠的是 `ProviderHooks::on_tick` 里那个安全点：effect 在分片
边界把请求读走 —— 读 `bridge.agent.state` 里的两条队列、填进输入框，再
`dispatch(QueueClear)`。driver 此刻正卡在 effect 里，按键任务碰不到 agent，
所以这个引用由 `TuiBridge` 后填进去。

与 ela 的唯一键位差异：取回是 `Ctrl+U`，不是 `Option+Up`。Windows 控制台的
`_getch` 拿不到 Alt+方向键（`translate_special_key` 只留下方向键本身），语义
一致、键不同。队列面板上的提示写的就是能按的那个键。

## 中断：Esc 走一条更短的路

命令队列要等 driver 空闲，中断不能等。`Esc` 只把 `tui.abort` 立起来，
provider effect 在下一个分片边界查 `ProviderHooks::should_abort`：

- **LLM 流**：查到就**收工**。已经收到的正文（text / thinking）按 ela / pi 的做法
  作为一条 `stop_reason=aborted` 的 assistant 消息保留下来，界面上补一行
  `[已中断]`；**半截 toolCall 必须剥掉** —— 流被掐断时参数 JSON 只写了一半，
  而一条带 toolCall 的消息后面没有对应的 toolResult，下一轮请求就是非法的。
  一个字都没收到时才走 `llm.failed(kind=aborted)`；
- **工具批次**：正在跑的那一条不打断（进程已经起来了，硬停会留下半截文件），
  从下一条起补 `tool.result(is_error=true, "用户中断，未执行")`，再收工 ——
  每个 `toolCall` 都必须有结果，否则下一轮请求是非法消息序列；
- 重试次数不增加：`Aborted` 在 `is_retryable` 里是 false。

中断的粒度是「下一个分片 / 下一条工具」，不是即时杀连接：HTTP 流上的
`read_until` 被取消会丢掉半行 SSE，那比晚几百毫秒更糟。provider 长时间不发
事件时，Esc 最迟在空闲超时（默认 120s）后才生效 —— 这是 v0.7 的已知边界。

## 面板：模型 / 思考级别 / 会话

`Ctrl+L`（或 `/model`）开模型面板；`/thinking` 开思考级别面板，
`/thinking <级别>` 直接切；`/resume` 开会话面板。面板**覆盖 composer 那一块**
（与 ela 的 selector 同形：整行宽、顶边框带标题、底边落在 composer 底边），
中间页相应变短：

```text
── 恢复会话 ─────────────────────────────────────
  ↑/↓ 选择 · Enter 确认 · Esc 取消
 › 刚刚  1792808634625 · 10 KB  ●
   2 小时前  1792808625918 · 10 KB
────────────────────────────────────────────────
```

- 模型列表来自 `models.json` 的 provider × model；`●` 是当前模型；
  Enter 走 `ModelChanged`，并把思考级别按新模型夹紧（不支持思考的模型回到
  `off`，显式禁用的档位也回到 `off`）；
- `/thinking` 只列当前模型**支持**的档位（`thinking_level_map` 里显式 `null`
  的不出现）；Enter 走 `ThinkingChanged`；
- `/resume` 列 `<agent dir>/sessions/*.jsonl`，按修改时间倒序，`●` 是当前文件；
  Enter 走 `SessionRestored`（messages / 轨迹 / 装载段 / 模型整体换掉），并把
  落盘器换成 `SessionWriter::restored` —— 接着那个文件写，不能把当前会话的
  历史追加到旧文件里；
- 面板只在空闲时能开（生成中按 `Ctrl+L` 会提示先中断）；Esc 关闭。
- 选完会 flush 一次会话（`model.init` / 后续请求的模型就是新的）。

## 键位

| 键 | 行为 |
| --- | --- |
| `Enter` | 空闲：提交；生成中：进 steer 队列；面板中：确认当前项 |
| `Alt+Enter` | 生成中：进 followUp 队列 |
| `Esc` | 生成中：中断；空闲：取回排队消息；面板中：关闭 |
| `Ctrl+U` | 取回排队消息（生成中也能用） |
| `Ctrl+L` | 模型面板 |
| `Ctrl+C` | 有输入先清空；空输入连按两次退出；生成中先中断；面板中：关闭 |
| `Ctrl+D` | 退出（先立中断标志，等环收工） |
| `Ctrl+R` | 对话页 / 轨迹页切换 |
| `Ctrl+O` | 展开 / 折叠工具输出与压缩摘要 |
| `↑` / `↓` | 历史输入；面板中：移动选中 |
| `←` / `→` / `Home` / `End` | 光标移动（按字符，不按字节） |
| `PgUp` / `PgDn` | 翻当前页；面板中：跳 5 项 |
| `Ctrl+Home` / `Ctrl+End` | 到顶 / 回到底部跟随 |
| `/model` | 模型面板（同 `Ctrl+L`） |
| `/thinking` | 思考级别面板 |
| `/thinking <级别>` | 直接切到那一档（大小写不敏感） |
| `/resume` | 会话面板（恢复历史 JSONL） |
| `/compact` | 手动压缩上下文 |
| `/continue` | 修复尾消息后继续未完成的回合 |
| `/tools` | 显示当前工具集 |
| `/tools read,bash` | 换工具集（下一次请求生效） |
| `/exit` `/quit` | 退出 |

Esc 与 Ctrl+C 的分工照 pi：Esc 是 `app.interrupt`，Ctrl+C 是 `app.clear`。
ela 里那个「一个键干两件事」的 `app.abort` 默认不绑，这里也不绑。

## 与 ela 的差距（分步补齐）

1. **markdown 高亮与逐字排版**：现在 assistant 文本是纯文本折行；工具块也
   没有 pi 的各工具专用渲染器（bash 的尾部保留、edit 的彩色 diff）。
2. **Windows 输入法**：`_getch` 拿到的是控制台代码页字节，不是 UTF-8；
   英文与多数符号没问题，中文长句输入建议在别处打好再粘贴（粘贴走的是
   同一批字节，表现一致）。

## Windows 终端

开屏时 `tty.c` 做两件事：输出代码页切到 UTF-8（65001），并打开
`ENABLE_VIRTUAL_TERMINAL_PROCESSING`；退出时原样还原。不做这两步的症状很
一致：中文变乱码、边框变乱码字面量（已在 Windows Terminal / conhost 的
PTY 里验证过）。输入侧仍是 `_getch` 的代码页字节，见上面第 4 条。

## 依赖与版本钉法

`moon.mod` 里除了 `mizchi/tui@0.10.2`，还显式列了 7 个传递依赖
（`crater-core` / `crater-layout` / `css` / `layout` / `signals` / `syntree` /
`tui-terminal-buffer`）。不是装饰：tui 0.10.2 的清单钉的是旧版本，其中
`crater-layout@0.18.0`、`css@0.2.0`、`tui-terminal-buffer@0.1.3` 还是
`moon.mod.json` 格式，当前 moon 直接拒绝安装。显式列成最新的 `moon.mod`
版本，解析器就会用能装的那一份。

升级 tui 时先看这 7 个是否还需要（上游改成新清单后就能删掉）。

## 手动验证

```bash
moon run cmd/pi-moon            # 全屏 TUI（stdin / stdout 都是终端时）
moon run cmd/pi-moon -p "..."   # 一次性，不启 TUI
echo "..." | moon run cmd/pi-moon   # 管道输入仍是一次性
moon run cmd/pi-moon > out.txt  # 输出被重定向：不启 TUI，避免把转义序列写进文件
```

`moon test` 覆盖的是纯逻辑：折行（含 CJK）、光标编辑、可见窗口、键位语义、
队列面板、页签/底栏、整帧渲染（`render_vnode_once`）。raw mode、流式重绘、
Windows 控制台这类东西必须在真终端里看。
