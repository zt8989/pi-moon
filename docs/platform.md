# 平台层：native 与 js 各一套实现，上层只认一套 API

`core/sys` 存在的唯一理由：**业务代码不该知道自己在哪个后端上跑**。

## 为什么需要它

`moonbitlang/async` 里真正 native-only 的东西，恰好是本项目离不开的几样：

| 包 | 目标 | 后果 |
| --- | --- | --- |
| `moonbitlang/async/fs` | 文件都标了 `native` / `wasm` | js 上没有文件系统 |
| `moonbitlang/async/process` | 同上 | js 上没有子进程 |
| `moonbitlang/async/stdio` | 同上 | js 上没有标准流对象 |
| `moonbitlang/async/shell` | `supported_targets = "native+wasm"` | **连构建计划都排不出来** |

最后一行是硬伤：`shell` 是从 `moon.pkg` 层面拒绝 js 的。所以平台层不仅要在 js 上
另写实现，还**不能 import `@shell`** —— 连 native 分支也不能，否则 import 表在 js 上
无效。`run_capture` 因此改走 `@process.collect_output`（拿 stdout / stderr / 退出码），
`glob` 改成一份两端共用的 `readdir` 递归实现（见 `glob.mbt`）。

HTTP 不需要平台层：`moonbitlang/async/http` 自带 `client.js.mbt`，js 上走 `fetch`，
native 上走 socket + TLS，`post_stream` 的调用形状完全一样。

## 文件布局

```
core/sys/
  moon.pkg        targets: 每个 *_native.mbt / *_js.mbt 只编到一个后端
  sys.mbt         共用形状：Kind / SysError / now / Capture / cli_args
  glob.mbt        共用实现：readdir 递归 + 段内通配
  fs_native.mbt   @fs 的薄包装
  fs_js.mbt       node:fs（同步 API）+ 错误槽
  proc_native.mbt @process + collect_output + spawn_orphan（常驻子进程）
  proc_js.mbt     node:child_process + promise/abort 桥 + 常驻子进程
  stdio_native.mbt @stdio
  stdio_js.mbt    process.stdout / stderr + readSync(0)
  term_native.mbt tty.c（isatty / VT / 代码页）+ exit
  term_js.mbt     process.stdin.isTTY / process.stdout.isTTY / process.exit
  tty.c           Windows：VT 输出开关 + 代码页切 UTF-8（退出时还原）
```

`targets` 是按文件切的，所以「同名函数在两份文件里各写一遍」是刻意的：两边签名
必须逐字一致，上层才不需要 `if target`。

## 常驻子进程（`Session`）

`spawn` 把子进程挂进 `TaskGroup`：任务组一结束进程就被收掉。扩展宿主不行 ——
它必须活过整个会话（见 [extensions](extensions.md)）。所以另有一套：

```moonbit
let io = @sys.spawn_session("bun", args, cwd=root)   // stdin + 合并的输出管道
io.write(line)
let chunk = io.read_some()
io.close()                                            // 关 stdin，宿主自己退
```

- native：`@process.spawn_orphan`（不挂在任务组上），stdout / stderr 并成一根
  管道；
- js：`child.stdin/stdout/stderr`，`close()` 走 `stdin.end()` —— 让对端的读循环
  看到 EOF，而不是靠发信号（native 侧拿不到跨平台的 kill）。

## 两端签名必须一致（一个必踩的坑）

两边同名函数的**error 类型**也得对得上。例：js 的 `OutputPipe::read_some` 声明是
泛型 `raise`（它要把取消错误原样传出去，不能收窄成 `SysError`），所以
`Session::read_some` 在两端都写 `raise`；写成 `raise SysError` 会在 js 上报
`[4118] The error type is mismatched`。

而这个错**`moon test`（不带 `--target`）抓不到**：它只重编当前目标，js 那串
数字可能来自旧计划。改过 `*_js.mbt` 或跨端共用代码后，两边的门禁都过：

```bash
moon test --target native && moon test --target js
moon check --target js        # 只编不跑，最快
```

## js 侧的四条硬约束

1. **extern "js" 不能抛异常。** JS 异常穿过 extern 边界会打断 async 驱动器
   （表现为 `_async_driver` 里的 `$tag` 崩）。所以每个 extern 自己 `try/catch`，
   把原因写进 `globalThis.__pi_moon_error`，MoonBit 侧用 `raise_pending_error()`
   取出来变回 `SysError`。
2. **失败要能区分「空值」与「出错」。** `read_some` 用「空 `Uint8Array` = EOF」，
   错误则走上面那个槽；`kind` 用 `0/1/2` + 错误槽。
3. **流式取消靠 abort signal。** `js_next(pipe, signal)` 返回一个 promise，取消时
   监听器 kill 子进程并 reject；MoonBit 侧 `@js_async.run_promise` 负责把
   coroutine 取消与 promise 生命周期接上。**读循环里不要 `catch` 掉取消**
   —— 那是 Esc 能掐断长命令的原因。
4. **`require` 可用**：moon 产出的 js 是单文件脚本（没有顶层 `import`/`export`），
   node 按 CJS 执行，同步 extern 里可以直接 `require('node:fs')`。需要 `await
   import()` 的写法只用在 async extern 里（vendored tui 的 `io_js.mbt` 就是这么写的）。

## 与 native 的行为差异（有意为之）

| 事项 | native | js |
| --- | --- | --- |
| 控制台代码页 | `tty.c` 切 UTF-8，退出还原 | Node 自己按控制台 API 写，不用管 |
| VT 输出开关 | `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)` | 空操作（libuv 已开） |
| REPL 逐行读 | `@stdio.stdin.read_until` | 同步 `readSync(0)` + 缓冲，遇 `EAGAIN` 重试 |
| argv | `[exe, ...]` | `[node, script, ...]`（`args_skip()` 吸收差量） |
| 子进程输出 | 一根 `@process` 管道，stdout/stderr 合并 | 一根 JS 队列，stdout/stderr 合并到同一个 `pipe` |
| 一次性命令超时 | `@async.with_timeout` 包 `collect_output` | `setTimeout` 里 `kill()` |

## 要加一个新平台函数时

1. 在 `sys.mbt` 里定义共用形状（类型、错误），或直接加进 `fs_*` / `proc_*` / `stdio_*` / `term_*`；
2. 两份实现文件里写**同名同签名**的函数；
3. `moon build` 与 `moon build --target js` 都要过；
4. 如果新函数只在一个后端有意义（比如 `tty.c`），把它放在该后端的文件里，
   调用方用 shared 函数分派，别让上层看见 `target`。

## 已知缺口

- js 端的 `rg` / `where` / `pwsh` 仍然靠 PATH 里真有的可执行文件；找不到就走
  glob 退路（与 native 同一条逻辑）。
- js 端没有实现 `--show-tool-progress` 之外的进度差异 —— 流式进度两端都有
  （`read_some` 逐块给）。
- 平台层不做代理：`@http` 在两端都不读 `HTTPS_PROXY`（见 [provider](provider.md)）。
