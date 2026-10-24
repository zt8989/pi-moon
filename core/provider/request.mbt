// 请求体：把内核的 state 翻译成 OpenAI 兼容的 `/chat/completions` JSON。
//
// 这是 faceoff 没有覆盖的那一半 —— 它的 `request_body` 只接受一个 prompt
// （system + user 两条消息），而 agent 需要完整的 messages 历史、工具定义与
// 思考参数。线格式仍是同一套：请求走 `Settings::chat_completions_url()`，
// SSE 用 `@faceoff.parse_sse_line` 解析。

///|
pub(all) struct ChatOptions {
  /// 显式 api key（`--api-key`），优先于配置文件。
  api_key : String?
  /// 显式思考级别（`--thinking`），优先于 settings.json。
  thinking_level : String?
  temperature : Double?
  max_tokens : Int32?
  /// 空闲超时：流上这么久没有一行数据就掐（毫秒）。
  idle_timeout_ms : Int32
} derive(Eq, Debug)

///|
pub fn ChatOptions::defaults() -> ChatOptions {
  {
    api_key: None,
    thinking_level: None,
    temperature: None,
    max_tokens: None,
    idle_timeout_ms: 120000,
  }
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
fn jstr(text : String) -> Json {
  Json::string(text)
}

///|
fn json_bool(value : Bool) -> Json {
  Json::boolean(value)
}

///|
fn jnum(value : Double) -> Json {
  Json::number(value)
}

///|
/// 文本块拼起来：user / assistant 的 content 在 OpenAI 线格式里可以是一整段字符串。
fn join_text_blocks(blocks : Array[@message.Content]) -> String {
  let builder = StringBuilder()
  for block in blocks {
    match block {
      @message.Text(text) => builder.write_string(text)
      _ => ()
    }
  }
  builder.to_string()
}

///|
fn join_thinking_blocks(blocks : Array[@message.Content]) -> String {
  let builder = StringBuilder()
  for block in blocks {
    match block {
      @message.Thinking(text) => builder.write_string(text)
      _ => ()
    }
  }
  builder.to_string()
}

///|
fn has_image_block(blocks : Array[@message.Content]) -> Bool {
  for block in blocks {
    match block {
      @message.Image(_) => return true
      _ => ()
    }
  }
  false
}

///|
fn content_parts_json(blocks : Array[@message.Content]) -> Json {
  let parts : Array[Json] = []
  for block in blocks {
    match block {
      @message.Text(text) =>
        parts.push(jobj([("type", jstr("text")), ("text", jstr(text))]))
      @message.Image(url) =>
        parts.push(
          jobj([
            ("type", jstr("image_url")),
            ("image_url", jobj([("url", jstr(url))])),
          ]),
        )
      _ => ()
    }
  }
  Json::array(parts)
}

///|
fn user_json(part : @message.UserPart) -> Json {
  let content = if has_image_block(part.content) {
    content_parts_json(part.content)
  } else {
    jstr(join_text_blocks(part.content))
  }
  jobj([("role", jstr("user")), ("content", content)])
}

///|
/// assistant 历史：文本 + （需要时）reasoning_content + tool_calls。
fn assistant_json(part : @message.AssistantPart, compat : ModelCompat) -> Json {
  let text = join_text_blocks(part.content)
  let reasoning = join_thinking_blocks(part.content)
  let calls = part.tool_calls()
  let entries : Array[(String, Json)] = [
    ("role", jstr("assistant")),
    ("content", jstr(text)),
  ]
  if compat.requires_reasoning_content && !reasoning.is_empty() {
    entries.push(("reasoning_content", jstr(reasoning)))
  }
  if !calls.is_empty() {
    let calls_json : Array[Json] = []
    for call in calls {
      let arguments = if call.arguments.is_empty() {
        "{}"
      } else {
        call.arguments
      }
      calls_json.push(
        jobj([
          ("id", jstr(call.id)),
          ("type", jstr("function")),
          (
            "function",
            jobj([("name", jstr(call.name)), ("arguments", jstr(arguments))]),
          ),
        ]),
      )
    }
    entries.push(("tool_calls", Json::array(calls_json)))
  }
  jobj(entries)
}

///|
fn tool_json(part : @message.ToolResultPart, compat : ModelCompat) -> Json {
  let text = @message.contents_text(part.content)
  let entries : Array[(String, Json)] = [
    ("role", jstr("tool")),
    ("tool_call_id", jstr(part.tool_call_id)),
    ("content", jstr(text)),
  ]
  if compat.requires_tool_result_name {
    entries.push(("name", jstr(part.tool_name)))
  }
  jobj(entries)
}

///|
fn system_json(part : @message.SystemPart, compat : ModelCompat) -> Json {
  // 只有 compat 明确支持时才用 developer；否则 system 是各家的最大公约数。
  let role = if compat.supports_developer_role && part.role == "developer" {
    "developer"
  } else {
    "system"
  }
  jobj([("role", jstr(role)), ("content", jstr(part.content))])
}

///|
fn message_json(message : @message.Message, compat : ModelCompat) -> Json {
  match message {
    @message.UserMsg(part) => user_json(part)
    @message.AssistantMsg(part) => assistant_json(part, compat)
    @message.ToolResultMsg(part) => tool_json(part, compat)
    @message.SystemMsg(part) => system_json(part, compat)
  }
}

///|
fn messages_json(
  state : @state.AgentState,
  compat : ModelCompat,
) -> Array[Json] {
  let out : Array[Json] = []
  // 基础 system prompt 在 state 里是单独一块（不在 messages 里），要显式放最前面。
  if !state.prompt.system_prompt.is_empty() {
    out.push(
      jobj([
        ("role", jstr("system")),
        ("content", jstr(state.prompt.system_prompt)),
      ]),
    )
  }
  for message in state.messages {
    out.push(message_json(message, compat))
  }
  out
}

///|
fn tool_parameters(tool : @action.PromptToolDefinition) -> Json {
  if tool.parameters.is_empty() {
    return Json::object(Map([]))
  }
  @json.parse(tool.parameters) catch {
    _ => Json::object(Map([]))
  }
}

///|
fn tools_json(tools : Array[@action.PromptToolDefinition]) -> Array[Json] {
  let out : Array[Json] = []
  for tool in tools {
    out.push(
      jobj([
        ("type", jstr("function")),
        (
          "function",
          jobj([
            ("name", jstr(tool.name)),
            ("description", jstr(tool.description)),
            ("parameters", tool_parameters(tool)),
          ]),
        ),
      ]),
    )
  }
  out
}

///|
fn history_has_tool_calls(messages : Array[@message.Message]) -> Bool {
  for message in messages {
    match message {
      @message.AssistantMsg(part) =>
        if !part.tool_calls().is_empty() {
          return true
        }
      @message.ToolResultMsg(_) => return true
      _ => ()
    }
  }
  false
}

///|
/// 思考级别的映射结果：显式 `null`（不支持这一档）与「没有映射，按原级别发」是
/// 两件事，不能压成一个 `String?`。
priv enum LevelParam {
  LevelDisabled
  LevelValue(String)
}

///|
fn level_param(model : PiModelInfo, level : String) -> LevelParam {
  match model.thinking_level_map.get(level) {
    Some(Some(value)) => LevelValue(value)
    Some(None) => LevelDisabled
    None => LevelValue(level)
  }
}

///|
fn apply_thinking(
  body : Map[String, Json],
  resolved : ResolvedProvider,
  options : ChatOptions,
) -> Unit {
  let model = resolved.model
  if !model.reasoning {
    return
  }
  let level = match options.thinking_level {
    Some(level) => level
    None => resolved.thinking_level
  }
  let enabled = level != "off"
  let format = model.compat.thinking_format
  let supports_effort = model.compat.supports_reasoning_effort
  let param = if enabled {
    level_param(model, level)
  } else {
    level_param(model, "off")
  }
  match param {
    LevelDisabled =>
      // 这一档明确是 null：不要把「不支持」伪装成「关掉」。
      ()
    LevelValue(value) =>
      match format {
        "deepseek" | "zai" => {
          body["thinking"] = jobj([
            ("type", jstr(if enabled { "enabled" } else { "disabled" })),
          ])
          if enabled && supports_effort {
            body["reasoning_effort"] = jstr(value)
          }
        }
        "qwen" => {
          body["enable_thinking"] = json_bool(enabled)
          if enabled && supports_effort {
            body["reasoning_effort"] = jstr(value)
          }
        }
        "openrouter" =>
          body["reasoning"] = jobj([
            ("effort", jstr(if enabled { value } else { "none" })),
          ])
        "together" => {
          body["reasoning"] = jobj([("enabled", json_bool(enabled))])
          if enabled && supports_effort {
            body["reasoning_effort"] = jstr(value)
          }
        }
        "string-thinking" => if enabled { body["thinking"] = jstr(value) }
        _ =>
          if supports_effort {
            if enabled {
              body["reasoning_effort"] = jstr(value)
            } else if value != "off" {
              body["reasoning_effort"] = jstr(value)
            }
          }
      }
  }
}

///|
/// 组一次 `/chat/completions` 请求体。
pub fn build_request_body(
  resolved : ResolvedProvider,
  state : @state.AgentState,
  options : ChatOptions,
  stream : Bool,
) -> Json {
  let compat = resolved.model.compat
  let body : Map[String, Json] = Map([])
  body["model"] = jstr(resolved.model.id)
  body["messages"] = Json::array(messages_json(state, compat))
  body["stream"] = json_bool(stream)
  if stream && compat.supports_usage_in_streaming {
    body["stream_options"] = jobj([("include_usage", json_bool(true))])
  }
  let max_tokens = match options.max_tokens {
    Some(max) => Some(max)
    None => resolved.model.max_tokens
  }
  match max_tokens {
    Some(max) => body[compat.max_tokens_field] = jnum(max.to_double())
    None => ()
  }
  match options.temperature {
    Some(temperature) => body["temperature"] = jnum(temperature)
    None => ()
  }
  let tools = tools_json(state.prompt.tools)
  if tools.is_empty() {
    // 历史里有 tool_calls / toolResult 时，有些网关（经 LiteLLM 代理的 Anthropic）
    // 要求 tools 字段存在，哪怕是空数组。
    if history_has_tool_calls(state.messages) {
      body["tools"] = Json::array([])
    }
  } else {
    body["tools"] = Json::array(tools)
  }
  apply_thinking(body, resolved, options)
  Json::object(body)
}

///|
/// 摘要请求体：**没有工具**，system prompt 是摘要助手那句，用户消息是拍平后的对话。
///
/// 与普通请求共用 `message_json` 的线格式（工具结果 / 思考块照样按同一条规则翻），
/// 但不发工具定义，也不发思考参数：摘要要的是确定性输出，不是再思考一遍。
pub fn build_summary_request_body(
  resolved : ResolvedProvider,
  system_prompt : String,
  messages : Array[@message.Message],
  max_tokens : Int32,
) -> Json {
  let compat = resolved.model.compat
  let body : Map[String, Json] = Map([])
  body["model"] = jstr(resolved.model.id)
  let out : Array[Json] = [
    jobj([("role", jstr("system")), ("content", jstr(system_prompt))]),
  ]
  for message in messages {
    out.push(message_json(message, compat))
  }
  body["messages"] = Json::array(out)
  body["stream"] = json_bool(true)
  if compat.supports_usage_in_streaming {
    body["stream_options"] = jobj([("include_usage", json_bool(true))])
  }
  body[compat.max_tokens_field] = jnum(max_tokens.to_double())
  // 历史里有 tool_calls / toolResult 时，有些网关要求 tools 字段存在，哪怕是空数组。
  if history_has_tool_calls(messages) {
    body["tools"] = Json::array([])
  }
  Json::object(body)
}

///|
/// 请求体字符串（调试 / 测试用）。
pub fn request_body_text(
  resolved : ResolvedProvider,
  state : @state.AgentState,
  options : ChatOptions,
) -> String {
  build_request_body(resolved, state, options, true).stringify()
}
