// 工具宿主进程：bun 那边的 tool_host.mjs（见 host/tool_host.mjs，经
// scripts/embed-host.mjs 嵌进本包）。
//
// 宿主是**常驻守护进程**，由用户或脚本手动启动（`bun tool_host.mjs --port …`），
// 不依赖 pi-moon 进程。这一层只负责「替测试与便利场景把它拉起来」：
//   - 找 bun 与 pi 的 node_modules 复用 core/ext 的同一对函数（agent_dir 的
//     推导在 ext 侧是测试私有助手，这里按同口径写了一份）；
//   - 把嵌入的脚本落到缓存目录；
//   - spawn bun、等端口回执，失败时把宿主的 stderr 诊断带上。
//
// 端口回执用文件而不是 stdout —— 守护进程的管道没人读（脚本侧已静默
// console，见 tool_host.mjs 文件头的约束），只有启动期才碰它一次。

///|
/// 工具宿主进程需要的路径。全部在启动时算一次。
pub(all) struct ToolHostPaths {
  /// bun 可执行文件。
  bun : String
  /// 写到缓存目录里的宿主脚本。
  script : String
  /// 缓存根目录（脚本与端口回执文件都放这里）。
  root : String
  /// 宿主自己的工作区（工具按它解析相对路径）。
  cwd : String
  /// pi 装机里的 node_modules。
  modules : String
}

///|
/// 算一次宿主路径，并把脚本落到缓存目录（内容变了才重写）。
///
/// `modules` 留空则走 `resolve_pi_modules`（`PI_PI_MODULES` 优先，再扫 pi 装机）；
/// `agent_dir` 留空走与扩展宿主同源的推导。bun 或 pi 装机缺一个就返回 None
/// —— 真宿主组整组跳过的依据。（找 bun / 找 pi 装机复用 core/ext 的同一对
/// 函数；agent_dir 的推导在 ext 侧是测试私有助手，这里按同口径写了一份。）
pub async fn prepare_tool_host_paths(
  cwd~ : String,
  agent_dir~ : String = "",
  modules~ : String = "",
) -> ToolHostPaths? {
  // agent_dir 留空走与扩展宿主同源的推导（PI_CODING_AGENT_DIR 或 ~/.pi/agent）
  // —— 缓存目录挂在它下面。
  let agent_dir = if agent_dir.is_empty() {
    let env = @env.get_env_vars()
    match env.get("PI_CODING_AGENT_DIR") {
      Some(dir) if !dir.is_empty() => dir
      _ =>
        match env.get("USERPROFILE") {
          Some(home) => home + "/.pi/agent"
          None =>
            match env.get("HOME") {
              Some(home) => home + "/.pi/agent"
              None => ".pi/agent"
            }
        }
    }
  } else {
    agent_dir
  }
  let modules = if modules.is_empty() {
    match @ext.resolve_pi_modules(agent_dir) {
      Some(path) => path
      None => return None
    }
  } else {
    modules
  }
  let bun = @ext.find_bun()
  if bun.is_empty() {
    return None
  }
  let root = agent_dir + "/cache/pi-moon/tool-host"
  let script = root + "/tool_host.mjs"
  @sys.mkdir_p(root) catch {
    _ => return None
  }
  let existing = @sys.read_text(script) catch { _ => "" }
  if existing != tool_host_script_source {
    @sys.write_text(script, tool_host_script_source) catch {
      _ => return None
    }
  }
  Some({
    bun,
    script: @ext.absolute(script),
    root: @ext.absolute(root),
    cwd: @ext.absolute(cwd),
    modules: @ext.absolute(modules),
  })
}

///|
/// 一个已启动的工具宿主守护进程。`port` 是它实际监听的端口。
pub(all) struct ToolHostProcess {
  session : @sys.Session
  mut port : Int
  /// 启动期从宿主管道里收到的诊断（失败时才用得上）。
  mut diagnostics : String
}

///|
/// 等宿主起监听的上限（毫秒）。工具宿主不需要构建（对比扩展宿主跑
/// Bun.build），但冷启动 + import pi 全家桶也要一点时间。
let tool_host_startup_ms : Int = 60000

///|
/// 拉起工具宿主：spawn bun（`--managed` —— 关掉 stdin 宿主就退）、轮询端口
/// 回执文件。超时就把宿主管道里攒的诊断（stderr）带上报错并收掉进程。
pub async fn ToolHostProcess::start(
  paths : ToolHostPaths,
  port_file~ : String,
  port? : Int = 0,
) -> ToolHostProcess raise RemoteError {
  // 守护进程的工作目录是缓存根 —— 相对路径会被它解错（ext 宿主同一条教训），
  // 端口回执文件在这里绝对化。
  let port_file = @ext.absolute(port_file)
  let io = @sys.spawn_session(
    paths.bun,
    [
      paths.script,
      "--port",
      port.to_string(),
      "--cwd",
      paths.cwd,
      "--modules",
      paths.modules,
      "--port-file",
      port_file,
      "--managed",
    ],
    cwd=paths.root,
  ) catch {
    error => raise RemoteStartup("起工具宿主失败：" + error.to_string())
  }
  let process : ToolHostProcess = {
    session: io,
    port: 0,
    diagnostics: "",
  }
  errdefer process.session.close()
  // 端口文件在 listen 回调里写；轮询到出现为止。
  let deadline = @sys.now() + tool_host_startup_ms.to_int64()
  while @sys.now() < deadline {
    let there = @sys.exists(port_file) catch { _ => false }
    if there {
      let text = @sys.read_text_lossy(port_file) catch { _ => "" }
      let parsed = @json.parse(text.trim().to_owned()) catch { _ => Json::null() }
      match parsed {
        Number(n, ..) => {
          process.port = n.to_int()
          return process
        }
        _ => ()
      }
    }
    @async.sleep(100) catch {
      // 取消原样折成启动失败（startup 被掐 = 收工，突变只发生在值路径）。
      error => raise RemoteFailure(error.to_string())
    }
  }
  // 超时：把管道里的宿主 stderr 抓出来（崩溃诊断只在那里），再报错。
  process.diagnostics = collect_diagnostics(process.session) catch { _ => "" }
  raise RemoteStartup(
    "等工具宿主监听超时（" +
    tool_host_startup_ms.to_string() +
    "ms）" +
    (if process.diagnostics.is_empty() {
      ""
    } else {
      "：" + process.diagnostics
    }),
  )
}

///|
/// 起监听失败时从宿主管道里抓诊断（读几块，带短超时 —— 管道可能没数据）。
async fn collect_diagnostics(session : @sys.Session) -> String {
  let collected : Array[String] = []
  for _i in 0..<3 {
    let chunk = @async.with_timeout(2000, async fn() {
      session.read_some()
    }) catch {
      _ => return collected.join("")
    }
    match chunk {
      Some(bytes) => collected.push(@utf8.decode_lossy(bytes))
      None => return collected.join("")
    }
  }
  collected.join("")
}

///|
/// 收掉宿主（关 stdin；`--managed` 让它自己退）。
pub fn ToolHostProcess::stop(self : ToolHostProcess) -> Unit {
  self.session.close()
}
