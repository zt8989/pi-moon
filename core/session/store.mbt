// 会话文件：JSONL 追加写 + 回放。
//
// 写入是**增量**的：每个节点只在第一次出现时写一条完整的 `add`，之后闭合只
// 补一条 `close`；消息按条数游标追加。所以同一段对话重复 flush 不会重复写。
//
// 调用方（CLI）在「一个回合跑完」后 flush 一次；这是刻意的时间粒度：写盘不是
// 环上的 action，不参与 reducer，也不打断流式输出。

///|
/// 从文件读回来的会话。
pub(all) struct LoadedSession {
  messages : Array[@message.Message]
  trace : @trace.TraceTree
  /// 装载段（head）：system prompt + 装载时那批工具。
  prompt : @action.PromptInitData?
  /// 中途 `tools.changed` 过的话，这里是**当前**工具集；没有就是 None。
  tools : Array[@action.PromptToolDefinition]?
  model : @action.ModelSpec?
  /// 已经 `add` 过的最大节点序号（`TracePersisted` 的游标）。
  persisted_seq : Int32
}

///|
/// 追加写句柄。游标都在这里，不放 state：它们是「盘上写到哪了」的事实，
/// 不是 reducer 的状态。
pub(all) struct SessionWriter {
  path : String
  node_cursor : Int32
  message_cursor : Int32
  /// prompt.init 是否已经写过（prompt 在会话里不会再变）。
  prompt_written : Bool
  /// 上一次写过的模型（provider / model / thinking）。变了才再写一条。
  model_key : String
  /// 上一次写过的工具集。变了才写一条 `tools.changed`。
  tools_key : String
  /// 已经 add 过、但落盘时还没闭合的节点（后面要补 close）。
  open_nodes : @ihm.HashMap[String, Bool]
}

///|
pub fn SessionWriter::new(path : String) -> SessionWriter {
  {
    path,
    node_cursor: 0,
    message_cursor: 0,
    prompt_written: false,
    model_key: "",
    tools_key: "",
    open_nodes: @ihm.HashMap::new(),
  }
}

///|
/// 接上一个已有会话继续写：游标从文件里读到的位置开始，避免重写历史。
pub fn SessionWriter::restored(
  path : String,
  loaded : LoadedSession,
) -> SessionWriter {
  let mut open_nodes = @ihm.HashMap::new()
  for id in loaded.trace.order {
    match loaded.trace.nodes.get(id) {
      Some(node) =>
        if node.status == @trace.Pending || node.ended_at is None {
          open_nodes = open_nodes.add(id, true)
        }
      None => ()
    }
  }
  {
    path,
    node_cursor: loaded.persisted_seq,
    message_cursor: loaded.messages.length(),
    prompt_written: match loaded.prompt {
      Some(_) => true
      None => false
    },
    model_key: match loaded.model {
      Some(model) =>
        model_key_of_spec(model.provider, model.model_id, model.thinking_level)
      None => ""
    },
    tools_key: tools_key_of(current_tools_of(loaded)),
    open_nodes,
  }
}

///|
/// 恢复时「当前工具集」：有 `tools.changed` 就用它，否则用 head。
fn current_tools_of(
  loaded : LoadedSession,
) -> Array[@action.PromptToolDefinition] {
  match loaded.tools {
    Some(tools) => tools
    None =>
      match loaded.prompt {
        Some(prompt) => prompt.tools
        None => []
      }
  }
}

///|
/// 工具集的指纹：名字 + 描述 + schema 都变了才需要重新声明。
fn tools_key_of(tools : Array[@action.PromptToolDefinition]) -> String {
  let parts : Array[String] = []
  for tool in tools {
    parts.push(
      tool.name + "\u{0000}" + tool.description + "\u{0000}" + tool.parameters,
    )
  }
  parts.join("\u{0001}")
}

///|
fn model_key_of_spec(
  provider : String,
  model_id : String,
  thinking_level : String,
) -> String {
  provider + "\u{0000}" + model_id + "\u{0000}" + thinking_level
}

///|
fn model_key_of_state(model : @state.ModelState) -> String {
  model_key_of_spec(model.provider, model.model_id, model.thinking_level)
}

///|
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) => if index == 0 { "/" } else { path[:index].to_owned() }
    None => "."
  }
}

///|
fn add_record(node : @trace.TraceNode, seq : Int32) -> String {
  jobj([("op", jstr("add")), ("seq", jint(seq)), ("node", encode_node(node))]).stringify()
}

///|
fn close_record(node : @trace.TraceNode) -> String {
  let ended_at = match node.ended_at {
    Some(value) => jint64(value)
    None => Json::null()
  }
  jobj([
    ("op", jstr("close")),
    ("id", jstr(node.id)),
    ("status", jstr(node.status.name())),
    ("ended_at", ended_at),
  ]).stringify()
}

///|
fn message_record(message : @message.Message) -> String {
  jobj([("op", jstr("message")), ("message", encode_message(message))]).stringify()
}

///|
/// 把「还没落盘的部分」追加进文件，返回新的 `TracePersisted` 游标。
///
/// 写入前会按需建父目录。重复调用是安全的：没有新内容就一行也不写。
pub async fn SessionWriter::flush(
  self : SessionWriter,
  state : @state.AgentState,
) -> (SessionWriter, Int32) {
  let lines : Array[String] = []
  let mut prompt_written = self.prompt_written
  let mut model_key = self.model_key
  let mut tools_key = self.tools_key
  let mut node_cursor = self.node_cursor
  let mut message_cursor = self.message_cursor
  let mut open_nodes = self.open_nodes
  if state.prompt.seeded {
    if !prompt_written {
      lines.push(encode_prompt_init(state.prompt).stringify())
      prompt_written = true
      tools_key = tools_key_of(state.prompt.tools)
    } else {
      let key = tools_key_of(state.prompt.tools)
      if key != tools_key {
        lines.push(encode_tools_changed(state.prompt.tools).stringify())
        tools_key = key
      }
    }
  }
  if state.model.seeded {
    let key = model_key_of_state(state.model)
    if key != model_key {
      lines.push(encode_model_init(state.model).stringify())
      model_key = key
    }
  }
  // 新节点 → add；之前 add 过、现在闭合了 → close。
  for id in state.trace.order {
    match state.trace.nodes.get(id) {
      Some(node) => {
        let seq = @trace.node_seq(node.id)
        if seq > node_cursor {
          lines.push(add_record(node, seq))
          if node.status == @trace.Pending || node.ended_at is None {
            open_nodes = open_nodes.add(id, true)
          }
          node_cursor = seq
        } else if open_nodes.contains(id) &&
          (node.status != @trace.Pending || node.ended_at is Some(_)) {
          lines.push(close_record(node))
          open_nodes = open_nodes.remove(id)
        }
      }
      None => ()
    }
  }
  // 消息按条数游标追加（messages 只增长；ConversationReset 不在本版 CLI 里用）。
  while message_cursor < state.messages.length() {
    lines.push(message_record(state.messages[message_cursor]))
    message_cursor = message_cursor + 1
  }
  let next : SessionWriter = {
    ..self,
    node_cursor,
    message_cursor,
    prompt_written,
    model_key,
    tools_key,
    open_nodes,
  }
  if lines.is_empty() {
    return (next, node_cursor)
  }
  let directory = parent_dir(self.path)
  if !(@fs.exists(directory) catch { _ => false }) {
    @fs.mkdir(directory, recursive=true) catch {
      err => raise SessionError::Write(path=self.path, message=err.to_string())
    }
  }
  let text = lines.join("\n") + "\n"
  @fs.write_file(self.path, text, append=true, create_mode=OpenOrCreate) catch {
    err => raise SessionError::Write(path=self.path, message=err.to_string())
  }
  (next, node_cursor)
}

///|
pub suberror SessionError {
  Write(path~ : String, message~ : String)
}

///|
pub fn SessionError::to_string(self : SessionError) -> String {
  match self {
    Write(path~, message~) => "无法写会话文件 " + path + "：" + message
  }
}

// ─── 回放 ────────────────────────────────────────────────────────────────────

///|
/// 读一个会话文件。文件不存在 / 空文件返回 None（当新会话）。
///
/// 坏行跳过：崩溃时最后一行可能是截断的 JSON。
pub async fn load_session(path : String, session_id : String) -> LoadedSession? {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let data = @fs.read_file(path) catch { _ => return None }
  let text = @utf8.decode_lossy(data.binary())
  let messages : Array[@message.Message] = []
  let mut trace = @trace.create_trace_tree(session_id)
  let mut prompt : @action.PromptInitData? = None
  let mut tools : Array[@action.PromptToolDefinition]? = None
  let mut model : @action.ModelSpec? = None
  let mut persisted_seq : Int32 = 0
  let mut saw_record = false
  for line in text.split("\n") {
    let line = line.trim()
    if line.is_empty() {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    let obj = match json {
      Object(obj) => obj
      _ => continue
    }
    saw_record = true
    match field_string_or(obj, "op", "") {
      "add" => {
        let seq = field_int(obj, "seq").unwrap_or(0)
        match decode_node(obj_field(obj, "node")) {
          Some(node) => {
            trace = @trace.restore_node(trace, node, seq)
            if seq > persisted_seq {
              persisted_seq = seq
            }
          }
          None => ()
        }
      }
      "close" => {
        let id = field_string_or(obj, "id", "")
        let status = match
          @trace.TraceNodeStatus::from_name(field_string_or(obj, "status", "")) {
          Some(status) => Some(status)
          None => None
        }
        let ended_at = field_int64(obj, "ended_at")
        if !id.is_empty() {
          trace = @trace.patch_node(trace, id, status?, ended_at?)
        }
      }
      "message" =>
        match decode_message(obj_field(obj, "message")) {
          Some(message) => messages.push(message)
          None => ()
        }
      "prompt.init" => prompt = decode_prompt_init(json)
      "tools.changed" => tools = decode_tools_changed(json)
      "model.init" => model = decode_model_init(json)
      _ => ()
    }
  }
  if !saw_record {
    return None
  }
  Some({
    messages,
    trace: @trace.recompute_tip(trace),
    prompt,
    tools,
    model,
    persisted_seq,
  })
}

///|
/// 目录里最新的一个会话文件（`--continue` 用）。
///
/// 文件名以毫秒时间戳开头，所以字典序 = 时间序。
pub async fn latest_session(directory : String) -> String? {
  let entries = @fs.readdir(directory) catch { _ => return None }
  let mut best : String? = None
  for entry in entries {
    if !entry.has_suffix(".jsonl") {
      continue
    }
    best = match best {
      Some(current) =>
        if entry.compare(current) > 0 {
          Some(entry)
        } else {
          Some(current)
        }
      None => Some(entry)
    }
  }
  match best {
    Some(name) => Some(directory + "/" + name)
    None => None
  }
}

///|
/// 新会话文件路径（`<dir>/<毫秒时间戳>.jsonl`）。
pub fn new_session_path(directory : String, timestamp : Int64) -> String {
  directory + "/" + timestamp.to_string() + ".jsonl"
}

///|
/// 从路径取会话 id（去掉目录与 `.jsonl`）。
pub fn session_id_from_path(path : String) -> String {
  let name = match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
  let name = if name.has_suffix(".jsonl") {
    name[:name.length() - 6].to_owned()
  } else {
    name
  }
  if name.is_empty() {
    "session"
  } else {
    name
  }
}
