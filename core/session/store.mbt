// 会话文件：JSONL 追加写 + 回放。
//
// 布局与 pi 同构：同一个会话两份文件同名不同目录，
//
// ```text
// <agent dir>/
//   sessions/--<cwd 编码>--/<ISO 时间戳>_<id>.jsonl   会话：header + 模型变更 + 消息 + 压缩
//   traces/--<cwd 编码>--/<ISO 时间戳>_<id>.jsonl     轨迹：装载段 + add/close
// ```
//
// 写入是**增量**的：轨迹节点只在第一次出现时写一条完整的 `add`，之后闭合只
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
  /// 会话 id（header 行的 `id`；旧格式文件没有 header，回退调用方传进来的那个）。
  session_id : String
  /// header 里的工作目录（旧格式没有，回退空串）。
  cwd : String
}

///|
/// 追加写句柄。游标都在这里，不放 state：它们是「盘上写到哪了」的事实，
/// 不是 reducer 的状态。
///
/// 文件布局与 pi 同构：**sessions 文件只放会话**（header + 模型变更 + 消息 +
/// 压缩），**traces 文件放轨迹**（装载段 + add/close）。同一个会话两份文件同名
/// 不同目录（见 `SessionPaths`）。
pub(all) struct SessionWriter {
  /// 会话文件（sessions/--<cwd>--/<时间戳>_<id>.jsonl）。
  path : String
  /// 轨迹文件（traces/--<cwd>--/<时间戳>_<id>.jsonl）。
  trace_path : String
  /// 会话 id（header 里写的就是它）。
  session_id : String
  /// header 是否写过（每个文件只写一次；恢复旧文件时不重写）。
  header_written : Bool
  message_cursor : Int32
  /// 上一次写过的模型（provider / model / thinking）。变了才再写一条。
  model_key : String
  /// 上一次写过的压缩代数。变了就说明压缩整段换掉了 messages。
  compaction_epoch : Int32
  /// 轨迹侧游标（add 过的最大 seq）与未闭合节点。
  node_cursor : Int32
  open_nodes : @ihm.HashMap[String, Bool]
  /// prompt.init / tools.changed 是否已经写过（轨迹侧）。
  trace_prompt_written : Bool
  trace_tools_key : String
  /// 轨迹侧的模型游标（model.init 记在轨迹里，与 pi 的 trace 文件一致）。
  trace_model_key : String
}

///|
pub fn SessionWriter::new(path : String, trace_path : String, session_id : String) -> SessionWriter {
  {
    path,
    trace_path,
    session_id,
    header_written: false,
    message_cursor: 0,
    model_key: "",
    compaction_epoch: 0,
    node_cursor: 0,
    open_nodes: @ihm.HashMap::new(),
    trace_prompt_written: false,
    trace_tools_key: "",
    trace_model_key: "",
  }
}

///|
/// 接上一个已有会话继续写：游标从文件里读到的位置开始，避免重写历史。
pub fn SessionWriter::restored(
  path : String,
  trace_path : String,
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
    trace_path,
    session_id: loaded.session_id,
    // 恢复旧文件：header 已经在盘上，不重写。
    header_written: true,
    message_cursor: loaded.messages.length(),
    model_key: match loaded.model {
      Some(model) =>
        model_key_of_spec(model.provider, model.model_id, model.thinking_level)
      None => ""
    },
    // 从 0 起算：state 也是 0，于是恢复后第一次 flush 不会重写历史；
    // 之后每压缩一次，state 的 epoch 就会超过它，照常触发一次整份重写。
    compaction_epoch: 0,
    node_cursor: loaded.persisted_seq,
    open_nodes,
    trace_prompt_written: loaded.prompt is Some(_),
    trace_tools_key: tools_key_of(current_tools_of(loaded)),
    trace_model_key: match loaded.model {
      Some(model) =>
        model_key_of_spec(model.provider, model.model_id, model.thinking_level)
      None => ""
    },
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
/// 会话 header（pi 同形）：`{"type":"session","version":3,"id":…,"timestamp":…,"cwd":…}`。
fn session_header(session_id : String, cwd : String, ms : Int64) -> String {
  jobj([
    ("type", jstr("session")),
    ("version", jint(3)),
    ("id", jstr(session_id)),
    ("timestamp", jstr(file_timestamp(ms))),
    ("cwd", jstr(cwd)),
  ]).stringify()
}

///|
/// 把「还没落盘的部分」追加进两份文件，返回新的 `TracePersisted` 游标。
///
/// 写入前会按需建父目录。重复调用是安全的：没有新内容就一行也不写。
pub async fn SessionWriter::flush(
  self : SessionWriter,
  state : @state.AgentState,
) -> (SessionWriter, Int32) {
  // ── 会话侧：header / model.init / message / compact ──
  let lines : Array[String] = []
  let mut header_written = self.header_written
  let mut model_key = self.model_key
  let mut message_cursor = self.message_cursor
  let mut compaction_epoch = self.compaction_epoch
  if !header_written {
    lines.push(session_header(self.session_id, state.cwd, now_unix_ms()))
    header_written = true
  }
  if state.model.seeded {
    let key = model_key_of_state(state.model)
    if key != model_key {
      lines.push(encode_model_init(state.model).stringify())
      model_key = key
    }
  }
  // 压缩整段换掉了 messages：增量游标不再成立，写一条 `compact` 记录带上整份历史。
  // 回放时它会重置 messages，之后的 `message` 记录再从新历史的尾巴往下长。
  if state.compaction_epoch != compaction_epoch {
    lines.push(encode_compaction(state.messages).stringify())
    compaction_epoch = state.compaction_epoch
    message_cursor = state.messages.length()
  }
  // 消息按条数游标追加（没压缩过时 messages 只增长）。
  while message_cursor < state.messages.length() {
    lines.push(message_record(state.messages[message_cursor]))
    message_cursor = message_cursor + 1
  }
  let next : SessionWriter = {
    ..self,
    header_written,
    message_cursor,
    model_key,
    compaction_epoch,
  }
  if !lines.is_empty() {
    append_file(self.path, lines)
  }
  // ── 轨迹侧：prompt.init / tools.changed / model.init / add / close ──
  let trace_lines : Array[String] = []
  let mut node_cursor = self.node_cursor
  let mut open_nodes = self.open_nodes
  let mut trace_prompt_written = self.trace_prompt_written
  let mut trace_tools_key = self.trace_tools_key
  let mut trace_model_key = self.trace_model_key
  if state.prompt.seeded {
    if !trace_prompt_written {
      trace_lines.push(encode_prompt_init(state.prompt).stringify())
      trace_prompt_written = true
      trace_tools_key = tools_key_of(state.prompt.tools)
    } else {
      let key = tools_key_of(state.prompt.tools)
      if key != trace_tools_key {
        trace_lines.push(encode_tools_changed(state.prompt.tools).stringify())
        trace_tools_key = key
      }
    }
  }
  if state.model.seeded {
    let key = model_key_of_state(state.model)
    if key != trace_model_key {
      trace_lines.push(encode_model_init(state.model).stringify())
      trace_model_key = key
    }
  }
  // 新节点 → add；之前 add 过、现在闭合了 → close。
  for id in state.trace.order {
    match state.trace.nodes.get(id) {
      Some(node) => {
        let seq = @trace.node_seq(node.id)
        if seq > node_cursor {
          trace_lines.push(add_record(node, seq))
          if node.status == @trace.Pending || node.ended_at is None {
            open_nodes = open_nodes.add(id, true)
          }
          node_cursor = seq
        } else if open_nodes.contains(id) &&
          (node.status != @trace.Pending || node.ended_at is Some(_)) {
          trace_lines.push(close_record(node))
          open_nodes = open_nodes.remove(id)
        }
      }
      None => ()
    }
  }
  let next = {
    ..next,
    node_cursor,
    open_nodes,
    trace_prompt_written,
    trace_tools_key,
    trace_model_key,
  }
  if !trace_lines.is_empty() {
    append_file(self.trace_path, trace_lines)
  }
  (next, node_cursor)
}

///|
/// 现在的 Unix 毫秒（header 时间戳用）。落盘器不在环上，直接问系统时间。
fn now_unix_ms() -> Int64 {
  @sys.now()
}

///|
/// 追加写一个文件（按需建父目录）。
async fn append_file(path : String, lines : Array[String]) -> Unit raise SessionError {
  let directory = parent_dir(path)
  if !(@sys.exists(directory) catch { _ => false }) {
    @sys.mkdir_p(directory) catch {
      err => raise SessionError::Write(path~, message=err.to_string())
    }
  }
  let text = lines.join("\n") + "\n"
  @sys.write_text(path, text, append=true) catch {
    err => raise SessionError::Write(path~, message=err.to_string())
  }
}

///|
pub suberror SessionError {
  Write(path~ : String, message~ : String)
  /// 按 id 没找到会话文件（`--session <id>` 指向了一个不存在的会话）。
  NotFound(id~ : String)
}

///|
/// `Error` trait 对象的 `to_string` 走 `Show`：实现它让顶层错误处理打出来的是
/// 人话，而不是限定名。
impl Show for SessionError with fn output(self : SessionError, logger) {
  logger.write_string(self.to_string())
}

///|
pub fn SessionError::to_string(self : SessionError) -> String {
  match self {
    Write(path~, message~) => "无法写会话文件 " + path + "：" + message
    NotFound(id~) =>
      "没有找到会话 " + id + "（可用 /resume 打开会话面板看有哪些会话）"
  }
}

// ─── 回放 ────────────────────────────────────────────────────────────────────

///|
/// 读一个会话文件。文件不存在 / 空文件返回 None（当新会话）。
///
/// 坏行跳过：崩溃时最后一行可能是截断的 JSON。
fn replay_line(
  line : String,
  messages : Array[@message.Message],
  trace : Ref[@trace.TraceTree],
  prompt : Ref[@action.PromptInitData?],
  tools : Ref[Array[@action.PromptToolDefinition]?],
  model : Ref[@action.ModelSpec?],
  persisted_seq : Ref[Int32],
  saw_record : Ref[Bool],
  header_id : Ref[String?],
  header_cwd : Ref[String?],
) -> Unit {
  let line = line.trim()
  if line.is_empty() {
    return
  }
  let json = @json.parse(line) catch { _ => return }
  let obj = match json {
    Object(obj) => obj
    _ => return
  }
  saw_record.val = true
  // pi 形状的 header 行：记录 id / cwd，但不作为任何 op 处理。
  if field_string_or(obj, "type", "") == "session" {
    let id = field_string_or(obj, "id", "")
    if !id.is_empty() {
      header_id.val = Some(id)
    }
    let cwd = field_string_or(obj, "cwd", "")
    if !cwd.is_empty() {
      header_cwd.val = Some(cwd)
    }
  }
  match field_string_or(obj, "op", "") {
    "add" => {
      let seq = field_int(obj, "seq").unwrap_or(0)
      match decode_node(obj_field(obj, "node")) {
        Some(node) => {
          trace.val = @trace.restore_node(trace.val, node, seq)
          if seq > persisted_seq.val {
            persisted_seq.val = seq
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
        trace.val = @trace.patch_node(trace.val, id, status?, ended_at?)
      }
    }
    "message" =>
      match decode_message(obj_field(obj, "message")) {
        Some(message) => messages.push(message)
        None => ()
      }
    "prompt.init" => prompt.val = decode_prompt_init(json)
    "tools.changed" => tools.val = decode_tools_changed(json)
    "model.init" => model.val = decode_model_init(json)
    // 压缩记录：整份替换历史（之前的 message 记录作废）。
    "compact" =>
      match decode_compaction(json) {
        Some(replaced) => {
          messages.clear()
          for message in replaced {
            messages.push(message)
          }
        }
        None => ()
      }
    _ => ()
  }
}

pub async fn load_session(path : String, session_id : String) -> LoadedSession? {
  let exists = @sys.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  // 轨迹在同名兄弟文件里（sessions/--cwd--/X.jsonl <-> traces/--cwd--/X.jsonl）。
  // 旧格式（轨迹混在会话文件里）没有这个文件，读不到就当没有 —— 回放逻辑对
  // 两种布局都成立：先读轨迹（add/close/装载段），再读会话（header/消息）。
  let trace_path = path + ".trace"
  let text = @sys.read_text_lossy(path) catch { _ => return None }
  let messages : Array[@message.Message] = []
  let trace = @trace.create_trace_tree(session_id)
  let prompt : @action.PromptInitData? = None
  let tools : Array[@action.PromptToolDefinition]? = None
  let model : @action.ModelSpec? = None
  let persisted_seq : Int32 = 0
  let saw_record = false
  // header 行（pi 形状的 "type":"session"）里的 id / cwd。
  let header_id : String? = None
  let header_cwd : String? = None
  let trace_ref : Ref[@trace.TraceTree] = Ref(trace)
  let prompt_ref : Ref[@action.PromptInitData?] = Ref(prompt)
  let tools_ref : Ref[Array[@action.PromptToolDefinition]?] = Ref(tools)
  let model_ref : Ref[@action.ModelSpec?] = Ref(model)
  let seq_ref : Ref[Int32] = Ref(persisted_seq)
  let saw_ref : Ref[Bool] = Ref(saw_record)
  let hid_ref : Ref[String?] = Ref(header_id)
  let hcw_ref : Ref[String?] = Ref(header_cwd)
  let trace_exists = @sys.exists(trace_path) catch { _ => false }
  if trace_exists {
    let trace_text = @sys.read_text_lossy(trace_path) catch { _ => return None }
    for line in trace_text.split("\n") {
      replay_line(line.to_owned(), messages, trace_ref, prompt_ref, tools_ref, model_ref, seq_ref, saw_ref, hid_ref, hcw_ref)
    }
  }
  for line in text.split("\n") {
    replay_line(line.to_owned(), messages, trace_ref, prompt_ref, tools_ref, model_ref, seq_ref, saw_ref, hid_ref, hcw_ref)
  }
  if !saw_ref.val {
    return None
  }
  Some({
    messages,
    trace: @trace.recompute_tip(trace_ref.val),
    prompt: prompt_ref.val,
    tools: tools_ref.val,
    model: model_ref.val,
    persisted_seq: seq_ref.val,
    // pi 形状的 header（"type":"session"）与本项目旧的装载段都在文件头部：
    // 有 header 就用它的 id / cwd，没有（旧文件）回退调用方传进来的 id。
    session_id: match hid_ref.val {
      Some(id) => id
      None => session_id
    },
    cwd: hcw_ref.val.unwrap_or(""),
  })
}

///|
/// 目录里最新的一个会话文件（`--continue` 用）。
///
/// 文件名以毫秒时间戳开头，所以字典序 = 时间序。
pub async fn latest_session(directory : String) -> String? {
  let entries = @sys.readdir(directory) catch { _ => return None }
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
/// 工作目录 → 目录名（与 pi 的 `encodeCwd` 同一规则）：
/// `C:\Users\me\proj` → `--C-Users-me-proj--`。sessions/ 与 traces/ 共用。
pub fn encode_cwd(cwd : String) -> String {
  let mut text = cwd.replace_all(old="\\", new="/")
  if text.has_prefix("/") {
    text = text[1:].to_owned()
  }
  "--" +
  text.replace_all(old="/", new="-")
  .replace_all(old=":", new="-")
  .replace_all(old=" ", new="-") +
  "--"
}

///|
/// 毫秒时间戳 → ISO 文件名片段（与 pi 的 `fileTimestamp` 同一规则）：
/// `2026-10-25T05:42:16.901Z` → `2026-10-25T05-42-16-901Z`。
pub fn file_timestamp(ms : Int64) -> String {
  // 毫秒 → 各字段。用 Julian 日数算日期（不用月份天数表，闰年免了）。
  let days = ms / 86400000L
  let mut z = days + 719468L
  let era = z / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let year = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if month <= 2L { year + 1L } else { year }
  z = ms % 86400000L
  let hour = z / 3600000L
  let minute = z / 60000L % 60L
  let second = z / 1000L % 60L
  let millis = z % 1000L
  let pad2 = fn(value : Int64) -> String {
    if value < 10L { "0" + value.to_string() } else { value.to_string() }
  }
  let pad3 = fn(value : Int64) -> String {
    if value < 10L {
      "00" + value.to_string()
    } else if value < 100L {
      "0" + value.to_string()
    } else {
      value.to_string()
    }
  }
  year.to_string() +
  "-" +
  pad2(month) +
  "-" +
  pad2(day) +
  "T" +
  pad2(hour) +
  "-" +
  pad2(minute) +
  "-" +
  pad2(second) +
  "-" +
  pad3(millis) +
  "Z"
}

///|
/// 会话 / 轨迹文件名：`<ISO 时间戳>_<id>.jsonl`（与 pi 同一形状）。
pub fn session_file_name(session_id : String, ms : Int64) -> String {
  file_timestamp(ms) + "_" + session_id + ".jsonl"
}

///|
/// 从文件名取 id：`<时间戳>_<id>.jsonl` → id；裸 `<id>.jsonl` 也认。
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
  // `<时间戳>_<id>`：第一个下划线之后是 id（时间戳本身不含下划线）。
  match name.find("_") {
    Some(index) => name[index + 1:].to_owned()
    None => name
  }
}

///|
/// 在目录里按 id 找文件：`<任意时间戳>_<id>.jsonl`，多个候选取文件名最大的
/// （时间戳定长，字典序 = 时间序）。也认裸 `<id>.jsonl`（旧形状）。找不到返回 None。
pub async fn find_file_by_id(directory : String, id : String) -> String? {
  if id.is_empty() {
    return None
  }
  let suffix = "_" + id + ".jsonl"
  let entries = @sys.readdir(directory) catch {
    _ => return None
  }
  let mut best : String? = None
  for entry in entries {
    let hit = entry.has_suffix(suffix) || entry == id + ".jsonl"
    if hit {
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
  }
  match best {
    Some(name) => Some(directory + "/" + name)
    None => None
  }
}

///|
/// 新会话 id：时间有序的 UUIDv7（与 pi 同一形状，粘给 pi 的 `--session` 也能用）。
/// 上游没有现成的 uuid 包，这里用 `@random` 自己拼：48 位毫秒时间戳 + 版本 7 +
/// 变体位 + 随机数。
pub fn new_session_id(now_ms : Int64) -> String {
  let rand = @random.Rand::chacha8()
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < 16 {
    bytes.push((rand.int(limit=256).reinterpret_as_uint() & 0xFFU).to_byte())
    index = index + 1
  }
  // 前 6 字节 = 毫秒时间戳（大端）。
  let mut shift = 40
  let mut position = 0
  while shift >= 0 {
    bytes[position] = (((now_ms >> shift) & 0xFFL).to_int()).to_byte()
    position = position + 1
    shift = shift - 8
  }
  // 版本 7（高 4 位）。
  bytes[6] = ((bytes[6].to_int() & 0x0F) | 0x70).to_byte()
  // 变体 10xx。
  bytes[8] = ((bytes[8].to_int() & 0x3F) | 0x80).to_byte()
  let hex = fn(value : Int) -> String {
    let digits = "0123456789abcdef"
    match digits.get_char(value) {
      Some(character) => character.to_string()
      None => "0"
    }
  }
  let mut out = ""
  for at in 0..<16 {
    let value = bytes[at].to_int()
    if at == 4 || at == 6 || at == 8 || at == 10 {
      out = out + "-"
    }
    out = out + hex(value / 16) + hex(value % 16)
  }
  out
}

///|
/// sessions / traces 的目录布局（与 pi 同构）：
///
/// ```text
/// <agent dir>/
///   sessions/--<cwd 编码>--/<ISO 时间戳>_<id>.jsonl   会话：header + 消息
///   traces/--<cwd 编码>--/<ISO 时间戳>_<id>.jsonl     轨迹：装载段 + add/close + compact
/// ```
pub(all) struct SessionPaths {
  /// 会话文件。
  session : String
  /// 轨迹文件。
  trace : String
  /// 会话 id（两边文件名共用）。
  id : String
} derive(Debug)

///|
/// 新会话的两份文件路径。
pub fn new_session_paths(
  agent_dir : String,
  cwd : String,
  now_ms : Int64,
) -> SessionPaths {
  let id = new_session_id(now_ms)
  let encoded = encode_cwd(cwd)
  let name = session_file_name(id, now_ms)
  {
    session: agent_dir + "/sessions/" + encoded + "/" + name,
    trace: agent_dir + "/traces/" + encoded + "/" + name,
    id,
  }
}

///|
/// 已知 id（或路径）时找两份文件：先按 id 扫 cwd 对应目录，再退到其它 cwd 目录
/// 扫一遍（会话可能是在别的目录里建的）。都找不到时用 cwd 目录拼新形状。
pub async fn resolve_session_paths(
  agent_dir : String,
  cwd : String,
  id : String,
) -> SessionPaths raise SessionError {
  let encoded = encode_cwd(cwd)
  let sessions_root = agent_dir + "/sessions"
  let traces_root = agent_dir + "/traces"
  let session_file = match (find_file_by_id(sessions_root + "/" + encoded, id) catch { _ => None }) {
    Some(path) => Some(path)
    None => {
      // cwd 目录里没有：扫其它 --<cwd>-- 目录（找不到要出声，见 load 侧）。
      let entries = @sys.readdir(sessions_root) catch {
        _ => []
      }
      let mut hit : String? = None
      for directory in entries {
        if directory.has_prefix("--") && directory.has_suffix("--") {
          match (find_file_by_id(sessions_root + "/" + directory, id) catch { _ => None }) {
            Some(path) => {
              hit = Some(path)
              break
            }
            None => ()
          }
        }
      }
      hit
    }
  }
  match session_file {
    Some(path) => {
      let name = match path.rev_find("/") {
        Some(index) => path[index + 1:].to_owned()
        None => path
      }
      {
        session: path,
        trace: traces_root + "/" + encoded + "/" + name,
        id,
      }
    }
    None =>
      // 两处都没有：给个明确的错（调用方决定是报错还是当新会话）。
      // 但 `--session <路径>` 的用法不在这里拦 —— 调用方传的是路径时 id 会是
      // 文件名里的 id，找不到就报错是对的。
      raise SessionError::NotFound(id~)
  }
}

///|
/// 新会话文件路径（旧形状，`<dir>/<毫秒时间戳>.jsonl`）—— 只剩测试在用。
pub fn new_session_path(directory : String, timestamp : Int64) -> String {
  directory + "/" + timestamp.to_string() + ".jsonl"
}
