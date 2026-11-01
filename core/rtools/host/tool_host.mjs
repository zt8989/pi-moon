// bun 工具宿主脚本：RemoteReActAgent 的「手脚」—— 常驻守护进程，把 pi 的
// TS 工具实现架到 TCP 行协议上。
//
// 与扩展宿主（ext_host.mjs）的分工：那边装载用户 TS 扩展（要 Bun.build 打包
// + 构建期沙盒改写）；这边只服务 pi 的内置八件套 —— pi 的工具文件就住在 pi
// 的 node_modules 树里，按绝对路径 import，bun 自己转译，裸包解析天然从包
// 自己的位置走（扩展宿主踩过的坑在这里不存在，因为没有第二份产物目录）。
//
//   bun tool_host.mjs --port <n> --cwd <dir> --modules <pi 的 node_modules>
//                     [--port-file <f>] [--managed]
//
//   --port 0    内核分配（实际端口写进 --port-file）；手动部署给固定端口。
//   --managed   由 pi-moon 拉起时带上：父进程关掉 stdin 就退出。手动部署
//               不带 —— 后台化（stdin 来自 /dev/null）也照常驻留。
//
// 约束（对应具体的坑）：
//   - **stdout 不是协议通道**（协议在 TCP 上），但也不能随便写：pi-moon 侧
//     不读守护进程的管道，写多了会把管子读满而卡死宿主。console.* 一律静默，
//     工具自身的输出由工具捕获（pi 的 bash / rg 都用自己的管道）。致命错误
//     走 stderr（启动失败就死，没有「读满」问题）。
//   - **每条连接一份工具定义**：PI_* 元数据按连接注入（bash 的 spawnHook），
//     不碰 process.env —— 两条连接的会话 id 不该互相串话。
//   - 工具抛错折成 isError 结果，宿主进程不崩；单连接断开不退宿主。
//   - 只绑 127.0.0.1（v1 信任边界：明文 TCP；跨机走 SSH 隧道）。

import { createServer } from "node:net";
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

//------------------------------------------------------------------------------------------------------------------------------
// 参数
//------------------------------------------------------------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { port: 0, cwd: "", modules: "", portFile: "", managed: false };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) {
        throw new Error("缺少 " + flag + " 的值");
      }
      return argv[i];
    };
    if (flag === "--port") {
      args.port = Number(next());
    } else if (flag === "--cwd") {
      args.cwd = next();
    } else if (flag === "--modules") {
      args.modules = next();
    } else if (flag === "--port-file") {
      args.portFile = next();
    } else if (flag === "--managed") {
      args.managed = true;
    } else {
      throw new Error("未知参数 " + flag);
    }
  }
  if (!args.cwd) {
    throw new Error("缺少 --cwd");
  }
  if (!Number.isFinite(args.port) || args.port < 0 || args.port > 65535) {
    throw new Error("--port 不是合法端口");
  }
  return args;
}

//------------------------------------------------------------------------------------------------------------------------------
// pi 的 node_modules：--modules 显式指定 > PI_PI_MODULES > pi 装机里版本号
// 最大的那份。与 pi-moon 侧 resolve_pi_modules 同一搜索顺序 —— 手动部署
// 只给 --port / --cwd 也能起（「bun 直接启动，不依赖 pi-moon 进程」）。
//------------------------------------------------------------------------------------------------------------------------------

function isPiModules(path) {
  try {
    return existsSync(join(path, "@earendil-works", "pi-coding-agent", "package.json"));
  } catch (error) {
    return false;
  }
}

// 「1.10.0」→ 可比较的整数序列，别按字典序把 1.10.0 排到 1.4.0 前面。
function versionKey(name) {
  let key = 0n;
  let parts = 0;
  for (const segment of name.split(".")) {
    let value = 0n;
    let seen = false;
    for (const character of segment) {
      if (character >= "0" && character <= "9") {
        value = value * 10n + BigInt(character.charCodeAt(0) - 48);
        seen = true;
      } else {
        break;
      }
    }
    if (seen && parts < 4) {
      key = (key << 16n) | (value & 0xffffn);
      parts += 1;
    }
  }
  return key;
}

function resolvePiModules() {
  if (process.env.PI_PI_MODULES && isPiModules(process.env.PI_PI_MODULES)) {
    return process.env.PI_PI_MODULES;
  }
  const home = process.env.PI_CODING_AGENT_DIR || join(process.env.USERPROFILE || process.env.HOME || ".", ".pi", "agent");
  const releases = join(home, "install", "releases");
  let best = null;
  try {
    for (const name of readdirSync(releases)) {
      const candidate = join(releases, name, "node_modules");
      if (isPiModules(candidate)) {
        const key = versionKey(name);
        if (best === null || key > best.key) {
          best = { key, path: candidate };
        }
      }
    }
  } catch (error) {
    // 没有 releases 目录
  }
  if (best) {
    return best.path;
  }
  const fallback = join(home, "npm", "node_modules");
  return isPiModules(fallback) ? fallback : "";
}

//------------------------------------------------------------------------------------------------------------------------------
// 静默 console：stdout/stderr 的管道没人读（见文件头约束），一个字都不能写。
//------------------------------------------------------------------------------------------------------------------------------

for (const method of ["log", "info", "warn", "error", "debug", "trace"]) {
  console[method] = () => {};
}

function fatal(message) {
  // 启动期失败才走这里：进程随后退出，管道随之关闭，不存在读满问题。
  process.stderr.write("[tool-host] " + String(message) + "\n");
  process.exit(1);
}

function jsonSafe(value) {
  if (value === undefined) {
    return null;
  }
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (error) {
    return null;
  }
}

//------------------------------------------------------------------------------------------------------------------------------
// pi 的内置工具
//------------------------------------------------------------------------------------------------------------------------------

async function loadToolFactory(args) {
  const entry = join(
    args.modules,
    "@earendil-works",
    "pi-coding-agent",
    "dist",
    "core",
    "tools",
    "index.js",
  );
  try {
    return await import(pathToFileURL(entry).href);
  } catch (error) {
    fatal(
      "加载 pi 工具实现失败（" + entry + "）：" + String((error && error.message) || error),
    );
    return null;
  }
}

// 每条连接一份定义：spawnHook 闭包住这条连接的会话元数据，把 PI_* 注进
// 每次进程执行的 env（pi 自己会把 PI_* 从基 env 里删掉，这里补回本连接的）。
// exposeSessionEnvironment 关掉 —— 那条路要 pi 的 sessionManager，守护进程没有。
function injectPiEnv(meta) {
  return (spawnContext) => {
    const env = { ...spawnContext.env };
    if (meta.sessionId) {
      env.PI_SESSION_ID = meta.sessionId;
    }
    if (meta.provider) {
      env.PI_PROVIDER = meta.provider;
    }
    if (meta.model) {
      env.PI_MODEL = meta.model;
    }
    return { ...spawnContext, env };
  };
}

//------------------------------------------------------------------------------------------------------------------------------
// 一条连接：ready 注册表 + hello 元数据 + call 往返
//------------------------------------------------------------------------------------------------------------------------------

function send(socket, obj) {
  socket.write(JSON.stringify(obj) + "\n");
}

async function handleConnection(socket, args, factory) {
  const meta = { sessionId: "", provider: "", model: "" };
  const definitions = factory.createAllToolDefinitions(args.cwd, {
    bash: { exposeSessionEnvironment: false, spawnHook: injectPiEnv(meta) },
    powershell: { exposeSessionEnvironment: false, spawnHook: injectPiEnv(meta) },
  });
  const names = Object.keys(definitions);
  const toolDefinitions = names.map((name) => ({
    name: definitions[name].name,
    description: definitions[name].description ?? "",
    parameters: definitions[name].parameters ?? {},
  }));
  send(socket, { event: "ready", ok: true, tools: names, toolDefinitions });

  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString();
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      if (line.trim().length > 0) {
        handleLine(socket, line, meta, definitions);
      }
    }
  });
  socket.on("error", () => {});
}

async function handleLine(socket, line, meta, definitions) {
  let request;
  try {
    request = JSON.parse(line);
  } catch (error) {
    // 非 JSON 行当噪音丢掉 —— 客户端会把日志行当诊断收走。
    return;
  }
  if (request.op === "hello") {
    const session = request.session ?? {};
    meta.sessionId = String(session.sessionId ?? "");
    meta.provider = String(session.provider ?? "");
    meta.model = String(session.model ?? "");
    send(socket, { ok: true, id: request.id });
    return;
  }
  if (request.op === "call") {
    const definition = definitions[String(request.tool)];
    if (!definition || typeof definition.execute !== "function") {
      send(socket, { ok: false, id: request.id, error: "没有工具 " + String(request.tool) });
      return;
    }
    try {
      const output = await definition.execute(
        request.toolCallId ?? String(request.id ?? "call"),
        request.args ?? {},
        undefined,
        () => {},
        undefined,
      );
      send(socket, { ok: true, id: request.id, result: jsonSafe(output) });
    } catch (error) {
      send(socket, {
        ok: true,
        id: request.id,
        result: {
          content: [{ type: "text", text: String((error && error.message) || error) }],
          isError: true,
        },
      });
    }
    return;
  }
  send(socket, { ok: false, id: request.id, error: "unknown op " + String(request.op) });
}

//------------------------------------------------------------------------------------------------------------------------------
// 启动
//------------------------------------------------------------------------------------------------------------------------------

try {
  const args = parseArgs(process.argv.slice(2));
  const modules = args.modules || resolvePiModules();
  if (!modules) {
    fatal(
      "找不到 pi 的 node_modules（--modules 或 PI_PI_MODULES 指定，或装好 pi）",
    );
  }
  const resolved = { ...args, modules };
  const factory = await loadToolFactory(resolved);
  const server = createServer((socket) => {
    handleConnection(socket, resolved, factory);
  });
  server.on("error", (error) => fatal("监听失败：" + String((error && error.message) || error)));
  server.listen(args.port, "127.0.0.1", () => {
    const port = server.address().port;
    if (args.portFile) {
      try {
        writeFileSync(args.portFile, String(port));
      } catch (error) {
        fatal("写端口文件失败：" + String((error && error.message) || error));
      }
    }
  });
  if (args.managed) {
    // pi-moon 拉起的：父进程关 stdin = 收工。
    process.stdin.resume();
    process.stdin.on("end", () => process.exit(0));
  }
} catch (error) {
  fatal(String((error && error.message) || error));
}
