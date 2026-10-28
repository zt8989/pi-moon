// pi-moon 的命令行入口。
//
// v0.6：provider / 工具 / 会话 / 压缩都是真的 —— pi 配置 → OpenAI 兼容流式接口；
// 八个内置工具按 pi 的 `defaultTools` 语义开关；会话以 JSONL 落盘，用 `-s` / `-c`
// 恢复，`-i` 进多轮 REPL；`/compact` 或超阈值时把老对话换成一段摘要。

///|
let usage : String = "pi-moon — Elm architecture agent core in MoonBit\n" +
  "\n" +
  "用法:\n" +
  "  pi-moon                      全屏 TUI（默认落盘，可 -c 恢复）\n" +
  "  pi-moon -p \"你的问题\"        跑一条就退出\n" +
  "  pi-moon --list-models          看 pi 配置里有什么 provider / model\n" +
  "  echo \"问题\" | pi-moon          从 stdin 读 prompt（不启 TUI）\n" +
  "\n" +
  "选项:\n" +
  "  -p, --prompt <text>      用户消息；省略时：终端进 TUI，管道读 stdin\n" +
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
  "      --skill <path>       额外的技能文件或目录（可重复；默认扫\n" +
  "                             ~/.pi/agent/skills 与 <cwd>/.pi/skills）\n" +
  "      --show-tool-progress 把工具输出（取最后一行）实时打到 stderr\n" +
  "  -s, --session <file|id>  会话文件路径或会话 id（存在则恢复，否则新建）\n" +
  "  -c, --continue           恢复 sessions 目录里最新的会话\n" +
  "      --no-session         不落盘 / 不恢复\n" +
  "  -i, --interactive        全屏 TUI（与不带参数相同；管道输入时退回逐行 REPL）\n" +
  "                             TUI 里 /tools 换工具，/compact 压缩上下文，/exit 退出\n" +
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
  /// `--skill` 给的额外技能文件 / 目录（可重复）。
  skill_paths : Array[String]
  mut no_tools : Bool
  mut show_tool_progress : Bool
  mut session : String?
  mut continue_session : Bool
  mut no_session : Bool
  mut interactive : Bool
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
    skill_paths: [],
    no_tools: false,
    show_tool_progress: false,
    session: None,
    continue_session: false,
    no_session: false,
    interactive: false,
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
      "--skill" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.skill_paths.push(value)
        index = next
      }
      "--show-tool-progress" => args.show_tool_progress = true
      "-s" | "--session" => {
        let (value, next) = option_value(argv, index, inline, flag)
        args.session = Some(value)
        index = next
      }
      "-c" | "--continue" => args.continue_session = true
      "--no-session" => args.no_session = true
      "-i" | "--interactive" => args.interactive = true
      _ => raise UnknownFlag(flag~)
    }
    index = index + 1
  }
  args
}

///|
/// system prompt：与 pi 同形 —— 交代工作目录、列出**当前开启**的工具，再附上
/// 工具自己的使用提示（pi 的 `promptSnippet` / `promptGuidelines`）；
/// 末尾拼上项目上下文（AGENTS.md 一族）与技能清单两个段。
///
/// 技能清单只列「名字 + 描述 + 文件位置」，正文不进 prompt：任务对上号时模型
/// 自己用 read 去读。开不了任何读文件工具时清单也照发 —— 反正工具表是动的，
/// 这条会话中途开了 read 就能用。
fn build_system_prompt(
  cwd : String,
  tool_names : Array[String],
  context_files : Array[@context.ContextFile],
  skills : Array[@context.Skill],
) -> String {
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
    lines.push("")
    lines.push(
      "In addition to the tools above, you may have access to other custom tools depending on the project.",
    )
  }
  if !context_files.is_empty() {
    lines.push("")
    lines.push(@context.render_project_context(context_files))
  }
  // pi 的口径：read 优先，没有 read 就用 bash（能用 shell 读文件）。
  let read_tool = if tool_names.contains("read") {
    "read"
  } else if tool_names.contains("bash") {
    "bash"
  } else {
    ""
  }
  let skills_prompt = @context.render_skills_prompt(skills, read_tool)
  if !skills_prompt.is_empty() {
    lines.push("")
    lines.push(skills_prompt)
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
  session_id : String,
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
    session_id,
    cwd,
    trace: None,
  })
}

///|
/// 配置解析结果 → `ModelSpec`（`ModelInit` / `SessionRestored` 共用一个形状）。
fn resolved_model_spec(
  resolved : @provider.ResolvedProvider,
) -> @action.ModelSpec {
  {
    provider: resolved.provider_name,
    model_id: resolved.model.id,
    thinking_level: resolved.thinking_level,
    reasoning: resolved.model.reasoning,
    capabilities: {
      mid_convo_system_messages: false,
      mid_convo_tool_additions: false,
      developer_role: resolved.model.compat.supports_developer_role,
    },
    context_window: resolved.model.context_window,
  }
}

///|
async fn seed(
  agent : @runtime.Agent,
  system_prompt : String,
  tools : Array[@action.PromptToolDefinition],
  model : @action.ModelSpec,
) -> Unit {
  agent.send(@action.PromptInit({ system_prompt, tools, }))
  agent.send(@action.ModelInit(model))
}

///|
/// 会话目录：与 pi 的配置目录放在一起（`<agent dir>/sessions`）。
fn session_directory(config : @provider.PiConfig) -> String {
  config.agent_dir + "/sessions"
}

///|
/// 本次用哪份会话（与 pi 同构的两份文件）：
///
/// - `--no-session` → None（不读不写）
/// - `--session <路径或id>` → 恢复（路径直接用；id 先在 cwd 目录扫，再扫其它目录）
/// - `--continue` → cwd 目录里最新的那份；没有则新建
/// - 其余 → 新建（`<ISO 时间戳>_<id>.jsonl`，sessions/ 与 traces/ 各一份）
async fn resolve_session_paths(
  config : @provider.PiConfig,
  args : CliArgs,
  cwd : String,
) -> @session.SessionPaths? {
  if args.no_session {
    return None
  }
  match args.session {
    Some(target) => {
      // 先当路径：给的是文件路径就直接用（老习惯不变）。
      if (@sys.exists(target) catch { _ => false }) {
        let id = @session.session_id_from_path(target)
        return Some({ session: target, trace: target + ".trace", id, })
      }
      // 再当 id：找不到给明确错误（pi 同样拒绝静默换会话）。
      Some(@session.resolve_session_paths(config.agent_dir, cwd, target))
    }
    None =>
      if args.continue_session {
        // cwd 目录里最新的；没有就新建。
        let directory = session_directory(config) +
          "/" +
          @session.encode_cwd(cwd)
        match @session.latest_session(directory) {
          Some(path) => {
            let id = @session.session_id_from_path(path)
            Some({ session: path, trace: path + ".trace", id, })
          }
          None => Some(@session.new_session_paths(config.agent_dir, cwd, @sys.now()))
        }
      } else {
        Some(@session.new_session_paths(config.agent_dir, cwd, @sys.now()))
      }
  }
}

///|
/// 把当前 state 里还没落盘的部分追加进会话文件，并把 `TracePersisted` 送回环。
///
/// 写失败只报一次到 stderr：游标保留在旧 writer 里，下一次 turn 再重试，
/// 不让磁盘问题打断对话。
async fn persist(
  writer : @session.SessionWriter?,
  agent : @runtime.Agent,
) -> @session.SessionWriter? {
  match writer {
    None => None
    Some(writer) => {
      let (next, cursor) = writer.flush(agent.state) catch {
        err => {
          eprintln("[session] " + err.to_string())
          return Some(writer)
        }
      }
      agent.send(@action.TracePersisted(cursor)) catch {
        _ => ()
      }
      Some(next)
    }
  }
}

///|
async fn eprintln(text : String) -> Unit {
  @sys.write_err(text + "\n") catch {
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
/// 发起压缩前的快照。
///
/// 只靠 `compaction_epoch` 不够：没什么可压时 epoch 不会变，但那次压缩
/// **真的完成了**（而且会把 `last_compaction` 换成 0 条）。
struct CompactSnapshot {
  epoch : Int32
  record : @state.CompactionRecord?
  error_node : String?
}

///|
fn compact_snapshot(state : @state.AgentState) -> CompactSnapshot {
  {
    epoch: state.compaction_epoch,
    record: state.last_compaction,
    error_node: state.error_node_id,
  }
}

///|
/// 自动压缩：一个回合彻底停下来之后判一次。
///
/// 为什么可以放在这里而不是做成订阅器：`agent.send()` 在**环完全停下来**时
/// 才返回（队列空 + effect 队列空），那一刻正是唯一安全的压缩时机 —— 压缩要
/// 整份换掉 messages，而 LLM 还在流 / 工具还在跑时换，那条流回来就找不到
/// 自己的 toolCallId 了。
///
/// `enabled` 关掉的只是**自动**压缩：手动 `/compact` 照旧能用。
async fn maybe_auto_compact(agent : @runtime.Agent, enabled : Bool) -> Unit {
  if !enabled {
    return
  }
  let state = agent.state
  if state.phase != @common.Idle || state.compacting {
    return
  }
  let decision = @loop.decide_compaction(state, false)
  if !decision.should {
    return
  }
  let reason = match decision.reason {
    Some(reason) => reason
    None => return
  }
  let before = compact_snapshot(state)
  agent.send(@action.CompactRequest(reason)) catch {
    err => {
      eprintln("[compact] " + err.to_string())
      return
    }
  }
  report_compaction(agent, before)
}

///|
/// 压完（或压失败）之后的一句话。
///
/// `before` 是发起压缩那一刻的快照：epoch 变大了说明真的换过历史；
/// `last_compaction` 变了说明压了一次「0 条」（没什么可压）；两者都没变、
/// 但 error 节点换了，才是失败。三种都要说 —— 静默是这里最坏的行为
/// （用户以为压了，实际历史一个字没动）。
async fn report_compaction(
  agent : @runtime.Agent,
  before : CompactSnapshot,
) -> Unit {
  let state = agent.state
  if state.compaction_epoch > before.epoch {
    match state.last_compaction {
      Some(record) =>
        eprintln(
          "[compact] " +
          record.reason.text() +
          "：" +
          record.summarized_count.to_string() +
          " 条 → " +
          record.kept_count.to_string() +
          " 条（压缩前约 " +
          record.tokens_before.to_string() +
          " tokens）",
        )
      None => ()
    }
  } else if state.last_compaction != before.record {
    eprintln("[compact] 没什么可压的")
  } else if state.error_node_id != before.error_node &&
    state.stop_cause == Some(@common.CauseCompactError) {
    eprintln("[compact] 失败：" + state.error.unwrap_or("未知错误"))
  } else {
    eprintln("[compact] 没什么可压的")
  }
}

///|
/// 字典序比较。这个工具链里的 `String::compare` 不对称
/// （`"tdd".compare("recap")` 是 -1，反倒是 1），排序不能用；
/// 按 code unit 逐位比，横幅里的名单都是普通标识符，够用。
fn text_less(a : String, b : String) -> Bool {
  let la = a.length()
  let lb = b.length()
  let shared = if la < lb { la } else { lb }
  for index in 0..<shared {
    let ca = a[index]
    let cb = b[index]
    if ca != cb {
      return ca < cb
    }
  }
  la < lb
}

///|
/// 用 `text_less` 的稳定排序（见上，`sort_by` + `compare` 不可信）。
fn sort_text(items : Array[String]) -> Array[String] {
  let out = items.copy()
  let n = out.length()
  for i in 0..<n {
    for j in 0..<(n - 1 - i) {
      if text_less(out[j + 1], out[j]) {
        let t = out[j]
        out[j] = out[j + 1]
        out[j + 1] = t
      }
    }
  }
  out
}

///|
/// 启动横幅（pi 的启动画面同形）：进了 prompt 的上下文文件、技能名单、
/// prompt 模板命令、扩展清单，段间空行。横幅画在对话页顶部随对话滚走 ——
/// 技能与命令名要反复对照打，但不能永远占着首屏，这是两个要求的交集。
fn build_banner(
  cwd : String,
  context_files : Array[@context.ContextFile],
  skills : Array[@context.Skill],
  prompts : Array[@context.PromptTemplate],
  extension_labels : Array[String],
  diagnostics : Array[String],
  system_prompt : String,
) -> Array[String] {
  let home = match @env.get_env_vars().get("USERPROFILE") {
    Some(home) => home
    None => @env.get_env_vars().get("HOME").unwrap_or("")
  }
  let blocks : Array[String] = []
  // 恢复的会话 prompt 是旧的那份：报「进了 prompt 的文件」不能拿现在磁盘上
  // 的清单冒充 —— 模型这轮实际收到的是 system_prompt 里写着的那些。
  // 简化口径：新旧 prompt 都来自同一次装载（新会话或同一次启动），照实报；
  // 只有能从 prompt 文本里认出来时才报，认不出（旧会话的老格式）就报当前的。
  let in_prompt : Array[@context.ContextFile] = []
  for file in context_files {
    if system_prompt.contains("path=\"" + file.path + "\"") {
      in_prompt.push(file)
    }
  }
  let shown_files = if in_prompt.is_empty() &&
    system_prompt.contains("<project_context>") {
    context_files
  } else {
    in_prompt
  }
  if !shown_files.is_empty() {
    let labels : Array[String] = []
    for file in shown_files {
      labels.push(@context.context_display_path(file.path, cwd, home))
    }
    blocks.push("[Context] " + labels.join(", "))
    blocks.push("")
  }
  let names : Array[String] = []
  for skill in skills {
    if system_prompt.contains("<name>" + skill.name + "</name>") {
      names.push(skill.name)
    } else if !system_prompt.contains("<available_skills>") {
      // prompt 没有技能段（比如 --no-tools 连 read 都没开）：装了也照报，
      // 但标出来 —— 它没进这轮 prompt。
      names.push(skill.name + "*")
    }
  }
  if !names.is_empty() {
    blocks.push("[Skills] " + sort_text(names).join(", "))
    blocks.push("")
  }
  if !prompts.is_empty() {
    let commands : Array[String] = []
    for template in prompts {
      commands.push("/" + template.name)
    }
    blocks.push("[Prompts] " + sort_text(commands).join(", "))
    blocks.push("")
  }
  if !extension_labels.is_empty() {
    blocks.push("[Extensions] " + extension_labels.join(", "))
  }
  if !diagnostics.is_empty() {
    if !blocks.is_empty() {
      blocks.push("")
    }
    blocks.push("[Skill conflicts] " + diagnostics.join("; "))
  }
  blocks
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
  // 扩展：沙盒化装载。编译只发生在启动前的这一处，命中缓存时连 JS 引擎
  // 都不起（快照直接 memcpy 回去）。所以这段放在会话/prompt 之前。
  let ext_startup = @ext.prepare_at_startup(cwd, config.agent_dir)
  for diagnostic in ext_startup.diagnostics {
    eprintln("[ext] " + diagnostic)
  }
  if !ext_startup.names.is_empty() {
    eprintln("[ext] 已装载：" + ext_startup.names.join(", "))
  }
  // 新会话的「默认装载」：当前配置 + 当前工具选择 + 上下文文件 + 技能。
  // 恢复会话时这三份只在 fallback 里用 —— prompt 是装载时定下的，原样回来。
  let fallback_tool_names = selected_tools(config, args)
  let context_files = @context.load_context_files(cwd, config.agent_dir)
  let env = @env.get_env_vars()
  let home = match env.get("USERPROFILE") {
    Some(home) => home
    None => env.get("HOME").unwrap_or("")
  }
  let skill_registry = @context.load_skill_registry(
    cwd,
    config.agent_dir,
    home_dir=home,
    extra_paths=args.skill_paths,
  )
  for diagnostic in skill_registry.diagnostics {
    eprintln("[skills] " + diagnostic)
  }
  // prompt 模板（pi 的 /命令）：只进横幅与补全，展开在输入侧。
  let prompt_templates = @context.load_prompt_templates(cwd, config.agent_dir)
  for diagnostic in prompt_templates.1 {
    eprintln("[prompts] " + diagnostic)
  }
  let fallback_prompt : @action.PromptInitData = {
    system_prompt: build_system_prompt(
      cwd,
      fallback_tool_names,
      context_files,
      skill_registry.skills,
    ),
    tools: @tools.definitions_for(fallback_tool_names),
  }
  let fallback_model = resolved_model_spec(resolved)
  // 会话两份文件：存在就恢复，不存在就新建。
  let paths = resolve_session_paths(config, args, cwd)
  let session_id = match paths {
    Some(paths) => paths.id
    None => "s-" + @sys.now().to_string()
  }
  let loaded = match paths {
    Some(paths) =>
      @session.load_session(paths.session, session_id) catch {
        err => {
          eprintln("[session] " + err.to_string())
          None
        }
      }
    None => None
  }
  let prompt_data = match loaded {
    Some(loaded) =>
      match loaded.prompt {
        Some(prompt) => prompt
        None => fallback_prompt
      }
    None => fallback_prompt
  }
  let current_tools = match loaded {
    Some(loaded) =>
      match loaded.tools {
        Some(tools) => tools
        None => prompt_data.tools
      }
    None => prompt_data.tools
  }
  let model_spec = match loaded {
    Some(loaded) =>
      match loaded.model {
        Some(model) => model
        None => fallback_model
      }
    None => fallback_model
  }
  let active_tool_names : Array[String] = []
  for tool in current_tools {
    active_tool_names.push(tool.name)
  }
  // 界面状态要在 hooks **之前**建：Esc 的中断标志就住在它里面。
  let tui_mode = wants_tui(args)
  let tui : TuiState? = if tui_mode { Some(TuiState::new()) } else { None }
  // `on_tick` 需要读 agent 的队列（取回排队消息），而 agent 要等 effect 表建好
  // 才能建 —— 先留一个可后填的引用格。
  let bridge = TuiBridge::new()
  let hooks : @provider.ProviderHooks = {
    on_content: async fn(text) {
      // TUI 下不往 stdout 写字：整帧由渲染循环统一画，这里再写就成两路输出。
      if !tui_mode {
        @sys.write_out(text) catch {
          _ => ()
        }
      }
    },
    on_thinking: async fn(text) {
      if !tui_mode && args.show_thinking {
        @sys.write_err(text) catch {
          _ => ()
        }
      }
    },
    on_tool_progress: async fn(tool_name, blocks) {
      if !tui_mode && args.show_tool_progress {
        let text = @message.contents_text(blocks)
        let line = match text.rev_find("\n") {
          Some(index) => text[index + 1:].to_owned()
          None => text
        }
        let (line, _) = @tools.truncate_line(line, max_chars=100)
        @sys.write_err("\r\u{001b}[2K[" + tool_name + "] " + line) catch {
          _ => ()
        }
      }
    },
    should_abort: fn() {
      match tui {
        Some(tui) => tui.abort
        None => false
      }
    },
    on_tick: async fn(dispatch) {
      match tui {
        Some(tui) => flush_ui_actions(tui, dispatch, bridge)
        None => ()
      }
    },
  }
  let table = @provider.effect_table_with_hooks(config, options, hooks)
  let agent = @runtime.Agent::new(
    initial_state(
      resolved,
      args.idle_timeout_ms,
      prompt_data.system_prompt,
      active_tool_names,
      session_id,
    ),
    table,
    fn() { @sys.now() },
  )
  bridge.agent = Some(agent)
  bridge.skills = skill_registry.skills
  // stdout 只留给模型回答：诊断与工具日志全走 stderr（先收集，跑完再打）。
  let notices : Array[String] = []
  agent.observe(action => {
    // 每归约一条 action 就标脏：流式 token 到达时下一帧就会带上它。
    // 同时记下消息条数 —— 反馈卡的锚点（`at`）用它。
    match tui {
      Some(tui) => {
        tui.dirty = true
        tui.message_count = agent.state.messages.length()
      }
      None => ()
    }
    match action {
      @action.LlmFailed(data) =>
        notices.push("[llm failed: " + data.kind.name() + "] " + data.error)
      @action.ToolStart(call) => notices.push("[tool] " + call.name)
      _ => ()
    }
  })
  let mut writer : @session.SessionWriter? = match paths {
    Some(paths) =>
      Some(
        match loaded {
          Some(loaded) =>
            @session.SessionWriter::restored(paths.session, paths.trace, loaded)
          None =>
            @session.SessionWriter::new(paths.session, paths.trace, session_id)
        },
      )
    None => None
  }
  // 恢复或装载。
  match loaded {
    Some(loaded) => {
      agent.send(
        @action.SessionRestored({
          prompt: prompt_data,
          tools: current_tools,
          model: model_spec,
          messages: loaded.messages,
          trace: loaded.trace,
          persisted_seq: loaded.persisted_seq,
        }),
      ) catch {
        err => {
          runtime_failure(err.to_string())
          return
        }
      }
      eprintln(
        "[session] 恢复 " +
        paths.unwrap_or({ session: "(内存)", trace: "", id: session_id, }).session +
        "（" +
        loaded.messages.length().to_string() +
        " 条消息 / " +
        loaded.trace.order.length().to_string() +
        " 个节点）",
      )
    }
    None => {
      seed(agent, prompt_data.system_prompt, current_tools, model_spec) catch {
        err => {
          runtime_failure(err.to_string())
          return
        }
      }
      writer = persist(writer, agent)
    }
  }
  // 压缩参数读 `settings.json` 的 `compaction` 段（与 pi 同一份配置）。
  agent.send(@action.CompactSettingsChanged(config.compaction)) catch {
    err => {
      runtime_failure(err.to_string())
      return
    }
  }
  if !tui_mode {
    eprintln(
      "[" +
      agent.state.provider_name +
      "/" +
      agent.state.model_id +
      " (thinking=" +
      agent.state.thinking_level +
      ")]  tools=" +
      (if active_tool_names.is_empty() {
        "(none)"
      } else {
        active_tool_names.join(",")
      }) +
      "  session=" +
      (match paths {
        Some(paths) => paths.id
        None => "(不落盘)"
      }) +
      "  按 Ctrl-C 中断（流式输出在 stdout，诊断在 stderr）",
    )
  }
  // 交互模式：终端上没人给 `-p` 就是全屏 TUI（与 pi 的默认行为一致）。
  // 管道进来的 stdin 不算交互（`wants_tui` 只问 stdin 本身）。
  if tui_mode {
    match tui {
      Some(tui) => {
        tui.writer = writer
        tui.banner = build_banner(
          cwd,
          context_files,
          skill_registry.skills,
          prompt_templates.0,
          ext_startup.labels,
          skill_registry.diagnostics,
          prompt_data.system_prompt,
        )
        run_tui(
          agent,
          tui,
          config,
          config.compaction.enabled,
          match paths {
            Some(paths) => paths.session
            None => ""
          },
          match paths {
            Some(paths) => paths.id
            None => ""
          },
          skill_registry.skills,
        )
        return
      }
      None => ()
    }
  }
  // 一次性 prompt：`-p` 给了就跑；没给且不是交互模式则把 stdin 整段当 prompt。
  let one_shot : String? = match args.prompt {
    Some(prompt) => Some(prompt.trim(chars=" \t\r\n").to_owned())
    None =>
      if args.interactive {
        None
      } else {
        let text = @sys.read_stdin_all() catch { _ => "" }
        Some(text.trim(chars=" \t\r\n").to_owned())
      }
  }
  match one_shot {
    Some(text) =>
      if text.is_empty() {
        usage_failure("missing value for -p/--prompt (or stdin)")
        return
      } else {
        let text = expand_skill_input(text, skill_registry.skills) catch {
          err => {
            eprintln("[skill] " + err.to_string())
            return
          }
        }
        agent.send(@action.UserMessage({ text, content: [], })) catch {
          err => {
            runtime_failure(err.to_string())
            return
          }
        }
        @sys.write_out("\n") catch {
          _ => ()
        }
        maybe_auto_compact(agent, config.compaction.enabled)
        writer = persist(writer, agent)
      }
    None => ()
  }
  // 多轮 REPL。
  if args.interactive {
    while true {
      @sys.write_err("\n> ") catch {
        _ => ()
      }
      let line = @sys.read_stdin_until("\n") catch { _ => None }
      let line = match line {
        Some(line) => line
        None => break
      }
      let text = line.trim(chars=" \t\r\n").to_owned()
      if text.is_empty() {
        continue
      }
      if text == "/tools" {
        eprintln(
          "tools: " +
          (if agent.state.tool_names.is_empty() {
            "(none)"
          } else {
            agent.state.tool_names.join(",")
          }),
        )
        continue
      }
      if text.has_prefix("/tools ") {
        let list = text[7:].trim().to_owned()
        let names = if list == "none" || list == "off" {
          []
        } else {
          split_tool_list(list)
        }
        let tools = @tools.definitions_for(names)
        let applied : Array[String] = []
        for tool in tools {
          applied.push(tool.name)
        }
        agent.send(@action.ToolsChanged(tools)) catch {
          err => {
            eprintln("[error] " + err.to_string())
            break
          }
        }
        eprintln(
          "tools -> " +
          (if applied.is_empty() { "(none)" } else { applied.join(",") }) +
          "（下一轮请求起生效）",
        )
        // 立刻落盘：用户可能改完工具就退出，下一轮不一定发生。
        writer = persist(writer, agent)
        continue
      }
      if text == "/exit" || text == "/quit" {
        break
      }
      if text == "/compact" {
        let before = compact_snapshot(agent.state)
        agent.send(@action.CompactRequest(@compact.Manual)) catch {
          err => {
            eprintln("[error] " + err.to_string())
            break
          }
        }
        report_compaction(agent, before)
        // 压缩换过历史：立刻落盘，否则用户压完就退出时文件还是旧的。
        writer = persist(writer, agent)
        continue
      }
      if text == "/continue" {
        agent.send(@action.TurnContinue) catch {
          err => {
            eprintln("[error] " + err.to_string())
            break
          }
        }
      } else {
        let text = expand_skill_input(text, skill_registry.skills) catch {
          err => {
            eprintln("[error] " + err.to_string())
            break
          }
        }
        agent.send(@action.UserMessage({ text, content: [], })) catch {
          err => {
            eprintln("[error] " + err.to_string())
            break
          }
        }
      }
      @sys.write_out("\n") catch {
        _ => ()
      }
      maybe_auto_compact(agent, config.compaction.enabled)
      writer = persist(writer, agent)
    }
  }
  // 工具进度是原地刷新的一行；收尾时擦掉它，别把后面的报告弄脏。
  if args.show_tool_progress {
    @sys.write_err("\r\u{001b}[2K") catch {
      _ => ()
    }
  }
  writer = persist(writer, agent)
  for notice in notices {
    eprintln(notice)
  }
  print_report(agent, !args.no_trace)
  // 恢复提示：同 TUI 退出 —— 真落过盘、说过话才提。
  match paths {
    Some(paths) =>
      if agent.state.messages.length() > 0 {
        eprintln("To resume this session: pi-moon --session " + paths.id)
      }
    None => ()
  }
  let _ = writer
}

///|

///|
/// 参数错误：打用法。
async fn usage_failure(error : String) -> Unit {
  eprintln("error: " + error)
  eprintln("")
  eprintln(usage)
  @sys.exit_with(1)
}

///|
/// 运行期错误（配置 / 网络 / 预算）：只打一句，不糊一屏用法。
async fn runtime_failure(error : String) -> Unit {
  eprintln("error: " + error)
  @sys.exit_with(1)
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
  let argv = @sys.cli_args()
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
  run(args) catch {
    err => runtime_failure(err.to_string())
  }
}
