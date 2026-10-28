# 上下文与技能（core/context）

启动时装进 system prompt 的两类静态资料：**项目上下文文件**与**技能**。
发现规则照 pi / elA 的同一套，但自己实现（pi 那份是 TypeScript，带完整的
YAML / ignore 解析，这里按需求收窄成几条能测的规则）。

## 上下文文件（AGENTS.md 一族）

`load_context_files(cwd, agent_dir)` 找两处：

| 位置 | 顺序 |
| --- | --- |
| `<agent dir>`（`~/.pi/agent`） | 全局，最前 |
| cwd 沿祖先链每层（**从最远的祖先到 cwd**） | 项目级，越近越靠后 |

每层目录按 pi 的候选顺序只取第一个存在的：`AGENTS.override.md` →
`AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`。路径重复只收第一份；
读失败当没有（宁可少一条规则，也不把空内容当规则发）。

渲染成 `<project_context>` 段，每份文件一个块：

```xml
<project_context>
Project-specific instructions and guidelines:

<project_instructions path="C:/repo/AGENTS.md">
…文件正文…
</project_instructions>
</project_context>
```

**与 pi 的刻意差异**：pi 对 git worktree 布局有「主仓库那份被本目录遮住」
的判定（要读 `.git` 内部结构），这里不搬 —— 收益只在 worktree 一个布局上。

**技能侧的差异**：祖先链的 `.agents/skills` pi 只收到 git 仓库根为止，这里
一直收到文件系统根（与 AGENTS.md 祖先链同一口径）；家目录那层跳过 —— 它
已经作为 user 层收过，否则同一个文件会跟自己重名。

## 技能（SKILL.md）

一个技能是一个 `SKILL.md`：frontmatter 的 `name`（缺省取父目录名）+
`description`（**必填**，缺了不装载），正文是给模型看的做法。模型**不会
自动加载正文**：prompt 里只列一张「名字 + 描述 + 路径」的清单，任务对上号
时模型自己用 read 工具去读那个文件。

`load_skill_registry(cwd, agent_dir)` 扫五处，**先装载的赢**：

| 位置 | scope |
| --- | --- |
| `<agent dir>/skills`（`~/.pi/agent/skills`） | `user` |
| `<家>/.agents/skills`（Claude Code 风格的技能都在这） | `user` |
| `<cwd>/.pi/skills` | `project` |
| cwd 祖先链每层的 `.agents/skills`（跳过家目录那层） | `project` |
| `--skill` 给的文件 / 目录（可重复） | `path` |

发现规则照 pi 的 `loadSkillsFromDir`：

- 目录里有 `SKILL.md` → 它是技能根，收下就走，不再往下递归；
- 否则递归子目录找 `SKILL.md`；
- 根目录的裸 `*.md` 也算技能（`.agents` 风格），名字取文件名，但必须有
  description；子目录里裸 `*.md` 不算；
- 跳过 `.` 开头与 `node_modules`；
- 重名记一条诊断（先装载的赢），**不静默丢** —— 否则用户以为装上了；
  `disable-model-invocation: true` 的技能不进 prompt 清单（作者声明「别
  让模型自己想起来用我」），但仍能被 `/skill:<name>` 显式展开。

frontmatter 是简化版：只认扁平 `key: value` 的三个键（`name` /
`description` / `disable-model-invocation`），不带完整 YAML 解析器。
名字合法性照 pi 校验（小写 a-z / 0-9 / 连字符，<=64 字符）—— 但只记诊断
不拒绝装载。

## `<skills>` prompt 段

`render_skills_prompt(skills, read_tool)` 形状照 pi 的
`formatSkillsForPrompt`：

```xml
The following skills provide specialized instructions for specific tasks.
Use the read tool to load a skill's file when the task matches its description.
…
<available_skills>
  <skill>
    <name>demo</name>
    <description>…</description>
    <location>C:/x/skills/demo/SKILL.md</location>
  </skill>
</available_skills>
```

`read_tool` 是清单开头那句提示里点的工具名：开了 read 写 `read`，没有
read 就写 `bash`（模型得有一条能读文件的路）；两个都没有时不发技能段。

## `/skill:<name> [参数]`

`expand_skill_command` 把命令展开成 `<skill …>正文</skill>` 块（frontmatter
剥掉），参数跟在块后面。展开成 XML 而不是普通文本：语义是「参考资料」，
且消息里能认出它来。未知名字原样返回 —— 静默吞掉会让用户以为生效了；
读失败把原因附在原命令后面，同样不吞。

## Prompt 模板（`/命令`）

一个 Markdown 文件就是一个 `/命令`（pi 的 prompt-templates 同规）：文件名是
命令名，frontmatter 的 `description`（缺省取正文第一个非空行）进横幅。

- 位置：`<agent dir>/prompts/*.md`（user）与 `<cwd>/.pi/prompts/*.md`
  （project），只扫直接的 `.md` 子文件，不递归；
- 同名时用户级先装载的获胜，被忽略的记一条 `[prompts]` 诊断；
- 模板的展开（`$1` / `$@` / `${1:-default}` 替换）在输入侧，装载层只负责
  发现与展示。

## 启动横幅（TUI）

对话页顶部常驻四段（`cmd/pi-moon/main.mbt` 的 `build_banner`），形状与 pi
的启动画面同形：标签行 + 缩进换行的清单，段间空行：

```text
 [Context] AGENTS.md, ~/.pi/agent/AGENTS.md

 [Skills] demo, other

 [Prompts] /review, /fix-loop

 [Extensions] demo.js

 [Skill conflicts] 重名：skill "demo" 冲突…
```

- `[Context]`：cwd 之下的相对化，其余缩 `~`；只报**真进了 prompt** 的文件
  （拿 system_prompt 文本反查 `path="…"`）—— 恢复旧会话时 prompt 是旧的，
  报磁盘上现在的清单会撒谎；
- `[Skills]`：名字排序后逗号连排；没进 prompt 的（prompt 没有技能段）标
  `*` —— 装了和「模型知道」是两回事；
- `[Prompts]`：`/命令` 按名字排序，见上节；
- `[Extensions]`：沙盒里装载成功的扩展，显示「装了什么」—— 单文件带后缀
  （`demo.js`），目录式扩展是目录名；顺序即装载顺序，不排序（与 pi 一致）；
- `[Skill conflicts]`：装载诊断，排在清单后。

注意：横幅里的排序不用 `Array::sort_by` + `String::compare` —— 这个工具链
里的 `compare` 不对称（`"tdd".compare("recap")` 是 -1，反倒是 1），`cmd`
侧改用自己的字典序比较（`text_less` / `sort_text`）。
