// 轨迹树（trace tree）—— 像 git log 一样，一次尝试一个节点的执行历史。
//
// 想法照搬 git：执行历史不是一条线而是一棵树（节点有 parent_id，tip 是
// 「最后一条成功闭合的节点」）。
//
// 最关键的一点：**error 节点不推进 tip**。后续尝试的产出与它平级、顺序即先后 ——
// 所以重试（连同它的多次失败）都包在**同一个 step 容器**里，树上不长分叉。
//
// 本文件是纯函数：没有 IO、不读时钟（`now` 由调用方传进来）。
// 同一个 action 序列 + 同一个 now 必然产出同一棵树，所以树能在 reducer 里算、
// 能在测试里断言、也能从 JSONL 回放重建。

///|
/// 节点类型。分两族：
///
///   - **对话族**（user / llm.* / tool.* / error / stop）—— 会推进 tip，是「发生过的事」。
///   - **上下文族**（prompt.* / model.*）—— **不推进 tip**，是「发给模型的上下文长什么样」。
pub(all) enum TraceNodeKind {
  User
  TurnStart
  TurnEnd
  StepStart
  StepEnd
  LlmResult
  ToolCallNode
  ToolResultNode
  ErrorNode
  StopNode
  CompactNode
  PromptBase
  PromptTools
  PromptSegment
  PromptSkills
  ModelInit
  ModelChanged
  ExtensionEvent
} derive(Eq, Debug)

///|
pub fn TraceNodeKind::name(self : TraceNodeKind) -> String {
  match self {
    User => "user"
    TurnStart => "turn.start"
    TurnEnd => "turn.end"
    StepStart => "step.start"
    StepEnd => "step.end"
    LlmResult => "llm.result"
    ToolCallNode => "tool.call"
    ToolResultNode => "tool.result"
    ErrorNode => "error"
    StopNode => "stop"
    CompactNode => "compact"
    PromptBase => "prompt.base"
    PromptTools => "prompt.tools"
    PromptSegment => "prompt.segment"
    PromptSkills => "prompt.skills"
    ModelInit => "model.init"
    ModelChanged => "model.changed"
    ExtensionEvent => "extension.event"
  }
}

///|
/// 名字 → 节点类型（JSONL 回放用）。`name()` 的逆运算。
pub fn TraceNodeKind::from_name(name : String) -> TraceNodeKind? {
  match name {
    "user" => Some(User)
    "turn.start" => Some(TurnStart)
    "turn.end" => Some(TurnEnd)
    "step.start" => Some(StepStart)
    "step.end" => Some(StepEnd)
    "llm.result" => Some(LlmResult)
    "tool.call" => Some(ToolCallNode)
    "tool.result" => Some(ToolResultNode)
    "error" => Some(ErrorNode)
    "stop" => Some(StopNode)
    "compact" => Some(CompactNode)
    "prompt.base" => Some(PromptBase)
    "prompt.tools" => Some(PromptTools)
    "prompt.segment" => Some(PromptSegment)
    "prompt.skills" => Some(PromptSkills)
    "model.init" => Some(ModelInit)
    "model.changed" => Some(ModelChanged)
    "extension.event" => Some(ExtensionEvent)
    _ => None
  }
}

///|
/// 节点状态。
///
/// 「闭合」（closed）是最重要的概念：**只有 closed 节点会推进 tip**。
/// 容器刚建时是 pending（它不推进 tip，因为它自己就是「发起中」）；
/// 它要么被标成 ok（成功），要么挂一个 error 孩子（失败）—— 两种情况都不直接推进 tip。
/// 真正推进 tip 的是 result / user / stop 这些 closed 节点。
pub(all) enum TraceNodeStatus {
  Pending
  Ok
  Errored
  Aborted
} derive(Eq, Debug)

///|
pub fn TraceNodeStatus::name(self : TraceNodeStatus) -> String {
  match self {
    Pending => "pending"
    Ok => "ok"
    Errored => "error"
    Aborted => "aborted"
  }
}

///|
pub fn TraceNodeStatus::from_name(name : String) -> TraceNodeStatus? {
  match name {
    "pending" => Some(Pending)
    "ok" => Some(Ok)
    "error" => Some(Errored)
    "aborted" => Some(Aborted)
    _ => None
  }
}

///|
pub(all) struct TraceNode {
  /// reducer 内单调自增的整数，转成字符串就是稳定 id（如 "n7"）。
  id : String
  /// 父节点 id；根为 None。
  parent_id : String?
  kind : TraceNodeKind
  status : TraceNodeStatus
  /// 短标签，渲染时显示。
  label : String
  /// 详细文本（LLM 回答全文、错误信息、工具参数…）。
  detail : String?
  /// 工具名 / provider / model 之类的附加信息。用数组保持插入顺序。
  meta : Array[(String, String)]
  /// 这条节点对应的对话消息。只有「会产生一条消息」的节点才有。
  message : @message.Message?
  created_at : Int64
  /// 闭合时刻（未闭合为 None）；与 created_at 相减得到耗时。
  ended_at : Int64?
} derive(Eq, Debug)

///|
pub(all) struct TraceTree {
  /// 扁平节点表，按 id 索引。持久化结构：追加节点得到新树，旧树仍可用。
  nodes : @ihm.HashMap[String, TraceNode]
  /// 插入顺序（= 时间顺序），用于稳定渲染。
  order : Array[String]
  /// 最后一条 closed 节点的 id；None 表示还没有。
  tip_id : String?
  /// 自增计数器，节点 id 的来源。
  next_seq : Int32
  /// 会话 id（持久化文件名用它）。
  session_id : String
} derive(Eq, Debug)

///|
pub fn create_trace_tree(session_id : String) -> TraceTree {
  {
    nodes: @ihm.HashMap::new(),
    order: [],
    tip_id: None,
    next_seq: 1,
    session_id,
  }
}

///|
/// 只有这几类节点推进 tip。**容器（turn.* / step.start）永远不推进** ——
/// 它们是区间的起点，闭合点是里面的 result / error / turn.end 子节点。
///
/// 这条规则正是「重试的产出与失败平级、全在同一个容器里」的根本原因。
pub fn advances_tip(node : TraceNode) -> Bool {
  let closed = match node.status {
    Ok | Aborted => true
    _ => false
  }
  let advancing = match node.kind {
    User | TurnEnd | LlmResult | ToolResultNode | StopNode | CompactNode => true
    _ => false
  }
  closed && advancing
}

///|
/// 建一个节点并挂到 `parent_id` 下。
///
/// `parent_id` 显式接受 None（根），**不继承父节点** —— 它就是调用方在
/// 发起那一刻的 tip。
pub fn append_node(
  tree : TraceTree,
  parent_id : String?,
  kind : TraceNodeKind,
  status : TraceNodeStatus,
  label : String,
  now : Int64,
  detail? : String,
  meta? : Array[(String, String)],
  message? : @message.Message,
  ended_at? : Int64,
) -> (TraceTree, TraceNode) {
  let seq = tree.next_seq
  let id = "n" + seq.to_string()
  let node : TraceNode = {
    id,
    parent_id,
    kind,
    status,
    label,
    detail,
    meta: match meta {
      Some(entries) => entries
      None => []
    },
    message,
    created_at: now,
    ended_at,
  }
  let tree : TraceTree = {
    ..tree,
    nodes: tree.nodes.add(id, node),
    order: tree.order.add([id]),
    next_seq: seq + 1,
    tip_id: if advances_tip(node) {
      Some(id)
    } else {
      tree.tip_id
    },
  }
  (tree, node)
}

///|
/// 就地更新一个节点（闭合 attempt、补 detail 等）。没有这个节点就原样返回。
///
/// 闭合一个 attempt（pending → ok）**不会**推进 tip：它只是把容器标成已完成，
/// 推进 tip 的是它的 result / user / stop 孩子。
pub fn patch_node(
  tree : TraceTree,
  id : String,
  status? : TraceNodeStatus,
  label? : String,
  detail? : String,
  meta? : Array[(String, String)],
  ended_at? : Int64,
) -> TraceTree {
  let existing = match tree.nodes.get(id) {
    Some(node) => node
    None => return tree
  }
  let node : TraceNode = {
    ..existing,
    status: match status {
      Some(value) => value
      None => existing.status
    },
    label: match label {
      Some(value) => value
      None => existing.label
    },
    detail: match detail {
      Some(value) => Some(value)
      None => existing.detail
    },
    meta: match meta {
      Some(value) => value
      None => existing.meta
    },
    ended_at: match ended_at {
      Some(value) => Some(value)
      None => existing.ended_at
    },
  }
  {
    ..tree,
    nodes: tree.nodes.add(id, node),
    tip_id: if advances_tip(node) {
      Some(id)
    } else {
      tree.tip_id
    },
  }
}

///|
/// 从 JSONL 回放一个节点：**保留原 id**（不像 `append_node` 那样重新编号）。
///
/// 同 id 再次回放时覆盖（`add` 记录可能先以 pending 落盘、后来带着同一 id
/// 重新出现，或者由 `close` 补丁修正）。`seq` 是记录里带的自增号，只用来推
/// `next_seq`，不参与 id 拼接。
pub fn restore_node(
  tree : TraceTree,
  node : TraceNode,
  seq : Int32,
) -> TraceTree {
  let order = match tree.nodes.get(node.id) {
    Some(_) => tree.order
    None => tree.order.add([node.id])
  }
  {
    ..tree,
    nodes: tree.nodes.add(node.id, node),
    order,
    next_seq: if seq >= tree.next_seq {
      seq + 1
    } else {
      tree.next_seq
    },
  }
}

///|
/// 回放完一遍后重算 tip：按插入顺序，最后一个**闭合且会推进 tip** 的节点。
///
/// 正常运行时 tip 是在 `append_node` 那一刻推进的；回放时节点可能先以 pending
/// 落盘、后来才由 `close` 补丁闭合，所以必须最后统一算一次。
pub fn recompute_tip(tree : TraceTree) -> TraceTree {
  let mut tip : String? = None
  for id in tree.order {
    match tree.nodes.get(id) {
      Some(node) => if advances_tip(node) { tip = Some(id) }
      None => ()
    }
  }
  { ..tree, tip_id: tip, }
}

///|
/// `"n12"` → `12`。取不到数字时返回 0（坏 id 不会让回放炸掉）。
pub fn node_seq(id : String) -> Int32 {
  let mut value = 0
  let mut index = if id.has_prefix("n") { 1 } else { 0 }
  while index < id.length() {
    let digit = match id.get_char(index) {
      Some(character) => character.to_int() - 48
      None => break
    }
    if digit < 0 || digit > 9 {
      break
    }
    value = value * 10 + digit
    index = index + 1
  }
  value
}

///|
pub fn get_node(tree : TraceTree, id : String) -> TraceNode? {
  tree.nodes.get(id)
}

///|
/// 某个节点的孩子（按插入顺序）。
///
/// 扫一遍 `order`，是 O(N)。**不要在循环里反复叫它** —— 那会变成 O(N²)。
pub fn children_of(tree : TraceTree, id : String?) -> Array[TraceNode] {
  let children : Array[TraceNode] = []
  for child_id in tree.order {
    match tree.nodes.get(child_id) {
      Some(node) => if node.parent_id == id { children.push(node) }
      None => ()
    }
  }
  children
}

///|
/// 从根到某节点的祖先链（含自己），用于展示「当前在哪条线上」。
pub fn path_to(tree : TraceTree, id : String) -> Array[TraceNode] {
  let chain : Array[TraceNode] = []
  let mut cursor : String? = Some(id)
  while true {
    match cursor {
      Some(node_id) =>
        match tree.nodes.get(node_id) {
          Some(node) => {
            chain.insert(0, node)
            cursor = node.parent_id
          }
          None => break
        }
      None => break
    }
  }
  chain
}

///|
/// 从根到 tip 的那条线（`git log HEAD` 看到的那条线）。
pub fn head_path(tree : TraceTree) -> Array[TraceNode] {
  match tree.tip_id {
    Some(id) => path_to(tree, id)
    None => []
  }
}

///|
pub(all) struct TraceStats {
  turns : Int32
  steps : Int32
  tool_calls : Int32
  errors : Int32
  retries : Int32
  duration_ms : Int64
} derive(Eq, Debug)

///|
/// 统计树的规模。
///
/// 数 `turn.start` / `step.start` 的**开口**而不是闭合点：回合还在跑就已经算上了
/// —— 因为 `turn.end` 是环转 idle 之后才发的，等它会让顶栏在整轮里都少一个。
pub fn trace_stats(tree : TraceTree) -> TraceStats {
  let mut turns = 0
  let mut steps = 0
  let mut tool_calls = 0
  let mut errors = 0
  let mut duration_ms : Int64 = 0L
  // error 按 parent 分桶，再逐个 step 容器汇总。
  let errors_by_parent : @ihm.HashMap[String, Int32] = @ihm.HashMap::new()
  let mut errors_by_parent = errors_by_parent
  for id in tree.order {
    match tree.nodes.get(id) {
      Some(node) => {
        match node.kind {
          TurnStart => turns = turns + 1
          StepStart => steps = steps + 1
          ToolResultNode => tool_calls = tool_calls + 1
          ErrorNode => {
            errors = errors + 1
            match node.parent_id {
              Some(parent) =>
                errors_by_parent = errors_by_parent.add(
                  parent,
                  errors_by_parent.get(parent).unwrap_or(0) + 1,
                )
              None => ()
            }
          }
          _ => ()
        }
        match node.ended_at {
          Some(ended) => duration_ms = duration_ms + (ended - node.created_at)
          None => ()
        }
      }
      None => ()
    }
  }
  // 重试口径：同一个 step 容器内，每个 error 孩子对应一次失败尝试；
  // 容器最终成功收口时全部算重试，失败收口时最后一个 error 是收工本身、不算重试。
  let mut retries = 0
  if steps > 0 {
    for id in tree.order {
      match tree.nodes.get(id) {
        Some(node) =>
          if node.kind == StepStart {
            let failed = errors_by_parent.get(id).unwrap_or(0)
            if failed > 0 {
              retries = retries +
                (if node.status == Ok {
                  failed
                } else if failed > 0 {
                  failed - 1
                } else {
                  0
                })
            }
          }
        None => ()
      }
    }
  }
  { turns, steps, tool_calls, errors, retries, duration_ms, }
}

// ─── 渲染：lazygit 风格的轨道树 ───

///|
/// 一行轨迹的渲染结果。
pub(all) struct TraceRow {
  node : TraceNode
  /// 行首的轨道 + 节点符号（纯文本，不含颜色）。
  prefix : String
  /// 整行文本 = prefix + id + kind + label + 耗时 + meta，已按 max_width 截断。
  text : String
} derive(Eq, Debug)

///|
/// 容器符号：只有「轮」与「步」会给子孙加一级缩进。
fn opens_scope(kind : TraceNodeKind) -> Bool {
  match kind {
    TurnStart | StepStart => true
    _ => false
  }
}

///|
/// 闭合点画在自己容器那一列（缩进不 +1），符号 `└─`，于是括号是闭合的。
fn closes_scope(kind : TraceNodeKind) -> Bool {
  match kind {
    TurnEnd | StepEnd => true
    _ => false
  }
}

///|
/// 一级轨道的宽度（3）。符号必须同宽，否则竖线会错位。
let rail : String = "│  "

///|
let dot : String = "○  "

///|
let corner : String = "└─ "

///|
fn rail_prefix(depth : Int32) -> String {
  let builder = StringBuilder()
  for _ in 0..<depth {
    builder.write_string(rail)
  }
  builder.to_string()
}

///|
fn truncate(text : String, width : Int32) -> String {
  if width <= 0 || text.length() <= width {
    return text
  }
  let keep = if width > 1 { width - 1 } else { 0 }
  text[0:keep].to_owned() + "…"
}

///|
fn meta_suffix(node : TraceNode) -> String {
  if node.meta.is_empty() {
    return ""
  }
  let parts : Array[String] = []
  for pair in node.meta {
    let (key, value) = pair
    parts.push(key + "=" + value)
  }
  " (" + parts.join(", ") + ")"
}

///|
/// 把整棵树算成一行一行（含每行的轨道前缀）。形状仿 lazygit 的 `--graph`：
///
/// ```text
/// ○  n1 user: 查两个
/// ○  n2 turn.start: 回合 1
/// │  ○  n3 step.start: 第 1 步
/// │  │  ○  n4 llm.result: 并行 [调用 bash] [调用 bash]
/// │  └─ n7 step.end: 第 1 步结束（2 个工具调用）
/// └─ n8 turn.end: 回合 1 结束：模型说完了
/// ```
///
/// **缩进只由容器给**（`turn.start` 与 `step.start` 无条件给子孙加一级）。
/// 不按父子关系缩进：轨迹树的链是一条直线，按父子缩进会让第 10 轮跑到第 10 层。
///
/// 实现：按 `order`（= 发生顺序）扫一遍，维护一个作用域栈 ——
/// 容器的**关闭时机**是事件性的，只看树不够。四条收口规则：
///
/// | 遇到 | 做什么 | 为什么 |
/// | --- | --- | --- |
/// | `turn.end` / `step.end` | 关掉 `parent_id` 那个作用域 | 闭合点画在容器那一列 |
/// | `turn.start` | 清空（回合不嵌套） | 上一个回合没等到 `turn.end` 时也要收 |
/// | `step.start` | 先关掉已经开着的 step | 旧的那一格不该还挂着 |
/// | `user`（`meta.queued != steer`） | 清空整个栈 | 「用户又发了一句话」= 新回合从根层开始 |
pub fn trace_rows(tree : TraceTree, max_width? : Int32) -> Array[TraceRow] {
  let width = match max_width {
    Some(value) => value
    None => 100
  }
  let rows : Array[TraceRow] = []
  if tree.order.is_empty() {
    return rows
  }
  // 当前开着的作用域（容器），栈顶是最内层。元素是 (容器 id, 容器 kind)。
  let stack : Array[(String, TraceNodeKind)] = []

  /// 关掉 `id` 这个容器：它自己和它里面还开着的都弹掉。没开着就什么也不做。
  fn close_scope(id : String?) -> Unit {
    match id {
      Some(scope_id) => {
        let mut at = -1
        for index in 0..<stack.length() {
          let (candidate, _) = stack[index]
          if candidate == scope_id {
            at = index
            break
          }
        }
        if at >= 0 {
          stack.truncate(at)
        }
      }
      None => ()
    }
  }

  for id in tree.order {
    match tree.nodes.get(id) {
      None => ()
      Some(node) => {
        // 先收口（见上面那张表），再画这一行。
        match node.kind {
          // 闭合点：把自己那个容器关掉。**先弹栈再画** —— 于是 step.end 与
          // step.start 同列（└─），括号才是闭合的。
          TurnEnd | StepEnd => close_scope(node.parent_id)
          // 新回合：上一个回合的作用域收掉（回合不嵌套）。
          TurnStart => stack.clear()
          // 新的一步：上一个还没关的 step 收掉。
          StepStart => {
            let mut at = -1
            for index in 0..<stack.length() {
              let (_, kind) = stack[index]
              if kind == StepStart {
                at = index
                break
              }
            }
            if at >= 0 {
              stack.truncate(at)
            }
          }
          // 用户又发了一句话（不是插话）= 新回合，从根层重新开始缩进。
          User => if meta_get(node, "queued") != Some("steer") { stack.clear() }
          _ => ()
        }

        let marker = if closes_scope(node.kind) { corner } else { dot }
        let prefix = rail_prefix(stack.length()) + marker
        let elapsed = match node.ended_at {
          Some(ended) => " " + format_duration(ended - node.created_at)
          None => ""
        }
        let head = prefix +
          node.id +
          " " +
          node.kind.name() +
          ": " +
          node.label +
          elapsed +
          meta_suffix(node)
        rows.push({ node, prefix, text: truncate(head, width), })
        if opens_scope(node.kind) {
          stack.push((node.id, node.kind))
        }
      }
    }
  }
  rows
}

///|
/// 读一个 meta 值。
pub fn meta_get(node : TraceNode, key : String) -> String? {
  for pair in node.meta {
    let (candidate, value) = pair
    if candidate == key {
      return Some(value)
    }
  }
  None
}

///|
/// 把树渲染成多行字符串。
pub fn render_tree(tree : TraceTree, max_width? : Int32) -> String {
  let rows = trace_rows(tree, max_width?)
  if rows.is_empty() {
    return "（轨迹为空）"
  }
  let lines : Array[String] = []
  for row in rows {
    lines.push(row.text)
  }
  lines.join("\n")
}

///|
pub fn format_duration(ms : Int64) -> String {
  if ms < 1000L {
    return ms.to_string() + "ms"
  }
  if ms < 60000L {
    let tenths = (ms * 10L + 500L) / 1000L
    let whole = tenths / 10L
    let frac = tenths % 10L
    return whole.to_string() + "." + frac.to_string() + "s"
  }
  let minutes = ms / 60000L
  let seconds = ms % 60000L / 1000L
  let padded = if seconds < 10L {
    "0" + seconds.to_string()
  } else {
    seconds.to_string()
  }
  minutes.to_string() + "m" + padded + "s"
}
