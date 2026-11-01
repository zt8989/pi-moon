// prepare 级的整条链路：一次启动里三类扩展的归宿。
//
// 装载结果（横幅）与运行期名册（call/emit）是两份：宿主装载成功的扩展都在
// 前者里 —— 包括没注册任何东西、进程被当场收掉的。缺 bun 时整组跳过。
//
// 夹具不用真 pi 的 node_modules：扩展都不 import 任何包，agent 目录里放一个
// 带 marker 的假 node_modules 就够 resolve_pi_modules 认（env 里设了
// PI_PI_MODULES 的话优先用它，同样成立）。目录与落盘 helper 复用
// host_wbtest / ext_wbtest 的（同包）。

///|
async test "prepare：装载结果列全名册，运行期名册只收注册了工具/事件的" {
  let root = host_root()
  // 假 pi node_modules：只需要 marker 文件。
  put(
    root +
    "/install/releases/0.0.0-test/node_modules/@earendil-works/pi-coding-agent/package.json",
    "{}",
  )
  // 三类扩展：只注命令（收掉）、注册工具（进名册）、什么都不注（收掉）。
  put(
    root + "/extensions/cmd.js",
    "export default function (pi) { pi.registerCommand('hi', { description: 'cmd', handler: async () => 'ok' }) }\n",
  )
  put(
    root + "/extensions/probe.js",
    "export default function (pi) { pi.registerTool({ name: 'probe_tool', description: '' }) }\n",
  )
  put(root + "/extensions/quiet.ts", "export default function (pi) { void pi }\n")
  let startup = prepare_at_startup(root, root)
  if !startup.available {
    // 缺 bun / 缺模块：环境缺失，不是回归 —— 与 host_wbtest 同规跳过。
    return
  }
  // 装载结果：三个都在，顺序即发现顺序（字典序）。名字是去后缀的 stem，
  // 标签是文件名。
  assert_eq(startup.names, ["cmd", "probe", "quiet"])
  assert_eq(startup.labels, ["cmd.js", "probe.js", "quiet.ts"])
  // 运行期名册：只有注册了工具的 probe。
  assert_false(startup.runtime.is_empty())
  assert_true(startup.runtime.owns("probe_tool"))
  // 收掉的两类各有诊断，说清楚为什么不会动。
  assert_true(
    startup
    .diagnostics
    .any(fn(d) { d.contains("cmd") && d.contains("只注册了斜杠命令") }),
  )
  assert_true(
    startup
    .diagnostics
    .any(fn(d) { d.contains("quiet") && d.contains("没注册任何工具/命令/事件") }),
  )
  startup.runtime.close()
}

///|
async test "prepare：包扩展走同一条装载管线，标签带包名前缀" {
  let root = host_root()
  put(
    root +
    "/install/releases/0.0.0-test/node_modules/@earendil-works/pi-coding-agent/package.json",
    "{}",
  )
  put(
    root + "/npm/node_modules/demo-pkg/dist/index.js",
    "export default function (pi) { pi.registerTool({ name: 'pkg_tool', description: '' }) }\n",
  )
  let packages : Array[PackageExtension] = [
    {
      package: "demo-pkg",
      dir: root + "/npm/node_modules/demo-pkg",
      entry: "dist",
    },
  ]
  let startup = prepare_at_startup(root, root, packages~)
  if !startup.available {
    // 缺 bun / 缺模块：环境缺失，不是回归。
    return
  }
  assert_eq(startup.labels, ["demo-pkg:dist"])
  assert_true(startup.runtime.owns("pkg_tool"))
  startup.runtime.close()
}
