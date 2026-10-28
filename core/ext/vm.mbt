// 沙盒宿主的形状：一个能跑 `quickjs.wasm`、能拍快照、能从快照恢复的 VM。
//
// 两个后端同一套签名（native 走 wasm3，js 走 npm 的 quickjs-wasi），上层
// （prepare / runtime 桥接）只认这里。
//
// 生命周期很短：**编译期**用它跑一遍扩展源然后抓快照，**启动期**用它恢复
// 快照，之后每次调扩展的 handler 都发生在恢复出来的 VM 里。

///|
/// 沙盒操作失败。都是「这个扩展装不进来」级别的问题，不是崩溃。
pub suberror VmError {
  /// 构造 / 恢复失败（wasm 读不出来、内存不够、快照坏了）。
  VmInit(String)
  /// 求值失败（语法错误、JS 抛异常）。
  VmEval(String)
  /// 快照生成失败。
  VmSnapshot(String)
  /// 当前后端没有沙盒实现。
  VmUnsupported
}

///|
pub fn VmError::to_string(self : VmError) -> String {
  match self {
    VmInit(reason) => "沙盒初始化失败：" + reason
    VmEval(reason) => "扩展执行失败：" + reason
    VmSnapshot(reason) => "快照失败：" + reason
    VmUnsupported => "js 后端没有沙盒实现（扩展只能在 native 构建里装载）"
  }
}

///|
/// 一个扩展沙盒。句柄语义由后端定义，上层只当它是「不透明的 VM」。
pub(all) struct ExtVm {
  /// 后端句柄（native 是 wasm3 实例地址）。
  handle : Int64
} derive(Eq)

///|
/// 快照解码出来的头部信息 —— 恢复前用来校验「快照与 wasm 版本对得上」。
pub(all) struct SnapshotHeader {
  /// 线性内存字节数。
  memory_size : Int
  /// wasm 的 `__stack_pointer`。
  stack_pointer : UInt
  runtime_ptr : UInt
  context_ptr : UInt
  /// 快照里携带的 wasm 扩展数量（pi-moon 恒为 0）。
  extensions : Int
} derive(Eq, Debug)

///|
/// 快照格式常量。与 quickjs-wasi 的 `serializeSnapshot` 逐字节一致。
pub let snapshot_magic : UInt = 0x514A5353
pub let snapshot_version : Int = 2
pub let snapshot_header_size : Int = 24

///|
/// 读快照头。坏快照返回 None。
pub fn read_snapshot_header(snapshot : Bytes) -> SnapshotHeader? {
  if snapshot.length() < snapshot_header_size {
    return None
  }
  let magic = (snapshot[0].to_uint() << 24) |
    (snapshot[1].to_uint() << 16) |
    (snapshot[2].to_uint() << 8) |
    snapshot[3].to_uint()
  if magic != snapshot_magic {
    return None
  }
  let version = snapshot[4].to_int()
  if version != 1 && version != snapshot_version {
    return None
  }
  let memory_size = read_u32(snapshot, 8)
  let stack_pointer = read_u32(snapshot, 12)
  let runtime_ptr = read_u32(snapshot, 16)
  let context_ptr = read_u32(snapshot, 20)
  let extensions = if version >= 2 && snapshot.length() >= snapshot_header_size + 4 {
    read_u32(snapshot, snapshot_header_size)
  } else {
    0
  }
  Some({
    memory_size: memory_size.to_int(),
    stack_pointer,
    runtime_ptr,
    context_ptr,
    extensions: extensions.to_int(),
  })
}

///|
fn read_u32(bytes : Bytes, offset : Int) -> UInt {
  bytes[offset].to_uint() |
  (bytes[offset + 1].to_uint() << 8) |
  (bytes[offset + 2].to_uint() << 16) |
  (bytes[offset + 3].to_uint() << 24)
}
