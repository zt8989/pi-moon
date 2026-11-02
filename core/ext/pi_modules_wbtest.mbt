// resolve_pi_modules：找 pi 装机里的 node_modules。
//
// 真机上 pi 的装法不止一种，这里把每种形状都做成夹具（不依赖本机装了什么）：
//   - pi 自己管理的装机：`<agent dir>/install/releases/<版本>/node_modules`；
//   - 扩展装的包：`<agent dir>/npm/node_modules`；
//   - **npm 全局装机**：扩展的 import 只能从全局 node_modules 根解析 ——
//     那个目录不在 agent 目录下面，得靠 PATH 上的全局 bin / 前缀推出来。
//     pi 由 `npm i -g` / nvm / scoop 装时都是这一种，也是「一条诊断就把全部扩展
//     关掉」的那个现场。
//
// 夹具复用 ext_wbtest 的 make_dir / put（同包）。

///|
/// 造一份干净的 env：只留 PATH（与宿主平台的路径分隔符口径一致），
/// 顺带避开真实环境里可能已经设了的 `PI_PI_MODULES`。
fn sandbox_env(path : String) -> Map[String, String] {
  let vars : Map[String, String] = Map([])
  if @tools.is_windows_env(@env.get_env_vars()) {
    vars.set("SystemRoot", "C:\\Windows")
  }
  vars.set("PATH", path)
  vars
}

///|
fn marker_at(modules_dir : String) -> String {
  modules_dir + "/@earendil-works/pi-coding-agent/package.json"
}

///|
fn found_or_fail(found : String?) -> String raise {
  match found {
    Some(path) => path
    None => fail("期望找到 pi 的 node_modules，实际没有")
  }
}

///|
/// 一个「像真机那样」的 agent 目录：`npm/node_modules` 存在，但里面装的是
/// 扩展的包，没有 pi 自己 —— 光看这里会判成「这台机器没装 pi」。
async fn agent_dir_with_ext_packages(root : String) -> String {
  let agent = root + "/agent"
  put(agent + "/npm/node_modules/demo-pkg/package.json", "{}")
  agent
}

///|
async test "resolve_pi_modules：npm 全局装机（bin 与 node_modules 同前缀）" {
  let root = make_dir("pi-modules-global")
  let agent = agent_dir_with_ext_packages(root)
  let prefix = root + "/nodejs/v24.21.0"
  put(marker_at(prefix + "/node_modules"), "{}")
  let found = resolve_pi_modules(agent, env=sandbox_env(prefix))
  assert_eq(found_or_fail(found), prefix + "/node_modules")
}

///|
async test "resolve_pi_modules：npm 全局装机（PATH 上是 bin，包在 ../lib 下）" {
  let root = make_dir("pi-modules-prefix")
  let agent = agent_dir_with_ext_packages(root)
  let prefix = root + "/usr/local"
  put(marker_at(prefix + "/lib/node_modules"), "{}")
  let found = resolve_pi_modules(agent, env=sandbox_env(prefix + "/bin"))
  assert_eq(found_or_fail(found), prefix + "/lib/node_modules")
}

///|
async test "resolve_pi_modules：PATH 上有多段时，只有装着 pi 的那段算" {
  let root = make_dir("pi-modules-multi")
  let agent = agent_dir_with_ext_packages(root)
  let filler = root + "/filler"
  let prefix = root + "/nodejs/v24.21.0"
  put(marker_at(prefix + "/node_modules"), "{}")
  let separator = if @tools.is_windows_env(@env.get_env_vars()) {
    ";"
  } else {
    ":"
  }
  let path = filler + separator + prefix + separator + root + "/other"
  let found = resolve_pi_modules(agent, env=sandbox_env(path))
  assert_eq(found_or_fail(found), prefix + "/node_modules")
}

///|
async test "resolve_pi_modules：agent 目录里的两种装法优先于 PATH" {
  let root = make_dir("pi-modules-order")
  let agent = agent_dir_with_ext_packages(root)
  let from_path = root + "/nodejs/v24.21.0"
  put(marker_at(from_path + "/node_modules"), "{}")
  let env = sandbox_env(from_path)
  // `install/releases` 里有多个版本时取版本号最大的那份（不是字典序）。
  put(marker_at(agent + "/install/releases/0.9.0/node_modules"), "{}")
  put(marker_at(agent + "/install/releases/0.10.0/node_modules"), "{}")
  let found = resolve_pi_modules(agent, env=env)
  assert_eq(found_or_fail(found), agent + "/install/releases/0.10.0/node_modules")
  // `PI_PI_MODULES` 比一切都先。
  env.set("PI_PI_MODULES", from_path + "/node_modules")
  let explicit = resolve_pi_modules(agent, env=env)
  assert_eq(found_or_fail(explicit), from_path + "/node_modules")
}

///|
async test "resolve_pi_modules：一个都没有时返回 None（扩展整体关闭）" {
  let root = make_dir("pi-modules-none")
  let agent = agent_dir_with_ext_packages(root)
  // PATH 上有 node_modules 目录，但里面没有 pi 的包 —— 不算。
  let prefix = root + "/nodejs/v24.21.0"
  put(prefix + "/node_modules/some-other-pkg/package.json", "{}")
  let found = resolve_pi_modules(agent, env=sandbox_env(prefix))
  match found {
    Some(path) => fail("期望 None，实际 " + path)
    None => ()
  }
}
