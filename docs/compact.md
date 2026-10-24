# 上下文压缩（compact）

长会话撑爆窗口时，把老对话换成一段结构化摘要。压缩之后模型看到的历史是
**「一条摘要消息 + 最近这段」**，而不是从第一句话开始的全量记录。

## 为什么自己不发明切点算法

`core/compact` 只做三件事：**估 token**、**找切点**、**拼摘要消息**。规则照着
pi 的 `core/compaction/` 写，因为它们都是踩坑定下来的：

- **绝不切在 toolResult 上**。它必须跟在它的 toolCall 后面，切错了消息序列就是
  非法的，provider 直接报错。
- 切在一轮中间（切到某轮的 assistant 而不是它的 user）时，另做一段
  **turn-prefix** 摘要 —— 否则模型会丢掉「这一轮是谁问的」。
- 往回累积到超过 `keepRecentTokens` 才停，且取**离切点最近的合法切点**。

自己另发明一套，症状会是「压缩之后模型突然不知道自己在干嘛」—— 极难归因。

与 pi 唯一的差别是会话模型：pi 的切点算法吃 `SessionEntry[]`（带 uuid / parent
的树），我们的 `messages` 是扁平的 `Message[]`。所以算法退化成「在消息序列里找
切点」，**规则一字不改**。

## 摘要是一条消息，不是一个新字段

```text
messages = [
  user（内容 = summary_prefix + 摘要 + summary_suffix，compaction_summary = true）,
  ...保留的尾巴
]
```

**为什么**：对话历史只有一条真相 —— 下一轮请求就是把 `messages` 交给 provider。
若摘要另开一个 `state.summary`，就要再改请求拼装、落盘器、回放三处，各留一条
「别忘了带上摘要」的隐式约定。做成消息则都不用改：它自己会被落盘、被回放、
被恢复。

`compaction_summary` 是**结构标记**，不用「内容长得像 `<summary>`」去猜 ——
用户完全可能手打一段一模一样的文本，而把那句当成压缩点会让回放丢掉真历史。

## 三条触发路径

| 路径 | 谁判定 | 什么时候 |
| --- | --- | --- |
| `manual` | 用户 `/compact` | 不看阈值，也不看 `enabled` |
| `threshold` | `decide_compaction` | 一个回合**结束**时，占用超过 `window - reserve` |
| `overflow` | 同上，看 `state.error` | provider 报了上下文溢出（含「静默溢出」） |

判定函数是 `core/loop/compact_ops.mbt` 的 `decide_compaction`（纯函数，
`state` + `manual` 进，`should / reason / context_tokens` 出）。

**自动压缩必须在环彻底停下来时发起**：它要整份换掉 `messages`，而 LLM 还在流 /
工具还在跑时换，那条流回来就找不到自己的 `toolCallId`。

`pi-moon` 的 `agent.send()` 恰好在「队列空 + effect 队列空」时才返回，所以 CLI
在 `send` 之后判一次就够 —— 不需要原项目那个盯 `phase` 的订阅器。`enabled:
false` 关掉的只是**自动**压缩；手动 `/compact` 仍然能用。

## 三个守卫

| 在哪儿 | 挡什么 | 不挡会怎样 |
| --- | --- | --- |
| `compact.request` | `phase != idle` | 正在跑的一轮被毁 |
| `compact.request` | 已经 `compacting` | 两条摘要基于同一份历史，后写的覆盖先写的，白花钱还丢信息 |
| `compact.done` / `failed` | `compacting` | 卡在压缩中，之后所有输入都被拒 |

`state.compact_requested` 是接线用的标记：它区分「这条请求开启了压缩」与
「压缩中又收到一条请求」—— 只看 `compacting` 的话，第二条请求会让 effect
再跑一遍。

## 小窗口要夹紧参数

`should_compact` 的判据是 `tokens > window - reserve`。pi 的默认 `reserve` 是
16384，而它面向的模型窗口都在 64k 以上 —— **但我们不保证**（网关目录里有小窗口
模型）。窗口 1000 时阈值变成 `-15384`，于是任何一次调用都判定为「该压了」，
每轮压一次，白花钱还把对话越压越碎。

`effective_settings()` 按窗口夹紧：`reserve ≤ 20%`、`keepRecent ≤ 50%`。
第二条同样重要：保留的部分必须装得下，否则压完还是超，然后又是「压了还是超」
的死循环。窗口为 0（不知道）时不夹。

## 失败绝不改状态

摘要失败（网络、provider 报错、**被 token 上限截断**、摘要试图调工具）时
dispatch 一条 `compact.failed`：树上 `compact` 节点标 error、下面挂一个 error
节点，`messages` **一个字都不动**，`stop_cause` 说清是压缩失败。

半截摘要绝对不能进 `messages` —— 模型会拿着残缺的「进度」继续干，比不压糟糕
得多。

「没有可压的内容」（切点找不到 / 整段都还在保留窗口里）**不是错误**，但也不能
静默：回一条 `compact.done` 带 `summarized_count: 0`，界面据此显示「没什么可压的」。
静默才最坏 —— 用户以为压了，实际历史一个字没动。

## 轨迹与落盘

树上一个 `compact` 节点，pending → ok。它**推进 tip**（压缩之后的那条线是从摘要
开始的，不是从被压掉的那段历史延续的）—— 与 git 里 squash 一段历史之后接上新
提交是同一个形状。

摘要消息本身是一条普通 `message` 记录，但**替换整段历史**不能靠增量记录表达，
所以 `SessionWriter` 在 `state.compaction_epoch` 变化时写一条 `compact` 记录，
带上整份新 `messages`。回放遇到它就重置 messages，之后的 `message` 记录再从
新历史的尾巴往下长。压缩过的会话恢复回来仍然是压缩过的状态。

## 配置

`~/.pi/agent/settings.json` 的 `compaction` 段（pi 的官方键名，两边同一份配置）：

```json
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 20000
  }
}
```

## 用法

```bash
# REPL 里手动压一次
moon run cmd/pi-moon -- -i
> /compact

# 自动压：settings.json 里 enabled = true（默认），回合结束时按阈值判
moon run cmd/pi-moon -- -p "把这件事做完"
```

压完 / 压失败都会在 stderr 说一句：

```text
[compact] 手动：12 条 → 4 条（压缩前约 18342 tokens）
[compact] 失败：上下文压缩失败（对话原样保留）：http 400: ...
```

## 已知边界

- **`overflow` 靠错误文案判**：只收最常用的几条（`context length` /
  `maximum context` / `上下文长度`…），不像 pi 那样维护 40+ 家 provider 的
  文案表。漏判的代价是「该压没压」，下一轮还会失败，不会破坏历史。
- **摘要用同一个模型**：另配一个「便宜的摘要模型」是另一个配置面（还要配 key），
  而摘要质量直接决定压缩之后模型能不能接着干。
- **摘要不发思考参数**：要的是确定性输出，不是再思考一遍。
- **自动压缩不自动重试**：压完停在 idle，用户 `/continue`（或再说一句）继续。
- `customInstructions` / 分支摘要 / 扩展尚未接。
