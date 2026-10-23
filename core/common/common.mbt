// 共享的标量枚举与纯策略函数。
//
// 这些值不依赖别的包，所以 action / state / loop / trace 都能引它们，
// 不会出现「两个包互相要对方的枚举」那种循环依赖。

///|
/// 相位：只描述「现在在等谁」，不含任何驱动方式的信息。
pub(all) enum Phase {
  Idle
  Thinking
  CallingTools
} derive(Eq, Debug)

///|
pub fn Phase::name(self : Phase) -> String {
  match self {
    Idle => "idle"
    Thinking => "thinking"
    CallingTools => "calling-tools"
  }
}

///|
/// 排队的用户输入属于哪一列（与 pi 的 `steer()` / `followUp()` 同口径）。
///
/// - `Steer`：当前 step 的工具跑完后、下一次 LLM 调用前插入；
/// - `FollowUp`：等模型没有工具调用了才插入，然后开一个新回合。
pub(all) enum QueueKind {
  Steer
  FollowUp
} derive(Eq, Debug)

///|
pub fn QueueKind::name(self : QueueKind) -> String {
  match self {
    Steer => "steer"
    FollowUp => "followUp"
  }
}

///|
/// LLM 失败的类别 —— 决定它是不是「可重试」的。
pub(all) enum LlmErrorKind {
  Timeout
  Network
  Auth
  Model
  Aborted
  Unknown
} derive(Eq, Debug)

///|
pub fn LlmErrorKind::name(self : LlmErrorKind) -> String {
  match self {
    Timeout => "timeout"
    Network => "network"
    Auth => "auth"
    Model => "model"
    Aborted => "aborted"
    Unknown => "unknown"
  }
}

///|
/// 这些错误重试有意义：网络抖动、超时。鉴权 / 参数错重试多少次都一样。
pub fn is_retryable(kind : LlmErrorKind) -> Bool {
  match kind {
    Timeout | Network => true
    _ => false
  }
}

///|
/// 从错误信息猜类别（effect 只拿到一个字符串，分类统一放在这里做）。
///
/// 顺序要紧：`network` 要在 `aborted` 之前认 —— `ECONNABORTED` 是连接错误，
/// 不是用户中断。
pub fn classify_llm_error(error : String) -> LlmErrorKind {
  let text = error.to_lower()
  if text.contains("network") ||
    text.contains("fetch failed") ||
    text.contains("econnreset") ||
    text.contains("econnrefused") ||
    text.contains("econnaborted") ||
    text.contains("socket hang up") ||
    text.contains("enotfound") ||
    text.contains("connection error") ||
    text.contains("connection refused") ||
    text.contains("connection reset") ||
    text.contains("connection closed") ||
    text.contains("网络") {
    return Network
  }
  if text.contains("abort") {
    return Aborted
  }
  if text.contains("timeout") ||
    text.contains("timed out") ||
    text.contains("超时") {
    return Timeout
  }
  if text.contains("unauthorized") ||
    text.contains("forbidden") ||
    text.contains("api key") ||
    text.contains("401") ||
    text.contains("403") ||
    text.contains("鉴权") {
    return Auth
  }
  if text.contains("model") || text.contains("模型") {
    return Model
  }
  Unknown
}

///|
/// 回合为什么停了 —— 界面据此区分「正常收工」和「被砍」。
pub(all) enum StopReason {
  Completed
  MaxTurns
  Errored
  Aborted
} derive(Eq, Debug)

///|
pub fn StopReason::name(self : StopReason) -> String {
  match self {
    Completed => "completed"
    MaxTurns => "maxTurns"
    Errored => "error"
    Aborted => "aborted"
  }
}

///|
/// 停止的**具体原因**：`Errored` 把超时 / 网络 / 鉴权 / 用户中断压成了一类，
/// 这一层拆细，界面与日志直接念它。
pub(all) enum StopCause {
  CauseCompleted
  CauseMaxTurns
  CauseUser
  CauseTimeout
  CauseNetwork
  CauseAuth
  CauseModel
  CauseLlmError
  CauseToolError
  CauseShutdown
  CauseCompactError
} derive(Eq, Debug)

///|
pub fn StopCause::name(self : StopCause) -> String {
  match self {
    CauseCompleted => "completed"
    CauseMaxTurns => "maxTurns"
    CauseUser => "user"
    CauseTimeout => "timeout"
    CauseNetwork => "network"
    CauseAuth => "auth"
    CauseModel => "model"
    CauseLlmError => "llm-error"
    CauseToolError => "tool-error"
    CauseShutdown => "shutdown"
    CauseCompactError => "compact-error"
  }
}

///|
/// 停止原因 → 一句人话。界面与日志共用，不必各写一份文案。
pub fn stop_cause_text(cause : StopCause) -> String {
  match cause {
    CauseCompleted => "模型说完了"
    CauseMaxTurns => "达到轮数上限"
    CauseUser => "用户中断"
    CauseTimeout => "模型调用超时"
    CauseNetwork => "网络错误"
    CauseAuth => "鉴权失败"
    CauseModel => "模型错误"
    CauseLlmError => "模型调用失败"
    CauseToolError => "工具执行失败"
    CauseShutdown => "内核已关闭"
    CauseCompactError => "上下文压缩失败"
  }
}

///|
/// 从失败的类别推出停止原因。effect 侧若带了真实原因（`cause`），以它为准。
pub fn cause_from_kind(kind : LlmErrorKind, cause : StopCause?) -> StopCause {
  match cause {
    Some(cause) => cause
    None =>
      match kind {
        Aborted => CauseUser
        Timeout => CauseTimeout
        Network => CauseNetwork
        Auth => CauseAuth
        Model => CauseModel
        Unknown => CauseLlmError
      }
  }
}

///|
/// 一次「回合」的结局。与 `StopReason` 的差别：这一层还知道「被新消息打断」。
pub(all) enum TurnEndReason {
  TurnCompleted
  TurnMaxTurns
  TurnError
  TurnAborted
  TurnInterrupted
} derive(Eq, Debug)

///|
/// 回合结束原因的人话版（写 `turn.end` 节点标签用）。
pub fn turn_reason_text(reason : TurnEndReason) -> String {
  match reason {
    TurnCompleted => "模型说完了"
    TurnMaxTurns => "达到轮数上限"
    TurnAborted => "用户中断"
    TurnInterrupted => "被新消息打断"
    TurnError => "出错收工"
  }
}

///|
/// 取一段文本的头一行、截到 60 个字符 —— 轨迹节点标签与列表项用。
pub fn summarize(text : String) -> String {
  let trimmed = text.trim().to_owned()
  if trimmed.is_empty() {
    return ""
  }
  let first = match trimmed.find("\n") {
    Some(index) => trimmed[0:index].to_owned()
    None => trimmed
  }
  if first.length() > 60 {
    first[0:59].to_owned() + "…"
  } else {
    first
  }
}

///|
pub fn TurnEndReason::name(self : TurnEndReason) -> String {
  match self {
    TurnCompleted => "completed"
    TurnMaxTurns => "maxTurns"
    TurnAborted => "aborted"
    TurnInterrupted => "interrupted"
    TurnError => "error"
  }
}
