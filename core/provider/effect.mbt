// 真实 provider 的 effect 表：用 faceoff 的线协议 + moonbitlang/async 的 HTTP 客户端。
//
// 分工：
//   - `@faceoff.Settings` 负责 baseUrl → /chat/completions 的拼接与凭证字段；
//   - `@faceoff.parse_sse_line` 负责 SSE 协议（文本 / 思考 / usage / finish / done）；
//   - 本文件补上 agent 需要的两样：**messages 历史**（`request.mbt`）与
//     **delta.tool_calls**（`sse.mbt`）；
//   - 传输走 `@http.post_stream`，每一行读取套一个空闲超时。

///|
/// 渲染钩子：provider 在**流还在跑的时候**把增量交出去。
///
/// 这是「边收边画」的正门 —— `Dispatch` 是同步的（当场归约），没法 await 一个写终端；
/// 而 effect 本身是异步的，所以把输出留给这里。默认是空实现。
pub(all) struct ProviderHooks {
  on_content : async (String) -> Unit
  on_thinking : async (String) -> Unit
  /// 工具执行中的增量（工具名，当前**全文**）。只对 shell 工具有意义。
  on_tool_progress : async (String, Array[@message.Content]) -> Unit
}

///|
pub fn noop_hooks() -> ProviderHooks {
  {
    on_content: async fn(_) { () },
    on_thinking: async fn(_) { () },
    on_tool_progress: async fn(_, _) { () },
  }
}

///|
/// 一次流式调用。
///
/// 所有失败都变成 `LlmFailed` action —— effect 表不把异常抛回环上，因为「重试还是收工」
/// 是 reducer 的判断。只有 dispatch 自身的预算错误会继续往上抛。
async fn stream_completion(
  resolved : ResolvedProvider,
  state : @state.AgentState,
  options : ChatOptions,
  hooks : ProviderHooks,
  dispatch : @runtime.Dispatch,
) -> Unit {
  dispatch.send(@action.LlmStarted)
  let body = build_request_body(resolved, state, options, true).stringify()
  let settings = resolved.faceoff_settings(state.prompt.system_prompt)
  let url = settings.chat_completions_url()
  let headers : @http.Headers = Map([])
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream"
  if !resolved.api_key.is_empty() {
    headers["Authorization"] = "Bearer " + resolved.api_key
  }
  let client = @http.post_stream(url, headers~) catch {
    err => {
      dispatch.send(
        @action.LlmFailed({
          error: "transport error: " + err.to_string(),
          kind: @common.Network,
          node_id: None,
          cause: None,
        }),
      )
      return
    }
  }
  defer client.close()
  let response = try {
    client.write(body)
    client.end_request()
  } catch {
    err => {
      dispatch.send(
        @action.LlmFailed({
          error: "transport error: " + err.to_string(),
          kind: @common.Network,
          node_id: None,
          cause: None,
        }),
      )
      return
    }
  }
  if response.code < 200 || response.code >= 300 {
    // 错误体也要按 UTF-8 解码（不要用 raw bytes 强转）。
    let text = client.read_all().text() catch { _ => "" }
    let kind = classify_status(response.code, text)
    dispatch.send(
      @action.LlmFailed({
        error: "http " + response.code.to_string() + ": " + truncate(text, 400),
        kind,
        node_id: None,
        cause: None,
      }),
    )
    return
  }
  let accumulator = StreamAccumulator::new()
  while !accumulator.done {
    let line = read_sse_line(client, options.idle_timeout_ms) catch {
      @async.TimeoutError => {
        dispatch.send(
          @action.LlmFailed({
            error: "llm idle timeout after " +
            options.idle_timeout_ms.to_string() +
            "ms",
            kind: @common.Timeout,
            node_id: None,
            cause: Some(@common.CauseTimeout),
          }),
        )
        return
      }
      err => {
        let message = err.to_string()
        dispatch.send(
          @action.LlmFailed({
            error: "stream error: " + message,
            kind: classify_transport(message),
            node_id: None,
            cause: None,
          }),
        )
        return
      }
    }
    let line = match line {
      Some(line) => line
      None => break
    }
    match accumulator.apply_line(line) {
      DeltaContent(fragment) => {
        (hooks.on_content)(fragment)
        dispatch.send(@action.LlmDelta(fragment))
      }
      DeltaReasoning(fragment) => {
        (hooks.on_thinking)(fragment)
        dispatch.send(@action.LlmThinking(fragment))
      }
      DeltaNone => ()
    }
  }
  if accumulator.is_truncated() {
    dispatch.send(
      @action.LlmFailed({
        error: "stream ended before finish/[DONE]",
        kind: @common.Network,
        node_id: None,
        cause: None,
      }),
    )
    return
  }
  let part = accumulator.to_assistant_part(resolved.model)
  dispatch.send(@action.LlmDone({ message: part, node_id: None, }))
}

///|
/// 读一行，套**空闲**超时（不是总时长）：长生成跑多久都不受限，卡的是「多久没数据」。
async fn read_sse_line(client : @http.Client, timeout_ms : Int32) -> String? {
  @async.with_timeout(timeout_ms, async fn() { client.read_until("\n") })
}

///|
fn truncate(text : String, width : Int32) -> String {
  if text.length() <= width {
    text
  } else {
    text[:width].to_owned() + "…"
  }
}

///|
/// HTTP 状态码 → 错误类别。429 与 5xx 按可重试的网络错误处理（与 pi 的 retry 口径一致）。
fn classify_status(code : Int32, body : String) -> @common.LlmErrorKind {
  if code == 401 || code == 403 {
    @common.Auth
  } else if code == 404 {
    @common.Model
  } else if code == 429 || code >= 500 {
    @common.Network
  } else if code == 400 || code == 422 {
    @common.Model
  } else if body.to_lower().contains("timeout") {
    @common.Timeout
  } else {
    @common.Unknown
  }
}

///|
fn classify_transport(message : String) -> @common.LlmErrorKind {
  let kind = @common.classify_llm_error(message)
  match kind {
    // 连接被掐断的文案千奇百怪；transport 层的失败默认按网络抖动处理。
    @common.Unknown => @common.Network
    _ => kind
  }
}

///|
/// 解析 provider / model（每次请求都重新解析：`/model` 切过之后要立刻生效）。
async fn run_agent_effect(
  config : PiConfig,
  options : ChatOptions,
  hooks : ProviderHooks,
  state : @state.AgentState,
  dispatch : @runtime.Dispatch,
) -> Unit {
  let provider = if state.model.provider.is_empty() {
    None
  } else {
    Some(state.model.provider)
  }
  let model = if state.model.model_id.is_empty() {
    None
  } else {
    Some(state.model.model_id)
  }
  let resolved = config.resolve(
    provider?,
    model?,
    api_key?=options.api_key,
    thinking=state.model.thinking_level,
  ) catch {
    err => {
      dispatch.send(
        @action.LlmFailed({
          error: err.to_string(),
          kind: @common.Model,
          node_id: None,
          cause: None,
        }),
      )
      return
    }
  }
  stream_completion(resolved, state, options, hooks, dispatch)
}

///|
/// 默认的工具执行：逐个调 `core/tools` 的实现，把 outcome 变成 `tool.result`。
///
/// 每个调用都必须落一条结果（即使工具失败），否则消息序列里就留下一个没有
/// 结果的 toolCall，下一轮请求会被网关拒掉。失败也**不掐回合**：模型能看到
/// 错误，自行决定重试还是换办法。
///
/// 启用检查读 `state.prompt.tools` —— 那是 `prompt.init` 装进来、**真正声明给模型**
/// 的那一份。关着的工具（例如默认关的 `powershell`）即使被硬调也只回「未知工具」。
async fn run_tools_with_hooks(
  state : @state.AgentState,
  calls : Array[@message.ToolCall],
  dispatch : @runtime.Dispatch,
  hooks : ProviderHooks,
) -> Unit {
  let enabled : Array[String] = []
  for definition in state.prompt.tools {
    enabled.push(definition.name)
  }
  for call in calls {
    dispatch.send(@action.ToolStart(call))
    let env : Map[String, String] = Map([])
    if !state.session_id.is_empty() {
      env["PI_SESSION_ID"] = state.session_id
    }
    if !state.model.provider.is_empty() {
      env["PI_PROVIDER"] = state.model.provider
    }
    if !state.model.model_id.is_empty() {
      env["PI_MODEL"] = state.model.model_id
    }
    if !state.model.thinking_level.is_empty() {
      env["PI_REASONING_LEVEL"] = state.model.thinking_level
    }
    let outcome = @tools.execute(state.cwd, call, env~, enabled~, on_progress=async fn(
      blocks,
    ) {
      (hooks.on_tool_progress)(call.name, blocks)
      dispatch.send(
        @action.ToolProgress({ tool_call_id: call.id, content: blocks, }),
      )
    })
    dispatch.send(
      @action.ToolResult({
        tool_call_id: call.id,
        tool_name: call.name,
        content: outcome.content,
        is_error: outcome.is_error,
        timestamp: @env.now().reinterpret_as_int64(),
      }),
    )
  }
  dispatch.send(@action.ToolBatchDone(calls.length()))
}

///|
async fn run_tools_default(
  state : @state.AgentState,
  calls : Array[@message.ToolCall],
  dispatch : @runtime.Dispatch,
) -> Unit {
  run_tools_with_hooks(state, calls, dispatch, noop_hooks())
}

///|
/// 用 pi 配置驱动的 effect 表。
pub fn effect_table(
  config : PiConfig,
  options : ChatOptions,
) -> @runtime.EffectTable {
  effect_table_full(config, options, noop_hooks(), run_tools_default)
}

///|
/// 带上渲染钩子（CLI / 界面用）。
pub fn effect_table_with_hooks(
  config : PiConfig,
  options : ChatOptions,
  hooks : ProviderHooks,
) -> @runtime.EffectTable {
  effect_table_full(config, options, hooks, async fn(state, calls, dispatch) {
    run_tools_with_hooks(state, calls, dispatch, hooks)
  })
}

///|
/// 工具执行由调用方注入。
pub fn effect_table_with_tools(
  config : PiConfig,
  options : ChatOptions,
  run_tools : async (
    @state.AgentState,
    Array[@message.ToolCall],
    @runtime.Dispatch,
  ) -> Unit,
) -> @runtime.EffectTable {
  effect_table_full(config, options, noop_hooks(), run_tools)
}

///|
/// 全部可注入：钩子管渲染，run_tools 管工具。
pub fn effect_table_full(
  config : PiConfig,
  options : ChatOptions,
  hooks : ProviderHooks,
  run_tools : async (
    @state.AgentState,
    Array[@message.ToolCall],
    @runtime.Dispatch,
  ) -> Unit,
) -> @runtime.EffectTable {
  {
    run_agent: async fn(state, dispatch) {
      run_agent_effect(config, options, hooks, state, dispatch)
    },
    run_tools,
  }
}

///|
/// `--list-models` 用：把配置里有什么原样列出来（不打网络、不打印 key）。
pub fn PiConfig::describe_models(self : PiConfig) -> String {
  let lines : Array[String] = []
  if self.providers.is_empty() {
    lines.push(
      "（models.json 里没有 provider；可用内置：" +
      "openai / deepseek / openrouter / groq / mistral / xai / together / " +
      "moonshot / zhipu / dashscope / ollama）",
    )
  }
  for provider in self.providers {
    let key = if provider.api_key is Some(_) {
      "key in models.json"
    } else if self.auth.contains(provider.name) {
      "key in auth.json"
    } else if self.env.contains(provider_env_key(provider.name)) {
      "key in env"
    } else {
      "no key"
    }
    lines.push(
      provider.name +
      "  " +
      provider.base_url +
      "  [" +
      key +
      "]  api=" +
      provider.api,
    )
    for model in provider.models {
      lines.push(
        "  - " +
        model.id +
        "  (" +
        model.name +
        ")" +
        (if model.reasoning { "  reasoning" } else { "" }) +
        (if model.context_window > 0 {
          "  ctx=" + model.context_window.to_string()
        } else {
          ""
        }),
      )
    }
  }
  if self.default_provider is Some(_) || self.default_model is Some(_) {
    lines.push(
      "default: " +
      self.default_provider.unwrap_or("-") +
      "/" +
      self.default_model.unwrap_or("-") +
      " thinking=" +
      self.default_thinking_level,
    )
  }
  lines.join("\n")
}
