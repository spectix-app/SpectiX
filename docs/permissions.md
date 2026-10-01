# 系统权限（TCC）

## ★ 零联网不变量（加任何网络代码前必读，含"就检查一下更新"）

**App 不联网，而且这一条已经对外公开成「可验证承诺」——它不再是实现细节，是产品契约。** 落在四处：`LICENSE` §4（**有法律约束力的条款**，不是营销话术）、`README.md` / `README.zh-CN.md` 的隐私节、官网 `web/privacy/` 与首页、`main.swift` 顶部的 NO-NETWORK INVARIANT 注释。对外我们让用户跑 `codesign -d --entitlements -` / `otool -L` / `lsof -i` / `spctl -a` 四条命令自查——**破坏它 = 用户下一次自查就发现你在撒谎**，代价远高于那个功能本身。

**两道构建守卫（`build.sh`）**，靠脚本硬拦而不是靠记性：① 编译前扫 `*.swift`（先剥掉 `//` 行注释，所以文档里可以写这些 API 名，代码里不行），命中 `URLSession|CFNetwork|NWConnection|socket(|getaddrinfo|import Network|…` 即 fail；② 编译后 `otool -L` 检查链接库，出现 `CFNetwork|Network.framework|libcurl|libssl` 再 fail。守卫**放在 `rm -rf "$APP"` 之前**——违规时旧 app 完好无损，不会既失败又把用户的 app 删了。`NSWorkspace.open(URL)` 故意不在清单里：那是把 URL 交给浏览器，本进程不开连接。

> **★ 不要为了「让证明更硬」去开 App Sandbox。** 用户那套「沙箱 + 不申请 `network.client` = 内核级联不了网」的推理**只在沙箱内成立**；非沙箱 App 缺网络 entitlement 照样能联网。但 SpectiX **开不了沙箱**：它要读 `~/.claude/` 下任意路径、要用 AXUIElement 驱动别的 App 窗口、要 spawn `osascript`——三件事沙箱全禁，开了等于废掉整个产品。所以对外文案（README / 官网）**明确写了这个 footnote**：第 1 条 entitlement 检查的意义是「这是它向系统申请过的完整、不可篡改的清单」，**不是**「内核在拦着它」，真正补缺口的是 otool / lsof / 公证那三条。**这个诚实注脚不许删**——面对的正是会自己跑 `codesign` 的技术用户，被拆穿一次比不写更伤。

**`tools/SpectiX.entitlements` 永远不加网络键**（文件里也写了同样的警告）。用户被引导直接从出厂二进制读这份清单，往里加一条 = 当场公开打脸。

真要上联网功能（Pro 授权校验、更新检查）：**先**把 `LICENSE` §4、两份 README、官网 privacy 页、changelog 全改掉并做成 opt-in，**再**动代码——顺序反了就是虚假宣传。

---

App 只需要**一项**权限——**辅助功能**，Settings 的「系统权限」区有实时状态 + 一键开启（`SettingsWindow.swift` `makePermissionRow` / 1.5s 轮询刷新）：

- **辅助功能**：跳转抬窗（`kAXRaiseAction`）、FocusRing pane 定位、桌面版 Claude AX 探测，以及**读 VSCode 窗口标题建 `vscodeWindowCache`**（`kAXTitleAttribute`，把会话 cwd 匹配到目标窗口）。授权后对运行中进程即时生效。

**★ dev build 与正式版必须彻底分身（改 `build.sh` 的 bundle id / 产物名前必读）**：2026-08-12 踩到「系统设置里开关明明是绿的，App 里却显示未授权」，连环三个坑，缺一条都修不好——

1. **TCC 按 bundle id 只存一条记录，锁的是「代码要求」不是 App 名字。** 正式版是 Developer ID 签名（要求 = id + apple anchor + 开发者 Team ID），dev build 是自签证书 `TaskBeacon Dev`（要求 = id + 那张证书的 leaf hash）。两者共用一个 id 时**互相顶替**：给谁授权另一个立刻失效，而列表里只有一行，看不出发生了什么。修法是 dev 用 `app.spectix.SpectiX.dev`。⚠️ **正式版那个 id 从现在起冻结**——它的要求里不含 cdhash 也不含版本号，所以发新版用户不用重新授权；改一次 = 全体用户重新授权。
2. **LaunchServices 按「路径」缓存 bundle id，同路径换 id 不会自动重读。** 结果 tccd 报 `failed to find an Application URL for bundle ID`，系统设置那一行画不出名字和图标、点不动，权限**永远给不了**。所以 `build.sh` 末尾会 `lsregister -f` 一次；换过 id 的旧产物还要 `lsregister -u` + 删掉，否则它继续占着那个 id。
3. **系统设置的隐私列表按 `.app` 文件名显示，不看 `CFBundleDisplayName`。** 只改 plist 里的显示名 = 白改，列表里仍是两个一模一样的 "SpectiX"。所以 dev 产物叫 **`SpectiX Dev.app`**（`CFBundleExecutable` 仍是 `SpectiX`，`pkill -x SpectiX` 照常通杀）。

**★ bundle id 为什么是 `app.spectix.*` 而不是带人名的（T206，2026-08-16）**：bundle id 是**公开且永久**的——任何人 `plutil -p` 下载来的 Info.plist 就能读到，而 Homebrew cask 的 `uninstall quit:` 与 `zap trash:` 必须逐字写出它并被 homebrew-cask 公开仓永久索引。旧 id `com.<vendor>.spectix` 的中段是个人信息，与「对外身份 = SpectiX Lab、零个人信息」直接冲突，故改成域名反写 `app.spectix.SpectiX`（`.dev` / `.installer` 同理）。**中段不需要是你真实拥有的域名**，macOS 从不校验，它只需在本机唯一。改动落点五处：`build.sh`、`installer/build-installer.sh`、`Migration.legacyDomains`、`InstallerCore.isOurApp`、`tools/wipe-install.sh` 的 `BUNDLE_IDS`。**只有这一次改得起**——当时装机量为零；设置能靠 `Migration.legacyDomains` 迁移，**辅助功能授权迁不了**（TCC 没有对应 API），所以再改一次就是全体用户重新授权。`tools/web-check.py` 的 `FORBIDDEN` 把那个中段列为官网硬 FAIL，`tools/export-public.sh` 对公开仓做同样的扫描。**旧 id 在代码里不许再写出来**：`Migration.legacyDomains`、`InstallerCore.isOurApp`、`wipe-install.sh` 都按形状（`com.<vendor>.spectix` / `.taskbeacon`）现场发现。

配套代码：`AppController.resetAccessibilityGrant()` 用 `tccutil reset Accessibility <自己的 bundle id>`（不需要 sudo）清掉陈旧记录，设置页的「开启」和菜单栏的「权限已失效」弹窗都会先调它。**反方向做不到**——macOS 没有任何 API 能程序化授予辅助功能，能自授权就等于 TCC 不存在；所以别再去找「自动打开那个开关」的办法，最后那一下必须是用户手点。调用前**必须**先确认权限确实是坏的，对着好记录跑等于把用户刚给的授权删掉。

诊断入口永远是 tccd 日志（见下条的 `log show` 手法）：先看它有没有把你的 id 解析成路径，再看 `Update Access Record` 里的 `CodeReq` 到底锁着谁。

> **★ 曾用「屏幕录制」，已彻底移除（改跳转前必读）**：早期靠 `CGWindowListCopyWindowInfo` 的 `kCGWindowName` 读跨 Space 窗口标题匹配跳转目标——而 macOS 只把 `kCGWindowName` 锁在屏幕录制权限后面。现改用 **AX `kAXTitleAttribute`（只需辅助功能）读当前 Space 窗口标题、按 wid（`_AXUIElementGetWindow`）累积进 `vscodeWindowCache`**（`main.swift` `scanVSCodeWindows` / `updateVSCodeWindowCache`）：AX 只列**当前 Space**，但缓存跨刷新**累积**——窗口在某 Space 露过一次面就永久可跳（`updateVSCodeWindowCache` 保留仍 live 但不在当前 Space 的条目）。曾试 WindowServer 枚举（`CGSCopyWindowsWithOptionsAndTags`）一次看所有 Space，但 `CGSCopyWindowProperty` 的 `kCGSWindowTitle` 对 off-Space 窗口返回空、不可靠，遂弃。

**★ 曾经的「权限弹窗雨」bug（改探针前必读）**：`requestUsageProbe()` spawn 的 `claude -p "/usage"` 在启动时会触碰 Downloads / 媒体库 / 其他 App 数据等受保护位置，而 macOS 把子进程的 TCC 访问记到 **responsible process**（= SpectiX）头上 → 用户被「SpectiX 想访问下载/音乐/…」刷屏。修复（`main.swift` `spawnDisclaimed`）：用 posix_spawn + 私有 API `responsibility_spawnattrs_setdisclaim`（Chromium/VSCode 同款）让 claude 子进程树对自己的 TCC 负责，并 `cd` 到 `~/.claude/spectix` 防止把 launchd 的 cwd（`/`）当项目根扫描。**新增任何 spawn 外部命令的代码都走 `spawnDisclaimed`，别用裸 Process()**——**唯一例外是 AppleScript/Apple Events 自动化**（`focusTerminal` 跳原生 Terminal/iTerm 的 osascript）：Automation 权限 TCC 按 **responsible process** 键控，disclaim 后责任进程是通用的 `/usr/bin/osascript` → 弹窗写「osascript 想控制 Terminal」且授权脆弱反复弹；必须走 `spawnResponsible`（**不 disclaim**，让 SpectiX 负责）→ 弹「SpectiX 想控制 Terminal」点一次永久生效。判据：子进程会**触碰受保护数据**（claude 探针碰 Downloads/媒体）→ disclaim 防雨；子进程只**发 Apple Event 控制别的 App** → 不 disclaim 让权限归到 SpectiX。诊断手法：`/usr/bin/log show --info --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "spectix"'`（注意 `log` 会撞 zsh builtin，必须全路径）看 AUTHREQ 的 `accessing=` 是谁。**Automation 被拒（用户点过「不允许」、或 TCC 里 `kTCCServiceAppleEvents` 那行 auth_value=0）的症状是 osascript 退出码非 0、屏幕上什么都不发生**（2026-09-02 实测：「点了添加账号什么都没发生」就是它）。`openProfileSession` 现在检查退出码并弹提示（去 自动化 打开 / 复制命令）；本机复位用 `tccutil reset AppleEvents <bundle id>`，dev 与正式版 bundle id 不同要分别复位。
