# 快捷动作：右下角扳手 → 一点就跑脚本 / skill

底栏最右边那颗 🔧（菜单栏弹窗和主窗口各一颗），点开是一块抽屉，三列方块，每块绑一个动作，最后一格「＋」添加。设计稿 `design/quick-actions.html` 方案 2（2026-10-21 用户选定，同时当面破了功能冻结）。实现全在 `QuickActions.swift`。

## 动作存在哪：`~/.claude/spectix/actions.json`

一个纯 JSON 数组。**这份文件就是接口** —— 用户说「帮我加个 SpectiX 按钮」时，任何 Claude 会话直接改这个文件即可，不需要 MCP。App 每次打开抽屉都会 stat 一次，文件变了就重读。

**连接 AI（MCP，2026-10-27 用户要求，功能冻结期当面破例）**：抽屉首页标题下一行「连接 AI」，Claude Code / Codex / Cursor 各一个按钮（只列这台电脑装了的）。连上后在 AI 里说「给 SpectiX 加个按钮…」，AI 调 `add_quick_action` 等 4 个工具（list / add / update / delete，`QuickActionsMCP.swift`）直接写 `actions.json`，抽屉开着时 3 秒内刷出来。

- **服务端就是 SpectiX 自己的二进制加 `--mcp`**（`main.swift` 入口第一行判断，不建 NSApplication）。不另打一个可执行文件，就不用第二份签名 / 公证 / 安装器改动。代价：dev 机上 `pkill -x SpectiX` 会顺带杀掉 AI 那边正在跑的 MCP 进程，下一个会话会自动重起
- **不联网**：MCP 走 stdin/stdout，没有 socket，build.sh 两道 gate 照过
- **注册方式**（`MCPClient.connect`）：Claude Code 走 `claude mcp add --scope user spectix -- <二进制> --mcp`（它自己时刻在改 `~/.claude.json`，手改会被覆盖）；Codex 直接改 `~/.codex/config.toml` 的 `[mcp_servers.spectix]` 表（`codex` 常装在 nvm 下，GUI 拿不到那个 PATH），写回时保留原文件权限（它是 0600）；Cursor 改 `~/.cursor/mcp.json` 的 `mcpServers.spectix`。注册的是**当前在跑的那个 App** 的路径 —— dev 版注册的指向 dev 产物，换正式版要重新点一次
- **「已连接」的意思**：MCP 进程是 AI 每个会话临时起的，没有常驻连线。绿点 = 配置里有 spectix；提示行的「N 分钟前用过」来自 `~/.claude/spectix/mcp-seen.json`（服务端收到 initialize 时按 `clientInfo.name` 记时间）。实测 Claude Code 报的名字是 `claude-code`（2026-10-27）；Codex / Cursor 的名字没有文档，按子串 codex / cursor 宽松匹配。刚连上还没开新会话时显示「新开一个会话后生效」
- **上下文开销**：Claude Code 默认把 MCP 工具定义延迟加载，会话开头只多 4 个工具名
- **不给 AI 运行按钮的工具**：会绕过「运行前先问我」，也超出「帮我建按钮」的需求
- 实测（2026-10-27）：`claude -p` 用工具加了一个「看磁盘」按钮，actions.json 多出一条、mcp-seen 记到 `claude-code`；Codex 连上后 `codex mcp list` 认得、断开后 config.toml 与原文件逐字节相同

**装了安装包的用户怎么让 AI 加**（他们没有这份文档）：「添加」页顶部「让 AI 帮你建」→「复制给 AI」把 `QuickActionStore.aiPrompt` 放进剪贴板 —— 一段自带文件路径、字段表、例子的话，结尾留着让用户写需求。贴给任何能改文件的 AI（Claude Code / Codex / Cursor）就能直接改好；只能聊天的 AI 会回一段 JSON，复制后点「粘贴 JSON」（`QuickActionStore.parse`：容忍 JSON 前后的说明文字和单元素数组）填进表单，用户检查后保存。粘贴来的 `id` 撞了已有按钮会自动加后缀，免得悄悄覆盖。「复制给 AI」现在是兜底：连得上 MCP 的 AI 走下面「连接 AI」一节。2026-10-22 实测：`claude -p` 拿这段话回的 JSON 一次就被 `parse` 读进来。改字段时这段话要跟着改。

```json
[
  {
    "id": "g915",
    "emoji": "🎹",
    "name": "清理 G915 配对",
    "kind": "script",
    "body": "blueutil --unpair \"$(blueutil --paired | grep -i G915 | grep -oE '([0-9a-f]{2}-){5}[0-9a-f]{2}')\""
  },
  { "emoji": "☀️", "name": "每日早报", "kind": "skill", "body": "/morning", "cwd": "~/Projects/TaskBeacon" },
  { "name": "整理下载", "kind": "prompt", "body": "把 ~/Downloads 里超过 30 天的文件按类型归档", "inTerminal": true }
]
```

| 字段 | 必填 | 含义 |
|---|---|---|
| `name` | ✅ | 方块上的名字（三列，起短点） |
| `kind` | ✅ | `script`（zsh 跑 body）/ `skill`（`claude -p "/xxx 参数"`，body 不带 `/` 会自动补；空格后面的是参数）/ `prompt`（`claude -p "<body>"`） |
| `body` | ✅ | 命令 / skill 名 / 给 Claude 的话 |
| `id` | | 稳定标识；不填就用 `name` 当标识（改名 = 新动作） |
| `emoji` | | 方块图标；不填就没有图标，方块只显示名字。编辑页里点「图标」从表情面板选，面板里「不要图标」清掉 |
| `cwd` | | 在哪个文件夹跑，支持 `~`；**不填 = SpectiX 自己的文件夹 `~/.claude/spectix/actions/workspace`**（跑出来的文件都留在这，卸载时随 `~/.claude/spectix` 一起删）。skill 读的是这个目录的 CLAUDE.md / `.claude/skills` |
| `inTerminal` | | `true` = 开 Terminal 新窗口跑（交互式 `claude "<prompt>"`，确认框在那个窗口里回答）；默认后台 |
| `confirm` | | `true` = 运行前弹一次确认 |

**文件写坏了**（JSON 解析失败）抽屉顶部会出一行橙字，方块保持上次读到的那份，不会清空。

## 怎么跑

- **★ 默认不在主目录跑**（2026-10-22 实测）：以前不填 `cwd` 就 `cd ~`，试跑一个 skill，`claude` 十几秒内连弹 8 个 macOS 权限框（下载 / 文稿 / 桌面 / 音乐资料库 / 其他 App 数据 / 3 次网盘文件夹）—— Claude 启动时会扫一遍所在文件夹，而 `~` 下面全是受保护目录。TCC 记录在 `~/Library/Application Support/com.apple.TCC/TCC.db`，`client` 是 `~/.local/share/claude/versions/<版本>`（spawn 时 disclaim 了，所以账记在 claude 头上，不在 SpectiX 头上）。现在不填就用 `QuickActionRunner.workspace`；编辑页里手填 `~` 会出橙色提示，给 AI 的那段话也写了别填 `~`。

- **后台**：`/bin/zsh -lc`，先补 PATH（`~/.local/bin` `/opt/homebrew/bin` `/usr/local/bin`，GUI App 不继承 shell PATH）再 `cd`。skill / prompt 带 `--permission-mode acceptEdits` —— 后台没人点「允许」，不带就会卡死在确认上。输出写 `~/.claude/spectix/actions/<id>.log`，结束后读最后 64 KB 进内存，弹 toast（成功 `done` 绿、失败 `needs` 红），点 toast 打开结果窗口。
- **Terminal**：写一个 `<id>.command` 文件再 `open -a Terminal`。**不用 AppleScript** —— 那条路要 Automation 授权，被拒时静默失败（docs/permissions.md）。
- spawn 一律 disclaim TCC 责任（docs/permissions.md：子进程碰受保护目录的弹窗不能记到 SpectiX 头上），且放进独立进程组，右键「停止」是 `kill(-pid)` 整组杀。

## 不联网红线

不受影响：跑的是 `claude` / 用户脚本，都是 App spawn 出去的进程，二进制本身不开 socket。

## 界面状态

- 扳手角上的点：跑着 = 蓝点呼吸（模型值停在 0.45、相位锚 `Motion.epoch`，见 design-system.md 循环动效两条铁律）；跑完 = 绿 / 红，**下次打开抽屉才清掉**。
- 方块（`design/quick-actions.html` 第二轮布局 B，2026-10-22 用户选定）：**点方块 = 打开详情页**。状态只占两个位置，互不抢地方：右上角一处（静止写类型 `BASH` / `AI·SKILL` / `AI` → 跑着写计时 `0:12` → 跑完写 `✓ 3m ago` / `✗ 失败` / `已停止`）+ 底边 3pt 色带（跑着蓝色流动、成功绿、失败红 + 红框、停止灰）。鼠标移上去，名字那一行换成「▶ 运行 | 详情」两颗按钮（跑着变「■ 停止」）。以前把 ▶、计时、结果点、类型塞在四个角，窄抽屉里互相压住，所以改掉。「已停止」和「失败」分开（`Result.stopped`）—— 停止是你自己点的，不该标红。右键菜单 运行/停止 · 看上次输出 · 编辑 · 删除。
- **添加 / 编辑不弹窗，是抽屉里的一页**（`QuickActionForm`，2026-10-27 用户要求）：点「＋」、详情页的「编辑」、右键「编辑…」都在抽屉里翻到这一页，保存后翻到这个动作的详情页，取消回到原处。抽屉在宿主里有 `top >= 顶边 + 8` 的约束，表单比空间高时在抽屉里滚动。弹窗关掉再打开时，填到一半的表单还在（`prepareForShow` 只在表单没开时才回方块页）。弹窗的 ↑/↓/⏎ 键盘监听在焦点落在输入框时放行（`main.swift` 的 `popoverKeyMonitor`），否则命令框里打不了回车。
- 类型选 Skill 时，**不是手写**，是从已装 skill 里选（`SkillCatalog.load`，和「技能」tab 同一份数据，只取 Claude 的 skill，按用过次数排）。上面一个搜索框（按名字和说明过滤，↑/↓ 在列表里移动、⏎ 选中），下面一个列表，每行两行：`名字  来源 · 用过 N 次` + 说明。**显示的名字不带 `/`**，存进 body 时才加。选了项目 skill，目录自动填成项目根（项目 skill 只在那个目录下找得到）；之后换成全局 skill 时，只清掉自动填的目录，不动你手填的。列表下面一格写「跟在后面的话」（`today`、`work`、存到哪），保存成 body 里 skill 名后面那段 —— 不另加字段，`claude -p "/x today"` 本来就这么传参。actions.json 里写了一个这台电脑没装的 skill，会在列表顶部单独列出并标「没找到」。
- **子 skill 也列出来**（2026-10-27 用户要求）：总入口 skill 文件夹里再往下一层的 `<子名>/SKILL.md`（如 `notes/daily-report`）排在它的总入口下面，标「在 notes 里」。Claude Code 只认第一层，`/daily-report` 跑不起来，所以选子 skill 存成 `/notes daily-report <那句话>`；读回来时 body 第二个词正好是这个总入口的子 skill 名，就认成选中它。只在表单里扫（`QuickActionForm.subSkills`），不进 `SkillCatalog`，「技能」tab 的计数不受影响；也不会进 Claude 每轮的 skill 清单。
- 详情页（抽屉内翻页，「‹ 快捷动作」返回）：类型（Bash 脚本 · 不经过 AI / AI · Claude 跑 skill …）· 状态行（还没跑过 / 运行中 · 计时 / 上次成功·几分钟前·用时 / 上次失败·退出码 / 终端模式只记「几分钟前在终端打开」）· **跑什么**（`commandPreview`：真正会执行的那条命令，skill 显示成 `claude -p '/x' --permission-mode acceptEdits`）· 目录和跑法 · 输出（运行中每秒读一次 log 尾巴，显示最后 8 行）· 运行/停止 + 完整输出。计时和实时输出靠 runner 的 `didTick`（有任务在跑时每秒一次，跑完就停），和 `didChange` 分开是因为扳手收到 `didChange` 会重挂呼吸动画。
- 弹窗每次重新弹出时抽屉收起；主窗口的抽屉保持开关状态。

## 没做的（有意砍掉）

- **每个动作的全局快捷键**：`HotKey.swift` 的绑定是固定枚举（`HotKeyAction`），动态动作要重构那一层，先不做。
- 演示模式有 8 个假动作（`Demo.actionsPath`，读路径换到 `$TMPDIR`），点了只跑 `sleep 4; echo <假输出>`，给推广截图用（`.claude/skills/promote-feature`）。
