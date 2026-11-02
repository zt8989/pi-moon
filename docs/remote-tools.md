# 远程工具（RemoteReActAgent）：大脑与手脚分机

`--remote-tools <host:port>` 进入远程模式：pi-moon 的事件环、LLM 调用、重试、
轨迹、会话、TUI **一个字不改**；八个内置工具的定义与执行搬进一个**独立的工具
宿主守护进程**，两边按行协议 RPC 说话。于是：

- 环跑在 A 机器（有模型密钥），工具跑在 B 机器（碰得到真实文件与 shell）——
  **手脚机器不需要任何模型密钥**，泄露面只有它自己的工作区；
- 一台宿主可以服务多个会话、多台大脑（每条连接状态独立）；
- 不给 `--remote-tools`（等价环境变量 `PI_MOON_REMOTE_TOOLS`）时一切照旧，
  现有用法一个字节都不变。

## 部署要求

| 位置 | 需要 |
| --- | --- |
| 大脑机器 | pi-moon 本体 + 模型密钥（与 pi 同一份配置） |
| 手脚机器 | bun ≥ 1.1 + pi 装机（node_modules 里有 `@earendil-works/pi-coding-agent`）+ 宿主脚本（随本仓库分发：`core/rtools/host/tool_host.mjs`） |

宿主自己解析 pi 装机：`--modules` 显式指定 > 环境变量 `PI_PI_MODULES` >
`<agent dir>/install/releases/` 里版本号最大的一份 > `<agent dir>/npm/node_modules`
> PATH 上全局 bin 反推出的 npm 全局 `node_modules`（`npm i -g` / nvm / scoop 装的
pi 只在这里）。与 pi-moon 侧同一条解析顺序。bun 的定位同理（`PI_MOON_BUN` 显式
指定 > 垫片扫描 —— Windows 上 npm/nvm 的 `.cmd` 垫片不能直接 spawn，真 exe 在
`node_modules/bun/bin/bun.exe` 下）。

## 本机双终端演示

```bash
# 终端 1（手脚）：起宿主，只绑 127.0.0.1
bun core/rtools/host/tool_host.mjs --port 8787 --cwd ~/somewhere

# 终端 2（大脑）：连上去干活
pi-moon --remote-tools 127.0.0.1:8787 -p "读 README.md 的前 3 行"
```

启动时 stderr 会报 `[rtools] 已连接 127.0.0.1:8787（工具：read, bash, …）`，
TUI 横幅多出 `[Remote tools]` 段（地址 + 当次生效的远程工具清单）。工具在
**宿主的 cwd** 里真执行：`read probe.txt` 读的是宿主工作区的那个文件。

## 跨机演示（LAN / SSH 隧道）

v1 的宿主**只绑 127.0.0.1**，跨机走隧道把远端端口引到本地：

```bash
# 手脚机器（B）上起宿主
bun tool_host.mjs --port 8787 --cwd ~/workdir

# 大脑机器（A）上建隧道，再连本地端口
ssh -N -L 8787:127.0.0.1:8787 user@B
pi-moon --remote-tools 127.0.0.1:8787 -p "..."
```

同一可信 LAN 里想直连的话，需要自己改宿主的绑定地址（v1 刻意不暴露该开关）。

## 手动验收清单（本机已走通的剧本）

1. 起宿主 → pi-moon 连接 → 真模型经 RPC 调 `read`，文件内容回到环上；
2. `PI_*` 元数据在宿主侧可见（hello 握手送达 → shell 工具的子进程 env 里有
   `PI_SESSION_ID` / `PI_PROVIDER` / `PI_MODEL`）；
3. 会话恢复：带 `--remote-tools` 落盘 → 重启 → `--session <id>` 重连宿主续跑；
4. 中途断宿主：`kill` 守护进程后，**当前调用**折成 `is_error`（stderr 出
   `[rtools] <tool>: 读远程工具宿主输出失败…`），**之后的调用立刻失败**（
   `远程工具宿主已经退出`），环照常走到 idle，会话不判死。

## 协议：与扩展宿主的对照

消息形状与扩展宿主（`ext_host.mjs`）完全一致，只有承载不同（stdio → TCP）：

| | 扩展宿主 | 工具宿主 |
| --- | --- | --- |
| 承载 | bun 子进程的 stdio，按行 JSON | TCP（127.0.0.1），按行 JSON |
| 第一条消息 | 宿主推 `ready`（扩展注册表） | 宿主推 `ready`（内置八件套：名字 / 描述 / schema） |
| 握手 | ——（扩展不需要） | 客户端发 `{"op":"hello","session":{…}}`（session id / provider / model） |
| 调用 | `{"op":"call","tool",…}` → `{"ok":true,"result":{…}}` | 同形；`toolCallId` 一样带 |
| 在途约束 | 一次一条（`id` 只做自检） | 同 |
| 噪音 | `{"event":"log"}` 行与非 JSON 行进诊断 | 同 |
| fatal | `{"event":"fatal"}` → 会话标死 | 同 |
| 转译 | `Bun.build` 打包（扩展是用户 TS） | 不打包：pi 的工具实现按绝对路径 import，bun 现场转译 |
| 多连接 | 一进程一扩展 | 一进程多连接（按连接注入 `PI_*`） |

结果折叠共用同一份 `outcome_of`（text → 文本块，image 的 data/mimeType →
data URL，isError → `is_error`），内核只有一种 ToolOutcome。

## 安全边界（v1）

- **明文 TCP**：行协议里没有密钥、没有凭据，但工具能读写宿主 cwd 里的任何
  文件——不要把它裸奔到不可信网络；
- **只绑 127.0.0.1**：跨机用 SSH 隧道（或等价的可信通道）；
- **无鉴权**：能连上端口的进程就能执行工具 —— 端口只对信任方可达；
- 宿主进程**不读任何模型配置**（不碰 models.json / auth.json / key）。

## Out of Scope（v1 明确不做）

- TLS / 鉴权 / 多租户；
- ToolProgress 流式跨 RPC（远程 shell 没有逐字进度，与扩展工具现状一致）、
  远端执行的中断 / 取消；
- 自动重连、宿主故障转移、多宿主负载分担（断线后调用立刻明确失败，不重连）；
- 扩展宿主远程化（扩展仍跑在 pi-moon 本地起的扩展宿主里）；
- LLM 调用远程化（大脑永远在 pi-moon 进程里）。

## 实现索引

- 客户端与路由：`core/rtools`（`RemoteTools::connect` / `call_tool`，路由链
  「扩展名册 → 远程名册 → 本地」在 provider 的 `run_tools_with_hooks`）；
- 宿主脚本：`core/rtools/host/tool_host.mjs`（经 `scripts/embed-host.mjs` 嵌进
  pi-moon 二进制，供测试与便利拉起；手动部署直接 bun 跑仓库里的文件）；
- 传输：`core/sys` 的 `TcpConn`（native = async/socket，js = node:net）；
- 协议会话：`core/rpc`（与扩展宿主共用）；
- 测试：假宿主协议组 + 真 bun 组（`PI_MOON_BUN` / `PI_PI_MODULES`，缺依赖整组
  跳过）+ 整环故障剧本，见 `core/rtools/rtools_wbtest.mbt`。
