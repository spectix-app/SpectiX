# 每行显示：时间 / token 数据源 + 「当前步骤」副标题 + 行标题

## 行标题（title-<tty>）：三源合成 + 垃圾 prompt 闸（改 title 逻辑前必读）

行标题 = hook（`hooks/spectix-status.sh` 末尾 title 块）写的 `title-<tty>`，App 只读不算。**三个来源协作，`ai-title` 是权威**（2026-09-03 改，见第 2 条），背后全是实测结论，改之前先读：

1. **Claude Code 自带 `ai-title`**（transcript 里的 `{"type":"ai-title"}` 事件，= VSCode 终端 tab 那个 AI 摘要）。**实测三条铁律**：① 落盘有延迟（会话中途才出现），② 相当多会话**从头到尾一条都没有**（不能依赖它），③ **一个会话只生成一次，之后原值反复重复追加、换话题也永不重算**。所以 hook 在每个事件上都查它（PreToolUse 路径 20s 节流，纯 grep/sed），但**只有没见过的新值才允许写入**——`title-ai-used-<tty>` 记录已消费的值，旧值重复追加不许重复写。**它一旦落盘就是权威**，prompt 从此不再改标题（第 2 条）。
2. **用户 prompt** = **兜底**，只在 `ai-title` 还没落盘之前有效。**一旦 `title-ai-used-<tty>` 非空，prompt 就再也不写标题** —— 这样行标题和 VSCode 终端 tab 显示的是同一个字符串。
   - **★ 为什么从「prompt 夺权」翻成「ai-title 权威」（2026-09-03，改这块前必读）**：旧规则是「实质性 prompt 永远夺权」，于是行标题跟的是**用户最后打的那句话**，tab 跟的是**整个会话的名字**，两者本来就不是一回事 —— 实测 15 个活着的终端里 **10 个对不上**（行显示 `1. 修复 2. autorun的时候都不…`，tab 显示 `Autorun log 改进分析`）。用户要的是两边一致，**代价是知情接受的**：`ai-title` 一个会话只生成一次，所以换了话题两边都停在最早那个名字上 —— 但两边一起停，比一个跟一个不跟更容易认。**要翻回话题跟随就得同时放弃对齐，没有两全的第三种**。
   - **落地是两处，第二处最容易漏**：hook 里 prompt 写入前一道 `[ -s "$dir/title-ai-used-$tty" ]`；**全局 `~/.claude/bin/todo.py` 的 `_write_taskbeacon_title` 里同样一道**（第 3 条那条路径根本不经过 hook）。只改 hook 的话，会话中期 `capture` / `claim` 一次就把行标题拽回任务标题、又跟 tab 分家 —— **实测当场踩到**。注意那个函数整体裹在 `try/except` 里，`os.path.getsize` 撞上不存在的文件会被静默吞成 return，把功能整条弄死，所以必须先 `os.path.exists` 再取大小。
   - **改 hook 不会自动纠正已经写歪的现场**：`title-<tty>` 是存量文件，要手工从 `title-ai-used-<tty>` 拷回去（一行 `for` 循环，见下）。
   - 以下三条**只在还没有 `ai-title` 时**生效：**垃圾/触发词 prompt**（`jx`、`jx T37`、`rr`、`done`、`好的`、纯数字选项回答、`bash check`…——正则见 hook 内 python）**只允许给还没有 title 的会话播种占位，绝不覆盖已有 title**（修「jx / 1 / 2 变成 title」bug）。判定：长度 <4，或触发词 + ≤6 字尾巴。
   - **★ 垃圾闸之前先剥 IDE 上下文（T142，改这块前必读）**：编辑器 chat 面板的 prompt 前面挂着**扩展注入的、用户没打过的** IDE 上下文块——`<ide_opened_file>…</ide_opened_file>`、`<ide_selection>…` 等。它们又长又不是触发词，垃圾闸**拦不住**，标题会被写成 `<ide_opened_file>The use`。故在判垃圾之前先 `re.sub` 掉**所有前导 `<tag>…</tag>` 块**，剩下的才是用户真打的字（**经常剥完就空了** → 直接 `exit 0` 不写）。终端会话永远不带这些块，剥离对它是 no-op——这也是为什么这道闸在接入 chat 面板之前不存在。
   - **★ 剥完 IDE 块再剥「拖进来的文件路径」（2026-09-03，改这块前必读）**：往 prompt 里拖一张截图，输入就是一串**带引号的绝对路径**（`'/var/folders/…/Screenshot ….png'`）。它又长又不是触发词，垃圾闸同样**拦不住**，实质性 prompt 直接夺权 → 行标题变成 `'/var/folders/2c/hsqx8tg`，而同会话的 ai-title 明明是准确的（VSCode tab 上就显示着）。故在判垃圾之前把**任意位置**的绝对路径 `re.sub` 掉：带引号的（路径里有空格时的形态）与反斜杠转义的裸路径都剥，**要求至少两段**（`/a/b`）以免把 slash 命令 `/task`、`/jx` 当路径吃掉；`https://…` 因为 `/` 前不是空白而天然不受影响。**剥完常常就空了 → 直接 `exit 0` 不写**，让原本准确的 ai-title 留在原位。同一根因还会污染 `title-ai-used-<tty>` 之外的现场文件，修 hook 不会自动纠正已写坏的 `title-<tty>`——那要手工从 `title-ai-used-<tty>` 拷回去。
   - **★ 注入块的开标签可能带属性（2026-09-12，改这块前必读）**：跨会话消息进到 prompt 里长这样 —— `<cross-session-message from="uds:/tmp/cc-socks/40377.sock" from-name="…" …>`。原来的剥离正则写的是 `<([a-z_][a-z0-9_-]*)>`，**只认没有属性的开标签**，于是整块没被剥掉、`p[:24]` 一刀切下来，收到过跨会话消息的行标题全部变成 `<cross-session-message f`（实测 `title-ttys001` / `title-ttys002` 同时中招，文件大小正好 24 字节）。两处一起修：① 正则允许属性 `<([a-z_][a-z0-9_-]*)(?:\s[^>]*)?>`；② **跨会话消息和 `<task-notification>` 同级**，直接 `exit 0` 不写 —— 那是别的会话在说话，不是这个会话的话题。**这一类已经是第三次**（`<ide_opened_file>` → 拖进来的绝对路径 → 带属性的注入块），判据统一成一句：**prompt 以 `<` 开头就先当注入块处理，别急着当话题**。

3. **`todo.py claim / new-task`**（全局 `~/.claude/bin/todo.py` 的 `_write_taskbeacon_title`）：认领 task/todo 的瞬间直接把任务标题写进 `title-<tty>`——jx 会话不用等 AI 就有准确标题；靠上面的垃圾闸活过后续的 `done`/`继续` 等短 prompt。**同样让位于 `ai-title`**：已有 `title-ai-used-<tty>` 就不写（见第 2 条）。改完这个文件记得重启 `todo.py watch-all` 守护进程。
   - **★ 目录名跟着改名走（改名时必读）**：TaskBeacon → SpectiX 改名时 hook 改成写 `~/.claude/spectix/`，但**全局 `todo.py` 漏改**，claim 的标题继续写进旧的 `~/.claude/taskbeacon/`——App 只读新目录，于是标题全部**静默丢失**，行标题永远停在垃圾闸播种的那个 `jx`。隐蔽在两端都不报错：旧目录里的 `title-<tty>` 时间戳一路在更新，看着完全正常。现在 `todo.py` 的 `_beacon_dir()` 按 `spectix` → `taskbeacon` 顺序探测取第一个存在的目录（同一根因还坑过 owner 存活探测读 `state-<tty>`）。**判据：改状态目录名时先 `grep -rl <旧名> ~/.claude/{hooks,bin}` 把两端一起数出来**——写入方散落在仓外的全局脚本里，只改仓内的 hook 必漏。同类残留见 `session-status.md` 的 `taskbeacon-status.sh`。

### 空闲行的 ` · Chat` 后缀（只在空闲时标，T257）

编辑器 chat 面板的行**一到空闲就和终端行长得一模一样**——都只剩一句 `空闲 ☾zzz`，而它没有 tty 可露出来，两者无从分辨。故 **idle 行（且仅 idle）**在标题末尾加一个淡色 ` · Chat`（`MainWindow.swift` 的 `ChildCell.chatTag(size:)`，被 `idleTitle(chat:)` 和「留着旧任务标题的 idle 行」各接一次）。

- **只在 idle 加**：运行中 / 需确认 / 完成的行有任务标题 + 当前步骤自证身份，再挂一个来源 tag 就是噪音。
- **后缀（用户拍板）**：标题是 `byTruncatingTail`，所以留了旧任务标题的长标题**会把这个 tag 吃掉**——已知代价，真正需要它的是那种只剩「空闲」两个字的行，那里位置绰绰有余。
- **和 header 的 VS 徽章不冲突**：徽章标的是**项目组的宿主**（chat 面板和同 cwd 的终端共用一颗，见 [`header-badge.md`](header-badge.md)），这里标的是**单行的会话种类**。

清除时机：`SessionStart(clear|startup)` 连 `title-ai-used-<tty>` / `title-ai-stamp-<tty>` 一起 rm。隔离测试脚本模式：`HOME=<fakehome> bash hooks/spectix-status.sh <action>` + 假 payload/假 transcript，13 个场景全绿后才部署。

### 分组标题：同名叶子目录要带上一层（T272）

分组标题默认只取 cwd 的叶子目录名，但同一个 repo 的两个 git worktree（`nextad/apps/deal-alarm` 和 `nextad-wt-deal-alarm/apps/deal-alarm`）叶子名逐字相同，两个组会并排出现两个 `deal-alarm`，无从分辨。故标题一律经 `ListModel.folderNames`（原先只有「最近项目」窗口在用，现在两处共用一份）：叶子唯一 → 只显示叶子；撞名 → `<最近一层不同的祖先> / <叶子>`；没有任何单独一层能分开（三份检出、两份同父）→ 退到 `~` 缩写的完整路径。

- **消歧只在撞名时发生**：绝大多数组仍是纯叶子名，没撞名的组一个字都不变。
- **组的身份仍是 cwd**：折叠 / 置顶 / 隐藏 / 拖拽序全部按 cwd 键控，标题只是显示，改名不影响状态。
- 「隐藏」撤销条和右键菜单里的项目名从 header 的 `folder` 读，所以自动跟着变。

## 每列的开关（设置 › 显示 › 列表）

这一列上的**每样东西都可以单独关**，开关按行上从左到右的顺序排在设置里：

| 设置项 | 键 | 默认 | 关掉后 |
|---|---|---|---|
| 工作时长 | `AppSettings.showDuration` | 开 | `⏱ N` 整段不渲染，右边所有列左移 |
| Tokens | `AppSettings.showTokens` | 开 | `◆ N` 整段不渲染，右边所有列左移 |
| 上下文占用 | `AppSettings.contextGaugeStyle` | 胶囊 | `.off` = % 胶囊 / 底部量条都不画，模型列左移 |
| 模型标签 | `AppSettings.showModelLabel` | 开 | chip 零宽，70pt 槽位还给步骤列 |
| 当前步骤 | `AppSettings.showStepLabel` | 关 | 步骤副标题（含 agent 节点的、以及「等待」行的后台命令 / agent 提示）不画 |
| 命令标记 | `AppSettings.showShellBadge` | 开 | 标题右侧的 `bash` 字条不画 |

**列位置是设置的函数、不是行的函数**（`UsageMetricsView.metaColW` / `modelColStart` / `reservedWidth`）——这是整列能对齐的前提，任何「这一行没数据就收缩」的改法都会把它作废。`metaColW`：两项都开 = `pctColX` 96；只留一项 = 48（`◆ 999k` 40.3 + 6 gap）；都关 = 0。开关一变 `AppSettings.didChange` 就发，`SessionListView.refreshItems` 全量重建（渲染签名故意不含设置，见那边注释），设置页的预览卡同步重画并闪一下被改的元素。

两个例外别改回去：
- **desktop 行**（Claude 桌面版那几行）的 meta 是状态短语不是度量列，所以 `configure(freeMeta: true)` 让它保住整格文字槽——它压根没有时长 / token，这两个开关不该动它。**但模型胶囊是例外，它有**（见下面「当前模型」段的 desktop 一条）。
- **`prefixProject`**（按状态分组时的项目名前缀）在 meta 为空（两项都关）时只写项目名，不留 `· ` 尾巴。

## 每行的「时间 / token」数据源（改这块前必读）

行/表头显示的 `⏱ 工作时长 · N tokens` 来自**两个不同的源**，别混：

- **工作时长（时间）**：来自 hook 写的 `events.jsonl`，逐 tty 统计。边界 = **进程启动时刻与最近一次真 `/clear` 里较晚的那个**（`max(processStartEpoch, fileEpoch(clear-boundary-<tty>))`）→ `main.swift` `sessionUsage()`。`session-<tty>` 文件现已无人读取（vestigial）。**`SessionStart(startup)` 绝不许盖边界**——它触发远比真正 /clear 频繁（重连、subagent），拿它当边界会把计数反复砍回近 0（老的「时间没变过」bug）；`startup` 本来就换了 pid，`processStartEpoch` 已经归零它。
  - **口径 = 真正在跑的时间，不是回合开着多久（T146，改这块前必读）**。老口径是 `run.ts → done.ts` 直接相减，那测的是**回合开了多久**：夜里挂在权限弹窗上没人理，第二天回来一点「Yes」，这一觉全算成工作（实测 17 天记了 **295 小时**「工作」，单个回合最长 22 小时）——就是「显示的是开着多久」这个抱怨的根。
  - 现在按**活动脉冲 + 间隔封顶**累加（`Stats.swift` 的 `WorkClock` / `SessionClock`，**三个消费方共用同一份**：行的 ⏱、统计窗的总时长/日·项目桶、统计窗的单任务时长）：
    - **脉冲** = `run` / `tick` / `decision` / `done` 四类事件。
    - **`tick` 是 hook 新加的心跳**：`action=working` 且不是 UserPromptSubmit 的事件（= 每次工具调用的 Pre/PostToolUse）打一拍，**每 tty 60s 至多一条**（`tick-<tty>` 时间戳文件先占坑再写）。**没有它整套就塌**——全程免确认的会话（autorun、白名单命令）中间一条事件都不产，只剩 run 和 done 两个脉冲，会被封顶砍成几分钟。
    - **两档封顶**：紧跟 `decision` 的那段用 `waitGapCap 120s`（弹窗立着、**卡的人是你**，给一点余量就停）；其余用 `workGapCap 1800s`（卡的是机器——长 build、长思考，那确实是在跑，只兜住「回合死了从没 done」的情况）。
    - `run` 撞上还没关的 `run`（Esc 打断、崩了）→ 直接开新段丢掉旧尾巴，不让下一个 done 把中间几小时全吞了。
  - **实测校准**（改参数前先照这个量一遍）：连续干活的会话新旧一致（14m12s → 14m12s，不误杀）；开着 54 分钟但多数时间在等人的会话 18m → 6m。历史数据总量 295h → ~49h（历史里没有 `tick`，所以旧数据仍偏低，往后自然回正）。
  - **`clear-boundary-<tty>` 退役过一次又回来了（T86 删 → T185 恢复），改这块前先读完这条**：它是 `session-<tty>` 的继任者，**只在 `source=clear` 盖戳，`startup` 永不盖**。T86 当时连坐删掉它，理由是「一个会话干一个 task，每做完一个就 `/clear`，⏱ 和 ◆ 于是每次归零」；T185 判定这个理由不成立并恢复了写入，两条依据：
    - **老 bug 的病根在 `startup` 不在 `clear`**。反复把计数砍回近 0 的是被重连/subagent 疯狂触发的 `startup`；`clear-boundary` 正是那次修复的产物，本来就只认真 `/clear`。所以**能删的只有 startup 那一支，clear 这一支是无辜的**。
    - **累计已经有归宿了**：`StatsWindow` / `WorkClock` 读同一份 `events.jsonl` 出按天/项目/任务的历史，且不受这个 boundary 影响。行上那个数字只回答「**这件事**跑了多久 / **这轮**烧了多少」，不该兼职终端累计。
    - 决定性的一条：`/clear` 后标题、步骤、context %、agent 台账、状态**全部**重置，只有 ⏱/◆ 不重置——那一行于是同时在说「这个对话刚开始（0%）」和「已经干了 2.4h」。**同一行里所有数字必须共享同一个区间定义**，这比「哪个区间更好」优先级高。
    - 配套的闸在 `main.swift`：token 的 cwd fallback 判据是 **`usage.tokens > 0 || loggedTokens`**，`loggedTokens` 按 **procStart** 而不是 boundary 扫。少了它，`/clear` 后合法的 0 会被判成「这个会话没日志」→ 回落项目累计，◆ 不但不归零反而**跳成更大的数**。
    - **`model` 不跟着清**（见下面「当前模型」段）：⏱/◆ 是「对某个区间的累加」，区间换了值必须换；`model` 是「当前事实」，区间换了值不变。清它只会用一段「我不知道」换掉一个仍然正确的事实。
  - **in-flight 的活口 run 要在 `working` **和** `needs` 两态都实时累加**（`sessionUsage(inFlight:)` = `status=="working" || status=="needs"`）：`needs`（等确认/plan/AskUserQuestion）时 turn 还开着（run 已记、done 未到，确认后必然 resume 出 done），时钟得继续走。只 gate 到 working 会让行一进 需确认 就把 ⏱ 时间（turn 1 时连整条 usage 行）抹掉——「确认时时间/token/上下文都不显示」的 bug。`paused`（Esc 中断、永不出 done）保持冻结，**不**算进 inFlight。
  - **冻结 ≠ 隐藏（T75）**：正因为 `paused` 不进 inFlight，「/clear 后第一个回合被 Esc 打断」的行 `workSec=0`、`ctx-<tty>` 也还没写 → 旧的 `notStarted`（`workSec≤0 && ctxTokens≤0`）闸把**整列**（⏱/◆/%/模型）抹掉，看起来就是「暂停后这一列没了」。working/needs 有 in-flight 秒数、done 有 done 事件，都躲过了这个闸，所以只有 `paused` 中招。现规则：**只有 `idle` 允许整列空着，其余状态一律显示**（还没数就显示 `⏱ 0s ◆ 0`），单一闸门 = `ChildCell.configure` 的 `showMetrics`。
- **token**：**两级来源，优先精确**（`main.swift` `sessionUsage()` / `loadTokensByCwd()`，行标 `SessionRow.tokensExact`）：
  1. **首选**：`events.jsonl` 的 done 事件按 tty 求和 `tok_in+tok_out+tok_cache_w+tok_cache_r`（同一进程启动边界）。hook 在 Stop 时读 transcript 按轮抓 token——**前提是会话落盘了 transcript**。关键坑：从 Claude Code 会话里启动的 VSCode 会让所有终端继承 `CLAUDE_CODE_CHILD_SESSION=1`，claude 见到它就当自己是子会话、**不写 transcript**，token 抓取全失败。修复 = `~/.zshrc` 里 `unset CLAUDE_CODE_CHILD_SESSION`（已加，2026-07-05），新开终端生效。
  - **整行去重（T191，别删）**：`StatsStore.parse` 逐行入库前先按整行哈希过一道 `seenLines`。**字节完全相同的两行 = 同一个事件被记了两次**（连 token 数都一样），来源是「两个 hook 同时接线」那种窗口期（改名 SpectiX 期间 4780 行里有 493 行重复），读取端拦不住写入端，只能拒绝计它。T180 把历史文件合并去重过一次，这道闸管的是**新产生的**重复。`seenLines` 必须和 `cachedEvents`/`cachedBytes` **一起**清空（增量解析只看新追加的字节，忘了清就会在文件被截断/换路径后把重写的行全当「见过」吞掉）。
  2. **fallback**（该会话日志里没有 token 字段时）：`~/.claude.json` 的 `projects.<cwd>.lastTotal*Tokens` 求和。局限：按**项目 cwd** 键控、只存最近一个 session 的累计值——同目录兄弟 session 显示同一个项目总量；全新 folder 暂显 0。
  - 表头合计（`Components.swift` `totalsText`）：exact 行逐行相加；fallback 行按 cwd 去重，且**跳过已有 exact 行的 cwd**（项目总量涵盖了 exact 会话的消耗，混加会重复计数）。
- **逐行 context 占用 %（行右侧的 `N%` 徽章/量条）**：占用 = hook 写的 `ctx-<tty>`（最后一条 assistant 消息的 input 侧，0 = 无 transcript / 刚 /clear），窗口上限 = `main.swift` `ctxLimit(for:)`（按 cwd 走祖先链查 `.claude.json` 的 `lastModelUsage`，`[1m]→1M / 否则 200k`）。`ctxPct`：`ctxTokens==0 → 0%`；否则 `ctxTokens / limit`。徽章的隐藏（desktop / idle）在**消费端 `MainWindow` `ChildCell.configure`** 处理（`pct = -1`），`ctxPct` 自身永远给真实数字。**「未启动就隐藏」已在 T75 取消**——它误伤了首回合被打断的 `paused` 行；现在 `showMetrics` 只认 desktop 和 idle 两个隐藏理由，%/量条/模型/`⏱·◆` 四样共用它。
  - **关键坑（2026-07-24 修）**：新版 Claude Code **不再逐项目写 `.claude.json` 的 `lastModelUsage`**（6/7 项目是 `{}`，连 `lastTotal*Tokens` 都归 0），祖先链一路 miss 返回 0，旧 `ctxPct` 在 `ctxLimit==0` 时返回 -1 → **凡是已抓到 context 的行（ctxTokens>0）徽章全消失**，而刚开、没抓到 context 的行反而显示 `0%`（诡异对比：同样运行中，A 项目有 %、B 项目没有）。
  - **为什么不能在 hook 端按 model 推 limit**：transcript 的 `message.model` = `claude-opus-4-8`（**不带 `[1m]`**），`[1m]`（1M context 档）是 Claude Code CLI 层标注，transcript / env / settings 都不可靠携带 → hook 端根本判不出 tier，硬推只会把 1M 会话全写成 200k（% 大 5 倍、超 200k 直接 clamp 100%）。
  - **修法（纯 App 端）**：① `ctxLimit(for:)` 祖先链 miss 后**回退账号默认**——`.claude.json` 唯一可靠残留是全局 `~/.claude` bootstrap 目录那条 `lastModelUsage`（带真实 tier）；只要 `byCwd` 里**有任一 1M 项**就判定账号有 1M 权限、未知 cwd 一律默认 1M，否则 200k，全空才 0。② `ctxPct` 在 `limit==0` 时**按占用反推**：`>200k 必是 1M，否则按 200k`，保证**永不隐藏**。这样 1M 用户所有会话默认 1M（正确），200k 用户默认 200k，超 200k 的占用铁定判 1M。
- **★ Codex 行的这三样走完全另一条源（2026-08-30）**：上面整段（`events.jsonl` 的 token、`~/.claude.json` 的 fallback、`ctx-<tty>`、`lastModelUsage` 的窗口推断）**全是 Claude 私有的**，对 Codex 会话一律读空。Codex 的 token / 上下文 / 模型改从它自己的 rollout 文件读，解析在 `CodexSession.swift`，接线在 `fetchRows` 的 `s.kind == .codex` 分支（判据与局限见 [`session-status.md`](session-status.md)「第二种 agent」）。四条要点：
  - 文件路径来自 `tp-<tty>`（Codex 每个 hook payload 都带 `transcript_path`），**不许自己去扫 `~/.codex/sessions/`** —— 那里有几十个同秒写入的迁移诱饵，按 mtime 挑会把终端接到它没跑过的会话上。
  - **上下文占用取 `last_token_usage` 而不是 `total_token_usage`**：后者是累计值（实测最大样本 1112 万 token 对着 25.8 万的窗口），拿它算 % 会直接顶到 100%。
  - **模型胶囊会先空一会儿**：模型名写在每轮开头的 `turn_context`，随后被本轮输出推出 64 KB 尾窗，所以 App 启动时就已经很大的会话要等下一轮才显示出来。这是刻意取舍——从头读的话首行光 `session_meta` 就 180 KB。
  - 胶囊只保留「厂商 + 版本」（`gpt-5-codex` → `GPT-5`），**不带后面的代号**：槽位固定 70pt、现存最宽标签 `Haiku 4.5` 实测 60.7pt，`GPT-5 Codex` 会撑破它——而撑破的后果不是它自己被裁，是把每行对齐用的步骤列一起推歪。
- **订阅配额（header 的「会话 % / 本周 %」）**：来自 `usage.json`（`claude -p "/usage"` 探针 → `spectix-usage.py` 解析）。**双触发**：① hook 在 turn 结束时刷（≥120s 节流）——但长回合进行中永远等不到 done，数字会饿死变陈旧（曾出现「Claude 显示 75%、App 显示 72%」）；② 所以 App 侧补了 `requestUsageProbe()`（`main.swift`）：popover/主窗口**打开时** + **开着期间每次 poll**（≥60-75s 节流）主动发同一探针。两边都先 touch 文件抢占节流窗口，互不重复探测。

## header 的 2×2 指标格（改 header 前必读）

**身份行在上、网格在下**，网格整宽、两张双行卡各占一半：

```
[logo] SpectiX  ……………………  [● 1 ● 2 ● 6]     ← 身份行：logo 在左，状态计数在右
CPU      3.4c  │  🕐 3h20m      左卡 = 这台机器（可点，打开活动监视器）
内存     9.4G  │  📅 5d02h      右卡 = Claude 订阅配额
```

⚠️ **两个宿主的「身份行」归属不同，改之前先认清在改谁**：

- **popover**：身份行**在 header 里**（`HeaderStatsView` 的 compact 分支）—— logo 左、计数胶囊右。
- **主窗口**：身份行是**窗口自己的标题行**（logo + SpectiX 字样 + 计数胶囊，归 `MainWindowController`），所以它的 header **里面只有网格**。计数胶囊别再放回 header —— 那会让它掉到 wordmark 下面单独占一行，和 logo 不同排。

计数的口径只有一份：`CountPill.configure(rows:placeholder:)`，两个宿主都调它。

**别把网格挪回去和身份行挤同一行**：在 popover 宽度下那样会把两张卡压到 bar 归零。

### ⚠️ 手写约束的两个坑（花了五轮才定位，别再踩）

**[1] 从 NSStackView 换成手写约束时，`translatesAutoresizingMaskIntoConstraints = false` 要自己补。**
stack 会替它的成员设这一行，手写约束不会。`MetricLine` 里的 `pctField` / `footField` 就是这么漏的 —— 它们身上还挂着 autoresizing 生成的约束，和手写的打架，整条宽度链解不出来。
**症状离病灶极远**：header 想要的宽度从 ~430 塌成 **51**，而这个窗口是**按内容定宽的**（AppKit 问 Auto Layout 要 fitting width 然后把窗口调成那个尺寸），于是整个窗口被缩到 ~130pt，看起来是「卡片只剩图标」「窗口拖不宽、一直吸在最小值」「最小宽度失效」。**注意它不报约束冲突**，日志里干干净净，所以只能靠量 `fittingSize` 抓 —— 排查手法见下。

**[2] 弹性列要用 `>=` 不能用高优先级的 `==`。**
`MicroProgressBar` 是这一行唯一的弹性列。给它 `width == 100 @ .defaultHigh` 会让窗口**精确吸附**到让它正好 100pt 的宽度（拖宽立刻弹回）—— 因为优先级约束的误差会被布局引擎通过改窗口宽度来消掉。改成 `width >= 60`：超过下限误差为零，没有力量把窗口往里拉，窗口就能停在用户拖到的任何宽度。

**排查手法**（下次窗口尺寸又不对时先做这个，别猜）：在 `reload` 里临时打印
`window.frame.width` / `statsHeader.fittingSize.width` / `contentView.fittingSize.width`。
三个数一对比就知道是「内容不想要那么宽」还是「有人在改窗口」。修好后应为 hdrFit ≈ 351、contentFit ≈ 387。

### ⚠️ 竖排 NSStackView 的坑（四格错位的真凶）

`MetricCard` 里两行**必须各自显式约束到卡片的同两条边**，不许改回 `NSStackView`。曾经用的是竖排 stack + `alignment = .width`，**它不做名字听起来的事**：两行没有填满卡片，而是各自保持固有宽度，结果上行贴左、下行被推到右边，四个量表全体错位。因为**每一列都是从所在行自己的边界量起的**，所以只要有一行没撑满卡片，四行的对齐就一起完蛋。

每行的结构是 `[icon] [pct%] [micro bar] [尾注]`（`Components.swift` 的 `MetricLine` / `MetricCard`）。

**改之前、改之后各跑一次 `./tools/header-preview.sh`**（说明在 `CLAUDE.md`「看 header 三列长什么样」）—— 这块的 bug 全是只有看得见才发现的那类。每张图 10 个镜头：两种宽度 · hover · 主窗口 · **额度打满** · **记着的数字** · **正在取** · **还没读数** · **倒计时好几周** · **本机还没采样**，深浅色 × 两套主题各一张。后六个是拿 `HeaderStatsView.update` 的真参数摆出来的（`live=false` 就是切账号之后 App 真正传的那个值），不是在视图层假装。

**四列全是固定槽位，这是整件事的地基**：pct 30pt、尾注 32pt，两张卡 `.fillEqually` 等宽 —— 于是四条 micro bar 共享同一条左边界和同一条右边界，四行才读成一个网格而不是四个各自为政的 chip。**任何让某一列按内容自适应的改动，会一次性毁掉全部四行的对齐。**bar 是唯一的弹性列（去掉了原来的 ≤48 上限），header 挤的时候由它独自让位。

### 尾注为什么必须是六个等宽字符（2026-09-04 起带斜杠）

尾注用**真正的等宽字体**（`.monospacedSystemFont`），**不是 `Theme.roundedMono`**。后者只给等宽**数字**，而数字从来不是问题 —— **字母才是**：`3h20m` 和 `5d02h` 都是 5 个字符，但圆体里 `m` 比 `d` 宽、`d` 比 `h` 宽，两行的数字于是落在不同的列上，只有整体右边界对得上。

同理，唯一的倒计时格式化器 `resetCountdown`（`fmtResetIn` / `weekRemaining` 都转调它）**一律补齐到 6 个字符**：会话 `3h/20m` / `0h/12m`，本周 `5d/02h` / `9h/24m`；没有重置时刻可算的（窗口还没开始 / 从没记录）用 `unknownCountdown` = `?h/??m`，**不许留空**——空槽读作渲染坏了。斜杠是用户定的（`1h44m` 会被读成一个连体数字）。旧的 `12m`、`5d` 这种短写会把自己那一行的 bar 拽出列。**新增任何尾注格式都要守住这个宽度，包括它的边界情况。** 账号面板里的每账号配额行用的就是同一个 `MetricLine`、同一个 `.trio` 预设（2026-09-10 起不再有单独的 `.panel`，两者本来就只差「尾注开不开」，现在都常开），所以这条规矩也管到那里。

### CPU / 内存这两格

- **数据源**：`SystemLoad.swift` 的 `SystemMonitor`，两个 mach trap（`host_statistics` / `host_statistics64`）。不 spawn、不要权限、不开连接 —— 后者是不联网承诺的红线（README《Privacy: no network》）。
- **CPU 归一化到 0–100**，即 Apple 自己给整机数字的口径（活动监视器的 System + User + Idle 加起来是 100%）。**那套「8 核可以到 800%」的是进程列表的口径**，混进量条会得到一个永远填不满的 bar。实测校准：本公式报 15% 时 `top` 同期报 user 9.46% + sys 7.42%，吻合。
- **CPU 是速率，所以第一次采样只能建基线**，那一格显示 `—`，下一个 poll 才有数。popover / 主窗口打开时会先采一次，把等待从两个 poll 缩到一个。
- **只在有可见 surface 时采样**（`renderRows`）—— 左卡是唯一消费者，窗口关着还采纯属白烧 mach trap。
- **尾注 `3.4c` = 有几个核在忙**（pct × 核数 ÷ 100）。这不是第二次测量，而是同一个数字换成绝对量 —— 补上单一百分比丢掉的那条信息（这台机器有多大）。**在 Apple Silicon 上尤其必要**：那个百分比是「没进 idle 的周期占比」，既不分 P/E 核也不管频率，后台任务全趴在 E 核上时可以读得很高却几乎不占吞吐。
- **内存尾注是已用 GB**，口径 = 活动监视器的 Memory Used（app memory − purgeable + wired + compressed）。**那个减法不能删**：macOS 会主动拿闲置内存做可回收的文件缓存，裸的 total − free 在一台完全健康的 Mac 上就能读到接近 100%。⚠️ 但要知道 Apple 的官方立场更进一步 —— 它说空闲内存根本不是健康指标，该看的是**内存压力**。没用压力是因为它是个只有三档、没有公开公式的枚举，做成尾注等于一个常年不动的死格；所以这一行是「有多满」，**不是**「这台机器缺不缺内存」的判断。

### 三张卡是一个格子里的三列（2026-09-04，用户定）

本机 / Claude / Codex **不再是三张各自带边框的卡**，而是一个圆角外框（`ChipShellView`）里的三列，竖细线画在列与列的交界上。用户原话：「一个大的格子里三个分开放，用竖条隔开」。间距的数字是用户自己在 `design/header-account-quota-5-proposals.html` **第八轮的可调预览器**里拖出来的（2026-09-11）：**列间 0（`MetricCard.seamInset` = 0）+ 卡内边距 5（`MetricCard.trioInset`）**，内容到内容 10pt。之前退回过两版：2026-09-04「间距 0 且没有内边距、线贴着内容」读作挤到一起；2026-09-10 列间 16 / 8（内容到内容 32 / 24）读作「中间空间太多」。**再要调，去第八轮预览器里拖，别猜数。**

三条实现决定，改之前先看：

- **外框是 `QuotaTrio` 的第一个子视图，不是 `QuotaTrio` 自己的 layer。** 把 strip 本身 `wantsLayer = true` 之后（2026-09-04 实测，探针见 git 历史）Auto Layout 只跑一遍：`apply()` 在 `layout()` 里重新分配完宽度，**第二遍 layout 不再来**，三张卡 frame 全是 0×0、内容从 x=0 溢出画在一起。strip 保持普通视图，那一遍就回来了。
- **竖线由每张卡自己画在自己 leading 边外侧 `seamOffset` 处**（`MetricCard.seamless` / `showsLeadingSeam`），不画在外框上：线的位置是列间距的一半，挤的时候间距归零它得跟着回到边缘，卡自己画最直接。（原先还有第二个理由 —— hover 重新分配宽度带动画，外框上的线跟不上；那套 hover 变宽 2026-09-10 已删，见下一节。）
- **挤不下时先牺牲间距**（`apply()` 里 gap 归零，seam 跟着回到边缘）。列有 required 的最小宽，硬塞会让 Auto Layout 放弃宽度约束、三列按固有宽度叠在一起——popover 比主窗口窄 ~100pt，正是这里撞上的。

### 倒计时常驻 + hover 变宽 3:1（2026-09-10 / 09-11，用户定）

三列里的尾注（`3h/20m` 倒计时）原本**平时收成 0 宽、鼠标悬停才展开**，配套「悬停那张卡长到 1.9 份、邻居缩到 0.62 份」的宽度重分配。用户看截图的反应是「中间空的太多」—— 平时那条 bar 独占了尾注让出来的位置，读起来就是一片空。所以：

- **尾注在 `.trio` 里常开**。`footStartsClosed` / `setFootOpen` / `.panel` 预设整套删掉（账号面板行和 header 行现在是同一个 `.trio`）。
- **hover 变宽保留**，但比例改成 **3 : 1**（`QuotaTrio.focusGrow` / `restGrow`），动画 200ms —— 用户在第八轮预览器里试过「关掉变宽」之后明确要它回来（2026-09-10 原话「hover 上去后还是得要扩大」）。尾注已经常开，所以变宽买到的只是更长的 bar。
- **每列的地板 `minCard` 是算出来的**（内边距×2 + 图标 + 3 个间隙 + 百分比槽 + bar 最短 + 尾注槽），不再是手写的 73 —— 改任何槽宽它自动跟着变。现值 = 10 + 12 + 6 + 25 + 6 + 36 = 95。
- **槽宽从预览器的数字往上修了两处**：百分比槽用户选 23、实测「35%」在 App 的圆体里要 25，所以取 25；尾注槽用户选 35、「5d/02h」要 35.5，取 36。**浏览器里的字比 App 窄**，以后从预览器抄数字先用 `NSTextField.intrinsicContentSize` 量一遍（脚本在这次的对话里，几行）。
- ⚠️ **两个槽都放不下自己最长的那个值，都靠「换个写法」解决，不靠加宽**（2026-09-14 修，T313）：
  - **百分比到三位数就去掉百分号**：`100%` 要 32pt、槽是 25，29 的时候也放不下，从来就没放下过。加宽槽会让**每一个两位数**和量条之间空出 6pt —— 正是 09-10 和 09-11 两次被退回的「中间空」；只让这一行的槽变宽，它的量条就会掉出四条量条共享的那一列。`100` 是 22.5pt，放得下，而且这一列每一行都带着百分号、旁边的量条已经满格，那个符号在这里不携带信息。
  - **倒计时满十天就去掉小时**：`26d/09h` 是**七个**字符、要 41.5pt，槽是 36。尾注这个字段抗压缩是 required，所以顶不住的是**槽的宽度约束**，结果两头都坏：实测它拿到 40pt（**从自己那行的量条身上抢走 4pt**，量条就掉出四条共享的那一列），而 40 仍然不够 41.5，**自己还是被切掉 1.5pt**。Codex 就会给出这种值 —— 用户 2026-09-11 那张截图上写的就是 `26d/09h`。改成 `26d`：比六个字符短，但字段在固定槽里右对齐，什么都不会动；到了 26 天，小时本来也没人看。
  - **判据不是「几个字符」而是「量出来放不放得进槽」** —— 新增任何尾注 / 百分比写法，先用 `NSTextField.intrinsicContentSize` 配 `Theme.roundedMono` 量一遍（⚠️ **必须带等宽数字特性**：不带的话 `100%` 量出来是 30.5 而不是 32，会得出错误结论）。

### 为什么没有折叠态了

老的两胶囊横排在 popover 上塞不下，于是有一套「折叠成一枚 + 点击滑动切换」的机制（含滑入滑出动画）。竖着摞成两行之后，「会话」「本周」两个文字标签换成了时钟和日历图标，横向需求直接减半，那套折叠连同动画一起删了。**别再往这里加按宽度隐藏的逻辑** —— micro bar 是弹性列，挤的时候它自己会吸收。

## 第二列 = 一个共享组件 `UsageMetricsView`（改度量行前必读）

`⏱ 时长 · ◆ tokens · % · [模型]` 这一整列**只有一份实现**：`Components.swift` 的 `UsageMetricsView`（列 x、字体、色调、可见性规则、`usageText/pctString/fmtDur/fmtTok` 全在里面）。两个消费方：

- **会话行** `ChildCell`（`MainWindow.swift`）——`usage.configure(meta:pct:model:)`，右边接 `▸ 工具步骤`；变体 C 的右对齐 `%` 和底边量条仍归 cell（它们贴的是卡片边，不属于这一列）。
- **agent 子列表节点** `AgentCell`（`Components.swift`）——同一个组件，所以 agent 行的度量和它挂靠的会话行**逐列对齐、同字体同色**。历史教训：这里曾经是手抄的一份（10pt 灰字、两个空格当分隔、`✦ 模型`是纯文字、裸 `0%`），跟上面一行怎么都对不齐——**任何新列表要显示这一列，用组件，别再抄一份**。

组件对齐的前提是「起点 x 一致」：`AgentCell` 的 `nameLabel/usage` 左边距取 55 = 会话行的标题/度量 x（6 卡片内缩 + 9 rail + 14 + 8 dot + 14 + 10）。
`reservedWidth`（= 步骤列起点）随全局设置整体平移，见下节。

### 子列表 = 会话行那张卡的「agent 段」（T81 · 方案 16）

agent 节点从来就是会话行**同一个 enclosure** 的切片（`.middle` / 末条 `.bottom`，会话行因此不圆自己的下沿）。但光靠共用外框不够——**子列表和会话行连底色都一样，读起来就是「几条矮一点的会话行」，而不是「下一层」**，这正是「agent 列表感觉不明显」的来源。补的两笔（`GroupCard.configure(nested:seamTop:)`）：

- **整段 iris 底**（`Theme.agentSegmentFill`）：`nested: true` 换掉 `cardFill`。CALayer 只有一个 `backgroundColor`，所以是**替换而不是叠加**，alpha 取得比 `cardFill` 略高，让这段和会话行一样亮但明显偏紫。
- **开口一条 iris 接缝**（`Theme.agentSeam`）：只有 `isFirstNode` 那条把顶部发丝线换成紫色，节点之间保持中性 `divider`。段内已经被底色圈住了，每条都上色只是重复画栏杆。

**别改成缩进**（方案 14）：缩进确实是更通用的层级语言，但它把名字/度量/pill 整体右移，直接废掉上一节那套「和会话行逐列对齐」——那是踩过坑才立的规矩。16 是唯一既给出层级、又一列不动的解法。5 个候选方案的完整对比见 `design/agent-sublist-5-proposals.html` 第四轮。

### agent 节点的 `%` = 子 agent 自己的 context（T80 起是真数字）

**曾经恒为 `0%` 占位**（「每个 agent 都 0%」的 bug），现在是实测值，**纯 App 端读取、不用改 hook**：

- **子 agent 有自己的 transcript**（不是写进父会话那份）：`~/.claude/projects/<proj>/<session-id>/subagents/agent-<agentId>.jsonl`，**文件名里的 `agentId` 就是 hook 台账 / `agents-<tty>` roster 里的那个 id**（实测核对过：roster id ↔ 文件名 ↔ 父 transcript 里 tool_response 的 `agentId` 三者同一个值），所以 roster 一行直接就能拼出路径。
- **路径来源**：`tp-<tty>`（hook 每个事件都盖的父 transcript 路径）去掉 `.jsonl` 后缀 = 那个 `<session-id>/` 目录 → 拼 `/subagents/agent-<id>.jsonl`。每个会话只读一次 `tp-<tty>`，不是每个 agent 读一次。
- **占用口径和会话行完全一致**：最后一条 assistant 消息的 input 侧（`input_tokens + cache_read + cache_creation`），即 hook 算 `ctx-<tty>` 的同一个定义 → `main.swift` `agentCtxTokens` / `lastCtxTokens`（tail 尾部 256KB 反向扫；usage 块很胖，窗口比 `lastModel` 那个大）。
- **实时**：文件随 agent 干活增长，所以**运行中**的节点百分比会一路往上爬，不用等它返回（对比 `◆ tokens` 只有返回时才被 hook 盖上）。
- **窗口上限沿用父会话的 `ctxLimit`**：子 agent 的 tier（`[1m]`）任何地方都读不到，且不带 `model` 参数的 agent 本来就跑父会话的模型。显式指定别的模型族时可能偏，`ctxPercent` 的「>200k 必是 1M」自升级兜底。
- **未知一律隐藏，不再假装 0%**：`AgentInfo.ctxPct` 在 `ctxTokens == 0`（没 tp 指针 / 文件还没出现 / 解析不出）时返回 **-1** → `PctCapsule` 空着。刚派出去、还没产出第一条回复的 agent 就是这个状态，几秒后自动有值。
- **缓存**：`agentCtxCache`（key=agent id，stamp=`size|mtime`），同 `liveModelCache` 的理由——一个回合内 FSEvent 刷新极频繁，不缓存就每次给每个 agent 重扫尾部；已返回的 agent 文件不再变，永久命中。id 会随时间累积（roster 会 prune、缓存不会），超 512 条整体清空。
- 顺带修的重复读：`row.agents` 先建、`backgroundAgentCount(tty:roster:)` 复用它的条数，不再把 `agents-<tty>` 每轮解析两遍。

`ctxPercent(tokens:limit:)`（`main.swift` 文件级函数）是会话行和 agent 节点**共用**的换算，两边口径一致；「限额未知就按占用反推」的逻辑只有这一份。

### agent 节点的职位 tag（`AgentTag`）——右列，不是名字的尾巴

`subagent_type` 那个小 tag **右对齐贴在状态 pill 左边**，和 pill 一起组成右侧「属性带」（`design/agent-name-tag-5-proposals.html` 方案 5）。**别再把它挪回名字后面**：跟着变长的名字跑，四个 agent 就是四个不同的 x，纵向没有列可循——这正是当初「看起来太乱」的原因，不是信息太多。三条配套规则同样别回退：

- **0.22 底 + 0.48 描边**：一度试过「无描边 + 0.12 淡底」求安静，结果 9pt 字在玻璃上直接糊没了——**安静 ≠ 看不见**，别再往下调。
- **砍前缀**：`worker-coder`→`coder`、`manager-frontend`→`frontend`、`general-purpose`→`general`；约定外的类型（`Explore`、项目自定义的）原样显示，截断它等于瞎编语义。
- **家族色 = 按命名前缀，不是按状态**（状态归右边的 pill，同一条边上再放个状态色的东西只会打架）：`worker-*` 鸢尾紫 `Theme.agentAccent`、`manager-*` 青 `Theme.agentManagerAccent`、其余中性冷灰 `Theme.agentNeutralAccent`。一眼数清这批 agent 里几个 worker 几个 manager，不用逐个读字。第三档**必须是实色**、不能用 `.secondaryLabelColor` 这类语义色——tag 的字/底/边都由同一个 tint 派生，语义色自带 alpha，再乘一次就洗没了。

没有 `subagent_type` 时整块 **塌成零宽**（`chipCollapse`，同 `pillCollapse` 的路子），不是隐藏了还占着 padding。配套地 `AgentTag` 内部的左右 padding 约束降到 `.defaultHigh`，否则 required 的 padding 会和零宽打架。

**节点之间画分隔线**：每个 `AgentCell` 都传 `topDivider: true`（含子列表第一个——那条线把子列表和它挂靠的会话行分开）。不像 `ChildCell` 的 `!isFirst`：agent 节点比会话行矮、字更小，没有线就糊成一整块。

## 「命令标记」：标题右侧的 `bash` 字条（改这块前必读）

**前台**跑命令时**状态不变**——仍是蓝的 `运行中`。字条只回答「这个『在跑』是哪种跑」：在想事情/写代码，还是在等一条命令。所以它**不是状态色的第二个出口**，也**不能跟着 `当前步骤` 一起关**——步骤列默认就是关的，那才是这个字条存在的理由。

> **两个词：`bash`（前台在跑）和 `shell`（后台还有命令活着）。** `shell` 曾在 T312 被删，理由是「后台命令已经有自己的状态『等待』，药丸在说同一件事」——**2026-09-12 恢复，那个理由站不住**：药丸说的是「在等」，没说**等的是什么**。等后台 agent 的行有 🤖 ×N 徽章，等命令的行删掉字条后**什么都不剩**。
>
> **本该解释这件事的副标题救不了场**：它挂在步骤列上，而 `applyRoom()` 在弹窗宽度下只剩约 45pt、步骤列地板是 60 —— 整列直接不画。**字条在这份预算里排第一顺位**，是窄行里唯一活得下来的东西（用户当场问「在等待什么？我没有看到有 shell 的标记」）。

- **两个词、一个源**（`MainWindow.swift` `ChildCell.configure` 的 `cmdTag`）：
  - `bash` = `status == "working"` 且 `step-<tty>` 是 `Bash` 或 `Bash · …`（前台 Bash 工具在飞）。
  - `shell` = `bgShells > 0`（后台命令还活着）。这一行同时就是「等待」状态，两者**不冲突而是互补**：药丸说「在等」，字条说「等的是一条命令」。
  - **判据是精确前缀 `Bash` / `Bash ·`，不是 `hasPrefix("Bash")`**：`BashOutput` / `KillShell` 是在**伺候后台那条命令**，让它们显示 `bash` 会在轮询输出时把字条来回抖。
- **位置 = 右侧属性带再往左一格**：`shellTag.trailing → agentBadge.leading`，而原先所有停在 `agentBadge.leading` 的东西（标题 / 度量块 / 变体 C 的 `%` / 步骤列）现在停在 `shellTag.leading`。折叠规则照抄 🤖 徽章：**宽 0 + gap 0**，于是没命令在跑的行和加这个字条之前**像素一致**。
- **宽度不够就整条不画（T256，和步骤列同一套 floor）**：字条要 `shellSlotW = 52`（两个词 + padding + 6pt gap，**常量**，理由同 `rightSlotW`——逐行测量会让同宽度的两行给出不同答案）。窄窗口硬塞进去，那 52pt 是从标题 / 度量列里抠的，字条在、被它注解的那行反而被压扁，看起来就是「bash 基本看不到」。
  - 分配顺序写在 `applyRoom()`（原 `applyStepRoom`，现在两个 floor 都归它）：**先给字条，剩下的才轮到步骤列**（字条更小，且它的存在意义就是活过「当前步骤」默认关掉）。给了字条就从 `room` 里扣掉再判步骤。
  - 判定只在 `layout()` 里做（`configure()` 跑在还没定尺寸的复用 cell 上，且窗口 resize 不会重新 configure）；`configure()` 只记 `wantsShell` 意图，末尾顺手跑一次。翻转前比 `shellShown` 防抖——这段每个 layout pass 都跑，约束不能反复重设。
  - 曾经试过**堆叠到 pill 下方**（不占横向）：pill 得上抬 9pt 才居中，字条出现/消失时整个 pill 上下跳，用户判「不好看」，已撤。
- **样式 = 复用 `AgentTag`**（0.22 底 + 0.48 描边的同一个配方），尺寸小一号（9.5 / 15 / 6）——它和状态 pill 共处一条边，同尺寸会读成「两个 pill」。**色用蓝 `Theme.shellTagAccent`**（2026-08-26 用户定，此前是中性冷灰 `Theme.agentNeutralAccent`——灰得几乎看不见）。⚠️ **是它自己的一档蓝，不是 `Status.accent("working")`**：字条和状态 pill 共处一条边，借状态色会和旁边的 pill 撞成两颗一样的东西。所以它走 palette 里的独立 token（`ThemeSpec.shellTagAccent`，两个主题各给一档，**明暗分开取**——同一个蓝不可能既在暗底上够亮又在亮底上够深），不参与用户的状态色 override。这条规矩本身没变：状态色仍然只归 pill。
- **不进步骤列的宽度地板**：`applyStepRoom()` 的 `room` 故意不减这个字条的宽度。地板只能是「窗口宽 + 全局设置」的函数（见上文），而字条是**逐行**的——算进去会出现「同一窗口宽度下 A 行有步骤列 B 行没有」。窄窗口下字条挤到步骤列时，由 `stepLabel.trailing ≤ shellTag.leading` 让步骤自己截断，这和 🤖 徽章挤它时的处理一致。
- **设置页预览**：`PreviewSessions` 第一行（working + `Bash · git push`）出 `bash`；第三行是 `await` + `bgShells: 1`，展示的是「等待」状态本身，不再出字条。

## 每行的「当前模型」（usage 行末尾的带底色胶囊）

usage 行的**最后一列** = 该会话**当前用的模型**（`SessionRow.model`，已 humanize 成 `Opus 5` / `Sonnet 5` / `Haiku 4.5`），排在 `%` 之后：`⏱ 12m · ◆ 56k · 62% · [Opus 5]`。位置方案见 `design/row-model-label.html`。

- **形态 = 带底色胶囊**（`ModelChip`，`Components.swift`）：文字用族色、底是同色 0.18 淡洗，材质/尺寸（10pt bold + 左右 6pt padding + 高 16 + 全圆角）**照抄邻居 `PctCapsule`**，两个 chip 读起来是同一族。**没有 `✦` 图标**——有底色已经把它和裸的 ⏱/◆ 数字分开了，胶囊里再塞字形只会挤。空串 → `intrinsic .zero` 整个消失。
- **为什么它不能像 ⏱/◆ 那样待在度量文字里**：`%` 是一个**独立 view**（`pctCapsule`）夹在中间，attributed string 没法绕着兄弟 view 排版。所以模型必须是自己的一个 view，钉在自己的列上。
- **开关**：设置「显示」段 →「模型标签」（`AppSettings.showModelLabel`，默认开）。关掉 → chip 收成零宽，那 70pt 让给 `▸ 工具步骤`。整列开关总表见开头「每列的开关」。
- **desktop 行也有模型胶囊**（`showModel = showMetrics || r.isDesktop`，`MainWindow.swift`）：⏱/◆/% 对桌面版都是假的（没有 hook、没有 token 数据），但模型是**直接从那个窗口自己的模型选择器读出来的**（`main.swift` `axFindModel`，按 wid 缓存、30s 一刷；两种写法 `Model  Opus 5` / `Model: Opus 5 High` 都要认）。所以这一格对桌面版是真的，别跟着别的度量一起关掉。桌面版为什么没有用量数据见 [`desktop-app.md`](./desktop-app.md)。

**颜色 = 模型族语义色**（`Status.modelTint(_:)`，按 label 首个单词判族）：**Opus 紫 `#b39df8`** / **Sonnet 青 `#5ad1c8`** / **Haiku 琥珀 `#f0b866`**（深色值取自设计页第二轮；浅色模式同 `claudeOrange`/`usageGreen` 的做法用同色系加深版）。**认不出的族回落中性灰**，绝不借用三色之一——这三个颜色是「这是哪个族」的断言，把未知模型涂成紫的等于说谎。这三色不是会话状态色，**不进** `Status.accent` override 体系。

- **三级来源，优先实时**（`main.swift` `fetchRows`）：
  1. **首选（T76 加，实时）**：**直接 tail 该 tty 的 transcript**——hook 每次事件把 payload 的 `transcript_path` 写进 `tp-<tty>`（`atomic_write`，一行路径），App 在 `liveModelKey(tty:)` 里读文件**尾部 256KB**、反向找**最后一条非 sidechain** 的 `"model":"claude-…"`。`/model` 切换只要产生一条 assistant 消息就反映出来（一次刷新内，2.5s 轮询或 hook 写文件触发的 FSEvent，**不用等回合结束**），新 tab 第一次回复就有标签。
     - **必须排除 sidechain**：subagent 的回合写进**同一个** transcript（`"isSidechain":true`），它可能跑在别的模型（如 haiku）上，取「最后一条 assistant」会把父会话标成 subagent 的模型。
     - **缓存**（`liveModelCache`，key=tty，stamp=`path|size|mtime`）：一个回合内 FSEvent 刷新极频繁，不缓存就每次给每个会话重扫尾部。nil 结果同样缓存（miss 和 hit 一样贵）。只在 `fetchRows`（串行 `scanQueue`）里访问，故无需加锁。
  2. **fallback**：`events.jsonl` 里该 tty **最后一条 `done` 事件**的 `model`（hook 在 Stop 时从 transcript 抓）。tp 指针丢失 / transcript 被删时接手。故意**不**按 `clear-boundary` 裁剪——`/clear` 换的是对话，不是模型。
     - **★ 但必须按「这条 done 是不是本会话写的」裁（2026-08-30 修，改这一级前必读）**：tty 比会话活得久，终端会被反复复用。实测 `ttys007` 01:47 还在 TaskBeacon 上跑 Fable、20:29 已经换成另一个项目跑 Sonnet，而新会话跑完第一轮之前上面两级都空 → 裸的「该 tty 最后一条 done」把**另一个项目几小时前的 Fable** 贴到了那个项目的行上（用户原话「我明明用的是 sonnet 5」）。现在这一级要求 `done.ts ≥ 本 claude 进程启动时刻`；进程启动时刻读不到（`procStart == 0`，时间判据形同虚设）时改用 `done.cwd == 会话 cwd` 兜底。`UsageEvent` 为此补了 `cwd` 字段（旧日志行没有 → 可选，缺了就退到下一级）。
  3. **末级 fallback**（该 tty 从没跑完过一轮 / 无 transcript）：`~/.claude.json` 的 `projects.<cwd>.lastModelUsage`（忽略 haiku 那把后台模型），走**祖先链**上溯（同 `ctxLimit(for:)`，Claude Code 常把条目记在 monorepo 根上）。**注意这一级已大面积失效**——新版 Claude Code 多数项目该字段是 `{}`（实测 8 个项目只有 2 个有），这正是 T76 之前「新 tab 没标签」的根因。**没有账号级默认兜底**——`ctxLimit` 缺失时宁可猜（否则量条消失），模型缺失时宁可留空（猜错等于在行上写一个确定错误的模型名）。
  - 只认 `claude-` 前缀：`<synthetic>`（本地非 API 回合）不许覆盖上一个真模型。
  - `/clear` 时 hook 一并 `rm tp-<tty>`（跟 `ctx-<tty>` 同批），避免指着上一个会话的 transcript。
- **`modelLabel(_:)`**（`main.swift`，纯函数，有 11 例自测跑过）：family = 第一个**非数字**段、version = 所有数字段用 `.` 连——所以 `claude-opus-4-8` → `Opus 4.8`，旧式 `claude-3-5-sonnet-20241022` → `Sonnet 3.5`（若按「第一段就是 family」会变成 `3 5.sonnet`）。尾部 8 位日期段丢掉；`[1m]` **一律剥掉**：只有 `.claude.json` 的 key 带它、`events.jsonl` 的 transcript id 从不带，留着会让同一会话的 label 随「哪个源答的」跳变。窗口大小已由 % 表达。
- **列宽（`UsageMetricsView`，`Components.swift`）**：整块预留宽 152 → **214**（`reservedWidth`），子列 `timeColX 42 / pctColX 96`（不动）`/ modelColX 144`。x 全是**量**出来的不是拍脑袋：`⏱ 1.8h` 34.8 → 42；`◆ 999k` 40.3 → 82.3 → % 落 96；% 胶囊最宽 41.0（`100%`）→ 137，+7 → 模型落 144；最宽胶囊 `Haiku 4.5` 60.7（旧式 `Sonnet 3.5` 67.5）→ 70pt 槽位 → 214。
  - 模型列**恒定预留**（未知时只是空着，不逐行收缩）——固定子列存在的意义就是 `▸ 步骤` 在每行从同一个 x 起排，逐行变宽等于把这件事作废。但**按样式/开关整体平移**是安全的（样式和开关都是全局的，所有行仍然一致）：变体 C（底部细条）没有内联 % 胶囊，chip 收拢到 `pctColX`；关掉「模型标签」则连槽位一起还给步骤列（组件内 `modelFixedX` + cell 的 `stepLeading` 两个 constant 各自在 `configure` 里读 `reservedWidth` 刷新，`modelSlotW = 70`）。
  - 两条 `≥` 兜底（`modelChip.leading ≥ pctCapsule.trailing + 6` 和 `≥ 度量文字 trailing + 6`，固定 x 用 `defaultHigh` 让位）：三位数 `%` 或 status 分组模式的项目名前缀把前面撑长时，宁可挪列也不许重叠。整块宽度本身是 `defaultLow` 的 `reservedWidth`——内容撑不下时块会变宽（列往右挪），有 `▸ 步骤` 同行时 cell 用 `usageWithinColumn` 把它卡回步骤起点，改由文字截断。
  - 代价：`▸ 工具步骤` 列起点右移 62pt，长步骤更早截断（MarqueeLabel 悬停可滚）；popover 缩到最窄 384pt 时步骤只剩约 46pt——嫌挤就关「模型标签」。
- 派生 row 要记得带上：`applyAck` 的 `seen` / `applyChecking` 的 `checking` 都显式 copy `model`（漏了 → ack 后模型标签消失）；`SessionListView` 的行签名也含 `r.model`，否则模型变了不重绘。

## 「当前步骤」副标题（终端会话 working 时）

会话 `working` 时行副标题从 `⏱ 时长·tokens` 切换成**当前工具步骤**（如 `▸ Edit · main.swift` / `▸ Bash · Push branch`），让你不进终端就知道它在干嘛。

- 来源：hook 写的 `step-<tty>` 文件。**PreToolUse** 用纯 sed 抽 `tool_name` + 关键 arg（Read/Edit/Write→文件名、Bash→description（**故意不用 command**，多行带引号做标签太丑）、Grep/Glob→pattern、Task→subagent_type、Web*→query/url）拼成一句。放在 state 写入之后（off 关键路径，不拖慢变色）。
- 清除时机：**UserPromptSubmit**（新回合还没工具）/ **Stop** / **SessionStart(clear|startup)** → `rm step-<tty>`，避免上一个工具残留。
- App 侧：`main.swift` `sessionStep(tty:)` 读取；`SessionRow.step`；`ChildCell.configure` 仅在 `status=="working" && !step.isEmpty` 时用 step 顶替 usage 行（`stepText()`，working 蓝色调，grapheme-safe 截断）。
- **窄窗口下的宽度地板 + 悬停全文（T153，改这块前必读）**：步骤列起点固定（`stepLeading` = meta 起点 + `reservedWidth`）、终点在 pill 之前，所以它的宽度 = **窗口宽剩下的那点**。默认设置下 `剩余 ≈ 窗口宽 − 359`，于是 **384pt（出厂就是最窄）时剩余 ≈ 25pt 甚至负数 → 这一列一个字都画不出来**，这正是「标签位置不够就直接没有显示了」那条抱怨。三条修法（`MainWindow.swift`）：
  - **地板**：`ChildCell.applyStepRoom()`，剩余 < `stepMinW` 60pt 时整列**直接不画**，而不是渲染一条读不出内容的碎片。默认设置约 **≥419pt 才画**；关掉「模型标签」后 `reservedWidth` 降到 144，门槛跟着降约 70pt——这就是本文档下面那条「嫌挤就关模型标签」的出路。
  - **地板只能是「窗口宽 + 全局设置」的函数**，右边 pill 槽位写死成常量 `rightSlotW 62` 而**不读本行 pill 的实际宽度**：状态词中英文宽度差很大、且 🤖 徽章会整体替换 pill，按行实测会出现「同一个窗口宽度下 A 行有步骤列 B 行没有」，等于把上面「列位置是设置的函数、不是行的函数」那条作废。判定放在 `layout()`（bounds 才可信；窗口 resize 不触发 reconfigure），不放 `configure()`。
  - **设置页的预览行豁免**（`ChildCell.enforcesStepFloor`，`SettingsLivePreview` 置 false）：预览行是 mock，存在的意义就是展示开关指向的那个元素，窄设置窗里被地板砍掉会让「当前步骤」这个开关没东西可预览。
  - **静止态出 `…`**：`MarqueeLabel` 的 `field` 加了 `restCap`（`field.width ≤ 容器宽`）+ `lineBreakMode = .byTruncatingTail`，所以放不下时结尾是省略号而不是从半个字中间硬裁——`…` 本身就是「悬停有更多」的提示。悬停时 `restCap` 关掉、field 回到自然全宽，跑马灯才有东西可滚（滚动 span 直接读 `field.frame.width`，所以约束状态和 span 用的是同一个数）。
  - **整行 tooltip 兜底**：`ChildCell.configure` 末尾把「完整行标题 + 度量行 + 完整步骤」拼成多行 `toolTip`，**挂在 cell 自己身上而不是某个 label**（`hitTest` 把卡片内任意点都收给 cell）。所以列被地板砍掉、或标题/步骤被截断时，内容都没丢，悬停即可读全。参照 `StatsWindow.taskRow` 的同类做法（密集列表 = 截断 + tooltip，**不**做 FocusRing 那种就地展开：64pt 固定行高展开会顶开每一行）。`idle` 行只有「空闲」两个字，不挂 tooltip。
- **开关**：设置「显示」段 →「列表」组 →「当前步骤」（`AppSettings.showStepLabel`，**默认关**）。它只管 working 的**实时工具步骤**。关掉 → 工具步骤不画，行退回稳定的 `⏱ 时长 · tokens`。
  - **★ 后台提示也归这个开关管（2026-09-12 用户拍板，改这块前必读）**：挂在「等待」行上的那句（后台命令 → `后台命令 · N 个 shell 运行中`；后台 agent → `后台 agent · N 个运行中`，T314 起同一条路径，时长取最早那个还没回来的 agent）**跟着开关走**：开了才画，关了整列不出现。**同日上午曾刻意豁免过**，理由是「等待」只换了行的颜色、开关关着时行不说自己在等什么；用户当天下午推翻——原话「setting 有开就显示，没有就不显示」，写着「当前步骤」的开关关掉后屏幕上还留着字就是个坏开关（和下一条 agent 子列表同一个判据）。关掉后「等待」药丸和它的颜色照常在，只是不再解释等的是什么。
  - 默认关的理由：这是行上最跳动的文字（每次工具调用都变），且后台 shell 那条只要命令没退就一直挂着。
  - **同样管住 agent 子列表**（2026-08-01 改）：`AgentCell` 的步骤列（含已返回节点的 `✓ 已返回`）也读这个开关。**曾经刻意豁免**，理由是「步骤是展开子列表的核心内容」——但一个写着「当前步骤」的开关关掉后屏幕上还留着步骤，就只是个坏开关。关掉后 agent 行右边仍有 运行/完成 pill 说明状态，信息不丢。
