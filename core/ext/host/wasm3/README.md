# wasm3（vendored）

上游：https://github.com/wasm3/wasm3 （MIT），`main` 分支，2026-10 拉取。

宿主用它跑 pi 的 `quickjs.wasm`：MoonBit 的 native 后端没有 wasm 运行时，
而快照方案又必须在 wasm 里才成立（见 `docs/extensions.md`）。

## 裁掉了什么

只保留解释器本体。以下文件上游有、这里没有，因为 pi-moon 不需要：

- `m3_api_libc.c` / `m3_api_wasi.c` / `m3_api_uvwasi.c` / `m3_api_meta_wasi.c`
  —— 通用 WASI 实现。quickjs 只 import 6 个 WASI 函数，全部在
  `../ext_host.c` 里自己实现（文件系统一律 ENOSYS）。
- `m3_api_tracer.c` —— 调试用。

对应地，`m3_api_*.h` 头文件留着只是因为 `m3_config.h` 会引用它们。

## 编译

不做单独构建：`core/ext/moon.pkg` 的 `native-stub` 直接把 `m3_*.c` 交给
moon 的 C 编译器。没有额外 flag —— 所有 `#include` 都写在同一层目录里。

## 升级时注意

- `ResizeMemory` 与 `m3_GetMemory` 的签名（`ext_host.c` 依赖前者把线性内存
  扩到快照要求的页数）；
- `m3_GetResultsV` 的语义：返回值放在运行时的返回槽里，**任何**下一次
  `m3_CallV` 都会覆盖它。取结果必须紧挨着调用，中间不能插别的 guest 调用。
