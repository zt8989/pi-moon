# 环：设计现状（v0.2）

这份文档记录 **pi-moon 的循环核心今天是什么样**，对应原项目
`docs/architecture/loop.md`。代码为准，本文解释「为什么是这样」。

三个文件构成骨架：

| 表 | 在哪 | 是什么 |
| --- | --- | --- |
| 迁移表 | `core/loop/transition.mbt` 的 `transition` | action → 下一个状态（纯函数） |
| 接线表 | `core/loop/wiring.mbt` 的 `wiring` | action → `Array[Cmd]`（纯数据） |
| effect 表 | `core/runtime/runtime.mbt` 的 `EffectTable` | `RunAgent` / `RunTools` 的真正实现（注入） |

`reduce(state, action, now)` = 迁移 + 接线：

```moonbit
pub fn reduce(state, action, now) -> (AgentState, Array[Cmd]) {
  let next = transition(state, action, now)
  let cmds = wiring(action, next)   // ← 读的是 next，不是 state
  (next, cmds)
}
```

## Cmd 是数据

```moonbit
pub(all) enum Cmd {
  Noop
  Batch(Array[Cmd])
  Redispatch(AgentAction)          // 送回 reducer（环上的一步）
  RunAgent(String?)                // 交给 effect 表
  RunTools(Array[ToolCall])        // 交给 effect 表
}
```

三条性质：

1. **可断言**。测试直接检查 `flatten_cmds(cmds)`，不需要真的打网络。
2. **可嵌套但不丢**。`flatten_cmds` 在入口一次性摊平；原项目踩过
   redux-loop 对嵌套 `Cmd.list` 静默吞 action 的坑，这里从结构上消掉。
3. **纯数据能序列化**。将来回放 / 跨进程传环时不需要搬运闭包。

## 运行时：传送带，不是 agent 循环

`Agent` 里有两条队列：

```text
外部 action 队列              延迟 effect 队列
      │                              │
      ▼                              ▼
  pump(action) ──► reduce ──► Redispatch：当场再 pump
                            └► RunAgent / RunTools：进 deferred
      │
      ▼
  run(): 外部队列非空 → pump；
         deferred 非空 → await 一个 effect，再回到上面
```

两个设计点：

- **即时归约（同步）**：effect 通过 `Dispatch.send()` 发回来的 action **当场**
  reduce 掉，而不是排到队尾。于是流式 token 到达时 `state.streaming_text`
  就是当下的值，界面不必等整个请求结束才看到字。
- **延迟 effect（异步）**：归约途中产生的 `RunAgent` / `RunTools` 进 deferred
  队列，等当前 effect 返回后按顺序 `await`。所以 effect 与 effect 之间没有嵌套，
  环也没有递归的 agent 调用。

`Dispatch` 因此是同步的（可以安全地在流式回调里连着发很多条），只有
`flush_deferred` 里那一次 `await` 在等网络。

effect 表是异步的：

```moonbit
run_agent: async fn(state, dispatch) {
  dispatch.send(LlmStarted)
  dispatch.send(LlmDelta("..."))       // 当场归约，state 立刻更新
  dispatch.send(LlmDone({ message: part, node_id: None }))
}
```

**顺序**由 deferred 队列保证：`Batch([Redispatch(StepStart), Redispatch(AgentRun)])`
先处理完 `step.start`，再执行 `agent.run` 的 effect。于是 effect 读到的 state
一定已经带上了新开的 step 容器。

`budget` 是防死循环的保险丝：effect 若把同一条 action 又发回来，运行时会以
`AgentError::BudgetExhausted` 停下，而不是静默卡住。

渲染层通过 `Agent::observe()` 订阅每一条被归约的 action；真实 provider 还可以
通过 `ProviderHooks` 在 await 期间把增量直接写给终端 —— 前者拿 state，后者拿
字节流，两者都不改 state。

## 两层容器

```text
user → turn.start → step.start → llm.result → tool.call → tool.result
                                 → step.end
       → turn.end
```

- **turn** = 一次用户输入引发的整个回合（中间可以有好几个 step）；
- **step** = 一次 LLM 调用 **加上它触发的工具批次**。

容器（`turn.start` / `step.start`）**不推进 tip**。`turn.end` 推进，
`step.end` 不推进（tip 由里面的 `llm.result` / `tool.result` / `error` 推进）。

这带来一个直接后果：**重试的产出与失败平级，全在同一个 step 容器里**。

## 重试

`LlmFailed` 的迁移先分类：

```text
can_retry = 有开着的 step
          && kind ∈ {timeout, network}
          && llm_attempts < max_llm_attempts
```

- **可以重试**：挂 `error` 孩子，容器**不闭合**、不重开；尝试计数 +1；
  相位留在 `thinking`；接线发 `AgentRun`。
- **不可以**：挂 `error` 孩子，关 step（`step.end`），相位 → idle；
  接线发 `TurnEnd`。

`llm_attempts` 在 `step.start` 时置 1，在 `tool.batch.done` 时归零
（下一步又从第 1 次尝试开始）。

超时是 **effect 侧**的事，而且是**空闲超时**：流上 `llm_timeout_ms` 没有事件
才掐。总时长闸会把「生成时间恰好超过阈值」的请求变成死循环 —— 这是原项目踩过
的坑，这里只保留空闲语义（字段已经进 state，真实 provider 与假 effect 都按这条语义实现）。

## 队列：生成中也能说话

两条队列各自 FIFO、互不排队：

| 队列 | 投递点 | 语义 |
| --- | --- | --- |
| steer | `tool.batch.done` 之后、下一次 LLM 调用之前 | 打断「模型→工具→模型」的延续，属于**当前回合** |
| followUp | `turn.end` 的迁移里 | 等模型没有工具调用了才插，然后**开新回合** |

两条都用 `QueueDelivered` 投递，区别只有落点：

- steer 的 user 节点挂在**当前回合容器**下面；
- followUp 先关旧回合，再把 user 节点挂在 tip 下，然后开新 `turn.start`。

`QueueInput` 在**空闲**时直接转成 `UserMessage`（复用同一段迁移）：
空闲时既不会有 `tool.batch.done` 也不会有 `llm.done` 来触发投递，
入队等于永远不发。

### 为什么投递点是 action 而不是 effect 里的调用

「什么时候该投递」是**状态决定的**，而只有 reducer 知道状态。于是投递成了环上的
一环：

```text
ToolBatchDone ──迁移：关 step──► wiring 看到 steer 队列非空
                              └─► Redispatch(QueueDelivered)
                                        └─► 迁移：插消息、弹队列
                                        └─► wiring：start_step()
```

## 轮数上限

`max_turns : Int?`（`None` = 不限，默认）。

判据在 `tool.batch.done` 的迁移里：`turns >= max_turns` 时开一个 `stop` 节点
（闭合、推进 tip）、相位 → idle。**必须在 reducer 里闭合**，否则「等环停下来」
永远等不到。

`turns` 数的是 **LLM 调用次数**，不是工具调用次数：一次 `LlmDone` 加 1，
哪怕这一轮并行发了 5 个工具。`UserMessage` 时归零。

## `/continue`

`TurnContinue` 做 `UserMessage` 的全部事情，**只少那条 user 消息**：

- 相位 idle → thinking，清掉 error / stop_reason / stop_cause；
- 计数器归零（含 `turns` —— 撞过上限的会话，不归零的话续跑第一步就又被砍）；
- 接线发 `TurnStart`（它自带 `StepStart` + `AgentRun`）；
- 末尾若挂着「有 toolCall、没有 toolResult」的 assistant，补一条 `is_error`
  的 toolResult —— 否则第一个请求就会被 provider 以非法消息序列拒掉。
  **只补末尾**：中插会让会话写入器的「已写条数」游标错位。

三条守卫：环在跑时不接、一条消息都没有不接。（压缩尚未接。）

## 轨迹树的 tip 规则

只有闭合（`ok` / `aborted`）的**对话族**节点推进 tip：

```text
user / turn.end / llm.result / tool.result / stop / compact
```

`error` 不在集合里 —— 这是「重试不推进 tip」的实现方式。容器也不在集合里。

装载族（`prompt.base` / `prompt.tools` / `model.init`）同样不推进 tip：
它们是「发给模型的上下文长什么样」，不是「发生过的事」。而且它们**推迟到
用户第一句话**才补上（`begin_trace`）：打开界面一句话没说就退出，不该在
盘上/树上留四个空节点。

## 接线表的几条不能动的规则

### 1. 接线读迁移之后的状态

`LlmFailed` 判出的 `retrying` 正是它的迁移刚算出来的。传旧状态的话，
接线永远看不到本次 action 造成的新事实，重试就发不出去。

同理，`LlmDone` 的接线**不能**用 `phase == thinking` 判断要不要跑工具 ——
那条迁移已经把相位推到 `calling-tools` 了，条件永远为假，工具永远不跑。
判据是「这次确实带工具调用」。

### 2. `UserMessage` 只发 `TurnStart`

若它同时发 `AgentRun`，`TurnStart` 里的 `start_step` 会再发一次 ——
LLM 被调两遍，第二遍的结果覆盖第一遍，树上就是两个 `llm.result` 兄弟。

### 3. `TurnEnd` 的接线看容器，不看队列

迁移已经把 followUp 从队列里取走了；再看队列会在「只有一条 followUp」
（最常见）时恒为空，于是新回合开了、消息也插了，模型永远不被调用。

### 4. 回合收口后 `TurnEnd` 是**另发**的

`LlmDone`（无工具）/ `LlmFailed`（不重试）/ `ToolBatchDone`（撞上限）都先把
相位推到 idle，然后由接线发 `TurnEnd`。

因此在「环刚停下来」这一刻读 state，看到的是 `phase == idle` 但
`open_turn_node_id` 仍然非空 —— 回合容器的闭合是**下一拍**的事。
要断言「回合确实收尾了」，得多跑一步（或读 `turn.end` 节点）。

## 测试策略

三层，各自盯一件事：

| 层 | 文件 | 盯什么 |
| --- | --- | --- |
| 轨迹树 | `core/trace/trace_wbtest.mbt` | tip 规则、重试统计、渲染缩进 |
| 表 | `core/loop/loop_wbtest.mbt` | 迁移后的状态、接线发的 Cmd（不接 effect） |
| 整环 | `core/runtime/runtime_wbtest.mbt` | 接假 effect 表，从一条用户消息跑到 idle |

整环测试不 mock 网络：effect 表就是几个闭包，按 state 决定发什么 action。
于是「重试」「steer」「followUp」「轮数上限」都能在毫秒级、确定性地断言。

## 已经接上的

- **异步 effect**：`EffectTable` 的两项都是 `async`；`Dispatch.send()` 同步归约，
  `flush_deferred()` 在 effect 边界 await。真实 provider（`core/provider`）就是
  按这个形状接的：SSE 增量在 await 期间逐条 dispatch。
- **provider**：pi 的 `models.json` / `auth.json` / `settings.json` → OpenAI 兼容
  的流式请求；详见 [provider](provider.md)。
- **工具**：`RunTools` 接上了八个内置工具（read / write / edit / bash /
  powershell / grep / find / ls），开关语义与 pi 的 `defaultTools` 一致；
  详见 [tools](tools.md)。
- **流式工具输出**：shell 命令边跑边读，`ToolProgress` 每 100ms 回到环上，
  写进 `state.tool_progress`；超时会保留 partial 输出。
- **会话落盘 / 恢复**：JSONL 追加写（`add` / `close` / `message` / 装载段），
  `session.restored` 一次性装回 state；详见 [session](session.md)。
- **工具集变更**：`tools.changed` 只改当前声明；下一次 `agent.run` 把差额作为
  一条新 system 消息追加并更新 `declared_tools`（不改 head / 不改历史消息）。
  声明写在防重入守卫**之前**：真实流程里 step 容器已经开了，守卫会跳过状态
  重置，但工具声明不能跳。

## 尚未接的部分（按计划的顺序）

1. **压缩 / 扩展 / 分支**：action 与迁移都未搬（刻意留在环稳定之后）。
