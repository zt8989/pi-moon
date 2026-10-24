// 压缩的纯策略：估算、夹紧、切点、摘要消息标记。

///|
fn long_text(count : Int32) -> String {
  let builder = StringBuilder()
  for _ in 0..<count {
    builder.write_string("x")
  }
  builder.to_string()
}

///|
fn text_message(text : String) -> @message.Message {
  @message.user_message(text, 0L)
}

///|
fn assistant_text(text : String) -> @message.Message {
  @message.assistant_message(text, "stop", 0L)
}

///|
fn assistant_with_call(name : String, arguments : String) -> @message.Message {
  @message.AssistantMsg({
    content: [
      @message.Text("调用工具"),
      @message.ToolCallBlock({ id: "call_1", name, arguments, }),
    ],
    stop_reason: "toolUse",
    error_message: None,
    usage: None,
    timestamp: 0L,
  })
}

///|
fn result_message(text : String) -> @message.Message {
  @message.tool_result_message(
    { id: "call_1", name: "read", arguments: "{}", },
    text,
    false,
    0L,
  )
}

///|
test "estimate_tokens 是 chars/4 向上取整，工具结果按内容算" {
  assert_eq(estimate_tokens(text_message("12345678")), 2)
  assert_eq(estimate_tokens(text_message("123456789")), 3)
  assert_eq(estimate_tokens(result_message("12345678")), 2)
  // 工具调用把名字与 arguments 一起算进去。
  assert_true(estimate_tokens(assistant_with_call("read", "{}")) > 0)
}

///|
test "effective_settings 按窗口夹紧（小窗口不会每轮都该压）" {
  let settings = default_settings()
  let clamped = effective_settings(settings, 1000)
  assert_eq(clamped.reserve_tokens, 200)
  assert_eq(clamped.keep_recent_tokens, 500)
  // 窗口不知道（0）时不夹。
  let unknown = effective_settings(settings, 0)
  assert_eq(unknown.reserve_tokens, 16384)
  assert_eq(unknown.keep_recent_tokens, 20000)
}

///|
test "plan_cut 绝不切在 toolResult 上：预算用尽时退到下一个合法切点" {
  let messages = [
    text_message("第一问"),
    assistant_with_call("read", "{\"path\":\"a.txt\"}"),
    result_message(long_text(4000)),
    text_message("第二问"),
    assistant_text("第二答"),
  ]
  let plan = plan_cut(messages, 15).unwrap()
  // 预算在 toolResult 那一格用尽 → 切点退到它后面的 user，而不是切在结果上。
  assert_false(plan.is_split_turn)
  assert_eq(plan.kept.length(), 2)
  assert_true(plan.kept[0] is @message.UserMsg(_))
  assert_eq(plan.summarized.length(), 3)
  assert_eq(plan.tokens_before, estimate_messages_tokens(messages))
}

///|
test "plan_cut 切在一轮中间时给出 turn_prefix，而不是丢掉半轮上下文" {
  let messages = [
    text_message("第一问"),
    assistant_text("第一答"),
    text_message("第二问"),
    assistant_text("第二答"),
  ]
  // 预算只够最后一格 → 切点落在 assistant，往前找到它的 user（第二问）。
  let plan = plan_cut(messages, 1).unwrap()
  assert_true(plan.is_split_turn)
  assert_eq(plan.turn_prefix.length(), 1)
  assert_true(plan.turn_prefix[0] is @message.UserMsg(_))
  assert_eq(plan.kept.length(), 1)
  assert_eq(plan.summarized.length(), 2)
}

///|
test "plan_cut 在没有可摘的历史时返回 None（压了等于没压）" {
  let messages = [text_message("只有一句"), assistant_text("只有一答")]
  assert_true(plan_cut(messages, 100000) is None)
  assert_true(plan_cut([], 1000) is None)
  // 头一条是中途插入的 system 声明时，不能把它当成「对话」摘成空摘要。
  let with_system = [
    @message.SystemMsg({
      role: "system",
      content: "[toolset changed] added: grep",
      sections: [],
      source: Some("tools.changed"),
      timestamp: 0L,
    }),
    text_message("问"),
    assistant_text("答"),
  ]
  assert_true(plan_cut(with_system, 100000) is None)
}

///|
test "摘要消息靠结构标记认，不靠内容猜" {
  let message = build_summary_message("这是摘要", 1234, 7L)
  assert_true(is_summary_message(message))
  assert_eq(summary_body(message), Some("这是摘要"))
  match message {
    @message.UserMsg(part) => {
      assert_true(part.compaction_summary)
      assert_eq(part.tokens_before, 1234)
      assert_eq(part.timestamp, 7L)
    }
    _ => assert_true(false)
  }
  // 用户手打一段一模一样的文本，不是摘要。
  let fake = text_message("[summary] 这是摘要")
  assert_false(is_summary_message(fake))
}

///|
test "last_summary_text 取尾巴里最后一条摘要（迭代压缩的起点）" {
  let messages = [
    text_message("早先的话"),
    build_summary_message("上一次的摘要", 100, 0L),
    text_message("后来的话"),
  ]
  assert_eq(last_summary_text(messages), Some("上一次的摘要"))
  assert_eq(last_summary_text([text_message("没有摘要")]), None)
}

///|
test "file_lists 从 read / write / edit 的 arguments 里抽路径" {
  let messages = [
    assistant_with_call("read", "{\"path\":\"a.txt\"}"),
    assistant_with_call("write", "{\"path\":\"b.txt\"}"),
    assistant_with_call("edit", "{\"path\":\"c.txt\"}"),
    assistant_with_call("read", "{\"path\":\"c.txt\"}"),
  ]
  let (read, modified) = file_lists(messages)
  assert_eq(read, ["a.txt"])
  assert_eq(modified, ["b.txt", "c.txt"])
}
