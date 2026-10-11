# 设计统一约定（改任何样式前必读）

**所有 UI 面共用同一套设计语言，改一处样式 = 先盘点其它面，和用户确认要不要一起改，再动手。** 涉及的面：

| 面 | 位置 | 共享组件 |
|---|---|---|
| 主窗口 | `MainWindow.swift`（HeaderStatsView + SessionListView + 4 pane）+ `BottomTabBar.swift`（底部导航条） | GroupCard / CountPill / CapsuleLabel / StatusDot / TabItemButton |
| menu bar popover | `MenuPopover.swift`（同一个 SessionListView + compact HeaderStatsView + 同构 flat 底栏） | 同上，改列表自动同步；底栏按钮 = TabItemButton |
| notification toast | `main.swift`（ToastSurfaceView） | CapsuleLabel / StatusDot / Theme 色值 |
| 统计 tab | `StatsWindow.swift`（`StatsPane`，主窗口 tab 2） | GlassCard |
| 最近项目 tab | `RecentProjectsWindow.swift`（`RecentProjectsPane`，主窗口 tab 3） | GlassCard |
| 技能 tab | `SkillsPane.swift`（主窗口 tab 4，排行榜式列表，`design/skills-agents-tab.html` 方案 2） | TabItemButton（分段）/ ChipButton |
| 设置 tab | `SettingsWindow.swift`（`SettingsPane`，主窗口 tab 5） | GlassCard |

> **tab 顺序的单一来源是 `MainTab`**（`MainWindow.swift`）：`sessions, stats, recent, skills, settings` —— 即 **会话 / 统计 / 最近项目 / 技能 / 设置**，`panes` 数组按 `rawValue` 索引，`BottomTabBar` 的五个按钮同序并各自绑 ⌘1–⌘5。上表的「tab N」是 1-based 的人读序号。**统计在最近项目前面**（早期设计稿里两者相反，别照旧稿改）。

已定的统一样式基线（导航条 = `design/main-window-merge-alternatives.html` 的 **scheme 6 底部 flat bar**；卡片/header 沿用 `design/main-window-tabs.html` 的 ghdr 设计）：
- **无 specular sheen**：所有卡片/toast 顶部不加白色反光线（`Theme.sheen` 已删，别加回来）
- **状态计数 = CountPill**：一颗玻璃胶囊装全部 `●n` 段，不用分离的彩色小胶囊
- **来源徽章 = 渐变字标方块**（`LogoBadge`），不用真实 App 图标。全部配方在 `LogoBadge.recipe(_:)`（`MainWindow.swift`）：**VSCode → 蓝 "VS" / Cursor → 紫 "CU" / Windsurf → 青 "WS"**（三个 fork 各自一个色，`CU`/`WS` 的色相刻意避开 VS 蓝、也避开状态色板）、终端 → `terminal` 符号、Claude 桌面版 → 铜橙 asterisk，另有按状态色 / 自定义 emoji / 自定义图片三种动态配方
- 表面材质统一走 token：`Theme.cardFill` + `Theme.hairline` 描边（**具体是玻璃还是不透明由主题定**，见下方 token 节的 `Theme.material` / `Theme.surfaceStyle`）

## 设计 token：两层，分界线是「主题能不能动它」（改任何尺寸/圆角/字号前必读）

所有 token 都在 `Theme.swift`，按**能否被主题覆盖**分两层，写法上一眼可辨：

| 层 | 写法 | 含义 |
|---|---|---|
| **常量层** | `static let` | 主题**不许动**。这些编码的是**信息密度**，是多轮实测调出来的；换肤不该有权推翻它 |
| **主题层** | `static var`（读 `Theme.current.*`） | 主题可变，见 `ThemeSpec.swift`（能变什么）/ `ThemeRegistry.swift`（怎么加一个） |

**常量层（`static let`，主题动不了）**：

| token | 值 | 用途 |
|---|---|---|
| `pad` | 18 | 窗口边距 |
| `gap` | 10 | 兄弟元素之间 |
| `inset` | 14 | 卡片内部 |
| `cardCellInset` | 18 | 卡片缩在自己 cell 里的距离 —— **同时决定它的阴影有多少空间可以淡出**，见下方注 |
| `rowHeight` | 64 | 会话行高 |
| `agentRowHeight` | 46 | 展开的 agent sublist 节点高 |
| `pill` | 999 | 胶囊圆角 —— 是个常量，不是主题选择 |

> **`cardCellInset` 的坑（改这个值前必读）**：scroll view 的 clip rect 会在自己边缘**裁掉一切**，而被裁掉的软阴影不会渐隐 —— 它是**直接切成一条直线**。所以窗口那 18pt 的侧边距是花在 **cell 内部**而不是列表外部：列表自身缩进 `pad - cardCellInset`（= 0），每个 cell 再把卡片缩进这个值。卡片落点和以前完全一样，但它的阴影从只有 6pt 可淡出变成有 18pt。**clay 主题的阴影 lobe 尺寸就是照着这个预算定的**（见 `ThemeClay.swift`），动这个值会连带把 clay 的阴影撑破或压扁。
>
> 由此定下**阴影预算硬约束**（写任何主题的阴影配方前必读）：**`|offset| + 2×blur ≤ 18`**，且 **hover 浮起只准加深浓度、不准放大几何** —— 放大必然超预算被裁成直角。另有 `NSView.letShadowsEscape()` 用来解除 table cell 那一层的裁剪；滚动容器那一层按职责必须裁，只能靠这个预算躲。

**主题层（`static var`）**：圆角 `card` / `group` / `chip` / `windowRadius` / `popoverRadius`（都读 `current.metrics`）；全部表面色与 hairline（`current.palette`）；材质与样式枚举 `Theme.surfaceStyle` / `Theme.material`（药丸样式是 **`Status.pillStyle`**，挂在 `Status` 上不是 `Theme` 上）；阴影 `Theme.shadow(in:)`；字重 `groupTitleWeight` / `sectionTitleWeight`（`current.weights`）。

**字体**：三个构造器，**字号一律不可主题化**（字号 = 密度），只有**字重**可以：

- `Theme.font(size, weight)` — 系统字，正文默认
- `Theme.rounded(size, weight)` — 圆体（`.rounded` design），标题/数字用
- `Theme.roundedMono(size, weight)` — 圆体 + **等宽数字**（tabular figures）。**凡是会跳动的数字必须用它**：`12m`→`13m`、`6.1k`→`6.2k` 换字符时不能推挤邻居；配合 usage 行的固定 tab stop，让各行的 `⏱ 时长` / `◆ token` 纵向对齐

> **为什么改主题不用改调用点**：`Theme.cardFill`、`Theme.card`、`Status.accent(_:)` 这些访问器**名字和形状都没变**，只是内部改成读 `Theme.current` —— 全 App 约 390 处读取点因此一行都不用动。加主题只有两步：新建 `ThemeFoo.swift`（**必须放项目根目录**，`build.sh` 只编译根目录的 `*.swift`，放子目录会静默不参与构建）暴露 `static let spec`，然后把它加进 `ThemeRegistry.all`。只有当新主题需要一种现有 `ThemeMaterial` / `SurfaceStyle` / `PillStyle` 都表达不了的观感时，才需要加枚举 case 并动那几个 switch。当前在册主题：`ThemeDefault`、`ThemeClay`。
>
> ⚠️ 换主题后**必须整体重建 UI**：颜色和圆角在建 view 时就烘进 layer 了，已存在的 view 不会自己变。走 `AppSettings.themeID`（它发 `themeDidChange` 驱动重建），别直接调 `Theme.apply(_:)`。

## 回顾页四个区块（改 `SectionBlock` 或回顾页分区前读）

回顾页从上到下四块：效能 · 成绩 · 帮了你什么 · 消耗（`design/insights-sections-3-proposals.html` 方案 13，2026-10-10 用户定）。每块是一个 `SectionBlock`（`ImpactView.swift`）：带本区颜色的淡底 + 同色描边，标题栏铺更深一档的同色，左侧一根发光竖条，标题后跟一句「这块是干什么的」，右端可选一颗小结药丸和折叠 ▲。**▲ 只收效能区的曲线**，成绩条永远在。

## 霓虹面在两种外观下都是暗的（改效能面板任何颜色前必读）

回顾页的「效能」区块（`SectionBlock(bed: true)`，里面装折叠条 `FoldBar` 或展开后的分数 + 三条曲线）**自己铺一层暗底**
（`NeonInk.bed(in:)`），不跟随窗口：浅色外观下是中灰蓝 `bed`，深色外观下是墨蓝 `darkBed`。
以前两种外观共用中灰蓝，深色窗口里它比周围亮一大截、看着发白发灰（2026-10-10 用户报），
深色那块是从四个候选的真实渲染里挑的（`design/impact-dark-bed.html`）。

**Why**：指标色（七个，见 `Theme.swift` 的 `Metric.accent`）是霓虹色 —— 它们的可读性来自「比背后亮多少」。浅色外观下背后没有暗，
掌控的黄绿和省时的薄荷绿在白底上直接消失（2026-09-04 用户实测截图报的就是这个）。发光需要
有地方可发。

**由此连带的一条**（最容易漏）：卡片在两种外观下都是暗的，所以**画在它上面的任何东西都不能用
系统语义色** —— `.labelColor` 在浅色外观下翻成黑色，正好埋进自己铺的暗底里。卡内文字一律用
`NeonInk.primary / .secondary / .faint`，网格线用 `NeonInk.rule`，它们在两种外观下都是浅色。

**边界**：只有 `bed: true` 的 `SectionBlock` 子树受这条约束。其余三个区块（成绩 / 帮了你什么 / 消耗）是叠在窗口上的淡色块，标题在浅色外观下退回 `.labelColor`，强调色只留在竖条和底色里。指标行（`MetricRow` / `NeonBar`）和详情卡
（`DetailCard`）**坐在窗口上、不在卡上**，照常跟随系统色；`NeonBar` 解决同一个问题的方式相反 ——
它没法给自己铺底，所以浅色下**用描边替代发光**。两张不同的床，两套配方，别互相搬。

**改完必须两种外观都看一眼**：

```bash
./tools/panel-preview.sh      # 每个时间范围 × {dark, light} × {静态, hover} 出图
```

浅色回归就是因为之前只渲染了当前系统外观那一种才漏掉的。

## 循环动效的两条铁律（加/改任何 perpetual 动画前必读）

**前提**：列表每次刷新走 `SessionListView.reload()` → renderKey 变了就 `tableView.reloadData()`，而 key 里含 `fmtDur(elapsed)` 和 `step`——**⏱ 秒数跳动、工具步骤变化都会全表重建**。reloadData 把 row view 移出 window，CoreAnimation **连带剥离该 layer 上的所有动画**，插入后再重新添加。所以任何无限循环动画都必须扛住「每秒被剥离重加一次」。两条缺一不可：

1. **相位锚定**：`beginTime = Motion.epoch`（`Components.swift` 顶部），不用 `CACurrentMediaTime()`。否则每次重加都从 frame 0 重启，指示灯和刷新同频闪。锚定后重建的 loop 直接跳回相位中间（同类 loop 还会齐步走）。
2. **模型值泊在动画的「最不显眼端」**：动画属性的**模型值**决定了「剥离后、重加前」那一帧画什么。默认值往往是最亮的（`opacity` 默认 1.0），于是每次刷新插入一个**亮度尖峰**——`beginTime` 锚定救不了这一帧（它保的是相位，不是模型值）。

   已按此办的地方：typing 迷你点 `mini.opacity = 0.45`（= 波谷，动画 `[0.45, 1, 0.45]`）、声纳环 `sonar.opacity = 0`（"model stays invisible between emissions"）、AgentBadge 光晕 `pulse.opacity = 0`、**agent 轴线节点 `dot.opacity = blinkDim(0.35)` while running**（T78：唯独它漏了这条，模型值停在默认 1.0，于是「每次更新时间或跑 Bash，点就闪一下」；`AgentAxisView.configure`）。

> 判据：**写下 `repeatCount = .infinity` 时，同时回答两个问题**——beginTime 锚 epoch 了吗？这个属性的模型值是不是动画里最暗/最不可见的那端？两个都答 yes 才算写完。
> 另注：`StatusDot.buildBreath`（compact 徽章点）的 `core.opacity` 仍是 1.0 而动画摆到 0.45，理论上有同类尖峰，但它每次由 `CountPill` 整个重建、且尺寸只有 7pt，暂未观察到可见闪烁——真要动 CountPill 时一并按第 2 条处理。

## 状态色单一源 + 全局 override（改任何状态色前必读）

**每个会话状态只有一个颜色源：`Status.accent(_:)`（`Theme.swift`）。** 所有状态色都从它派生，禁止在别处硬编码状态色：

> **第七个状态「等待」（`await`，T312，2026-09-10）**：青 #00BFA5 / 深 #008074。色相刻意卡在完成绿（151°）和运行蓝（199°）之间——它就是两者的中间态（后台命令在跑、AI 会自己续、期间你可插话）。**它是全 App 唯一的空心圆点**（`StatusDot.buildAwait`）：实心 = 有人在忙或有事轮到你，空心 = 都没有，只是在等；缺口环 4s 一转说「没结束、也不急」。compact 小点（菜单栏胶囊、计数药丸）退化成不转的闭合空心圈。**药丸和其它状态一样实心**（2026-09-12 用户拍板推翻初版的描边药丸——一行里只有圆点该承担「空心 = 在等」这层意思，药丸跟着空一次，整行就散了）：走 `Status.pillStyle` 的通用路径，玻璃主题实心青底白字、陶土主题浅底深字。选型过程与另外 19 个落选方案在 `design/waiting-status-10-proposals.html`。别给第二个状态用空心圆点——这处形状差异是它的全部识别度。

- `Status.tint(_:)` = `accent × 0.18`（药丸浅底），自动跟随。
- `Status.fill(_:)` = 药丸上那一档色。默认色是**手调常量**（每个都实测过白字 ≥4.5:1，比值写在 `ThemeDefault.swift` 各行注释里，改值必须重算）；手调常量在 `.solidWhiteText` 主题下**也过一遍** `deepenedForWhiteText()` 兜底——达标值下是 no-op，值调错时只会略深一档而不会出不可读的白字；`.tintedDeepText` 主题（clay）跳过，因为它的 fill 是**浅底上的文字色**、暗色模式下故意偏亮。
- ⚠️ **没有手调 deep 档的色（用户 override、别的主题的配色）必须按当前主题的 `pillStyle` 派生，方向相反**：`.solidWhiteText` 下这个色当**背景**、白字压上面 → 走 `deepenedForWhiteText()` 往**深**推；`.tintedDeepText` 下它当**文字**、压在 `Status.pillBed` 上 → 走 `contrastedForTintedBed(_:)` **背离床**推（浅色模式变深、暗色模式变亮）。同一个 hex 两个主题要求相反，无条件加深就是 T113 的 bug —— 陶土 + 暗色下最差只有 **1.31:1**，修好后 4.50:1。派生要对着 `Status.pillBed(_:mix:)`（药丸真正画出来的那个床）算，两边各算各的就等于没验证。
- 消费点（都在 redraw 时读 accent/tint/fill，勿缓存硬编码）：列表行 / header wash / StatusDot / CountPill / AgentBadge / 菜单栏胶囊（`MenuCapsule.swift`，`main.swift updateButton` 只负责算出计数）/ toast / 跳转高亮圈 + caption。
- ⚠️ **菜单栏胶囊的床是半透明玻璃底**（暗 `white α0.14` / 亮 `black α0.06`，跟菜单栏自身外观走），点和数字用 `Status.accent`。T167 曾把它改成不透明纯白 + `Status.fill(...).contrastedForTintedBed(白)`（理由是菜单栏半透明、花壁纸会把满饱和 accent 冲淡），2026-08-09 用户明确要回玻璃底，那套白床派生随之撤掉。**这两块必须成对改**：白床专调的深色 `fill` 放到暗色菜单栏的半透明底上是不可读的，反之亦然；呼吸下限同理（玻璃底 0.5，白床要 0.75）。

- ⚠️ **菜单栏胶囊里不许每帧写 status button 的属性**（2026-09-15 实测）。它以前是每 0.1 秒渲一张 `NSImage` 塞给 `statusItem.button.image`，好让运行中的点呼吸；macOS 26 上**每次写 status button 的属性，AppKit 都会登记一对再也不释放的 KVO 依赖**——实测 `.image` +5.0 个对象、`.title` +4.0、`.imagePosition` +4.0、改宽度 +160，同样的写法换成普通 `NSButton` 一个都不漏（所以是 AppKit 的坑，flush 不掉）。10 Hz 下每天约 1 GB：一个跑了 22 小时的进程里 `NSKeyValueDependency` / `NSKeyValueDependencyContext` / `__NSMallocBlock__` / `__NSExactBlockVariable__` 各 125 万个。现在胶囊是**塞进 button 里的一个视图**（`MenuCapsule.swift`），呼吸交给 CALayer 自己跑，底图只在计数或配色真的变了时重画，button 的属性只在首次安装和宽度变化时写。**加任何跟着时间动的东西都别再回到「定时重画整张图」那条路**——编译得过、跑得动、测试全绿，只是几天后机器变慢。查法：`tools/menubar-leak-probe.sh`。

- ⚠️ **哪些 AppKit 写入会漏，别猜，用 `tools/appkit-write-leak-probe/main.swift` 量**（2026-09-15 实测，macOS 26.6.2，每项 2 万次）。直觉在这件事上是错的 —— 一条每秒写 27 次透明度的路径实测**一个对象都不漏**，而看着人畜无害的「把窗口提到上层」每次漏 18 个：

  | 写什么 | 每次净漏 |
  |---|---|
  | 状态栏按钮 `.image` | +5.02 |
  | 状态栏按钮 `.alphaValue` | 0 |
  | `NSPanel` / `NSButton` `.alphaValue` | 0 |
  | `NSPanel .ignoresMouseEvents` | 0 |
  | `NSView .needsDisplay` | 0 |
  | **`NSPanel .order(.above:)`** | **+18.05** |
  | **`NSPanel .contentView = 新视图`** | **+15.04** |

  还有一条量不进表里、但在真机上占比最大的：**每次新建控件并插进窗口**（`NSControl viewDidMoveToWindow` / `NSView _setSuperview:` / `NSTextFieldCell _refreshVisualProviderForStyle:` 这条链）AppKit 都会登记一个不释放的依赖对象，实测本 App 稳态约 **35 个/秒**。所以「列表重载时整批重建单元格」「高亮圈尺寸一变就重建 contentView」这类写法是有持续代价的 —— 已登记为 **T318**，别当成菜单栏那条的残留。
  查法：`tools/menubar-leak-probe.sh <秒数>` 挂到在跑的 App 上看总速率，`tools/appkit-write-leak-probe/main.swift` 判断某一种写法该不该上定时器。

**全局 override**：`AppSettings.userColor(for:)` / `setUserColor(_:for:)`（存 `ringColor-<status>` hex，键名沿用旧 ring 色以兼容存量）。`Status.accent` **先查 override 再回落默认**，所以用户改一个状态色 → 上述所有面一起变。setter 发 `didChange` → `main.refresh()` 全量重建列表/header/菜单栏 + `FocusRing` recolor always-on 圈。

**主题 ⊥ 配色（两个正交维度，T113）**：主题（`ThemeRegistry`）只管**材质**——阴影、描边、圆角、药丸形态；配色只管**六个状态色**。任意组合都合法（陶土材质 + 玻璃那套鲜亮色是正当选择），所以配色预设里**每个主题的自带色都作为一项列出**（由 `ThemeRegistry.all` 动态生成，加主题自动多一项）。代价：这些项解析成**固定 hex**，丢掉主题原有的 `themePick(dark:light:)` 明暗双值——与另外三套手写预设行为一致；要保留明暗自适应就选**「跟随主题」**（即不 override）。主题面板底部那行只是**陈述**当前配色 + 「更改」跳转，**不是冲突警告**（旧版琥珀警告条把正交维度渲染成冲突，会把用户劝回主题自带色，已删）。

- 改色 UI：设置「显示」段的**「状态颜色」卡片**（`SettingsWindow.makeStatusColorsCard`，scheme 8「自定义即微调」）。上半是两列预设网格 `ThemeCard`（行数由预设数派生，别写死）+ 一张全宽**「自定义」卡**：可点选（选中 = 蓝框 + `✓ 使用中` + 实时 6 色条），点开后**内部**收着 7 态胶囊（`StatusChip`，needs/working/checking/paused/await/done/idle，见 `AppSettings.statusColorStatuses`）+ 单状态预设色板手风琴（`⟲ 默认` 恢复）。改任意单色 → 自动归为「自定义」。它**独立于**「终端高亮」段的「各状态样式」卡片（后者只管 ring 样式 `ringStyleStatuses`，6 态无 checking）。
- **不纳入统一**（专用色，非会话状态色，别硬塞进 override）：LogoBadge 编辑器品牌渐变、Stats 图表调色板、caption 药丸的中性深灰底（只 accent 元素随色）、**agent 鸢尾紫**（`Theme.agentAccent`/`agentDeep` #7c8cff→#5a6bf5 —— 🤖 AgentBadge 渐变 + 展开的 agent sublist 的轴线/节点/chip/运行中 pill；它表达「有后台 agent」这个正交维度，故意区别于一切状态色。T49 起 AgentBadge 不再用 working 蓝）。
