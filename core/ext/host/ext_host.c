// pi-moon 的扩展宿主：把 pi 的 `quickjs.wasm` 跑在 wasm3 上。
//
// 为什么是 wasm 而不是「链接一份原生 QuickJS」：扩展的编译产物是 **VM 快照**
// —— 整块线性内存 + 栈指针 + rt/ctx 指针。只有在 wasm 里，线性内存才是一块
// 可以整体拷进拷出的字节数组，快照才能跨进程复用；原生 QuickJS 的堆是
// allocator 给的地址，落盘就失效了。
//
// 这个文件的职责边界：
//   - 实例化 + 12 个 import（WASI 与 quickjs-wasi 的 host_* 钩子）；
//   - 调 wasm 导出的 `qjs_*` C API（eval / 取字符串 / 取指针）；
//   - 快照序列化，格式与 quickjs-wasi 的 `QuickJS.serializeSnapshot` 完全一致
//     （"QJSS" + 版本 2 + 扩展元数据 + 线性内存），于是两边的快照可以互换。
//
// 不在这里做的事：扩展 API 的语义（registerTool / on(...) 那一套）在 JS
// 预置脚本里，由 MoonBit 侧通过 host_call 桥接。

#include "moonbit.h"
#include "wasm3/wasm3.h"
#include "wasm3/m3_env.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

//---------------------------------------------------------------------------------------------------------------------------------
//  快照格式（与 quickjs-wasi 对齐）
//---------------------------------------------------------------------------------------------------------------------------------

#define PIM_SNAPSHOT_MAGIC 0x514A5353u // "QJSS"
#define PIM_SNAPSHOT_VERSION 2
#define PIM_SNAPSHOT_HEADER 24

//---------------------------------------------------------------------------------------------------------------------------------
//  VM 句柄
//---------------------------------------------------------------------------------------------------------------------------------

typedef struct ExtVM {
  IM3Environment env;
  IM3Runtime rt;
  IM3Module mod;
  // 最近一次操作的文本结果（eval 的返回值 / 异常 / 错误说明）。
  uint8_t* out;
  int32_t out_len;
  // 快照序列化时的临时缓冲。
  uint8_t* snap;
  int32_t snap_len;
} ExtVM;

// 无 VM 可依附的错误（实例化失败、解析失败）。
static uint8_t* g_error = NULL;
static int32_t g_error_len = 0;

static void set_error(const char* message) {
  free(g_error);
  g_error = NULL;
  g_error_len = 0;
  if (message == NULL) {
    return;
  }
  size_t len = strlen(message);
  g_error = (uint8_t*)malloc(len);
  if (g_error != NULL) {
    memcpy(g_error, message, len);
    g_error_len = (int32_t)len;
  }
}

static void vm_set_out(ExtVM* vm, const uint8_t* data, int32_t len) {
  free(vm->out);
  vm->out = NULL;
  vm->out_len = 0;
  if (data == NULL || len <= 0) {
    return;
  }
  vm->out = (uint8_t*)malloc((size_t)len);
  if (vm->out != NULL) {
    memcpy(vm->out, data, (size_t)len);
    vm->out_len = len;
  }
}

static void vm_set_out_str(ExtVM* vm, const char* text) {
  vm_set_out(vm, (const uint8_t*)text, text ? (int32_t)strlen(text) : 0);
}

//---------------------------------------------------------------------------------------------------------------------------------
//  线性内存
//---------------------------------------------------------------------------------------------------------------------------------

// 每次都重新取：wasm_malloc 与 memory.grow 之后指针可能变（重映射）。
static uint8_t* mem_of(ExtVM* vm) {
  size_t size = 0;
  uint8_t* base = m3_GetMemory(vm->mod, &size, 0);
  return base;
}

static uint8_t* mem_at(ExtVM* vm, uint32_t ptr) {
  uint8_t* base = mem_of(vm);
  return base == NULL ? NULL : base + ptr;
}

//---------------------------------------------------------------------------------------------------------------------------------
//  WASI 与 quickjs-wasi 的 host_* 导入
//
// 故意只实现快照/编译真正用到的那几个：fd_write 打到 stderr（quickjs 自己
// 只会用它报告未捕获的问题），clock 给个单调时间，random 给随机数。
// 文件系统一律 ENOSYS —— 沙盒里没有文件。
//---------------------------------------------------------------------------------------------------------------------------------

static m3ApiRawFunction(pim_host_timezone_offset) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_host_interrupt) {
  m3ApiReturnType(uint32_t)
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_host_promise_rejection) {
  (void)runtime;
  (void)_ctx;
  m3ApiGetArg(uint32_t, promise)
  m3ApiGetArg(uint32_t, reason)
  m3ApiGetArg(uint32_t, handled)
  (void)promise;
  (void)reason;
  (void)handled;
  m3ApiSuccess()
}

static m3ApiRawFunction(pim_host_module_normalize) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, base)
  m3ApiGetArg(uint32_t, name)
  (void)base;
  (void)name;
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_host_module_load) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, name)
  (void)name;
  m3ApiReturn(0)
}

// 宿主函数回调：JS 调 `__pi_host_call(name, argsJson)` 时进这里。
// 现在只登记「被调过」，真正的派发在 MoonBit 侧（见 ext_host_invoke）。
static m3ApiRawFunction(pim_host_call) {
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, name_ptr)
  m3ApiGetArg(uint32_t, name_len)
  m3ApiGetArg(uint32_t, this_ptr)
  m3ApiGetArg(uint32_t, argc)
  m3ApiGetArg(uint32_t, argv_ptr)
  (void)name_ptr;
  (void)name_len;
  (void)this_ptr;
  (void)argc;
  (void)argv_ptr;
  (void)runtime;
  // 返回 0 表示「宿主没接住」，JS 侧会看到一个明确的错误而不是静默的 undefined。
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_wasi_clock_time_get) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, clock_id)
  m3ApiGetArg(uint64_t, precision)
  m3ApiGetArg(uint32_t, result_ptr)
  (void)clock_id;
  (void)precision;
  uint8_t* mem = m3_GetMemory(runtime->modules, NULL, 0);
  if (mem != NULL) {
    *(uint64_t*)(mem + result_ptr) = 0;
  }
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_wasi_fd_close) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, fd)
  (void)fd;
  m3ApiReturn(8) // EBADF
}

static m3ApiRawFunction(pim_wasi_fd_fdstat_get) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, fd)
  m3ApiGetArg(uint32_t, ptr)
  uint8_t* mem = m3_GetMemory(runtime->modules, NULL, 0);
  if (mem != NULL && (fd == 1 || fd == 2)) {
    memset(mem + ptr, 0, 24);
    mem[ptr] = 2; // character device
    m3ApiReturn(0)
  }
  m3ApiReturn(8)
}

static m3ApiRawFunction(pim_wasi_fd_seek) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, fd)
  m3ApiGetArg(uint64_t, offset)
  m3ApiGetArg(uint32_t, whence)
  m3ApiGetArg(uint32_t, result_ptr)
  (void)fd;
  (void)offset;
  (void)whence;
  (void)result_ptr;
  m3ApiReturn(8) // EBADF
}

static m3ApiRawFunction(pim_wasi_fd_write) {
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, fd)
  m3ApiGetArg(uint32_t, iovs_ptr)
  m3ApiGetArg(uint32_t, iovs_len)
  m3ApiGetArg(uint32_t, nwritten_ptr)
  uint8_t* mem = m3_GetMemory(runtime->modules, NULL, 0);
  if (mem == NULL) {
    m3ApiReturn(8)
  }
  uint32_t total = 0;
  for (uint32_t index = 0; index < iovs_len; index++) {
    uint32_t buffer = *(uint32_t*)(mem + iovs_ptr + index * 8);
    uint32_t length = *(uint32_t*)(mem + iovs_ptr + index * 8 + 4);
    if (fd == 1) {
      fwrite(mem + buffer, 1, length, stdout);
    } else if (fd == 2) {
      fwrite(mem + buffer, 1, length, stderr);
    } else {
      m3ApiReturn(8)
    }
    total += length;
  }
  *(uint32_t*)(mem + nwritten_ptr) = total;
  m3ApiReturn(0)
}

static m3ApiRawFunction(pim_wasi_random_get) {
  (void)runtime;
  (void)_ctx;
  m3ApiReturnType(uint32_t)
  m3ApiGetArg(uint32_t, ptr)
  m3ApiGetArg(uint32_t, len)
  uint8_t* mem = m3_GetMemory(runtime->modules, NULL, 0);
  if (mem != NULL) {
    for (uint32_t index = 0; index < len; index++) {
      // 扩展只需要「不可预测到不影响正确性」的字节；沙盒里没有秘密要保护。
      mem[ptr + index] = (uint8_t)(rand() & 0xFF);
    }
  }
  m3ApiReturn(0)
}


//---------------------------------------------------------------------------------------------------------------------------------
//  实例化
//---------------------------------------------------------------------------------------------------------------------------------

static const char* link_imports(IM3Module mod) {
  const struct {
    const char* module;
    const char* name;
    const char* signature;
    M3RawCall function;
  } imports[] = {
    { "env", "host_get_timezone_offset", "i(ii)i", pim_host_timezone_offset },
    { "env", "host_interrupt", "i()i", pim_host_interrupt },
    { "env", "host_promise_rejection", "v(iii)", pim_host_promise_rejection },
    { "env", "host_module_normalize", "i(ii)i", pim_host_module_normalize },
    { "env", "host_module_load", "i(ii)i", pim_host_module_load },
    { "env", "host_call", "i(iiiii)i", pim_host_call },
    { "wasi_snapshot_preview1", "clock_time_get", "i(iIi)i",
      pim_wasi_clock_time_get },
    { "wasi_snapshot_preview1", "fd_close", "i(i)i", pim_wasi_fd_close },
    { "wasi_snapshot_preview1", "fd_fdstat_get", "i(ii)i",
      pim_wasi_fd_fdstat_get },
    { "wasi_snapshot_preview1", "fd_seek", "i(iIii)i", pim_wasi_fd_seek },
    { "wasi_snapshot_preview1", "fd_write", "i(iiii)i", pim_wasi_fd_write },
    { "wasi_snapshot_preview1", "random_get", "i(ii)i", pim_wasi_random_get },
  };
  for (size_t index = 0; index < sizeof(imports) / sizeof(imports[0]); index++) {
    M3Result result = m3_LinkRawFunction(mod, imports[index].module,
                                        imports[index].name,
                                        imports[index].signature,
                                        imports[index].function);
    if (result != NULL) {
      return result;
    }
  }
  return NULL;
}

// 从 wasm 字节造一个 VM。失败返回 NULL 并写 g_error。
static ExtVM* vm_create(const uint8_t* wasm, int32_t wasm_len) {
  if (wasm == NULL || wasm_len <= 0) {
    set_error("quickjs.wasm 为空");
    return NULL;
  }
  ExtVM* vm = (ExtVM*)calloc(1, sizeof(ExtVM));
  if (vm == NULL) {
    set_error("内存不足");
    return NULL;
  }
  vm->env = m3_NewEnvironment();
  if (vm->env == NULL) {
    set_error("wasm3 环境创建失败");
    free(vm);
    return NULL;
  }
  // 解释器栈：quickjs 的 C 递归（解析、GC）会吃掉不少，给 8MB。
  vm->rt = m3_NewRuntime(vm->env, 8 * 1024 * 1024, NULL);
  if (vm->rt == NULL) {
    set_error("wasm3 运行时创建失败");
    m3_FreeEnvironment(vm->env);
    free(vm);
    return NULL;
  }
  M3Result result = m3_ParseModule(vm->env, &vm->mod, wasm, (uint32_t)wasm_len);
  if (result != NULL) {
    set_error(result);
    m3_FreeRuntime(vm->rt);
    m3_FreeEnvironment(vm->env);
    free(vm);
    return NULL;
  }
  result = m3_LoadModule(vm->rt, vm->mod);
  if (result != NULL) {
    set_error(result);
    m3_FreeRuntime(vm->rt);
    m3_FreeEnvironment(vm->env);
    free(vm);
    return NULL;
  }
  const char* link_error = link_imports(vm->mod);
  if (link_error != NULL) {
    set_error(link_error);
    m3_FreeRuntime(vm->rt);
    m3_FreeEnvironment(vm->env);
    free(vm);
    return NULL;
  }
  return vm;
}

static void vm_free(ExtVM* vm) {
  if (vm == NULL) {
    return;
  }
  free(vm->out);
  free(vm->snap);
  m3_FreeRuntime(vm->rt);
  m3_FreeEnvironment(vm->env);
  free(vm);
}

static IM3Function find(ExtVM* vm, const char* name) {
  IM3Function function = NULL;
  if (m3_FindFunction(&function, vm->rt, name) != NULL) {
    return NULL;
  }
  return function;
}

// 调一个无参函数，返回 wasm 侧返回值（错误时为 -1）。
static int32_t call0(ExtVM* vm, const char* name) {
  IM3Function function = find(vm, name);
  if (function == NULL) {
    vm_set_out_str(vm, name);
    return -1;
  }
  M3Result result = m3_CallV(function);
  if (result != NULL) {
    vm_set_out_str(vm, result);
    return -1;
  }
  uint32_t value = 0;
  m3_GetResultsV(function, &value);
  return (int32_t)value;
}

static uint32_t call_u32(ExtVM* vm, const char* name) {
  IM3Function function = find(vm, name);
  if (function == NULL) {
    return 0;
  }
  if (m3_CallV(function) != NULL) {
    return 0;
  }
  uint32_t value = 0;
  m3_GetResultsV(function, &value);
  return value;
}

// 把一段字节写进 guest 内存，返回 guest 指针（0 = 失败）。
static uint32_t alloc_guest(ExtVM* vm, const uint8_t* data, int32_t len) {
  IM3Function alloc = find(vm, "wasm_malloc");
  if (alloc == NULL) {
    return 0;
  }
  uint32_t ptr = 0;
  if (m3_CallV(alloc, (uint32_t)len + 1) != NULL) {
    return 0;
  }
  m3_GetResultsV(alloc, &ptr);
  if (ptr == 0) {
    return 0;
  }
  uint8_t* dst = mem_at(vm, ptr);
  if (dst == NULL) {
    return 0;
  }
  if (len > 0 && data != NULL) {
    memcpy(dst, data, (size_t)len);
  }
  dst[len] = 0;
  return ptr;
}

static void free_guest(ExtVM* vm, uint32_t ptr) {
  IM3Function release = find(vm, "wasm_free");
  if (release != NULL && ptr != 0) {
    m3_CallV(release, ptr);
  }
}

// 把一个 JS 值读成 UTF-8 文本（带长度，避免 NUL 截断）。
// 与 quickjs-wasi 的 JSValueHandle.toString() 走同一条 API。
static int32_t value_to_text(ExtVM* vm, uint32_t value, uint8_t** out) {
  *out = NULL;
  IM3Function get = find(vm, "qjs_get_string_len");
  IM3Function release_text = find(vm, "qjs_free_cstring");
  if (get == NULL) {
    return 0;
  }
  uint32_t len_ptr = alloc_guest(vm, (const uint8_t*)"\0\0\0\0", 4);
  if (len_ptr == 0) {
    return 0;
  }
  M3Result result = m3_CallV(get, value, len_ptr);
  if (result != NULL) {
    free_guest(vm, len_ptr);
    return 0;
  }
  uint32_t text_ptr = 0;
  m3_GetResultsV(get, &text_ptr);
  uint32_t text_len = 0;
  uint8_t* mem = mem_at(vm, len_ptr);
  if (mem != NULL) {
    text_len = *(uint32_t*)mem;
  }
  free_guest(vm, len_ptr);
  if (text_ptr == 0) {
    return 0;
  }
  uint8_t* base = mem_at(vm, text_ptr);
  if (base != NULL && text_len > 0) {
    *out = (uint8_t*)malloc((size_t)text_len);
    if (*out != NULL) {
      memcpy(*out, base, (size_t)text_len);
    } else {
      text_len = 0;
    }
  }
  if (release_text != NULL) {
    m3_CallV(release_text, text_ptr);
  }
  return (int32_t)text_len;
}

// 把 value 的文本写进 result 缓冲。
static void vm_set_out_value(ExtVM* vm, uint32_t value) {
  uint8_t* text = NULL;
  int32_t length = value_to_text(vm, value, &text);
  vm_set_out(vm, text, length);
  free(text);
}

//---------------------------------------------------------------------------------------------------------------------------------
//  MoonBit 侧入口
//---------------------------------------------------------------------------------------------------------------------------------

/// 新建 VM（尚未 qjs_init）并返回句柄；0 表示失败，原因用 pim_ext_error_* 取。
int64_t pim_ext_vm_new(moonbit_bytes_t wasm, int32_t wasm_len) {
  set_error(NULL);
  ExtVM* vm = vm_create((const uint8_t*)wasm, wasm_len);
  return (int64_t)(uintptr_t)vm;
}

/// 释放 VM。
void pim_ext_vm_free(int64_t handle) {
  vm_free((ExtVM*)(uintptr_t)handle);
}

/// 走一遍 WASI reactor 的 `_initialize` 与 quickjs 的 `qjs_init`。0 = 成功。
int32_t pim_ext_vm_init(int64_t handle) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL) {
    return -1;
  }
  IM3Function initialize = find(vm, "_initialize");
  if (initialize != NULL) {
    M3Result result = m3_CallV(initialize);
    if (result != NULL) {
      vm_set_out_str(vm, result);
      return -1;
    }
  }
  int32_t code = call0(vm, "qjs_init");
  if (code != 0) {
    return -1;
  }
  return 0;
}

/// 在 VM 里 eval 一段代码；结果（或异常文本）落在 result 缓冲里。
/// 0 = 正常（结果可取），-1 = 引擎错误（原因在 result 里）。
int32_t pim_ext_vm_eval(int64_t handle, moonbit_bytes_t code, int32_t code_len,
                        moonbit_bytes_t filename, int32_t filename_len) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL) {
    return -1;
  }
  uint32_t code_ptr = alloc_guest(vm, (const uint8_t*)code, code_len);
  if (code_ptr == 0) {
    vm_set_out_str(vm, "wasm_malloc 失败");
    return -1;
  }
  uint32_t name_ptr = alloc_guest(vm, (const uint8_t*)filename, filename_len);
  if (name_ptr == 0) {
    free_guest(vm, code_ptr);
    vm_set_out_str(vm, "wasm_malloc 失败");
    return -1;
  }
  IM3Function eval = find(vm, "qjs_eval");
  if (eval == NULL) {
    free_guest(vm, code_ptr);
    free_guest(vm, name_ptr);
    vm_set_out_str(vm, "找不到 qjs_eval");
    return -1;
  }
  M3Result result =
    m3_CallV(eval, code_ptr, (uint32_t)code_len, name_ptr, (uint32_t)0);
  // 结果必须在**任何**别的 guest 调用之前取出来：wasm3 把返回值放在运行时
  // 的返回槽里，下一次 m3_CallV（哪怕是 wasm_free）就会覆盖掉。
  uint32_t value = 0;
  if (result == NULL) {
    m3_GetResultsV(eval, &value);
  }
  free_guest(vm, code_ptr);
  free_guest(vm, name_ptr);
  if (result != NULL) {
    vm_set_out_str(vm, result);
    return -1;
  }
  // 异常：把异常对象的字符串化结果作为诊断。
  IM3Function is_exception = find(vm, "qjs_is_exception");
  if (is_exception != NULL) {
    m3_CallV(is_exception, value);
    uint32_t flag = 0;
    m3_GetResultsV(is_exception, &flag);
    if (flag != 0) {
      // 挂起的异常在 context 上：取出来才能字符串化，顺便清掉挂起状态，
      // 之后这个 VM 还能继续用。
      IM3Function get_exception = find(vm, "qjs_get_exception");
      uint32_t exception = 0;
      if (get_exception != NULL) {
        if (m3_CallV(get_exception) == NULL) {
          m3_GetResultsV(get_exception, &exception);
        }
      }
      if (exception != 0) {
        vm_set_out_value(vm, exception);
        IM3Function free_exception = find(vm, "qjs_free_value");
        if (free_exception != NULL) {
          m3_CallV(free_exception, exception);
        }
      }
      if (vm->out_len == 0) {
        vm_set_out_str(vm, "JS 异常");
      }
      IM3Function free_value = find(vm, "qjs_free_value");
      if (free_value != NULL) {
        m3_CallV(free_value, value);
      }
      return -1;
    }
  }
  vm_set_out_value(vm, value);
  IM3Function free_value = find(vm, "qjs_free_value");
  if (free_value != NULL) {
    m3_CallV(free_value, value);
  }
  return 0;
}

/// 最近一次结果的字节数。
int32_t pim_ext_result_len(int64_t handle) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL) {
    return g_error_len;
  }
  return vm->out_len;
}

/// 把最近一次结果拷进 out（最多 cap 字节），返回实际拷出的字节数。
int32_t pim_ext_result_copy(int64_t handle, moonbit_bytes_t out, int32_t cap) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  const uint8_t* source = NULL;
  int32_t length = 0;
  if (vm == NULL) {
    source = g_error;
    length = g_error_len;
  } else {
    source = vm->out;
    length = vm->out_len;
  }
  if (source == NULL || out == NULL || cap <= 0) {
    return 0;
  }
  int32_t copied = length < cap ? length : cap;
  memcpy(out, source, (size_t)copied);
  return copied;
}

/// 用错误文本设置 result（MoonBit 侧创建 VM 失败时用它拿原因）。
void pim_ext_set_error(moonbit_bytes_t message, int32_t len) {
  set_error(NULL);
  if (message == NULL || len <= 0) {
    return;
  }
  g_error = (uint8_t*)malloc((size_t)len);
  if (g_error != NULL) {
    memcpy(g_error, message, (size_t)len);
    g_error_len = len;
  }
}

/// 无 VM 时的错误文本长度。
int32_t pim_ext_error_len(void) { return g_error_len; }

/// 无 VM 时的错误文本拷贝。
int32_t pim_ext_error_copy(moonbit_bytes_t out, int32_t cap) {
  if (g_error == NULL || out == NULL || cap <= 0) {
    return 0;
  }
  int32_t copied = g_error_len < cap ? g_error_len : cap;
  memcpy(out, g_error, (size_t)copied);
  return copied;
}

//---------------------------------------------------------------------------------------------------------------------------------
//  快照
//---------------------------------------------------------------------------------------------------------------------------------

static int32_t snapshot_build(ExtVM* vm) {
  free(vm->snap);
  vm->snap = NULL;
  vm->snap_len = 0;
  size_t memory_size = 0;
  uint8_t* memory = m3_GetMemory(vm->mod, &memory_size, 0);
  if (memory == NULL || memory_size == 0) {
    vm_set_out_str(vm, "线性内存不可用");
    return -1;
  }
  IM3Global stack_global = m3_FindGlobal(vm->mod, "__stack_pointer");
  if (stack_global == NULL) {
    vm_set_out_str(vm, "找不到 __stack_pointer");
    return -1;
  }
  M3TaggedValue stack_value;
  memset(&stack_value, 0, sizeof(stack_value));
  stack_value.type = c_m3Type_i32;
  if (m3_GetGlobal(stack_global, &stack_value) != NULL) {
    vm_set_out_str(vm, "读不出 __stack_pointer");
    return -1;
  }
  uint32_t runtime_ptr = call_u32(vm, "qjs_get_runtime_ptr");
  uint32_t context_ptr = call_u32(vm, "qjs_get_context_ptr");
  // 版本 2 的扩展元数据：这里恒为「一个扩展都没有」——
  // pi-moon 不加载 wasm side module，扩展逻辑全在 JS 里。
  int32_t total = PIM_SNAPSHOT_HEADER + 4 + (int32_t)memory_size;
  uint8_t* buffer = (uint8_t*)malloc((size_t)total);
  if (buffer == NULL) {
    vm_set_out_str(vm, "内存不足");
    return -1;
  }
  memset(buffer, 0, PIM_SNAPSHOT_HEADER + 4);
  uint32_t magic = PIM_SNAPSHOT_MAGIC;
  buffer[0] = (uint8_t)(magic >> 24);
  buffer[1] = (uint8_t)(magic >> 16);
  buffer[2] = (uint8_t)(magic >> 8);
  buffer[3] = (uint8_t)magic;
  buffer[4] = PIM_SNAPSHOT_VERSION;
  uint32_t memory32 = (uint32_t)memory_size;
  memcpy(buffer + 8, &memory32, 4);
  memcpy(buffer + 12, &stack_value.value.i32, 4);
  memcpy(buffer + 16, &runtime_ptr, 4);
  memcpy(buffer + 20, &context_ptr, 4);
  // buffer[24..28] 是 extensions 计数，已经是 0。
  memcpy(buffer + PIM_SNAPSHOT_HEADER + 4, memory, memory_size);
  vm->snap = buffer;
  vm->snap_len = total;
  return 0;
}

/// 生成快照，返回字节数（0 = 失败）。
int32_t pim_ext_vm_snapshot_len(int64_t handle) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL) {
    return 0;
  }
  if (snapshot_build(vm) != 0) {
    return 0;
  }
  return vm->snap_len;
}

/// 拷出快照字节，返回实际拷出的字节数。
int32_t pim_ext_vm_snapshot_copy(int64_t handle, moonbit_bytes_t out,
                                 int32_t cap) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL || vm->snap == NULL || out == NULL || cap <= 0) {
    return 0;
  }
  int32_t copied = vm->snap_len < cap ? vm->snap_len : cap;
  memcpy(out, vm->snap, (size_t)copied);
  return copied;
}

/// 从快照恢复：新建 VM → 调整内存页数 → 拷内存 → 设 rt/ctx 与栈指针。
/// 返回句柄，0 = 失败。
int64_t pim_ext_vm_restore(moonbit_bytes_t wasm, int32_t wasm_len,
                           moonbit_bytes_t snapshot, int32_t snapshot_len) {
  set_error(NULL);
  if (snapshot == NULL || snapshot_len < PIM_SNAPSHOT_HEADER + 4) {
    set_error("快照太短");
    return 0;
  }
  const uint8_t* snap = (const uint8_t*)snapshot;
  uint32_t magic = ((uint32_t)snap[0] << 24) | ((uint32_t)snap[1] << 16) |
                   ((uint32_t)snap[2] << 8) | (uint32_t)snap[3];
  if (magic != PIM_SNAPSHOT_MAGIC) {
    set_error("快照 magic 不对");
    return 0;
  }
  uint8_t version = snap[4];
  if (version != 1 && version != PIM_SNAPSHOT_VERSION) {
    set_error("快照版本不支持");
    return 0;
  }
  uint32_t memory_size = 0;
  uint32_t stack_pointer = 0;
  uint32_t runtime_ptr = 0;
  uint32_t context_ptr = 0;
  memcpy(&memory_size, snap + 8, 4);
  memcpy(&stack_pointer, snap + 12, 4);
  memcpy(&runtime_ptr, snap + 16, 4);
  memcpy(&context_ptr, snap + 20, 4);
  int32_t memory_offset = PIM_SNAPSHOT_HEADER;
  if (version >= 2) {
    // 有扩展元数据就得逐条跳过：本宿主不加载 side module，遇到非零计数直接拒。
    uint32_t extension_count = 0;
    memcpy(&extension_count, snap + PIM_SNAPSHOT_HEADER, 4);
    if (extension_count != 0) {
      set_error("快照携带 wasm 扩展，本宿主不加载 side module");
      return 0;
    }
    memory_offset = PIM_SNAPSHOT_HEADER + 4;
  }
  if (memory_offset + (int32_t)memory_size > snapshot_len) {
    set_error("快照被截断");
    return 0;
  }
  ExtVM* vm = vm_create((const uint8_t*)wasm, wasm_len);
  if (vm == NULL) {
    return 0;
  }
  size_t current_size = 0;
  m3_GetMemory(vm->mod, &current_size, 0);
  size_t needed_pages = ((size_t)memory_size + 65535) / 65536;
  size_t current_pages = current_size / 65536;
  if (needed_pages > current_pages) {
    if (ResizeMemory(vm->rt, vm->mod->memories[0], (uint64_t)needed_pages) !=
        NULL) {
      set_error("恢复时扩展内存失败");
      vm_free(vm);
      return 0;
    }
  }
  uint8_t* memory = mem_of(vm);
  if (memory == NULL) {
    set_error("恢复时拿不到线性内存");
    vm_free(vm);
    return 0;
  }
  memcpy(memory, snap + memory_offset, (size_t)memory_size);
  // 内存里已经有 runtime / context，但 C 侧的全局指针要先指回去。
  IM3Function set_ptrs = find(vm, "qjs_set_runtime_and_context");
  if (set_ptrs != NULL) {
    m3_CallV(set_ptrs, runtime_ptr, context_ptr);
  }
  IM3Global stack_global = m3_FindGlobal(vm->mod, "__stack_pointer");
  if (stack_global == NULL) {
    set_error("找不到 __stack_pointer");
    vm_free(vm);
    return 0;
  }
  M3TaggedValue stack_value;
  memset(&stack_value, 0, sizeof(stack_value));
  stack_value.type = c_m3Type_i32;
  stack_value.value.i32 = stack_pointer;
  m3_SetGlobal(stack_global, &stack_value);
  return (int64_t)(uintptr_t)vm;
}

/// quickjs 版本串（诊断用）：写进 result 缓冲并返回长度。
int32_t pim_ext_quickjs_version(int64_t handle) {
  ExtVM* vm = (ExtVM*)(uintptr_t)handle;
  if (vm == NULL) {
    return 0;
  }
  IM3Function version = find(vm, "qjs_get_quickjs_version");
  if (version == NULL) {
    return 0;
  }
  if (m3_CallV(version) != NULL) {
    return 0;
  }
  uint32_t text_ptr = 0;
  m3_GetResultsV(version, &text_ptr);
  // 版本串是 C 字符串，直接读到 NUL 为止。
  const char* text = (const char*)mem_at(vm, text_ptr);
  vm_set_out_str(vm, text);
  return vm->out_len;
}
