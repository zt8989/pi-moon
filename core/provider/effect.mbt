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
  /// 用户按了 Esc。
  ///
  /// 中断必须由 effect 自己发起：`Dispatch.send()` 是同步的，界面没有别的办法
  /// 在一条流跑到一半时把「停止」送进环里。effect 在分片边界查这个谓词，
  /// 真就回一条 `llm.failed(kind=aborted)` —— 半截输出不会进 messages。
  ///
  /// 默认恒为 `false`：一次性 CLI 与测试的行为一个字都不变。
  should_abort : () -> Bool
}

///|
pub fn noop_hooks() -> ProviderHooks {
  {
    on_content: async fn(_) { () },
    on_thinking: async fn(_) { () },
    on_tool_progress: async fn(_, _) { () },
    should_abort: fn() { false },
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
    // 中断在**分片边界**生效：已经收到的字照常进 state（界面看得见它停在哪），
    // 但这条 assistant 消息不会落进 messages。
    if (hooks.should_abort)() {
      dispatch.send(abort_failure())
      return
    }
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
/// 用户中断的 `llm.failed`。`Aborted` 不可重试，因此它一定收工。
fn abort_failure() -> @action.AgentAction {
  @action.LlmFailed({
    error: "用户中断",
    kind: @common.Aborted,
    node_id: None,
    cause: Some(@common.CauseUser),
  })
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
  let mut index = 0
  while index < calls.length() {
    // 工具批次里的中断点：正在跑的那一条**不打断**（进程已经起来了，硬停会留下
    // 半截文件），从下一条起补失败结果再收工 —— 每个 toolCall 都必须有结果，
    // 否则下一轮请求就是非法消息序列。
    if (hooks.should_abort)() {
      while index < calls.length() {
        let skipped = calls[index]
        dispatch.send(
          @action.ToolResult({
            tool_call_id: skipped.id,
            tool_name: skipped.name,
            content: [@message.Text("用户中断，未执行")],
            is_error: true,
            timestamp: @env.now().reinterpret_as_int64(),
          }),
        )
        index = index + 1
      }
      dispatch.send(abort_failure())
      return
    }
    let call = calls[index]
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
    index = index + 1
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
priv struct SummaryResult {
  text : String
  usage : @message.Usage?
}

///|
/// 组一个摘要预算：`ratio` 是 reserve 的百分比，再按模型的 max_tokens 封顶。
fn summary_budget(
  reserve_tokens : Int32,
  model_max : Int32?,
  ratio : Int32,
) -> Int32 {
  let raw = reserve_tokens * ratio / 100
  let capped = match model_max {
    Some(max) => if max > 0 && max < raw { max } else { raw }
    None => raw
  }
  if capped < 1 {
    1
  } else {
    capped
  }
}

///|
fn part_text(part : @message.AssistantPart) -> String {
  let builder = StringBuilder()
  for block in part.content {
    match block {
      @message.Text(text) => builder.write_string(text)
      _ => ()
    }
  }
  builder.to_string().trim().to_owned()
}

///|
/// 打一次摘要请求（流式收完，但不往环上发 delta）。
///
/// 失败用 `Err` 返回而不是 dispatch：调用方要先把两次摘要（历史 + 半轮前缀）
/// 都拿到才 dispatch 一条 `compact.done`。
async fn summarization_call(
  resolved : ResolvedProvider,
  system_prompt : String,
  user_text : String,
  options : ChatOptions,
  max_tokens : Int32,
) -> Result[SummaryResult, String] {
  let message : @message.Message = @message.UserMsg({
    content: [@message.Text(user_text)],
    timestamp: @env.now().reinterpret_as_int64(),
    compaction_summary: false,
    tokens_before: 0,
  })
  let body = build_summary_request_body(
    resolved,
    system_prompt,
    [message],
    max_tokens,
  ).stringify()
  let settings = resolved.faceoff_settings(system_prompt)
  let url = settings.chat_completions_url()
  let headers : @http.Headers = Map([])
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "text/event-stream"
  if !resolved.api_key.is_empty() {
    headers["Authorization"] = "Bearer " + resolved.api_key
  }
  let client = @http.post_stream(url, headers~) catch {
    err => return Err("transport error: " + err.to_string())
  }
  defer client.close()
  let response = try {
    client.write(body)
    client.end_request()
  } catch {
    err => return Err("transport error: " + err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    let text = client.read_all().text() catch { _ => "" }
    return Err("http " + response.code.to_string() + ": " + truncate(text, 400))
  }
  let accumulator = StreamAccumulator::new()
  while !accumulator.done {
    let line = read_sse_line(client, options.idle_timeout_ms) catch {
      @async.TimeoutError =>
        return Err(
          "summary idle timeout after " +
          options.idle_timeout_ms.to_string() +
          "ms",
        )
      err => return Err("stream error: " + err.to_string())
    }
    let line = match line {
      Some(line) => line
      None => break
    }
    let _ = accumulator.apply_line(line)
  }
  if accumulator.is_truncated() {
    return Err("stream ended before finish/[DONE]")
  }
  let part = accumulator.to_assistant_part(resolved.model)
  // 半截摘要绝对不能进 messages：模型会拿着残缺的「进度」继续干，
  // 比不压糟糕得多。pi 的 `getSummarizationFailure` 专门拦这一条。
  if part.stop_reason == "length" {
    return Err("generation hit the token cap and the summary is incomplete")
  }
  if !part.tool_calls().is_empty() {
    return Err("summarization attempted to call a tool")
  }
  let text = part_text(part)
  if text.is_empty() {
    return Err("summary was empty")
  }
  Ok({ text, usage: part.usage, })
}

///|
fn merge_unique(target : Array[String], extra : Array[String]) -> Unit {
  for item in extra {
    if !target.contains(item) {
      target.push(item)
    }
  }
}

///|
fn combine_usage(
  left : @message.Usage?,
  right : @message.Usage?,
) -> @message.Usage? {
  match (left, right) {
    (Some(a), Some(b)) =>
      Some({
        input_tokens: a.input_tokens + b.input_tokens,
        output_tokens: a.output_tokens + b.output_tokens,
        total_tokens: a.total_tokens + b.total_tokens,
        cost_total: a.cost_total + b.cost_total,
      })
    (Some(a), None) => Some(a)
    (None, Some(b)) => Some(b)
    (None, None) => None
  }
}

///|
/// 压缩的真正干活处：读 `state.compact_plan` → 生成摘要 → dispatch `compact.done`。
///
/// effect 不改 state（本项目的不变式）：它只发 action，换历史是迁移的事。
async fn run_compact_effect(
  config : PiConfig,
  options : ChatOptions,
  state : @state.AgentState,
  dispatch : @runtime.Dispatch,
) -> Unit {
  let plan = match state.compact_plan {
    Some(plan) => plan
    None => {
      // 正常情况下接线已经用 `compact.done` 处理了「没什么可压」，走到这里
      // 说明状态不对 —— 回一条空结果，别让 compacting 卡死。
      dispatch.send(
        @action.CompactDone({
          messages: state.messages,
          summary: "",
          tokens_before: 0,
          summarized_count: 0,
          kept_count: state.messages.length(),
          usage: None,
        }),
      )
      return
    }
  }
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
      dispatch.send(@action.CompactFailed({ error: err.to_string(), }))
      return
    }
  }
  // 窗口小的模型要夹紧 reserve / keepRecent（理由见 `effective_settings`）。
  let settings = @compact.effective_settings(
    state.compact_settings,
    state.model.context_window,
  )
  let history_budget = summary_budget(
    settings.reserve_tokens,
    resolved.model.max_tokens,
    80,
  )
  let previous = @compact.last_summary_text(plan.summarized)
  let history = summarization_call(
    resolved,
    @compact.summarization_system_prompt(),
    @compact.summarize_prompt(plan.summarized, previous),
    options,
    history_budget,
  )
  let history_result = match history {
    Ok(result) => result
    Err(error) => {
      dispatch.send(
        @action.CompactFailed({
          error: "上下文压缩失败（对话原样保留）：" + error,
        }),
      )
      return
    }
  }
  let mut summary = history_result.text
  let mut usage = history_result.usage
  // 切点落在一轮中间：前半轮另做一段摘要并拼在后面（pi 的合并形状）。
  if plan.is_split_turn && !plan.turn_prefix.is_empty() {
    let prefix_budget = summary_budget(
      settings.reserve_tokens,
      resolved.model.max_tokens,
      50,
    )
    let prefix = summarization_call(
      resolved,
      @compact.summarization_system_prompt(),
      @compact.turn_prefix_prompt(plan.turn_prefix),
      options,
      prefix_budget,
    )
    match prefix {
      Ok(result) => {
        summary = summary +
          "\n\n---\n\n**Turn Context (split turn):**\n\n" +
          result.text
        usage = combine_usage(usage, result.usage)
      }
      Err(error) => {
        dispatch.send(
          @action.CompactFailed({
            error: "上下文压缩失败（对话原样保留）：" + error,
          }),
        )
        return
      }
    }
  }
  // 文件清单附在摘要末尾：压缩之后模型仍要知道这个会话碰过什么文件。
  let (read, modified) = @compact.file_lists(plan.summarized)
  let (prefix_read, prefix_modified) = @compact.file_lists(plan.turn_prefix)
  let read_all : Array[String] = []
  let modified_all : Array[String] = []
  merge_unique(read_all, read)
  merge_unique(read_all, prefix_read)
  merge_unique(modified_all, modified)
  merge_unique(modified_all, prefix_modified)
  summary = summary + @compact.format_file_operations(read_all, modified_all)
  let summary_message = @compact.build_summary_message(
    summary,
    plan.tokens_before,
    @env.now().reinterpret_as_int64(),
  )
  let messages : Array[@message.Message] = [summary_message]
  for message in plan.kept {
    messages.push(message)
  }
  dispatch.send(
    @action.CompactDone({
      messages,
      summary,
      tokens_before: plan.tokens_before,
      summarized_count: plan.summarized.length(),
      kept_count: plan.kept.length(),
      usage,
    }),
  )
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
    run_compact: async fn(state, dispatch) {
      run_compact_effect(config, options, state, dispatch)
    },
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
