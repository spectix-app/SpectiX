# header 来源标记与自定义图标

## header 来源标记

每个 header 前有来源徽章区分（按 `design/main-window-tabs.html` 的 ghdr 设计）：VSCode terminal 组 = **蓝渐变圆角方块 + 白色 "VS" 字标**，桌面版组 = **铜橙渐变 + 白色 asterisk**（`MainWindow.swift` `LogoBadge`，也是拖拽把手）。判定靠 `cwd == AppController.desktopCwd`。右侧计数是**一颗玻璃 pill 装全部状态桶**（`Components.swift` `CountPill`，●n ●n 同一胶囊），不再一个状态一颗。→ `MainWindow.swift` `HeaderCell`。

**一个项目组混了多种来源时选哪个徽章**：`ListModel.source(_:)` 定，优先级 `desktop` > 第一个 `editor != nil` 的行 > `terminal`。∴ 同一项目里 VSCode 集成终端 + 原生 Terminal.app 混着开 → 显示 VS 徽章。**编辑器 chat 面板（无 tty 的侧栏/tab 会话）不需要任何特判**：它的 `editor` 同样从宿主 bundle id 解析出来（宿主就是 Code），落进同一条 editor 分支，与同 cwd 的终端会话自然归进**同一个项目组、同一颗 VS 徽章**——这是期望行为，别为它加第二种徽章（**行**这一级另有一个只在空闲时出现的 ` · Chat` 后缀区分它，见 [`row-display.md`](row-display.md)——那是行的事，不是徽章的事）。会话本身的机制见 [`session-status.md`](session-status.md)「无 tty 会话」一节。
> ★ 判据是 `editor != nil` 而**不是** `terminalApp == nil`：不受支持的宿主（Warp / Ghostty / tmux…）两者都是 nil，用后者会把它们全扫进 editor 分支 = 「把每个未知宿主当 VSCode」那个已被 T131 删掉的假设。它们应当落到通用 terminal 徽章。

## 自定义 header 图标（emoji 选择器 + 上传图片）

右键 project header 的**徽章**（不是整行）→ 弹菜单 `编辑图标… / 上传图片… / 随机 emoji / 移除自定义`。「编辑图标」开一个 Notion 式 emoji 选择器（搜索 + 分类跳转条 + 分区网格 + 底部 随机/🖼 上传/移除）。设计稿：`design/emoji-icon-picker.html`。

**两种图标源，共用一个槽位**（`AppSettings.CustomIcon` 枚举 `.emoji` / `.image`）：设一个自动清另一个，「移除自定义」两者都清。所有读取点只 switch `AppSettings.customIcon(cwd:)`，映射成 `LogoBadge.Mode` 一律走 `LogoBadge.mode(for:)`（**加新图标源只改这一处**）。

| 源 | 存储 | 渲染 |
|---|---|---|
| emoji | `AppSettings.customIcons`（`[cwd → emoji]`，UserDefaults） | `Mode.custom(emoji)`：**纯 emoji 无背景色**，只叠一层中性淡底把 glyph 锚在槽位里 |
| 上传图片 | 归一化成 **128×128 PNG** 落 `~/.claude/spectix/icons/<uuid>.png`，UserDefaults 的 `customIconImages`（`[cwd → 文件名]`）只存文件名 | `Mode.image(文件名)`：**满铺** 26pt 方块 + 7pt 圆角裁切（`LogoBadge.photo`），像 app 图标 |

- 键控同 `hiddenCwds`（cwd）。写入发 `didChange` → 列表就地重绘徽章。`recentEmojis` 喂选择器的「最近」行。
- 徽章判定：`HeaderCell.badgeHit(_:)`（右键落点在 `logoBadge` padded bounds 内 → 图标菜单，否则原「隐藏项目」菜单）；`iconAnchor` 供面板锚点。
- ★ **图片不进 UserDefaults**（改这块前必读）：原图可能几 MB，plist 塞 Data 会被每次读反序列化拖垮。`AppSettings.importIconImage(from:)` 在入口就 aspect-fill 居中裁正方 + 缩到 128px 落盘（badge 只有 26pt，@3x 也够），只存文件名；`iconImage(_:)` 带内存缓存（徽章每轮 poll 都重绘，不能每次读盘）。换图 / 移除时删旧文件 + 失效缓存，别留垃圾。
- ★ **`LogoBadge.Mode` 只带文件名不带 NSImage**：Mode 是 `Equatable`，`configure` 靠 `newMode != mode` 短路重绘；塞 NSImage 既破坏这个短路又让每个 mode 拖着一张位图。
- ★ **选择器里的「🖼 上传」先关面板再开 NSOpenPanel**：面板靠 global mouse-down 自关（见下条），叠一个模态 open panel 上去，第一次点击就把它关了。上传走模态 `runModal()` 不走 sheet —— 徽章常在菜单栏 popover 里，没有值得 attach 的窗口。
- ★ 选择器**必须是独立浮动面板（`EmojiPickerPanel` NSPanel），不能用 NSPopover**（改这块前必读）：徽章常活在菜单栏 popover（`MenuPopover`，`.transient`）里，把子 popover 锚在 transient popover 内的视图上 → 两者抢焦点互相 dismiss（~0.7s 一闪即消的「闪退」bug）。面板按徽章的**屏幕坐标**（`editIconClicked` 里 `convertToScreen` 提前抓好）定位，不依赖锚点视图/父 popover 的生命周期。关闭靠 `.leftMouseDown/.rightMouseDown` 的 global+local 事件监听（点面板外即关）+ Esc（`cancelOperation`），**不用 resign-key**（会和父 popover 关闭的焦点变化竞态误关）。
- 选择器：`EmojiPicker.swift`（`EmojiCatalog` 目录带搜索关键词 + `EmojiIconPicker` NSViewController + `EmojiIconPicker.present(anchorScreenRect:...)` 建面板）。菜单/动作收在同文件的 **`ProjectIconMenu`**（`menu(cwd:anchor:)` 建菜单并**当场**抓 anchor 的屏幕矩形——动作触发时 header 所在的 popover 可能已经关了）。两个调用点各持一个实例（`NSMenuItem.target` 是弱引用，菜单活着时对象必须还在）。
- **最近项目（`RecentProjectsWindow.swift`）用同一个图标**：`ProjectRowView` 的图标位是个 28pt 槽，里面叠 Finder 文件夹图标 + `LogoBadge`，`refreshIcon()` 按 `AppSettings.customIcon(cwd:)` 二选一显示（槽固定尺寸，两者差 2pt 也不会推动旁边的名字/路径列）。右键**整行**都弹 `ProjectIconMenu`（header 那边限定在徽章上是因为行的其余部分另有「隐藏/置顶」菜单，这里没有竞争项）。`AppSettings.didChange` 时只 `refreshIcon()` 不重建行——重建会吞掉 hover 态。`LogoBadge.showsGripCursor = false` 关掉抓手光标（这里不是拖拽把手）。
- 跳转落点高亮圈的 caption 也画同一个徽章（`FocusRing.swift` `badgeLayer`，共用 `LogoBadge.recipe`）——**加图标源时它必须一起改**，否则圈里还是旧徽章。
- 桌面版组（`cwd == "Claude App"`）同样可自定义。status 桶 header 无 projectCwd → 不进图标菜单。
