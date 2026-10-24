// 摘要请求的提示词与对话序列化。
//
// 摘要的**格式**是模型续接时的契约（下游靠 `## Next Steps` 决定接着做什么），
// 所以这段提示词与 pi 逐字一致 —— 两边生成的摘要可以互相读。

///|
pub fn summarization_system_prompt() -> String {
  "You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.\n\nDo NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary."
}

///|
pub fn summarization_prompt() -> String {
  [
    "## Goal", "[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]",
    "", "## Constraints & Preferences", "- [Any constraints, preferences, or requirements mentioned by user]",
    "- [Or \"(none)\" if none were mentioned]", "", "## Progress", "### Done", "- [x] [Completed tasks/changes]",
    "", "### In Progress", "- [ ] [Current work]", "", "### Blocked", "- [Issues preventing progress, if any]",
    "", "## Key Decisions", "- **[Decision]**: [Brief rationale]", "", "## Next Steps",
    "1. [Ordered list of what should happen next]", "", "## Critical Context", "- [Any data, examples, or references needed to continue]",
    "- [Or \"(none)\" if not applicable]", "", "Keep each section concise. Preserve exact file paths, function names, and error messages.",
  ].join("\n")
}

///|
fn update_summarization_rules() -> String {
  [
    "Update the existing structured summary with new information. RULES:", "- PRESERVE all existing information from the previous summary",
    "- ADD new progress, decisions, and context from the new messages", "- UPDATE the Progress section: move items from \"In Progress\" to \"Done\" when completed",
    "- UPDATE \"Next Steps\" based on what was accomplished", "- PRESERVE exact file paths, function names, and error messages",
    "- If something is no longer relevant, you may remove it", "", "Use this EXACT format:",
    "", "## Goal", "[Preserve existing goals, add new ones if the task expanded]",
    "", "## Constraints & Preferences", "- [Preserve existing, add new ones discovered]",
    "", "## Progress", "### Done", "- [x] [Include previously done items AND newly completed items]",
    "", "### In Progress", "- [ ] [Current work - update based on progress]", "",
    "### Blocked", "- [Current blockers - remove if resolved]", "", "## Key Decisions",
    "- **[Decision]**: [Brief rationale] (preserve all previous, add new)", "", "## Next Steps",
    "1. [Update based on current state]", "", "## Critical Context", "- [Preserve important context, add new if needed]",
    "", "Keep each section concise. Preserve exact file paths, function names, and error messages.",
  ].join("\n")
}

///|
fn update_summarization_prompt() -> String {
  "The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.\n\n" +
  update_summarization_rules()
}

///|
fn turn_prefix_summarization_prompt() -> String {
  [
    "The messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.",
    "", "Create a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.",
    "", "## Original Request", "[What did the user ask for?]", "", "## Progress So Far",
    "- [Key decisions and work completed in these messages]", "", "## Context Needed to Continue",
    "- [Information from these messages needed to understand the later work]", "",
    "Only summarize information explicitly present above. Do not infer or recreate later messages.",
  ].join("\n")
}

// ─── 序列化 ─────────────────────────────────────────────────────────────────

///|
/// 一条工具结果最多保留多少字符（pi 的 `TOOL_RESULT_MAX_CHARS`）。
let tool_result_max_chars : Int32 = 2000

///|
fn truncate_for_summary(text : String, max_chars : Int32) -> String {
  if text.length() <= max_chars {
    return text
  }
  text[:max_chars].to_owned() +
  "\n\n[... " +
  (text.length() - max_chars).to_string() +
  " more characters truncated]"
}

///|
fn text_of(blocks : Array[@message.Content]) -> String {
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
/// 把对话拍平成文本，交给摘要模型。
///
/// 拍平是必需的：把原始消息直接发过去，模型会把「总结」理解成「接着聊」。
/// 工具结果截到 2000 字符 —— 摘要不需要完整输出，不截会让摘要请求自己又撑爆窗口。
pub fn serialize_conversation(messages : Array[@message.Message]) -> String {
  let parts : Array[String] = []
  for message in messages {
    match message {
      @message.UserMsg(part) => {
        let text = text_of(part.content)
        if !text.is_empty() {
          parts.push("[User]: " + text)
        }
      }
      @message.AssistantMsg(part) => {
        let thinking = StringBuilder()
        let calls : Array[String] = []
        let mut has_text = false
        for block in part.content {
          match block {
            @message.Thinking(text) => {
              if thinking.to_string().length() > 0 {
                thinking.write_string("\n")
              }
              thinking.write_string(text)
            }
            @message.Text(_) => has_text = true
            @message.ToolCallBlock(call) =>
              calls.push(call.name + "(" + call.arguments + ")")
            @message.Image(_) => ()
          }
        }
        let thinking_text = thinking.to_string()
        if !thinking_text.is_empty() {
          parts.push("[Assistant thinking]: " + thinking_text)
        }
        if has_text {
          parts.push("[Assistant]: " + text_of(part.content))
        }
        if !calls.is_empty() {
          parts.push("[Assistant tool calls]: " + calls.join("; "))
        }
      }
      @message.ToolResultMsg(part) => {
        let text = text_of(part.content)
        if !text.is_empty() {
          parts.push(
            "[Tool result]: " +
            truncate_for_summary(text, tool_result_max_chars),
          )
        }
      }
      @message.SystemMsg(_) => ()
    }
  }
  parts.join("\n\n")
}

///|
/// 历史摘要的提示词：`<conversation>` 包住对话，有旧摘要时附 `<previous-summary>`。
pub fn summarize_prompt(
  messages : Array[@message.Message],
  previous_summary : String?,
) -> String {
  let builder = StringBuilder()
  builder.write_string("<conversation>\n")
  builder.write_string(serialize_conversation(messages))
  builder.write_string("\n</conversation>\n\n")
  match previous_summary {
    Some(summary) => {
      builder.write_string("<previous-summary>\n")
      builder.write_string(summary)
      builder.write_string("\n</previous-summary>\n\n")
      builder.write_string(update_summarization_prompt())
    }
    None => builder.write_string(summarization_prompt())
  }
  builder.to_string()
}

///|
/// 半轮前缀的提示词（切点落在一轮中间时另做一段）。
pub fn turn_prefix_prompt(messages : Array[@message.Message]) -> String {
  "# Conversation\n" +
  serialize_conversation(messages) +
  "\n\n# Instructions\n" +
  turn_prefix_summarization_prompt()
}
