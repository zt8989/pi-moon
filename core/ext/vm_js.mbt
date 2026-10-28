// js 后端：还没接。
//
// node 上有现成的 `quickjs-wasi`（pi 自己用的就是它），接法是 `import()` 之后
// 复用同一套快照格式 —— 但 pi-moon 的 js 目标目前只用来跑测试与管道模式，
// 扩展装载先只保证 native。留着这一份是为了让上层签名两端一致：谁在 js 上
// 用扩展，会拿到一条明确的「没实现」，而不是编译期就分叉。

///|
pub fn ExtVm::new(wasm : Bytes) -> ExtVm raise VmError {
  let _ = wasm
  raise VmUnsupported
}

///|
pub fn ExtVm::eval(self : ExtVm, code : String, filename? : String = "<ext>") -> String raise VmError {
  let _ = (self, code, filename)
  raise VmUnsupported
}

///|
pub fn ExtVm::snapshot(self : ExtVm) -> Bytes raise VmError {
  let _ = self
  raise VmUnsupported
}

///|
pub fn ExtVm::restore(wasm : Bytes, snapshot : Bytes) -> ExtVm raise VmError {
  let _ = (wasm, snapshot)
  raise VmUnsupported
}

///|
pub fn ExtVm::quickjs_version(self : ExtVm) -> String {
  let _ = self
  ""
}

///|
pub fn ExtVm::free(self : ExtVm) -> Unit {
  let _ = self
  ()
}
