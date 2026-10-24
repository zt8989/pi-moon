// 主题引擎的断言。
//
// 关键的一组：`okhsl_to_rgb` 的结果必须与 pi 自己渲染出来的 RGB **逐字节相同** ——
// 同一个主题，pi 与 pi-moon 不能是两个颜色。期望值取自 pi 1.4.0 的
// `theme.colors.*`（dark / light 两份内置主题）。

///|
test "okhsl：与 pi dark 主题解析出的 RGB 一致" {
  // userMessageBg = blueBg
  assert_eq(okhsl_to_rgb(233.0, 0.41, 0.24), (33, 59, 73))
  // toolPendingBg
  assert_eq(okhsl_to_rgb(229.0, 0.05, 0.24), (52, 56, 58))
  // toolSuccessBg
  assert_eq(okhsl_to_rgb(158.0, 0.46, 0.25), (37, 65, 49))
  // toolErrorBg
  assert_eq(okhsl_to_rgb(19.0, 0.54, 0.25), (91, 40, 42))
  // customMessageBg
  assert_eq(okhsl_to_rgb(295.0, 0.42, 0.24), (58, 48, 85))
  // muted / dim / thinkingText
  assert_eq(okhsl_to_rgb(229.0, 0.06, 0.67), (157, 165, 169))
  assert_eq(okhsl_to_rgb(229.0, 0.08, 0.56), (126, 136, 142))
  assert_eq(okhsl_to_rgb(226.0, 0.07, 0.65), (150, 160, 164))
  // mdHeading / mdCode / mdLink
  assert_eq(okhsl_to_rgb(83.0, 0.88, 0.67), (205, 154, 34))
  assert_eq(okhsl_to_rgb(295.0, 0.50, 0.67), (167, 152, 215))
  assert_eq(okhsl_to_rgb(232.0, 0.54, 0.67), (105, 173, 208))
}

///|
test "okhsl：与 pi light 主题解析出的 RGB 一致" {
  assert_eq(okhsl_to_rgb(235.0, 0.19, 0.91), (223, 231, 236))
  assert_eq(okhsl_to_rgb(229.0, 0.08, 0.47), (103, 113, 118))
  assert_eq(okhsl_to_rgb(229.0, 0.07, 0.59), (135, 144, 149))
  assert_eq(okhsl_to_rgb(234.0, 0.08, 0.55), (124, 134, 140))
  assert_eq(okhsl_to_rgb(83.0, 0.99, 0.47), (143, 104, 2))
}

///|
test "颜色写法：#hex / okhsl / oklch / ANSI 索引 / 空串" {
  assert_eq(parse_color("#0f0"), Some("rgb(0,255,0)"))
  assert_eq(parse_color("#102030"), Some("rgb(16,32,48)"))
  assert_eq(parse_color("okhsl(233 41% 24%)"), Some("rgb(33,59,73)"))
  assert_eq(parse_color("okhsl(233deg 0.41 0.24)"), Some("rgb(33,59,73)"))
  // 196 是 256 色立方里的纯红。
  assert_eq(parse_color("196"), Some("rgb(255,0,0)"))
  // 空串 = 用终端默认色。
  assert_eq(parse_color(""), Some(""))
  // 认不出来的写法不该瞎猜。
  assert_eq(parse_color("chartreuse"), None)
  assert_eq(parse_color("okhsl(1 2)"), None)
}

///|
test "主题：内嵌 dark 的 token 与 pi 一致" {
  let theme = builtin_theme("dark", "dark")
  assert_eq(theme.name, "dark")
  assert_eq(theme.appearance, "dark")
  assert_eq(theme.color_or("userMessageBg", ""), "rgb(33,59,73)")
  assert_eq(theme.color_or("toolSuccessBg", ""), "rgb(37,65,49)")
  assert_eq(theme.color_or("toolErrorBg", ""), "rgb(91,40,42)")
  assert_eq(theme.color_or("toolPendingBg", ""), "rgb(52,56,58)")
  assert_eq(theme.color_or("customMessageBg", ""), "rgb(58,48,85)")
  assert_eq(theme.color_or("muted", ""), "rgb(157,165,169)")
  assert_eq(theme.color_or("dim", ""), "rgb(126,136,142)")
  assert_eq(theme.color_or("thinkingText", ""), "rgb(150,160,164)")
  assert_eq(theme.color_or("mdCode", ""), "rgb(167,152,215)")
  assert_eq(theme.color_or("mdLink", ""), "rgb(105,173,208)")
  assert_eq(theme.color_or("mdHeading", ""), "rgb(205,154,34)")
  assert_eq(theme.color_or("toolDiffAdded", ""), "rgb(104,183,141)")
  assert_eq(theme.color_or("toolDiffRemoved", ""), "rgb(234,127,129)")
}

///|
test "主题：内嵌 light 与 pi 的 light 一致，且自带 appearance" {
  let theme = builtin_theme("light", "dark")
  assert_eq(theme.name, "light")
  assert_eq(theme.appearance, "light")
  assert_eq(theme.color_or("userMessageBg", ""), "rgb(223,231,236)")
  assert_eq(theme.color_or("muted", ""), "rgb(103,113,118)")
  assert_eq(theme.color_or("mdCode", ""), "rgb(116,89,180)")
}

///|
test "主题：自定义 JSON 的 vars 引用会被展开" {
  let text = "{\"name\":\"mine\",\"appearance\":\"dark\",\"vars\":{\"bg\":\"#102030\",\"deep\":\"bg\"},\"colors\":{\"userMessageBg\":\"deep\",\"muted\":\"okhsl(229 6% 67%)\",\"text\":\"\"}}"
  let theme = match parse_theme(text, "fallback") {
    Some(theme) => theme
    None => panic()
  }
  assert_eq(theme.name, "mine")
  assert_eq(theme.color_or("userMessageBg", ""), "rgb(16,32,48)")
  assert_eq(theme.color_or("muted", ""), "rgb(157,165,169)")
  // 空串保留成「终端默认色」，不能被当成缺失。
  assert_eq(theme.color("text"), Some(""))
}

///|
test "主题：settings 的 theme 字段决定用哪一份" {
  // 显式名字
  assert_eq(resolve_theme_name(Some("light"), "dark"), "light")
  assert_eq(resolve_theme_name(Some("dark"), "light"), "dark")
  // 自动形式 light/dark：按终端深浅挑
  assert_eq(resolve_theme_name(Some("light/dark"), "light"), "light")
  assert_eq(resolve_theme_name(Some("light/dark"), "dark"), "dark")
  // system / 没配 → 跟着终端
  assert_eq(resolve_theme_name(Some("system"), "light"), "light")
  assert_eq(resolve_theme_name(None, "light"), "light")
  assert_eq(resolve_theme_name(Some("  "), "dark"), "dark")
  // 名字认不出来 → 交给 builtin_theme 按深浅兜底
  assert_eq(builtin_theme("mine", "light").name, "light")
  assert_eq(builtin_theme("mine", "dark").name, "dark")
}

///|
test "主题：light 主题能算出浅色配色（换主题不是换几个数字）" {
  let light = builtin_theme("light", "light")
  let palette = Palette::from_theme(light, @render.ColorMode::TrueColor)
  assert_eq(palette.user_bg, "rgb(223,231,236)")
  assert_eq(palette.tool_success_bg, "rgb(222,233,225)")
  assert_eq(palette.muted, "rgb(103,113,118)")
  assert_eq(palette.dim, "rgb(135,144,149)")
  assert_eq(palette.md.code, "rgb(116,89,180)")
  assert_eq(palette.thinking_color("high"), "rgb(181,165,232)")
}

///|
test "主题：markdown 的配色也来自主题" {
  let light = MarkdownColors::from_theme(builtin_theme("light", "light"))
  let lines = markdown_lines(
    "`code` 和 [链接](https://x.y)",
    60,
    colors=light,
  )
  let mut code_color = ""
  let mut link_color = ""
  for line in lines {
    for span in spans_of(line) {
      if span.text == "code" {
        code_color = span.fg.unwrap_or("")
      }
      if span.text == "链接" {
        link_color = span.fg.unwrap_or("")
      }
    }
  }
  assert_eq(code_color, "rgb(116,89,180)")
  assert_eq(link_color, "rgb(47,120,153)")
}

///|
test "主题：composer 框线跟着思考级别换（同 pi 的 thinking*）" {
  let palette = Palette::true_color()
  assert_eq(palette.thinking_color("off"), "rgb(108,118,123)")
  assert_eq(palette.thinking_color("high"), "rgb(151,118,229)")
  // 认不出来的级别退回普通边框色。
  assert_eq(palette.thinking_color("???"), palette.border)
}

///|
async test "主题：<agent dir>/themes 下的主题优先于内嵌" {
  let dir = "_build/theme-test-custom"
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
  @fs.mkdir(dir, recursive=true)
  @fs.mkdir(dir + "/themes", recursive=true)
  @fs.write_file(dir + "/settings.json", "{\"theme\":\"mine\"}")
  @fs.write_file(
    dir + "/themes/mine.json",
    "{\"name\":\"mine\",\"appearance\":\"light\",\"colors\":{\"muted\":\"#010203\",\"userMessageBg\":\"#0a0b0c\"}}",
  )
  let theme = load_theme(dir)
  assert_eq(theme.name, "mine")
  assert_eq(theme.appearance, "light")
  assert_eq(theme.color_or("muted", ""), "rgb(1,2,3)")
  let palette = Palette::from_theme(theme, @render.ColorMode::TrueColor)
  assert_eq(palette.user_bg, "rgb(10,11,12)")
  // 主题里缺的 token 用 dark 的默认值补齐，不会漏成空串。
  assert_eq(palette.dim, "rgb(126,136,142)")
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "主题：设置指向 dark/light 但没有主题文件时用内嵌的" {
  let dir = "_build/theme-test-builtin"
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
  @fs.mkdir(dir, recursive=true)
  @fs.write_file(dir + "/settings.json", "{\"theme\":\"light\"}")
  let theme = load_theme(dir)
  assert_eq(theme.name, "light")
  assert_eq(theme.color_or("userMessageBg", ""), "rgb(223,231,236)")
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}
