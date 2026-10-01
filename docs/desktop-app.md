# Claude 桌面版 App 状态行（无 hook，靠 AX 探测）

桌面版 App（claude.ai 原生客户端，bundleId `com.anthropic.claudefordesktop`）无 hook 机制，作为**特殊 row**（`SessionRow.isDesktop`）接入。

**一个 app，多个 row**：桌面版是一个 Electron 进程托管多个窗口（聊天窗口 + **Claude Design** 窗口），`Claude Design` **不是独立 app**（`/Applications` 下只有 `Claude.app`，开 Design 只是多起一个 `Claude Helper (Renderer)`，`--app-path` 仍指向同一个 `app.asar`）。所以**按窗口出行**，不是按 app 出行：

- **键控 = `CGWindowID`**（`SessionRow.desktopWid`）。pid 被所有窗口共用、tty 为空，窗口号是唯一能把两行分开的东西 —— 它同时是 `SessionRow.id`（`desktop:<wid>`）、latch 的 key、跳转目标。**改这块别退回按 pid 键控**，那样两行会撞成一个 id，ack/toast 记账全乱。
- **两个 sentinel cwd**：`AppController.desktopCwd = "Claude App"` / `desktopDesignCwd = "Claude Design"`，各自成一个 header 组、各自有独立的隐藏开关。UI 里判断「这是不是桌面版组」一律用 **`AppController.isDesktopCwd(_:)`**，不要拿单个 sentinel 比 —— 加 Design 时正是这种单点比较悄悄漏掉了一半的行。
- **同类多窗口**：开两个聊天窗口 = `Claude App` 组下两行（`seq` 组内递增）。

## 判定（全部按窗口，不按 app）

- **在跑（两个判据，别只留一个）**：Chromium 默认不建 a11y 树，先对 app 的 AXUIElement 设 `AXManualAccessibility`（+`AXEnhancedUserInterface`）强制展开，再在**该窗口**子树里找（`main.swift` `axIsGenerating()`）：
  1. `AXButton` 的 desc 含 `"Stop response"` —— **聊天窗口**的判据。
  2. 以 `…` 结尾的**短状态文字**（`Thinking…` / `Shelling…` / `Generating questions…`）—— **Design 窗口**的判据。
  
  为什么必须有第二条：**Design 的停止按钮完全没有无障碍名字**——`title` 和 `description` 都是空的（它的标签是一个不可见的图标字形），按钮本身没有任何可匹配的东西。只留判据①的后果实测过：Design 整轮对话从提问到回答全程显示「闲置」。
  
  第二条是启发式，所以**围了两道栅栏**：① **只对 Design 窗口生效**（聊天窗口已有判据①那种精确信号，放启发式进去只会白添误报）；② **收窄到 ≤30 字符、≤3 个词**，这样对话正文里恰好以省略号收尾的句子冒充不了状态行。误报比漏报严重得多——它会把行**永久**钉在「运行中」。实测 7 份真实快照：生成中 5 份全中、答完那一刻立刻转出、聊天窗口闲置 0 误报。
- **是不是 Design 窗口**：两个判据取或，且**一旦判定就按 wid 粘住**（`desktopDesignWids`，窗口关掉才清）——
  ① 原生窗口标题 == `Design`（**只在项目列表页成立**，打开一个 design 项目后标题会变成项目名）；② 子树里有 `AXWebArea` 标题 `Claude Design`（**耐久判据**）。
  判据②搭 `axScanWindow` 同一次遍历的便车 —— 整棵树走一次 ~200ms，**别拆成两次遍历**。
- **done 合成**：AX 只给「在跑/没在跑」两态。`done`（该你了）由状态机合成：working→非working 的**边沿** latch `done`。**latch 是 per-wid 的字典**（`desktopWasWorking` / `desktopDoneLatched`）——app 级单值会让聊天窗口结束一轮时把 Design 那行也点亮。
- **「你已看到」清 latch**：条件是 **app 前台 且 该窗口是 focused window**。只看 `app.isActive` 不够 —— 多窗口下你在读聊天窗口，不代表你看过 Design。同理 `frontmostIsSession()` 对桌面版行也要比对 focused window id，否则两行互相之间的自动跳转会被误判成「你已经在这儿了」而抑制掉。
- **开销控制**：idle 窗口无 `Stop response` 可 early-exit，每个窗口要走完整棵子树，故 **~2s 节流**（`desktopProbeAt`/`desktopCache`）。节流**在没有缓存时也必须成立** —— 否则 AX 一坏，每次 refresh 都重走一遍树，而正在跑一轮对话（refresh 一秒好几次）恰恰是最耗不起的时刻。
  ⚠️ `AXUIElementSetMessagingTimeout` **只作用于被设的那个 element，不会被它返回的子元素继承**（`AXUIElement.h`）。所以它管的只是「取窗口列表」这一个调用，从来没有 bound 住整棵树的遍历（旧注释写反了）。窗口 element 要单独再设一次。超时从 0.3s 提到 **1.0s**：Electron 主线程在启动时 / 生成中 / Squirrel 自更新时routinely 超过 0.3s，而每次超时的代价是**丢掉全部桌面版行**。

### 谁决定一行存不存在（别再翻回去）

**WindowServer（`CGWindowList`，零权限）决定行的存在，AX 只负责往行上补 status/kind/model。**

以前是反的 —— AX 产出行，于是**只要早期探测失败，两行就整个会话消失**：每条失败路径都返回那个还是空的 cache，手里根本没有东西可交。而启动后第一次探测**必然失败**（Chromium 的 a11y 树是懒建的）。丢行会把一整个会话的状态藏起来，而一行短暂地被归错组、或读作「闲置」，下一次探测就自己好了。

- **记住 AX 认过的窗口**：`desktopKnownWids`（+ `desktopDesignWids` 分类）落盘在 `desktop-windows.json`，跨 SpectiX 重启有效。AX 挂掉时，拿它和 WindowServer 的实时窗口取交集出行 —— 这就是 `desktopFallback`。
- **绝不拿原始 CGWindowList 直接造行**：一个可见聊天窗口背后，app 会公布 **~13 个 layer-0 窗口**（每块屏一条 3440×30 的原生顶栏、一个 500×500 helper、几个从不显示的 800×600 壳）。照单全收就是十几个幽灵行，比原 bug 更糟。**CGWindowList 的公开字段筛不掉它们**——`alpha`/`sharingState`/`storeType`/`memoryUsage` 逐个相同，唯一能分开的 `kCGWindowName` 正是屏幕录制权限管的那个字段。所以 CGWindowList 只回答「这个窗口还在不在」。
- **谁回答「这是不是一个真窗口」：WindowServer 自己**（`WindowServerWindows.swift`，见下节）。它跨 Space 有效，所以**从没和你同处一个 Space 的窗口现在也有行**。
- **代价**：AX 挂着时 status 退化成「闲置」（没有树就看不到 `Stop response`，但已 latch 的 done 仍显示）、model 用最后读到的值、**kind 退化成聊天组**（没探测过就不知道是不是 Design，切过去一次就自己归位）。
- **这条降级路径最常被触发的原因不是「AX 坏了」，而是「Claude 在别的 Space」**（见下面 ⚠️ 那节）。
- `desktopFallback` **故意不写 `desktopCache`** —— cache 是「最后一次 AX 认定的事实」，用降级快照覆盖它会让节流开始分发猜测。**但这只管节流路径**（见下条）。

### ⚠️ 两条出口必须给同一个答案（行「每 2 秒闪一次」，2026-08-25）

`desktopStatus()` 有**两个出口**：2s 一次的**真探测**，和这 2s 之间每次 refresh 走的**节流分支**（直接返回 `desktopCache`）。它们答案不一样，行就会按探测周期一闪一闪。

- **闪的成因**：真探测走完 AX 一无所获 → 降级问 WindowServer → 此刻 `ws=0`（app 开着但窗口被 ⌘W 关了）→ **0 行**；而 `desktopCache` 还压着上次 AX 成功时的那一行 → 节流分支照发 → **1 行**。两秒一循环。实测现场：`ws=0` 持续 18 分钟，行全程闪。
- **修法**：**真探测降级时，把降级结果 adopt 进 `desktopCache`**（`live.isEmpty` 那个分支）。判据是「这次是不是一个结论」——真探测走过 AX 且空手而归**是**结论；节流分支只是两次探测之间的替身，**不是**，所以它调的 `desktopFallback` 仍然不许写 cache。上一条那句「故意不写」因此只对节流路径成立。
- **adopt 时要把标题带过去**：`label` 是降级路径**唯一造不出来**的字段（只有 AX 有窗口标题），按 wid 从旧 cache 继承。`model` 有 `desktopModelByWid` 兜底、`isDesign` 有 `desktopDesignWids` 兜底，都不用管。
- **配套：窗口全关那条分支要清两个 cache**。`desktopCache` 和 `desktopFallbackCache` 是同一个答案的两个视图，节流读哪个都有可能——只清一个、另一个还留着非空快照，窗口都没了还能再发 2 秒的行。

### 跨 Space 认窗口：`SLSCopySpacesForWindows`（T188）

**问题**：`kAXWindows` 只枚举当前 Space（见下面 ⚠️ 那节）。开机后 Claude 自启动在别的桌面 / 全屏（全屏按定义独占一个 Space），你一次都没切过去 —— AX 永远没描述过这两个窗口，于是**行永远不出现**。

**判据**：**WindowServer 只给真正属于某个桌面的窗口分配 Space**。顶栏 strip、从不显示的壳窗口、helper 全都**没有** Space。2026-08-08 实测（Claude 当时正好在别的 Space 上）：

| app | layer-0 窗口 | 有 Space 的 |
|---|---|---|
| Claude | 12 | **1**（真窗口，在 Space 3） |
| Notion（同为 Electron） | 10 | **1** |
| Finder（当时没开窗） | 9 | **0** |
| VS Code（开着 3 个窗口） | 11 | **3** |

**怎么调**：`dlsym(RTLD_DEFAULT, …)` 取 `SLSMainConnectionID` / `SLSCopySpacesForWindows`（selector `0x7` = 含全屏与平铺 Space）。SkyLight 已被 AppKit 加载，**不 dlopen、不 link** —— `otool -L` 输出不变，不影响官网请人自行验证「无网络」那条卖点。只要辅助功能权限，**不需要屏幕录制**。

**三道闸**（幽灵行比缺行更糟，所以每一道都往「少一行」的方向失败）：
1. **符号闸**：任一 `dlsym` 取不到 → 整条路关闭，退回「只有 AX 认过的窗口才有行」的旧行为。
2. **几何闸**：还要 `w ≥ 200 && h ≥ 120`。顶栏 strip 高 30/33，光凭这一条就进不来。
3. **数量闸**：单个 app 超过 8 个「真窗口」判定为**位语义已变**（这类私有 API 坏起来的样子就是「筛子不筛了」），整份答案作废而不是发出去。

**试过并否掉的两条**：① yabai 那套 tag/attribute 位掩码 —— 本机 macOS 上**所有**窗口的 `SLSWindowIteratorGetAttributes` 都读作 `0x0`（真窗口也是），且真窗口和从不显示的壳窗口 tag 逐位相同（`0x300000100080401`），筛不出任何东西；② `SLSCopyWindowProperty(kCGSWindowTitle)` —— 每个窗口都返回空串，标题同样被权限挡住，指望不上它认 Design 窗口。

**已知残留**：这样出的行是**降级行** —— 没有 status（恒「闲置」）、没有 model、归在聊天组。它不会自愈，除非你切过去一次让 AX 描述它。但「一行读作闲置」远好过「整行不存在」，而且点它就能跳过去、跳过去就自愈。

## 点击跳转（跨 Space，改这块前必读）

`focus(_:)` 中 `row.isDesktop` → 先 `deminiaturizeWindows`（最小化的窗口不吃任何前置动作），再 **`raiseDesktopWindow(pid:wid:)`：拿缓存的 `AXUIElement` 做 `kAXRaiseAction` + `kAXFrontmost`**，和编辑器跳转同一条路（[`jump.md`](./jump.md)「为什么必须缓存 AXUIElement」）。

- **必须传 `wid`**：候选顺序是 `本行的 wid → focused → 最大窗口`。后两个是**没有窗口可指**时的兜底 —— 早期只有它们，于是点 Design 行会落到聊天窗口（"最大的那个"）。
- 缓存 = `desktopAXCache`（wid → element），由 `cacheDesktopWindows` 搭 `desktopStatus()` 那次 ~2s 节流探测的便车填（此时 a11y 树已被 `AXManualAccessibility` 展开），窗口关掉即被 live-wid 过滤剔除。
- **修的 bug**：老路径 `switchToSpace` + `activate` + `slpsFocusWindow` 是把 Claude **拽到当前 Space**，而不是切过去——后台 App 调 CGS 设 Space 只翻 WindowServer 标志位、物理屏不动，随后的 activate/SLPS 就把窗口拖了过来。该三件套只留作缓存未命中的兜底（此时也用本行的 wid，不再退回最大窗口），跳过去一次即自愈。
- **高亮圈也要带 wid**：`TerminalFocusRing.highlightWindow(windowID:)`。raise 是异步跑在 `jumpQueue` 上的，圈如果按「当前 focused window」解析，多半解析到**你正要离开的那个窗口**。

## 用量 / token（现状：没有，且已确认做不到）

桌面版行**不显示时长/token**（`configure(freeMeta: true)` 保状态短语，见 [`row-display.md`](./row-display.md)）。原因不是没做，是**本地没有可信来源**。2026-08-03 查了个底朝天，结论存档在这里，**别再重查一遍**：

- Design 窗口的 a11y 树里**没有任何** token / usage / credit / quota 文字（实测 dump 全树 226 行，零命中）。
- 桌面版自己写的 `~/Library/Application Support/Claude/plan-usage-history.json` 只有 `{fh, sd}` = 5 小时窗口 % / 7 天 % 的**整数百分比**，300s 一采样，**账号级、不按窗口拆、无 token 绝对值**。
- 而且 `fh`/`sd` 和 header 已经在显示的「会话%/本周%」（`usage.json` ← `claude -p "/usage"` 探针）**逐位相同**（实测同时刻 `fh=15,sd=26` vs `session_pct=15,week_pct=26`）——两个采集器读的是同一份套餐配额。所以把它显示到桌面版行上只会是「顶部数字的副本 + 看着像是这个窗口花的」，用户已明确否掉。

**唯一按窗口成立的数据 = 模型**：`axFindModel` 从窗口自己的模型选择器读，按 wid 缓存、30s 一刷 —— 选择器埋得深（聊天窗口 ~depth 25），不能搭 2s 状态探测的便车。它喂 `SessionRow.model`，行末的模型胶囊对桌面版行照常显示。

⚠️ **`Model` 前缀不是恒定的**，实测三种写法：`Model  Opus 5`（Design 首页）/ `Model: Opus 5 High`（聊天）/ **`Opus 5 Medium`（Design 进了项目后，完全没有前缀）**。所以判据不是「标题以 Model 开头」——那样进项目后模型就空了——而是「剥掉可选的 `Model` 标签后，**剩下的第一个词是模型族名**」（`modelFamilies`）。这同时挡掉了同窗口里别的 popup（`No file open`、`Account menu`）。

## 排查手法①：读探测日志（先看这个）

再有人报「Claude 那几行不见了 / 一直闲置」，**第一件事是读 `~/.claude/spectix/desktop-probe.log`**，不要再靠猜。探测不干净时才写一行，同一签名一分钟最多一条、超 200KB 自动截断，所以它不会长。

一行长这样，每个字段各自证一件事：

```
[1786224760] err=0 man=0 ax=0 usable=0 cg=12 on=0 ws=1 widMiss=0 trusted=1 finder=0 OFF-SPACE(normal) fails=0
```

| 组合 | 说明 |
|---|---|
| `err=-25211`（APIDisabled） | 我们的辅助功能授权没了 / 死了 |
| `err=-25204`（CannotComplete）+ `finder=0` | Claude 主线程当时太忙，等下一轮就好 |
| **`err=0` + `ax=0` + `cg>0` + `on=0`** | **不是故障**：窗口全在别的 Space 上（见下）。照常记一行，但**不计入 fails**；此时 `ws=` 才是「到底有没有行」的答案 |
| `ws=N` | WindowServer 跨**所有** Space 数出的真窗口数。`ax=0 ws=1` = 在别的 Space 但行照出；`ws=0` = Claude 确实一个窗口都没开；**`ws=off`** = SkyLight 符号没了（三道闸的第一道），只剩 AX 认过的窗口能出行 |
| `err=0` + `ax=0` + `cg>0` + **`on>0`** | 窗口就在眼前 AX 还是不列 —— 这才是「树没建起来」，也**只有这一种值得查** |
| `man!=0` | app **拒绝**了 `AXManualAccessibility` 激活（`-25205` = 这个 Electron 版本不认这个属性了） |
| `finder!=0` 而 `trusted=1` | TCC 说已授权，但 AX 对本进程实际是死的（macOS 已知问题，见下） |

### ⚠️ `cg` 和 `ax` 对不上，多半根本不是 bug（这条坑了一整轮调查）

**`kAXWindows` 只枚举「当前 Space」上的窗口** —— 和 `raiseDesktopWindow` 那里早就写着的、当年造成多窗口跳转 bug 的是同一条约束。而 `desktopWindowList` 问 `CGWindowList` 要的是 **`.optionAll`（跨所有 Space）**。所以只要 Claude 待在别的桌面、或处于全屏（**全屏窗口按定义独占一个 Space**），`cg=12 ax=0` 就是**正确**读数，而且你不切过去它就一直是这个样子（实测连续几分钟 `fails=161`，看着像彻底坏了）。

同一时刻实测：`optionAll=12`，`onScreenOnly=0`。

没有 `on=` 这一列时，这行日志读起来和「a11y 树坏了」**一模一样**，会把下一个人依次送去查 Chromium、Electron 和 TCC 数据库 —— 三个都是无辜的。**别再照着 `cg>0 && ax==0` 去查 a11y，先看 `on=`。**

`finder` 是拿 **Finder** 当探针：它永远在跑、是原生 app、绝不是 Chromium，所以是唯一能把「我们的授权坏了」和「那个 Electron app 在闹脾气」分开的东西。

**「已授权但是死的」**：`AXIsProcessTrusted()` 会在每个 AX 调用都返回空的情况下照样报 true（App 重装 / 更新后授权记录对不上新签名）。这时提示用户「去开启权限」是彻头彻尾的误导 —— 开关本来就是开的。`AppController.axDegraded` 就是这个状态，popover 的警告按钮、设置页的「辅助功能」行、以及点开后的弹窗文案都按它分叉，修法是**把开关关掉再打开**或重启 App。

## 排查手法②：dump a11y 树

`touch ~/.claude/spectix/design-ax-dump.request` → 之后**每轮探测**把每个桌面版窗口的树写成 `design-tree-<wid>-<0…5>.txt`（**只在树发生变化时**才占一个槽位，所以 6 个槽 = 最近 6 个**不同状态**，而不是 12 秒）。删掉 request 文件即停。

- **为什么是「持续抓」而不是「抓一次」**：值得找的东西（停止控件、状态行）**只在一轮对话进行中存在**，事前事后抓都是空的 —— 用法是拿「生成中」那份和「答完」那份做 diff。
- **为什么用文件开关而不是环境变量**：App 必须经 LaunchServices 启动才保得住辅助功能授权（从终端直接起的进程 TCC 算在终端头上，AX 全部拿不到，实测 `windows=0`，见 [`permissions.md`](./permissions.md)），根本没有能挂环境变量的启动方式。
- Chromium 的 `AXDOMClassList` / `AXDOMIdentifier` **别指望**：实测 class 一个都没有、id 只有 4 个自动生成的（`base-ui-_r_3o_`），认不了人。

要重新调查时用上面「排查手法②」那一节的 dump。
