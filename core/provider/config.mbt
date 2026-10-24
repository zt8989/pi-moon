// pi 配置的读取与解析。
//
// 只认 OpenAI 兼容的线格式（`openai-completions`）；遇到 `openai-responses` /
// `anthropic-messages` 之类会给出明确的错误，而不是发出一个必然失败的请求。

///|
pub(all) struct ModelCompat {
  /// `openai` / `deepseek` / `qwen` / `zai` / `openrouter` / `together` /
  /// `string-thinking`，空串表示按 baseUrl 猜。
  thinking_format : String
  /// `max_tokens`（默认）或 `max_completion_tokens`。
  max_tokens_field : String
  /// 能不能发 `reasoning_effort`。
  supports_reasoning_effort : Bool
  /// 流里能不能要 `stream_options.include_usage`。
  supports_usage_in_streaming : Bool
  /// DeepSeek 一类：assistant 历史里必须带 `reasoning_content`。
  requires_reasoning_content : Bool
  /// 能不能发 `developer` role（否则统一用 system）。
  supports_developer_role : Bool
  /// 一些网关要求 tool 消息带 `name`。
  requires_tool_result_name : Bool
} derive(Eq, Debug)

///|
pub let default_compat : ModelCompat = {
  thinking_format: "",
  max_tokens_field: "max_tokens",
  supports_reasoning_effort: true,
  supports_usage_in_streaming: true,
  requires_reasoning_content: false,
  supports_developer_role: false,
  requires_tool_result_name: false,
}

///|
pub(all) struct PiModelInfo {
  id : String
  name : String
  api : String
  /// 单模型覆盖 provider 的 baseUrl（pi 的内置目录里每个模型都带一份）。
  base_url : String?
  reasoning : Bool
  context_window : Int32
  max_tokens : Int32?
  /// thinking level → 该家要的字符串；显式 `null` 表示这一档不支持。
  thinking_level_map : Map[String, String?]
  cost_input : Double
  cost_output : Double
  compat : ModelCompat
}

///|
pub(all) struct PiProviderInfo {
  name : String
  base_url : String
  api : String
  /// models.json 里的 `apiKey`（凭证优先级最高的一档）。
  api_key : String?
  models : Array[PiModelInfo]
}

///|
pub(all) struct PiConfig {
  providers : Array[PiProviderInfo]
  default_provider : String?
  default_model : String?
  default_thinking_level : String
  /// `settings.json` 的 `defaultTools`（没配就是 None）。
  ///
  /// 语义与 pi 的 `resolveDefaultTools()` 一致（见 `core/tools` 的
  /// `resolve_tool_selection`）：不带前缀的名字替换默认合集，`+name` / `-name`
  /// 在结果上增删。这里只负责**读**，不开工。
  default_tools : Array[String]?
  /// `settings.json` 的 `compaction` 段（pi 的官方键名，两边同一份配置）。
  /// 没配就是 pi 的默认值（enabled=true, reserve=16384, keepRecent=20000）。
  compaction : @compact.Settings
  /// provider → api key（auth.json）。
  auth : Map[String, String]
  env : Map[String, String]
  agent_dir : String
  /// 读取配置时遇到的问题（坏 JSON、读不动…）。CLI 会打到 stderr。
  /// 缺文件不在这里 —— 那不算错误。
  diagnostics : Array[String]
}

///|
pub(all) suberror ProviderError {
  UnknownProvider(String)
  UnknownModel(provider~ : String, model~ : String)
  UnsupportedApi(api~ : String, provider~ : String)
  MissingBaseUrl(provider~ : String)
  /// 配置文件读不出来 / 形状不对。
  Config(message~ : String)
}

///|
pub fn ProviderError::to_string(self : ProviderError) -> String {
  match self {
    UnknownProvider(name) =>
      "unknown provider `" +
      name +
      "`: not in models.json and not a built-in OpenAI-compatible provider"
    UnknownModel(provider~, model~) =>
      "unknown model `" + model + "` for provider `" + provider + "`"
    UnsupportedApi(api~, provider~) =>
      "provider `" +
      provider +
      "` uses api `" +
      api +
      "`; this port only speaks OpenAI-compatible `openai-completions`"
    MissingBaseUrl(provider~) =>
      "provider `" + provider + "` has no baseUrl (set it in models.json)"
    Config(message~) => "config error: " + message
  }
}

// ─── 小工具：从 Json 里安全取值 ───

///|
fn jstring(value : Json?) -> String? {
  match value {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn jbool(value : Json?) -> Bool? {
  match value {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn jnumber(value : Json?) -> Double? {
  match value {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn jint(value : Json?) -> Int32? {
  match jnumber(value) {
    Some(n) => Some(n.to_int())
    None => None
  }
}

///|
fn jobject(value : Json?) -> Map[String, Json]? {
  match value {
    Some(Object(obj)) => Some(obj)
    _ => None
  }
}

///|
fn field_string(obj : Map[String, Json], key : String) -> String? {
  jstring(obj.get(key))
}

///|
/// 字符串数组：只收字符串元素（pi 的 schema 也是这个口径）。
fn field_string_array(obj : Map[String, Json], key : String) -> Array[String]? {
  match obj.get(key) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(value) => out.push(value)
          _ => ()
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn field_bool(obj : Map[String, Json], key : String, fallback : Bool) -> Bool {
  match jbool(obj.get(key)) {
    Some(value) => value
    None => fallback
  }
}

///|
fn field_int(obj : Map[String, Json], key : String, fallback : Int32) -> Int32 {
  match jint(obj.get(key)) {
    Some(value) => value
    None => fallback
  }
}

///|
fn field_double(
  obj : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double {
  match jnumber(obj.get(key)) {
    Some(value) => value
    None => fallback
  }
}

// ─── 兼容性推断（与 pi-ai 的 detectCompat 同一个方向，只保留本内核用得到的项）───

///|
fn contains_any(text : String, needles : Array[String]) -> Bool {
  for needle in needles {
    if text.contains(needle) {
      return true
    }
  }
  false
}

///|
fn detect_thinking_format(provider : String, base_url : String) -> String {
  let probe = provider.to_lower() + " " + base_url.to_lower()
  if contains_any(probe, ["deepseek"]) {
    "deepseek"
  } else if contains_any(probe, ["dashscope", "aliyuncs", "qwen"]) {
    "qwen"
  } else if contains_any(probe, ["openrouter"]) {
    "openrouter"
  } else if contains_any(probe, ["bigmodel", "zai", "zhipu"]) {
    "zai"
  } else if contains_any(probe, ["together"]) {
    "together"
  } else {
    "openai"
  }
}

///|
fn parse_compat(
  provider : String,
  base_url : String,
  obj : Map[String, Json],
) -> ModelCompat {
  let compat = match jobject(obj.get("compat")) {
    Some(compat) => compat
    None => Map([])
  }
  let detected_format = detect_thinking_format(provider, base_url)
  let detected_effort = !contains_any(
    provider.to_lower() + " " + base_url.to_lower(),
    ["zai", "bigmodel", "moonshot", "together"],
  )
  {
    thinking_format: match field_string(compat, "thinkingFormat") {
      Some(format) => format
      None => detected_format
    },
    max_tokens_field: match field_string(compat, "maxTokensField") {
      Some(field) => field
      None => "max_tokens"
    },
    supports_reasoning_effort: field_bool(
      compat, "supportsReasoningEffort", detected_effort,
    ),
    supports_usage_in_streaming: field_bool(
      compat, "supportsUsageInStreaming", true,
    ),
    requires_reasoning_content: field_bool(
      compat, "requiresReasoningContentOnAssistantMessages", false,
    ),
    supports_developer_role: field_bool(compat, "supportsDeveloperRole", false),
    requires_tool_result_name: field_bool(
      compat, "requiresToolResultName", false,
    ),
  }
}

///|
fn parse_thinking_level_map(obj : Map[String, Json]) -> Map[String, String?] {
  let out : Map[String, String?] = Map([])
  match jobject(obj.get("thinkingLevelMap")) {
    Some(levels) =>
      for key, value in levels {
        out[key] = match value {
          String(text) => Some(text)
          Null => None
          _ => None
        }
      }
    None => ()
  }
  out
}

///|
fn parse_model(
  provider : String,
  base_url : String,
  provider_api : String,
  fallback_id : String,
  obj : Map[String, Json],
) -> PiModelInfo {
  let id = match field_string(obj, "id") {
    Some(id) => id
    None => fallback_id
  }
  let name = match field_string(obj, "name") {
    Some(name) => name
    None => id
  }
  let api = match field_string(obj, "api") {
    Some(api) => api
    None => provider_api
  }
  let cost = match jobject(obj.get("cost")) {
    Some(cost) => cost
    None => Map([])
  }
  {
    id,
    name,
    api,
    base_url: field_string(obj, "baseUrl"),
    reasoning: field_bool(obj, "reasoning", false),
    context_window: field_int(obj, "contextWindow", 0),
    max_tokens: match jint(obj.get("maxTokens")) {
      Some(max) => Some(max)
      None => None
    },
    thinking_level_map: parse_thinking_level_map(obj),
    cost_input: field_double(cost, "input", 0.0),
    cost_output: field_double(cost, "output", 0.0),
    compat: parse_compat(provider, base_url, obj),
  }
}

///|
fn parse_models(
  provider : String,
  base_url : String,
  provider_api : String,
  value : Json?,
) -> Array[PiModelInfo] {
  let models : Array[PiModelInfo] = []
  match value {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(obj) =>
            models.push(parse_model(provider, base_url, provider_api, "", obj))
          _ => ()
        }
      }
    Some(Object(entries)) =>
      // 旧形状：{ "<id>": { ... } }
      for id, item in entries {
        match item {
          Object(obj) =>
            models.push(parse_model(provider, base_url, provider_api, id, obj))
          _ => ()
        }
      }
    _ => ()
  }
  models
}

///|
fn parse_provider(name : String, obj : Map[String, Json]) -> PiProviderInfo {
  let base_url = match field_string(obj, "baseUrl") {
    Some(url) => url
    None => ""
  }
  let api = match field_string(obj, "api") {
    Some(api) => api
    None => "openai-completions"
  }
  {
    name,
    base_url,
    api,
    api_key: field_string(obj, "apiKey"),
    models: parse_models(name, base_url, api, obj.get("models")),
  }
}

///|
fn parse_providers(json : Json) -> Array[PiProviderInfo] {
  let providers : Array[PiProviderInfo] = []
  let root = match json {
    Object(obj) => obj
    _ => return providers
  }
  // 现行形状：{ "providers": { "<name>": {...} } }
  // 旧形状就是根对象本身；两种都读。
  let table = match jobject(root.get("providers")) {
    Some(providers) => providers
    None => root
  }
  for name, value in table {
    match value {
      Object(obj) =>
        // 旧根对象里可能混着 version 之类的标量，只认带对象值的条目。
        providers.push(parse_provider(name, obj))
      _ => ()
    }
  }
  providers
}

///|
fn parse_auth(json : Json?) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  match jobject(json) {
    Some(root) =>
      for name, value in root {
        match value {
          Object(obj) =>
            match field_string(obj, "key") {
              Some(key) => out[name] = key
              None => ()
            }
          String(key) => out[name] = key
          _ => ()
        }
      }
    None => ()
  }
  out
}

///|
/// `~/.pi/agent`（或 `PI_CODING_AGENT_DIR` 指到的那一份）。
pub fn resolve_agent_dir(env : Map[String, String]) -> String {
  match env.get("PI_CODING_AGENT_DIR") {
    Some(dir) =>
      if dir.is_empty() {
        default_agent_dir(env)
      } else {
        trim_trailing_slash(dir)
      }
    None => default_agent_dir(env)
  }
}

///|
fn default_agent_dir(env : Map[String, String]) -> String {
  let home = match env.get("USERPROFILE") {
    Some(home) => Some(home)
    None => env.get("HOME")
  }
  let home = match home {
    Some(home) => home
    None => "."
  }
  trim_trailing_slash(home) + "/.pi/agent"
}

///|
fn trim_trailing_slash(path : String) -> String {
  if path.length() > 1 && (path.has_suffix("/") || path.has_suffix("\\")) {
    path[:path.length() - 1].to_owned()
  } else {
    path
  }
}

///|
async fn read_json_file(path : String, diagnostics : Array[String]) -> Json? {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let data = @fs.read_file(path) catch {
    err => {
      diagnostics.push(path + ": " + err.to_string())
      return None
    }
  }
  let text = data.text() catch {
    err => {
      diagnostics.push(path + ": " + err.to_string())
      return None
    }
  }
  let parsed = @json.parse(text) catch {
    err => {
      diagnostics.push(path + ": invalid JSON: " + err.to_string())
      return None
    }
  }
  Some(parsed)
}

///|
/// 读 `settings.json` 的 `compaction` 段。
///
/// 只读不写：真正的压缩参数也在这里定，于是「两边用同一份配置」不是一句口号 ——
/// 在 pi 里改了阈值，pi-moon 下一次启动就跟着变。
fn parse_compaction(settings : Map[String, Json]) -> @compact.Settings {
  let defaults = @compact.default_settings()
  let obj = match settings.get("compaction") {
    Some(Object(obj)) => obj
    _ => Map([])
  }
  {
    enabled: field_bool(obj, "enabled", defaults.enabled),
    reserve_tokens: field_int(obj, "reserveTokens", defaults.reserve_tokens),
    keep_recent_tokens: field_int(
      obj,
      "keepRecentTokens",
      defaults.keep_recent_tokens,
    ),
  }
}

///|
/// 读 pi 的三份配置。缺文件不是错误：`settings.json` 没有就用默认值，
/// 只靠 `models.json` 或内置 provider 也能跑。
pub async fn load_pi_config(agent_dir? : String) -> PiConfig {
  let env = @env.get_env_vars()
  let dir = match agent_dir {
    Some(dir) => trim_trailing_slash(dir)
    None => resolve_agent_dir(env)
  }
  let diagnostics : Array[String] = []
  let models_json = read_json_file(dir + "/models.json", diagnostics)
  let auth_json = read_json_file(dir + "/auth.json", diagnostics)
  let settings_json = read_json_file(dir + "/settings.json", diagnostics)
  let settings = match jobject(settings_json) {
    Some(obj) => obj
    None => Map([])
  }
  {
    providers: match models_json {
      Some(json) => parse_providers(json)
      None => []
    },
    default_provider: field_string(settings, "defaultProvider"),
    default_model: field_string(settings, "defaultModel"),
    default_thinking_level: match
      field_string(settings, "defaultThinkingLevel") {
      Some(level) => level
      None => "off"
    },
    default_tools: field_string_array(settings, "defaultTools"),
    compaction: parse_compaction(settings),
    auth: parse_auth(auth_json),
    env,
    agent_dir: dir,
    diagnostics,
  }
}

// ─── 内置 provider 的 baseUrl（只列 OpenAI 兼容的那些）───

///|
fn builtin_base_url(name : String) -> String? {
  match name {
    "openai" => Some("https://api.openai.com/v1")
    "deepseek" => Some("https://api.deepseek.com/v1")
    "openrouter" => Some("https://openrouter.ai/api/v1")
    "groq" => Some("https://api.groq.com/openai/v1")
    "mistral" => Some("https://api.mistral.ai/v1")
    "xai" => Some("https://api.x.ai/v1")
    "together" => Some("https://api.together.xyz/v1")
    "moonshot" => Some("https://api.moonshot.cn/v1")
    "zhipu" => Some("https://open.bigmodel.cn/api/paas/v4")
    "dashscope" | "qwen" =>
      Some("https://dashscope.aliyuncs.com/compatible-mode/v1")
    "ollama" => Some("http://127.0.0.1:11434/v1")
    _ => None
  }
}

///|
/// provider 名 → 环境变量名：`foo-bar` → `FOO_BAR_API_KEY`（与 pi 同口径）。
pub fn provider_env_key(name : String) -> String {
  let builder = StringBuilder()
  for ch in name.to_upper() {
    let is_digit = ch >= '0' && ch <= '9'
    let is_alpha = ch >= 'A' && ch <= 'Z'
    if is_digit || is_alpha {
      builder.write_string(ch.to_string())
    } else {
      builder.write_string("_")
    }
  }
  builder.write_string("_API_KEY")
  builder.to_string()
}

///|
pub fn PiConfig::find_provider(
  self : PiConfig,
  name : String,
) -> PiProviderInfo? {
  for provider in self.providers {
    if provider.name == name {
      return Some(provider)
    }
  }
  None
}

///|
fn synthetic_provider(
  name : String,
  base_url : String,
  api : String,
) -> PiProviderInfo {
  { name, base_url, api, api_key: None, models: [], }
}

///|
fn synthetic_model(
  provider : PiProviderInfo,
  provider_name : String,
  model_id : String,
) -> PiModelInfo {
  let compat = parse_compat(provider_name, provider.base_url, Map([]))
  {
    id: model_id,
    name: model_id,
    api: provider.api,
    base_url: None,
    reasoning: false,
    context_window: 0,
    max_tokens: None,
    thinking_level_map: Map([]),
    cost_input: 0.0,
    cost_output: 0.0,
    compat,
  }
}

///|
fn resolve_api_key(
  config : PiConfig,
  provider : PiProviderInfo,
  explicit : String?,
) -> String {
  match explicit {
    Some(key) => if !key.is_empty() { return key }
    None => ()
  }
  match provider.api_key {
    Some(key) => if !key.is_empty() { return key }
    None => ()
  }
  match config.auth.get(provider.name) {
    Some(key) => if !key.is_empty() { return key }
    None => ()
  }
  match config.env.get(provider_env_key(provider.name)) {
    Some(key) => key
    None => ""
  }
}

///|
/// 解析出一次请求要用的全部东西。
///
/// 优先级与 pi 一致：
/// - provider：显式 > `settings.json` 的 defaultProvider > 唯一一个 provider > 内置；
/// - model：显式 > defaultModel > provider 的第一个模型；
/// - api key：显式 > models.json 的 apiKey > auth.json > `<ID>_API_KEY`；
/// - thinking：显式 > defaultThinkingLevel > `off`。
pub fn PiConfig::resolve(
  self : PiConfig,
  provider? : String,
  model? : String,
  api_key? : String,
  thinking? : String,
) -> ResolvedProvider raise ProviderError {
  let provider_name = match provider {
    Some(name) =>
      if !name.is_empty() {
        name
      } else {
        self.default_provider.unwrap_or("")
      }
    None => self.default_provider.unwrap_or("")
  }
  let mut provider_info : PiProviderInfo? = self.find_provider(provider_name)
  if provider_info is None &&
    provider_name.is_empty() &&
    self.providers.length() == 1 {
    provider_info = Some(self.providers[0])
  }
  if provider_info is None && !provider_name.is_empty() {
    match builtin_base_url(provider_name) {
      Some(base_url) =>
        provider_info = Some(
          synthetic_provider(provider_name, base_url, "openai-completions"),
        )
      None => ()
    }
  }
  let provider_info = match provider_info {
    Some(info) => info
    None =>
      raise UnknownProvider(
        if provider_name.is_empty() {
          "（未指定）"
        } else {
          provider_name
        },
      )
  }
  let model_id = match model {
    Some(id) =>
      if !id.is_empty() {
        id
      } else {
        self.default_model.unwrap_or("")
      }
    None => self.default_model.unwrap_or("")
  }
  let mut model_info : PiModelInfo? = None
  for candidate in provider_info.models {
    if candidate.id == model_id {
      model_info = Some(candidate)
    }
  }
  if model_info is None &&
    model_id.is_empty() &&
    provider_info.models.length() > 0 {
    model_info = Some(provider_info.models[0])
  }
  if model_info is None {
    if model_id.is_empty() {
      raise UnknownModel(provider=provider_info.name, model="（未指定）")
    }
    // 模型不在目录里（常见于自定义网关）：只要 provider 有 baseUrl 就按 OpenAI
    // 兼容的默认参数发，不假装知道它的窗口/价格。
    model_info = Some(
      synthetic_model(provider_info, provider_info.name, model_id),
    )
  }
  let model_info = match model_info {
    Some(info) => info
    None => raise UnknownModel(provider=provider_info.name, model=model_id)
  }
  if !model_info.api.has_prefix("openai-completions") {
    raise UnsupportedApi(api=model_info.api, provider=provider_info.name)
  }
  // provider 没写 baseUrl 时允许回落到内置表（pi 里覆盖内置 provider 的
  // models.json 条目常常只写 apiKey + models）。
  let provider_base = if provider_info.base_url.is_empty() {
    match builtin_base_url(provider_info.name) {
      Some(url) => url
      None => ""
    }
  } else {
    provider_info.base_url
  }
  let base_url = match model_info.base_url {
    Some(url) => url
    None => provider_base
  }
  if base_url.is_empty() {
    raise MissingBaseUrl(provider=provider_info.name)
  }
  let thinking_level = match thinking {
    Some(level) =>
      if !level.is_empty() {
        level
      } else {
        self.default_thinking_level
      }
    None => self.default_thinking_level
  }
  {
    provider_name: provider_info.name,
    base_url,
    api: model_info.api,
    model: model_info,
    api_key: resolve_api_key(self, provider_info, api_key),
    thinking_level,
    agent_dir: self.agent_dir,
  }
}

///|
pub(all) struct ResolvedProvider {
  provider_name : String
  base_url : String
  api : String
  model : PiModelInfo
  api_key : String
  thinking_level : String
  agent_dir : String
}

///|
/// 交给 faceoff 的连接设置：URL 拼接、默认值都与库保持同一套。
///
/// `system` 只影响 `@faceoff.request_body`（本项目不用它 —— agent 需要完整的
/// messages 历史），但填上它让 `Settings` 是一个完整可用的对象。
pub fn ResolvedProvider::faceoff_settings(
  self : ResolvedProvider,
  system_prompt : String,
) -> @faceoff.Settings {
  {
    api_key: self.api_key,
    base_url: self.base_url,
    model: self.model.id,
    system: system_prompt,
    temperature: None,
    max_tokens: None,
    timeout_ms: 120000,
    enable_thinking: self.thinking_level != "off",
    reasoning_effort: match self.thinking_level {
      "off" => None
      level => Some(level)
    },
  }
}

///|
/// 一句话描述「这次要用谁」（启动横幅 / `--list-models` 用）。
pub fn ResolvedProvider::describe(self : ResolvedProvider) -> String {
  self.provider_name +
  "/" +
  self.model.id +
  " (thinking=" +
  self.thinking_level +
  ")" +
  (if self.api_key.is_empty() { " [no key]" } else { "" })
}
