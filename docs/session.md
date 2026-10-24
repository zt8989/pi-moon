# 会话：JSONL 落盘与恢复

`core/session` 把一次会话写成 **JSONL**（一行一个记录），并能在下次启动时把
**messages / 轨迹树 / prompt / model** 原样装回去。没有它，`pi-moon` 每次
`-p` 都是一次性的；有了它，才有了「上次聊到哪了」。

## 文件里有什么

默认位置：`<agent dir>/sessions/<毫秒时间戳>.jsonl`（与 pi 的配置同址，
`~/.pi/agent/sessions/`）。每行一个 `op`：

| op | 内容 | 什么时候写 |
| --- | --- | --- |
| `prompt.init` | system prompt + **装载时**那批工具（head） | 会话第一次落盘时 |
| `tools.changed` | **当前**工具集（中途换过才有） | 工具集第一次落盘时，以及此后每次变化时 |
| `model.init` | provider / model / thinking / 能力 / context window | 首次，以及模型或档位变化时 |
| `message` | 一条对话消息（user / assistant / toolResult / system） | 消息第一次出现时 |
| `compact` | 压缩后的**整份** messages（重置历史） | `state.compaction_epoch` 变化时 |
| `add` | 轨迹节点的**完整**字段（带 `seq`） | 节点第一次出现时 |
| `close` | 节点的闭合补丁（id / status / ended_at） | 之前 add 过、后来闭合时 |

轨迹用 `add` + `close` 而不是每次写整棵树：长会话里只有新节点和「刚闭合」的
节点会产生新行。回放时先逐条 `add`，再应用 `close`，最后重算 tip
（`@trace.recompute_tip`：按插入顺序最后一个闭合且会推进 tip 的节点）。

坏行直接跳过——崩溃时最后一行可能是截断的 JSON，不影响前面的记录。

## 什么时候写

CLI 在**一个回合跑完**后 flush 一次（以及启动装载后、退出前）。这是刻意的粒度：

- 写盘不是环上的 action，不参与 reducer，也不打断流式输出；
- 一回合内崩溃会丢这一回合（包括它的工具调用），但不会丢掉更早的历史；
- `SessionWriter` 是**值类型**：`flush` 返回新的 writer + 游标，调用方把
  `TracePersisted(cursor)` 送回环上。写失败保留旧游标，下一次再重试。

```text
一个回合结束
   │
   ▼
SessionWriter::flush(state)
   ├─ prompt.init（没写过才写）
   ├─ model.init（模型/档位变了才写）
   ├─ add 新节点 / close 刚闭合的节点
   ├─ compact（压缩换过历史才写：整份新 messages）
   └─ message（按条数游标追加）
   │
   ▼
(新 writer, 游标) → dispatch TracePersisted(游标)
```

## 恢复

启动时如果会话文件存在：

1. `@session.load_session` 逐行回放 → `messages` / `trace` / `prompt` / `model` /
   `persisted_seq`；
2. CLI 构造 Agent 后 dispatch **一条** `session.restored` action；
3. 迁移把 prompt / model / messages / trace / 游标一次性写进 state
   （不是逐条重放 `user.message` —— 那会在轨迹树上重复节点、tip 也会错位）；
4. `SessionWriter::restored` 把游标接上，之后的 flush 只写新增部分。

恢复出来的状态是「静止的会话」：相位 idle、流式缓冲清空、没有打开中的容器、
队列为空。下一句用户输入照常从 `trace.tip_id` 往下接。

压缩过的会话恢复回来仍然是压缩过的状态：回放遇到 `compact` 记录就把 messages
整份重置成那条摘要 + 尾巴，之后的 `message` 记录再从它后面长。模型不会「想起」
被丢掉的那部分 —— 那才是对的：摘要就是全部上下文了。

## 用法

```bash
# 新建会话（默认就会落盘）
moon run cmd/pi-moon -- -p "读 README.md 的前 3 行"

# 指定文件；存在则恢复，不存在则新建
moon run cmd/pi-moon -- -s logs/today.jsonl -p "继续"

# 恢复 sessions 目录里最新的那份
moon run cmd/pi-moon -- -c -p "刚才说到哪了？"

# 多轮 REPL（/exit 退出，/continue 续跑当前回合）
moon run cmd/pi-moon -- -i

# 不读不写
moon run cmd/pi-moon -- --no-session -p "..."
```

stderr 会打出这一次用的是哪个文件、恢复了多少：

```text
[session] 恢复 ~/.pi/agent/sessions/1712345678901.jsonl（4 条消息 / 15 个节点）
[workbuddy/cn:deepseek-v4.1-flash (thinking=high)]  tools=read,bash,...  session=...  按 Ctrl-C 中断
```

## 验证过的行为

- 一次会话（`-p "记住 42"`）→ 文件里有 prompt.init / model.init / 节点 / 消息；
- 第二次用同一个 `-s` 启动 → `session.restored` 装回 2 条消息 / 9 个节点，
  模型能基于历史回答 `42`；
- REPL 里继续问「42 + 1」→ 回答 `43`，文件继续追加；
- 重复 flush 不产生重复行；恢复后继续写不会重写历史；
- 坏行（截断的半行）被跳过；
- pending 节点先写 `add`、闭合后写 `close`，回放出来是闭合的。

测试在 `core/session/session_wbtest.mbt`（含路径 / `--continue` 选最新）。

## 已知边界

- **一次回合内不落盘**：flush 发生在 `agent.send` 返回之后；回合中途崩溃会丢
  这一回合。要更细的粒度，需要把 flush 挂到 effect 边界（`RunAgent` /
  `RunTools` 之后），而不是每次 token 都写。
- **`conversation.reset` 不落盘**：messages 只增不减（压缩是例外：它写一条
  `compact` 记录把历史整段换掉）；CLI 目前没有 `/clear`。
- **prompt / model 记录只保留最后一次**：回放取最后一条；没有「会话中途换过
  哪些模型」的完整时间线（轨迹节点里有 event，但 message 级历史不追）。
- **工具集以恢复出来的记录为准**：有 `tools.changed` 就用它，否则用
  `prompt.init` 里那批；即使当前 `settings.json` 改了 `defaultTools` 也不会
  覆盖会话里的选择（否则历史里的 toolCall 会对不上）。
