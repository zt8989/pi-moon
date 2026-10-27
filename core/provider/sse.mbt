// SSE 流的水位线：把一行行事件累积成一条 assistant 消息。
//
// 这一层是**纯的**（除了 StringBuilder 之外没有 IO），所以能用固定样例断言：
// 文本增量、思考增量、工具调用的分片参数、usage、finish_reason、[DONE]。
//
// 简单的事件（文本 / 思考 / usage / finish / done）直接交给
// `parse_sse_line` —— SSE 协议与各家字段的容忍度由库负责；本文件只额外
// 处理它刻意忽略的 `delta.tool_calls`。

///|
pub(all) enum StreamDelta {
  DeltaNone
  DeltaContent(String)
  DeltaReasoning(String)
} derive(Eq, Debug)

///|
/// 一个正在拼装的工具调用。OpenAI 的流式 tool_calls 是按 `index` 分片的：
/// 第一片带 id/name，后面的片只带 arguments 的增量。
pub(all) struct ToolCallDraft {
  index : Int32
  mut id : String
  mut name : String
  mut arguments : String
}

///|
pub(all) struct StreamAccumulator {
  content : StringBuilder
  reasoning : StringBuilder
  drafts : Array[ToolCallDraft]
  mut usage : TokenUsage?
  mut finish_reason : String?
  mut done : Bool
}

///|
pub fn StreamAccumulator::new() -> StreamAccumulator {
  {
    content: StringBuilder(),
    reasoning: StringBuilder(),
    drafts: [],
    usage: None,
    finish_reason: None,
    done: false,
  }
}

///|
fn StreamAccumulator::draft_at(
  self : StreamAccumulator,
  index : Int32,
) -> ToolCallDraft {
  while self.drafts.length() <= index {
    self.drafts.push({
      index: self.drafts.length(),
      id: "",
      name: "",
      arguments: "",
    })
  }
  self.drafts[index]
}

///|
fn trim_line(line : String) -> String {
  line.trim(chars=" \t\r\n").to_owned()
}

///|
/// 从一行里取 `data:` 之后的部分；不是 data 行返回 None。
fn sse_payload(line : String) -> String? {
  let text = trim_line(line)
  if !text.has_prefix("data:") {
    return None
  }
  Some(trim_line(text[5:].to_owned()))
}

///|
/// `delta.tool_calls` 的增量。库把它归进 `Ignore`，这里补上。
fn StreamAccumulator::apply_tool_deltas(
  self : StreamAccumulator,
  line : String,
) -> Unit {
  let payload = match sse_payload(line) {
    Some(payload) => payload
    None => return
  }
  if payload == "[DONE]" || payload.is_empty() {
    return
  }
  let json = @json.parse(payload) catch { _ => return }
  let obj = match json {
    Object(obj) => obj
    _ => return
  }
  let choices = match obj.get("choices") {
    Some(Array(choices)) => choices
    _ => return
  }
  let choice = match choices {
    [Object(choice), ..] => choice
    _ => return
  }
  let delta = match choice.get("delta") {
    Some(Object(delta)) => delta
    _ => return
  }
  let calls = match delta.get("tool_calls") {
    Some(Array(calls)) => calls
    _ => return
  }
  for item in calls {
    match item {
      Object(call) => {
        let index = match jint(call.get("index")) {
          Some(index) => index
          None => 0
        }
        let draft = self.draft_at(index)
        match jstring(call.get("id")) {
          Some(id) => if !id.is_empty() { draft.id = id }
          None => ()
        }
        match jobject(call.get("function")) {
          Some(function) => {
            match jstring(function.get("name")) {
              Some(name) => draft.name = draft.name + name
              None => ()
            }
            match jstring(function.get("arguments")) {
              Some(arguments) => draft.arguments = draft.arguments + arguments
              None => ()
            }
          }
          None => ()
        }
      }
      _ => ()
    }
  }
}

///|
/// `usage` 有时搭在**带 choices 的最后一个 chunk** 上（DeepSeek / 一些网关），
/// 而 `parse_sse_line` 的 choice 分支只认 content / reasoning / finish_reason，
/// 会把这种块归成 `Ignore`。这里补一刀，两种位置都能拿到。
fn StreamAccumulator::apply_usage(
  self : StreamAccumulator,
  line : String,
) -> Unit {
  let payload = match sse_payload(line) {
    Some(payload) => payload
    None => return
  }
  if payload == "[DONE]" || payload.is_empty() {
    return
  }
  let json = @json.parse(payload) catch { _ => return }
  let obj = match json {
    Object(obj) => obj
    _ => return
  }
  let usage = match obj.get("usage") {
    Some(Object(usage)) => usage
    _ => return
  }
  let prompt_tokens = match jint(usage.get("prompt_tokens")) {
    Some(value) => value
    None => 0
  }
  let completion_tokens = match jint(usage.get("completion_tokens")) {
    Some(value) => value
    None => 0
  }
  if prompt_tokens == 0 && completion_tokens == 0 {
    return
  }
  let reasoning_tokens = match jobject(usage.get("completion_tokens_details")) {
    Some(details) =>
      match jint(details.get("reasoning_tokens")) {
        Some(value) => value
        None => 0
      }
    None =>
      match jint(usage.get("reasoning_tokens")) {
        Some(value) => value
        None => 0
      }
  }
  self.usage = Some(
    TokenUsage::new(prompt_tokens, completion_tokens, reasoning_tokens),
  )
}

///|
/// 吃进一行 SSE，返回**这一行**产生的可见增量（若有）。
///
/// 累积与「立刻通知界面」是两件事：状态要累积，界面要逐字。所以返回值只带
/// 文本 / 思考增量，工具调用在结束时才组装。
pub fn StreamAccumulator::apply_line(
  self : StreamAccumulator,
  line : String,
) -> StreamDelta {
  // 先补工具分片与 usage：一个 chunk 里 content 与它们理论上可以同时出现。
  self.apply_tool_deltas(line)
  self.apply_usage(line)
  let event = parse_sse_line(line)
  let delta = match event {
    Some(Content(fragment)) => {
      self.content.write_string(fragment)
      DeltaContent(fragment)
    }
    Some(Reasoning(fragment)) => {
      self.reasoning.write_string(fragment)
      DeltaReasoning(fragment)
    }
    Some(Usage(usage)) => {
      self.usage = Some(usage)
      DeltaNone
    }
    Some(Finish(reason)) => {
      self.finish_reason = Some(reason)
      DeltaNone
    }
    Some(Done) => {
      self.done = true
      DeltaNone
    }
    _ => DeltaNone
  }
  delta
}

///|
pub fn StreamAccumulator::text(self : StreamAccumulator) -> String {
  self.content.to_string()
}

///|
pub fn StreamAccumulator::thinking(self : StreamAccumulator) -> String {
  self.reasoning.to_string()
}

///|
/// 组装好的工具调用（只保留有名字的；arguments 为空时补 `{}`）。
pub fn StreamAccumulator::tool_calls(
  self : StreamAccumulator,
) -> Array[@message.ToolCall] {
  let calls : Array[@message.ToolCall] = []
  for draft in self.drafts {
    if draft.name.is_empty() {
      continue
    }
    let id = if draft.id.is_empty() {
      "call_" + draft.index.to_string()
    } else {
      draft.id
    }
    let arguments = if draft.arguments.is_empty() {
      "{}"
    } else {
      draft.arguments
    }
    calls.push({ id, name: draft.name, arguments, })
  }
  calls
}

///|
fn usage_of(raw : TokenUsage, model : PiModelInfo) -> @message.Usage {
  let input = raw.prompt_tokens
  let output = raw.completion_tokens
  let cost = (
      input.to_double() * model.cost_input +
      output.to_double() * model.cost_output
    ) /
    1000000.0
  {
    input_tokens: input,
    output_tokens: output,
    total_tokens: input + output,
    cost_total: cost,
  }
}

///|
/// 把累积下来的东西组装成内核要的 assistant 消息。
///
/// `stop_reason` 用我们的两个约定值：有工具调用 → `toolUse`；否则 `stop` /
/// `length`。`llm.done` 的迁移只看它是否等于 `aborted`，与 provider 的原始
/// `finish_reason` 解耦。
pub fn StreamAccumulator::to_assistant_part(
  self : StreamAccumulator,
  model : PiModelInfo,
) -> @message.AssistantPart {
  let calls = self.tool_calls()
  let content : Array[@message.Content] = []
  let thinking = self.thinking()
  if !thinking.is_empty() {
    content.push(@message.Thinking(thinking))
  }
  let text = self.text()
  if !text.is_empty() {
    content.push(@message.Text(text))
  }
  for call in calls {
    content.push(@message.ToolCallBlock(call))
  }
  let stop_reason = if !calls.is_empty() {
    "toolUse"
  } else {
    match self.finish_reason {
      Some("length") => "length"
      _ => "stop"
    }
  }
  {
    content,
    stop_reason,
    error_message: None,
    usage: match self.usage {
      Some(usage) => Some(usage_of(usage, model))
      None => None
    },
    timestamp: 0L,
  }
}

///|
/// 流结束得「不像话」：没有 content、没有工具、也没见到 finish / [DONE]。
/// 这通常是连接被截断，得按网络错误重试，而不是把一条空消息交给模型。
pub fn StreamAccumulator::is_truncated(self : StreamAccumulator) -> Bool {
  !self.done &&
  self.finish_reason is None &&
  self.text().is_empty() &&
  self.tool_calls().is_empty()
}
