// 沙盒宿主的端到端测试：真的把 pi 的 `quickjs.wasm` 跑起来。
//
// 找不到 wasm（没装 pi / 测试机干净）时整组跳过 —— 这是环境缺失，不是回归。

///|
async fn quickjs_bytes() -> Bytes? {
  let env = @env.get_env_vars()
  let agent_dir = match env.get("PI_CODING_AGENT_DIR") {
    Some(dir) if !dir.is_empty() => dir
    _ => {
      let home = match env.get("HOME") {
        Some(home) => home
        None => return None
      }
      home + "/.pi/agent"
    }
  }
  match load_quickjs_wasm(agent_dir) {
    Some((_, bytes)) => Some(bytes)
    None => None
  }
}

///|
async test "sandbox：eval 一个表达式" {
  match quickjs_bytes() {
    None => return
    Some(wasm) => {
      let vm = ExtVm::new(wasm) catch { error => fail(error.to_string()) }
      defer vm.free()
      let result = vm.eval("1 + 2") catch { error => fail(error.to_string()) }
      assert_eq(result, "3")
      // quickjs 的版本串能读出来，缓存键与诊断都依赖它。
      assert_true(vm.quickjs_version().length() > 0)
    }
  }
}

///|
/// 求值并期望失败：成功返回 None，失败把错误带回来。
fn eval_error(vm : ExtVm, code : String) -> VmError? {
  let _ = try vm.eval(code) catch {
    error => return Some(error)
  }
  None
}

///|
async test "sandbox：语法错误与 JS 异常都变成 VmError" {
  match quickjs_bytes() {
    None => return
    Some(wasm) => {
      let vm = ExtVm::new(wasm) catch { error => fail(error.to_string()) }
      defer vm.free()
      match eval_error(vm, "this is not js") {
        Some(VmEval(message)) => assert_true(message.length() > 0)
        Some(other) => fail("期望 VmEval，实际 " + other.to_string())
        None => fail("语法错误没有报错")
      }
      match eval_error(vm, "throw new Error('boom')") {
        Some(VmEval(message)) => assert_true(message.contains("boom"))
        Some(other) => fail("期望 VmEval，实际 " + other.to_string())
        None => fail("JS 异常没有报错")
      }
      // 抛过异常之后 VM 仍然可用。
      let after = vm.eval("6 * 7") catch { error => fail(error.to_string()) }
      assert_eq(after, "42")
    }
  }
}

///|
async test "sandbox：快照恢复后状态还在" {
  match quickjs_bytes() {
    None => return
    Some(wasm) => {
      let vm = ExtVm::new(wasm) catch { error => fail(error.to_string()) }
      let prelude = vm.eval(
        "globalThis.__pi_ext_state = { ready: true, answer: 41 }; 'ok'",
      ) catch {
        error => fail(error.to_string())
      }
      assert_eq(prelude, "ok")
      let snapshot = vm.snapshot() catch { error => fail(error.to_string()) }
      vm.free()
      // 头部要能被解出来：版本、内存大小、扩展数为 0。
      match read_snapshot_header(snapshot) {
        Some(header) => {
          assert_eq(header.extensions, 0)
          assert_true(header.memory_size > 0)
          assert_true(snapshot.length() >= snapshot_header_size + 4 + header.memory_size)
        }
        None => fail("快照头解析失败")
      }
      let restored = ExtVm::restore(wasm, snapshot) catch {
        error => fail(error.to_string())
      }
      defer restored.free()
      let answer = restored.eval("__pi_ext_state.answer + 1") catch {
        error => fail(error.to_string())
      }
      assert_eq(answer, "42")
      // 恢复出来的 VM 自己也能再拍快照（快照链）。
      let again = restored.snapshot() catch { error => fail(error.to_string()) }
      assert_true(again.length() > snapshot_header_size)
    }
  }
}
