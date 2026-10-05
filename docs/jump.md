# 跳转机制与优先级

跳转落点的视觉高亮圈见 [`focus-ring.md`](./focus-ring.md)。

## ★ 前置：宿主白名单（T131，改 `focus()` / `SessionRow.editor` 前必读）

**能跳的宿主只有六个**：Terminal.app · iTerm（`TerminalApp`，走 AppleScript 路）· VS Code · Cursor · Windsurf（`EditorApp`，走 raise + 扩展 `term.show` 路）· Claude 桌面版（走窗口 raise 路）。判据收在 `SessionRow.hostSupported`。

**其余宿主一律不跳，也不画圈不画标签**——Warp / Ghostty / kitty / Hyper / Alacritty / tmux server / 裸 ssh 登录都属此列，且**故意不做逐个适配**（不维护「勉强能跳」的灰名单）。

**这曾经是个 bug**：`SessionRow.editor` 早先默认 `.vscode`，把「认不出的宿主」当成 fallback 一起吞了。VSCode 是唯一编辑器的年代无害，多终端时代直接变成——那些会话自称住在某个 VSCode pane 里，于是点它会**把真正的 VSCode 拉到前台**、让扩展去 reveal 一个它根本不拥有的 shellPid，圈就画在了随便一个 pane 上；`flashPaused`（会话被打断时**自发**触发，无需点击）同一条路，画得更莫名其妙。现在 `editor` 是 `EditorApp?`，`nil` 明确表示「宿主不受支持」，`focus()` 遇到它**直接 return**——没有窗口可指时，不动比指错强。

**不支持 ≠ 不显示**：状态来自按 tty 键控的 hook，与宿主无关，所以这些行的 运行中 / 需确认 / 完成 判定照常准确，只有「需要一个窗口/pane 来指」的能力被收走。列表里它们戴通用终端徽章（`badgeMode` 的 `case nil`），不再借用 VS Code 的。

## ★ shellPid 不是「父进程」，是「最近的 shell 祖先」（T299，改 `discoverSessions` / `shellPID(above:)` 前必读）

pane 路径上所有按 pid 对账的东西——扩展的 `term.show`、`verifyTerminalFocus`、`active-terminal` token 的 ack 与 `frontmostIsSession`、FocusRing / StatusPip 的 pane 反查——认的都是 VSCode 的 `terminal.processId`，即那个终端里的**交互 shell**。早先 `shellPid` 直接取 agent 进程的 ppid，对原生 `claude`（父进程就是 zsh）成立，对 **npm 装的 Codex 不成立**：它的原生二进制跑在一层 `node` 启动壳底下（实测 2026-09-08：`zsh 69989 → node 70568 → codex 70569`），ppid 拿到的是 node。症状是「点 Codex 行：窗口来了、pane 不落、done 不 ack」，`jump-diag.log` 里 `verify GAVE UP — token names sh15227, wanted sh70568`，而扩展的 `terminals-<pid>.json` 里只登记 69989，永远对不上。

修法 = `shellPID(above:ppid:)`：从 ppid 起向上走，取第一个 `pbi_comm` 在 shell 名单里的祖先（zsh / bash / fish / sh …），最多 6 层；找不到就退回 ppid（行为同旧）。原生 `claude` 一步即中，零变化；chat panel 行不走这条（它的 `shellPid` 本来就是扩展宿主，不是 shell）。

- **自查**：`ps -o pid,ppid,comm -p <agent pid>` 看父进程是不是 shell；`jump-diag.log` 的 `wanted sh<pid>` 必须能在对应窗口的 `terminals-<extHostPid>.json` 里找到。
- **不要改成「同 tty 的最高祖先」**：Terminal.app 下那是 setuid-root 的 `login`，proc_pidinfo 还会 EPERM。

## ★ 免费档只到窗口（T213，排查「点了却没落进 pane」前先看这条）

`Pro.enabled(.preciseJump)` 为假时（**现在恒为真**：T326 删掉了按构建年龄降级的 `Expiry`，目前也没有付费档，这道门只是留着的接口），`focus()` 顶部据此算出 `precise`，**分界线是「哪个窗口到前台」保留、「窗口内落到哪」收走**：

| 路径 | 免费档还做 | 免费档不做 |
|---|---|---|
| 编辑器 pane | `raiseEditorWindow`（含切 Space） | `armJump` · 扩展 `term.show` · `verifyTerminalFocus` · 落点圈的 pane 目标 —— 四者本来就都挂在 `paneTargeted` 上，加一个 `precise &&` 一起断 |
| chat 面板 | 同上抬窗口 | `requestChatFocus`（聊天输入框同属窗口内落点） |
| 原生终端 | 靠 tty 找到是哪个窗口 + `set index of w to 1` / `select w` | Terminal 的 `set selected of t to true`、iTerm 的 `select t` / `select s` |
| 桌面版行 | 全套照旧 | —— 窗口没有 pane，无可降 |

**窗口级 raise 故意不降**：后台 App 只有缓存 AX raise 能跟随离屏窗口切 Space（见下面「为什么必须缓存 AXUIElement」），一并降掉会让「窗口在别的 Space」时点击**毫无视觉反馈**，而「把编辑器带到前台」是保底核心功能。落点圈不用单独加闸——`FocusRing.highlight` / `highlightWindow` 首行的 `AppSettings.highlightsEnabled` 已被 `Pro.enabled(.highlights)` 门住，免费档整条 pane 树 AX 遍历不发生。

**怎么验**（两个方向都要跑，只验一边看不出降级和坏掉的区别）：`focus-request` 是 `term.show` 的唯一触发文件，点一行后看它的 mtime——免费档点击**不写**、正常点击**必写**。现在没有现成办法进入免费档（`SPECTIX_FAKE_AGE_DAYS` 随 `Expiry` 一起删了），要验只能临时把 `Pro.enabled` 改成对 `.preciseJump` 返回 false 再编一版。

## 跳转优先级：三条跳转路径的统一原理（改任何自动跳转前必读）

**「等待」（`await`，T312）不在任何跳转桶里**：它是「后台命令在跑、AI 会自己续」，什么都不欠你，`awaitsYou` 为 false，快捷键 / 闲置自动跳 / 答完连跳三条路径都看不见它；点列表行仍是普通 focus。`answered` 判据把 needs/paused → await 算作「你处理完了」（和 → working 同款）。

**核心不变量：优先级 = 严格分桶（strict bucketing），不是排序。** 按用户配置的 `AppSettings.jumpPriority`（设置 › 高亮 › 跳转优先级，出厂默认 [paused, needs, done]，见 `AppSettings.jumpStatuses`）取**第一个非空桶**当池子——高优先级桶只要还有行，低优先级桶就**完全不可达**。三条路径全用这一个原理，只在「桶的取值范围」和「桶内怎么走」上有差异：

| 路径 | 入口（`main.swift`） | 桶范围 | 桶内行为 |
|---|---|---|---|
| 快捷键跳转 | `jumpToNextAttention` | **恒为全三桶** needs/paused/done，不受配置影响 | `lastJumpedId` 桶内循环；空池 → `returnToOrigin` |
| 闲置自动跳转 | `maybeIdleAutoJump` | `jumpAutoPriority`（出厂 paused/needs） | latch（`idleJumpedIds`）逐个 surface，输入即清 |
| 答完/恢复连跳 | `autoJumpToNextNeeds`（由 `notifyTransitions` 的 `answered` 触发） | `jumpAutoPriority`（出厂 paused/needs） | 取桶内第一行，跳一次 |

**★ 两条自动路径的桶范围是用户可配的（T184）**：`AppSettings.jumpAutoPriority` = `jumpPriority` 按 `jumpAutoStatuses` 过滤——**顺序只有一个源（`jumpPriority`）**，配置里存的只是成员资格。UI 是「跳转优先级」卡片里每个 chip 上的「自动 / Auto」小药丸（点一下开关，拖拽仍然只管顺序）。出厂 `jumpAutoDefault = ["paused","needs"]`，与改造前那句硬编码 `filter { $0 == "needs" || $0 == "paused" }` 逐字等价，**老用户升级零行为变化**。

三条不对称，都是有意的：

- **手动路径永远三桶全用，不给排除**。对一个「按了才发生」的动作做排除没意义（不想去就别按）；对「自己会发生」的动作做排除才是真需求（= 它能不能打断我）。
- **空集合不允许**：卡片拒绝关掉最后一个药丸（摇一下 + 提示指向下面那两个开关），`jumpAutoStatuses` 读侧也把空数组兜底成出厂值。否则「自动跳转开着但什么都不跳」的原因藏在另一张卡里，是个没有线索的死胡同。
- **连跳的触发判据 `answered`（needs/paused → working）不扩到 done**：它的语义是「**你**处理完了一件事」，而会话自己跑完不代表你动过手。

**done 进自动池后的两处配套（缺一即出 bug）**：`maybeAutoReturn` 的「还有没有待办」判据**故意保持写死的 needs/paused**——done 什么都不欠你，而且它是**没有自然出口的驻留态**（只有去那个终端敲下一轮才会离开），算进去就是「有一个绿的就永远回不了家」。因此两条自动路径**落在 done 上时一律 `pendingAutoReturn = false`**（`jumpOrigin` 保留，手动快捷键仍能回家）：不清的话，跳到绿的那一瞬 needs/paused 已空，下一次 refresh 立刻把人弹回去，表现为一次 ~200ms 的抽搐。

**★ 原地不跳（两条自动路径共用，`frontmostIsSession(row)`）**：目标 row **就是用户此刻所在的那个会话**（其 editor 是 frontmost 且 `active-terminal` token 指向它的 shellPid；桌面版行则看 Claude 桌面版是否 frontmost）→ **直接 return，不 focus 不画圈**。手动快捷键**不加**这道闸（按键=主动要求「再指给我看一次」）。修的 bug：「自动跳转一直重复触发、终端标签被反复刷新」——根因在状态层，不在跳转层：**停在弹窗上的红会话每隔几秒收到 idle-ping hook，那个短命外壳骗过忙碌探测的时刻守卫，于是它自己就在 红→蓝→红 抖**（见 [`session-status.md`](./session-status.md) 的「命令外壳探测」）。**done 进自动池后这道闸更吃重**（T184）：「自己所在的终端跑完变绿」是最高频的事件，没有它就是「我这个终端每跑完一轮就给自己重画一遍呼吸圈」——所以它是 done 可配置的前提，不是可选优化。这一抖同时喂了两条自动路径 —— ① 连跳的 `answered` 判据正是 `needs→working`，没人答任何东西也反复置位，取到的「下一个红」往往就是用户正坐着的那个终端；② 闲置跳转的 latch 靠 `formIntersection(pending)` 维护，抖出池子就掉 latch，抖回来即被当成全新目标再 surface 一次。两条都是「跳到你已经站着的地方」= 零位移、只有呼吸圈无限重启 + `term.show` 反复揭同一个 tab。**此规则覆盖旧需求「就算我本来就已经在对的地方了 也显示高亮」**：原地画圈只是锦上添花，而它和「每次抖动都画一次」在实现上是同一件事，无法只留前者。（若日后回头修状态层的抖动，这道闸也应保留：自动路径跳到原地本就无意义。）

**★ 手头这个红没答完就不跳（T182，两条自动路径共用，`parkedAttentionId`）**：用户此刻**正停在一个还在等他的会话上**（`frontmostIsSession(row)` 且该行 needs/paused）时，两条自动路径**整条禁用**——别处新亮起的红一律等着，不许把人从答到一半的弹窗上拽走。上面那条「原地不跳」只挡「跳到你已经站着的那一行」，挡不住这个：新红是**另一行**，位移货真价实，闸放行，于是屏幕被抢走。

- **latch 何时解**：只有两种情形。① 用户**自己走开**了（frontmost 不再是那一行）——没什么可保护的了；② 那一行离开 needs/paused **且最近 3 秒内有过键鼠输入**（`parkedReleaseInputWindow`）——他真答了。
- **为什么判据是「有没有输入」而不是给个 grace 期**：停在弹窗上的红会自己 红→蓝→红 抖（idle-ping 的短命外壳骗过忙碌探测，见 [`session-status.md`](./session-status.md)「命令外壳探测」）。抖到蓝的那一瞬它掉出 pool，若只看状态，latch 当场就解、新红立刻把人拽走——bug 原封不动地复活。而**答弹窗一定是一次按键，抖动永远不是**，这就是全部的区分点。也不需要额外的宽限时间：答完那一刻的状态写入经 FSEvents 立刻变成一次 refresh。
- **维护点**：`updateParkedAttention(rows)` 每次 `refresh()` 跑一次，且**必须排在 `notifyTransitions` 之前**（连跳就在它里面触发，读的是这一 pass 的 latch）。
- **不影响手动快捷键**：按键 = 主动要求「带我去下一个」，照跳。
- **盲区**：原生终端（Terminal/iTerm）行的 `frontmostIsSession` 恒 false（没有扩展报焦点），所以停在它们上面时这道闸不生效，行为同旧。

**踩过的坑（T19，按时间顺序）**：

1. **扁平拼接 + latch ≠ 优先级**（第一版的错）：`pending = paused行 + needs行` 拼接、latch 逐个往下走——看似「先暂停后需确认」，实际第一跳常是**不可见 no-op**：用户刚按 Esc 暂停，人就停在那个终端上，focus 原地画个圈没有任何视觉位移，latch 却记它「已呈现」→ 下一个 2.5s poll 顺着池子**掉进 needs** → 现象「有暂停却先去了需确认」。快捷键早年也踩过同类坑（flat needs+paused+done cycle 的 "jumps to green first" bug，见 `jumpToNextAttention` 注释）。→ 修复 = 和快捷键一样 first-non-empty-bucket，低桶物理不可达。
2. **「处理完当前项 → 跳下一项」不能走闲置路径**：用户在暂停会话里输入（恢复它）后，键盘输入把闲置计时归零，要**重新闲满整个阈值**（+最多 2.5s poll）才跳下一个——「等了好一会」bug。→ 正确通道是 answered-chain：hook 写 state → FSEvents → refresh **秒触发**，`notifyTransitions` 检测状态转变置 `answered` → 本 pass 尾部连跳。关键：`answered` 判据必须**含 paused→working**（恢复也算处理完），不只 needs→working/done。
3. **连跳的目标也要过优先级**：老 `autoJumpToNextNeeds` 硬编码 `first(status=="needs")`——答完一个弹窗会无视「暂停优先」直接扑向下一个红的。目标选择必须复用同一套 needs/paused 分桶。

**衔接**：自动返程 `maybeAutoReturn` 等 needs+paused **全清**才回家——和两条自动路径的桶范围一致，连跳没跳完之前绝不会提前把人拽回原处。

## ★ 跳错了怎么抓现场（T24 诊断通道）

「按快捷键有时跳到正在运行的 terminal」这类报告**不要凭空推理**，先跑 `tools/tb-jump-log.sh` 拿现场。

- **落点在 `~/.claude/spectix/jump-diag.log`**，不是统一日志。每个跳转决策（`hotkey` / `idle-auto` / `answered-chain` 三条路径各自带标签、`returnToOrigin`、`verify GAVE UP`、`raiseEditorWindow` 的窗口匹配结果）都写一行，200 KB 自动清零。写入方式与 `desktop-probe.log` 完全同款（`jumpDiag`，`main.swift`）。
- **为什么不能只靠 NSLog / `log show`**：本 App 自身的 FrontBoard 噪音约 **3 小时 25 万行**，把 `/var/db/diagnostics` 冲得只剩**不到一天**——2026-07-23 埋的 NSLog 到 2026-08-09 一条都没抓到，不是没复现，是等用户来报的时候证据已经被轮转掉了。统一日志现在只当**当天**的旁证。
- **zsh 有内建 `log`**：直接敲 `log show …` 会报 `too many arguments`，必须写 `/usr/bin/log`（脚本里已经处理）。
- **别给每次刷新的东西挂这个通道**：`jumpDiag` 的每一行都由「人按键 / 人点行」产生。`maybeIdleAutoJump` 里那条按 poll 打的 trace 仍然是 NSLog + `TB_DEBUG` 环境变量门控，原因就是它一秒好几条。
- **三条判据**（脚本自己会打印）：`pool EMPTY → returnToOrigin` 且 `homeStatus=working` = A 回原处，本来就设计如此；`verify GAVE UP` = B 同窗兄弟终端抢走焦点；`hotkey pool=[…]` 里的状态与当时菜单栏显示不符 = C 行陈旧。三条都不沾 = 落点当时是对的，是到了之后那个终端又跑起来了。

## 跳转机制：跳到编辑器窗口 / pane / terminal（改跳转前必读）

> **★ 三个编辑器，不只 VSCode**（改这块前必读）：`EditorApp`（`main.swift` 顶部）枚举 **VSCode / Cursor / Windsurf**，值就是各自的 bundle id（`com.microsoft.VSCode` / `com.todesktop.230313mzl4w4u92` / `com.exafunction.windsurf`），并各自带一个 `extDir`（`~/.vscode|.cursor|.windsurf/extensions`，配套 `spectix.focus` 扩展装在那）。跳转入口因此叫 **`raiseEditorWindow(cwd:editor:)`**（旧名 `raiseVSCodeWindow` 已废，仅存于若干注释里）。缓存变量名仍沿用 `vscode*` 前缀（`vscodeWindowCache` / `vscodeAXCache` / `vscodeWindowEditor`）——**名字是历史包袱，内容覆盖全部三个编辑器**，别照名字以为只存了 VSCode。

点击行 → 跳编辑器窗口 = 从 `vscodeWindowCache` 里**先按 `vscodeWindowEditor[wid]` 滤出属于本行那个编辑器的窗口**（同一个 folder 同时在两个编辑器里开着时，才能落到正确的宿主；缺失的条目默认按 `.vscode` 算，覆盖重启后缓存刚重建的常见情况）→ 按 cwd 的路径分量匹配标题得目标 wid（**深的分量优先**，会话 cwd 嵌在已打开的父 workspace 下时优先选最具体的窗口；先精确分段匹配，再退回宽松子串匹配以容忍装饰过的标题）→ 用 **`vscodeAXCache[wid]`（留存的 `AXUIElement`）调 `kAXRaiseAction` + `kAXFrontmostAttribute` + `kAXFocusedWindowAttribute`**，一步搞定「视觉切到窗口所在 Space + 置顶窗口 + 把键盘焦点交给它」（AltTab 聚焦离屏窗口同款）。element **用前验证**（`_AXUIElementGetWindow` 复核仍解析到同一 wid——Electron 会重建 a11y 对象，死 element 上 raise 是静默 no-op），失效即剔除。

三级 fallback（按命中顺序）：**该编辑器压根没在跑** → `open -b <editor.rawValue> <cwd>`（编辑器自我激活跟随切 Space，落地后下轮扫描补缓存自愈），**不是** `app.activate()`（跨 App 激活不切 Space）；**缓存为空**（编辑器刚启动，或目标窗口从没在我们访问过的 Space 上出现过）→ 退回 `app.activate(...)`；**标题匹配不上任何窗口** → 同样 `app.activate(...)`。**★ 顺序（`focus()` 里）**：先重解析最新 row（toast/行 closure 捕获的是渲染时快照，点击时 status 可能已变——圈的颜色/ack 要用当下状态），再 `raiseEditorWindow`——其四个 AX IPC（kAXMain/kAXRaise/kAXFrontmost/**kAXFocusedWindow**，各 0.5s timeout）**在专用串行 `jumpQueue` 上跑，不占主线程**（主线程同步等 IPC 会在连点跳转时冻住整个 App：VSCode 忙上一跳的 Space 动画时回复顶格，点击全排队——「连点中间卡」bug）。`term.show` 的调度 = **jumpQueue 上排一个 FIFO marker**（串行队列保证它在 raise 完成后才跑）→ 再 +150ms 主线程发 `requestTerminalFocus`＋ **`verifyTerminalFocus` 落点校验**——raise 因 timeout 提前返回后，VSCode 激活完成时会把焦点还给它上次活跃的 terminal、盖掉抢跑的 term.show（「点两下才跳对」bug）。校验 = ~0.75s 后读 `active-terminal` token，没落到目标就重发 focus-request（nonce 保证重写触发 watcher）再验，最多重发 2 次（~1.9s 窗口，之后视为用户主动去了别处，不抢焦点）。**跳转代数 `jumpSeq`**：每次 `focus()` 自增，旧跳转残留的 term.show/校验闭包发现 seq 过期即中止——连点不同行时旧校验绝不把焦点拽回旧目标（「焦点拉锯」bug）；**高亮圈立即启动**（不再等 400ms）——present 本身被 token+paneOwner 三重判据 gate 住，token 一到即画（典型 ~250-450ms）；term.show 提前会把窗口拖到当前 Space。ring overlay 必须用 **toast 同款 NSPanel 配置**（`.nonactivatingPanel`+`.canJoinAllSpaces`+`.stationary`，见 `FocusRing.swift` `makeOverlayWindow`/`show()`）——裸 NSWindow 由后台 App order 时 Space 归属不可靠；正因 `.canJoinAllSpaces`，圈窗口在 Space 切换动画中途创建也可见（老的 400ms 死等已过时移除）。桌面版行 = **同款缓存 AX raise**（`raiseDesktopWindow`，缓存由 AX 状态探测顺手填），`switchToSpace` + `activate` + `slpsFocusWindow` 只作缓存未命中的兜底——详见 [`desktop-app.md`](./desktop-app.md)。

### ★ 第四步 `kAXFocusedWindow` 不可省——少了它整条身份判据会塌（T218，改 raise 序列前必读）

前三步（`AXMain` + `AXRaise` + `AXFrontmost`）**只把窗口摆到最前，不交出键盘焦点**：AX 里 `AXMain`（是不是主窗口）和 `AXFocused`（持不持有键盘焦点）是两个独立属性，而 `kAXFocusedUIElement` 跟随的是 **focused window**，不是 main window。三步跑完，窗口在最前、App 在前台、窗口是 main，**焦点仍停在你跳转前那个窗口里**。随后的 `term.show` 只是 VSCode 内部选中终端（所以 token 是对的），抢不来 OS 级焦点。

后果落在 [`focus-ring.md`](./focus-ring.md) 的**身份对账第 ③ 条**上——它读的是 App 级 `kAXFocusedUIElement`，于是永远解析成**旧窗口里**某个 pane 的身份，把「焦点还没到位」当成「证据表明是别人」→ 每 tick 否决：没有 pane 记忆时圈从头到尾不出现（~6s 后放弃），有记忆时预绘画出来、2s 等不到确认被 `armPredictionGuard` 撤回（用户报的「1. 不显示高亮 2. 显示了一下就消失」，同一个根因）。**实测焦点 5.1 秒零变化**——不是慢，是压根不到。

判据很好认：只有当跳转目标恰好在**当前已持有焦点的那个窗口**里时才画得出来，跳去任何别的窗口都画不出；手点终端（`jump=false`）从不复现，因为那是真实的焦点转移。

实测 Electron **接受** settable `AXFocusedWindow`（`jump-diag.log` 的 `focus wid=… → ok`）。这行日志是留着的探针：哪天变成 `err N` 就说明这条路被关了，届时第 ③ 条判据不能再依赖 App 级焦点，得改成遍历**目标窗口**的 AX 树按 `paneIdentity` 定位 pane（可复用 `findTerminalContainers` / `scanPanes`）。

### ★ 「回原处」（nextAttention 快捷键的空池行为）

一轮跳转结束（所有 needs/paused/done 都清空）后再按一次快捷键 = **回到这轮跳转开始前你所在的地方**（space + 窗口 + terminal）。你在 T1 干活 → 弹窗来了按快捷键跳去处理 → 处理完再按一下，回 T1。→ `main.swift` `jumpToNextAttention` 的 `pool.isEmpty` 分支改为调 `returnToOrigin()`（原来是裸 `return` no-op）。

- **捕获时机（关键）**：每次按键前先看 `frontmostIsInPool(pool)`——当前最前窗口**是不是**池子里的待办项。**不是**（浏览器 / 普通 terminal / 非待办的 VSCode terminal）→ 说明你正站在「家」，(重新)捕获 origin；**是**（正站在刚处理完的待办上，跳转途中）→ **保持**原有 origin 不覆盖。这样最终回的是**这轮起点**，不是最后处理的那一项；也顺带修掉「上一轮没按返回、origin 变陈旧」的问题（下轮从家里起跳时会自动刷新）。
- **捕获内容**（`captureJumpOrigin` → `JumpOrigin`）：frontmost app 的 pid + `kAXFocusedWindowAttribute` 窗口 element + 其 wid（`_AXUIElementGetWindow`）；若 home 是我们在跟踪的 VSCode terminal，另存 `shellPid`。两者全空 → 不记录（不留残废 origin）。
- **返回**（`returnToOrigin`）：`shellPid` 仍对应活着的 row → 直接 `focus(row)` 复用完整跳转（切 Space + `term.show` + 高亮圈），回家和跳出去手感一致；否则走通用路径 `switchToSpace` + `kAXRaiseAction` + `activate` + `slpsFocusWindow`（浏览器 / 原生 terminal / 任意 App 都能回）。返回后清 `jumpOrigin` 并把 `lastJumpedId` 归零 → 下一轮重新开始。
- 局限 v1：原生 terminal（Terminal/iTerm）的待办项无法在 `frontmostIsInPool` 里按 tty 认出来，站在它上面按键会被当成「家」而刷新 origin；无 origin 时空池按键仍是 no-op（同老行为）。
- **★ 闲置自动跳转的自动返程（T17，改 home 追踪前必读）**：`maybeIdleAutoJump` 把你**非自愿**跳到待办后，答完（无 needs/paused 剩余，done 不拦）由 `maybeAutoReturn` **自动**调 `returnToOrigin()` 回原处——不用再按快捷键；手动快捷键路径不武装（`pendingAutoReturn` 只由 idle-jump 置位），保持「再按一次回去」语义。三个踩过的坑：① **不能在跳转瞬间抓 frontmost 当 origin**——那一刻 frontmost 可能是 SpectiX 自己的窗口（曾把自己记成「家」，返回=激活自己）。改为**持续追踪 `homeApp`**（`trackHome`），武装时用它。② **`NSWorkspace.didActivateApplicationNotification` 在同一 App 的窗口/终端之间切换时不触发**——两个 VSCode 项目窗口共享一个 pid，光靠激活事件 home 会卡在旧终端（「回到错误终端」bug）。故 `trackHome` 挂三处：激活观察者（跨 App 切换）+ `checkFocusFlash` 的 0.3s token watcher（VSCode 内部终端切换，`active-terminal` 变了就刷）+ 每次 `refresh()`（兜底）。③ **Electron App（Notion 等）的 `kAXFocusedWindowAttribute` 拿不到聚焦窗口** → `originSnapshot` 加 `frontWindowID(ofPID:)` 兜底：CGWindowList 按 owner pid 取最前 layer-0 窗口的 wid（只用 owner/number/layer，不碰 `kCGWindowName`，**无需屏幕录制权限**）。武装期间 `jumpToNextAttention` 不覆盖 origin（`!pendingAutoReturn` guard），保证多次手动补跳后仍回到最初的 doc；`trackHome` 本身不 gate 在 jumpOrigin 上（跳转目标已被 attention 过滤，不会把在途落点记成家）。④ **武装判据必须是 `pendingAutoReturn`，不能是 `jumpOrigin == nil`**（T59「自动跳转最后没有跳转回一开始的地方」）：`jumpOrigin` **只有 `returnToOrigin` 会清**，而手动快捷键路径也写它——用户按快捷键跳去处理完、直接用鼠标点回来（不再按第二次快捷键触发返程），origin 就永久悬着非 nil；老的 `if jumpOrigin == nil` 武装条件从此再也进不去，`pendingAutoReturn` 不置位 → `maybeAutoReturn` 首行 guard 直接 return → **整条自动返程腿被静默禁用**（只差一次手动跳转就复发，且无任何日志）。改用 `!pendingAutoReturn` 判据：它才是「burst 是否在进行中」的真实标志，burst 内重复 idle-jump 仍保持原 home 不变，同时顺手把陈旧 origin 覆盖成当下的 `homeApp`（用户此刻真正在的地方，正是返程该落的点）。

### ★ `scanVSCodeWindows` 的两趟结构（T91 加，改这块前必读）

函数分**两趟**，只有第二趟被节流，**顺序不能动**：

- **PASS 1（便宜，每次刷新都跑）**：`CGWindowListCopyWindowInfo` → `live`（所有 editor 窗口的 wid，跨 Space，无 AX）。
- **PASS 2（贵，被 gate）**：`kAXWindowsAttribute` 遍历取标题 + 留存 `AXUIElement` → `seen`。触发条件三选一：`live` 集合变了（开/关窗口 → 立即）、`forced`（Space 切换 / 切换前台 App → 立即，`requestForceAXScan()`）、距上次 ≥ `axRescanInterval`(10s)。
- **🚫 血坑（T91 当场踩到并修）**：`live` **必须在 gate 之前算完整**。调用方 `updateVSCodeWindowCache` 拿 `live` 去 `filter` 裁剪三个缓存（`vscodeWindowCache`/`vscodeAXCache`/`vscodeWindowEditor`），所以**提前 return 时交回一个空的或残缺的 `live` = 把整个窗口缓存清空**，跳转直接退化成 `open -b` fallback。gate 只准跳过 PASS 2，`seen` 空是安全的（缓存靠 `live` 保住，只是本轮没被重新确认）。
  - 自查方法：`defaults read app.spectix.SpectiX vscodeWindowCache` —— VSCode 开着却读出 `{}` 就是这个坑。
- **为什么值得节流**：PASS 2 是跨进程 AX IPC，而它原来跟着**每次 FSEvent 刷新**跑（一个活跃回合每秒好几次），窗口开关/改标题却是分钟级的事。节流后开关窗口和切 Space 依然是**即时**补扫，只有"什么都没变"的那些刷新被省掉。

### ★ 同名文件夹（worktree）撞车：靠 `AXDocument` 消歧（T267，改窗口→路径反查前必读）

窗口标题**只有文件夹名，没有路径**。同一个 repo 的两个 git worktree（`nextad/apps/deal-alarm` 和 `nextad-wt-deal-alarm/apps/deal-alarm`）标题逐字相同，于是「名字 → 路径」反查只能靠排序猜，两处一起错：

- **列表多出一个空组**：真正开着的是 worktree 那条、且它有会话；反查却按「置顶优先」落到主仓那条 → 主仓没会话 → 触发 `openProjectsWithoutSessions` 的「窗口开着但没会话」分支，**同一个窗口被数了两遍**（一次真组、一次 header-only 空组）。
- **跳转跳错 checkout**：`raiseEditorWindow` 按标题匹配，两个候选都命中，取 first 就可能是另一棵树 —— 窗口看着对，文件不对。

**判据是 `kAXDocumentAttribute`**：窗口当前显示文件的绝对路径，是唯一带路径的窗口属性。实测（2026-08-25，本机三个 VSCode 窗口）全部有值，连 diff 视图（标题 `index.html (Working Tree) (index.html) — TaskBeacon`）都给出 `~/Projects/TaskBeacon/web/index.html`。值是 percent-encoded 的 `file://` URL，`pathFromAXDocument` 归一化。

**三条不许动的约束**：

- **只当 tie-breaker，不当前提**。webview / 欢迎页窗口压根没有 document，所以先用标题筛出候选、只在候选里用 doc 挑；候选唯一或没 doc 时逐字退回旧行为，**不可能把原本对的解析弄错**。
- **不许改成「doc 优先于 title」**。doc 会过期：窗口换了工作区、用户还没点开文件时 doc 仍指向旧项目，此时标题已经是新的 —— 让 doc 压过标题会把窗口拽到一个标题都对不上的项目去。
- **扫描没读到 doc 时保留旧值**（`updateVSCodeWindowCache`）。切到 webview tab 会让 `AXDocument` 变空而项目归属没变，清掉就等于把歧义放回来。不持久化（同 `vscodeAXCache`），重启第一轮 AX 扫描重填。

**自查**：`~/.claude/spectix/jump-diag.log` 里 `ambiguous folder name in "<标题>" → [候选路径…] | doc=…` —— 只在名字真撞车时才写，不会刷屏；跳转那几行的 `doc=` 列显示每个候选窗口开着什么文件，跳错时只有这一列看得出为什么。

### ★ 没有 doc 的窗口（webview / 终端-only）：T267 的消歧兜不住，靠窗口自报文件夹（T317，2026-09-15）

上一节的 `AXDocument` 是个 **tie-breaker**，前提是窗口有 doc。**停在网页预览标签、或只开着终端的窗口从来没有 doc**，于是 worktree 撞名原封不动地回来了 —— 用户开着 `nextad-wt-deal-alarm/apps/deal-alarm`（有 3 个会话），列表里却多出一个灰色空组 `nextad / deal-alarm`：标题 `99 Ranch probe (127.0.0.1:8799) — deal-alarm` 没 doc → 退回排名 → 置顶的主仓路径排第一 → 主仓没会话 → 画出幽灵组。同一天 anthaul 也在撞（`PIXEL BLOW UP (127.0.0.1:8766) — anthaul`），没出幽灵只是因为主仓没置顶、排名刚好对了。

两层一起修，**上层失灵会退回下层**：

**上层 — 窗口自己报（扩展 ≥ 0.0.8）**：`writeManifest` 每 2s 顺带写 `~/.claude/spectix/window-<扩展宿主 pid>.json` = `{"folders":[…]}`，`deactivate` 里和 `terminals-*.json` 一起删；`CompanionExtension.liveWindowFolders()` 读它并按 `hostAlive` 滤掉死宿主（盘上还躺着 8 月的旧 manifest）。**按编辑器分别信任，且只在该编辑器每个窗口都答了才信**（`报告数 == vscodeWindowCache 里该编辑器的窗口数`）—— 有窗口没重载扩展就整个编辑器退回下层，绝不半信半疑：漏报一个窗口 = 静默少一个 header。走了哪条路看 `jump-diag.log` 的 `window folder reports trusted|unusable for <bid>: N/M answered`（**只在翻转时写**，这函数每 2.5s 跑一次）。

- 🚫 **不许把文件夹塞进 `terminals-*.json`** —— FocusRing（两处）、`StatusPip`、`Diagnostics` 的 `manifests()` 四个读取点都按顶层数组解析，改格式会同时弄坏高亮圈、角标和诊断导出，而且新旧扩展版本在不同窗口里是**同时跑着的**。

**下层 — 标题反查，规则收在 `WindowFolderResolve.resolve()`**（独立文件、纯函数、不碰 AppController，就为了能被 `tools/empty-group-check.sh` 单独编译）。**候选唯一时逐字保持旧行为**，以下只在候选 >1 时生效：

1. doc 落在某个候选下 → 选它（T267，不动）
2. 候选里**有任何一个正有会话** → 返回 nil。这个窗口大概率就是那个已经有真组的项目；**幽灵组比缺一个灰组更糟**（同 `docs/desktop-app.md` 的「三道闸往少一行的方向失败」）
3. 去掉已 taken 的候选，优先选 `EditorWorkspaces.openFolders()` 里有的 —— **只当排序，不当过滤**：实测 2026-09-15 该列表有 8 个文件夹而只有 6 个窗口开着（`backupWorkspaces` 会残留已关窗口）
4. 再按 ProjectHistory 排名

⚠️ **候选列表必须先按 path 去重**：同一条路径会同时从 ProjectHistory 和 EditorWorkspaces 进来，不去重就让一个不含糊的名字看起来含糊，规则 2 会替规则「唯一候选」做决定。

**已知代价（上层没生效时）**：两个同名窗口都开着、有会话的是一个、没会话的那个又停在网页上 → 后者的灰组不显示。**少一行，不是多一行假的**。

**验证**：`tools/empty-group-check.sh` —— 14 个用例覆盖上面 6 个场景 + 去重 + 路径边界（`/a/web-dash` 不算在 `/a/web` 下），一秒跑完。幽灵组在别的记录里全是隐形的（两个候选都是合法路径、标题看着正常），所以这是唯一能随时重跑的证据。

### ★ `open -b` 必须串行：两次挨太近会合并成一个 `Untitled (Workspace)` 窗口（2026-08-26，改任何 `open -b` 调用前必读）

跳转的兜底路径、以及最近项目的「打开」，都是 `open -b <编辑器> <文件夹>`。`open` 发的是 odoc AppleEvent，而 **VSCode 会把挨得近的几个 odoc 攒成一批**：一批里有两个**不同**文件夹时，它不开两个文件夹窗口，而是开**一个多根的 `Untitled (Workspace)` 窗口**把两个都塞进去。

两个后果一起来，而且看上去毫不相干：

- **凭空冒出一个 workspace 窗口** —— 用户没做过这个动作，以为是 VSCode 抽风。
- **项目从列表里消失** —— 这个窗口的标题里只有文件名 + `Untitled (Workspace)`，一个文件夹名都没有，而 `openProjectsWithoutSessions` / `raiseEditorWindow` 全靠标题反查路径 → 永远解析不出来。

**实测（2026-08-26，本机 VSCode 1.135）**：背靠背两次 `open -b` **每次都**合并成一个 workspace（`~/Library/Application Support/Code/Workspaces/<ts>/workspace.json` 里躺着两个 root）；同样两次隔 **400ms** 则各开各的窗口，不合并。

**修法 = `openInEditor()` 串行队列**（`main.swift`，三个调用点全部改走它，**不许再直接 `run("/usr/bin/open", …)`**）：相邻两次至少隔 `editorOpenGap` = 0.6s（在实测安全值之上留余量），队列空闲时立即发，所以单次点击的手感不变；同一个 bundle+path 已在排队就直接丢弃，连点同一行不会攒出一串延迟的 open。

**为什么会挨这么近**：不是只有手抖连点 —— 自动跳转的 open 兜底撞上用户手点另一个项目，就是两个不同文件夹的 open 相隔几十毫秒。

**自查**：`ls ~/Library/Application\ Support/Code/Workspaces/` 出现新目录 = 又合并了；目录里的 `workspace.json` 直接写着被合进去的两个 root 是谁。

### ★ 为什么必须缓存 AXUIElement（血泪，改这块前必读）

从后台 App（`LSUIElement`）**没有别的办法**视觉切到离屏窗口的 Space。逐一实测失败：① `CGSManagedDisplaySetCurrentSpace`（`switchToSpace`）后台调用**只翻 WindowServer 当前-Space 标志位，物理屏不切** → 随后前置动作把窗口显示到屏幕实际所在 Space = **拖窗**；② `_SLPSSetFrontProcessWithOptions`（SLPS）对离屏窗口单独调不触发视觉切换；③ `NSRunningApplication.activate()` 跨-App 激活 macOS 不跟随切 Space（只有 App **自激活**才跟随，故主窗口 `NSApp.activate` / 原生 Terminal `osascript activate` 能切、跨 App 激活 VSCode 不能），且无法把离屏窗口设为前台；④ 扩展 `term.show(false)` 的 `window.focus()` 跨 Space 即拖窗。**唯一可行**：`kAXWindowsAttribute` 只列当前 Space 窗口，但把 element **引用留存**（`scanVSCodeWindows` 存进 `vscodeAXCache`），窗口移走后引用仍有效，`kAXRaiseAction` 它会切 Space + 置顶。缓存随刷新累积、不持久化（跨进程失效，重启第一轮重填）。见 `main.swift` `raiseEditorWindow` / `scanVSCodeWindows` / `focus`。
