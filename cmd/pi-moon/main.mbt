// pi-moon 的命令行入口。
//
// v0.3：provider 与工具都是真的 —— pi 配置 → OpenAI 兼容流式接口；八个内置工具
// 按 pi 的 `defaultTools` 语义开关（默认 read / bash / edit / write）。
// 命令行开关与 pi 的 `-t` / `-xt` / `--no-tools` 对齐。

///|
let usage : String = "pi-moon — Elm architecture agent core in MoonBit\n" +
  "\n" +
  "用法:\n" +
  "  pi-moon -p \"你的问题\"        跑一条就退出\n" +
  "  pi-moon --list-models          看 pi 配置里有什么 provider / model\n" +
  "  echo \"问题\" | pi-moon          从 stdin 读 prompt\n" +
  "\n" +
  "选项:\n" +
  "  -p, --prompt <text>      用户消息；省略则读 stdin\n" +
  "  -P, --provider <name>    覆盖 settings.json 的 defaultProvider\n" +
  "  -m, --model <id>         覆盖 settings.json 的 defaultModel\n" +
  "      --api-key <key>      覆盖 models.json / auth.json / 环境变量\n" +
  "      --thinking <level>   off | minimal | low | medium | high | xhigh | max\n" +
  "      --agent-dir <dir>    pi 配置目录（默认 PI_CODING_AGENT_DIR 或 ~/.pi/agent）\n" +
  "      --max-tokens <n>     请求里的 max_tokens（默认取模型目录里的 maxTokens）\n" +
  "      --temperature <f>    采样温度\n" +
  "      --idle-timeout <ms>  流上多久没数据算超时（默认 120000）\n" +
  "      --show-thinking      把思考增量打到 stderr\n" +
  "  -t, --tools <list>       替换默认工具选择（逗号分隔，例如 read,grep,ls）\n" +
  "  -xt, --exclude-tools <list>  从选择里去掉几个工具（逗号分隔）\n" +
  "      --no-tools           关闭全部内置工具\n" +
  "      --no-trace           不打印轨迹树\n" +
  "  -h, --help               显示这段文字"

///|
/// CLI 自己的参数错误。不借 argparse 是为了与 pi 的 `-P` / `-m` 完全对齐。
pub suberror CliError {
  MissingValue(flag~ : String)
  UnknownFlag(flag~ : String)
  BadNumber(value~ : String)
}

///|
pub fn CliError::to_string(self : CliError) -> String {
  match self {
    MissingValue(flag~) => "missing value for " + flag
    UnknownFlag(flag~) => "unknown flag: " + flag
    BadNumber(value~) => "not a number: " + value
  }
}

///|
extern "c" fn c_exit(code : Int32) -> Unit = "exit"

///|
struct CliArgs {
  mut prompt : String?
  mut provider : String?
  mut model : String?
  mut api_key : String?
  mut thinking : String?
  mut agent_dir : String?
  mut max_tokens : Int32?
  mut temperature : Double?
  mut idle_timeout_ms : Int32
  mut tools : String?
  mut exclude_tools : String?
  mut no_tools : Bool
  mut list_models : Bool
  mut show_thinking : Bool
  mut no_trace : Bool
  mut help : Bool
}

///|
fn default_args() -> CliArgs {
  {
    prompt: None,
    provider: None,
    model: None,
    api_key: None,
    thinking: None,
    agent_dir: None,
    max_tokens: None,
    temperature: None,
    idle_timeout_ms: 120000,
    tools: None,
    exclude_tools: None,
    no_tools: false,
    list_models: false,
    show_thinking: false,
    no_trace: false,
    help: false,
  }
}

///|
/// 用 JSON 的数字解析（核心库没有公开的 strconv）。
fn parse_number(value : String) -> Double raise CliError {
  let json = @json.parse(value) catch { _ => raise BadNumber(value~) }
  match json {
    Number(n, ..) => n
    _ => raise BadNumber(value~)
  }
}

///|
fn parse_int(value : String) -> Int32 raise CliError {
  parse_number(value).to_int()
}

///|
fn parse_double(value : String) -> Double raise CliError {
  parse_number(value)
}

///|
/// 取一个带值选项的值：`--flag value` 或 `--flag=value`。
fn option_value(
  argv : Array[String],
  index : Int32,
  inline : String?,
  flag : String,
) -> (String, Int32) raise CliError {
  match inline {
    Some(value) => (value, index)
    None => {
      let next = index + 1
      if next >= argv.length() {
        raise MissingValue(flag~)
      }
      (argv[next], next)
    }
  }
}

///|
/// 手写解析（参数不多，且需要与 pi 的 `-P` / `-m` 对齐）。
fn parse_args(argv : Array[String]) -> CliArgs raise CliError {
  let args = default_args()
  let mut index = 0
  while index < argv.length() {
    let arg = argv[index]
    let (flag, inline) = match arg.find("=") {
      Some(at) => (arg[:at].to_owned(), Some(arg[at + 1:].to_owned()))
      None => (arg, None)
    }
    match flag {
      "-h" | "--help" => args.help = true
      "--list-models" => args.list_models = true
      "--show-thinking" => args.show_thinking = true
      "--no-trace" => args.no_trace = true
      "-p" | "--prompt" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.prompt = Some(value)
        index = next
      }
      "-P" | "--provider" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.provider = Some(value)
        index = next
      }
      "-m" | "--model" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.model = Some(value)
        index = next
      }
      "--api-key" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.api_key = Some(value)
        index = next
      }
      "--thinking" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.thinking = Some(value)
        index = next
      }
      "--agent-dir" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.agent_dir = Some(value)
        index = next
      }
      "--max-tokens" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.max_tokens = Some(parse_int(value))
        index = next
      }
      "--temperature" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.temperature = Some(parse_double(value))
        index = next
      }
      "--idle-timeout" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.idle_timeout_ms = parse_int(value)
        index = next
      }
      "-t" | "--tools" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.tools = Some(value)
        index = next
      }
      "-xt" | "--exclude-tools" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.exclude_tools = Some(value)
        index = next
      }
      "--no-tools" => args.no_tools = true
      _ => raise UnknownFlag(flag~)
    }
    index = index + 1
  }
  args
}

///|
/// system prompt：与 pi 同形 —— 交代工作目录、列出**当前开启**的工具，再附上
/// 工具自己的使用提示（pi 的 `promptSnippet` / `promptGuidelines`）。
fn build_system_prompt(cwd : String, tool_names : Array[String]) -> String {
  let lines : Array[String] = [
    "You are pi-moon, a concise coding assistant running in a terminal.",
    "Answer in the user's language.",
    "",
    "Current working directory: " + cwd,
  ]
  if !tool_names.is_empty() {
    lines.push("")
    lines.push("Available tools:")
    for name in tool_names {
      match @tools.prompt_snippet(name) {
        Some(snippet) => lines.push("- " + name + ": " + snippet)
        None => ()
      }
    }
    let guidelines : Array[String] = []
    for name in tool_names {
      for guideline in @tools.prompt_guidelines(name) {
        guidelines.push("- " + guideline)
      }
    }
    if !guidelines.is_empty() {
      lines.push("")
      lines.push("Tool guidelines:")
      for guideline in guidelines {
        lines.push(guideline)
      }
    }
  }
  lines.join("\n")
}

///|
/// 逗号分隔的清单（CLI 的 `--tools` / `--exclude-tools`）。
fn split_tool_list(text : String) -> Array[String] {
  let out : Array[String] = []
  for item in text.split(",") {
    let name = item.trim().to_owned()
    if !name.is_empty() {
      out.push(name)
    }
  }
  out
}

///|
/// 本次会话开哪些工具：
///
/// 1. `--tools` 给了就**替换**（与 pi 的 `-t` 一致）；否则从
///    `settings.json` 的 `defaultTools` 解析（不配就是 pi 的默认四个）；
/// 2. `--no-tools` 再清空（内置工具全关）；
/// 3. `--exclude-tools` 最后剔除（与 pi 的 `-xt` 一致）。
fn selected_tools(config : @provider.PiConfig, args : CliArgs) -> Array[String] {
  let base = match args.tools {
    Some(list) => split_tool_list(list)
    None => @tools.resolve_tool_selection(config.default_tools)
  }
  let base = if args.no_tools { [] } else { base }
  match args.exclude_tools {
    Some(list) => @tools.exclude_tools(base, split_tool_list(list))
    None => base
  }
}

///|
/// 从配置解析结果造初始状态 —— 与 pi 同源的那几个字段（provider / model /
/// thinking / context window）在这里落进 state，之后 `/model` 之类的入口才能
/// 通过 action 改它们。
fn initial_state(
  resolved : @provider.ResolvedProvider,
  idle_timeout_ms : Int32,
  system_prompt : String,
  tool_names : Array[String],
) -> @state.AgentState {
  let cwd = match @env.current_dir() {
    Some(cwd) => cwd
    None => "."
  }
  @state.create_initial_state({
    system_prompt,
    provider_name: resolved.provider_name,
    model_id: resolved.model.id,
    thinking_level: resolved.thinking_level,
    tool_names,
    max_turns: None,
    max_llm_attempts: 2,
    llm_timeout_ms: idle_timeout_ms.to_int64(),
    session_id: "s-" + @env.now().to_string(),
    cwd,
    trace: None,
  })
}

///|
async fn seed(
  agent : @runtime.Agent,
  resolved : @provider.ResolvedProvider,
  system_prompt : String,
  tool_names : Array[String],
) -> Unit {
  agent.send(
    @action.PromptInit({
      system_prompt,
      tools: @tools.definitions_for(tool_names),
    }),
  )
  let compat = resolved.model.compat
  agent.send(
    @action.ModelInit({
      provider: resolved.provider_name,
      model_id: resolved.model.id,
      thinking_level: resolved.thinking_level,
      reasoning: resolved.model.reasoning,
      capabilities: {
        mid_convo_system_messages: false,
        mid_convo_tool_additions: false,
        developer_role: compat.supports_developer_role,
      },
      context_window: resolved.model.context_window,
    }),
  )
}

///|
async fn eprintln(text : String) -> Unit {
  @stdio.stderr.write(text + "\n") catch {
    _ => ()
  }
}

///|
async fn print_report(agent : @runtime.Agent, show_trace : Bool) -> Unit {
  let state = agent.state
  if show_trace {
    eprintln(@trace.render_tree(state.trace, max_width=0))
  }
  let usage_text = match state.usage {
    Some(usage) =>
      "tokens: " +
      usage.input_tokens.to_string() +
      " in / " +
      usage.output_tokens.to_string() +
      " out" +
      (if usage.cost_total > 0.0 {
        "  cost: " + usage.cost_total.to_string()
      } else {
        ""
      })
    None => "tokens: -"
  }
  let stop = match state.stop_cause {
    Some(cause) => @common.stop_cause_text(cause)
    None => "-"
  }
  eprintln(
    "[" +
    state.model.provider +
    "/" +
    state.model.model_id +
    "] " +
    stop +
    "  步=" +
    @trace.trace_stats(state.trace).steps.to_string() +
    "  " +
    usage_text,
  )
}

///|
async fn run(args : CliArgs) -> Unit {
  let config = @provider.load_pi_config(agent_dir?=args.agent_dir)
  for diagnostic in config.diagnostics {
    eprintln("[config] " + diagnostic)
  }
  if args.list_models {
    println(config.describe_models())
    return
  }
  let resolved = config.resolve(
    provider?=args.provider,
    model?=args.model,
    api_key?=args.api_key,
    thinking?=args.thinking,
  ) catch {
    err => {
      runtime_failure(err.to_string())
      return
    }
  }
  let prompt = match args.prompt {
    Some(prompt) => prompt
    None => {
      let text = @stdio.stdin.read_all() catch { _ => "" }
      text.text() catch {
        _ => ""
      }
    }
  }
  let prompt = prompt.trim(chars=" \t\r\n").to_owned()
  if prompt.is_empty() {
    usage_failure("missing value for -p/--prompt (or stdin)")
    return
  }
  let options : @provider.ChatOptions = {
    api_key: args.api_key,
    thinking_level: args.thinking,
    temperature: args.temperature,
    max_tokens: args.max_tokens,
    idle_timeout_ms: args.idle_timeout_ms,
  }
  let cwd = match @env.current_dir() {
    Some(cwd) => cwd
    None => "."
  }
  let tool_names = selected_tools(config, args)
  let system_prompt = build_system_prompt(cwd, tool_names)
  let hooks : @provider.ProviderHooks = {
    on_content: async fn(text) { @stdio.stdout.write(text) catch { _ => () } },
    on_thinking: async fn(text) {
      if args.show_thinking {
        @stdio.stderr.write(text) catch {
          _ => ()
        }
      }
    },
  }
  let table = @provider.effect_table_with_hooks(config, options, hooks)
  let agent = @runtime.Agent::new(
    initial_state(resolved, args.idle_timeout_ms, system_prompt, tool_names),
    table,
    fn() { @env.now().reinterpret_as_int64() },
  )
  // stdout 只留给模型回答：诊断与工具日志全走 stderr（先收集，跑完再打）。
  let notices : Array[String] = []
  agent.observe(action => {
    match action {
      @action.LlmFailed(data) =>
        notices.push("[llm failed: " + data.kind.name() + "] " + data.error)
      @action.ToolStart(call) => notices.push("[tool] " + call.name)
      _ => ()
    }
  })
  seed(agent, resolved, system_prompt, tool_names) catch {
    err => {
      runtime_failure(err.to_string())
      return
    }
  }
  eprintln(
    "[" +
    resolved.describe() +
    "]  tools=" +
    (if tool_names.is_empty() { "(none)" } else { tool_names.join(",") }) +
    "  按 Ctrl-C 中断（流式输出在 stdout，诊断在 stderr）",
  )
  agent.send(@action.UserMessage({ text: prompt, content: [], })) catch {
    err => {
      runtime_failure(err.to_string())
      return
    }
  }
  // 模型的回答可能没有结尾换行；这里补一个，但只在 stdout 上。
  @stdio.stdout.write("\n") catch {
    _ => ()
  }
  for notice in notices {
    eprintln(notice)
  }
  print_report(agent, !args.no_trace)
}

///|

///|
/// 参数错误：打用法。
async fn usage_failure(error : String) -> Unit {
  eprintln("error: " + error)
  eprintln("")
  eprintln(usage)
  c_exit(1)
}

///|
/// 运行期错误（配置 / 网络 / 预算）：只打一句，不糊一屏用法。
async fn runtime_failure(error : String) -> Unit {
  eprintln("error: " + error)
  c_exit(1)
}

///|
/// 不依赖方法解析，按变体取文案（suberror 的 `to_string` 在 `Error` 上会被
/// 当成 Debug 打印成限定名）。
fn cli_error_text(err : CliError) -> String {
  match err {
    MissingValue(flag~) => "missing value for " + flag
    UnknownFlag(flag~) => "unknown flag: " + flag
    BadNumber(value~) => "not a number: " + value
  }
}

///|
async fn main {
  let raw = @env.args()
  let argv : Array[String] = []
  for index in 1..<raw.length() {
    argv.push(raw[index])
  }
  let args = parse_args(argv) catch {
    err => {
      usage_failure(cli_error_text(err))
      return
    }
  }
  if args.help {
    println(usage)
    return
  }
  run(args)
}
