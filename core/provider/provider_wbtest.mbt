// 配置解析、请求体、SSE 累积 —— 全部离线。
//
// 真实网关的手工验证在整环之外单独跑；测试只钉协议与优先级，
// 不碰网络、不读真实 key。

///|
fn test_config(
  models_text : String,
  auth_text : String,
  settings_text : String,
) -> PiConfig {
  let models = @json.parse(models_text) catch { _ => Json::null() }
  let auth = @json.parse(auth_text) catch { _ => Json::null() }
  let settings = @json.parse(settings_text) catch { _ => Json::null() }
  let settings_obj = match settings {
    Object(obj) => obj
    _ => Map([])
  }
  {
    providers: parse_providers(models),
    default_provider: field_string(settings_obj, "defaultProvider"),
    default_model: field_string(settings_obj, "defaultModel"),
    default_thinking_level: match
      field_string(settings_obj, "defaultThinkingLevel") {
      Some(level) => level
      None => "off"
    },
    default_tools: field_string_array(settings_obj, "defaultTools"),
    compaction: @compact.default_settings(),
    auth: parse_auth(Some(auth)),
    env: Map([]),
    agent_dir: "/tmp/pi",
    diagnostics: [],
  }
}

///|
fn expect_error(
  config : PiConfig,
  provider : String,
  model : String,
) -> ProviderError {
  try {
    let _ = config.resolve(provider~, model~)
    abort("expected resolve to fail")
  } catch {
    err => err
  }
}

///|
test "现行 models.json 形状：providers 对象 + models 数组" {
  let config = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"api\":\"openai-completions\",\"apiKey\":\"file-key\",\"models\":[{\"id\":\"m1\",\"name\":\"Model One\",\"reasoning\":true,\"contextWindow\":128000,\"maxTokens\":4096,\"thinkingLevelMap\":{\"off\":null,\"low\":\"low\",\"high\":\"high\"},\"cost\":{\"input\":0.3,\"output\":1.2},\"compat\":{\"thinkingFormat\":\"deepseek\",\"supportsReasoningEffort\":true}}]}}}",
    "{}", "{}",
  )
  assert_eq(config.providers.length(), 1)
  let provider = config.providers[0]
  assert_eq(provider.name, "demo")
  assert_eq(provider.base_url, "http://gw/v1")
  assert_eq(provider.api_key, Some("file-key"))
  assert_eq(provider.models.length(), 1)
  let model = provider.models[0]
  assert_eq(model.id, "m1")
  assert_eq(model.name, "Model One")
  assert_true(model.reasoning)
  assert_eq(model.context_window, 128000)
  assert_eq(model.max_tokens, Some(4096))
  assert_eq(model.cost_input, 0.3)
  assert_eq(model.cost_output, 1.2)
  assert_eq(model.compat.thinking_format, "deepseek")
  assert_eq(model.compat.max_tokens_field, "max_tokens")
  // off 显式 null：这一档不支持。
  assert_eq(model.thinking_level_map.get("off"), Some(None))
  assert_eq(model.thinking_level_map.get("low"), Some(Some("low")))
}

///|
test "旧形状：根对象是 provider 表，models 是对象 map" {
  let config = test_config(
    "{\"legacy\":{\"baseUrl\":\"http://old/v1\",\"models\":{\"m-old\":{\"reasoning\":false}}}}",
    "{}", "{}",
  )
  assert_eq(config.providers.length(), 1)
  assert_eq(config.providers[0].name, "legacy")
  assert_eq(config.providers[0].models.length(), 1)
  // 对象 map 的 key 就是 id。
  assert_eq(config.providers[0].models[0].id, "m-old")
}

///|
test "凭证优先级：显式 > models.json > auth.json > 环境变量" {
  let config = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"apiKey\":\"file-key\",\"models\":[{\"id\":\"m1\"}]}}}",
    "{\"demo\":{\"type\":\"api_key\",\"key\":\"auth-key\"}}", "{\"defaultProvider\":\"demo\",\"defaultModel\":\"m1\"}",
  )
  // env 里也放一份：优先级最低。
  config.env["DEMO_API_KEY"] = "env-key"
  assert_eq(config.resolve(api_key="explicit-key").api_key, "explicit-key")
  assert_eq(config.resolve().api_key, "file-key")
  // 去掉 models.json 的 key 之后落 auth.json。
  let config2 = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"models\":[{\"id\":\"m1\"}]}}}",
    "{\"demo\":{\"type\":\"api_key\",\"key\":\"auth-key\"}}", "{\"defaultProvider\":\"demo\",\"defaultModel\":\"m1\"}",
  )
  assert_eq(config2.resolve().api_key, "auth-key")
  // 再去掉 auth.json 之后落环境变量。
  let config3 = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"models\":[{\"id\":\"m1\"}]}}}",
    "{}", "{\"defaultProvider\":\"demo\",\"defaultModel\":\"m1\"}",
  )
  config3.env["DEMO_API_KEY"] = "env-key"
  assert_eq(config3.resolve().api_key, "env-key")
}

///|
test "默认值来自 settings.json；显式参数覆盖它" {
  let config = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"models\":[{\"id\":\"m1\"},{\"id\":\"m2\"}]}}}",
    "{}", "{\"defaultProvider\":\"demo\",\"defaultModel\":\"m2\",\"defaultThinkingLevel\":\"high\"}",
  )
  let resolved = config.resolve()
  assert_eq(resolved.provider_name, "demo")
  assert_eq(resolved.model.id, "m2")
  assert_eq(resolved.thinking_level, "high")
  let overridden = config.resolve(model="m1", thinking="low")
  assert_eq(overridden.model.id, "m1")
  assert_eq(overridden.thinking_level, "low")
}

///|
test "内置 provider：deepseek + 环境变量 key，不需要 models.json" {
  let env : Map[String, String] = Map([])
  env["DEEPSEEK_API_KEY"] = "env-key"
  let config : PiConfig = {
    providers: [],
    default_provider: None,
    default_model: None,
    default_thinking_level: "off",
    default_tools: None,
    compaction: @compact.default_settings(),
    auth: Map([]),
    env,
    agent_dir: "/tmp/pi",
    diagnostics: [],
  }
  let resolved = config.resolve(provider="deepseek", model="deepseek-chat")
  assert_eq(resolved.base_url, "https://api.deepseek.com/v1")
  assert_eq(resolved.api_key, "env-key")
  // 不在目录里的模型按 OpenAI 兼容的默认参数处理，而不是报错。
  assert_eq(resolved.model.id, "deepseek-chat")
}

///|
test "未知 provider / 非 OpenAI 线格式都给出明确错误" {
  let config = test_config(
    "{\"providers\":{\"demo\":{\"baseUrl\":\"http://gw/v1\",\"models\":[{\"id\":\"m1\"},{\"id\":\"m2\",\"api\":\"anthropic-messages\"}]}}}",
    "{}", "{}",
  )
  match expect_error(config, "nope", "m1") {
    UnknownProvider(_) => ()
    other => abort("expected UnknownProvider, got " + other.to_string())
  }
  match expect_error(config, "demo", "m2") {
    UnsupportedApi(api~, ..) => assert_eq(api, "anthropic-messages")
    other => abort("expected UnsupportedApi, got " + other.to_string())
  }
}

///|
test "环境变量名：provider id → <ID>_API_KEY" {
  assert_eq(provider_env_key("workbuddy"), "WORKBUDDY_API_KEY")
  assert_eq(provider_env_key("my-gateway"), "MY_GATEWAY_API_KEY")
}

// ─── 请求体 ───

///|
fn test_resolved(thinking_level : String) -> ResolvedProvider {
  let levels : Map[String, String?] = Map([])
  levels["off"] = None
  levels["low"] = Some("low")
  levels["high"] = Some("high")
  {
    provider_name: "demo",
    base_url: "http://gw/v1",
    api: "openai-completions",
    model: {
      id: "m1",
      name: "M1",
      api: "openai-completions",
      base_url: None,
      reasoning: true,
      context_window: 1000,
      max_tokens: Some(4096),
      thinking_level_map: levels,
      cost_input: 1.0,
      cost_output: 2.0,
      compat: {
        thinking_format: "deepseek",
        max_tokens_field: "max_tokens",
        supports_reasoning_effort: true,
        supports_usage_in_streaming: true,
        requires_reasoning_content: true,
        supports_developer_role: false,
        requires_tool_result_name: false,
      },
    },
    api_key: "k",
    thinking_level,
    agent_dir: "/tmp/pi",
  }
}

///|
fn body_object(body : Json) -> Map[String, Json] {
  match body {
    Object(obj) => obj
    _ => abort("body is not an object")
  }
}

///|
fn jfield(json : Json, key : String) -> Json? {
  match json {
    Object(obj) => obj.get(key)
    _ => None
  }
}

///|
test "请求体：system 在前、工具与思考参数按 compat 发" {
  let state = @state.create_initial_state({
    system_prompt: "SYS",
    provider_name: "demo",
    model_id: "m1",
    thinking_level: "high",
    tool_names: ["read"],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s1",
    cwd: "/tmp",
    trace: None,
  })
  let (state, _) = @loop.reduce(
    state,
    @action.PromptInit({
      system_prompt: "SYS",
      tools: [
        {
          name: "read",
          description: "read a file",
          parameters: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
      ],
    }),
    1L,
  )
  let (state, _) = @loop.reduce(
    state,
    @action.ModelInit({
      provider: "demo",
      model_id: "m1",
      thinking_level: "high",
      reasoning: true,
      capabilities: @action.no_capabilities,
      context_window: 1000,
    }),
    2L,
  )
  let (state, _) = @loop.reduce(
    state,
    @action.UserMessage({ text: "你好", content: [], }),
    3L,
  )
  let options : ChatOptions = {
    ..ChatOptions::defaults(),
    max_tokens: Some(512),
  }
  let body = body_object(
    build_request_body(test_resolved("high"), state, options, true),
  )
  assert_eq(body.get("model"), Some(Json::string("m1")))
  assert_eq(body.get("stream"), Some(Json::boolean(true)))
  // 思考：deepseek 格式 → thinking.type + reasoning_effort。
  let thinking = body_object(body.get("thinking").unwrap())
  assert_eq(thinking.get("type"), Some(Json::string("enabled")))
  assert_eq(body.get("reasoning_effort"), Some(Json::string("high")))
  assert_eq(body.get("max_tokens"), Some(Json::number(512.0)))
  let messages = match body.get("messages") {
    Some(Array(items)) => items
    _ => abort("messages missing")
  }
  // system prompt 在最前，user 在最后。
  assert_eq(jfield(messages[0], "role"), Some(Json::string("system")))
  assert_eq(jfield(messages[0], "content"), Some(Json::string("SYS")))
  assert_eq(jfield(messages[1], "role"), Some(Json::string("user")))
  let tools = match body.get("tools") {
    Some(Array(items)) => items
    _ => abort("tools missing")
  }
  assert_eq(tools.length(), 1)
  let function = jfield(tools[0], "function").unwrap()
  assert_eq(jfield(function, "name"), Some(Json::string("read")))
  // 参数被解析成对象（不是字符串）。
  assert_true(jfield(function, "parameters") is Some(Object(_)))
}

///|
test "摘要请求体：system 是摘要助手、不带工具、不发思考参数" {
  let prompt : @message.Message = @message.user_message(
    "<conversation>…</conversation>", 0L,
  )
  let body = body_object(
    build_summary_request_body(test_resolved("high"), "SUM-SYS", [prompt], 640),
  )
  assert_eq(body.get("model"), Some(Json::string("m1")))
  assert_eq(body.get("stream"), Some(Json::boolean(true)))
  assert_eq(body.get("max_tokens"), Some(Json::number(640.0)))
  // 摘要不再思考：思考参数会让摘要又贵又容易跑偏。
  assert_eq(body.get("thinking"), None)
  assert_eq(body.get("reasoning_effort"), None)
  // 没有工具历史时不发 tools 字段。
  assert_eq(body.get("tools"), None)
  let messages = match body.get("messages") {
    Some(Array(items)) => items
    _ => abort("messages missing")
  }
  assert_eq(messages.length(), 2)
  assert_eq(jfield(messages[0], "role"), Some(Json::string("system")))
  assert_eq(jfield(messages[0], "content"), Some(Json::string("SUM-SYS")))
  assert_eq(jfield(messages[1], "role"), Some(Json::string("user")))
  // 有 toolResult 的历史：网关要求 tools 字段存在（哪怕是空数组）。
  let with_tool = build_summary_request_body(
    test_resolved("off"),
    "SUM-SYS",
    [
      @message.tool_result_message(
        { id: "c1", name: "read", arguments: "{}", },
        "内容",
        false,
        0L,
      ),
    ],
    100,
  )
  match with_tool {
    Object(obj) =>
      match obj.get("tools") {
        Some(Array(items)) => assert_eq(items.length(), 0)
        _ => abort("tools missing")
      }
    _ => abort("body is not an object")
  }
}

///|
test "assistant 历史：tool_calls 与 reasoning_content" {
  let call : @message.ToolCall = {
    id: "c1",
    name: "read",
    arguments: "{\"path\":\"a\"}",
  }
  let part : @message.AssistantPart = {
    content: [
      @message.Thinking("想一想"),
      @message.Text("我读一下"),
      @message.ToolCallBlock(call),
    ],
    stop_reason: "toolUse",
    error_message: None,
    usage: None,
    timestamp: 0L,
  }
  let compat = test_resolved("high").model.compat
  let json = body_object(assistant_json(part, compat))
  assert_eq(json.get("reasoning_content"), Some(Json::string("想一想")))
  let calls = match json.get("tool_calls") {
    Some(Array(items)) => items
    _ => abort("tool_calls missing")
  }
  assert_eq(calls.length(), 1)
  assert_eq(jfield(calls[0], "id"), Some(Json::string("c1")))
  assert_eq(
    jfield(jfield(calls[0], "function").unwrap(), "arguments"),
    Some(Json::string("{\"path\":\"a\"}")),
  )
}

// ─── SSE ───

///|
test "SSE：文本 + 思考 + 工具分片 + usage + [DONE]" {
  let lines : Array[String] = [
    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}", "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}",
    "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}", "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a\\\"}\"}}]}}]}",
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"completion_tokens_details\":{\"reasoning_tokens\":2}}}",
    "data: [DONE]",
  ]
  let accumulator = StreamAccumulator::new()
  let deltas : Array[StreamDelta] = []
  for line in lines {
    deltas.push(accumulator.apply_line(line))
  }
  assert_eq(accumulator.text(), "你好")
  assert_eq(accumulator.thinking(), "想")
  assert_true(accumulator.done)
  assert_true(!accumulator.is_truncated())
  let part = accumulator.to_assistant_part(test_resolved("high").model)
  assert_eq(part.stop_reason, "toolUse")
  assert_eq(part.content.length(), 3)
  match part.content[2] {
    @message.ToolCallBlock(call) => {
      assert_eq(call.id, "c1")
      assert_eq(call.name, "read")
      assert_eq(call.arguments, "{\"path\":\"a\"}")
    }
    _ => abort("expected a tool call block")
  }
  match part.usage {
    Some(usage) => {
      assert_eq(usage.input_tokens, 10)
      assert_eq(usage.output_tokens, 5)
      assert_eq(usage.total_tokens, 15)
    }
    None => abort("usage missing")
  }
  // 增量是按出现顺序返回的（思考、你、好）。
  assert_eq(deltas.length(), 7)
  assert_eq(deltas[0], DeltaReasoning("想"))
  assert_eq(deltas[1], DeltaContent("你"))
  assert_eq(deltas[2], DeltaContent("好"))
}

///|
test "SSE：没有 finish / DONE 的空流算截断" {
  let accumulator = StreamAccumulator::new()
  let _ = accumulator.apply_line("data: {\"choices\":[{\"delta\":{}}]}")
  assert_true(accumulator.is_truncated())
}

///|
test "models.json 覆盖内置 provider 时可以省略 baseUrl" {
  let config = test_config(
    "{\"providers\":{\"deepseek\":{\"models\":[{\"id\":\"deepseek-chat\"}]}}}", "{\"deepseek\":{\"type\":\"api_key\",\"key\":\"auth-key\"}}",
    "{}",
  )
  let resolved = config.resolve()
  assert_eq(resolved.base_url, "https://api.deepseek.com/v1")
  assert_eq(resolved.api_key, "auth-key")
}

///|
/// `run_tools` 的流式接线：命令还在跑的时候就要有 `ToolProgress`，
/// 而不是等结束才一次性给结果。
async test "run_tools 把 bash 的中间输出变成 ToolProgress" {
  let base = @state.create_initial_state({
    system_prompt: "",
    provider_name: "fake",
    model_id: "fake-1",
    thinking_level: "off",
    tool_names: ["bash"],
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: 120000L,
    session_id: "s-tools",
    cwd: ".",
    trace: None,
  })
  let (state, _) = @loop.reduce(
    base,
    @action.PromptInit({
      system_prompt: "",
      tools: @tools.definitions_for(["bash"]),
    }),
    0L,
  )
  let actions : Array[@action.AgentAction] = []
  let dispatch : @runtime.Dispatch = { emit: action => actions.push(action), }
  run_tools_default(
    state,
    [
      {
        id: "call-1",
        name: "bash",
        arguments: "{\"command\":\"printf first; sleep 0.3; printf second\"}",
      },
    ],
    dispatch,
  )
  let mut started = 0
  let mut progress = 0
  let mut result_text = ""
  let mut is_error = true
  for action in actions {
    match action {
      @action.ToolStart(call) => {
        assert_eq(call.name, "bash")
        started = started + 1
      }
      @action.ToolProgress(data) => {
        assert_eq(data.tool_call_id, "call-1")
        if @message.contents_text(data.content).contains("first") {
          progress = progress + 1
        }
      }
      @action.ToolResult(result) => {
        result_text = @message.contents_text(result.content)
        is_error = result.is_error
      }
      _ => ()
    }
  }
  assert_eq(started, 1)
  assert_true(progress >= 1)
  assert_eq(is_error, false)
  assert_eq(result_text, "firstsecond")
}

///|
test "中断：半截正文保留成 aborted 消息，未完成的 toolCall 被剥掉" {
  let accumulator = StreamAccumulator::new()
  let _ = accumulator.apply_line(
    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}",
  )
  let _ = accumulator.apply_line(
    "data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}",
  )
  let _ = accumulator.apply_line(
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}",
  )
  let part = aborted_part(accumulator, test_resolved("high").model).unwrap()
  assert_eq(part.stop_reason, "aborted")
  assert_eq(part.content.length(), 2)
  for block in part.content {
    match block {
      @message.ToolCallBlock(_) =>
        abort("half-written tool call must not enter messages")
      _ => ()
    }
  }
}

///|
test "中断：还没有任何正文时不产出 aborted 消息" {
  let accumulator = StreamAccumulator::new()
  assert_true(aborted_part(accumulator, test_resolved("high").model) is None)
}
