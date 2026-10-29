// bun 宿主脚本：pi 扩展在这里装载、注册、被调用。
//
// 形状照 magpie：主程序不嵌 JS 引擎，扩展跑在独立进程里，两边按行说 JSON。
//
// 两种模式：
//   --mode load   一次性：构建（命中缓存则跳过）→ 加载 → 回传注册表 → 退出
//   --mode serve  常驻：同上，然后从 stdin 读请求（call / emit / command）
//
// 关键约束（每一条都对应一个踩过的坑）：
//   - 扩展是 TS，bun 自己会转译，但 import 的 pi 包必须落在**产物所在目录**
//     的 node_modules 里 —— bun 按 realpath 解析 importer，符号链接扩展目录
//     会指回原位置，所以统一 Bun.build 打包到 hostRoot/build 下再 import。
//   - 沙盒边界靠 **构建期改写**：node:fs / node:child_process 被换成策略模块，
//     路径检查按允许根目录（cwd / agent 目录 / tmp）做。运行期 monkeypatch
//     内置模块对 ESM 具名导入无效，所以只能在这一层拦。
//   - 扩展抛的错必须变成 JSON 里的 error 字段，不能让宿主进程崩掉。

import { existsSync, mkdirSync, symlinkSync, lstatSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { isBuiltin } from "node:module";
import { format } from "node:util";

//------------------------------------------------------------------------------------------------------------------------------
//  stdout 是协议通道
//------------------------------------------------------------------------------------------------------------------------------
//
// serve 模式下 stdout 每一行都是 RPC（请求 / 响应 / log），所以**任何**非协议
// 写入都是污染源：扩展里一句 console.log 就能把一行的开头咬掉。stderr 这边也
// 不能用 —— 两侧共用一根管道，没人读的那一半会把管子读满而把宿主卡死。
// 所以：console.* 与宿主自己的诊断统一写成 `{"event":"log"}` 行，由 pi-moon
// 转到 stderr 的 `[ext]` 诊断里。

function writeLog(level, text) {
  process.stdout.write(
    JSON.stringify({ event: "log", level, text: String(text) }) + "\n",
  );
}

for (const level of ["log", "info", "warn", "error", "debug", "trace"]) {
  console[level] = (...args) => writeLog(level, args.map((arg) => (typeof arg === "string" ? arg : format(arg))).join(" "));
}

//------------------------------------------------------------------------------------------------------------------------------
//  参数
//------------------------------------------------------------------------------------------------------------------------------

const argv = process.argv.slice(2);

function flag(name, fallback) {
  const index = argv.indexOf("--" + name);
  if (index < 0 || index + 1 >= argv.length) {
    return fallback;
  }
  return argv[index + 1];
}

// 一律先转绝对路径：宿主脚本自己的工作目录是缓存目录，相对路径会解错。
// bun 的模块解析读的是 `PWD` 环境变量，不是真实的 process.cwd()。
// 主程序 spawn 宿主时 PWD 还指着调用者的目录，于是「产物里的裸包 import」
// 会从错误的地方向上找 node_modules（表现为 Cannot find module，而同样的
// 命令在 shell 里手动跑却正常）。
process.env.PWD = process.cwd();

const hostRoot = resolve(flag("root", "."));
const modulesDir = resolve(flag("modules", "."));
const cwd = resolve(flag("cwd", process.cwd()));
const agentDir = flag("agent", "") ? resolve(flag("agent", "")) : "";
const mode = flag("mode", "load");
const extensionPath = flag("path", "") ? resolve(flag("path", "")) : "";
const cacheKey = flag("key");
const sourceName = flag("name", "extension");
const outputPath = flag("out", "") ? resolve(flag("out", "")) : "";

if (!hostRoot || !modulesDir || !extensionPath || !cacheKey) {
  writeLog("error", "pi-moon 扩展宿主：缺少 --root / --modules / --path / --key");
  process.exit(2);
}

// 允许访问的目录：工作目录、agent 目录、临时目录。写操作同样只在这些根下。
const allowedRoots = [cwd, agentDir, process.env.TMPDIR || "/tmp"]
  .filter((root) => typeof root === "string" && root.length > 0)
  .map((root) => (root.endsWith(sep) ? root : root + sep));

function ensureWithin(target, forWrite) {
  const absolute = resolve(cwd, String(target));
  const okay = allowedRoots.some(
    (root) => absolute === root.slice(0, -1) || absolute.startsWith(root),
  );
  if (!okay) {
    const kind = forWrite ? "写" : "读";
    throw new Error(
      "扩展沙盒拒绝" + kind + "路径 " + absolute + "（只允许 cwd / agent 目录 / 临时目录）",
    );
  }
  return absolute;
}

//------------------------------------------------------------------------------------------------------------------------------
//  宿主根目录：node_modules 指向 pi 的安装目录
//------------------------------------------------------------------------------------------------------------------------------

function prepareHostRoot() {
  mkdirSync(hostRoot, { recursive: true });
  mkdirSync(join(hostRoot, "build"), { recursive: true });
  // 关掉 bun 的自动安装：否则解析不到的包会被悄悄从 npm 下载，
  // 「能不能装」取决于网络而不是这台机器上装了什么。
  writeFileSync(
    join(hostRoot, "bunfig.toml"),
    '[install]\nauto = "disable"\n',
    "utf8",
  );
  const linkPath = join(hostRoot, "node_modules");
  let present = false;
  try {
    present = lstatSync(linkPath).isSymbolicLink();
  } catch (error) {
    present = false;
  }
  if (!present) {
    try {
      if (existsSync(linkPath)) {
        rmSync(linkPath, { recursive: true, force: true });
      }
      // Windows 上建目录符号链接要特权（Developer Mode 或管理员），普通用户是
      // EPERM；junction 不要。扩展的裸包 import 在构建时已经改写成绝对路径了，
      // 这一层只是给「运行期自己 require 一个包」的扩展留的后路。
      symlinkSync(
        modulesDir,
        linkPath,
        process.platform === "win32" ? "junction" : "dir",
      );
    } catch (error) {
      // 没有符号链接也能跑 —— 只是 pi 自己的包会解析不到，装载时再报。
      writeLog("warn", "[ext-host] node_modules 链接失败：" + String(error.message || error));
    }
  }
}

//------------------------------------------------------------------------------------------------------------------------------
//  构建：一次打包，产物按 cacheKey 落在 hostRoot/build 下
//------------------------------------------------------------------------------------------------------------------------------

//------------------------------------------------------------------------------------------------------------------------------
//  目录白名单：产物后处理把 `node:fs` / `node:child_process` 的导入改指向
//  这几个 sidecar。
//
//  为什么不在 Bun.build 的插件里做：bun 的 onResolve **看不到内置模块**
//  （`fs` / `node:fs` 在插件之前就被解析成 external 了），试过确认拦不住。
//  产物很小（几百字节），import 语句是可枚举的文本，直接改写最实在。
//
//  这是 JS 层的门禁：挡得住「顺手读了不该读的文件」，挡不住刻意绕过
//  （动态拼路径、process.binding 之类）。真正的 OS 级隔离要平台支持
//  （Linux landlock / seatbelt），macOS 上 sandbox-exec 已经不能用了。
//------------------------------------------------------------------------------------------------------------------------------

const policyFsSource = String.raw`
import * as real from "node:fs";
export * from "node:fs";

const state = globalThis.__pi_moon_policy;
function check(target, forWrite) {
  const absolute = state.resolve(state.cwd, String(target));
  const okay = state.roots.some((root) => absolute === root.slice(0, -1) || absolute.startsWith(root));
  if (!okay) {
    const kind = forWrite ? "写" : "读";
    const message = "扩展沙盒拒绝" + kind + "路径 " + absolute + "（只允许 cwd / agent 目录 / 临时目录）";
    state.denied.push(message);
    throw new Error(message);
  }
  return target;
}
function guard(name, forWrite) {
  const original = real[name];
  if (typeof original !== "function") { return original; }
  return function (target, ...rest) {
    check(target, forWrite);
    return original.call(real, target, ...rest);
  };
}

export const readFileSync = guard("readFileSync", false);
export const readFile = guard("readFile", false);
export const writeFileSync = guard("writeFileSync", true);
export const writeFile = guard("writeFile", true);
export const appendFileSync = guard("appendFileSync", true);
export const appendFile = guard("appendFile", true);
export const readdirSync = guard("readdirSync", false);
export const readdir = guard("readdir", false);
export const statSync = guard("statSync", false);
export const stat = guard("stat", false);
export const lstatSync = guard("lstatSync", false);
export const existsSync = guard("existsSync", false);
export const openSync = guard("openSync", false);
export const mkdirSync = guard("mkdirSync", true);
export const mkdtempSync = guard("mkdtempSync", true);
export const rmSync = guard("rmSync", true);
export const unlinkSync = guard("unlinkSync", true);
export const renameSync = guard("renameSync", true);
export const copyFileSync = guard("copyFileSync", true);
export const realpathSync = guard("realpathSync", false);
export const createReadStream = guard("createReadStream", false);
export const createWriteStream = guard("createWriteStream", true);
`;

const policyFsPromisesSource = String.raw`
import * as real from "node:fs/promises";
export * from "node:fs/promises";

const state = globalThis.__pi_moon_policy;
function check(target, forWrite) {
  const absolute = state.resolve(state.cwd, String(target));
  const okay = state.roots.some((root) => absolute === root.slice(0, -1) || absolute.startsWith(root));
  if (!okay) {
    const kind = forWrite ? "写" : "读";
    const message = "扩展沙盒拒绝" + kind + "路径 " + absolute + "（只允许 cwd / agent 目录 / 临时目录）";
    state.denied.push(message);
    throw new Error(message);
  }
  return target;
}
function guard(name, forWrite) {
  const original = real[name];
  if (typeof original !== "function") { return original; }
  return async function (target, ...rest) {
    check(target, forWrite);
    return await original.call(real, target, ...rest);
  };
}

export const readFile = guard("readFile", false);
export const writeFile = guard("writeFile", true);
export const appendFile = guard("appendFile", true);
export const readdir = guard("readdir", false);
export const stat = guard("stat", false);
export const lstat = guard("lstat", false);
export const mkdir = guard("mkdir", true);
export const mkdtemp = guard("mkdtemp", true);
export const rm = guard("rm", true);
export const unlink = guard("unlink", true);
export const rename = guard("rename", true);
export const copyFile = guard("copyFile", true);
export const realpath = guard("realpath", false);
`;

const policyChildProcessSource = String.raw`
import * as real from "node:child_process";
export * from "node:child_process";

const state = globalThis.__pi_moon_policy;
function note(command) {
  if (state.childCalls.length < 128) { state.childCalls.push(String(command)); }
}
export const spawn = function (command, ...rest) { note(command); return real.spawn(command, ...rest); };
export const exec = function (command, ...rest) { note(command); return real.exec(command, ...rest); };
export const execSync = function (command, ...rest) { note(command); return real.execSync(command, ...rest); };
export const spawnSync = function (command, ...rest) { note(command); return real.spawnSync(command, ...rest); };
export const execFile = function (file, ...rest) { note(file); return real.execFile(file, ...rest); };
export const execFileSync = function (file, ...rest) { note(file); return real.execFileSync(file, ...rest); };
`;

// 写在 build 目录旁边：产物里的 `./policies/fs.mjs` 按相对路径解析。
function writePolicies(builtDir) {
  const dir = join(builtDir, "policies");
  mkdirSync(dir, { recursive: true });
  return [
    [join(dir, "fs.mjs"), policyFsSource],
    [join(dir, "fs-promises.mjs"), policyFsPromisesSource],
    [join(dir, "child-process.mjs"), policyChildProcessSource],
  ].map(([file, source]) => {
    try {
      if (existsSync(file) && readFileSyncSafe(file) === source) {
        return false;
      }
    } catch (error) {
      // 读不出来就重写。
    }
    writeFileSyncSafe(file, source);
    return true;
  }).some(Boolean);
}

const readFileSyncSafe = (file) => readFileSync(file, "utf8");
const writeFileSyncSafe = (file, source) => writeFileSync(file, source, "utf8");

// 哪些 specifier 交给 bun 自己解析（相对路径 / 绝对路径 / 内置模块）。
//
// 绝对路径这条为什么必须显式判：Windows 的入口路径是 `C:\...`，既不以 "/"
// 也不以 "." 开头，会被当成裸包 —— 于是 `resolveSync` 把它解析成绝对路径又标
// external，Bun.build 直接报「entry point cannot be marked as external」。
//
// 内置模块也必须留在这里解析：一旦在 onResolve 里把它们标成 external，后面的
// 策略改写（node:fs → policies/fs.mjs）就再也拦不到了。
const isOwnPath = (specifier) =>
  specifier.startsWith(".") ||
  isAbsolute(specifier) ||
  specifier.startsWith("file:") ||
  specifier.startsWith("node:") ||
  isBuiltin(specifier);

// 把产物里剩下的裸包 import 改成**绝对路径**。
//
// 为什么不能靠 node_modules 符号链接：bun 在进程启动时就固定了解析根，
// 而链接是启动后才建的（缓存目录是新建的），于是运行期 import 找不到包。
//   - 只标 external 不够 —— bun 之后还要按 referrer 再解析一次
//     （referrer 为空时会失败，且报错信息是它自己的）；
//   - 只给绝对路径不标 external —— bun 会把整个 pi CLI 内联进来
//     （单个扩展 8.9MB）。
// 所以：构建时 external，构建后按 modulesDir 解析成绝对路径写回产物。
// 裸包从哪里找：pi 自己的依赖不一定在 node_modules 根下。
//
// `typebox` 就是典型：它装在 `@earendil-works/pi-coding-agent/node_modules`
// 里（pi 自己的依赖），从根目录 resolve 不到。pi 的扩展在 pi 进程里能 import
// 到它，是因为解析链从 pi 包开始 —— 这里把同一个起点补回来。
function resolveBare(specifier) {
  for (const base of [modulesDir, join(modulesDir, "@earendil-works", "pi-coding-agent")]) {
    try {
      return Bun.resolveSync(specifier, base);
    } catch (error) {
      // 下一个起点
    }
  }
  return "";
}

function absolutizeBareImports(code) {
  const bareImport = /(from\s*|import\s*|require\s*\(\s*|import\s*\(\s*)(["'])([^"'./][^"']*)\2/g;
  return code.replace(bareImport, (whole, prefix, quote, specifier) => {
    // bun 会把 `node:path` 归一成 `path`，所以两种都要按内置模块跳过，
    // 否则 resolveSync 会把它们当相对路径，产出 file:///cwd/path 这种鬼东西。
    if (specifier.startsWith("node:") || isBuiltin(specifier)) {
      return whole;
    }
    const resolved = resolveBare(specifier);
    if (!resolved) {
      return whole;
    }
    return prefix + quote + pathToFileURL(resolved).href + quote;
  });
}

// 把裸内置导入改指向 sidecar。三种写法都覆盖：
//   `from "node:fs"` / `from "fs"` / `import "node:fs"` / `require("node:fs")`
function rewritePolicies(code) {
  const mappings = [
    ["node:fs/promises", "./policies/fs-promises.mjs"],
    ["fs/promises", "./policies/fs-promises.mjs"],
    ["node:child_process", "./policies/child-process.mjs"],
    ["child_process", "./policies/child-process.mjs"],
    ["node:fs", "./policies/fs.mjs"],
    ["fs", "./policies/fs.mjs"],
  ];
  let out = code;
  for (const [specifier, replacement] of mappings) {
    for (const quote of ['"', "'"]) {
      out = out.split("from " + quote + specifier + quote).join("from " + quote + replacement + quote);
      out = out.split("import " + quote + specifier + quote).join("import " + quote + replacement + quote);
      out = out.split("require(" + quote + specifier + quote + ")").join("require(" + quote + replacement + quote + ")");
      out = out.split("import(" + quote + specifier + quote + ")").join("import(" + quote + replacement + quote + ")");
    }
  }
  return out;
}

globalThis.__pi_moon_policy = {
  cwd,
  roots: allowedRoots,
  resolve,
  childCalls: [],
  denied: [],
};

function policyModule(realSpecifier) {
  return policySource.replaceAll("__REAL__", realSpecifier);
}

// 构建必须在**别的进程**里做：同一个 bun 进程里跑过 Bun.build 之后，
// 运行期 import 的裸包解析会被构建插件污染（实测：先构建再 import 同一个
// 产物，报 Cannot find module；产物已缓存、没跑构建时同一份文件 import 正常）。
// 只有缓存未命中才多起一个 bun，代价约 30ms。
function buildInChild() {
  // 显式拼子进程参数：不能复用 argv —— 里面已经有 `--mode load`，
  // `flag()` 取第一个匹配会又跑一遍 load（自噬）。
  const childArgs = [
    process.execPath,
    import.meta.path,
    "--root", hostRoot,
    "--modules", modulesDir,
    "--cwd", cwd,
    "--agent", agentDir,
    "--path", extensionPath,
    "--key", cacheKey,
    "--name", sourceName,
    "--mode", "build",
  ];
  const result = Bun.spawnSync(childArgs, {
    cwd: hostRoot,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) {
    const detail = new TextDecoder().decode(result.stderr) ||
      new TextDecoder().decode(result.stdout);
    throw new Error("打包失败：" + String(detail).trim());
  }
}

async function buildExtension() {
  const builtPath = join(hostRoot, "build", cacheKey + ".mjs");
  if (existsSync(builtPath)) {
    return { path: builtPath, built: false };
  }
  buildInChild();
  if (!existsSync(builtPath)) {
    throw new Error("打包失败：产物没有落地 " + builtPath);
  }
  return { path: builtPath, built: true };
}

async function buildOnly() {
  const builtPath = join(hostRoot, "build", cacheKey + ".mjs");
  if (existsSync(builtPath)) {
    return { path: builtPath, built: false };
  }
  const options = {
    entrypoints: [extensionPath],
    target: "bun",
    format: "esm",
    plugins: [
      {
        name: "pi-moon-policy",
        setup(build) {
          // 裸包：pi 的包只有 `"import"` 条件，createRequire 会失败，
          // 必须用 Bun.resolveSync；解析不到就明确报「沙盒不提供」。
          build.onResolve({ filter: /.*/ }, (args) => {
            if (args.namespace === "pi-moon-policy") {
              // 策略模块自己 import 真模块：放行，否则会自噬。
              return undefined;
            }
            const specifier = args.path;
            if (isOwnPath(specifier)) {
              return undefined;
            }
            // 解析成**绝对路径 + external**：
            //   - 只标 external 不够 —— bun 之后还要按 referrer 再解析一次
            //     （referrer 为空时会失败，且报错信息是它自己的）；
            //   - 只给绝对路径不标 external —— bun 会把整个 pi CLI 内联进来
            //     （单个扩展 8.9MB）。
            const resolved = resolveBare(specifier);
            if (!resolved) {
              return {
                errors: [
                  {
                    message:
                      "扩展沙盒解析不到模块 \"" +
                      specifier +
                      "\"（只提供 pi 装机里的包）",
                  },
                ],
              };
            }
            return { path: resolved, external: true };
          });
        },
      },
    ],
  };
  let result;
  try {
    result = await Bun.build(options);
  } catch (error) {
    // Bun.build 有时直接抛，详情在 error.logs / error.errors 里。
    const extra = [error && error.message, error && error.errors, error && error.logs]
      .filter(Boolean)
      .map((value) => (typeof value === "string" ? value : JSON.stringify(value)))
      .join("; ");
    throw new Error("打包失败：" + extra);
  }
  if (!result.success) {
    const details = result.logs
      .map((log) => {
        const position = log.position
          ? " @ " + log.position.file + ":" + log.position.line
          : "";
        return String(log.message || log) + position;
      })
      .join("; ");
    throw new Error("打包失败：" + details);
  }
  const code = absolutizeBareImports(rewritePolicies(await result.outputs[0].text()));
  writePolicies(join(hostRoot, "build"));
  await Bun.write(builtPath, code);
}

//------------------------------------------------------------------------------------------------------------------------------
//  pi 对象
//------------------------------------------------------------------------------------------------------------------------------

const registry = {
  tools: [],
  commands: [],
  handlers: {},
  unsupported: [],
  providers: [],
  mcps: [],
};

const toolImpls = new Map();
const commandImpls = new Map();
const handlerImpls = new Map();

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

function noteUnsupported(name) {
  if (!registry.unsupported.includes(name)) {
    registry.unsupported.push(name);
  }
}

const piApi = {
  registerTool(tool) {
    if (!tool || typeof tool.name !== "string" || tool.name.length === 0) {
      throw new Error("registerTool 需要一个带 name 的工具定义");
    }
    registry.tools.push({
      name: tool.name,
      label: tool.label ?? null,
      description: tool.description ?? "",
      parameters: jsonSafe(tool.parameters),
      exposure: tool.exposure ?? "direct",
      annotations: jsonSafe(tool.annotations),
      executionMode: tool.executionMode ?? null,
    });
    toolImpls.set(tool.name, tool);
    return () => {
      toolImpls.delete(tool.name);
    };
  },
  registerCommand(name, definition) {
    registry.commands.push({
      name: String(name),
      description: String((definition && definition.description) || ""),
    });
    commandImpls.set(String(name), definition || {});
    return () => {
      commandImpls.delete(String(name));
    };
  },
  on(event, handler) {
    if (typeof handler !== "function") {
      return () => {};
    }
    const list = registry.handlers[event] ?? (registry.handlers[event] = []);
    list.push(list.length);
    const handlers = handlerImpls.get(event) ?? [];
    handlers.push(handler);
    handlerImpls.set(event, handlers);
    return () => {
      const at = handlers.indexOf(handler);
      if (at >= 0) {
        handlers.splice(at, 1);
      }
    };
  },
  registerProvider(name) {
    registry.providers.push(String(name));
  },
  registerMcpServer(name) {
    registry.mcps.push(String(name));
  },
  // 会话与工具集是宿主的事：这些在 pi-moon 里还没有对应实现，记一笔空操作。
  appendEntry() {},
  sendMessage() {},
  sendUserMessage() {},
  setActiveTools() {},
  getActiveTools() {
    return [];
  },
  getAllTools() {
    return [];
  },
  events: {
    on() {
      return () => {};
    },
    emit() {},
  },
};

const pi = new Proxy(piApi, {
  get(target, key) {
    if (typeof key === "symbol") {
      return target[key];
    }
    if (Object.prototype.hasOwnProperty.call(target, key)) {
      return target[key];
    }
    return function () {
      noteUnsupported(String(key));
      return () => {};
    };
  },
});

globalThis.pi = pi;

// 扩展不该掀掉宿主：`process.exit` 变成一条记录。
const realExit = process.exit.bind(process);
process.exit = function (code) {
  noteUnsupported("process.exit(" + String(code) + ")");
  throw new Error("扩展不能结束宿主进程（process.exit(" + String(code) + ")）");
};

//------------------------------------------------------------------------------------------------------------------------------
//  装载
//------------------------------------------------------------------------------------------------------------------------------

async function loadExtension() {
  const built = await buildExtension();
  // 不能加 `?v=` 之类的查询串：产物里的裸包 import 要按**产物路径**向上找
  // node_modules，带查询串会把 importer 变成一个找不到的路径。
  // 产物名就是内容哈希，源码变了键就变了，不需要额外破缓存。
  const module = await import(pathToFileURL(built.path).href);
  const factory = module.default ?? module;
  if (typeof factory !== "function") {
    throw new Error("扩展没有导出默认函数");
  }
  await factory(pi);
  return { built: built.built, builtPath: built.path };
}

//------------------------------------------------------------------------------------------------------------------------------
//  JSON-lines
//------------------------------------------------------------------------------------------------------------------------------

function writeLine(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

async function handleLoad() {
  const started = Date.now();
  const details = await loadExtension();
  return {
    ok: true,
    name: sourceName,
    registry: {
      tools: registry.tools.map((tool) => tool.name),
      commands: registry.commands.map((command) => command.name),
      events: Object.keys(registry.handlers),
      unsupported: registry.unsupported,
      providers: registry.providers,
      mcps: registry.mcps,
    },
    policy: { denied: globalThis.__pi_moon_policy.denied, childCalls: globalThis.__pi_moon_policy.childCalls },
    toolDefinitions: registry.tools,
    built: details.built,
    ms: Date.now() - started,
  };
}

async function handleCall(request) {
  const impl = toolImpls.get(String(request.tool));
  if (!impl || typeof impl.execute !== "function") {
    throw new Error("扩展没有注册工具 " + String(request.tool));
  }
  const output = await impl.execute(
    request.toolCallId ?? "ext-call",
    request.args ?? {},
    undefined,
    () => {},
    undefined,
  );
  return { ok: true, id: request.id, result: jsonSafe(output) };
}

async function handleEmit(request) {
  const handlers = handlerImpls.get(String(request.event)) ?? [];
  const results = [];
  for (const handler of handlers) {
    try {
      const value = await handler(request.payload ?? {}, undefined);
      results.push(jsonSafe(value));
    } catch (error) {
      results.push({ error: String((error && error.message) || error) });
    }
  }
  return { ok: true, id: request.id, results };
}

async function handleCommand(request) {
  const impl = commandImpls.get(String(request.command));
  if (!impl || typeof impl.handler !== "function") {
    throw new Error("扩展没有注册命令 " + String(request.command));
  }
  const value = await impl.handler(request.args ?? "", undefined);
  return { ok: true, id: request.id, result: jsonSafe(value) };
}

async function dispatch(line) {
  let request;
  try {
    request = JSON.parse(line);
  } catch (error) {
    return { ok: false, id: null, error: "请求不是合法 JSON" };
  }
  try {
    if (request.op === "call") {
      return await handleCall(request);
    }
    if (request.op === "emit") {
      return await handleEmit(request);
    }
    if (request.op === "command") {
      return await handleCommand(request);
    }
    return { ok: false, id: request.id ?? null, error: "未知 op：" + String(request.op) };
  } catch (error) {
    return {
      ok: false,
      id: request.id ?? null,
      error: String((error && error.message) || error),
    };
  }
}

//------------------------------------------------------------------------------------------------------------------------------
//  入口
//------------------------------------------------------------------------------------------------------------------------------

async function main() {
  prepareHostRoot();
  if (mode === "build") {
    await buildOnly();
    realExit(0);
    return;
  }
  if (mode === "load") {
    let payload;
    try {
      payload = await handleLoad();
    } catch (error) {
      payload = { ok: false, error: String((error && error.message) || error) };
    }
    const text = JSON.stringify(payload);
    if (outputPath) {
      await Bun.write(outputPath, text);
    } else {
      writeLine(payload);
    }
    realExit(payload.ok ? 0 : 1);
    return;
  }

  // serve：先把扩展装好，再进读循环
  try {
    const loaded = await handleLoad();
    writeLine({ event: "ready", ...loaded });
  } catch (error) {
    writeLine({ event: "fatal", error: String((error && error.message) || error) });
    realExit(1);
    return;
  }

  let pending = "";
  const decoder = new TextDecoder();
  for await (const chunk of Bun.stdin.stream()) {
    pending += decoder.decode(chunk, { stream: true });
    let index = pending.indexOf("\n");
    while (index >= 0) {
      const line = pending.slice(0, index).trim();
      pending = pending.slice(index + 1);
      if (line.length > 0) {
        const response = await dispatch(line);
        writeLine(response);
      }
      index = pending.indexOf("\n");
    }
  }
  realExit(0);
}

main().catch((error) => {
  writeLine({ ok: false, event: "fatal", error: String((error && error.message) || error) });
  realExit(1);
});
