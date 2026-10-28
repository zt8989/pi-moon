// js 后端：直接复用 node 上的 `quickjs-wasi`（pi 装机里那份）。
//
// 沙盒语义与 native 完全一致 —— 同一份 `quickjs.wasm`、同一种快照格式
// （"QJSS" v2）。差别只有宿主：native 是 vendored wasm3 + 自己写的 WASI shim，
// 这里是 quickjs-wasi 自带的 npm 实现。
//
// 两条约束照 core/sys 的老规矩：
//   1. JS 异常不能穿过 extern 边界（会打断 async 驱动器），所以桥接里每个入口
//      自己 try/catch，把原因写进 `globalThis.__pi_moon_ext_error`，MoonBit 侧
//      再变回 `VmError`；
//   2. `quickjs-wasi` 是 ESM（`"type": "module"`），moon 产出的 CJS 脚本只能
//      用 `await import()` 加载它 —— 于是 create / restore 是异步的，用
//      `@js_async.Promise` 桥回来。
//
// VM 句柄：JS 对象塞不进 Int64，于是进程内维护一张 `id → VM` 的 Map，
// `handle` 就是那个 id。对上层来说与 native 的「不透明整数句柄」没有区别。

///|
/// 一次性装好桥接：`globalThis.__pi_moon_ext`。
///
/// 之所以是「装一次」而不是每个 extern 各写一段：VM 注册表、quickjs-wasi 的
/// 模块缓存、id 计数都要进程内共享，重复定义会让缓存的模块实例对不上。
extern "js" fn js_bridge_install() -> Unit =
  #| () => {
  #|   if (globalThis.__pi_moon_ext) { return }
  #|   const nodePath = require('node:path')
  #|   const nodeUrl = require('node:url')
  #|   const vms = new Map()
  #|   let nextId = 1
  #|   let quickjs = null
  #|   const fail = (error) => {
  #|     globalThis.__pi_moon_ext_error = String((error && error.message) || error)
  #|   }
  #|   const load = async (packageDir) => {
  #|     if (quickjs) { return quickjs }
  #|     const candidates = []
  #|     if (packageDir && packageDir.length > 0) {
  #|       candidates.push(nodeUrl.pathToFileURL(nodePath.join(packageDir, 'dist', 'index.js')).href)
  #|     }
  #|     if (process.env.PI_QUICKJS_WASM) {
  #|       candidates.push(nodeUrl.pathToFileURL(
  #|         nodePath.join(nodePath.dirname(process.env.PI_QUICKJS_WASM), 'dist', 'index.js')).href)
  #|     }
  #|     candidates.push('quickjs-wasi')
  #|     let lastError = null
  #|     for (const spec of candidates) {
  #|       try { quickjs = await import(spec); return quickjs } catch (error) { lastError = error }
  #|     }
  #|     throw lastError || new Error('找不到 quickjs-wasi 包')
  #|   }
  #|   const adopt = (vm) => {
  #|     const id = nextId
  #|     nextId += 1
  #|     vms.set(id, vm)
  #|     return id
  #|   }
  #|   globalThis.__pi_moon_ext = {
  #|     create: async (wasm, packageDir) => {
  #|       try {
  #|         const mod = await load(packageDir)
  #|         return adopt(await mod.QuickJS.create({ wasm }))
  #|       } catch (error) { fail(error); return 0 }
  #|     },
  #|     restore: async (wasm, snapshot, packageDir) => {
  #|       try {
  #|         const mod = await load(packageDir)
  #|         const restored = await mod.QuickJS.restore(
  #|           mod.QuickJS.deserializeSnapshot(snapshot), { wasm })
  #|         return adopt(restored)
  #|       } catch (error) { fail(error); return 0 }
  #|     },
  #|     eval: (id, code, filename) => {
  #|       const vm = vms.get(id)
  #|       if (!vm) { fail(new Error('VM 句柄不存在')); return '' }
  #|       try {
  #|         const handle = vm.evalCode(code, filename)
  #|         try { return handle.toString() } finally { handle.dispose() }
  #|       } catch (error) { fail(error); return '' }
  #|     },
  #|     snapshot: (id) => {
  #|       const vm = vms.get(id)
  #|       if (!vm) { fail(new Error('VM 句柄不存在')); return new Uint8Array(0) }
  #|       try { return quickjs.QuickJS.serializeSnapshot(vm.snapshot()) }
  #|       catch (error) { fail(error); return new Uint8Array(0) }
  #|     },
  #|     free: (id) => {
  #|       const vm = vms.get(id)
  #|       vms.delete(id)
  #|       try { if (vm) { vm.dispose() } } catch (error) {}
  #|     },
  #|     version: (id) => {
  #|       const vm = vms.get(id)
  #|       try { return vm ? String(vm.versions.quickjs) : '' } catch (error) { return '' }
  #|     },
  #|     takeError: () => {
  #|       const text = globalThis.__pi_moon_ext_error || ''
  #|       globalThis.__pi_moon_ext_error = ''
  #|       return text
  #|     }
  #|   }
  #| }

///|
extern "js" fn js_vm_create(wasm : Bytes, package_dir : String) -> @js_async.Promise[Int] =
  #| (wasm, packageDir) => globalThis.__pi_moon_ext.create(wasm, packageDir)

///|
extern "js" fn js_vm_restore(
  wasm : Bytes,
  snapshot : Bytes,
  package_dir : String,
) -> @js_async.Promise[Int] =
  #| (wasm, snapshot, packageDir) =>
  #|   globalThis.__pi_moon_ext.restore(wasm, snapshot, packageDir)

///|
extern "js" fn js_vm_eval(id : Int, code : String, filename : String) -> String =
  #| (id, code, filename) => globalThis.__pi_moon_ext.eval(id, code, filename)

///|
extern "js" fn js_vm_snapshot(id : Int) -> Bytes =
  #| (id) => globalThis.__pi_moon_ext.snapshot(id)

///|
extern "js" fn js_vm_free(id : Int) -> Unit =
  #| (id) => globalThis.__pi_moon_ext.free(id)

///|
extern "js" fn js_vm_version(id : Int) -> String =
  #| (id) => globalThis.__pi_moon_ext.version(id)

///|
extern "js" fn js_take_error() -> String =
  #| () => globalThis.__pi_moon_ext.takeError()

///|
/// 把桥接里攒下的错误取出来（空串表示没有）。
fn take_error() -> String {
  js_take_error()
}

///|
pub async fn ExtVm::new(wasm : Bytes, host? : String = "") -> ExtVm raise VmError {
  js_bridge_install()
  let id = try @js_async.Promise::wait(js_vm_create(wasm, host)) catch {
    error => raise VmInit(error.to_string())
  }
  if id <= 0 {
    let reason = take_error()
    raise VmInit(if reason.is_empty() { "quickjs-wasi 起不来" } else { reason })
  }
  { handle: id.to_int64() }
}

///|
pub fn ExtVm::eval(self : ExtVm, code : String, filename? : String = "<ext>") -> String raise VmError {
  js_bridge_install()
  let text = js_vm_eval(self.handle.to_int(), code, filename)
  let error = take_error()
  if !error.is_empty() {
    raise VmEval(error)
  }
  text
}

///|
pub fn ExtVm::snapshot(self : ExtVm) -> Bytes raise VmError {
  js_bridge_install()
  let bytes = js_vm_snapshot(self.handle.to_int())
  let error = take_error()
  if !error.is_empty() {
    raise VmSnapshot(error)
  }
  if bytes.length() == 0 {
    raise VmSnapshot("快照为空")
  }
  bytes
}

///|
pub async fn ExtVm::restore(wasm : Bytes, snapshot : Bytes, host? : String = "") -> ExtVm raise VmError {
  js_bridge_install()
  let id = try @js_async.Promise::wait(js_vm_restore(wasm, snapshot, host)) catch {
    error => raise VmInit(error.to_string())
  }
  if id <= 0 {
    let reason = take_error()
    raise VmInit(if reason.is_empty() { "快照恢复失败" } else { reason })
  }
  { handle: id.to_int64() }
}

///|
pub fn ExtVm::quickjs_version(self : ExtVm) -> String {
  js_bridge_install()
  js_vm_version(self.handle.to_int())
}

///|
pub fn ExtVm::free(self : ExtVm) -> Unit {
  js_bridge_install()
  js_vm_free(self.handle.to_int())
}
