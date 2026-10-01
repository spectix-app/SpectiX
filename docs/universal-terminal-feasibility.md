# 研究：能否通用侦测 + adapt 任意终端（免去逐终端适配）

> T44 研究结论。问题：能不能让 SpectiX 侦测到「任何 IDE 内置终端 / 任何第三方独立终端」里的 Claude 会话，并跳转/定位过去，而**不用**为每种终端单独写代码。
> 一句话结论：**「侦测」层已经天然通用、零逐终端成本；「跳转定位」层不存在通用机制、必须逐终端适配——但可以用一个「通用窗口级 fallback」覆盖所有未知终端，把逐终端工作从「必需」降级成「精度增强的可选项」。**

---

## 核心洞察：把问题拆成两层，答案完全不同

SpectiX 干两件事，它们对「终端类型」的依赖天差地别：

| 层 | 做什么 | 对终端类型的依赖 |
|---|---|---|
| **① 侦测（detect）** | 列出所有 Claude 会话 + 它们的状态（运行中/完成/需确认/闲置）+ 时长/token/标题 | **零依赖，已经通用**。任何终端都行。 |
| **② 跳转定位（adapt/jump）** | 点一行 → 切到那个终端窗口 + 选中那个 tab/pane + 画高亮圈 | **强依赖**。每种终端暴露的自动化接口都不一样，没有跨终端标准。 |

用户价值的大头（「一眼看到哪个会话该我处理了」）在 ① 层——**这一层现在就已经对所有终端生效**。② 层是「锦上添花的一键跳过去」，这才是逐终端适配的成本所在。

---

## ① 侦测层：已经完全终端无关（无需任何逐终端代码）

证据链（`main.swift` + hook）：

1. **进程发现不认终端**：`discoverSessions()`（`main.swift:1750`）用 `allPIDs()` 枚举**全系统进程**，只挑 `arg0 == "claude"` 的（排掉 daemon / `--print` / stdio 扩展宿主等非交互进程）。它根本不看宿主是什么终端——Warp / Ghostty / Kitty / Alacritty / tmux / Terminal.app 里的 claude 一律照抓。
2. **tty 来自内核**：会话的 tty 从 `processBSDInfo(pid).tty` 拿（`main.swift:1788`），是内核给每个 pty 的唯一标识，与终端品牌无关。
3. **状态来自 hook，hook 跑在 claude 进程内**：`hooks/spectix-status.sh` 由全局 `~/.claude/settings.json` 注册，Claude Code 无论在哪个终端里跑都会触发它，写 `~/.claude/spectix/state-<tty>`。终端只是个「装 claude 的壳」，hook 感知不到也不关心壳是谁。
4. **键控原则本就按 tty/pid**（见 CLAUDE.md「通用约定」）——天然不绑终端。

> **结论**：把 claude 跑在任何一个从没适配过的终端里，SpectiX 的菜单栏列表、状态颜色、时长/token/上下文占用、标题——**全部照常工作**，一行代码都不用加。这一点已经是「通用 adapt」了。

**唯一的小瑕疵**：未知宿主会被 `discoverSessions` 里 `EditorApp.init(rawValue:) ?? .vscode`（`main.swift:1791`）**默认归类成 VSCode**。这不影响状态显示（状态是 tty 驱动的），只影响 header 那个「来源图标」画成 VSCode 徽章、以及跳转会错走 VSCode 路径（见下）。

---

## ② 跳转定位层：不存在通用机制，现状是「三档 + 一个空洞」

`focus(row)` 按宿主分派到三条互斥路径：

| 档 | 覆盖的终端 | 机制 | 逐终端成本 |
|---|---|---|---|
| **A. VSCode 家族** | VSCode / Cursor / Windsurf | 装一个**配套扩展**（`vscode-extension/extension.js`）+ AX 抬窗（`raiseEditorWindow`） | 扩展只写一次，三个 fork 共用（只是装到各自的 `.vscode`/`.cursor`/`.windsurf` 扩展目录，`EditorApp.extDir`）。加一个新 VSCode fork ≈ 加一行 bundle id。 |
| **B. 可脚本化原生终端** | Terminal.app / iTerm2 | **AppleScript 按 tty 选 tab**（`focusTerminal`，`main.swift:2931`）+ `TerminalFocusRing` 画窗口级圈 | 每个 app 一段方言不同的 AppleScript（Terminal 用 `tabs`，iTerm 用 `sessions`）。加一个 = 写一段新 osascript。 |
| **C. 其它所有终端** | Warp / Ghostty / Kitty / Alacritty / Hyper / WezTerm / tmux / … | **无适配** → 落到默认 `.vscode` → 走 VSCode 扩展的文件监听 → 那个终端里根本没装扩展 → **静默 no-op（跳转什么也不发生）** | —— 这就是那个「空洞」 |

### 为什么没有「一套代码搞定所有终端」的跳转

这是**操作系统层面的根本约束**，不是没写好：

- 操作系统只给你两样东西：**进程**（tty、pid、父子链）和**窗口**（AX 树、CGWindow）。
- 但一个终端的 **tab / pane 是 app 内部的概念，操作系统根本不建模**。从「tty X」定位到「选中显示 tty X 的那个 tab」，你**必须问那个终端 app 自己**。
- 而「问」的接口每家都不同、且没有跨 app 标准：
  - VSCode 家族 → 扩展 API（`term.processId` 匹配 + `term.show()`）；
  - Terminal/iTerm → AppleScript（它们把 `tty` 暴露成脚本对象属性）；
  - Warp / Ghostty / Kitty / Alacritty → **既不可 AppleScript 脚本化、tab 也在单窗口内**，操作系统没有任何办法「按 tty 选中某个 pane」。

所以：**pane 级精确跳转，逐终端适配是绕不过去的**——要么该终端有脚本接口（写方言），要么你能给它注入扩展（VSCode 那种），二者皆无就做不到 pane 级。

**pane 级高亮圈更是结构性绑死 VSCode**：`FocusRing.focusedTerminalPane()`（`FocusRing.swift:508`）靠读 AX 属性 `AXDOMClassList` 里有没有 `xterm-helper-textarea` 来认 pane——这是 **Electron/Chromium 特有的 AX 属性 + xterm.js 特有的 DOM class**。任何非 Electron、非 xterm.js 内核的终端（原生 Terminal、Warp、Ghostty…）在这里必然返回 nil，pane 圈根本画不出来。这不是「没写适配」，是「非 Electron 终端没有这个 AX 结构可读」——所以 pane 级精度**天然只对 VSCode 家族成立**。另外「打开最近项目」也写死了 VSCode（`main.swift:2674` `open -b com.microsoft.VSCode`），是另一处需要一并通用化的硬编码。

### 但「窗口级」跳转可以做成通用的（这才是本研究的可落地产出）

档 C 现在是「什么都不做」。可以把它改成一个**不需要任何逐终端代码的通用 fallback**：

- `hostAppBundleId(forClaudePid:)`（`main.swift:1806`）已经能拿到**任意**宿主 app 的 bundle id / pid（走父链到 launchd）。
- 拿到 pid 后，用**已有的通用原语**把那个 app 的窗口抬到前台：AX `kAXRaiseAction` + `NSRunningApplication.activate`（跨 Space 的坑代码里都趟过了），再用 `TerminalFocusRing.highlightWindow`（`FocusRing.swift:198`，本就按 appPid+bundleId 画窗口级圈、非 VSCode 专属）画个圈。
- 效果：**任何第三方终端**，点一行 → 那个终端 app 被切到前台 + 画高亮圈。**做不到**的只是「多窗口/多 tab 时选中确切那一个」——但对「一个终端就开一两个窗口」的常见用法（Ghostty/Alacritty/Warp 单窗口多 tab 或少窗口）已经够用；对 tmux 更是天然只有一个终端窗口。

这样「通用 adapt」就成立了，只是分级：

| 精度 | 覆盖 | 成本 |
|---|---|---|
| **状态侦测**（列表+颜色+统计） | 100% 所有终端 | 0（已实现） |
| **窗口级跳转 + 圈** | 100% 所有终端 | 一次性写一个通用 fallback（约几十行，复用现有原语） |
| **tab/pane 级精确跳转** | 仅可脚本化 / 可注入扩展的终端 | 逐终端（VSCode 扩展 already；原生终端 AppleScript already；其余做不到） |

---

## 硬限制（无论怎么做都覆盖不了，需向用户说明）

1. **SSH / 远程会话**：claude 跑在远端主机，本地**没有对应进程**，`discoverSessions` 抓不到——侦测都不可能，更别说跳转。（除非在远端也部署一套上报，超出当前架构。）
2. **tmux / screen 复用器**：claude 的 tty 是 tmux 分配的 pty，父链走到的是 **tmux server 进程**而非可见终端 app → `hostAppBundleId` 可能解析不到真正的宿主终端 → 窗口级跳转的目标会不准。侦测（状态）仍正常，跳转会打偏。
3. **纯 CLI / 无窗口环境**（裸 tty、后台 mux）：没有可抬的窗口，跳转无意义（侦测仍可）。

---

## 建议的落地路径（如果决定做）

按性价比排序，每步独立可交付：

1. **【高性价比·先做】通用窗口级跳转 fallback**：给档 C 补上「AX 抬宿主窗口 + 窗口级圈」。一次性覆盖所有第三方终端，让「点击跳转」不再是 no-op。同时把未知宿主的 header 徽章从「假装 VSCode」改成一个中性「通用终端」图标（`ListModel.swift:43` `HeaderSource` 加一个 case）。
2. **【按需】给高频第三方终端加 pane 级适配**：只有当某个终端既常用、又暴露了 tab 选择接口时才值得。现实里：
   - **WezTerm** 有 CLI（`wezterm cli activate-pane --pane-id`）可按 pane 精确跳，但要 tty↔pane-id 映射；
   - **Kitty** 有 remote control（`kitty @ focus-window --match`）；
   - **Warp / Ghostty / Alacritty** 目前**无**可编程的 tab 选择接口 → 只能停在窗口级。
   逐个评估，不必一次全做。
3. **不建议**：试图找「一套 API 跳所有终端」——上面已论证操作系统层面不存在，投入会打水漂。

---

## 一句话回答用户的原始诉求

> 「这样我就不用专门为不同的 ide 各种别的 terminal 来专门写了」

- **侦测（看状态）**：你已经**不用**为任何终端专门写了——现在就通用。
- **跳转（一键跳过去）**：**窗口级**可以做到「写一次、通用」；**tab/pane 级精确**做不到通用（操作系统的锅），但那是可选的精度增强，不做也不影响核心价值。

**推荐决策**：做第 1 步（通用窗口级 fallback），把「侦测通用 + 跳转窗口级通用」这条线补齐，就基本满足诉求；pane 级精确适配退化成「个别高频终端按需增强」，而不是「每来一个终端就得写一遍」的负担。
