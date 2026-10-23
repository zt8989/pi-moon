// 对话消息模型（user / assistant / toolResult / system）。
//
// 一个原则：**`messages` 是发给模型的那一份历史，只放终值**。
// 流式增量（llm.delta / tool.progress）不进这里，它们只用于渲染。

///|
/// 模型要求执行的一次工具调用。
///
/// `arguments` 是 JSON 文本（原项目是对象）。内核只把它原样透传给 provider
/// 和工具实现，不在这里解析 —— 少一层解析就少一处「两边 JSON 形状不一致」。
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
/// 一条消息里的内容块。
pub(all) enum Content {
  Text(String)
  Thinking(String)
  ToolCallBlock(ToolCall)
  Image(String)
} derive(Eq, Debug)

///|
/// token 用量。`cost_total` 用 Double：界面要累加，会显示小数。
pub(all) struct Usage {
  input_tokens : Int32
  output_tokens : Int32
  total_tokens : Int32
  cost_total : Double
} derive(Eq, Debug)

///|
pub let zero_usage : Usage = {
  input_tokens: 0,
  output_tokens: 0,
  total_tokens: 0,
  cost_total: 0.0,
}

///|
/// user 消息。带附件时 `content` 是 text / image 块的混合。
pub(all) struct UserPart {
  content : Array[Content]
  timestamp : Int64
} derive(Eq, Debug)

///|
/// assistant 消息。
///
/// `stop_reason` 是字符串（`stop` / `toolUse` / `aborted` / …），
/// 因为 provider 之间本来就不统一；内核只特别认 `aborted` 一个值。
pub(all) struct AssistantPart {
  content : Array[Content]
  stop_reason : String
  error_message : String?
  usage : Usage?
  timestamp : Int64
} derive(Eq, Debug)

///|
/// 工具结果消息。`tool_call_id` 必须与那条 `ToolCall.id` 对上 ——
/// 这是 provider 眼里唯一合法的配对方式。
pub(all) struct ToolResultPart {
  tool_call_id : String
  tool_name : String
  content : Array[Content]
  is_error : Bool
  timestamp : Int64
} derive(Eq, Debug)

///|
/// 中途追加的 system / developer 消息。
pub(all) struct SystemPart {
  role : String
  content : String
  sections : Array[(String, String)]
  source : String?
  timestamp : Int64
} derive(Eq, Debug)

///|
pub(all) enum Message {
  UserMsg(UserPart)
  AssistantMsg(AssistantPart)
  ToolResultMsg(ToolResultPart)
  SystemMsg(SystemPart)
} derive(Eq, Debug)

///|
/// 一个内容块的纯文本形式（非文本块给一个占位标记）。
pub fn content_text(block : Content) -> String {
  match block {
    Text(text) => text
    Thinking(text) => text
    ToolCallBlock(call) => "[调用 " + call.name + "]"
    Image(_) => "[image]"
  }
}

///|
/// 一组内容块拼成人读的文本：文本块按空格连起来，忽略空块。
pub fn contents_text(blocks : Array[Content]) -> String {
  let parts : Array[String] = []
  for block in blocks {
    let text = content_text(block)
    if !text.is_empty() {
      parts.push(text)
    }
  }
  parts.join(" ")
}

///|
/// 消息里的内容块。
pub fn Message::content(self : Message) -> Array[Content] {
  match self {
    UserMsg(part) => part.content
    AssistantMsg(part) => part.content
    ToolResultMsg(part) => part.content
    SystemMsg(_) => []
  }
}

///|
/// 消息的纯文本形式（渲染 / 节点标签用）。
pub fn Message::text(self : Message) -> String {
  match self {
    SystemMsg(part) => part.content
    _ => contents_text(self.content())
  }
}

///|
/// 消息角色（与 pi-ai 的 `role` 取值同名）。
pub fn Message::role(self : Message) -> String {
  match self {
    UserMsg(_) => "user"
    AssistantMsg(_) => "assistant"
    ToolResultMsg(_) => "toolResult"
    SystemMsg(_) => "system"
  }
}

///|
/// 消息时刻。
pub fn Message::timestamp(self : Message) -> Int64 {
  match self {
    UserMsg(part) => part.timestamp
    AssistantMsg(part) => part.timestamp
    ToolResultMsg(part) => part.timestamp
    SystemMsg(part) => part.timestamp
  }
}

///|
/// assistant 消息里的工具调用（按出现顺序）。
pub fn AssistantPart::tool_calls(self : AssistantPart) -> Array[ToolCall] {
  let calls : Array[ToolCall] = []
  for block in self.content {
    match block {
      ToolCallBlock(call) => calls.push(call)
      _ => ()
    }
  }
  calls
}

///|
/// 一条消息里的工具调用；非 assistant 消息没有。
pub fn Message::tool_calls(self : Message) -> Array[ToolCall] {
  match self {
    AssistantMsg(part) => part.tool_calls()
    _ => []
  }
}

///|
/// toolResult 消息配对的调用 id；别的消息没有。
pub fn Message::tool_result_id(self : Message) -> String? {
  match self {
    ToolResultMsg(part) => Some(part.tool_call_id)
    _ => None
  }
}

///|
/// 纯文本 user 消息的构造糖。
pub fn user_message(text : String, timestamp : Int64) -> Message {
  UserMsg({ content: [Text(text)], timestamp, })
}

///|
/// 纯文本 assistant 消息的构造糖。
pub fn assistant_message(
  text : String,
  stop_reason : String,
  timestamp : Int64,
) -> Message {
  AssistantMsg({
    content: [Text(text)],
    stop_reason,
    error_message: None,
    usage: None,
    timestamp,
  })
}

///|
/// 工具结果消息的构造糖。
pub fn tool_result_message(
  call : ToolCall,
  text : String,
  is_error : Bool,
  timestamp : Int64,
) -> Message {
  ToolResultMsg({
    tool_call_id: call.id,
    tool_name: call.name,
    content: [Text(text)],
    is_error,
    timestamp,
  })
}
