# 全屏 TUI

`pi-moon` 在终端上不带 `-p` 启动时进全屏界面（stdin / stdout 都得是终端；
重定向到文件或管道会退回一次性模式）。`-p` / 管道输入仍然是一次性模式。
界面参照 `event-loop-agent` 的 `packages/tui`（那一版建在 pi-tui 上），
这里用 [`mizchi/tui`](https://github.com/mizchi/tui.mbt) 重画，**只做终端，
不做 Web**。

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
`Submit` / `Continue` / `Compact` / `Tools` / `ListTools` / `Exit`，driver
按顺序消费；上一回合没跑完时按 Enter，消息就排在队列里，回合结束后发。

## 中断：Esc 走一条更短的路

命令队列要等 driver 空闲，中断不能等。`Esc` 只把 `tui.abort` 立起来，
provider effect 在下一个分片边界查 `ProviderHooks::should_abort`：

- **LLM 流**：查到就 dispatch `llm.failed(kind=aborted, cause=user)`，
  已收到的字留在 `streaming_text` 里给界面看，**半截消息不进 `messages`**；
- **工具批次**：正在跑的那一条不打断（进程已经起来了，硬停会留下半截文件），
  从下一条起补 `tool.result(is_error=true, "用户中断，未执行")`，再收工 ——
  每个 `toolCall` 都必须有结果，否则下一轮请求是非法消息序列；
- 重试次数不增加：`Aborted` 在 `is_retryable` 里是 false。

中断的粒度是「下一个分片 / 下一条工具」，不是即时杀连接：HTTP 流上的
`read_until` 被取消会丢掉半行 SSE，那比晚几百毫秒更糟。provider 长时间不发
事件时，Esc 最迟在空闲超时（默认 120s）后才生效 —— 这是 v0.7 的已知边界。

## 布局

四块，全部在一个 `column` 里：

```text
顶栏    provider/model · 相位 · token
对话区  border=rounded，自折行的一行一条 text
输入区  border，光标块 ▌
底栏    提示 / 通知 / 排队数
```

对话区**自己折行**，不交给布局引擎：`core` 的 `char_display_width` 让 CJK
按两格算，折错只会表现为「右边越界」；先折成行数组，滚动就只是数组切片，
换终端宽度也只是重算一次。

滚动是「离底部多少行」：`0` 表示跟随最新。PgUp/PgDn 翻半屏，Ctrl+Home/End
到顶/底；用户往上翻之后，新 token 不会把视口拽回底部（只有提交新消息时
`scroll` 归零）。

## 键位

| 键 | 行为 |
| --- | --- |
| `Enter` | 提交；生成中则排队到本回合结束 |
| `Esc` | 生成中：中断；空闲：清空输入 |
| `Ctrl+C` | 有输入先清空；空输入连按两次退出；生成中先中断 |
| `Ctrl+D` | 退出（先立中断标志，等环收工） |
| `↑` / `↓` | 历史输入 |
| `←` / `→` / `Home` / `End` | 光标移动（按字符，不按字节） |
| `PgUp` / `PgDn` | 翻页 |
| `Ctrl+Home` / `Ctrl+End` | 到顶 / 回到底部跟随 |
| `Ctrl+O` | 展开 / 折叠工具输出 |
| `/compact` | 手动压缩上下文 |
| `/continue` | 修复尾消息后继续未完成的回合 |
| `/tools` | 显示当前工具集 |
| `/tools read,bash` | 换工具集（下一次请求生效） |
| `/exit` `/quit` | 退出 |

Esc 与 Ctrl+C 的分工照 pi：Esc 是 `app.interrupt`，Ctrl+C 是 `app.clear`。
ela 里那个「一个键干两件事」的 `app.abort` 默认不绑，这里也不绑。

## 与 ela 的差距（分步补齐）

v0.7 是第一步：**能连续对话、能中断、能看工具输出、能压缩、能恢复会话**。
还没做的：

1. **steer 的投递时机**：现在生成中按 Enter 是「回合结束后发送」（followUp
   语义）；ela/pi 的 steer 是在**工具批次结束**时投递，模型下一步就能看到。
   要做对需要在 effect 里给界面一个安全的 dispatch 点。
2. **中断时半截文本的去处**：现在只留在界面上（`streaming_text`），**不进
   messages**；ela 会作为 `stop_reason=aborted` 的 assistant 消息保留。
   两步都能接受，但历史不同，以后要统一。
3. **轨迹页**（`Ctrl+R`）与 `Ctrl+O` 的逐节点展开：`core/trace` 的
   `trace_rows` 已经能给出结构化行，缺的是面板与焦点。
4. **模型 / 思考档位 / 会话选择器**（`Ctrl+L` 等）。
5. **markdown 高亮与逐字排版**：现在 assistant 文本是纯文本折行。
6. **Windows 输入法**：`_getch` 拿到的是控制台代码页字节，不是 UTF-8；
   英文与多数符号没问题，中文长句输入建议在别处打好再粘贴（粘贴走的是
   同一批字节，表现一致）。

## Windows 终端

开屏时 `tty.c` 做两件事：输出代码页切到 UTF-8（65001），并打开
`ENABLE_VIRTUAL_TERMINAL_PROCESSING`；退出时原样还原。不做这两步的症状很
一致：中文变乱码、边框变乱码字面量（已在 Windows Terminal / conhost 的
PTY 里验证过）。输入侧仍是 `_getch` 的代码页字节，见上面第 6 条。

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
整帧渲染（`render_vnode_once`）。raw mode、流式重绘、Windows 控制台这类
东西必须在真终端里看。
