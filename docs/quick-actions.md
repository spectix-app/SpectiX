# 快捷动作：右下角扳手 → 一点就跑脚本 / skill

底栏最右边那颗 🔧（菜单栏弹窗和主窗口各一颗），点开是一块抽屉，三列方块，每块绑一个动作，最后一格「＋」添加。设计稿 `design/quick-actions.html` 方案 2（2026-10-21 用户选定，同时当面破了功能冻结）。实现全在 `QuickActions.swift`。

## 动作存在哪：`~/.claude/spectix/actions.json`

一个纯 JSON 数组。**这份文件就是接口** —— 用户说「帮我加个 SpectiX 按钮」时，任何 Claude 会话直接改这个文件即可，不需要 MCP。App 每次打开抽屉都会 stat 一次，文件变了就重读。

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
| `kind` | ✅ | `script`（zsh 跑 body）/ `skill`（`claude -p "/xxx"`，body 不带 `/` 会自动补）/ `prompt`（`claude -p "<body>"`） |
| `body` | ✅ | 命令 / skill 名 / 给 Claude 的话 |
| `id` | | 稳定标识；不填就用 `name` 当标识（改名 = 新动作） |
| `emoji` | | 方块图标，默认 ⚡️ |
| `cwd` | | 在哪个目录跑，支持 `~`；默认 home。skill 读的是这个目录的 CLAUDE.md / `.claude/skills` |
| `inTerminal` | | `true` = 开 Terminal 新窗口跑（交互式 `claude "<prompt>"`，确认框在那个窗口里回答）；默认后台 |
| `confirm` | | `true` = 运行前弹一次确认 |

**文件写坏了**（JSON 解析失败）抽屉顶部会出一行橙字，方块保持上次读到的那份，不会清空。

## 怎么跑

- **后台**：`/bin/zsh -lc`，先补 PATH（`~/.local/bin` `/opt/homebrew/bin` `/usr/local/bin`，GUI App 不继承 shell PATH）再 `cd`。skill / prompt 带 `--permission-mode acceptEdits` —— 后台没人点「允许」，不带就会卡死在确认上。输出写 `~/.claude/spectix/actions/<id>.log`，结束后读最后 64 KB 进内存，弹 toast（成功 `done` 绿、失败 `needs` 红），点 toast 打开结果窗口。
- **Terminal**：写一个 `<id>.command` 文件再 `open -a Terminal`。**不用 AppleScript** —— 那条路要 Automation 授权，被拒时静默失败（docs/permissions.md）。
- spawn 一律 disclaim TCC 责任（docs/permissions.md：子进程碰受保护目录的弹窗不能记到 SpectiX 头上），且放进独立进程组，右键「停止」是 `kill(-pid)` 整组杀。

## 不联网红线

不受影响：跑的是 `claude` / 用户脚本，都是 App spawn 出去的进程，二进制本身不开 socket。

## 界面状态

- 扳手角上的点：跑着 = 蓝点呼吸（模型值停在 0.45、相位锚 `Motion.epoch`，见 design-system.md 循环动效两条铁律）；跑完 = 绿 / 红，**下次打开抽屉才清掉**。
- 方块：跑着 = 蓝底蓝框、emoji 变淡；右键菜单 运行/停止 · 看上次输出 · 编辑 · 删除。
- 弹窗每次重新弹出时抽屉收起；主窗口的抽屉保持开关状态。

## 没做的（有意砍掉）

- **每个动作的全局快捷键**：`HotKey.swift` 的绑定是固定枚举（`HotKeyAction`），动态动作要重构那一层，先不做。
- 演示模式不造假动作。
