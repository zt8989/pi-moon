// 文件系统：js 侧直接调 Node 的 fs。
//
// Node 抛出的异常不能穿过 extern 边界（会打断 async 驱动器），所以每个 extern
// 都自己 try/catch，把原因写进 `globalThis.__pi_moon_error`，由 `raise_pending_error()` 取出来
// 变回 MoonBit 错误。

///|
extern "js" fn js_take_error() -> String =
  #| () => {
  #|   const e = globalThis.__pi_moon_error || ''
  #|   globalThis.__pi_moon_error = ''
  #|   return e
  #| }

///|
fn raise_pending_error() -> Unit raise SysError {
  let error = js_take_error()
  if !error.is_empty() {
    raise SysError(error)
  }
}

///|
extern "js" fn js_read_text(path : String) -> String =
  #| (path) => {
  #|   try { return require('node:fs').readFileSync(path, 'utf8') }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return '' }
  #| }

///|
extern "js" fn js_read_bytes(path : String) -> Bytes =
  #| (path) => {
  #|   try { return new Uint8Array(require('node:fs').readFileSync(path)) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return new Uint8Array(0) }
  #| }

///|
extern "js" fn js_write_text(
  path : String,
  content : String,
  append : Bool,
) -> Unit =
  #| (path, content, append) => {
  #|   try {
  #|     const fs = require('node:fs')
  #|     if (append) { fs.appendFileSync(path, content, 'utf8') }
  #|     else { fs.writeFileSync(path, content, 'utf8') }
  #|   } catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e) }
  #| }

///|
extern "js" fn js_write_bytes(path : String, content : Bytes) -> Unit =
  #| (path, content) => {
  #|   try { require('node:fs').writeFileSync(path, content) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e) }
  #| }

///|
extern "js" fn js_exists(path : String) -> Bool =
  #| (path) => require('node:fs').existsSync(path)

///|
extern "js" fn js_kind(path : String) -> Int =
  #| (path) => {
  #|   try {
  #|     const st = require('node:fs').statSync(path)
  #|     if (st.isFile()) { return 1 }
  #|     if (st.isDirectory()) { return 2 }
  #|     return 0
  #|   } catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return 0 }
  #| }

///|
extern "js" fn js_readdir(path : String, include_hidden : Bool) -> Array[String] =
  #| (path, include_hidden) => {
  #|   try {
  #|     const names = require('node:fs').readdirSync(path).map(String)
  #|     return include_hidden ? names : names.filter((n) => !n.startsWith('.'))
  #|   } catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return [] }
  #| }

///|
extern "js" fn js_mkdir_p(path : String) -> Unit =
  #| (path) => {
  #|   try { require('node:fs').mkdirSync(path, { recursive: true }) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e) }
  #| }

///|
extern "js" fn js_tmpdir(prefix : String) -> String =
  #| (prefix) => {
  #|   try {
  #|     const fs = require('node:fs')
  #|     const os = require('node:os')
  #|     const path = require('node:path')
  #|     return fs.mkdtempSync(path.join(os.tmpdir(), prefix + '-'))
  #|   } catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return '' }
  #| }

///|
pub async fn read_bytes(path : String) -> Bytes raise SysError {
  let bytes = js_read_bytes(path)
  raise_pending_error()
  bytes
}

///|
pub async fn read_text(path : String) -> String raise SysError {
  let text = js_read_text(path)
  raise_pending_error()
  text
}

///|
pub async fn write_text(
  path : String,
  content : String,
  append? : Bool = false,
) -> Unit raise SysError {
  js_write_text(path, content, append)
  raise_pending_error()
}

///|
pub async fn write_bytes(path : String, content : Bytes) -> Unit raise SysError {
  js_write_bytes(path, content)
  raise_pending_error()
}

///|
pub async fn exists(path : String) -> Bool raise SysError {
  js_exists(path)
}

///|
pub async fn kind(path : String) -> Kind raise SysError {
  let kind = js_kind(path)
  raise_pending_error()
  if kind == 1 {
    Regular
  } else if kind == 2 {
    Directory
  } else {
    Other
  }
}

///|
pub async fn readdir(
  path : String,
  include_hidden? : Bool = true,
) -> Array[String] raise SysError {
  let names = js_readdir(path, include_hidden)
  raise_pending_error()
  names
}

///|
pub async fn mkdir_p(path : String) -> Unit raise SysError {
  js_mkdir_p(path)
  raise_pending_error()
}

///|
pub async fn tmpdir(prefix : String) -> String raise SysError {
  let path = js_tmpdir(prefix)
  raise_pending_error()
  path
}

///|
extern "js" fn js_mtime(path : String) -> Int64 =
  #| (path) => {
  #|   try { return BigInt(Math.floor(require('node:fs').statSync(path).mtimeMs)) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return 0n }
  #| }

///|
extern "js" fn js_file_size(path : String) -> Int64 =
  #| (path) => {
  #|   try { return BigInt(require('node:fs').statSync(path).size) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e); return 0n }
  #| }

///|
pub async fn mtime(path : String) -> Int64 raise SysError {
  let value = js_mtime(path)
  raise_pending_error()
  value
}

///|
pub async fn file_size(path : String) -> Int64 raise SysError {
  let value = js_file_size(path)
  raise_pending_error()
  value
}

///|
extern "js" fn js_remove_dir(path : String) -> Unit =
  #| (path) => {
  #|   try { require('node:fs').rmSync(path, { recursive: true, force: true }) }
  #|   catch (e) { globalThis.__pi_moon_error = String((e && e.message) || e) }
  #| }

///|
pub async fn remove_dir(path : String) -> Unit raise SysError {
  js_remove_dir(path)
  raise_pending_error()
}
