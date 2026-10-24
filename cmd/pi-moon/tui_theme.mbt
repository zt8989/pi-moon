// 主题：颜色从 pi 的 theme JSON 来，渲染代码里不写死 RGB。
//
// 与 pi 同一套规则（`dist/modes/interactive/theme/theme.js` + `pi-tui/dist/colors.js`）：
//
//   settings.json 的 `theme`
//     ├─ "light/dark"（自动形式）→ 按终端深浅挑一边
//     ├─ "system"               → pi 按终端上报的颜色现算；这里退化成 dark/light
//     └─ 名字                    → <agent dir>/themes/<name>.json
//   找不到文件 → 内嵌的 dark / light（见 `tui_theme_data.mbt`）
//
// 颜色写法也照 pi：`#rgb` / `#rrggbb` / `okhsl(h s% l%)` / `oklch(l c h)` /
// 数字（ANSI 索引）/ `""`（终端默认色），并且可以在 `vars` 里互相引用。
// OKHSL / OKLCH 的换算是 Björn Ottosson 参考实现的移植（MIT），系数与 pi 逐项一致 ——
// 换出来的 RGB 与 pi 渲染出来的必须逐字节相同，否则同一个主题两边不同色。

///|
/// 一份解析好的主题：`colors` 里的值已经是渲染器认的写法（`rgb(r,g,b)` 或 `""`）。
pub(all) struct Theme {
  name : String
  appearance : String
  colors : Map[String, String]
}

///|
/// 取一个 token；主题里没有就返回 None（调用方自己决定退路）。
pub fn Theme::color(self : Theme, token : String) -> String? {
  self.colors.get(token)
}

///|
/// 取一个 token，缺了用 `fallback`。
pub fn Theme::color_or(
  self : Theme,
  token : String,
  fallback : String,
) -> String {
  match self.colors.get(token) {
    Some(color) if !color.is_empty() => color
    _ => fallback
  }
}

// ============================================================================
// 主题加载
// ============================================================================

///|
/// 按 pi 的规则决定用哪套主题，并把颜色解析出来。
///
/// 顺序：`<agent dir>/themes/<name>.json` → `$PI_PACKAGE_DIR` 下的同名主题 →
/// 内嵌的 dark / light。任何一步失败都往下退，最终一定有颜色可用。
pub async fn load_theme(agent_dir : String) -> Theme {
  let setting = read_theme_setting(agent_dir)
  let appearance = detect_appearance()
  let name = resolve_theme_name(setting, appearance)
  for path in theme_candidates(agent_dir, name) {
    match read_theme_file(path, name) {
      Some(theme) => return theme
      None => ()
    }
  }
  builtin_theme(name, appearance)
}

///|
/// `settings.json` 的 `theme` 字段（pi 与 pi-moon 读同一份文件）。
async fn read_theme_setting(agent_dir : String) -> String? {
  let path = agent_dir + "/settings.json"
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let data = @fs.read_file(path) catch { _ => return None }
  let text = data.text() catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  match json {
    Object(obj) =>
      match obj.get("theme") {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// `theme` 设置 → 主题名。
///
/// `"light/dark"` 这种自动形式按终端深浅挑一边；`system` 需要现算（pi 用终端上报
/// 的颜色生成整套调色板，那套算法不在这里），退化成 dark/light。
fn resolve_theme_name(setting : String?, appearance : String) -> String {
  let raw = match setting {
    Some(value) => value.trim(chars=" ").to_owned()
    None => ""
  }
  if raw.is_empty() || raw.to_lower() == "system" || raw.to_lower() == "auto" {
    return appearance
  }
  match auto_theme_parts(raw) {
    Some((light, dark)) => if appearance == "light" { light } else { dark }
    None => raw
  }
}

///|
/// `"light/dark"` → (light, dark)；没有 `/` 或有多段的不是自动形式。
fn auto_theme_parts(setting : String) -> (String, String)? {
  match setting.find("/") {
    Some(index) => {
      let light = setting[:index].trim(chars=" ").to_owned()
      let rest = setting[index + 1:].to_owned()
      if rest.find("/") is Some(_) {
        return None
      }
      let dark = rest.trim(chars=" ").to_owned()
      if light.is_empty() || dark.is_empty() {
        None
      } else {
        Some((light, dark))
      }
    }
    None => None
  }
}

///|
/// 终端是深底还是浅底。pi 优先问终端自己（OSC 11），这里退一步用 `COLORFGBG`
/// （vim / tmux 都在用的那个），判不出来按 dark。
fn detect_appearance() -> String {
  let value = match @env.get_env_var("COLORFGBG") {
    Some(value) => value
    None => return "dark"
  }
  // `fg;bg` 或 rxvt 的 `fg;xpm;bg`：最后一段是背景色的 ANSI 索引。
  let parts : Array[String] = []
  for part in value.split(";") {
    parts.push(part.trim(chars=" ").to_owned())
  }
  if parts.is_empty() {
    return "dark"
  }
  let background = parts[parts.length() - 1]
  let index = match parse_int_opt(background) {
    Some(index) if index >= 0 && index <= 15 => index
    _ => return "dark"
  }
  // 0-6 与 8（亮黑，Solarized Dark 的底色）算深底，7 与 9-15 算浅底。
  if index <= 6 || index == 8 {
    "dark"
  } else {
    "light"
  }
}

///|
/// 候选主题文件，按优先级排。
fn theme_candidates(agent_dir : String, name : String) -> Array[String] {
  let out : Array[String] = []
  out.push(agent_dir + "/themes/" + name + ".json")
  match @env.get_env_var("PI_PACKAGE_DIR") {
    Some(dir) =>
      out.push(dir + "/dist/modes/interactive/theme/" + name + ".json")
    None => ()
  }
  out
}

///|
async fn read_theme_file(path : String, name : String) -> Theme? {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let data = @fs.read_file(path) catch { _ => return None }
  let text = data.text() catch { _ => return None }
  parse_theme(text, name)
}

///|
/// 内嵌主题：先按名字，再按终端深浅；名字认不出来就当 dark。
pub fn builtin_theme(name : String, appearance : String) -> Theme {
  // 认得出的名字按名字；认不出来（自定义主题丢了文件、"system" 等）按终端深浅。
  let chosen = match name.to_lower() {
    "light" => "light"
    "dark" => "dark"
    _ => appearance
  }
  cached_builtin(chosen)
}

///|
/// 内嵌主题解析一次就够：`tab_nodes` / `footer_lines` 这类每帧都调的函数会
/// 用到默认配色，每帧解一遍 2 KB JSON 是白花的时间。
let cached_dark_theme : @ref.Ref[Theme?] = @ref.Ref(None)

///|
let cached_light_theme : @ref.Ref[Theme?] = @ref.Ref(None)

///|
fn cached_builtin(name : String) -> Theme {
  let cache = if name == "light" {
    cached_light_theme
  } else {
    cached_dark_theme
  }
  match cache.val {
    Some(theme) => theme
    None => {
      let text = if name == "light" {
        theme_light_json
      } else {
        theme_dark_json
      }
      let theme = match parse_theme(text, name) {
        Some(theme) => theme
        None => { name, appearance: name, colors: Map([]), }
      }
      cache.val = Some(theme)
      theme
    }
  }
}

// ============================================================================
// 主题 JSON
// ============================================================================

///|
/// theme JSON → Theme。`vars` 先展开，再把每个 token 的颜色换算成 `rgb(r,g,b)`。
pub fn parse_theme(text : String, name_hint : String) -> Theme? {
  let json = @json.parse(text) catch { _ => return None }
  let root = match json {
    Object(obj) => obj
    _ => return None
  }
  let vars = match root.get("vars") {
    Some(Object(vars)) => vars
    _ => Map([])
  }
  let colors = match root.get("colors") {
    Some(Object(colors)) => colors
    _ => return None
  }
  let name = match root.get("name") {
    Some(String(value)) => value
    _ => name_hint
  }
  let appearance = match root.get("appearance") {
    Some(String(value)) => value
    _ => "dark"
  }
  let resolved : Map[String, String] = Map([])
  for key, value in colors {
    match resolve_color_value(value, vars, 0) {
      Some(color) => resolved.set(key, color)
      None => ()
    }
  }
  Some({ name, appearance, colors: resolved, })
}

///|
/// 颜色值 → `rgb(r,g,b)`；`""` 原样保留（终端默认色）。
///
/// JSON 里既可能是字符串（可能是 `vars` 的引用），也可能是数字（ANSI 索引）。
fn resolve_color_value(
  value : Json,
  vars : Map[String, Json],
  depth : Int32,
) -> String? {
  if depth > 8 {
    return None
  }
  match value {
    Number(number) => indexed_color(number.to_int())
    String(text) => {
      let trimmed = text.trim(chars=" ").to_owned()
      if trimmed.is_empty() {
        return Some("")
      }
      if is_color_literal(trimmed) {
        return parse_color(trimmed)
      }
      match vars.get(trimmed) {
        Some(next) => resolve_color_value(next, vars, depth + 1)
        None => parse_color(trimmed)
      }
    }
    _ => None
  }
}

///|
fn is_color_literal(value : String) -> Bool {
  if value.has_prefix("#") {
    return true
  }
  let lower = value.to_lower()
  lower.has_prefix("okhsl(") || lower.has_prefix("oklch(")
}

// ============================================================================
// 颜色写法
// ============================================================================

///|
/// 一种颜色写法 → `rgb(r,g,b)`；认不出来返回 None。
pub fn parse_color(value : String) -> String? {
  let trimmed = value.trim(chars=" ").to_owned()
  if trimmed.is_empty() {
    return Some("")
  }
  if trimmed.has_prefix("#") {
    return hex_color(trimmed)
  }
  let lower = trimmed.to_lower()
  if lower.has_prefix("okhsl(") && lower.has_suffix(")") {
    return okhsl_color(trimmed[6:trimmed.length() - 1].to_owned())
  }
  if lower.has_prefix("oklch(") && lower.has_suffix(")") {
    return oklch_color(trimmed[6:trimmed.length() - 1].to_owned())
  }
  match parse_int_opt(trimmed) {
    Some(index) => indexed_color(index)
    None => None
  }
}

///|
fn hex_color(value : String) -> String? {
  let digits = value[1:].to_lower().to_owned()
  let expanded = if digits.length() == 3 {
    let buf = StringBuilder()
    for c in digits {
      buf.write_char(c)
      buf.write_char(c)
    }
    buf.to_string()
  } else if digits.length() == 6 {
    digits
  } else {
    return None
  }
  match
    (
      parse_int_opt(expanded[:2], base=16),
      parse_int_opt(expanded[2:4], base=16),
      parse_int_opt(expanded[4:6], base=16),
    ) {
    (Some(r), Some(g), Some(b)) => Some(rgb_string(r, g, b))
    _ => None
  }
}

///|
/// `okhsl(h s% l%)`：h 是度数（可带 deg），s / l 带 % 时按 0-100 读。
fn okhsl_color(body : String) -> String? {
  let parts = split_whitespace(body)
  if parts.length() != 3 {
    return None
  }
  let hue = match number_with_unit(parts[0], "deg") {
    Some(value) => value
    None => return None
  }
  let saturation = match percentage(parts[1]) {
    Some(value) => value
    None => return None
  }
  let lightness = match percentage(parts[2]) {
    Some(value) => value
    None => return None
  }
  if saturation < 0.0 || saturation > 1.0 || lightness < 0.0 || lightness > 1.0 {
    return None
  }
  let (r, g, b) = okhsl_to_rgb(hue, saturation, lightness)
  Some(rgb_string(r, g, b))
}

///|
/// `oklch(l c h)`：l 带 % 时按 0-100 读。
fn oklch_color(body : String) -> String? {
  let parts = split_whitespace(body)
  if parts.length() != 3 {
    return None
  }
  let lightness = match percentage(parts[0]) {
    Some(value) => value
    None => return None
  }
  let chroma = match parse_double_opt(parts[1]) {
    Some(value) => value
    None => return None
  }
  let hue = match number_with_unit(parts[2], "deg") {
    Some(value) => value
    None => return None
  }
  if lightness < 0.0 || lightness > 1.0 || chroma < 0.0 {
    return None
  }
  let (r, g, b) = oklch_to_rgb(lightness, chroma, hue)
  Some(rgb_string(r, g, b))
}

///|
/// `"0-1"` 或 `"0-100%"` → 0-1。
fn percentage(value : String) -> Double? {
  if value.has_suffix("%") {
    match parse_double_opt(value[:value.length() - 1]) {
      Some(number) => Some(number / 100.0)
      None => None
    }
  } else {
    parse_double_opt(value)
  }
}

///|
fn number_with_unit(value : String, unit : String) -> Double? {
  if value.has_suffix(unit) {
    parse_double_opt(value[:value.length() - unit.length()])
  } else {
    parse_double_opt(value)
  }
}

///|
/// 解析失败返回 None（颜色写法是主题作者写的，不能 panic）。
fn parse_int_opt(text : StringView, base~ : Int32 = 10) -> Int32? {
  Some(@string.parse_int(text, base~)) catch {
    _ => None
  }
}

///|
fn parse_double_opt(text : StringView) -> Double? {
  Some(@string.parse_double(text)) catch {
    _ => None
  }
}

///|
/// 按空白切（多次空格 / tab 都当一次）。
fn split_whitespace(text : String) -> Array[String] {
  let out : Array[String] = []
  let buf : Array[Char] = []
  for c in text.trim(chars=" \t").to_owned() {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if !buf.is_empty() {
        out.push(String::from_array(buf))
        buf.clear()
      }
    } else {
      buf.push(c)
    }
  }
  if !buf.is_empty() {
    out.push(String::from_array(buf))
  }
  out
}

///|
fn rgb_string(r : Int32, g : Int32, b : Int32) -> String {
  "rgb(" + r.to_string() + "," + g.to_string() + "," + b.to_string() + ")"
}

///|
/// ANSI 索引 → 该索引实际显示的颜色（16 色基本盘 / 6×6×6 立方 / 24 级灰阶）。
fn indexed_color(index : Int32) -> String? {
  if index < 0 || index > 255 {
    return None
  }
  if index < 16 {
    let basic : Array[(Int32, Int32, Int32)] = [
      (0, 0, 0),
      (128, 0, 0),
      (0, 128, 0),
      (128, 128, 0),
      (0, 0, 128),
      (128, 0, 128),
      (0, 128, 128),
      (192, 192, 192),
      (128, 128, 128),
      (255, 0, 0),
      (0, 255, 0),
      (255, 255, 0),
      (0, 0, 255),
      (255, 0, 255),
      (0, 255, 255),
      (255, 255, 255),
    ]
    let (r, g, b) = basic[index]
    return Some(rgb_string(r, g, b))
  }
  let cube = [0, 95, 135, 175, 215, 255]
  if index < 232 {
    let offset = index - 16
    return Some(
      rgb_string(cube[offset / 36], cube[offset % 36 / 6], cube[offset % 6]),
    )
  }
  let gray = 8 + (index - 232) * 10
  Some(rgb_string(gray, gray, gray))
}

// ============================================================================
// OKLab / OKHSL / OKLCH → sRGB
//
// 移植自 Björn Ottosson 的参考实现（https://bottosson.github.io/posts/colorpicker/，
// MIT），矩阵系数与 pi-tui 的 `oklab.js` 逐项一致。改这里必须让 `tui_theme_wbtest`
// 里那组「与 pi 渲染结果逐字节相同」的断言继续过。
// ============================================================================

///|
let lms_to_linear_srgb : Array[Array[Double]] = [
  [4.0767416360759583, -3.3077115392580629, 0.2309699031821043],
  [-1.2684379732850315, 2.6097573492876882, -0.341319376002657],
  [-0.0041960761386756, -0.7034186179359362, 1.7076146940746117],
]

///|
let lab_to_lms : Array[Array[Double]] = [
  [1.0, 0.3963377773761749, 0.2158037573099136],
  [1.0, -0.1055613458156586, -0.0638541728258133],
  [1.0, -0.0894841775298119, -1.2914855480194092],
]

///|
let k1 : Double = 0.206

///|
let k2 : Double = 0.03

///|
fn k3() -> Double {
  (1.0 + k1) / (1.0 + k2)
}

///|
fn sqrt_of(value : Double) -> Double {
  value.sqrt()
}

///|
fn pow_of(base : Double, exponent : Double) -> Double {
  base.pow(exponent)
}

///|
/// OKHSL 的 lightness → OKLab 的 L。
fn okhsl_to_oklab_lightness(x : Double) -> Double {
  (x * x + k1 * x) / (k3() * (x + k2))
}

///|
fn linear_to_srgb(value : Double) -> Double {
  if value > 0.0031308 {
    1.055 * pow_of(value, 1.0 / 2.4) - 0.055
  } else {
    12.92 * value
  }
}

///|
fn matrix_apply(
  m : Array[Array[Double]],
  x : Double,
  y : Double,
  z : Double,
) -> (Double, Double, Double) {
  let row0 = m[0]
  let row1 = m[1]
  let row2 = m[2]
  (
    row0[0] * x + row0[1] * y + row0[2] * z,
    row1[0] * x + row1[1] * y + row1[2] * z,
    row2[0] * x + row2[1] * y + row2[2] * z,
  )
}

///|
/// OKLab (L, a, b) → 线性 sRGB（可能出界）。
fn oklab_to_linear_srgb(
  l : Double,
  a : Double,
  b : Double,
) -> (Double, Double, Double) {
  let (l_, m_, s_) = matrix_apply(lab_to_lms, l, a, b)
  matrix_apply(lms_to_linear_srgb, l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
}

///|
fn linear_srgb_to_rgb(
  linear : (Double, Double, Double),
) -> (Int32, Int32, Int32) {
  let (r, g, b) = linear
  (
    (linear_to_srgb(r).clamp(min=0.0, max=1.0) * 255.0).round().to_int(),
    (linear_to_srgb(g).clamp(min=0.0, max=1.0) * 255.0).round().to_int(),
    (linear_to_srgb(b).clamp(min=0.0, max=1.0) * 255.0).round().to_int(),
  )
}

///|
/// 每个 sRGB 通道先出界的 (a, b) 半平面，以及该处的最大饱和度拟合系数。
let saturation_fit : Array[(Array[Double], Array[Double])] = [
  (
    [-1.8817031, -0.80936501],
    [1.19086277, 1.76576728, 0.59662641, 0.75515197, 0.56771245],
  ),
  (
    [1.8144408, -1.19445267],
    [0.73956515, -0.45954404, 0.08285427, 0.12541073, -0.14503204],
  ),
  (
    [0.13110758, 1.81333971],
    [1.35733652, -0.00915799, -1.1513021, -0.50559606, 0.00692167],
  ),
]

///|
/// 沿 (a, b) 方向的 LMS 变化率（LAB_TO_LMS 的 a / b 两列）。
fn lms_slopes(a : Double, b : Double) -> Array[Double] {
  let slopes : Array[Double] = []
  for row in lab_to_lms {
    slopes.push(row[1] * a + row[2] * b)
  }
  slopes
}

///|
/// 该色相方向在 sRGB 里的最大饱和度（多项式拟合 + 一次 Halley 迭代）。
fn max_saturation(a : Double, b : Double) -> Double {
  let mut channel = 2
  let mut index = 0
  while index < 2 {
    let edge = saturation_fit[index].0
    if edge[0] * a + edge[1] * b > 1.0 {
      channel = index
      break
    }
    index = index + 1
  }
  let coefficients = saturation_fit[channel].1
  let weights = lms_to_linear_srgb[channel]
  let slopes = lms_slopes(a, b)
  let mut saturation = coefficients[0] +
    coefficients[1] * a +
    coefficients[2] * b +
    coefficients[3] * a * a +
    coefficients[4] * a * b
  let base : Array[Double] = []
  let mut i = 0
  while i < 3 {
    base.push(1.0 + saturation * slopes[i])
    i = i + 1
  }
  let mut f = 0.0
  let mut f1 = 0.0
  let mut f2 = 0.0
  let mut i = 0
  while i < 3 {
    let squared = base[i] * base[i]
    f = f + weights[i] * squared * base[i]
    f1 = f1 + weights[i] * 3.0 * slopes[i] * squared
    f2 = f2 + weights[i] * 6.0 * slopes[i] * slopes[i] * base[i]
    i = i + 1
  }
  saturation = saturation - f * f1 / (f1 * f1 - 0.5 * f * f2)
  saturation
}

///|
/// 该色相最饱和颜色的 (L, C)。
fn cusp(a : Double, b : Double) -> (Double, Double) {
  let saturation = max_saturation(a, b)
  let (r, g, bl) = oklab_to_linear_srgb(1.0, saturation * a, saturation * b)
  let lightness = @math.cbrt(1.0 / max3(r, g, bl))
  (lightness, lightness * saturation)
}

///|
fn max3(a : Double, b : Double, c : Double) -> Double {
  let mut out = a
  if b > out {
    out = b
  }
  if c > out {
    out = c
  }
  out
}

///|
/// 等亮度线上 sRGB 边界的最大 chroma。
fn max_chroma(
  a : Double,
  b : Double,
  lightness : Double,
  cusp_l : Double,
  cusp_c : Double,
) -> Double {
  if lightness <= cusp_l {
    return cusp_c * lightness / cusp_l
  }
  let t = cusp_c * (lightness - 1.0) / (cusp_l - 1.0)
  let slopes = lms_slopes(a, b)
  let cubes : Array[Double] = []
  let currents : Array[Double] = []
  let squares : Array[Double] = []
  let mut i = 0
  while i < 3 {
    let value = lightness + t * slopes[i]
    cubes.push(value * value * value)
    currents.push(3.0 * slopes[i] * value * value)
    squares.push(6.0 * slopes[i] * slopes[i] * value)
    i = i + 1
  }
  let mut best = 1.0e308
  for row in lms_to_linear_srgb {
    let f = row[0] * cubes[0] + row[1] * cubes[1] + row[2] * cubes[2] - 1.0
    let f1 = row[0] * currents[0] + row[1] * currents[1] + row[2] * currents[2]
    let f2 = row[0] * squares[0] + row[1] * squares[1] + row[2] * squares[2]
    let u = f1 / (f1 * f1 - 0.5 * f * f2)
    let step = if u >= 0.0 { -f * u } else { 1.0e308 }
    if step < best {
      best = step
    }
  }
  t + best
}

///|
/// OKHSL 在给定 L 和色相方向上的三个 chroma 锚点：(c0, cMid, cMax)。
fn chroma_stops(l : Double, a : Double, b : Double) -> (Double, Double, Double) {
  let (cusp_l, cusp_c) = cusp(a, b)
  let c_max = max_chroma(a, b, l, cusp_l, cusp_c)
  let peak_ratio = cusp_c / cusp_l
  let low = l * peak_ratio
  let high = (1.0 - l) * (cusp_c / (1.0 - cusp_l))
  let k = c_max / (if low < high { low } else { high })
  let mid_s = 0.11516993 +
    1.0 /
    (
      7.4477897 +
      4.1590124 * b +
      a *
      (
        -2.19557347 +
        1.75198401 * b +
        a *
        (
          -2.13704948 -
          10.02301043 * b +
          a * (-4.24894561 + 5.38770819 * b + 4.69891013 * a)
        )
      )
    )
  let mid_t = 0.11239642 +
    1.0 /
    (
      1.6132032 -
      0.68124379 * b +
      a *
      (
        0.40370612 +
        0.90148123 * b +
        a *
        (
          -0.27087943 +
          0.6122399 * b +
          a * (0.00299215 - 0.45399568 * b - 0.14661872 * a)
        )
      )
    )
  let left = pow_of(l * mid_s, 4.0)
  let right = pow_of((1.0 - l) * mid_t, 4.0)
  let c_mid = 0.9 * k * sqrt_of(sqrt_of(1.0 / (1.0 / left + 1.0 / right)))
  let low_term = pow_of(l * 0.4, 2.0)
  let high_term = pow_of((1.0 - l) * 0.8, 2.0)
  let c0 = sqrt_of(1.0 / (1.0 / low_term + 1.0 / high_term))
  (c0, c_mid, c_max)
}

///|
/// OKHSL → sRGB（0-255，出界裁剪）。
pub fn okhsl_to_rgb(
  hue : Double,
  saturation : Double,
  lightness : Double,
) -> (Int32, Int32, Int32) {
  let l = okhsl_to_oklab_lightness(lightness)
  if l <= 0.0 || l >= 1.0 || saturation <= 0.0 {
    return linear_srgb_to_rgb(oklab_to_linear_srgb(l, 0.0, 0.0))
  }
  let angle = 2.0 * 3.141592653589793 * ((hue % 360.0 + 360.0) % 360.0) / 360.0
  let a = @math.cos(angle)
  let b = @math.sin(angle)
  let (c0, c_mid, c_max) = chroma_stops(l, a, b)
  let chroma = if saturation < 0.8 {
    let t = 1.25 * saturation
    let kc = 0.8 * c0
    t * kc / (1.0 - (1.0 - kc / c_mid) * t)
  } else {
    let t = 5.0 * (saturation - 0.8)
    let kc = 0.2 * c_mid * c_mid * 1.25 * 1.25 / c0
    c_mid + t * kc / (1.0 - (1.0 - kc / (c_max - c_mid)) * t)
  }
  linear_srgb_to_rgb(oklab_to_linear_srgb(l, chroma * a, chroma * b))
}

///|
/// OKLCH → sRGB；出界时降 chroma（二分 20 步，与 pi 同一条路）。
pub fn oklch_to_rgb(
  lightness : Double,
  chroma : Double,
  hue : Double,
) -> (Int32, Int32, Int32) {
  let radians = hue * 3.141592653589793 / 180.0
  let cos = @math.cos(radians)
  let sin = @math.sin(radians)
  let direct = oklab_to_linear_srgb(lightness, chroma * cos, chroma * sin)
  if in_gamut(direct) {
    return linear_srgb_to_rgb(direct)
  }
  let mut linear = oklab_to_linear_srgb(lightness, 0.0, 0.0)
  let mut low = 0.0
  let mut high = chroma
  let mut step = 0
  while step < 20 {
    let candidate_chroma = (low + high) / 2.0
    let candidate = oklab_to_linear_srgb(
      lightness,
      candidate_chroma * cos,
      candidate_chroma * sin,
    )
    if in_gamut(candidate) {
      low = candidate_chroma
      linear = candidate
    } else {
      high = candidate_chroma
    }
    step = step + 1
  }
  linear_srgb_to_rgb(linear)
}

///|
fn in_gamut(linear : (Double, Double, Double)) -> Bool {
  let epsilon = 1.0e-7
  let (r, g, b) = linear
  r >= -epsilon &&
  r <= 1.0 + epsilon &&
  g >= -epsilon &&
  g <= 1.0 + epsilon &&
  b >= -epsilon &&
  b <= 1.0 + epsilon
}
