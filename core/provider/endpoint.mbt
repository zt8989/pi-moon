// 端点设置与 SSE 解析 —— 照 conglinyizhi/moonbit-llm-faceoff@0.2.0（MIT）里
// 那一小块纯逻辑搬进来的本地副本。
//
// 为什么不再直接依赖它：faceoff 的 `moon.pkg` 写的是 `supported_targets =
// "+native"`，只要它出现在 import 表里，js 目标连构建计划都排不出来。本项目
// 用到的只有 `Settings`（URL 拼接）、`TokenUsage` 和 `parse_sse_line`，都是纯
// 字符串 / JSON 逻辑，没有任何 IO —— 搬进来既能两端同码，也免得多一层 native
// 依赖。上游行为（字段容错、reasoning 与 content 的优先级）保持原样。

///|
/// OpenAI 兼容端点的连接与生成设置。
pub(all) struct Settings {
  /// Bearer token。空串表示不发 `Authorization`。
  mut api_key : String
  /// API base URL，不带尾斜杠。
  mut base_url : String
  /// 请求体里的 model id。
  mut model : String
  /// 每条请求前拼上去的 system prompt。
  mut system : String
  /// 采样温度，未设置就不发。
  mut temperature : Double?
  /// 生成上限，未设置就不发。
  mut max_tokens : Int?
  /// 单次请求超时（毫秒）。
  mut timeout_ms : Int
  /// 推理开关：勾上就往请求体里带 enable_thinking: true。
  mut enable_thinking : Bool
  /// 另一种风格：reasoning_effort。None 表示不发。
  mut reasoning_effort : String?
} derive(Eq)

///|
/// `chat/completions` 的完整 URL。
pub fn Settings::chat_completions_url(self : Settings) -> String {
  if self.base_url.has_suffix("/") {
    self.base_url + "chat/completions"
  } else {
    self.base_url + "/chat/completions"
  }
}

///|
/// `usage` 块里的 token 账目。推理模型单独报 `reasoning_tokens`，此时
/// completion 是「思考 + 回答」的总和。
pub(all) struct TokenUsage {
  prompt_tokens : Int
  completion_tokens : Int
  reasoning_tokens : Int
} derive(Eq, Debug)

///|
pub fn TokenUsage::new(
  prompt_tokens : Int,
  completion_tokens : Int,
  reasoning_tokens : Int,
) -> TokenUsage {
  { prompt_tokens, completion_tokens, reasoning_tokens, }
}

///|
/// 思考占生成预算的比例，落在 `[0, 1]`。没报 completion 时算 0。
pub fn TokenUsage::reasoning_ratio(self : TokenUsage) -> Double {
  if self.completion_tokens == 0 {
    0.0
  } else {
    self.reasoning_tokens.to_double() / self.completion_tokens.to_double()
  }
}

///|
/// 一条有意义的 SSE 行。
pub(all) enum SseEvent {
  /// 可见回答的增量。
  Content(String)
  /// 思考过程的增量。
  Reasoning(String)
  /// 最后的 `usage` 块（chunk 的 `choices` 为空）。
  Usage(TokenUsage)
  /// 停止原因（`stop` / `length` / `tool_calls` ...）。
  Finish(String)
  /// `[DONE]` 哨兵。
  Done
  /// 看懂了但不需要追踪的行（只有 role 的片、工具调用增量、注释 ...）。
  Ignore
} derive(Eq, Debug)

///|
/// 解析一行。`None` 表示「跳过」：空行、注释、或不是 `data:` 的字段。
pub fn parse_sse_line(line : String) -> SseEvent? {
  let text = line.trim(chars=" \t\r\n")
  if text.length() == 0 || text.has_prefix(":") {
    return None
  }
  if !text.has_prefix("data:") {
    return Some(Ignore)
  }
  let payload = text[5:].trim(chars=" \t\r\n").to_owned()
  if payload == "[DONE]" {
    return Some(Done)
  }
  let parsed = @json.parse(payload) catch { _ => return Some(Ignore) }
  Some(parse_stream_chunk(parsed))
}

///|
/// 一个 chunk 里可见回答优先于思考：两者同时出现时，回答才是要计时的那个。
fn parse_stream_chunk(json : Json) -> SseEvent {
  let object = match json {
    Object(object) => object
    _ => return Ignore
  }
  let choices = match object.get("choices") {
    Some(Array(choices)) => choices
    _ => []
  }
  if choices.length() > 0 {
    return parse_choice(choices)
  }
  match object.get("usage") {
    Some(Object(usage)) => Usage(parse_usage(usage))
    _ => Ignore
  }
}

///|
fn parse_choice(choices : Array[Json]) -> SseEvent {
  let choice = match choices {
    [Object(choice), ..] => choice
    _ => return Ignore
  }
  let delta = match choice.get("delta") {
    Some(Object(delta)) => delta
    _ => return Ignore
  }
  match non_empty_string(delta.get("content")) {
    Some(text) => return Content(text)
    None => ()
  }
  match non_empty_string(delta.get("reasoning_content")) {
    Some(text) => return Reasoning(text)
    None => ()
  }
  match non_empty_string(choice.get("finish_reason")) {
    Some(reason) => Finish(reason)
    None => Ignore
  }
}

///|
fn parse_usage(usage : Map[String, Json]) -> TokenUsage {
  {
    prompt_tokens: int_field(usage, "prompt_tokens"),
    completion_tokens: int_field(usage, "completion_tokens"),
    reasoning_tokens: int_field(usage, "reasoning_tokens"),
  }
}

///|
/// 字符串字段：null 与 `""` 都算没有。
fn non_empty_string(value : Json?) -> String? {
  match value {
    Some(String(text)) => if text.length() == 0 { None } else { Some(text) }
    _ => None
  }
}

///|
fn int_field(object : Map[String, Json], key : String) -> Int {
  match object.get(key) {
    Some(Number(number, ..)) => number.to_int()
    _ => 0
  }
}
