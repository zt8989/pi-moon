# 工具：八个内置工具，开关与 pi 一致

`core/tools` 是工具注册表 + 执行器。它只依赖 `message` / `action`；「什么时候跑
工具」是 provider 的 effect 表决定的（`RunTools` → `@tools.execute`）。

```text
reducer ──► Cmd::RunTools(calls)
                │
                ▼
        provider 的 run_tools effect
                │  每个 call：
                │    dispatch ToolStart
                │    @tools.execute(state.cwd, call)   ← 读 / 写 / 跑命令
                │    dispatch ToolResult
                │  最后 dispatch ToolBatchDone
                ▼
        回到环上（step 收口，下一次 LLM 调用）
```

失败**不抛回环上**：每个调用都产生一条 `toolResult`（`is_error = true`），消息序列
保持合法，模型自己决定重试还是换办法。这与 pi 的 `runToolCall` 同口径。

## 工具清单

名字、描述、参数 schema 与 pi 的 `BUILTIN_TOOL_NAMES` 一致：

| 工具 | 默认 | 做什么 |
| --- | --- | --- |
| `read` | **开** | 读文件（文本 / 图片；`offset` / `limit`；头截断 2000 行 / 50KB） |
| `write` | **开** | 写文件（自动建父目录；覆盖） |
| `edit` | **开** | 多段精确文本替换（必须唯一、不重叠；保留 CRLF / BOM） |
| `bash` | **开** | 跑 shell 命令（Git Bash / PATH 上的 bash；Unix 用 `/bin/bash` 或 `sh`） |
| `powershell` | **关** | 跑 PowerShell 命令（仅 Windows；`pwsh.exe` 优先） |
| `grep` | **关** | `rg --json` 搜内容（尊重 .gitignore；长行截到 500 字符） |
| `find` | **关** | glob 找文件（`rg --files` 的清单 + 本项目的 glob 匹配器，尊重 .gitignore） |
| `ls` | **关** | 列目录（按字母排序，目录加 `/`；含 dotfile） |

默认开启的是 pi 的 `DEFAULT_TOOL_NAMES`：`read` / `bash` / `edit` / `write`。

## 开关：与 pi 的 `resolveDefaultTools()` 逐条一致

配置文件与 pi 同址：`<agent dir>/settings.json`（默认 `~/.pi/agent/settings.json`）。

```json
{
  "defaultTools": ["read", "bash", "edit", "write", "+powershell"]
}
```

解析规则（`core/tools` 的 `resolve_tool_selection`）：

1. 没配 / 空数组 → `["read", "bash", "edit", "write"]`；
2. 出现**不带前缀**的名字 → 整份清单被**替换**（不是追加）；
3. 只有 `+name` / `-name` → 先取默认清单，再按顺序增删。

未知名字**不报错也不剔除**：与 pi 一样，结果是「那个工具不存在，于是没开成」
—— 它进不了发给模型的声明，也执行不了。

### CLI 覆盖

与 pi 的 `-t` / `-xt` / `--no-tools` 对齐：

```bash
# 替换整个选择（必须列全）
moon run cmd/pi-moon -- -t read,grep,ls -p "..."

# 从选择里去掉几个
moon run cmd/pi-moon -- -xt bash,powershell -p "..."

# 全关
moon run cmd/pi-moon -- --no-tools -p "..."
```

启动时的 stderr 会打出本次实际开着的工具：

```text
[workbuddy/cn:deepseek-v4.1-flash (thinking=high)]  tools=read,bash,edit,write,powershell  ...
```

`prompt.tools` 轨迹节点也记着同一份清单（`count=5`）。

## 与 pi 的差异（有意保留）

| 差异 | 原因 |
| --- | --- |
| `bash` 的 stdout / stderr 是**分别收集后拼接** | `@shell.Cmd::output` 不合并两条流；pi 是按到达顺序合并。对模型来说顺序偶尔不同，截断策略一致。 |
| `edit` 只做**严格匹配** | pi 还有 NFKC / 智能引号 / 行尾空白的模糊匹配兜底。严格匹配更可预测，失败信息也照抄 pi。 |
| `find` 用 `rg --files` + 本地 glob 匹配器 | 不依赖 fd；`*` / `?` / `**` / `[...]` 都支持。没有 `rg` 时退回 `@shell.glob`（此时**不读** .gitignore）。 |
| `read` 的图片不做缩放 | pi 会把大图重新编码；这里原样转成 `data:` URL 发给模型。 |
| `ToolProgress` 还没有增量 | 工具结果一次性回传；bash 的长输出不是边跑边显示。action / state / 渲染都已就位，缺的是执行器里的流式回调。 |

## 执行细节

```
@tools.execute(cwd, call : ToolCall) -> ToolOutcome
```

- `cwd` 来自 `state.cwd`；相对路径都按它解析（`~`、`@path`、`..` 会展开 / 折叠）。
- 参数是 `call.arguments`（JSON 文本）；坏 JSON / 缺参数 → 错误结果。
- **启用检查在执行侧也做一遍**：provider 把 `state.prompt.tools` 的名字传进
  `execute(enabled=...)`，所以关着的工具（比如默认关的 `powershell`）即使被模型
  硬调，也只会拿到「未知工具」—— 与 pi 的 `getTool()` 同口径。
- 输出上限与 pi 一致：头截断（read / grep / find / ls）或尾截断（bash /
  powershell）2000 行 / 50KB；`bash` 超限时把完整输出写到临时文件并在结果里给出路径。
- 图片（jpg / png / gif / webp / bmp）读成两段内容：一段文本说明，一段
  `data:<mime>;base64,...` 的 image 块。
- shell 工具会拿到 `PI_SESSION_ID` / `PI_PROVIDER` / `PI_MODEL` /
  `PI_REASONING_LEVEL`（与 pi 同名），所以 system prompt 里的那条提示是真能用的。

## 测试

`core/tools/tools_wbtest.mbt` 覆盖：

- 默认集合、`+/−`、替换、重复、未知名字、CLI 剔除；
- 八个工具的定义与 schema（JSON 可解析）；
- glob 匹配器与头 / 尾截断；
- 一条完整链路：`write → read → edit → ls → grep → find → bash`（临时目录，
  跑完删除）；grep 的目录 / 单文件 / context、ls 的 dotfile、bash 的 `PI_*`
  环境变量都在里面；非零退出码 / 未知工具 / 坏参数 / 缺参数 / 未启用的工具
  都是错误结果；
- `edit` 保留 CRLF 与 BOM；`read` 把图片转成 text + `data:` image 块；
- `powershell`：Windows 上真跑，其它平台给明确错误。
