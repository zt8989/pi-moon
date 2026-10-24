// Cmd —— reducer 能返回的**唯一**一种副作用描述。
//
// 它是数据，不是闭包：于是「这个 action 该发哪些 effect」可以在测试里直接断言，
// 而不必真的去打网络。这也是本项目与 rabbita 的 `Cmd` 的差别：rabbita 的 Cmd
// 给 DOM 运行时用（不透明），这里的 Cmd 是 redux-loop 那种可检视的数据。
//
// 运行时解释它：
//   - `Redispatch(action)` → 把 action 送回 reducer（环上的一步）；
//   - `RunAgent` / `RunTools` → 交给注入的 effect 表。

///|
pub(all) enum Cmd {
  /// 什么也不做。批处理里方便占位。
  Noop
  /// 一组命令。运行时按顺序展开（**不会**嵌套丢失）。
  Batch(Array[Cmd])
  /// 把 action 重新 dispatch 出去：让 reducer 再看到它一次。
  Redispatch(@action.AgentAction)
  /// 跑一轮对话（= 调一次 LLM）。
  RunAgent(String?)
  /// 执行一批工具调用。
  RunTools(Array[@message.ToolCall])
  /// 压缩上下文：读 `state.compact_plan` → 打一次摘要请求 → 回一条 `compact.done`。
  RunCompact
} derive(Eq, Debug)

///|
/// 把嵌套的 `Batch` 摊平成叶子命令，丢掉 `Noop`。
///
/// 原项目踩过一个坑：接线返回裸 Cmd，若被外部再次包成 `Cmd.list`，redux-loop
/// 对**嵌套 LIST** 会把内层返回的 `[]` 一路吞掉 —— 那条 action 既没执行也没报错。
/// 这里在入口一次性摊平，从类型上让「嵌套」在运行时不可见。
pub fn flatten_cmds(cmds : Array[Cmd]) -> Array[Cmd] {
  let out : Array[Cmd] = []
  for cmd in cmds {
    flatten_into(cmd, out)
  }
  out
}

///|
fn flatten_into(cmd : Cmd, out : Array[Cmd]) -> Unit {
  match cmd {
    Noop => ()
    Batch(inner) =>
      for item in inner {
        flatten_into(item, out)
      }
    _ => out.push(cmd)
  }
}

///|
/// 一条命令 → 一批命令（保持顺序）。
pub fn Cmd::batch(cmds : Array[Cmd]) -> Cmd {
  Batch(cmds)
}

///|
/// `Redispatch` 的构造糖。
pub fn redispatch(action : @action.AgentAction) -> Cmd {
  Redispatch(action)
}

///|
/// 开下一个 step：先 `step.start`（开容器），再 `agent.run`（真的调 LLM）。
pub fn start_step_cmd() -> Cmd {
  Batch([redispatch(StepStart), redispatch(AgentRun(None))])
}

///|
/// 收工：只发一条 `turn.end`。
///
/// 绕一圈是必需的：`llm.done` / `llm.failed` 是从 effect 里回到 reducer 的，
/// 从那里直接改状态会绕开「回合容器由 turn.end 闭合」这条路径 —— 树上就少一个
/// 闭合点，`followUp` 也永远开不出新回合。
pub fn close_turn_cmd() -> Cmd {
  Redispatch(TurnEnd)
}
