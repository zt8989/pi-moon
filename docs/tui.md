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

## 颜色：来自主题，不写死

所有颜色都从 **pi 的主题**算出来（`cmd/pi-moon/tui_theme.mbt`），渲染代码里
没有 RGB 常量：

```text
settings.json 的 theme
  ├─ "light/dark"（自动形式）→ 按终端深浅挑一边
  ├─ "system"               → pi 会按终端上报的颜色现算；这里退化成 dark/light
  └─ 名字                    → <agent dir>/themes/<name>.json（pi 的自定义主题目录）
找不到文件 → 内嵌的 dark / light（`tui_theme_data.mbt`，原样照搬 pi 的 JSON）
```

解析规则与 pi 一致：`vars` 互相引用先展开，颜色支持 `#rgb` / `#rrggbb` /
`okhsl(h s% l%)` / `oklch(l c h)` / ANSI 索引数字 / `""`（终端默认色）。
OKHSL / OKLCH → sRGB 是 Björn Ottosson 参考实现的移植（MIT），系数与 pi 的
`oklab.js` 逐项一致 —— **同一个主题，两边必须算出一模一样的 RGB**，
`tui_theme_wbtest.mbt` 里那组断言就是拿 pi 的实际输出钉的。

于是换 `settings.json` 的 `theme` 就等于换整套界面配色：用户块、工具块、
压缩摘要、思考灰字、markdown 的标题 / 链接 / 行内 code / diff 增删、
composer 框线的思考级别色（`thinkingOff`..`thinkingMax`）全部跟着走。

**唯一的例外是面板底色**（`userMessageBg` / `toolSuccessBg` / …），它跟终端
能力走：

- **24-bit 终端**：用主题原值（dark 下用户块 `rgb(33,59,73)`、工具成功
  `rgb(37,65,49)`、失败 `rgb(91,40,42)`、进行中 `rgb(52,56,58)`）；
- **只有 256 色**：退回 16 色名字（`blue` / `green` / `red` / `magenta`）。
  默认渲染把 rgb 量化到 256 色立方（6×6×6），pi 那几块很暗的底色会双双落成
  同一个 `#005f5f`，用户块与工具块就分不出来了。前景色没这个问题（它们不挨着
  铺），一律用主题值。

“是不是 24-bit”先问 tui 的 `ColorMode::detect()`（`COLORTERM` / `TERM`），
再补它看不到的那几个：Windows Terminal 只给 `WT_SESSION`，VS Code 只给
`TERM_PROGRAM`，老终端用 `ConEmuANSI=ON` / `ANSICON`。都不广告就回 256 色 ——
猜成 TrueColor 而终端不支持，那几块底色会整段变成默认色。

终端是深底还是浅底：pi 优先问终端自己（OSC 11），这里退一步看 `COLORFGBG`
（vim / tmux 都在用），判不出来按 dark。

**命令反馈卡**（ela 的 `statusCards`）不在底栏，而是钉在**对话流里**：锚点是
创建时的 messages 条数，新消息把它往上顶；同一位置连续提示就地替换（不刷屏），
换会话（`/resume`）时整批清掉，最多留 50 张。

## markdown

assistant 正文与用户块都过 markdown，但**解析和渲染分两层**：

- **解析**交给 `NoahLiu/mdparse`（`mizchi/markdown` 的解析链路 fork，只留
  CommonMark CST）。它给的是 AST，不是 HTML 字符串，所以实体的解码、
  强调标记的配对、链接定义这些细节由解析器负责；
- **渲染**在 `tui_markdown.mbt`：AST → `StyledLine`。终端能给的样式只有
  前景色 + 粗体，这一层只做这个映射。

块级：

| 块 | 画法 |
| --- | --- |
| 标题 | 去井号、整行加粗；h3 以下再用暗色，层级才分得出来 |
| 围栏 / 缩进代码 / 数学块 | 保留 ```` ```lang ```` 行（`mdCodeBlockBorder`）、内容用 `mdCodeBlock`、行结构原样 |
| ```` ```diff ```` | 按行上色：`+` / `-` 用主题的 `toolDiffAdded` / `toolDiffRemoved`，`@@` 用 `mdLink`，`diff` / `+++` / `---` 加粗暗色 |
| 无序 / 有序列表 | `•` / `1.`，嵌套按外层标记宽度缩进 |
| 任务列表 | `☑` / `☐` |
| 引用 / GitHub alert | `│ ` 灰前缀（alert 带 `NOTE` / `WARNING` 标签） |
| 表格 | 列宽按内容算，超宽从最宽的列收；分隔线 `──┼──`，按 `:---:` 对齐 |
| 分隔线 | 整行 `─` |
| 术语列表 / 脚注定义 | 术语加粗，定义缩进两格 |

行内：`` `code` ``（主题 `mdCode`）、`**粗体**`、`[text](url)`（主题 `mdLink` + 灰 url）、
引用式链接（从文档定义里解出 url）、autolink、实体（`&amp;` → `&`）、
硬换行（行尾两空格 / `\`）真的断行。

**折行按单元格宽度做**：样式先铺到字符上再折，`**粗体**` 被折到两行时
两段都还是粗体——先拼字符串再折会把样式丢掉。

不做的：斜体（vnode 的 text 没有开关，`*强调*` 只保留文字，不假装斜体）、
表格单元格里的行内样式（单元格要先算列宽再补空格，保留 span 会和宽度
算法打架，所以只留纯文字）、图片（按 `![alt](url)` 原文显示）。

## 三个任务，两条碰 agent 的路

```text
key loop     read_key → 改输入缓冲 / 命令队列 → 标脏；
             界面显示类按键（翻页 / 滚动 / 面板）经 ui_dispatch 发 Ui 事件，
             Agent::dispatch_ui 同步归约 —— 无 await，生成中也能用
render loop  标脏时把 agent.state 画成一帧（vnode diff，只写变化的格子）
driver       await agent.send(...)：模型流、工具、压缩都在这条 await 里
```

碰 agent 的路有两条，各走各的事件：

- **对话类动作**（发消息、换模型、压缩）只有 driver 碰：`Agent::send()` 会
  await 到整个回合结束，按键如果直接调它，生成期间连 Esc 都按不进来 ——
  而 Esc 恰恰是生成期间最需要按的键。所以键循环只改自己的状态、往队列里
  放一条命令，driver 按顺序消费。命令是 `Submit` / `Continue` / `Compact` /
  `Tools` / `ListTools` / `Dequeue` / `Exit`。
- **UI 事件**（`Ui(PageToggled)` / `Ui(Scrolled(...))` / `Ui(PickerMoved(...))`）
  走 `Agent::dispatch_ui`：同步归约、不排队、不碰 deferred，整个调用没有
  await，协作式调度下不会与 driver 正在 await 的 effect 交错。所以翻页、
  滚动、开关面板在生成中也能立即生效。这些事件只改 `state.ui`，不进轨迹、
  不落盘（见 [loop](loop.md) 的 UI 事件一节）。

生成中敲的话走另一条更短的路：`TuiState.pending_actions` 里放一条
`QueueInput`，由 provider effect 的 `ProviderHooks::on_tick` 在**流分片边界 /
每条工具之前** dispatch 进环里。那条路与 driver 同上下文，不会在别人 await
时把 deferred 队列里的 effect 拉起来并发跑。

### render(state)

渲染是 state 的纯函数：`tui_view(tui, agent.state)`。哪一页、滚到哪、
工具块展开没展开、面板开着没有、选中是哪行 —— 全部从 `state.ui` 重算；
TUI 自己只贡献环表达不了的本地细节：终端尺寸、输入缓冲与历史、反馈卡、
落盘游标。于是键循环不再直接改界面显示，它只发 UI 事件，改的是同一个
reducer 里的 state。

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
`read_until` 被取消会丢掉半行 SSE，那比晚几百毫秒更糟。provider 长时间
不发事件时，Esc 也不用等空闲超时 —— 读行与中断轮询并跑（`read_sse_line_or_abort`，
每 100ms 查一次 `should_abort`），谁先完成谁赢，Esc 最迟 ~100ms 生效。

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
| 滚轮 | 翻当前页（±3 行，SGR 鼠标，`init_vnode_terminal(mouse=true)`） |
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

## 工具块：每个工具各画各的

工具块的形状照 pi 的 `ToolExecutionComponent`：一个空行、标题行加粗（
`toolTitle`）、正文缩进两格、底色按 pending / success / error 切换，
`Ctrl+O` 在折叠（标题 + 少量正文）与展开（至多 40 行）之间切换。
折叠时保留几行**每个工具不一样**，与 pi 的 `core/tools/renderers` 同一套：

| 工具 | 标题 | 折叠保留 | 展开 |
| --- | --- | --- | --- |
| `bash` / `powershell` | `$ cmd` / `PS> cmd`（带 `timeout` 时附 `(timeout Ns)`） | **尾部 5 行**（命令输出越靠后越重要），完成附一行 `耗时 1.2s`（pi 的 `formatDuration` 口径） | 尾部 40 行 |
| `edit` | `edit 路径` | 彩色 diff：删 `-` 红、加 `+` 绿（`toolDiffRemoved` / `toolDiffAdded`），上下文灰，首尾相同的行折成上下文（各至多 3 行）；多段 edits 用 `@@ edits[N]` 分隔 | 前 40 行 |
| `write` | `write 路径` | 内容预览 10 行 + `… 还有 N 行（共 M 行，Ctrl+O 展开）` | 前 40 行 |
| `read` | `read 路径[:起-止]`（带 `offset` / `limit` 时） | 只留标题（pi 同款：标题已说明读了什么） | 前 40 行 |
| `grep` | `grep /模式/ in 路径 (glob) limit N` | 15 行 | 40 行 |
| `find` / `ls` | `find 模式 in 路径` / `ls 路径` | 20 行 | 40 行 |
| 其它 | `名字 参数` | 6 行（扩展工具的兕底）| 40 行 |

实现细节与 pi 的差别（都有意为之）：

- `edit` 的 diff 从**参数**算（`oldText` → `newText`），因为工具结果里没有
  结构化 diff；没有文件行号，所以行首只有 `+` / `-` 标记。
- 成功的 `edit` / `write` 不再复读结果文本（`Successfully replaced ...`），
  块里就是 diff / 内容；失败时显示错误文本（`error` 色，折叠也保留 10 行）。
- `bash` 保留尾部：与工具本身的截断口径一致（模型看到的也是尾部）；
  提示写「前面还有 N 行」。耗时来自 `state.tool_timings`。
- 绝对路径相对化到 cwd、统一 `/` 分隔（pi 的 `renderToolPath` 同效果）。
- 标题、正文、提示的排版在 `tui_view.mbt`（`push_bg_block_lines`），
  「标题 + 行 + 提示」的算法在 `tui_tool.mbt`（纯函数，测试在
  `tui_tool_wbtest.mbt`）。

参数 JSON 解析失败不致命：标题退回 `名字 一行参数`，正文退回结果文本 ——
半个 JSON 的流式中途块也能画。

## 与 ela 的差距（分步补齐）

1. **POSIX 粘贴丢字**：vendor 的 `read_key` 把 ESC 后 16 字节内的可打印
   字节都当 CSI 参数吞掉（终止判定 `0x40-0x7e`），粘贴文本撞上转义序列
   时大段正文会被吞成一个 Unknown 事件；且 `parse_input` 对多字符可打印
   输入只取第一个字符。修复应在 vendor 层（照 `io_native.mbt` inline
   input 的「multi-character printable → 整串 Insert」补偿）。
2. **图片只画占位**：`read` 图片块在对话页显示 `[image <mime>]` 一行，
   不渲染内容（终端画不了图）；点击 / 悬停等其余鼠标事件未接。

~~Windows 输入法乱码~~ 已修：vendor 的 Windows 输入从 `_getch`（代码页
字节）换成了 `ReadConsoleInputW`（UTF-16 → UTF-8），中文输入不再依赖
代码页（vendor `6623b19`）。

## Windows 终端

开屏时 `tty.c` 做两件事：输出代码页切到 UTF-8（65001），并打开
`ENABLE_VIRTUAL_TERMINAL_PROCESSING`；退出时原样还原。不做这两步的症状很
一致：中文变乱码、边框变乱码字面量（已在 Windows Terminal / conhost 的
PTY 里验证过）。输入侧仍是 `_getch` 的代码页字节，见上面第 4 条。

## 依赖与版本钉法

**TUI 本身是一条本地 fork**：`vendor/tui` 是 git submodule
（`https://github.com/zt8989/tui.mbt.git`，分支 `zt8989/true-color`，在 0.10.2
之上加了 24-bit 颜色），`moon.work` 把它列为 workspace 成员，于是
`mizchi/tui` 这个名字解析到本地那一份，而不是 registry 的 0.10.2。

```bash
git clone --recurse-submodules <repo>   # 不带 submodule 就编不过（缺 ColorMode）
moon work sync                          # 升级 fork 后同步成员间的依赖版本
moon fmt cmd/pi-moon                    # 注意：仓库根下的 `moon fmt` 会连 vendor/tui 一起格式化
```

`moon.mod` 里仍然写着 `mizchi/tui@0.10.2` 和 7 个传递依赖
（`crater-core` / `crater-layout` / `css` / `layout` / `signals` / `syntree` /
`tui-terminal-buffer`）。后 7 个不是装饰：tui 0.10.2 的清单钉的是旧版本，其中
`crater-layout@0.18.0`、`css@0.2.0`、`tui-terminal-buffer@0.1.3` 还是
`moon.mod.json` 格式，当前 moon 直接拒绝安装。显式列成最新的 `moon.mod`
版本，解析器就会用能装的那一份。

升级 tui 时先看这 7 个是否还需要（上游改成新清单后就能删掉）。

主题数据在 `cmd/pi-moon/tui_theme_data.mbt`：pi 的 `dark.json` / `light.json`
原样内嵌（`#|` 多行字符串），升级 pi 后重新生成，别手改 —— 那两份只是「没装
pi 也能跑」的兜底，磁盘上有主题文件时以磁盘为准。

markdown 侧的依赖只有一个：`NoahLiu/mdparse@0.1.0`（CommonMark CST，
零传递依赖，原生可编译）。不直接用上游 `mizchi/markdown`：它把编译器、
字体、图片渲染一起拖进来，还会顶到 `moonbitlang/async@0.22`，而 tui
钉的是 0.21。

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
