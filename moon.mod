// pi-moon：用 MoonBit 复刻 event-loop-agent。
//
// 形状照搬原项目：reducer 是纯函数，返回 (state, Cmd[])；Cmd 是**数据**，
// 由运行时解释执行。环不是写出来的 while 循环，是 action → reducer → Cmd →
// effect → action 自己接起来的。
name = "pi-moon"

version = "0.7.0"

readme = "README.md"

repository = ""

license = "Apache-2.0"

keywords = [ "agent", "elm", "tea", "loop" ]

preferred_target = "native"

description = "Elm-architecture code agent core with a pi-compatible OpenAI provider, in MoonBit"

import {
  "conglinyizhi/moonbit-llm-faceoff@0.2.0",
  "moonbitlang/async@0.21.3",
  // TUI：mizchi/tui 0.10.2 钉的传递依赖里有三个还是旧的 moon.mod.json 格式，
  // 当前 moon 拒绝安装。显式列成已迁移的版本，解析器就会用能装的那一份。
  // 上游换成新清单后，这一整段可以缩成 "mizchi/tui@0.10.2" 一行。
  "mizchi/tui@0.10.2",
  "mizchi/tui-terminal-buffer@0.1.4",
  "mizchi/crater-core@0.19.0",
  "mizchi/crater-layout@0.19.1",
  "mizchi/css@0.7.4",
  "mizchi/layout@0.2.1",
  "mizchi/signals@0.6.5",
  "mizchi/syntree@0.2.4",
}
