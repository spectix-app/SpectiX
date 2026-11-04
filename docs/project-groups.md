# 项目组：把几个项目拖进一个大块（T387）

同一个功能分在几个仓库里（1 个前端 + 2 个后端）时，把它们收进一个组：组标题一行 + 成员项目卡紧跟在下面 + 左边一根紫色贴边线把它们连起来。设计稿 `design/project-groups.html` 第二轮，用户 2026-10-28 定：**C 改 · 贴边线**（卡片一格不往里缩）+ **I2 图标外圈倒计时** + **停 0.5 秒**。

## 怎么用

- 按住一个项目的图标拖到另一个项目标题上**停 0.5 秒** → 目标图标外圈转满、出现「松手 → 合成一组」→ 松手成组
- 再拖第 3、4 个到组标题（或组里任一成员）上停住 → 加进组
- 没停够就松手 = 普通换位置（和以前一样）
- 落点在组内两个成员之间（紫线里面）= 放进组 / 组内换序；落点在组外 = 移出组
- 按住组标题的紫色图标拖 = 整组一起挪
- 右键组标题：重命名组 / 解散组；右键成员：移出组
- 组里只剩 1 个成员 → 自动解散
- 点组标题任意处 = 折叠；折起来只剩一行组名 + 合计状态 + 成员名

## 数据

- `ListModel.groups: [ProjectGroup]`，存 UserDefaults `listProjectGroups`（JSON）。成员是 cwd；**关掉的项目保留在组里**，窗口重开就回到组里
- 屏幕上只有**至少 2 个成员开着**的组才画成组，否则剩下那个按普通项目画
- 组的位置 = 它排序最靠前的那个开着的成员的位置；成员按组内顺序紧跟在组标题下
- 折叠状态走现有的 `collapsed` 集合，键是 `group:<id>`（和项目折叠一样只存内存）
- 合并 / 入组后用 `rebuildOrder(flat:moved:)` 重排 `folderOrder`，保证组员在排序里连续、组留在原地 —— 不重排的话，一个排在前面的项目加进组会把整个组拽上去

## 视图

| 东西 | 在哪 |
|---|---|
| 组标题行 | `GroupTitleCell`（`ProjectGroupViews.swift`），`DisplayItem.group` |
| 倒计时圈 + 「松手 →」提示 | `MergeRingView` / `MergeHint`，项目标题（`HeaderCell.setMergeState`）和组标题共用 |
| 贴边紫线 | 画在 `TransparentRowView` 的 `railLayer` 上，每行画自己那一段，行与行之间无缝拼成一根 |
| 停留计时 + 放下逻辑 | `SessionListView` 的 validateDrop / acceptDrop，`rowGroup` 记每行属于哪个组 |

`DisplayItem.group` 的 `isHeader` 为 true（它也是一段卡片的起点），所以成员最后一行的圆角、拖拽落点、悬停浮起的边界都自动认它。

## 改这块前必读

- **★ 停留计时不能只信 validateDrop**：鼠标停住不动时 AppKit 不一定再发拖拽更新，所以「转满」靠 `asyncAfter` 自己翻，放下时 `acceptDrop` 按时钟判断是否已满，不看 drop operation
- **★ 行视图图层的坐标是从上往下的**（table row view 是 flipped，它的图层几何也是）。2026-10-28 我从缩略图误判成从下往上，改完紫线反而在行交界处断开；后来用像素量才确认。**改紫线前后用像素量**，别靠看缩略图：`tools/row-preview.sh` 的演示数据里固定有一个组（pico-engine + notes-api），最后一列是「组折起来」
- AppKit 自带的「拖到行上」蓝框已在 `TransparentRowView.drawDraggingDestinationFeedback` 里关掉，反馈只有自己的圈
- 组员拖到**自己组的标题**上不会触发合并倒计时；松手按蓝线落点处理，落点在标题上方 = 移出组
