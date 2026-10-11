# 账号面板：显示当前账号、一键切换、记住用过的账号

header 的 Claude / Codex 卡片点开的那个面板。代码：`AgentAccount.swift`（读当前账号，不碰密钥）· `AccountBook.swift`（账号簿 + 切换编排）· `CredentialVault.swift`（**全 App 唯一碰密钥的文件**）· `Components.swift` 的 `AccountPanel` / `AccountRow` · `main.swift` 的 `runInTerminal`。

## 2026-09-02 的决定：推翻「不碰凭证」

用户当面拍板：一键切换比「只读状态文件」的卖点重要。所以 App 现在会**读、存、写回**两个 CLI 的登录凭证。这条改动对外必须写明（README、官网 /security /privacy 已改口），**不许再把措辞改回「never touches a credential」**。

## 切换是怎么做的

- **拿副本**：**只有一个时机** —— 用户点另一个账号去切换的那一刻，`switchTo` 先抓**正在离开**的那个账号（refresh token 会轮换，副本只能在这时候取）。把 CLI 的活凭证抄一份进 SpectiX 自己的 Keychain 条目（service `SpectiX account vault`，account `<claude|codex>:<邮箱>`）。**永远不落纯文件。**
- **切换**：把目标账号的副本写回成活凭证。Claude = Keychain 里 `Claude Code-credentials` 那条；Codex = `~/.codex/auth.json`（0600）。Claude 还会把 `~/.claude.json` 的 `oauthAccount` 换成那个账号的（账号簿里存了原样 JSON，不含密钥），CLI 自己显示的账号才对得上。
- **所有 Keychain 读写一律走 `/usr/bin/security`**，活凭证和自己存的副本都是——原因是 Keychain 的访问控制按「条目的 ACL 名单」判，而名单认的是**建这条条目的那个二进制的代码签名**。Claude Code 用 `security` 命令建的活凭证条目，名单上只有 `security`；SpectiX 用同一个工具读写，名单不变，两边都不弹密码框。代价是 blob 在 argv 上待 ~50ms。**改成 SecItem 会弹「SpectiX 想访问 Claude Code-credentials」且 Claude Code 每次重建条目都再弹一次。**

## ★ 副本条目也必须走 `security`（2026-09-03，用户被弹疯了才发现）

副本条目原来是 `SecItemAdd` 建的，理由是「标准访问控制把它锁死在本 app」。**实测这条理由在 dev build 上是反的**：ACL 绑的是代码签名，而 `./build.sh` 走 ad-hoc 签名，**每编译一次 cdhash 就变一次**，系统于是把 App 当成一个陌生程序，弹「SpectiX Dev wants to access key "SpectiX account vault"」要求输入登录密码。点「始终允许」也没用——下一次编译又是个陌生人。一晚上 rebuild 十几次就弹十几次。

改成 `security add-generic-password` 之后名单上是那个**签名永不变的系统工具**，弹窗彻底消失。

- **代价要照直说**：任何能以该用户身份跑 `security` 的程序都能读到这些副本，不再是「只有 SpectiX 能读」。活凭证那半本来就是这样（CLI 自己就这么存的），变的只是副本这半。README 与官网 /security 的措辞必须跟着这条事实走。
- **旧条目不迁移，直接删**：读一条旧条目恰恰就是会触发弹窗的那个动作，所以没法「读出来再写回去」。`retireFrameworkItems()` 用一个 `UserDefaults` 开关一次性 `SecItemDelete` 掉整个 service，当前账号的副本会在下一次刷新自动重抓，别的账号退化成「首次切换需登录一次」。
- **`store` 是先删后加，不是 `-U` 更新**：条目带着它**出生时**的 ACL，更新一条旧签名建的条目等于继承那份 ACL，弹窗照旧。
- 丢掉了 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（`security` 命令没有对应选项）。login keychain 本身不进 iCloud Keychain，所以「不出这台机器」这条实际仍成立。
- **兜底**：没有副本、或写回失败 → 开 Terminal 跑 `claude auth login --email <邮箱>`（Codex 是 `codex login`，没有邮箱参数）。行的第二行「首次切换需登录一次」就是这个状态。副本放久了被服务端作废时同样退化成登录一次——不会更糟。
- **移除**：右键「从列表移除」= 删账号簿那条 + 删 Keychain 副本（`security delete-generic-password`）。当前账号那行不给删（删了下次刷新又回来）。

## 行的排序与左边缘（2026-09-03）

- **顺序固定，永不重排**：`RememberedAccount.addedAt`（首次见到的时间）是排序键，`lastSeen` 只是记账。切换账号**不会**把那一行拉到顶部——用户点第二行，松手后第二行还是那一行；会跳走的列表让人不敢连点第二下。旧账号簿没有这个字段，`list()` 首次读到时按 `lastSeen` 排一次并把值钉死写回（**不能等 `note()` 补**——它只看得见当前账号，别的地址永远补不上，而 `switchTo` 会移动 `lastSeen`）。
- **勾在右边不在左边**：勾在行首时每一行都要留 16pt 空槽，地址整体被推离面板标题，读起来像缩进坏了。现在勾跟套餐 chip 一起挂在尾部，当前账号那行的地址另外**上 accent 色 + medium 字重**——勾是确认，不是唯一标记。
- 面板从标题到脚注**只有一条左边缘**：标题行和脚注各自内缩 6pt，对齐每行为 hover 高亮留的那 6pt。

## 每个账号的用量（2026-09-03）

行的第二行是两个窗口的迷你进度条：`5h`（5 小时会话窗口）和 `7d`（本周）。数据存在账号簿的 `AccountUsage` 里，由 `AppController.headerAgentInfo` 每轮喂给 `AccountBook.noteUsage`。

**★ 只有当前登录的那个账号有实时数字。** 两个 CLI 都只报自己登着的账号——`claude -p /usage` 问的是默认配置目录，Codex 的额度来自正在跑的会话写的 rollout。所以别的账号只有四种读数，UI 必须把它们区分开（`QuotaMini.Reading`）：

| 读数 | 什么时候 | 画成什么样 |
|---|---|---|
| `.live` | 就是当前账号 | 实心条 + 裸数字，按用量染色 |
| `.stale` | 上次它当当前账号时记下的，窗口还没滚过 | 半透明条 + `~` 前缀 + 灰字 |
| `.refreshed` | 记下的 `resetsAt` 已经过去 | 空条 + 绿色 `0%`——**这是唯一确定的推算**，窗口滚过就是满额，不需要任何读数 |
| `.unknown` | 这个账号从没在 App 运行期间用过 | `—` |

`.refreshed` 是这一整条功能存在的理由：它回答「另一个账号现在能不能用了」，而这件事不需要登录过去查。

**绝对不许**把 `.stale` 画得和 `.live` 一样——那是拿旧数字冒充实时。

**一个真实局限**：从没在 App 运行期间用过的账号，什么记录都没有（`—`）。要有数据，得先切过去用一会儿。

### ★ 面板的刷新按钮：不切换也能查（2026-09-04，用户拍板，学自 claude-graft）

上面「只有当前账号有实时数字」现在有例外：**Claude 面板标题旁有一个刷新按钮**，只在「有至少一个非当前账号存着副本」时才出现（Codex 没有，它的额度没有已知接口）；**2026-09-09 起，在面板里点另一个账号去切换的那一刻也会发同样的一次请求**。按下去：

- `CredentialVault.usageResponse` 从每份副本里取出 **`accessToken`**（连同 `expiresAt`，过期就直接放弃，不请求），用 `/usr/bin/curl` GET `https://api.anthropic.com/api/oauth/usage`（`anthropic-beta: oauth-2025-04-20`）—— 就是 CLI 自己 `/usage` 调的那个接口。**token 走 stdin 上的 curl 配置文件（`-K -`），不进 argv**，`ps` 看不到。
- 回来的 `five_hour` / `seven_day` 的 `utilization` + `resets_at` 由 `AccountBook.parseUsageBody` 解析，写进账号簿，并打上 **`probed = true`**。行的判定变成：`probed && 10 分钟内` → 画成 `.live`（tooltip 写「刚向服务器查的」）；超过 10 分钟退回 `.stale`。
- **永远不碰 refresh token**：它一用就轮换，副本就废了；活账号还会被登出。这条是从 claude-graft 的 CLAUDE.md 学来的，他们踩过。
- **只在你亲手按下的那一刻发请求**，触发点有两个：按刷新按钮，和**在面板里点另一个账号去切换**（2026-09-09 加，见下条）。打开面板不发、不按定时器发、不在后台发、App 启动不发。这是不联网承诺里「新联网功能必须 opt-in」的落法（承诺写在 README《Privacy: no network》与官网 /privacy） —— 按下去这个动作本身就是 opt-in；README / /privacy / /security 九语言已改口（`perm.bad3`、`perm.note`、`faq.a3`、`privacy.15/16/38b`、`security.acct.5/5b`），**不许改回「never sent anywhere」**。
- **切换账号的那一刻也发一次（2026-09-09，用户拍板）**：取的是刚写回去、成为活凭证的那份副本里的 `accessToken`，问的就是刚切过去的这个账号。为什么加：header 上那两条额度条的数字走的是另一条路（spawn `claude -p /usage` 子进程，实测 5.1 秒，前面还压着最长 15 秒的节流窗口），所以切完账号最坏要等约 20 秒数字才更新，这期间画的还是上一个账号的百分比；这一次请求把它压到约 1 秒。Codex 那半没有这个行为，它的额度没有已知接口。
- 二进制仍不开 socket：请求在 curl 子进程里，和手表震动的「测试」按钮同一条路。`build.sh` 的联网 gate 对 `curl` 字符串无感。
- 查不到（副本过期 / 401 / 断网）：那一行**保持上次的数字**，按钮变成琥珀色叹号，tooltip 说明「切过去登录一次会刷新」。`curl --fail` 把非 2xx 变成非零退出 + 空 body，App 不区分原因。

这条对硬约定 1 的修正：`CredentialVault` 现在会**解析一个字段**（Claude blob 的 `claudeAiOauth.accessToken` / `expiresAt`），但 token 仍然不出这个文件（curl 在这个文件里 spawn），不打日志、不落文件。

## 三条硬约定

1. **凭证只在 `CredentialVault.swift` 里出现，且当作不透明 blob**——不解析、不打日志、不进 `~/.claude/spectix/` 任何文件。`AgentAccount.swift` 仍然只读身份字段。**唯一的例外**（2026-09-04 立，2026-09-09 扩到两个触发点）：刷新按钮和切换账号这两条路会从 Claude 副本里取 `accessToken` + `expiresAt` 发给额度接口，见上面「面板的刷新按钮」；除这两个字段外仍然不解析，`refreshToken` 一个字节都不读。
2. **只有 `switchTo` 能碰凭证**（2026-09-04 收窄）。原来还有两个时机：见到新邮箱就抄一份、启动时给当前账号补一份。**都删了** —— 那意味着一个刚装上、什么都没点的新用户，开机就吃一个钥匙串密码框。代价是「从没切走过的账号」没有副本，切过去要登录一次，行上写着「首次切换需登录一次」，用户点之前就知道。**不许以任何理由把这两个时机加回来**，包括「只查一次不算碰」——`has()` 不弹窗，但它旁边那个 `capture()` 弹。判断「有没有副本」用不带 `-w` 的查询，问「存不存在」不该是一次解密请求。
3. **账号簿**（`~/.claude/spectix/accounts-<claude|codex>.json`）只记邮箱 / 名字 / 套餐 / id / `oauthAccount` 原样 JSON / 配额快照，没有密钥。面板只在打开、切换、移除时读它，1 Hz 刷新不许碰。

## ★ 为什么不是「每个账号一个配置目录」

第一版（2026-08-30 ～ 09-02）用的是 `CLAUDE_CONFIG_DIR` / `CODEX_HOME`：一个目录一个账号，点账号行 = 带着环境变量开新终端。实测两个问题，**别改回去**：

- 那个变量换的是**整套配置**不只是账号——settings / hooks / skills / memory 全在 `~/.claude` 里，换目录后全是空的，SpectiX 自己的状态 hook 也不在，那些会话它看不见。
- 它只管从 SpectiX 开出去的那一个终端，VSCode 里敲的 `claude` 还是老账号。用户要的是「点一下之后我开的每个 CLI 都是新账号」。

Keychain 里凭证是按配置目录路径哈希分条的（`Claude Code-credentials` 和 `Claude Code-credentials-<hash>`），所以「换目录」和「换账号」在 CLI 眼里是同一件事。旧版留下的 `~/.claude-profiles/` 空目录和带 hash 的 Keychain 条目都没清理，无害。

## ★ header 的两条额度条：切换之后画谁的数字（2026-09-09）

`AppController.headerUsage` 决定 header 那张卡画什么。**两个本地来源都不带地址** —— `claude -p /usage` 问的是默认配置目录，Codex 的额度来自 rollout，谁都答不出「这是哪个账号的」。所以 `AccountBook.lastSwitch` 是唯一的归属判据：**读数早于切换时刻 → 它属于我们刚离开的那个账号**，此时改画账号簿里这个地址自己的快照，并且**必须降一档画**（`MetricLine.configure(stale:)`，alpha 0.72，和面板行同一套语法）。这个账号从没有过读数就画 `—` —— 空着好过画别人的百分比。

- **切换那一刻会向服务器要一次**（见上一节），拿回来的读数带 `probed`，10 分钟内直接当实时画。所以正常情况下那一档「记着的数字」只存在约 1 秒。
- **`AccountBook.quotaDidChange` 通知不能删**：请求是异步回来的，而 header 自己 2.5 秒才刷一次 —— 不发这个通知，这次请求省下来的时间又还回去了。
- **⚠️ 残留竞态，没实测过、也没修**：`spectix-usage.py` 写的 `updated_at` 是**探针结束**的时刻（脚本在管道尾端取 `now`），而探针从起到落地实测 5.1 秒。所以「探针 t=0 起跑（账号 A）→ 用户 t=2 切到 B → t=5.1 落地」这一串里，`updated_at` 会晚于切换时刻，于是 A 的数字被当成 B 的实时读数画出来，窗口约 5 秒。这是本来就有的（原先 `noteUsage` 的守卫用的是同一个判据），本次改动只是把出错窗口从「一直错到探针落地」缩到了这 5 秒。真要根治得让探针把「跑的时候登着谁」一起写进 usage.json。

## ★ 一个邮箱 = 可能多个账号（2026-10-10）

同一个邮箱可以同时属于个人套餐（Max）和公司 Team 两个组织，CLI 里是**两次不同的登录**：token 不同、额度不同。以前账号簿和钥匙串副本都只按邮箱认，两者塌成一行，切换时还会把另一个组织的 token 写回去。

- **行的身份 = `邮箱#organizationUuid`**（`RememberedAccount.key` / `AgentAccount.key`）。Codex 没有组织字段，仍是纯邮箱。
- **旧行迁移不动凭证**：`list()` 从行里存着的 `oauthAccountJSON` 读出组织补上，同时记 `vaultKey = 邮箱` —— 旧副本的钥匙串标签还是 `claude:<邮箱>`，行继续指向它，不搬、不重读（守住硬约定 2）。新行的副本标签是 `claude:<邮箱>#<org>`。删除时只有没有别的行再指向那条副本才删。
- **同一邮箱出现在两行时**，地址后面跟组织名（个人套餐自动生成的 `<邮箱>'s Organization` 显示成「个人」）。
- **在终端里登录别的账号也算一次切换**：`note()` 发现当前账号的 key 和上一轮不同，就设 `switchedAt`（之前测的额度归走掉的那个账号，header 不再把旧数字画到新账号上，探针改 15 秒节奏重测），并发 `currentDidChange` 让打开着的面板立刻重画。以前只有面板里点切换才算，从终端登录后面板不动、旧额度还被记到新账号名下。

- **在终端里离开的账号，副本就作废了**（2026-10-10 实测）：副本只在面板里切走那一刻抓。如果是在终端里登录别的账号离开的，CLI 之后会轮换掉 refresh token，留着的副本就是死凭证。实测一份一个月前的副本被写回去：面板显示切过去了，CLI 其实登不上。现在 `note()` 发现账号不是经面板换掉的，就给走掉的那行打 `copyStale`，那一行退回「首次切换需登录一次」，点它走 `claude auth login`；下一次从面板切走时重新抓副本，标记清掉。面板的「添加账号」也先抓当前账号（`prepareLogin`），否则加完新号，原来那个号就作废了。上一次在线的账号存在 UserDefaults（`accountBook.lastLive.<kind>`），App 没开时换的号也能在启动时查出来。

**改切换逻辑后跑 `./tools/account-switch-test.sh`**：用假钥匙串 + 刷新令牌会轮换的假 CLI 跑一遍切换，不碰真凭证。去掉作废判断后它会在「CLI 登得上」那一步报错，就是 2026-10-10 那次的症状。

## 踩过的坑

- **点工作账号结果切到了个人账号**（2026-09-04，紧跟着上一条）：`switchTo` 先给「正在离开的账号」抄副本，而「谁在登着」来自 `AgentAccounts` 的缓存——文件读不出来时它保留上一次解析成功的值。于是文件里是个人账号的字节、身份却还说是工作账号，副本就以工作账号的名字存了个人账号的 token；之后每次点工作账号都「没反应」，因为真的把个人账号写了回去。现在 `capture` 会从 Codex 的 blob 里解出 id_token 的邮箱，**跟标签对不上就一个字节都不存**。Claude 的 blob 不带邮箱，核不了，只能靠 `~/.claude.json` 和钥匙串条目同步这一前提。那份错标的副本已手动删除。
- **切 Codex 账号后「没反应」，其实是把它登出了**（2026-09-04）：`security find-generic-password -w` 只在密文全是可打印字符时才原样输出，否则打成**十六进制**。Claude 的凭证是一行 JSON → 原样；Codex 的 `auth.json` 是带换行的 pretty JSON → 一串 hex。`restore` 把那串 hex 原封不动写进了 `~/.codex/auth.json`，CLI 解析不了，App 端也当成撕裂读保留旧值，勾就不动。现在**所有读出来的密文都过 `CredentialVault.plain(_:)`**：去尾、必要时 hex 解码、**必须能 parse 成 JSON**，否则视为「没有」——`capture` 不会拿坏文件盖掉好副本，`restore` 也不会把坏东西写进活文件。

- **点了什么都不发生** = Automation 权限被拒（TCC 里 `kTCCServiceAppleEvents` 那行 auth_value=0），osascript 静默退出。`runInTerminal` 现在检查退出码并弹提示（去「自动化」打开 / 复制命令）。本机复位：`tccutil reset AppleEvents <bundle id>`，dev 与正式版 id 不同要分别复位。详见 `docs/permissions.md`。
- **只开网页登录不管用**：网页登录不会写 CLI 凭证，只有 CLI 进程自己跑 login 才会。所以「添加账号」永远是开终端跑 CLI 的 login，由 CLI 去开浏览器。
- **Codex 面板把主窗口撑宽**：面板「对齐到卡片左边」那条约束优先级必须 < 500（`windowSizeStayPut`），否则最右那张卡的面板塞不下时系统会把窗口拉宽来迁就它。
- **在跑的会话切换后会怎样，没验证**：Claude Code 进程刷新 token 时可能重读 Keychain 拿到另一个账号的凭证。面板脚注让用户先结束再切；别把脚注删了。
