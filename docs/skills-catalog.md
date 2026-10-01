# 技能 / Skills tab：这台 Mac 上有哪些 skill 和 agent、各用了多少次

**改 `SkillCatalog.swift` / `SkillUsage.swift`、或改任何「次数怎么数」的规则前读这份。** 这块的 bug 不报错、不崩，只是数字悄悄偏大或偏小 —— 下面每条 ⚠️ 都是调查时实测过的多算 / 漏算来源，删掉哪条都会把数字改错。

## 是什么 / 在哪

主窗口第 5 个 tab，列出本机所有 Claude Code 和 Codex 的 skill 与 agent：简介、文件位置、用了几次、最近一次什么时候用，默认按次数排。界面是一张「排行榜」列表：每行背后一条蓝色长条，长度按次数比例；顶上的 Skills/Agents 分段、Claude/Codex 筛选、排序按钮固定不动，列表在下面滚；点一行展开详情。

| 文件 | 管什么 |
|---|---|
| `SkillCatalog.swift` | 扫定义文件出目录 + 把次数挂到条目上。入口 `SkillCatalog.load(projectRoots:completion:)`，后台串行队列跑，回主线程给 `[CatalogItem]`（次数降序，同次数按名字） |
| `SkillUsage.swift` | 扫对话记录数次数 + 增量缓存。`SkillUsage.scan()` 是阻塞调用，只许在后台跑 |
| `SkillsPane.swift` | UI（上面那段描述的列表）。细节以代码为准，这份文档不管 |
| `tools/skill-usage-probe/main.swift` | 命令行探针：不起 App 跑一遍全量，打印分组计数、每类前 20、耗时 |

`CatalogItem.id` 全局唯一：项目级 skill 是 `<tool>.<kind>.<name>@<项目目录名>`，其余是 `<tool>.<kind>.<name>`（= `key`）。同一个 id 只收第一次见到的（`definitions` 里的 `seen`）。

## 目录从哪来

### Claude

· **用户 skill**：`~/.claude/skills/<dir>/SKILL.md`。只认「子目录里有 `SKILL.md`」的，目录里别的散文件（如 `notes.md`、`synced/`）自然跳过  
· **插件**：`~/.claude/plugins/installed_plugins.json` 的 `plugins`，key 形如 `<plugin>@<marketplace>`，取 `[0].installPath`；**只收 `~/.claude/settings.json` 的 `enabledPlugins[key] == true` 的**  
　· 名字前缀取 `<installPath>/.claude-plugin/plugin.json` 的 `name`（如 `si:`），**不是 marketplace 的 key**；没有 plugin.json 时退回插件名  
　· skill 名 = `<前缀>:<frontmatter name 或目录名>`；插件 agent 在 `<installPath>/agents/*.md`，同样加前缀  
· **项目 skill**：对传进来的每个 `projectRoots` 读 `<root>/.claude/skills/*/SKILL.md`，origin 是 `.project(<目录名>)`  
  ⚠️ **主目录会被跳过**：`ProjectHistory` 里常有 `~` 本身（在家目录开过会话），而 `~/.agents/skills` 正是 Codex 用户 skill 的目录 —— 不跳过的话每个 Codex skill 都会多一份「项目 · <用户名>」（2026-09-24 预览图里抓到的）。根路径先 `standardizingPath` 再去重
· **agent**：`~/.claude/agents/*.md`，frontmatter 没有 `name` 的跳过（如 `LAYOUT.md`）

⚠️ **monorepo 插件不能 glob `skills/`**：gamedev 那个 marketplace 给每个插件装的都是整个仓库，glob 会把 68 个 skill 每个列 6 遍。规则是：`plugins/marketplaces/<mkt>/.claude-plugin/marketplace.json` 的 `plugins[]` 里如果找到本插件、且声明了 `skills` 数组 → 只收数组里列的（去掉 `./` 前缀、文件不存在的丢掉）；没声明才 glob `<installPath>/skills/*/SKILL.md`。

### Codex

· **用户 skill 在 `~/.agents/skills/`**，⚠️ **不在 `~/.codex/skills/`** —— 那里只有 `.system` 下的 6 个系统 skill（origin `.system`）  
· **项目 skill**：`<root>/.agents/skills/*/SKILL.md`  
· **agent**：`~/.codex/agents/*.toml`，只读顶层 `name` / `description` / `model`。`tomlTopLevel` 会跳过 `"""` / `'''` 多行串 —— agent 的指令正文里常有 `name = ...` 这种行，不跳就会把正文读成 key；遇到第一个 `[表头]` 就停

### 内置项与「已删除」

`builtinClaudeSkills`（12 个，如 `update-config` `run` `code-review` `loop`）和 `builtinClaudeAgents`（`general-purpose` `Explore` `Plan` `claude-code-guide` `statusline-setup` `fork`）没有定义文件。它们**只在有使用次数时**才出现，origin `.builtin`。记录里有次数、但目录里找不到的名字（如已删掉的 `autorun-loop`）也照样出一行，origin `.missing`，简介和路径为空。

### 次数挂到哪一条

一个使用 key 只挂一条：先按 origin 排 `user < plugin < system < project`，先按完整 key 找，找不到再按 **SKILL.md 所在目录名** 找。第二步是给 Codex 用的 —— Codex 的使用是从命令里的路径反推的，拿到的是目录名，而有的 frontmatter `name` 和目录名不一样。同名的项目副本因此永远是 0 次，次数记在用户级那条上。

## 次数怎么数

### Claude（`~/.claude/projects/*/*.jsonl` + `*/<session>/subagents/*.jsonl`）

先按字节 `memmem` 找含 `"name":"Skill"` / `"name":"Agent"` / `"name":"Task"` / `<command-name>` 的行，命中的行再 `JSONSerialization` 整行解析；解析失败或没有 `message` 的行跳过。

· **skill**：`type=="assistant"` 的 `tool_use` 块，`name=="Skill"` → `input.skill`，key `claude.skill.<X>`  
· **手敲斜杠命令**：`type=="user"` 的文本（字符串 content 或 `type=="text"` 块）里的 `<command-name>/X</command-name>` → `claude.typed.<X>`。手敲 `/X` 不会再产生一条 Skill tool_use，所以两者相加不重复  
· **agent**：`tool_use` 的 `name` 是 `Agent` 或 `Task` → `input.subagent_type`，空则算 `general-purpose`  
· **时间**：每行顶层 `timestamp`（ISO UTC），由手写的 `parseISO` 解（`concurrentPerform` 里不共享 formatter）

★ **被拒的 agent 启动不算**：带 `id` 的 Agent/Task 调用先进 `pending`，往后找含 `"tool_use_id":"<id>"` 的行，找到对应 `tool_result` 且 `is_error == true` → 丢弃，否则转正。**还没等到 tool_result 的也照算**（被杀掉的会话永远等不到），pending 跨增量扫描保存在缓存里，下次从新读入的字节开头接着找。

★ **手敲命令在汇总时才过滤**：`claude.typed.*` 在 `SkillUsage` 里原样存，到 `SkillCatalog.build` 才只保留名字属于某个 Claude skill（目录里的 + 内置）的，并入 `claude.skill.<X>`。`/usage` 一类记录有 2 万多条，不过滤会把排行榜顶满；放在汇总时过滤是为了**后来装上的 skill 不用重扫也能拿到它过去被手敲的次数**。

★ **`subagents/*.jsonl` 要扫**：子 agent 里再调的 skill / agent 是真实使用，这些文件不重复父文件的行。

⚠️ **为什么必须 JSON 解析，不能正则 / grep 计数**：agent 调用的 key 顺序实测 8 种以上，而且 prompt 正文里也会出现 `"name":"Agent"` 这类字符串 —— grep 会多算 5–20%。字节预筛只是为了快，**判定一律看解析出来的结构**。

**不要数**（每一条都是会让数字虚高的真实来源）：

· `skill_listing` / `agent_listing_delta` 附件 —— 每轮注入的目录清单，不是使用。代码只认 assistant 行的 `tool_use` 块和 user 行文本里的 `<command-name>` 标签，别的行类型一律落进 `default` 分支  
· `subagents/*.meta.json` —— 和父文件里那次 Agent 调用是同一件事。`listClaude` 只收 `.jsonl`  
· prompt 正文里出现的 skill 名 —— 只认 tool_use 结构和 `<command-name>` 标签  
· `/usage` `/clear` `/model` 等 CLI 命令 —— 见上面「汇总时才过滤」

### Codex（`~/.codex/sessions/**/rollout-*.jsonl`）

预筛字节 `spawn_agent` / `SKILL.md` / `<skill>` / `task_started`，命中行解析；字段在 `payload` 里，没有 `payload` 的行按顶层读。

· **skill 注入**：`type=="message"`、`role=="user"` 的文本以 `<skill>\n<name>` 开头 → `<name>` 里的名字（用户 `$X` 触发时 Codex 注入的）  
· **读 SKILL.md**：`custom_tool_call name=="exec"` 的 `input`，或 `function_call name` 为 `shell` / `exec_command` 的 `arguments` 里，匹配 `sed -n '1,Np' …/<dir>/SKILL.md` 或 `cat …/<dir>/SKILL.md` → 取 `<dir>`  
· ★ **同一轮只算一次**：`task_started` 之间同一个 skill 重复注入 / 重复读都只记 1 次  
· **agent**：`function_call name=="spawn_agent"`，`arguments` 本身是 JSON 字符串要再解一次 → `agent_type`，空则 `default`  
· **时间**：行的 `timestamp`；2025 旧格式没有逐行时间，退回文件名 `rollout-YYYY-MM-DDTHH-mm-ss-…` 里的时间（按本机时区解析，文件名是不是本地时间：未验证）

⚠️ **编辑 / grep SKILL.md 不算**：正则只认「从第 1 行起 sed」和 `cat`。放宽成「命令里出现 SKILL.md」会把 Codex 改 skill、搜 skill 的动作都算成使用。

⚠️ Codex agent 的另一个来源 `~/.codex/state_5.sqlite` 的 `threads.agent_role` **没用**，也别加 —— 和 `spawn_agent` 是同一件事，两边都算就翻倍。

## 增量缓存

· 位置：`~/Library/Caches/SpectiX/skill-usage.json`（实测约 4.8 MB）。每个记录文件一条：`size` / `mtime` / `offset` / `uses` / `pending`  
· `size` 和 `mtime` 都没变 → 整条复用，不开文件  
· **Claude 是真增量**：从 `offset` 接着读，每次只处理到最后一个完整行（最后一个 `\n`），`offset` 停在那里，写了一半的行下次再读。文件变短（`size < offset`）→ 当作新文件从头扫  
· **Codex 不增量**：文件一变就整份重扫（`offset` 直接记成 `size`）。「同一轮只算一次」的 `turnSkills` 依赖从头读，改成增量要先解决这个状态怎么跨次保存  
· 这次没列到的文件（被删了）不写回缓存  
· 实测（2026-09-24，Claude 记录约 1.2 GB / 2.2 万个文件）：**冷扫约 6.2 s，热扫约 0.5 s**

⚠️ **改了任何计数规则，必须把 `SkillUsage.cacheVersion` 加 1。** `loadCache` 只在版本号不等时丢弃旧缓存；不加的话，大小和 mtime 没变的老文件会一直带着旧规则算出来的 `uses`，只有新写入的会话按新规则算 —— 数字新旧混杂，而且不会自己恢复。改 `FileEntry` / `PendingUse` 的字段同理。

## 怎么验

```bash
swiftc -O SkillCatalog.swift SkillUsage.swift tools/skill-usage-probe/main.swift -o /tmp/skillprobe
/tmp/skillprobe            # 带着现有缓存跑两遍：as-is + 热扫
/tmp/skillprobe --cold     # 先删缓存，量冷扫
/tmp/skillprobe --dump     # 末尾追加每个条目一行 TSV（id / origin / 次数 / 最近 / model / 路径 / 简介）
```

探针的项目根是 `~/Projects/*` 里带 `.claude` 或 `.agents` 的目录（App 里由调用方传）。它会打印重复 id —— 必须是 `none`。

★ **改了计数规则就要独立对照一次**：另写一个不共用代码的脚本（Python 全量 `json.loads` 每一行、同样的规则），和探针的每类前 20 **逐个比，数字必须完全相等**，不是「差不多」。2026-09-24 的对照结果：前 10 名完全一致，skill 共 79 次、agent 共 589 次（已排除被拒的 18 次）。对不上时先怀疑预筛关键字漏了某种写法，再怀疑解析。

## 已知限制

· **Codex 插件 skill 不收**：插件在 `~/.codex/plugins/cache/<mkt>/<plugin>/<ver>/`，按 `~/.codex/config.toml` 的 enabled 过滤、同插件多版本只取一个 —— 但 Codex 对插件 skill 的命名前缀未知，收进来也对不上使用记录，所以跳过  
· **gamedev 插件前缀未验证**：它没有 `plugin.json`，前缀退回插件名；这个前缀和使用记录里的名字对不对得上，没核对过：未验证  
· 同名的项目 skill 副本永远 0 次（见「次数挂到哪一条」）  
· Claude 没有等到 `tool_result` 的 agent 调用算作使用 —— 被杀掉的会话里那次启动其实可能被拒过  
· 目录里的内置 skill / agent 名单是手写死的，Claude Code 新增内置项要来改 `builtinClaudeSkills` / `builtinClaudeAgents`，否则它们显示为 `.missing`

## 界面（`SkillsPane.swift`）

· 主窗口第 4 个 tab「技能 / Skills」（⌘4，设置挪到 ⌘5），`design/skills-agents-tab.html` 方案 2：排行榜式列表，每行背后一条蓝条，长度 = 次数 ÷ 当前可见列表里的最大次数；按次数排序时带名次，0 次的行半透明  
· 分段（Skills / Agents）、筛选胶囊（全部 / Claude / Codex）、排序按钮都在滚动区**外面**，列表滚动时它们不动 —— 这是用户点名要的，别把它们挪进 `listStack`  
· 项目根 = `ProjectHistory.all()` 的路径；每次切进 tab 调一次 `SkillCatalog.load`（`loading` 防重入），演示模式下直接用 `Demo.catalog()`，不读任何真文件  
· 列表只在加载完成或用户操作（切分段 / 筛选 / 排序 / 展开）时重建，**不许挂定时器刷新**：每次插入控件 AppKit 都会登记一份不释放的依赖（见 design-system.md 的 T318 那段）  
· 展开的详情：简介 · 使用次数与最近时间 · 来源 · 模型（只有 agent 有）· 位置，以及「在 Finder 中显示 / 打开文件 / 复制名字」三个按钮；没有文件的内置 / 已删除项不给按钮  
· 看效果：`./tools/skills-preview.sh`（真实目录 + 演示数据 × 两个主题 × 深浅色 × 384 / 476 两个宽度，出 PNG 到 `/tmp/spectix-skills`）

## 零联网

整块只读本地文件（`FileManager` / `FileHandle` / `stat`）、写一个本地缓存文件，不 spawn 任何进程。两个文件都在根目录、被 `build.sh` 的 `*.swift` 编进 App，所以受源码网络 API gate 管 —— 这里出现 `URLSession` 一类调用会直接编译失败。见 CLAUDE.md「App 二进制不联网」。
