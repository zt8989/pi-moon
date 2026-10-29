// 运行时 —— 环的驱动者。
//
// 它只做三件事：
//   1. 收 action，调 `reduce(state, action, now)`；
//   2. 把返回的 Cmd 摊平：`Redispatch` 立即再归约，`RunAgent` / `RunTools` 进 effect 队列；
//   3. 在 effect 边界 await —— 除此之外，环上没有别的地方等。
//
// **这里没有「agent 循环」**：没有 `while (还在干活)`、没有递归的 agent 调用。
// 环是 action 进、action 出自己接起来的 —— 驱动者只是那条传送带。
//
// 两个设计点：
//
// - **即时归约**：effect 通过 `Dispatch` 发回 action 时，`pump` 立刻把它归约掉
//   （而不是排到队尾）。于是流式 token 到达时 `state.streaming_text` 是**当下**的，
//   界面不必等整个请求结束才看到字。
// - **延迟 effect**：归约途中产生的 `RunAgent` / `RunTools` 进 deferred 队列，
//   等当前 effect 返回后再按顺序 await。这就是「环不递归、effect 不嵌套」的保证。
//
// effect 表是注入的：换一张表就换掉「谁真的去调模型 / 跑工具」，reducer 一个字都不用改。

///|
/// 交给 effect 的 dispatch 句柄。
///
/// effect 用它把结果（token 增量、工具结果、错误）送回环上。它是**同步**的：
/// 送进来的 action 当场归约，产生的 effect 进队列 —— 所以流式回调可以连着发
/// 很多条而不爆栈，也不会把当前 effect 自己的执行顺序打乱。
pub(all) struct Dispatch {
  emit : (@action.AgentAction) -> Unit raise
}

///|
pub fn Dispatch::send(
  self : Dispatch,
  action : @action.AgentAction,
) -> Unit raise {
  (self.emit)(action)
}

///|
/// effect 表：`RunAgent` / `RunTools` / `RunCompact` 的真正实现。
///
/// 三张表各自只拿到「当时的 state」与 dispatch 句柄 —— 它读不到 store，
/// 也改不了 state。想改状态只能发 action。
pub(all) struct EffectTable {
  run_agent : async (@state.AgentState, Dispatch) -> Unit
  run_tools : async (@state.AgentState, Array[@message.ToolCall], Dispatch) -> Unit
  run_compact : async (@state.AgentState, Dispatch) -> Unit
}

///|
/// 什么都不做的表：`RunAgent` / `RunTools` 被丢掉（用来测试「接线发对了没有」）。
/// `RunCompact` 例外：它回一条失败，因为「压到一半没人收尾」会把之后所有输入卡住。
pub fn noop_effect_table() -> EffectTable {
  {
    run_agent: async fn(_, _) { () },
    run_tools: async fn(_, _, _) { () },
    // 压缩不能「什么都不做」：那样 `compacting` 会永远卡住，之后所有输入都被拒。
    // 回一条失败，至少把状态放回 idle（对话原样保留）。
    run_compact: async fn(_, dispatch) {
      dispatch.send(
        @action.CompactFailed({ error: "本内核没有接入上下文压缩", }),
      )
    },
  }
}

///|
/// 异步事件汇：每条被归约的 action 在**异步边界**上交给它一次。
///
/// 为什么不是直接在归约里送达：归约是同步纯函数（流式回调里也要能调），而
/// 事件的目标（比如扩展宿主的行协议）要写进程、要等回执。所以这里只排队，
/// 真正送达发生在 `Agent::run` 的下一个 await 点 —— 顺序仍然是 action 的顺序。
///
/// 典型用途：扩展的 `turn_start` / `turn_end` 钩子（`tool_execution_*` 不在
/// 这里 —— 它们由工具执行那侧直接发，才能卡在工具真的跑之前 / 之后）。
pub(all) struct EventSink {
  deliver : async (@action.AgentAction) -> Unit
}

///|
/// 一个装配好的环。
///
/// `clock` 是注入的：reducer 不读时钟（纯函数），时间戳只在驱动者这里取一次。
pub(all) struct Agent {
  mut state : @state.AgentState
  table : EffectTable
  clock : () -> Int64
  /// 外部投递的 action 队列（FIFO）。
  queue : Array[@action.AgentAction]
  mut head : Int32
  /// 归约途中产生、等当前 effect 返回后再执行的 effect 命令。
  deferred : Array[@loop.Cmd]
  /// 还能处理多少条 action —— 防「effect 又发回同一条 action」的死循环。
  mut budget : Int32
  /// 已经处理过的 action 数（测试与演示用）。
  mut processed : Int32
  /// 每归约一条 action 调一次（渲染层订阅增量用）。
  mut observer : ((@action.AgentAction) -> Unit)?
  /// 事件汇（扩展的事件钩子）。
  mut sink : EventSink?
  /// 已经归约、还没送达的事件（按 action 顺序）。
  events : Array[@action.AgentAction]
}

///|
pub fn Agent::new(
  state : @state.AgentState,
  table : EffectTable,
  clock : () -> Int64,
) -> Agent {
  {
    state,
    table,
    clock,
    queue: [],
    head: 0,
    deferred: [],
    budget: 100000,
    processed: 0,
    observer: None,
    sink: None,
    events: [],
  }
}

///|
/// 订阅「每归约一条 action」。
///
/// 这是渲染层唯一的入口：流式增量到达时它会被逐条调用（**在** effect 还在跑的时候），
/// 所以终端 / 网页都能边收边画。回调拿不到 state 的引用，只该画 / 记日志。
pub fn Agent::observe(self : Agent, f : (@action.AgentAction) -> Unit) -> Unit {
  self.observer = Some(f)
}

///|
/// 订阅「每归约一条 action」的**异步**版本：与 `observe` 同样的触发点，但送
/// 达推迟到下一个 effect 边界（`flush_deferred` 里逐个 await）。
///
/// 两者可以共存：渲染要走同步（一帧都不能落下），扩展要走异步（要等进程）。
pub fn Agent::deliver_actions(self : Agent, sink : EventSink) -> Unit {
  self.sink = Some(sink)
}

///|
/// 把排队的事件按顺序送达。送达失败不影响环 —— 钩子是观测者，不是一环。
async fn Agent::drain_events(self : Agent) -> Unit {
  while !self.events.is_empty() {
    let action = self.events.remove(0)
    match self.sink {
      Some(sink) =>
        (sink.deliver)(action) catch {
          _ => ()
        }
      None => ()
    }
  }
}

///|
/// UI 事件的专用入口：**同步**归约一条 action，不排队、不碰 deferred 队列、
/// 不消耗防死循环预算。
///
/// 只该喂 `Ui(...)` 事件：它的接线不发 Cmd，归约拉不起任何 effect。键循环
/// 在生成中也能安全调用 —— 整个函数没有 await，协作式调度下不会与 driver
/// 正在 await 的 effect 交错；observer 照常触发，下一帧就带上新的界面状态。
pub fn Agent::dispatch_ui(
  self : Agent,
  action : @action.AgentAction,
) -> Unit raise {
  let now = (self.clock)()
  let (next, cmds) = @loop.reduce(self.state, action, now)
  self.state = next
  self.processed = self.processed + 1
  match self.observer {
    Some(observe) => observe(action)
    None => ()
  }
  self.absorb(cmds)
}

///|
/// 把一条 action 放进队列（不立即执行）。
pub fn Agent::enqueue(self : Agent, action : @action.AgentAction) -> Unit {
  self.queue.push(action)
}

///|
/// 收一条 action 并立刻把环跑到没有待处理 action 为止。
pub async fn Agent::send(self : Agent, action : @action.AgentAction) -> Unit {
  self.enqueue(action)
  self.run()
}

///|
/// 跑到外部队列空、且所有延迟 effect 都执行完。
pub async fn Agent::run(self : Agent) -> Unit {
  while true {
    self.drain_events()
    if self.head < self.queue.length() {
      let action = self.queue[self.head]
      self.head = self.head + 1
      self.pump(action)
      // 队列读空了就把数组收一收，长会话里不会无限增长。
      if self.head == self.queue.length() {
        self.queue.clear()
        self.head = 0
      }
    } else if !self.deferred.is_empty() {
      self.flush_deferred()
    } else {
      break
    }
  }
}

///|
/// 同步归约一条 action：状态迁移 + 接线 + 把 Cmd 分流到「立即再归约」或 deferred。
///
/// 它是**同步**的，所以 effect 可以在流式回调里随时调它；真正需要等待的只有
/// `RunAgent` / `RunTools`，它们在 `flush_deferred` 里 await。
fn Agent::pump(self : Agent, action : @action.AgentAction) -> Unit raise {
  if self.budget <= 0 {
    raise AgentError::BudgetExhausted
  }
  self.budget = self.budget - 1
  let now = (self.clock)()
  let (next, cmds) = @loop.reduce(self.state, action, now)
  self.state = next
  self.processed = self.processed + 1
  match self.observer {
    Some(observe) => observe(action)
    None => ()
  }
  match self.sink {
    Some(_) => self.events.push(action)
    None => ()
  }
  self.absorb(cmds)
}

///|
/// 把一批 Cmd 分流：`Redispatch` 立即归约（环上的一步），effect 进 deferred 队列。
fn Agent::absorb(self : Agent, cmds : Array[@loop.Cmd]) -> Unit raise {
  for cmd in @loop.flatten_cmds(cmds) {
    match cmd {
      @loop.Redispatch(action) => self.pump(action)
      @loop.Noop | @loop.Batch(_) => ()
      // RunAgent / RunTools
      _ => self.deferred.push(cmd)
    }
  }
}

///|
/// 按顺序 await 所有已排队的 effect。
///
/// effect 执行期间又会产生新的 deferred（例如 `llm.done` 带工具 → `RunTools`），
/// 所以这里是一个直到队列空为止的循环 —— 但每一圈只 await 一次 effect，
/// effect 与 effect 之间没有嵌套。
async fn Agent::flush_deferred(self : Agent) -> Unit {
  while !self.deferred.is_empty() {
    // 先送事件再跑下一个 effect：钩子看到的顺序与 action 的顺序一致，而且
    // `turn_start` 一定在它那一回合的 LLM 调用之前到达。
    self.drain_events()
    let cmd = self.deferred.remove(0)
    let dispatch : Dispatch = { emit: action => self.pump(action), }
    match cmd {
      @loop.RunAgent(_text) =>
        // effect 读的是**当前** state（reduce 已把它换成了迁移之后的那一版）。
        (self.table.run_agent)(self.state, dispatch)
      @loop.RunTools(calls) =>
        (self.table.run_tools)(self.state, calls, dispatch)
      @loop.RunCompact => (self.table.run_compact)(self.state, dispatch)
      @loop.Redispatch(action) => self.pump(action)
      _ => ()
    }
  }
}

///|
/// 从当前状态再跑一轮（外部 effect 只入队、没跑完时用）。
pub async fn Agent::pump_pending(self : Agent) -> Unit {
  self.run()
}

///|
/// 环上还有待处理的 action 吗。
pub fn Agent::pending(self : Agent) -> Bool {
  self.head < self.queue.length() || !self.deferred.is_empty()
}

///|
pub suberror AgentError {
  BudgetExhausted
}
