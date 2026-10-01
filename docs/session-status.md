# 🧠 核心机制：会话状态判定（改这块前必读）

> 这是本 App 的心脏。判定错了整个产品就没意义。排查状态相关 bug 一律先回到这里。

## 状态从哪来

不读 transcript。**状态来自 hook 写的按 tty 命名的文件**：`~/.claude/spectix/state-<tty>`，内容是 `working` / `done` / `needs` / `idle` 之一。

**★ 为什么不读 transcript（2026-08-03 实测修正，改这块前必读）**：
理由**不是**「transcript 不存在」——旧表述说「v2.1 daemon 不再为活跃终端会话写可发现的 `<session>.jsonl`」，**实测已证伪**：6 个活会话里 5 个都有对应 jsonl 且在实时更新（忙碌会话 mtime 仅 22–42 秒）。
真正的理由是 **transcript 是滞后的副产品，且恰好在最关键的时刻静止**：会话卡在权限弹窗上时 transcript **根本不再更新**（实测两个 `waiting` 会话分别静止 591s / 668s）。靠「最近 N 秒有没有新条目」判活性的实现，只能推出「闲置」，推不出「在等你」。
实测佐证：c9watch（transcript 路线）在 transcript 龄 >30s 时 **0/27 全部误判为闲置**，断崖精确落在其源码的 30 秒阈值上；在 18 次真正 `waiting` 的观测里**一次都没报出「需要你」**。完整数据见 [`launch/12-accuracy-benchmark.md`](../launch/12-accuracy-benchmark.md)。

- hook 脚本：`hooks/spectix-status.sh`（真身在 `~/.claude/hooks/spectix-status.sh`，由全局 `~/.claude/settings.json` 注册。同目录下的 `taskbeacon-status.sh` 是改名前的残留，**没有被注册**，改错了不会生效）
- App 读取：`main.swift` 的 `sessionStatus(tty:)`
- 按 **tty** 键控，不用 env / sessionId——实测依据见 [`CLAUDE.md`](../CLAUDE.md)「键控原则」：`CLAUDE_CODE_SSE_PORT` 确被同窗共享（按它键控会塌缩），`sessionId` 会在同一进程内漂移（按它键控会把一个终端切成多条记录）。tty 在整个终端生命周期内恒定。
  > ⚠️ 旧表述「`CLAUDE_CODE_SESSION_ID` 会被同窗共享、把兄弟会话塌缩成一个」**实测未能复现，已删**。

## hook → 状态 映射

| Claude Code hook | 写入状态 | 颜色 | 含义 |
|---|---|---|---|
| `UserPromptSubmit` / `PreToolUse` | working | 蓝 | 模型在忙 |
| `Stop` | done | 绿 | 轮次结束，该你了（台账非空 → App 渲染成青「等待」，见 ★T314）|
| `PermissionRequest` | needs | 红 | 权限弹窗出现（实时） |
| `PreToolUse` 且 tool=`AskUserQuestion`/`ExitPlanMode` | needs | 红 | 停下等你答/批准 |
| `Notification`（含 `needs your permission/approval` 文案） | needs | 红 | 仅老版 Claude Code 的兜底（会 debounce ~2-4s；已经是 needs 就 **不重写**，见下「每次弹两次」注） |
| `Notification`（`notification_type=idle_prompt`）且**当前是 needs/working**、且**台账为空** | paused | 洋红 | 中断恢复信号：Esc / Ctrl+C / 拒绝权限**不发任何 hook**，靠这个 idle ping 反推「这一轮被打断了，没完成」 |
| `SessionStart`(clear/startup) | idle | 灰 | 会话清空/新开 |

> idle ping 的其余情况**一律不写**：台账非空（后台 subagent 在跑，不是中断，见 ★T314）→ 原样保留；当前是 done/idle（安静的行）→ 直接 exit，绝不凭空 repaint（「闲置突然变绿」bug）。
> 老版 Notification 兜底那条的 **`[ "$(cat state-$tty)" = "needs" ] && exit 0`** 不能删：新版 Claude Code 对同一个弹窗**两个事件都发**（PermissionRequest 秒发 + Notification 约 6s 后补），重写会重放提示音、重复计数，更要命的是**刷新 state 文件 mtime** —— 而那正是 App「外壳必须启动晚于 needs」时刻守卫的基准线，6s 内已确认的话命令外壳反而变成「早于」被挡掉，行从蓝弹回红并再弹一次 toast（「每次弹两次」bug）。

## 第二种 agent：Codex CLI（2026-08-30 接入，改进程发现前必读）

列表里不只有 Claude Code 了。Codex CLI 的会话走**同一条状态链**，因为 Codex 自带一套和 Claude Code 同构的 hook 系统（实测 codex-cli 0.151.0：`hooks.json` 结构逐字相同，事件名 `PreToolUse` / `PostToolUse` / `PermissionRequest` / `SessionStart` / `SessionEnd` / `UserPromptSubmit` / `Stop` 全都在，另有 `PreCompact` / `PostCompact` / `SubagentStart` / `SubagentStop` / `Interrupt`）。

**`spectix-status.sh` 一个字节都没改，两边共用同一份。** 这不是省事，是硬约束：

> ⚠️ **Codex 有信任闸门，按脚本内容 hash 记账**（`~/.codex/config.toml` 的 `[hooks.state]`）。未被批准的 hook **静默不执行**。改脚本 = 所有已装用户的 Codex 侧当场失效，且没有任何报错，直到他们自己去跑 `/hooks` 重新批准。**要改这个脚本前，先想清楚这一条。**

实测确认（2026-08-30，隔离 pty 上跑 `codex exec`）：Codex 触发 hook → 脚本沿父链解析出 tty → 正常写 `state-<tty>` / `title-<tty>` / `tp-<tty>`。**按 tty 键控对 Codex 原样成立**，这是整套接入的地基。

### 进程发现

判据在 `AgentKind`（`main.swift`）：**可执行文件名恰为 `codex` + 有 tty + argv 里没有子命令**。

- 名字：Codex 的 argv[0] 是绝对路径（`…/vendor/aarch64-apple-darwin/bin/codex`），所以比的是 `lastPathComponent`。
- **有 tty**：ChatGPT.app 和 VSCode 扩展各自**自带一个 `codex` 二进制**跑 `app-server`，全都没有 tty。它们的 argv 是 OpenAI 的、随时可能变，tty 这一条不受影响，所以两道判据都留着。
- **无子命令**：`codex exec` 是唯一会**带着真 tty**出现的非交互形态（脚本化跑批），只靠 tty 判据挡不住它。
- npm 装的是「node 包装器 + 原生二进制」两个进程共用一个 tty，但包装器的 argv[0] 是 `node`，天然不匹配，**不会重复出行**。

### 哪些能力对 Codex 关掉了，以及为什么

| 能力 | Codex 行 | 原因 |
|---|---|---|
| 状态（working/done/needs/idle） | ✅ 全同 | hook 同构，`PermissionRequest` 比 Claude 的 `Notification` 兜底语义还干净 |
| 标题 / 当前步骤 | ✅ 全同 | 同一个 hook 写的同一批文件 |
| token / 上下文 / 模型 | ✅ 走另一条源 | 见下 |
| **忙碌探测（「确认」盲区那一套）** | ❌ 关掉 | **实测 2026-08-30：Codex 把工具命令作为自己的直接子进程 spawn**（`sleep 12` 的 ppid 就是 codex 二进制），没有 `sh -c`、没有 shell snapshot 可 source，下面那套签名一条都匹配不上 |
| daemon 三分支补盲 | ❌ 天然失效 | 读的是 Claude daemon 的 `~/.claude/sessions/<pid>.json`，Codex pid 没有对应文件 |
| 后台 subagent 台账（🤖 徽章） | ❌ 天然为空 | `agents-<tty>` 由 Claude 的 Task 工具记账，Codex 的 `SubagentStart/Stop` 没接进来 |

> ★ **不要**把忙碌探测「放宽成：Codex 就数任意长命子进程」。签名存在的意义正是排掉长命子进程 —— MCP server 也是长命子进程，数上它会让一行**永远**停在蓝色，那比它要修的 bug 更糟。Codex 行因此只靠 hook，和编辑器聊天面板是同一种取舍（见下「无 tty 会话」的局限表，那些局限对 Codex 行同样成立，**未实测，按同构推定**）。

### token / 上下文 / 模型：读 Codex 自己的 rollout

Codex 在**每个 hook payload 里都给 `transcript_path`**，hook 原样写进 `tp-<tty>`，指向 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`。解析在 `CodexSession.swift`（尾部 64 KB 倒读 + 按 path memo）。

**★ 一定要用这个指针，不许自己去扫 `~/.codex/sessions/`**：那个目录里全是诱饵 —— 导入别家 agent 配置时会在同一秒批量写进几十个 rollout，按 mtime 或「最新那个」挑，会把一个终端接到它从没跑过的会话上。

口径两条（都已实测）：
- **上下文占用取 `last_token_usage`，不是 `total_token_usage`** —— 后者是累计值，最大的样本 1112 万 token 对着 25.8 万的窗口。
- `rate_limits` **可能是 null**（`codex exec` 会话就没有），所以配额四个字段全是 optional。

**已知局限**：`turn_context`（模型名的出处）每轮开头写一次，随后被本轮输出推出 64 KB 尾窗，所以**模型胶囊对一个「SpectiX 启动时就已经很大」的会话会先空着，等它下一轮才补上**。解法只有从头读（首行光 `session_meta` 就 180 KB），每秒读那么多不值，接受。

## ★ 关键难点：「确认」盲区（这是最容易出 bug 的地方）

实测事件顺序：

```
PreToolUse        → working(蓝)     命令准备跑
PermissionRequest → needs(红)       权限弹窗出现
   ★ 用户点「确认」★                ← Claude Code 在这一刻【不发任何 hook】！
PostToolUse       → working(蓝)     命令【跑完】才发
```

**Claude Code 在承认的瞬间没有 hook。** 承认后唯一能把红改回蓝的是这条命令的 `PostToolUse`，而它只在命令**结束**时发。
→ 后果：`npx expo start` 这类**前台长命令**，跑多久 state 文件就红多久（「确认过了还是红」的 bug）。

## 解法：App 侧「忙碌探测 + 时刻守卫」

真相在进程树里。Claude Code 跑 Bash 工具 = 在 `claude` 进程下 spawn 一个命令外壳 `zsh -c '...eval 命令...'`（常驻的 `sourcekit-lsp` / `caffeinate` **不带 `-c`**，天然区分开）。

`main.swift` 的 `runningToolShells(claudePid:since:)`：**当某行是 `needs` 时**，去 `claude` 的直接子进程里找命令外壳（`zsh`/`bash`/`sh` 且含 `-c`）。找到 → 说明弹窗已消失、命令在跑 → 渲染成蓝，而不是红。

**但只有外壳还不够**——会踩「残留进程」误判：一个 session 可能有个**以前的 dev server 外壳还活着**（残留），同时又弹了个**新的、真在等你确认的**弹窗；光看有没有外壳会把红误判成蓝。

**时刻守卫（决定性判据）**：
- 刚承认跑起来的命令，其外壳一定在 **`needs` 写入之后**才 spawn。
- 残留 dev server 在 `needs` **之前**就存在。
- → **只认「进程启动时刻 > state 文件 mtime（= needs 写入时刻）」的外壳。** 残留进程时刻更早，自动排除。

实现：`processStartEpoch(pid)`（进程启动 epoch，来自 `proc_bsdinfo.pbi_start_tv*`）对比 `fileMTime(state 文件)`。

**★ hook 外壳排除（「闲置/需确认行时不时闪蓝」bug 的根因）**：
Claude Code 跑 **hook** 用的外壳和跑 Bash 工具一模一样（`sh -c ~/.claude/hooks/….sh …`，有时带 snapshot 包装），同样是 `claude` 的直接子进程。停在弹窗上的会话每隔几秒收到 idle-ping/Notification hook——这个短命外壳的启动时刻**必然晚于** needs 写入，天然满足时刻守卫，被误判成「确认后在跑的命令」→ 行闪蓝几百毫秒后弹回。其他会话越忙 → state 写入越频繁 → App refresh 越密 → 撞上概率越高（看起来像「被别的终端影响」，实为采样频率效应）。
→ 修复（`runningToolShells`）：① argv 含 `.claude/hooks/` 的外壳直接跳过；② 外壳必须已存活 ≥1s 才算数（真命令轻松超过，1s 延迟感知不到；短命 helper 壳永远不够格）。

## 后台 subagent 台账（记账机制；颜色语义见 ★T314）

> **★ T54 → T314：颜色又改了一次（改这块前必读）**：这条路径的颜色改过三次。最早：Stop 时台账非空就涂 `working`（蓝）。**T54 反转**成 `done` 绿 —— 后台 subagent 不占用主循环，它在跑时你照样能直接和 AI 对话干别的，所以不是「忙」。**T314 再改**（2026-09-12 用户提出）：绿也不对 —— 绿 + 「完成」横幅 + 完成音三样一起在说「该你了」，而所有 agent 回来之前没有任何事轮到你，会话会被 task-notification **自己唤醒**接着跑。∴ 台账非空时那一行显示 **`await`（青「等待」）**，和 T312 给后台 Bash 的是同一个第五状态，只是信号源不同（这边读台账文件，那边探活进程）。
>
> **三处落法**：① **hook 仍一律写 `done`**（state 文件里只有五个 hook 状态，`await` 永远不出现），颜色由 App 定 —— `main.swift` 在 `row.bgAgents > 0` 且状态是 done/idle 时改成 `await`（needs 不动：后台 subagent 等确认优先级更高）；② **完成音 / 手表推送走同一条台账闸门**（hook 的 `case "$state" in done)` 前置 `[ -s "$bgfile" ] ||`）—— 屏幕上不说「完成」，耳朵里也不能说；③ **`await` → `done` 不弹横幅**（`notifyTransitions`）：那不是一次新的完成，state 文件还是等待开始前那次 Stop 写的同一个 done，变的只是最后一个 agent 走了，而会话紧接着就会自己醒过来；真正的新完成一定先经过 working，那一跳照常弹。
>
> **★ 计数取 roster 不取裸台账**：`backgroundAgentCount` 优先读 `agents-<tty>`，roster 里的 agent 在**它自己的 transcript 结束轮次**时就被摘掉 —— 不用等唤醒销账、也不用等 600s sweep，所以一个漏销的幽灵 id 钉不住一行青色。只有装着老 hook（没有 roster 文件）时才回退到裸台账，那种情况仍由 sweep 兜底。
>
> 台账同时喂 🤖 ×N 徽标（任意状态都显示，表达「N 个 agent 在跑」）+ 销账/sweep。下面「记账/销账/sweep」逻辑照旧。

主会话用 Agent 工具派后台 subagent 时，**主回合会立刻 Stop**（进入「Waiting for background agent」），agent 继续在跑。实测事件序列（trace 抓的）：

```
PreToolUse(Agent) → PostToolUse(Agent, 秒回, tool_response 带 agentId)
→ Stop                       ← 盲区起点：涂绿但其实在等 agent
→ …subagent 自己的工具调用也会打到本 tty 的 hook（PreToolUse 等）…
→ UserPromptSubmit           ← agent 完成，task-notification 唤醒（prompt 以
                                <task-notification> 开头，<task-id> == agentId）
```

修复（hook 侧台账 `bg-<tty>`，一行一个未完成 agent id）：
- **记账**：PostToolUse 且 tool=Agent/Task 且 **payload 带 `agentId`** → 追加该 `agentId`。**★ 判据是 agentId 的存在，不是 `run_in_background:true`**（改这块前必读）：实测本 harness 把**每个** Agent/Task 都当异步跑（立即返回 agentId + 靠 task-notification 唤醒），但**只有显式传 `run_in_background:true` 时 PostToolUse 才带那个字段**——不传时 payload 是 `bg=no aid=yes`。老代码卡 `run_in_background:true` → 这些不带 flag 的异步 agent 全部漏记 → 台账恒空 → 主回合 Stop 直接涂 done → **「一个 subagent 完成就弹 complete」bug**。带 agentId = 会有 task-notification 回来唤醒，销账用同一 id 键，天然配对。
  **★ 但 agentId 已不再等价于「异步」（2026-08-04 实测，改这块前必读）**：**同步** Agent 调用（显式 `run_in_background:false`）阻塞到 agent 跑完，然后返回**同一个 agentId**——它**已经结束**，永远不会有 task-notification 回来销账。记它 = 一条永不消失的「运行中」幽灵 + 虚高的 🤖 ×N，只能等 stale sweep 十分钟后收尸。两者靠 launch 的 `tool_response.status` 区分（两种真实 payload 实测）：`async_launched` → 记账；`completed` → **跳过**。
- **Stop（★T54 起不再改写颜色；★T314 起颜色由 App 定）**：Stop 一律写 `done`，台账非空也照写；台账非空时 **App 把那一行渲染成 `await` 青「等待」**（见本节顶部 ★T314），hook 侧只多做一件事 —— **这次 Stop 不放完成音、不推手表**。台账保留供 🤖 徽标 + 销账用。〔历史：T54 前这里台账非空会改写成 `working`（蓝）+ step「Agent · 后台任务运行中」〕
- **销账**：唤醒的 UserPromptSubmit **移除 payload 里出现的每一个 `<task-id>`**（不只最后一个）。批处理唤醒（多个 agent 在会话忙时一起回来）会把多个 `<task-notification>` 塞进同一个 UserPromptSubmit——老代码单条 sed 只抓最后一个 `<task-id>`，其余卡在台账里（行永远卡蓝）。现用 `grep -oE '<task-id>…'` 抽全部逐个删。后台 Bash 的通知 id 不在账上，天然 no-op。**★ 销账的致命前提（改这块前必读）**：销账只在 task-notification **作为一次独立的 UserPromptSubmit hook 事件触发脚本**时才跑——而这只发生在唤醒通知到达时主会话**空闲、需要被唤醒成新一轮**。若通知在主会话**正忙于一个回合**（连续跑工具）时到达，它只是被**注入当前回合的上下文**，**不产生独立的 UserPromptSubmit hook** → 销账根本不执行 → id 残留（被 kill 的 agent、回合中途完成的 agent 都会漏销）。「边忙边派 agent」是这个漏销的高发场景。→ 兜底全靠下面的通用 stale sweep。
- **安全阀（★T54 起台账非空 = 保留状态，不再涂蓝）**：idle-ping 到达时**台账为空**才走 paused/idle 判定；**台账非空**说明后台 subagent 还在跑 → **保留当前状态**（Stop 已写的 done，App 渲染成青「等待」）且不清账，既不涂 working（T54 不算忙）也不翻 paused（agent 在跑不是中断，「subagent 在跑却显示暂停」的修复）。SessionStart(clear/startup) 仍无条件清账，兜底 agent 被 kill 没通知的卡账。〔历史：T54 前这里台账非空会保持 `working`（蓝）〕
- **通用 stale 台账清账**（「僵尸台账钉住忙碌会话」+「完成的会话卡成 working/暂停」bug 的修复）：剩余 id **心跳停滞 >600s** 说明它是**僵尸**（agent 被 kill/崩溃/漏销，永不销账）。
  **★ 逐 id 判活，不是整本台账一刀切（2026-08-04 改，改这块前必读）**：老判据看 **`bg-<tty>` 文件的 mtime**——一个 mtime 代表所有 id，两头都错，且方向相反：① **任何一次新 launch 都会重写台账刷新 mtime**，于是几分钟前漏销的 id 看起来永远「新鲜」，在一个持续派 agent 的会话里**僵尸永不清**（🤖 计数只涨不落，实测两个已结束的 agent 一直挂着）；② 反过来，**一个合法跑过 600s 的长 agent 会把整本台账拖下水**——老代码是 `rm` 掉台账 + roster + 全部 step 文件，把还活着的兄弟 agent 一并抹掉。现在每个 id 有自己的心跳，可信度从高到低：**① `agent-step-<tty>-<id>` 的 mtime**（该 agent **每次调工具**都重写它，真在干活的 agent 无论跑多久都在刷新）→ **② roster 里的 `start`**（还没调过工具的 agent）→ **③ 台账 mtime**（兜底，即老行为）。只有自己心跳冻结 >600s 的 id 被摘掉，存活的兄弟留在账上；**台账被摘空时**才写 `done`（有幸存者则不动状态行）。**★ sweep 位置（改这块前必读）**：这个 `ledger_age >600s → rm 台账 + atomic_write state=done` 现在放在**脚本顶部**（SessionStart 分支之后、状态解析之前），**每次非-SessionStart hook 事件都跑**——不再只在 idle_prompt 分支。原因：漏销高发于「持续忙碌」的会话（见上一条），而忙会话**永远进不到 idle_prompt 分支**（那需要会话静止），老代码把 stale 清理只放在 idle_prompt 里 → 忙会话的僵尸台账**永驻**（曾出现 4-id 台账钉住正在忙的会话、直到会话 idle 才清）。提到顶部后，忙会话的每个 working/Stop/tool 事件都会顺带 sweep，僵尸 >600s 即清。**清账时写 `done`（不是 paused）**：台账非空证明 Stop 早已发生（agent 是回合内派的），真相是「完成」而非「被打断」；写 done 同时**修好 idle_prompt else 分支**——僵尸被顶部清后，若残留 state 是 working，idle_prompt 的 else 会误判 paused，顶部预先写 done 让它读到 done 直接保持。idle_prompt 分支里原来的 stale 子分支已随之删除（顶部覆盖，冗余）。误清可自愈：真有 straggler 晚回来，其 task-notification re-log run 重画行。600s 覆盖合法长 subagent。曾出现一个 18-id 台账卡 2h 把已完成会话钉成 working/暂停。
- 唤醒 prompt 不写行标题（否则标题会变成 `<task-notification> <tas…`），但**照记 run 事件**——App 的 run→done 配对靠它算唤醒后那段工作时长
- 局限 v1：Workflow 工具的后台运行不记账（完成通知的 id 格式未验证）；bg agent 等待期间的时长/token 不计入统计（subagent transcript 是独立文件）

### per-agent roster（T49 展开 sublist 的数据源）

台账只有 id；「每个 agent 是谁、在干什么」由两组伴生文件承载（同生共死于台账的清理点：SessionStart clear/startup、>600s stale sweep）：

- **`agents-<tty>`**（JSONL，一行一个 agent）：launch 时（PostToolUse Agent/Task 带 agentId）从 tool_input 抄 `subagent_type`/`description` 写 `{id,type,desc,start}`；retire（唤醒 UserPromptSubmit）**直接删掉那一行**（并删它的 step 文件），台账被删空则连文件一起 `rm`。手搓 JSON：type/desc 写入前 strip 反斜杠和双引号。
- **★ 完成的 agent 立刻从列表消失（2026-08-18 改，改这块前必读）**：老做法是 retire 盖 `end`+`tokens` 保留该行、UI 显示「✓ 已返回」，等**下一次 launch** 再 prune 掉 done>300s 的旧行 —— 于是「不再派 agent 的会话，那几行永远挂着」。更糟的是 **retire 本身要等唤醒送到 UserPromptSubmit**，也就是**等用户下次敲字**：会话闲着时 agent 早就跑完了，UI 还把它画成蓝色运行中（实测现场 `agents-ttys003` 的行无 `end`，而它的 transcript 早已 `end_turn`）。现在**两条独立信号，谁先到算谁**：① **App 读 agent 自己的 transcript 尾部**，最后一条 assistant 消息的 `stop_reason != "tool_use"`（即 `end_turn`/`max_tokens`…）就是「这个 agent 的回合结束了」—— 这是**唯一在会话闲置时也能即时到达**的信号，读不到 `stop_reason` 一律当作还在跑（**绝不猜掉一个活着的 agent**）；② hook 的 retire 删行（台账追平）。App 侧同时丢弃任何带 `end` 的行，这样旧 hook 写的台账也不会再显示僵尸。**连带**：`AgentInfo` 不再有 `end`/`tokens`/`running` —— 列表里只可能有运行中的 agent，节点恒蓝、⏱ 一直在走、◆ 显示它自己的 context tokens。**徽标计数**只在**台账文件不存在**时才回退 `bg-<tty>`（不能在「过滤后为空」时回退，否则刚跑完的 agent 会变成一个点开是空的 🤖 ×1）。**读 agent transcript 必须先 `resolvingSymlinksInPath`**：resume/fork 出来的会话，`subagents/` 里是**指向原会话的 symlink**，属性读不跟随 link → 拿到的 size/mtime 是 link 的、永远不变 → 缓存永久命中，第一眼看到的状态就再也不更新了。
- **`agent-step-<tty>-<id>`**：**实测 subagent 的每个工具事件 payload 自带 `agent_id`（== 台账 agentId）+ `agent_type`**（2026-07 验证），所以 PreToolUse 能按 agent 归属 —— 共享 step-<tty> 照旧写（行副标题跟最新活动），同时镜像一份进该 agent 自己的 step 文件；retire 时删。
- **★ 自愈补记（「agent 在跑但列表里没有」bug 的修复，2026-08-04，改这块前必读）**：roster **只在 launch 那一刻写**，所以它一旦丢失就**永远不会重建**——漏记的 launch、SessionStart 清账、stale 误清，任何一条路径丢了 roster，这个 agent 在它剩余的整个生命里都不会再出现在 UI 上，哪怕它每隔几秒还在调工具。**病征是一个孤儿 `agent-step-<tty>-<id>` 在持续刷新，旁边却没有 `bg-<tty>` 也没有 `agents-<tty>`**（实测现场：agent 已跑 5 分钟、transcript 还在长，UI 里一个 agent 都不显示；App 的 `backgroundAgents()` 只读 roster，读不到就等于不存在）。修复：**subagent 的工具事件本身就是「它还活着」的铁证**——PreToolUse 拿到 `agent_id` 时若发现它不在台账上，就地把台账 + roster 补回去，下一次工具调用 UI 即恢复，**不管当初是被谁弄丢的**。`type` 取事件自带的 `agent_type`；`desc` 只存在于已丢失的 launch payload 里，故留空由 UI 回退到 type；`start` **不stamp当前时间**，而是取该 agent transcript（`<父 transcript 去后缀>/subagents/agent-<id>.jsonl`）的**创建时间**，否则每个被恢复的 agent 的 ⏱ 都会从 0 重新计。正常路径上零成本：id 在账上就跳过整段，只花一次 `grep`。
- App 侧：`backgroundAgents(tty:ctxLimit:)` 把 roster + step 文件拼成 `SessionRow.agents`（只留运行中的，见上条），驱动点击 🤖 徽标展开的 agent sublist（AgentCell，设计 `design/agent-sublist-5-proposals.html` 方案 9）。每个 agent 的 context 占用与「跑完没有」由 `agentTail(parentTranscript:agentId:)` **一次扫描**同时得出。
- **per-agent context %（T80）**：roster 的 `id` **就是**子 agent transcript 的文件名（`<父 transcript 去后缀>/subagents/agent-<id>.jsonl`），所以 App 用 `tp-<tty>` + roster id 就能读到每个 agent **自己的** context 占用，**hook 不用管**（它只在 retire 时盖累计 token）。口径 / 缓存 / 未知隐藏见 [`docs/row-display.md`](row-display.md)。
- 已知缺口：通知在主回合忙碌时到达 → 不触发独立 UserPromptSubmit → retire 不跑（与台账漏销同源；2026-08-04 实测轻易复现：「边忙边派 agent」时通知只是被注入当前回合，销账根本不执行），agent 在 sublist 里保持「运行中」直到 stale sweep 按**它自己的心跳**清场（逐 id 判活后这个兜底才真正生效——老的整本 mtime 判据在持续派 agent 的会话里永远清不掉它）；per-agent 等确认（daemon waiting 是会话级）不显示。

## daemon session status 补盲（三个 hook 结构性看不见的盲区）

> 起初只为修「后台 subagent 等确认却显示在跑」，后来又接管了另外两个**同源**盲区——**「答完还红一会儿」**和**「拒绝/中断后一直红」**。共同点：这三种情况 Claude Code 都**不发任何 hook**，state 文件因此停在过期值，只有 daemon 知道真相。判定链见下面的三分支表。

台账防住了「subagent 在跑却显示完成」，但防不住反向的盲区：**后台 subagent 请求权限时，Claude Code 不发 PermissionRequest hook 到主 tty**（实测：主会话 Stop 进「Waiting for background agent」后，subagent 弹权限确认，events.jsonl 零 decision、state 文件不更新）。hook 侧没有任何信号 → state 被台账钉在 `working`（蓝），用户以为在跑就不管，subagent 一直堵在等确认。同理适用于后台 subagent 的 AskUserQuestion / ExitPlanMode。

修复靠 hook 之外的第二信号源：**Claude Code v2.1 daemon 为每个活会话写 `~/.claude/sessions/<pid>.json`**，含 hook 看不到的 `status` 字段——`busy`（模型在忙 / 已确认命令在跑）/ `idle`（轮次结束等你下一句）/ `waiting`（卡在待你响应的交互，同级 `waitingFor` 说明是什么："permission prompt" / 问题 / plan）。实测对照：正常 done→`idle`、模型忙→`busy`、**只有卡着等你交互才 `waiting`**。

- App 侧 `daemonSessionStatus(_ pid:)`（`main.swift`）：按 **pid** 键控读 json（pid 每进程唯一，和 tty 一样不塌缩兄弟会话，符合本项目键控原则；不用 sessionId），返回 **`(status, updatedAt)` 元组**——`updatedAt` 来自 json 的 `statusUpdatedAt`（**epoch 毫秒**，读出来除 1000 转秒，才能直接和 `fileMTime` 比大小）。另外校验 json 里的 `pid` 字段确实等于本 pid（防串号）；文件缺失/解析失败返回 `("", 0)` → 降级到 hook 判定。
- **★ 判定链是三条分支，不是一条**（改这块前必读）。`fetchRows()` 拿到 hook status 后**最后一步**跑，放在 `runningToolShells` 探测**之后**（所以残留 dev-server 外壳的误判压不过它）。三条按序 if/else：

  | daemon | 附加条件 | 结果 | 修的是什么 |
  |---|---|---|---|
  | `waiting` | 无 | 强制 `needs`(红) | 后台 subagent 等确认（本节主题）。凡「等你选择 / 回复 / 确认」daemon 都标 waiting |
  | `busy` | 当前是 `needs` **且** `updatedAt > state 文件 mtime` | 改 `working`(蓝) | **「答完还红一会儿」bug**：你答完 AskUserQuestion / 批完 plan / 点了确认后模型进入思考，这一步**不发任何 hook**（要等下一个 PreToolUse），state 被钉在 needs 红整个思考期；`runningToolShells` 也救不了——模型在推理，还没 spawn 任何外壳。daemon 一答完立刻翻 busy，故「busy 写入比 needs 写入新」= 已答、活儿续上了 |
  | `idle` | 当前是 `needs`/`working`、**`bgShells == 0`**、且 `updatedAt > state 文件 mtime` | 改 `paused`(洋红) | **「拒绝后一直红」bug**：拒绝权限（No/Esc）或中途 Ctrl+C **零 hook**，state 永远卡在 needs/working（实测有会话红了 49 分钟，hook 侧的 idle_prompt→paused 兜底并没有触发）。hook 还说忙、daemon 已经 idle = 这一轮是被打断的，不是完成 |

  **两条守卫缺一不可**：
  - **`updatedAt > mtime` 时刻守卫**（两条分支都要）：不比时刻就会拿**陈旧的** daemon 状态盖掉**新鲜的** hook 状态。① 弹窗刚冒出来时 daemon 还停在弹窗**之前**的 busy（比 needs 写入旧）→ 不带守卫会把该红的行刷成蓝；② 一轮刚起步时 PreToolUse 刚写完 working、daemon 还停在上一轮的 idle（比 working 写入旧）→ 不带守卫会把刚跑起来的行闪成「暂停」。另外点「确认」走的是 waiting→**busy**（永远不经 idle），所以正常确认绝不会误触发 paused 那条。
  - **`bgShells == 0`**（只 paused 那条）：双保险，绝不把「后台命令还在跑」读成暂停。`bgShells > 0` 已在上游强制 `await`（T312）、根本进不到这个 needs/working 分支，守卫留着兜底。
- 局限：daemon-detected 的 needs 不经 hook → events.jsonl 不记 decision，统计漏这类后台确认（次要）；`waiting` 语义按「只出现在 pending 交互」采样得出，若未来 daemon 用 waiting 表示某种不需响应的等待需再收窄。
- **★ 监听 sessions 目录（「暂停后不立马高亮」bug 的修复）**：`paused`（中断 = No/Esc/Ctrl+C）**不发任何 hook**，只有 daemon 改 `sessions/<pid>.json` → 老代码只在 2.5s dataTimer poll 才读到 → 暂停高亮（`flashPaused`）最多迟 2.5s 才画。修复：`startStateWatcher` 的 FSEvents watch-paths 加 `sessionsDir`，再对 `sessionsDir` 起一个 kqueue `startDirSource(create:false)`（daemon 目录非我方所有，`create:false`；缺失就跳过 kqueue 靠 FSEvents 兜）。daemon 一改状态即触发 `refresh()` → `notifyTransitions` 秒画 paused 环。watcher 共用 `refresh()` 的 burst 合并（`refreshGen` 头尾守卫），daemon 高频写不会压垮。
- **★ 监听器会跳过两类「跟行无关」的写入（2026-09-24，CPU 修复）**：`terminals-*.json` / `window-*.json`（VSCode 插件每窗口每 2 秒的心跳，读方按 mtime 判活，**所以插件不能改成「内容变了才写」**）和 `*.log`（我方自己的 diag 日志）。以前它们每写一次就触发一整轮全机进程扫描，实测 20 秒 85 次写入里占 55 次，是 dev 版 6 天烧掉约 5 小时 CPU 的主因。判定在 `AppController.isWatcherNoise`；这些文件仍由 2.5s dataTimer 读到。**往这个目录新加一种「行依赖的」文件时，别用 `window-` / `terminals-` 前缀或 `.log` 后缀**，否则它的变化要等最多 2.5 秒才上屏。同一轮还给 `processArgs`（按 pid + 启动时刻 + 可执行名缓存，exec 会换可执行名所以它必须在键里）和 tty 名加了缓存。

## ★ 陈旧度闸门：两个信号一起静止时（2026-08-25，改这块前必读）

上面所有机制都建立在「至少有一个信号源还在动」上。**两个一起停下来时，整条判定链集体投蓝。**

实测现场：一个会话派出两个后台 agent 后主回合结束，**唤醒通知没送达** → 主会话再没产生过任何消息 → hook 一个事件都不发（`state-` / `step-` / `tick-` / 台账全部冻在同一分钟）；同时 `sessions/<pid>.json` 记的是**最后一次状态变化而不是心跳**，于是它也冻在同一个 `busy` 上。结果那一行**显示了六天的蓝色「运行中」**，而它台账上那个 agent 早就 `end_turn` 了。

三道兜底为什么一道都没接住：

| 兜底 | 失效原因 |
|---|---|
| hook 的 >600s 僵尸台账 sweep | 挂在「下一次 hook 事件」上跑。零事件 → 永不执行，台账里的 id 六天后还挂着 |
| `runningToolShells` 忙碌探测 | 只在 `status == "needs"` 时才进（见上「忙碌探测 + 时刻守卫」节），冻住的行是 `working`，整段不进 |
| daemon 三分支 | 没有分支匹配 `busy` + `working`；且两条带守卫的分支都要求 `updatedAt > state mtime`，而 state 文件也停了 → **补盲机制恰好在会话冻死时集体退场** |

**根因不是哪条分支写错，而是 `working` 从来没有陈旧度闸门**——`done` 从第一天就有（`fileMTime < launchTime → idle`），`working` 一个都没有，所以六天前写的 `working` 和一秒前写的在 App 眼里完全一样。蓝色的语义是「在忙，别管它」，**误报的代价就是用户真的一直不管**。

修复（`main.swift`，判定链的最后一步，daemon 三分支之后）：

```swift
if status == "working",
   now - fileMTime("state-<tty>") > 600,
   now - daemon.updatedAt > 600,
   runningToolShells(claudePid: s.claudePid, since: 0).count == 0 { status = "paused" }
```

- **必须两个信号都陈旧，不是任一**：只要还有一个在动就保持蓝。长思考期不发工具事件、但 daemon 会翻 busy；长 Bash 不发 hook 流量、但留着活的命令外壳——两种合法的「安静地忙」各由一条守卫接住。
- **外壳探测放最后**：它是进程扫描，前两个 mtime 比较在健康行上直接短路掉它，正常路径零额外开销。
- **600s** 对齐 hook 自己的僵尸台账 sweep 阈值，两边口径一致。
- **桌面版行不受影响**：`desktopRows()` 是独立路径，`append` 在 `sessions.map` 之后，压根不经过这道闸门。
- **聊天面板行只剩两个条件把关**：它们的 daemon json 没有 `status` / `statusUpdatedAt`（见下节局限表），`daemon.updatedAt` 恒为 0 → 那条守卫恒真。可接受——聊天面板的 hook 信号本身是正常的（下节实测），state mtime 可信。

### ★ 判成 paused 之后：必须把它摘出注意力池（改跳转 / 高亮前必读）

**这一条比闸门本身更容易出人命。** `paused` 是跳转的**最高优先级桶**（`AppSettings.jumpStatuses = ["paused","needs","done"]`、`jumpAutoDefault = ["paused","needs"]`），而所有池都是**严格分桶**——`.first { !$0.isEmpty }`，高优先级桶一旦非空，低优先级桶**根本不参与**。

冻死的行按定义**永远不会离开 paused**（离开只有一条路：那个 tty 写出新 state，而它已经不发 hook 了）。所以如果放任它待在池里，**一行冻死的会话就能让整个跳转系统瘫痪**：

- 真正的红色「需确认」永远跳不到（热键和自动跳转都被钉在 paused 桶）
- 闲置自动跳转每个闲置周期抢一次屏幕，跳去一个死了几天的终端（`idleJumpedIds` 每次有输入就清空，所以会反复抢）
- 自动回原处永久失效（`maybeAutoReturn` 的 `attentionLeft` 含 paused，永远提前 return）

∴ `SessionRow.isFrozen` 标记这一类，`SessionRow.awaitsYou`（= `needs || paused` **且非 frozen**）是唯一的注意力池判据。**新增任何「哪些行在等我」的地方一律用 `awaitsYou`，不要再写 `status == "needs" || status == "paused"`。** 两个按 status 字符串分桶的跳转池另外显式带 `&& !$0.isFrozen`。

冻死的行**不画洋红高亮圈**（`flashPaused`）：它不是刚发生的中断，没有即时性；而且它指向的终端可能早被复用，圈会落到无关的 pane 上。颜色、统计条分段照常按 paused 走——它看起来仍然是洋红「暂停」，只是不再和活的待办抢注意力。

### 闸门的已知局限（都已实测确认，接受不修）

| 局限 | 后果 | 为什么接受 |
|---|---|---|
| **系统睡眠 ≥10 分钟**（合盖）会让所有 mid-turn 的行在唤醒瞬间同时满足前两条 | 唤醒时可能几行一起短暂翻洋红 | 判据用的是墙钟，排除睡眠要引入单调钟 + 每行观察戳。而合盖时那些回合大多**确实**被打断了，判 paused 语义并不错；就算错了，下一次工具事件就刷回蓝，且 frozen 行已被摘出注意力池，代价只剩颜色闪一下 |
| **登录 shell 不是 zsh/bash/sh**（fish / nushell） | 该用户的前台长命令数不到外壳，跑过 600s 会被判 paused | `runningToolShells` 的进程名白名单是既有判据（不是这道闸门引入的），改它要连带重验「确认后长命令在跑」那条主路径。本机无法复现，不盲改 |
| **hook 停写但会话仍在跑工具**时可能频闪 | 有外壳的瞬间翻蓝、外壳一消失又翻洋红，几秒一个来回 | 需要「hook 坏了但 Claude Code 还活着」这种双重异常才成立，属次生场景。frozen 行不画圈，所以频闪只影响列表里的颜色 |


## 无 tty 会话（编辑器聊天面板）的键控与已知局限

> VSCode 侧栏 / 新 tab / 新窗口里的 Claude Code 聊天面板。**它整条父链一个 tty 都没有**（`claude → Code Helper (Plugin) → Code → launchd`），所以上面「按 tty 键控」那套对它不成立，靠一条回退分支接住。

**信号本身没问题，缺的只是键**：实测（2026-08-05，2.1.222）聊天面板发的 hook 与终端会话**逐个一致**（`UserPromptSubmit` / `Stop` / `PreToolUse` …），只是 hook 老代码 `[ -z "$tty" ] && exit 0` 把它整个丢掉了。故两侧各改一处，键换成 **`pid<PID>`（claude 进程自己的 pid）**：

| 侧 | 位置 | 做法 |
|---|---|---|
| hook | `hooks/spectix-status.sh` 的键解析块 | 爬父链时**先找 `ttys*`**，命中即 `break`；只有整条链无 tty 才回退成第一个 `comm == claude` 祖先的 `pid<PID>`；两者都没有仍 `exit 0` |
| App | `main.swift` `discoverSessions()` | `--output-format` / `--input-format` 从**无条件排除**改成**有条件放行**：daemon json 声明 `entrypoint` 前缀 `claude-vscode` 且 `kind == "interactive"` 才放行（`isEditorChatSession`）。`LiveSession.tty` 对它填 `pid<PID>`，与 hook 对齐 |

- **★ 顺序是本特性的回归底线（改这块前必读）**：终端会话链上**也有** `claude` 进程，一旦把 pid 分支提到 ttys 分支之前，全部历史 `state-ttysNNN` 当场失效、所有行状态错乱。ttys 必须先命中并 `break`。附带好处：终端会话第一跳就 break，那次多问一次 `comm` 的 `ps` **根本不执行**，终端路径零额外开销。
- **`-p` / `--print` 的排除必须原样保留**：我们自己的 `claude -p '/usage'` 探针靠它挡住（否则每轮 poll 闪一个幻影 `spectix` 头，见 `discoverSessions` 注释）。判据取 daemon 的 `entrypoint` 而非匹配扩展安装路径 —— 那是 Claude Code 自己声明的语义，扩展升级不会改。
- **伴生文件全部自动跟随**：`state-` / `title-` / `step-` / `bg-` / `agents-` / `agent-step-` / `ctx-` / `tp-` / `clear-boundary-` 都是 `$dir/xxx-$tty` 拼接，改 `$tty` 一处即全域生效（已逐个 grep 核对无硬编码 `ttys`）。
- **编号另走一把键**：同一编辑器**窗口**里的多个聊天**共享一个扩展宿主 pid**，而 `seqOf` 按 `shellPid` 编号 → 会撞成同序号、同 `folder · 02` 标题。故 `LiveSession.seqKey` 对聊天面板返回 `claudePid`。两类都是真实 pid，永不碰撞。
- **pid 复用**：与终端复用 `ttysNNN` 同一套机制兜底 —— 会话启动时 `SessionStart` 写 idle，盖掉可能读到的陈旧 state。

**已知局限（用户已确认接受，不在 T142 解决）**：

| 局限 | 后果 | 为什么不修 |
|---|---|---|
| **daemon 三分支补盲全部失效** | 上一节那三条（`waiting`→红 / `busy`→蓝 / `idle`→洋红）对聊天行**一条都不生效** → 「答完还红一会儿」「拒绝/中断后一直红」在聊天行上重现。终端行不受影响 | daemon 给聊天会话写的 `~/.claude/sessions/<pid>.json` **没有 `status` / `statusUpdatedAt` 字段**（终端会话的有）。2026-08-09 复测仍然如此：`entrypoint: cli` 的 json 有 `status`，`claude-vscode` 和 `sdk-cli` 的都没有。信号源不存在，App 侧修不了 |
| **同窗多聊天跳转不可区分** | 侧栏 + 新 tab 同开时，跳转只能定位到**窗口**，落不到具体哪个聊天 | 它们共享同一个扩展宿主 pid，而跳转正是按宿主 pid 广播的（见 [`jump.md`](jump.md)）。**状态侧不受影响** —— 各自按自己的 claude pid 键控，分得清 |
| **新聊天晚几秒才出现** | 刚开的聊天面板可能晚一到两轮 poll 才进列表 | 放行判据读 daemon json，而 daemon 在会话启动后一小会儿才写。等一轮即可，不值得为它加探测 |
| **聚焦聊天面板不算「看过了」**（T204 新增，2026-08-09 用户拍板） | 点进聊天面板只让列表**高亮那一行**；不消横幅、不把红行转成「我在看」的眼睛、不给绿行的 ack 上膛——这些终端焦点会做的事（`dismissFocusedToast`）聊天焦点一律不做 | 终端那套敢做是因为判据是 extension **按 pid 精确写**的 token；聊天焦点只能靠 a11y 轮询认（VSCode 不给第三方扩展 webview 焦点事件，见 [`focus-ring.md`](focus-ring.md)），**一次误读就会把真的「需确认」红行标成已看**，用户可能就此错过。代价不对称，故只做可逆的高亮 |

> 标题侧另有一个坑（扩展把 `<ide_opened_file>…` 作为 prompt 注入，会污染行标题）——已在 `title-<key>` 的垃圾 prompt 闸里加「剥离前导 `<tag>…</tag>` 块」处理，细节见 [`row-display.md`](row-display.md)。

## 客户端覆盖层：checking（查看中）/ seen（已看过）

上面全是**真状态**。这两个是 App 自己贴的视图覆盖层，只改颜色、不写 state 文件、不进 `lastStatus`/`notifyTransitions`（`applyChecking` / `applyAck`，`main.swift`）：

| 覆盖 | 触发 | 显示 | 撤销 |
|---|---|---|---|
| `checking` | 焦点进了一个 **needs** 会话（点横幅 / 聚焦那个终端） | 琥珀「查看中」眼睛 | 真状态离开 needs（你真答了） |
| `seen` | 焦点进过一个 **done** 会话 | 灰（读作闲置） | 真状态不再是 done |

- **needs 不可 ack**：聚焦终端 ≠ 回答弹窗，红必须留到 hook 写出 working/done。
- **★ T144：ack 是「到达时上膛、离开时才生效」（改 `acknowledge` / `promotePendingAck` 前必读）**。老实现在**落地那一刻**就把行涂灰 —— 用户原话「我现在点绿色 跳转过去后直接就是灰色的」。它既突兀又不真：绿=「该你了」，你人坐在那儿读结果、还没回复，**依然是该你了**。∴ 聚焦 done 只写 `pendingAck`（行保持绿），真正**离开**它时才升级进 `acked` 变灰 —— 那才是「看过了、翻篇了」成立的时刻。两处观测「离开」：① `dismissFocusedToast` 收到指向**别的** shellPid 的 `active-terminal` 报告（终端焦点互斥，含同一编辑器窗口内切终端）；② `ackOnAppSwitch` 前台 App 变成**不承载**该会话的 App（`hostBundleId(forSessionId:)` 比对，desktop/editor/terminal 三类宿主）。**激活我们自己不算离开**（开列表看一眼不该把行从眼皮底下涂灰）。常见路径根本走不到变灰：你一打字 hook 就写 working，`applyAck` 里 `pendingAck` 值和真状态对不上即作废。

## 最终判定表（回归时对照这张表）

| 情况 | 命令外壳 | 应显示 |
|---|---|---|
| 确认后长命令在跑 | 启动**晚于** needs 且存活 ≥1s | 运行中(蓝) |
| 残留 dev server + 新弹窗待确认 | 启动**早于** needs | 需确认(红) |
| AskUserQuestion / ExitPlanMode 等你答 | 无外壳 | 需确认(红) |
| 弹窗刚出、还没确认 | 无（命令未 spawn）| 需确认(红) |
| 弹窗未答 + idle-ping hook 外壳在跑 | argv 含 `.claude/hooks/` → 排除 | 需确认(红)，不闪蓝 |
| 后台 subagent 等确认（hook 无信号） | daemon `sessions/<pid>.json` status=`waiting` | 需确认(红) |
| 刚答完问题/批完 plan，模型在思考（hook 无信号） | 无外壳（还没 spawn）；daemon `busy` 且比 needs 写入**新** | 运行中(蓝) |
| 拒绝权限(No/Esc) 或中途 Ctrl+C（hook 无信号） | daemon `idle` 且比 needs/working 写入**新**，且无后台命令 | 暂停(洋红) |
| 一轮刚起步，daemon 还停在上一轮 idle | daemon `idle` 但**旧于** working 写入 → 时刻守卫挡掉 | 运行中(蓝)，不闪暂停 |
| **会话冻死：主回合无 Stop 就结束**（派完 agent 没等到唤醒） | 无外壳，且 state 文件与 daemon 双双 >600s 未动 | 暂停(洋红) |
| 后台 subagent 在跑、主回合已 Stop（★T314） | 台账非空（App 侧判定；state 文件仍是 done） | **await(青「等待」)** + 🤖 ×N 徽标 + 副标题 `▸ 后台 agent · N 个运行中 · <时长>`；完成音与横幅都不响（见台账节 ★T314） |
| 后台 Bash（`run_in_background`）还在跑，主回合已 Stop（★T312） | 外壳带 `shell-snapshots/` 签名、存活 ≥1s（启动**早于** done，`since=0` 无时刻守卫） | **await(青「等待」)** + 副标题 `▸ 后台命令 · N 个 shell 运行中 · <时长>`（不是运行中蓝、不是完成绿、不是暂停，见下节） |

## 后台 Bash 命令补盲（探测机制；颜色语义见 ★T312）

> **★ T312 第五状态「等待」（改这块前必读）**：这条路径的颜色改过三次。最早探到活外壳就涂 `working`（蓝）；**T54 反转**成 `done` 绿——后台命令不占用主循环，你照样能直接和 AI 干别的，所以不算「忙」；**T312 再改**：绿也不准，因为命令一退出 AI 会**自己接着跑**，这时并没有什么事轮到你。既不是运行、不是完成、也不是闲置，就是第四个答案 —— **`await`（青「等待」，#00BFA5，空心缺口环 4s 一转 + 实心青药丸）**。∴ `bgShells > 0` 现在把 status 强制成 `await`，**副标题 `▸ 后台命令 · N 个 shell 运行中 · <时长>` 照常显示**（`hasStep` 门控按 `bgShells > 0` 放行）。**内部键是 `await` 不是 `waiting`**：daemon 的 `sessions/<pid>.json` 里 `waiting` 早就表示「等你答确认」→ needs，同一段判定链里两个 waiting 必混。**state 文件里永远不会出现 `await`**——hook 不写它，它完全由 App 的探测得出。**长驻 dev server 也一直显示等待**（用户 2026-09-10 拍板）：几小时的 `expo start` 那一行就是青色 + 「1 个 shell 运行中 · 2h」，完成音（hook 在 Stop 时播）照旧响，但 App 的「完成」横幅不会弹——它要等真正的 done。（**后台 agent 那条路径 T314 起连完成音也闸掉了**，shell 这条不闸：shell 压根不进 `bg-<tty>` 台账，hook 无从知道它在跑。）

`run_in_background:true` 的 Bash 命令（`npx expo run:ios` 之类）：Bash 立即返回 → 主回合秒 Stop → 涂 done（绿），随后 startup 重连/stale 可能再降级成 idle（灰）。但命令的外壳 `zsh -c 'source …/shell-snapshots/…snapshot.sh 2>/dev/null || <cmd>'` 作为 **`claude` 的直接子进程**一直活到命令结束——hook 侧没有任何「还在跑」的信号（`PostToolUse` 已发、`Stop` 已发）。

- 判据：done/idle 行调 `runningToolShells(since: 0)`——**丢掉时刻守卫**（后台命令外壳启动早于 done，用 needs 那套「启动晚于 mtime」会把它挡掉）。done/idle 无待答弹窗，不存在「残留外壳 vs 新弹窗」的歧义，所以有活外壳 = 真在跑 → **强制 `await`（★T312；T54 时是 `done`，更早是 `working`）**，done 与 stale-idle 两路统一读作「等它自己回来」。
- 防误判：`since=0` 会放行任何长驻 `sh -c`（比如某些 `sh -c server` 起的 MCP server）。用 **`shell-snapshots/` 签名**收窄——只有 Claude Code Bash 工具外壳（前台/后台都）会 source shell-snapshot，MCP server 不会。该签名要求加在 `runningToolShells` 里对 needs 路径也是纯增益（Bash 工具外壳必带签名）。
- 自我修正：命令结束外壳消失 → 下次 refresh 探测返回 0 → done 行副标题消失（bgShells 归 0）。
- **★ 必须标出「有 N 个后台命令在跑」（「以为是在卡」bug 的修复，T312 后依旧）**：这条路径的 await 行**没有 hook step**（`Stop` 已 `rm step-<tty>`），只剩 `⏱ 时长` —— 一个不说在干嘛的行读起来像「没事发生」，青色本身只说「在等」、不说等多久。故 `runningToolShells` 返回 **`(count, oldest)`**（不是 bool）→ `SessionRow.bgShells` / `bgShellsSince` → `MainWindow` 在 step 为空且 `bgShells>0` 时合成副标题 **`▸ 后台命令 · N 个 shell 运行中 · <时长>`**（对齐 Claude Code 自己的 "N shells still running"；时长 = `now - oldest`，即最早那个外壳的存活时间，`oldest == 0` 时省略这一段），**门控 `hasStep` 按 `bgShells > 0` 放行**（不看状态；T54 前只在 working 渲染）。计数只在 done/idle 分支采集（那里本来就要扫）。〔T312 顺手删了标题右侧的 `shell` 字条：等待行的药丸已经在说同一件事，字条只剩 `bash`（前台命令在跑的 working 行）。〕
- **★ daemon idle 不得把它判成暂停**（改判定链前必读）：主回合已结束、后台命令还在跑时，daemon 的 `sessions/<pid>.json` 就是 **`idle`**（合法，不是中断），daemon 判定链里 `idle + status==working → paused` 本会把它翻成洋红「暂停」。`bgShells>0` 已强制 `await`（不再 working），天然进不到这条 needs/working 分支；`bgShells == 0` 守卫作为**兜底**保留，双保险绝不把在跑的后台命令读成暂停。
- 局限：副标题报**数量 + 已跑多久**，但不报具体是什么命令（外壳里的真实命令没抽）；后台命令的时长/token 不单独计入统计（同 subagent 台账局限）。

## 相关代码位置（`main.swift`）

- `sessionStatus(tty:)` — 读 state 文件
- `fetchRows()` — 组装每行。顺序固定：`needs` 行调探测覆盖为 working → done/idle 行调 `since=0` 探测，有活外壳则**强制 `await`（★T312，不是 working 也不是 done）**并留下计数 → **最后**跑 daemon 三分支覆盖
- `runningToolShells(claudePid:since:)` — 忙碌探测 + 时刻守卫（核心）；要求外壳带 `shell-snapshots/` 签名；**返回 `(count, oldest)` 元组** —— `count` 是符合条件的外壳个数（0 = 没在跑），`oldest` 是其中最早的启动时刻，供副标题算「已跑多久」
- `daemonSessionStatus(_ pid:)` — 读 daemon 的 `sessions/<pid>.json`，**返回 `(status, updatedAt)` 元组**（`updatedAt` 由毫秒转秒，用来和 state 文件 mtime 比新旧）
- `childPIDs(_:)` — libproc `PROC_PPID_ONLY` 取直接子进程
- `processStartEpoch(_:)` / `fileMTime(_:)` — 时刻对比两端
- `discoverSessions()` — 枚举活跃 `claude` 进程，`LiveSession.claudePid` 供探测用；stream-stdio 会话的有条件放行也在这里
- `isEditorChatSession(_ pid:)` — 读 daemon 的 `sessions/<pid>.json` 判断「这个无 tty 的 claude 是不是编辑器聊天面板」（`entrypoint` 前缀 `claude-vscode` + `kind == "interactive"`）

## 配套约定

长命令（dev server / build / watch / `expo start`）**优先 `run_in_background`**（已写进全局 `~/.claude/CLAUDE.md`）：后台命令 Bash 立即返回 → `PostToolUse` 秒发 → 状态马上正确，从源头绕开前台阻塞盲区。

## 调试手法（状态又出错时）

1. 看真实事件顺序：在 hook 的 `atomic_write "$dir/state-$tty" "$state"` 之后临时加一行 append trace（`时间 tty action state hook_event_name` → `$dir/trace.log`），触发一次后 `cat` 看序列，**排查完删掉**。
2. 看进程树印证：
   ```bash
   CP=$(ps -Ao pid,tty,command | awk '$2=="ttysNNN" && /[c]laude$/{print $1;exit}')
   ps -Ao pid,ppid,stat,command | awk -v P="$CP" '$2==P'   # 看有无 zsh -c 外壳
   stat -f '%m' ~/.claude/spectix/state-ttysNNN             # needs 写入时刻
   ps -o lstart= -p <外壳pid>                                # 外壳启动时刻，比大小
   ```
3. **聊天面板（无 tty）单独一套**：上面按 tty 找进程的写法对它无效。先从 daemon 的 json 里挑出来，再照 `pid<PID>` 找它的 state：
   ```bash
   grep -l claude-vscode ~/.claude/sessions/*.json          # 哪些 pid 是聊天面板
   cat ~/.claude/spectix/state-pid<PID>                     # 它的状态（键是 pid 不是 ttys）
   ps -Ao pid,ppid,command | awk -v P=<PID> '$1==P'         # ppid 应是 Code Helper (Plugin)
   ```
   行根本不出现 → 多半是 daemon json 还没写（等一轮）或 `entrypoint` 变了；行在但状态不动 → 看 hook 的键解析块是不是没回退到 pid。
