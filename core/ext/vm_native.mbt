// native 后端：wasm3 上的 `quickjs.wasm`（C 实现在 host/ext_host.c）。
//
// 这里只做三件事：把 MoonBit 的 Bytes 递给 C、把结果拷回来、把错误码翻成
// `VmError`。所有 wasm 细节（实例化、WASI import、快照布局）都在 C 里。

///|
#borrow(wasm)
extern "c" fn pim_ext_vm_new(wasm : Bytes, wasm_len : Int) -> Int64 = "pim_ext_vm_new"

///|
extern "c" fn pim_ext_vm_free(handle : Int64) -> Unit = "pim_ext_vm_free"

///|
extern "c" fn pim_ext_vm_init(handle : Int64) -> Int = "pim_ext_vm_init"

///|
#borrow(code)
#borrow(filename)
extern "c" fn pim_ext_vm_eval(
  handle : Int64,
  code : Bytes,
  code_len : Int,
  filename : Bytes,
  filename_len : Int,
) -> Int = "pim_ext_vm_eval"

///|
extern "c" fn pim_ext_result_len(handle : Int64) -> Int = "pim_ext_result_len"

///|
#borrow(out)
extern "c" fn pim_ext_result_copy(handle : Int64, out : Bytes, cap : Int) -> Int = "pim_ext_result_copy"

///|
extern "c" fn pim_ext_error_len() -> Int = "pim_ext_error_len"

///|
#borrow(out)
extern "c" fn pim_ext_error_copy(out : Bytes, cap : Int) -> Int = "pim_ext_error_copy"

///|
extern "c" fn pim_ext_vm_snapshot_len(handle : Int64) -> Int = "pim_ext_vm_snapshot_len"

///|
#borrow(out)
extern "c" fn pim_ext_vm_snapshot_copy(handle : Int64, out : Bytes, cap : Int) -> Int = "pim_ext_vm_snapshot_copy"

///|
#borrow(wasm)
#borrow(snapshot)
extern "c" fn pim_ext_vm_restore(
  wasm : Bytes,
  wasm_len : Int,
  snapshot : Bytes,
  snapshot_len : Int,
) -> Int64 = "pim_ext_vm_restore"

///|
extern "c" fn pim_ext_quickjs_version(handle : Int64) -> Int = "pim_ext_quickjs_version"

///|
/// 取 C 侧「无 VM 的错误文本」。
fn take_global_error() -> String {
  let length = pim_ext_error_len()
  if length <= 0 {
    return "未知错误"
  }
  let buffer = Bytes::new(length)
  let copied = pim_ext_error_copy(buffer, length)
  @utf8.decode_lossy(buffer[:copied])
}

///|
/// 取某个 VM 的结果缓冲。
fn take_result(handle : Int64) -> String {
  let length = pim_ext_result_len(handle)
  if length <= 0 {
    return ""
  }
  let buffer = Bytes::new(length)
  let copied = pim_ext_result_copy(handle, buffer, length)
  @utf8.decode_lossy(buffer[:copied])
}

///|
/// 开工：实例化 + `_initialize` + `qjs_init`。
pub fn ExtVm::new(wasm : Bytes) -> ExtVm raise VmError {
  let handle = pim_ext_vm_new(wasm, wasm.length())
  if handle == 0L {
    raise VmInit(take_global_error())
  }
  if pim_ext_vm_init(handle) != 0 {
    let reason = take_result(handle)
    pim_ext_vm_free(handle)
    raise VmInit(if reason.is_empty() { "qjs_init 失败" } else { reason })
  }
  { handle }
}

///|
/// 在 VM 里跑一段 JS。返回值为 `qjs_eval` 结果字符串化后的文本。
///
/// 注意：这里只接受「求值后能变成字符串」的结果 —— 扩展源的求值结果一律
/// 被预置脚本包装成 JSON 字符串，见 `prelude.mbt`。
pub fn ExtVm::eval(self : ExtVm, code : String, filename? : String = "<ext>") -> String raise VmError {
  let code_bytes = @utf8.encode(code)
  let name_bytes = @utf8.encode(filename)
  let status = pim_ext_vm_eval(
    self.handle,
    code_bytes,
    code_bytes.length(),
    name_bytes,
    name_bytes.length(),
  )
  let result = take_result(self.handle)
  if status != 0 {
    raise VmEval(result)
  }
  result
}

///|
/// 把整块线性内存拍成快照（含 rt/ctx 指针与栈指针）。
pub fn ExtVm::snapshot(self : ExtVm) -> Bytes raise VmError {
  let length = pim_ext_vm_snapshot_len(self.handle)
  if length <= 0 {
    raise VmSnapshot(take_result(self.handle))
  }
  let buffer = Bytes::new(length)
  let copied = pim_ext_vm_snapshot_copy(self.handle, buffer, length)
  if copied != length {
    raise VmSnapshot("快照拷贝不完整")
  }
  buffer
}

///|
/// 从快照恢复一个 VM。
pub fn ExtVm::restore(wasm : Bytes, snapshot : Bytes) -> ExtVm raise VmError {
  let handle = pim_ext_vm_restore(wasm, wasm.length(), snapshot, snapshot.length())
  if handle == 0L {
    raise VmInit(take_global_error())
  }
  { handle }
}

///|
/// quickjs 自己的版本串（诊断与缓存键用）。
pub fn ExtVm::quickjs_version(self : ExtVm) -> String {
  if pim_ext_quickjs_version(self.handle) <= 0 {
    return ""
  }
  take_result(self.handle)
}

///|
/// 释放 VM。
pub fn ExtVm::free(self : ExtVm) -> Unit {
  pim_ext_vm_free(self.handle)
}
