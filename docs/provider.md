# Provider：读 pi 的配置，走 OpenAI 兼容线格式

v0.2 把 `RunAgent` 接到了真实模型上。形状仍然是「effect 表注入」：

```
reducer ──► Cmd::RunAgent ──► Agent 的 deferred 队列
                                      │ await
                                      ▼
                         core/provider 的 effect 表
                          ├─ 读 pi 配置（models/auth/settings）
                          ├─ 组 /chat/completions 请求（messages + tools）
                          └─ 读 SSE → dispatch LlmStarted/Delta/Done/Failed
```

## 端点设置与 SSE 解析（本地的一份）

`core/provider/endpoint.mbt` 里是 `Settings` / `TokenUsage` / `SseEvent` /
`parse_sse_line` 的本地实现 —— 逻辑照 [conglinyizhi/moonbit-llm-faceoff](https://github.com/conglinyizhi/moonbit-llm-faceoff)
@0.2.0（MIT）那一小块搬过来的。不再直接依赖它，因为它 `moon.pkg` 里写的是
`supported_targets = "+native"`，只要出现在 import 表里，js 目标连构建计划都排不出来。

分工仍和以前一样：**连接与协议在本项目内，消息体与工具调用也在本项目内**。
搬过来的只有三样纯逻辑：`Settings`（baseUrl → URL）、`TokenUsage`、
`parse_sse_line`（content / reasoning / usage / finish / done）；`request_body` /
`ask` / `stream_parts` / 自带 CLI 都不用（agent 的请求天然是「一整段 messages +
工具定义」，而库的公开 API 是「一句话进、一段话出」）。

传输仍然走 `moonbitlang/async` 的 `@http.post_stream`，每读一行套一个**空闲**超时。
native 走 socket + TLS，js 走 `fetch`（`@http` 自己按目标选了实现）。

## 配置：与 pi 同址、同形状

目录解析与 pi 一致：

```
PI_CODING_AGENT_DIR   （有就用）
USERPROFILE | HOME    →  /.pi/agent
```

三份文件，缺一份不是错误（读不动 / JSON 坏掉会进 `PiConfig.diagnostics`，
CLI 打到 stderr）：

### `models.json`

```json
{
  "providers": {
    "demo": {
      "baseUrl": "http://gw:7863/v1",
      "api": "openai-completions",
      "apiKey": "可选（优先级最高的一档）",
      "models": [
        {
          "id": "cn:some-model",
          "name": "Some Model",
          "reasoning": true,
          "contextWindow": 1000000,
          "maxTokens": 128000,
          "thinkingLevelMap": { "off": null, "low": "low", "high": "high" },
          "cost": { "input": 0.3, "output": 1.2 },
          "compat": {
            "thinkingFormat": "deepseek",
            "maxTokensField": "max_tokens",
            "supportsReasoningEffort": true,
            "requiresReasoningContentOnAssistantMessages": true
          }
        }
      ]
    }
  }
}
```

两种旧形状也读：

- 根对象直接是 provider 表（没有 `providers` 这一层）；
- `models` 是 `{ "<id>": { ... } }` 对象 map（key 当 id）。

`baseUrl` 可以写在 provider 上，也可以写在单个模型上（后者优先）。

### `auth.json`

```json
{ "demo": { "type": "api_key", "key": "sk-..." } }
```

也接受旧形状的裸字符串 `{ "demo": "sk-..." }`。OAuth 条目（没有 `key`）目前不认。

### `settings.json`

```json
{ "defaultProvider": "demo", "defaultModel": "cn:some-model", "defaultThinkingLevel": "high" }
```

## 解析优先级

| 东西 | 顺序 |
| --- | --- |
| provider | `--provider` > `settings.defaultProvider` > 唯一一个 provider > 内置 |
| model | `--model` > `settings.defaultModel` > provider 的第一个模型 |
| api key | `--api-key` > `models.json` 的 `apiKey` > `auth.json` > `<ID>_API_KEY` 环境变量 |
| thinking | `--thinking` > `settings.defaultThinkingLevel` > `off` |

`<ID>_API_KEY` 的 id 会大写、非字母数字换成 `_`：`my-gateway` → `MY_GATEWAY_API_KEY`。

**内置 provider**（没有 `models.json` 也能用）：`openai` / `deepseek` /
`openrouter` / `groq` / `mistral` / `xai` / `together` / `moonshot` / `zhipu` /
`dashscope`（别名 `qwen`）/ `ollama`。都只支持 OpenAI 兼容线格式。

显式给了 `--model` 但模型不在目录里：不报错，按 OpenAI 兼容的默认参数发（不知道
窗口与价格就不假装知道）。`api` 不是 `openai-completions` 前缀的（如
`openai-responses` / `anthropic-messages`）会明确报错。

## 请求体

`request.mbt` 把 state 翻译成：

```
system prompt（state.prompt.system_prompt，放在最前）
+ state.messages（user / assistant / toolResult / system）
+ tools（state.prompt.tools，parameters 从 JSON 文本解析回对象）
+ 思考参数（按 compat.thinkingFormat）
+ stream: true + stream_options.include_usage
```

几个容易踩的点：

- **工具参数是字符串**：OpenAI 线格式里 `function.arguments` 是 JSON **字符串**，
  不是对象。这里原样传我们存的 `arguments` 文本（空则 `"{}"`）。
- **reasoning_content**：`compat.requiresReasoningContentOnAssistantMessages` 为真
  （DeepSeek 一类）时，assistant 历史要把 Thinking 块拼进 `reasoning_content`，
  否则下一轮会被拒。
- **tool 消息的 `name`**：`compat.requiresToolResultName` 为真时补上。
- **空 tools**：历史里有 tool_calls / toolResult 时，即使当前没有工具，也发
  `"tools": []` —— 有些经 LiteLLM 代理的 Anthropic 要求这个字段存在。
- **max_tokens**：`--max-tokens` > 模型目录里的 `maxTokens` > 不发。字段名按
  `compat.maxTokensField`（`max_tokens` / `max_completion_tokens`）。

### 思考参数

| `compat.thinkingFormat` | 开启 | 关闭 |
| --- | --- | --- |
| `deepseek` / `zai` | `thinking: {type:"enabled"}` + 可选 `reasoning_effort` | `thinking: {type:"disabled"}` |
| `qwen` | `enable_thinking: true` + 可选 `reasoning_effort` | `enable_thinking: false` |
| `openrouter` | `reasoning: {effort: <mapped>}` | `reasoning: {effort: "none"}` |
| `together` | `reasoning: {enabled:true}` + 可选 effort | `reasoning: {enabled:false}` |
| `string-thinking` | `thinking: <mapped string>` | 不发 |
| 其它（`openai`） | `reasoning_effort: <mapped>` | `off` 有映射时才发 |

`thinkingLevelMap[level]` 显式为 `null` 表示「这一档不支持」，此时什么都不发
—— 不把「不支持」伪装成「关掉」。映射缺失时按原级别字符串发。

## 流

```
@http.post_stream
  → write(body) + end_request()
  → 非 2xx：读 body → LlmFailed(kind 由状态码分类)
  → 逐行 read_sse_line_or_abort：读行（套 idle_timeout_ms 空闲超时）与
    中断轮询（每 100ms 查 should_abort）并跑，谁先完成谁赢
      → parse_sse_line：content / reasoning / usage / finish / done
      → 额外解析 delta.tool_calls（本地解析把它归进 Ignore）
      → 额外解析搭在 finish chunk 上的 usage（本地实现只认空 choices 的 usage）
      → DeltaContent / DeltaReasoning：先交给 ProviderHooks（写终端），
        再 dispatch LlmDelta / LlmThinking（当场归约）
  → 流没有任何 content / 工具 / finish 就结束：按截断处理，LlmFailed(Network)
  → 正常结束：LlmDone(assistant part)
```

工具调用分片按 `index` 拼：第一片带 `id` + `name`，后面的片只带 `arguments`
增量；拼完的 `arguments` 是 JSON 文本，直接进 `ToolCall`。

**超时是空闲语义**：`idle_timeout_ms` 卡的是「多久没收到一行」，不是总时长。
长生成跑多久都不受限（原项目踩过总时长闸把合法长回复砍成死循环的坑）。
空闲超时只决定「多久没数据报错」；中断不走这条闸，见 `read_sse_line_or_abort`
的并行轮询（`core/provider/effect.mbt`）。

## 错误分类

| 来源 | kind | 可重试 |
| --- | --- | --- |
| `@async.TimeoutError` | `Timeout` | ✓ |
| 连接 / TLS / 流中断 | `Network` | ✓ |
| HTTP 429 / 5xx | `Network` | ✓ |
| HTTP 401 / 403 | `Auth` | ✗ |
| HTTP 404 / 400 / 422 | `Model` | ✗ |
| 其它 | `Unknown` | ✗ |

重试由 reducer 决定（`llm_attempts < max_llm_attempts`，默认失败后重试一次），
且重试在**同一个 step 容器**里进行。

## 命令行

```bash
pi-moon -p "用一句话说明什么是 Elm 架构"
pi-moon --list-models
pi-moon -P deepseek -m deepseek-chat --thinking low -p "..."
echo "总结这段日志" | pi-moon --no-trace
```

- **stdout 只有模型回答**（流式逐字），诊断（banner / 轨迹 / tokens）全在 stderr；
  所以 `pi-moon -p ... > answer.txt` 拿到的是干净的回答。
- `--thinking` 的级别会进请求（见上面的思考参数表）。
- `--show-thinking` 把思考增量打到 stderr（默认不显示）。
- `--show-tool-progress` 把 shell 工具的中间输出（只取最后一行）原地刷到 stderr；
  `ToolProgress` action 本身无论开不开都会回环（见 [tools](tools.md)）。
- `-s/--session <file>` / `-c/--continue` / `-i/--interactive` / `--no-session`：
  JSONL 会话（恢复 / 最新 / 多轮 / 不落盘），见 [session](session.md)。
- `--agent-dir` 指向另一份 pi 配置（默认 `~/.pi/agent`）。
- 退出码：参数 / 配置 / 网络错误为 1。

## 已验证

对着 `models.json` 里的自定义网关（`openai-completions`）实跑：

```text
$ pi-moon -p "用一句话解释什么是 Elm 架构" --thinking off --no-trace
Elm 架构是一种把界面程序拆成 Model、View、Update 三部分、以单向数据流运转的 UI 组织模式。
[workbuddy/cn:deepseek-v4.1-flash] 模型说完了  步=1  tokens: 90 in / 67 out
```

轨迹（stderr）：

```text
○  n6 step.start: 第 1 步 1.5s (provider=workbuddy, model=cn:deepseek-v4.1-flash)
│  │  ○  n7 llm.result: 你好 0ms
│  └─ n8 step.end: 第 1 步结束（0 个工具调用）
└─ n9 turn.end: 回合 1 结束：模型说完了 (reason=completed, steps=1)
```

## 已知边界

- **只支持 OpenAI 兼容线格式。** 没有 Anthropic / Gemini / Responses 的转换；
  遇到这些 `api` 会明确报错而不是发一个必然失败的请求。
- **工具执行已接。** 请求里带 `state.prompt.tools` 的声明；`run_tools`、工具实现
  与开关语义见 [tools](tools.md)。工具失败是**错误结果**（消息序列仍然合法），
  不掐回合。
- **OAuth 凭证不认。** `auth.json` 里只有 `key`（api_key）会被使用。
- **价格**：`models.json` 的模型没写 `cost` 时，`tokens` 照常显示，`cost` 不显示。
- **不读系统代理环境变量**：`@http` 客户端不会自动用 `HTTPS_PROXY`。需要走代理时
  目前只能直连；加 `--proxy` 是后续的事。
- **`moon` 的一条依赖警告**：`rabbita → hackwaly/moonback@0.8.1` 已弃用。这是
  上游依赖链，来自 vendored tui 的传递依赖，不影响构建。
