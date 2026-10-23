// pi-moon：用 MoonBit 复刻 event-loop-agent。
//
// 形状照搬原项目：reducer 是纯函数，返回 (state, Cmd[])；Cmd 是**数据**，
// 由运行时解释执行。环不是写出来的 while 循环，是 action → reducer → Cmd →
// effect → action 自己接起来的。
name = "zhouteng/pi_moon"

version = "0.4.0"

readme = "README.md"

repository = ""

license = "Apache-2.0"

keywords = [ "agent", "elm", "tea", "loop" ]

preferred_target = "native"

description = "Elm-architecture code agent core with a pi-compatible OpenAI provider, in MoonBit"

import {
  "conglinyizhi/moonbit-llm-faceoff@0.2.0",
  "moonbitlang/async@0.21.3",
}
