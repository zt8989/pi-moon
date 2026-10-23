// 会话 JSONL 的编解码。
//
// 一行一个记录（`op` 区分）：
//   - `prompt.init` / `model.init`  装载段，各一条（最后一次出现的那条生效）
//   - `add`                        轨迹节点首次出现（带 seq 与完整字段）
//   - `close`                      节点闭合补丁（id / status / ended_at）
//   - `message`                    一条对话消息（回放 messages，零 token）
//
// 轨迹用 add + close 而不是每次都写整棵树：长会话里只有新节点和「刚闭合」的
// 节点会产生新行，文件不会二次膨胀。坏行（崩溃时截断的半行）在回放时跳过。

///|
fn jstr(value : String) -> Json {
  Json::string(value)
}

///|
fn jbool(value : Bool) -> Json {
  Json::boolean(value)
}

///|
fn jint(value : Int32) -> Json {
  Json::number(value.to_double())
}

///|
fn jint64(value : Int64) -> Json {
  Json::number(value.to_double())
}

///|
fn jobj(entries : Array[(String, Json)]) -> Json {
  let map : Map[String, Json] = Map([])
  for pair in entries {
    let (key, value) = pair
    map[key] = value
  }
  Json::object(map)
}

///|
fn jarr(items : Array[Json]) -> Json {
  Json::array(items)
}

///|
fn optional_string(value : String?) -> Json {
  match value {
    Some(text) => jstr(text)
    None => Json::null()
  }
}

///|
fn obj_field(obj : Map[String, Json], key : String) -> Json {
  match obj.get(key) {
    Some(value) => value
    None => Json::null()
  }
}

///|
fn field_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn field_string_or(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match field_string(obj, key) {
    Some(text) => text
    None => fallback
  }
}

///|
fn field_object(obj : Map[String, Json], key : String) -> Map[String, Json]? {
  match obj.get(key) {
    Some(Object(value)) => Some(value)
    _ => None
  }
}

///|
fn field_array(obj : Map[String, Json], key : String) -> Array[Json]? {
  match obj.get(key) {
    Some(Array(items)) => Some(items)
    _ => None
  }
}

///|
fn field_int(obj : Map[String, Json], key : String) -> Int32? {
  match obj.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn field_int64(obj : Map[String, Json], key : String) -> Int64? {
  match obj.get(key) {
    Some(Number(value, ..)) => Some(value.to_int64())
    _ => None
  }
}

///|
fn field_bool(obj : Map[String, Json], key : String) -> Bool? {
  match obj.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

// ─── 消息 ────────────────────────────────────────────────────────────────────

///|
fn encode_content(content : @message.Content) -> Json {
  match content {
    @message.Text(text) => jobj([("type", jstr("text")), ("text", jstr(text))])
    @message.Thinking(text) =>
      jobj([("type", jstr("thinking")), ("text", jstr(text))])
    @message.ToolCallBlock(call) =>
      jobj([
        ("type", jstr("tool_call")),
        ("id", jstr(call.id)),
        ("name", jstr(call.name)),
        ("arguments", jstr(call.arguments)),
      ])
    @message.Image(url) => jobj([("type", jstr("image")), ("url", jstr(url))])
  }
}

///|
fn decode_content(json : Json) -> @message.Content? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  let kind = field_string_or(obj, "type", "")
  match kind {
    "text" => Some(@message.Text(field_string_or(obj, "text", "")))
    "thinking" => Some(@message.Thinking(field_string_or(obj, "text", "")))
    "tool_call" =>
      Some(
        @message.ToolCallBlock({
          id: field_string_or(obj, "id", ""),
          name: field_string_or(obj, "name", ""),
          arguments: field_string_or(obj, "arguments", ""),
        }),
      )
    "image" => Some(@message.Image(field_string_or(obj, "url", "")))
    _ => None
  }
}

///|
fn encode_contents(contents : Array[@message.Content]) -> Json {
  let items : Array[Json] = []
  for content in contents {
    items.push(encode_content(content))
  }
  jarr(items)
}

///|
fn decode_contents(
  obj : Map[String, Json],
  key : String,
) -> Array[@message.Content] {
  let out : Array[@message.Content] = []
  match field_array(obj, key) {
    Some(items) =>
      for item in items {
        match decode_content(item) {
          Some(content) => out.push(content)
          None => ()
        }
      }
    None => ()
  }
  out
}

///|
fn encode_usage(usage : @message.Usage?) -> Json {
  match usage {
    Some(usage) =>
      jobj([
        ("input_tokens", jint(usage.input_tokens)),
        ("output_tokens", jint(usage.output_tokens)),
        ("total_tokens", jint(usage.total_tokens)),
        ("cost_total", Json::number(usage.cost_total)),
      ])
    None => Json::null()
  }
}

///|
fn decode_usage(json : Json) -> @message.Usage? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  Some({
    input_tokens: field_int(obj, "input_tokens").unwrap_or(0),
    output_tokens: field_int(obj, "output_tokens").unwrap_or(0),
    total_tokens: field_int(obj, "total_tokens").unwrap_or(0),
    cost_total: match obj.get("cost_total") {
      Some(Number(value, ..)) => value
      _ => 0.0
    },
  })
}

///|
/// 一条消息 → JSON。`role` 与 `Message::role()` 同一套拼写。
pub fn encode_message(message : @message.Message) -> Json {
  match message {
    @message.UserMsg(part) =>
      jobj([
        ("role", jstr("user")),
        ("content", encode_contents(part.content)),
        ("timestamp", jint64(part.timestamp)),
      ])
    @message.AssistantMsg(part) =>
      jobj([
        ("role", jstr("assistant")),
        ("content", encode_contents(part.content)),
        ("stop_reason", jstr(part.stop_reason)),
        ("error_message", optional_string(part.error_message)),
        ("usage", encode_usage(part.usage)),
        ("timestamp", jint64(part.timestamp)),
      ])
    @message.ToolResultMsg(part) =>
      jobj([
        ("role", jstr("toolResult")),
        ("tool_call_id", jstr(part.tool_call_id)),
        ("tool_name", jstr(part.tool_name)),
        ("content", encode_contents(part.content)),
        ("is_error", jbool(part.is_error)),
        ("timestamp", jint64(part.timestamp)),
      ])
    @message.SystemMsg(part) => {
      let sections : Array[Json] = []
      for section in part.sections {
        let (key, value) = section
        sections.push(jarr([jstr(key), jstr(value)]))
      }
      jobj([
        ("role", jstr(part.role)),
        ("content", jstr(part.content)),
        ("sections", jarr(sections)),
        ("source", optional_string(part.source)),
        ("timestamp", jint64(part.timestamp)),
      ])
    }
  }
}

///|
/// JSON → 一条消息。`role` 不认识时返回 None（坏行跳过）。
pub fn decode_message(json : Json) -> @message.Message? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  let timestamp = field_int64(obj, "timestamp").unwrap_or(0L)
  match field_string_or(obj, "role", "") {
    "user" =>
      Some(
        @message.UserMsg({
          content: decode_contents(obj, "content"),
          timestamp,
        }),
      )
    "assistant" =>
      Some(
        @message.AssistantMsg({
          content: decode_contents(obj, "content"),
          stop_reason: field_string_or(obj, "stop_reason", ""),
          error_message: field_string(obj, "error_message"),
          usage: decode_usage(obj_field(obj, "usage")),
          timestamp,
        }),
      )
    "toolResult" =>
      Some(
        @message.ToolResultMsg({
          tool_call_id: field_string_or(obj, "tool_call_id", ""),
          tool_name: field_string_or(obj, "tool_name", ""),
          content: decode_contents(obj, "content"),
          is_error: field_bool(obj, "is_error").unwrap_or(false),
          timestamp,
        }),
      )
    "system" | "developer" => {
      let sections : Array[(String, String)] = []
      match field_array(obj, "sections") {
        Some(items) =>
          for item in items {
            match item {
              Array(pair) =>
                if pair.length() >= 2 {
                  match (pair[0], pair[1]) {
                    (String(key), String(value)) => sections.push((key, value))
                    _ => ()
                  }
                }
              _ => ()
            }
          }
        None => ()
      }
      Some(
        @message.SystemMsg({
          role: field_string_or(obj, "role", "system"),
          content: field_string_or(obj, "content", ""),
          sections,
          source: field_string(obj, "source"),
          timestamp,
        }),
      )
    }
    _ => None
  }
}

// ─── 轨迹节点 ────────────────────────────────────────────────────────────────

///|
fn encode_meta(meta : Array[(String, String)]) -> Json {
  let items : Array[Json] = []
  for entry in meta {
    let (key, value) = entry
    items.push(jarr([jstr(key), jstr(value)]))
  }
  jarr(items)
}

///|
fn decode_meta(obj : Map[String, Json]) -> Array[(String, String)] {
  let meta : Array[(String, String)] = []
  match field_array(obj, "meta") {
    Some(items) =>
      for item in items {
        match item {
          Array(pair) =>
            if pair.length() >= 2 {
              match (pair[0], pair[1]) {
                (String(key), String(value)) => meta.push((key, value))
                _ => ()
              }
            }
          _ => ()
        }
      }
    None => ()
  }
  meta
}

///|
/// 一个轨迹节点的**完整**字段（`add` 记录用）。
pub fn encode_node(node : @trace.TraceNode) -> Json {
  let message = match node.message {
    Some(message) => encode_message(message)
    None => Json::null()
  }
  let ended_at = match node.ended_at {
    Some(value) => jint64(value)
    None => Json::null()
  }
  let parent_id = match node.parent_id {
    Some(value) => jstr(value)
    None => Json::null()
  }
  let detail = optional_string(node.detail)
  jobj([
    ("id", jstr(node.id)),
    ("parent_id", parent_id),
    ("kind", jstr(node.kind.name())),
    ("status", jstr(node.status.name())),
    ("label", jstr(node.label)),
    ("detail", detail),
    ("meta", encode_meta(node.meta)),
    ("message", message),
    ("created_at", jint64(node.created_at)),
    ("ended_at", ended_at),
  ])
}

///|
/// JSON → 轨迹节点。`seq` 来自 `add` 记录（不是节点字段），只用于推 `next_seq`。
pub fn decode_node(json : Json) -> @trace.TraceNode? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  let kind = match
    @trace.TraceNodeKind::from_name(field_string_or(obj, "kind", "")) {
    Some(kind) => kind
    None => return None
  }
  let status = match
    @trace.TraceNodeStatus::from_name(field_string_or(obj, "status", "")) {
    Some(status) => status
    None => return None
  }
  let message = match obj_field(obj, "message") {
    Object(_) => decode_message(obj_field(obj, "message"))
    _ => None
  }
  let id = field_string_or(obj, "id", "")
  if id.is_empty() {
    return None
  }
  Some({
    id,
    parent_id: field_string(obj, "parent_id"),
    kind,
    status,
    label: field_string_or(obj, "label", ""),
    detail: field_string(obj, "detail"),
    meta: decode_meta(obj),
    message,
    created_at: field_int64(obj, "created_at").unwrap_or(0L),
    ended_at: field_int64(obj, "ended_at"),
  })
}

// ─── 装载段 ──────────────────────────────────────────────────────────────────

///|
fn encode_tools(tools : Array[@action.PromptToolDefinition]) -> Json {
  let items : Array[Json] = []
  for tool in tools {
    items.push(
      jobj([
        ("name", jstr(tool.name)),
        ("description", jstr(tool.description)),
        ("parameters", jstr(tool.parameters)),
      ]),
    )
  }
  jarr(items)
}

///|
fn decode_tools(obj : Map[String, Json]) -> Array[@action.PromptToolDefinition] {
  let tools : Array[@action.PromptToolDefinition] = []
  match field_array(obj, "tools") {
    Some(items) =>
      for item in items {
        match item {
          Object(tool) => {
            // `parameters` 正常是 JSON 文本；旧文件可能存成对象，兼容一下。
            let parameters = match tool.get("parameters") {
              Some(String(text)) => text
              Some(Object(_)) => obj_field(tool, "parameters").stringify()
              _ => ""
            }
            tools.push({
              name: field_string_or(tool, "name", ""),
              description: field_string_or(tool, "description", ""),
              parameters,
            })
          }
          _ => ()
        }
      }
    None => ()
  }
  tools
}

///|
/// prompt 装载记录。
pub fn encode_prompt_init(prompt : @state.PromptState) -> Json {
  jobj([
    ("op", jstr("prompt.init")),
    ("system_prompt", jstr(prompt.system_prompt)),
    ("tools", encode_tools(prompt.tools)),
  ])
}

///|
pub fn decode_prompt_init(json : Json) -> @action.PromptInitData? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  if field_string_or(obj, "op", "") != "prompt.init" {
    return None
  }
  Some({
    system_prompt: field_string_or(obj, "system_prompt", ""),
    tools: decode_tools(obj),
  })
}

///|
fn encode_capabilities(capabilities : @action.ModelCapabilities) -> Json {
  jobj([
    ("mid_convo_system_messages", jbool(capabilities.mid_convo_system_messages)),
    ("mid_convo_tool_additions", jbool(capabilities.mid_convo_tool_additions)),
    ("developer_role", jbool(capabilities.developer_role)),
  ])
}

///|
fn decode_capabilities(obj : Map[String, Json]) -> @action.ModelCapabilities {
  {
    mid_convo_system_messages: field_bool(obj, "mid_convo_system_messages").unwrap_or(
      false,
    ),
    mid_convo_tool_additions: field_bool(obj, "mid_convo_tool_additions").unwrap_or(
      false,
    ),
    developer_role: field_bool(obj, "developer_role").unwrap_or(false),
  }
}

///|
/// model 装载记录。
pub fn encode_model_init(model : @state.ModelState) -> Json {
  jobj([
    ("op", jstr("model.init")),
    ("provider", jstr(model.provider)),
    ("model_id", jstr(model.model_id)),
    ("thinking_level", jstr(model.thinking_level)),
    ("reasoning", jbool(model.reasoning)),
    ("capabilities", encode_capabilities(model.capabilities)),
    ("context_window", jint(model.context_window)),
  ])
}

///|
pub fn decode_model_init(json : Json) -> @action.ModelSpec? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  if field_string_or(obj, "op", "") != "model.init" {
    return None
  }
  let capabilities = match field_object(obj, "capabilities") {
    Some(capabilities) => decode_capabilities(capabilities)
    None => @action.no_capabilities
  }
  Some({
    provider: field_string_or(obj, "provider", ""),
    model_id: field_string_or(obj, "model_id", ""),
    thinking_level: field_string_or(obj, "thinking_level", "off"),
    reasoning: field_bool(obj, "reasoning").unwrap_or(false),
    capabilities,
    context_window: field_int(obj, "context_window").unwrap_or(0),
  })
}
