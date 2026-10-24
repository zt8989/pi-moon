// 颜色：终端能力探测 + 从主题算出来的一套界面配色。
//
// 颜色**不在渲染代码里写死**：底色、前景色、markdown 那些颜色全部来自 pi 的
// 主题（见 `tui_theme.mbt`），这里只做两件事：
//
//   1. 决定终端支持 24-bit 还是只有 256 色；
//   2. 把主题的 token 摊平成渲染时好用的字段。
//
// 底色为什么要分两种：默认渲染把 `rgb()` 量化到 256 色立方（6×6×6），pi 那几块
// 很暗的底色会被压到一起（用户块 `rgb(33,59,73)` 与工具块 `rgb(37,65,49)` 都落成
// `#005f5f`），用户块与工具块就分不出来了。所以只在 24-bit 终端上用主题原值，
// 256 色终端退回 16 色名字。前景色没有这个问题（它们不挨着铺），一律用主题值。

///|
/// 渲染用的一整套颜色，由主题算出来。
pub(all) struct Palette {
  /// 面板底色。256 色终端上是 16 色名字，24-bit 上是主题原值。
  user_bg : String
  tool_pending_bg : String
  tool_success_bg : String
  tool_error_bg : String
  compaction_bg : String
  /// 前景色（主题的 `text` / `muted` / `dim` / …）。
  text : String
  muted : String
  dim : String
  accent : String
  border : String
  success : String
  error : String
  warning : String
  /// 思考级别 → composer 框线颜色（pi 的 `thinkingOff`..`thinkingMax`）。
  thinking : Map[String, String]
  /// markdown 的配色。
  md : MarkdownColors
} derive(Eq, Debug)

///|
pub fn Palette::thinking_color(self : Palette, level : String) -> String {
  match self.thinking.get(level) {
    Some(color) => color
    None => self.border
  }
}

///|
/// 从主题算配色。`mode` 只影响面板底色：见文件头的说明。
pub fn Palette::from_theme(theme : Theme, mode : @render.ColorMode) -> Palette {
  let dark = builtin_theme("dark", "dark")
  let pick = fn(token : String) {
    theme.color_or(token, dark.color_or(token, ""))
  }
  let panel = fn(token : String, fallback : String) {
    if mode.is_true_color() {
      pick(token)
    } else {
      fallback
    }
  }
  let thinking : Map[String, String] = Map([])
  let levels : Array[(String, String)] = [
    ("off", "thinkingOff"),
    ("minimal", "thinkingMinimal"),
    ("low", "thinkingLow"),
    ("medium", "thinkingMedium"),
    ("high", "thinkingHigh"),
    ("xhigh", "thinkingXhigh"),
    ("max", "thinkingMax"),
  ]
  for entry in levels {
    thinking.set(entry.0, pick(entry.1))
  }
  {
    user_bg: panel("userMessageBg", "blue"),
    tool_pending_bg: panel("toolPendingBg", "black"),
    tool_success_bg: panel("toolSuccessBg", "green"),
    tool_error_bg: panel("toolErrorBg", "red"),
    compaction_bg: panel("customMessageBg", "magenta"),
    text: pick("text"),
    muted: pick("muted"),
    dim: pick("dim"),
    accent: pick("accent"),
    border: pick("border"),
    success: pick("success"),
    error: pick("error"),
    warning: pick("warning"),
    thinking,
    md: MarkdownColors::from_theme(theme),
  }
}

///|
/// 256 色终端的默认配色（dark 主题 + 16 色底）。测试用这个当基准。
pub fn Palette::ansi256() -> Palette {
  Palette::from_theme(builtin_theme("dark", "dark"), @render.ColorMode::Ansi256)
}

///|
/// 24-bit 终端的默认配色（dark 主题原值）。
pub fn Palette::true_color() -> Palette {
  Palette::from_theme(
    builtin_theme("dark", "dark"),
    @render.ColorMode::TrueColor,
  )
}

///|
/// 当前终端该用哪种颜色编码。
///
/// 先问 tui 自己的探测（`COLORTERM` / `TERM`），再补它的探测看不到的那几个：
/// Windows Terminal 只给 `WT_SESSION`，VS Code 只给 `TERM_PROGRAM`。
pub fn tui_color_mode() -> @render.ColorMode {
  color_mode_from_env(
    env_or_empty("TERM"),
    env_or_empty("COLORTERM"),
    env_or_empty("WT_SESSION"),
    env_or_empty("TERM_PROGRAM"),
    env_or_empty("ConEmuANSI"),
    env_or_empty("ANSICON"),
  )
}

///|
fn env_or_empty(name : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => value
    None => ""
  }
}

///|
/// 纯函数版本（测试直接喂环境变量）：显式广告 24-bit 的终端用 TrueColor，
/// 其余一律回 256 色 —— 猜错只影响观感，但猜成 TrueColor 而终端不支持，
/// 那几块底色会整段变成默认色（比量化难看）。
fn color_mode_from_env(
  term : String,
  colorterm : String,
  wt_session : String,
  term_program : String,
  conemu : String,
  ansicon : String,
) -> @render.ColorMode {
  let advertised = @render.ColorMode::from_env(term, colorterm)
  if advertised.is_true_color() {
    return advertised
  }
  // `TERM_PROGRAM` 的写法不统一（Windows Terminal 给的是
  // `Windows_Terminal`），先把下划线当成空格归一。
  let program = term_program.to_lower().replace_all(old="_", new=" ")
  if !wt_session.is_empty() ||
    program.contains("windows terminal") ||
    program.contains("vscode") ||
    conemu.to_lower() == "on" ||
    !ansicon.is_empty() {
    @render.ColorMode::TrueColor
  } else {
    @render.ColorMode::Ansi256
  }
}
