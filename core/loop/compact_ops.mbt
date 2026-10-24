// 压缩判定：要不要压、为什么。
//
// 放在 loop 而不是 compact：判据要读 state（messages / window / 最近一次错误），
// 而 `core/compact` 刻意只依赖 message —— 那样切点算法才能脱离环单独测。
//
// 三条路径（与 pi 的 `_checkCompaction` 同一套语义）：
//
// - `manual`：用户按了 `/compact`，不看阈值、也不看 enabled（关掉的是**自动**压）；
// - `overflow`：provider 报了上下文溢出（含「静默溢出」—— 某些网关收下超长请求
//   并正常返回，只在 usage 里露馅）；
// - `threshold`：占用超过 `window - reserve`。

///|
pub(all) struct CompactDecision {
  should : Bool
  reason : @compact.CompactReason?
  /// 判定时的上下文 token 数（不知道就是 None）。
  context_tokens : Int32?
} derive(Eq, Debug)

///|
/// provider 的错误文案看起来是不是「上下文溢出」。
///
/// pi 的 `isContextOverflow` 维护着 40+ 家 provider 的报错文案；这里只收最
/// 常见的那几条 —— 判错的代价是「该压没压」（下一轮还会失败）或「白压一次」，
/// 都不是正确性问题。
pub fn looks_like_context_overflow(error : String) -> Bool {
  let text = error.to_lower()
  text.contains("context length") ||
  text.contains("context window") ||
  text.contains("maximum context") ||
  text.contains("too many tokens") ||
  text.contains("prompt is too long") ||
  text.contains("reduce the length") ||
  text.contains("exceeds the model") ||
  text.contains("上下文长度") ||
  text.contains("上下文窗口") ||
  text.contains("超出上下文")
}

///|
/// 要不要压，以及为什么。
///
/// `manual` 为真时直接返回 `manual`：用户主动要求，不该被阈值或 `enabled`
/// 拦住 —— `enabled: false` 关掉的是**自动**压缩。
pub fn decide_compaction(
  state : @state.AgentState,
  manual : Bool,
) -> CompactDecision {
  let context_tokens = @compact.last_context_tokens(state.messages)
  let window = state.model.context_window
  let settings = @compact.effective_settings(state.compact_settings, window)
  if manual {
    return { should: true, reason: Some(@compact.Manual), context_tokens, }
  }
  if !settings.enabled {
    return { should: false, reason: None, context_tokens, }
  }
  // 溢出：provider 明确报了，或者「静默溢出」（收下了但 usage 显示装不下）。
  let overflowed = match state.error {
    Some(error) => looks_like_context_overflow(error)
    None => false
  }
  if overflowed {
    return { should: true, reason: Some(@compact.Overflow), context_tokens, }
  }
  if window > 0 {
    match context_tokens {
      Some(tokens) =>
        if @compact.should_compact(tokens, window, settings) {
          return {
            should: true,
            reason: Some(@compact.Threshold),
            context_tokens,
          }
        }
      None => ()
    }
  }
  { should: false, reason: None, context_tokens, }
}
