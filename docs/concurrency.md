# 多任务共用工作区

本项目当前是 non-worktree 模式：多个 Codex Terminal 会直接共用同一份文件。`todo.py` 只能防止两个会话认领同一个任务，不能防止两个不同任务改到同一文件。

## 高频共享文件

| 文件 | 常见改动 |
|---|---|
| `Theme.swift` / `ThemeSpec.swift` | 样式、配色、圆角 |
| `Components.swift` | 共享控件 |
| `main.swift` | AppController、菜单栏、toast、跳转 |
| `SettingsWindow.swift` | 设置项 |
| `MainWindow.swift` | 行与表头 |
| `FocusRing.swift` | 高亮圈、常驻标签、overlay |

改这些文件前读 `task/.taskbeacon/todos.json` 的 WIP 记录并核对文件范围。另一个任务正在写同一文件 → 停止写入，改用快照做只读分析或等对方收尾。

Swift 编译报 `input file ... was modified during the build` 表示编译期间有另一个任务改了文件，不等于代码已被覆盖。等目标文件修改时间稳定后再构建，不在前台无限重试。
