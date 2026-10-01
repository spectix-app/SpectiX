import Cocoa
import ServiceManagement

// MARK: - App settings
//
// Small UserDefaults-backed store for user preferences that live outside the
// hotkey system. Changing a value posts `didChange`, which the session list
// observes to re-render in place.
enum AppSettings {
    static let didChange = Notification.Name("AppSettingsDidChange")

    // Which display setting a `didChange` came from, carried as the notification's
    // `object`. Only the settings the live preview card can point at are tagged; every
    // other post stays nil ("something changed, redraw"). Listeners that re-render
    // wholesale — the session list — ignore it; the preview card uses it to flash the
    // one element that setting controls (see SettingsLivePreview).
    enum DisplayKey: String {
        case statusLabels, modelLabel, stepLabel, contextGauge, sortMode, statusColors
        case duration, tokens, shellBadge
    }

    // MARK: Launch at login
    //
    // Whether macOS starts SpectiX at login, through the modern SMAppService login
    // item (macOS 13+ — the same entry System Settings → General → 登录项 lists).
    //
    // The system owns this state, not UserDefaults: the user can flip it in System
    // Settings behind our back, so the getter always asks the system and there is no
    // copy of ours that could drift out of sync.
    private static let launchAtLoginSeededKey = "launchAtLoginSeeded"

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    // False = the system refused. The reachable case is a login item the user denied
    // in System Settings (status .requiresApproval), which register() cannot override;
    // the settings row bounces its switch back and sends them there.
    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }

    // Opt a fresh install in, exactly once — a menu-bar monitor that isn't running
    // tells you nothing, so on is the useful default. It has to be a one-shot seed
    // rather than a default-on read: the system state is the truth afterwards, and
    // without the flag every launch would re-register the item the user just switched
    // off.
    static func seedLaunchAtLogin() {
        // Never from the dev build: it has its own bundle id (build.sh), so the login
        // item it would register is a SECOND one alongside the release install's, and
        // the machine boots two menu bar instances. The settings row still registers it
        // by hand if that is genuinely wanted.
        guard !Build.isDev else { return }
        guard !UserDefaults.standard.bool(forKey: launchAtLoginSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: launchAtLoginSeededKey)
        setLaunchAtLogin(true)
    }

    // MARK: Editor-reload hint

    private static let reloadHintSeenKey = "editorReloadHintSeenVersion"

    /// True exactly once per installed version — reading it marks that version seen.
    ///
    /// An editor loads its extensions when its extension host starts, so the copy an
    /// installer just dropped in does nothing in a window that was already open: jumps
    /// keep working (they raise the window over AX and need no extension) but land with
    /// no highlight ring, which reads as "highlights are broken" rather than "reload me"
    /// (T226).
    ///
    /// Keyed on the version rather than a plain bool so a new build says it once more,
    /// and rather than the bundle's modification date because `./build.sh` changes that
    /// every time — which would fire this on every restart for whoever is working on the
    /// app.
    static func consumeEditorReloadHint() -> Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        guard UserDefaults.standard.string(forKey: reloadHintSeenKey) != version else { return false }
        UserDefaults.standard.set(version, forKey: reloadHintSeenKey)
        return true
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Language
    //
    // UI language. `.system` (default) follows the macOS preferred-language list
    // (zh* -> Chinese, otherwise English); the other two force a language. Changing
    // it posts `languageDidChange`, which AppController observes to rebuild the
    // windows + popover so every statically-built label re-resolves through L().
    static let languageDidChange = Notification.Name("AppSettingsLanguageDidChange")

    enum Language: String, CaseIterable {
        case system, zh, en
        // Language names show in their own script (Chinese / English), reading the
        // same regardless of the current UI language; only `.system` is translated.
        var title: String {
            switch self {
            case .system: return L("跟随系统", "System")
            case .zh:     return "中文"
            case .en:     return "English"
            }
        }
    }

    private static let languageKey = "language"

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            NotificationCenter.default.post(name: languageDidChange, object: nil)
        }
    }

    // The concrete language L() resolves against (never `.system`).
    static var effectiveLang: Lang {
        switch language {
        case .zh: return .zh
        case .en: return .en
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("zh") ? .zh : .en
        }
    }

    // MARK: Theme
    //
    // Which visual theme the app wears (see ThemeSpec.swift / ThemeRegistry.swift).
    // Structurally the same problem as `language`: colors, radii and material are
    // baked into layers when views are built, so a change cannot be re-rendered in
    // place — the windows + popover have to be rebuilt wholesale. Hence its own
    // notification rather than riding `didChange` (whose listeners only re-render).
    static let themeDidChange = Notification.Name("AppSettingsThemeDidChange")

    private static let themeIDKey = "themeID"

    static var themeID: String {
        // An id we no longer ship (a downgrade, a removed theme, a hand-edited
        // preference) reads back as the default instead of leaving the app unstyled.
        get {
            // Locked reads as the built-in theme — the same path an unknown id takes,
            // so a free install is styled, just not with a theme it didn't pay for.
            guard Pro.enabled(.themes) else { return ThemeRegistry.fallback.id }
            let stored = UserDefaults.standard.string(forKey: themeIDKey) ?? ThemeRegistry.fallback.id
            return ThemeRegistry.isKnown(stored) ? stored : ThemeRegistry.fallback.id
        }
        set {
            // Compare against what's STORED, not the gated read: while locked the getter
            // always answers the fallback, which would make every tap look like a change.
            let stored = UserDefaults.standard.string(forKey: themeIDKey) ?? ThemeRegistry.fallback.id
            guard newValue != stored else { return }   // no rebuild for a no-op tap
            UserDefaults.standard.set(newValue, forKey: themeIDKey)
            // Swap the palette BEFORE announcing it: observers rebuild their views
            // synchronously and must read the new spec, not the outgoing one. Applying
            // the GATED id (not newValue) is what keeps a locked install on the built-in
            // look while still remembering the pick — unlocking restores it untouched.
            Theme.apply(themeID)
            NotificationCenter.default.post(name: themeDidChange, object: nil)
        }
    }

    // MARK: Main window sizing
    //
    // Once the user drags the main window's edge, we stop auto-fitting its height
    // to the sessions list (which otherwise snaps back on every 2.5s poll) and let
    // their chosen size stick. Persisted so a dragged size survives relaunch — the
    // restored frame would otherwise get overwritten by the first content-fit.
    private static let mainWindowUserSizedKey = "mainWindowUserSized"

    static var mainWindowUserSized: Bool {
        get { UserDefaults.standard.bool(forKey: mainWindowUserSizedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mainWindowUserSizedKey) }
    }

    // Main-window frame, persisted by hand — NSWindow's setFrameAutosaveName silently
    // no-ops on this transparent-titlebar window, so we save/restore the frame ourselves
    // (screen coords, as NSStringFromRect) to survive relaunch. nil until first saved.
    private static let mainWindowFrameKey = "mainWindowFrame"

    static var mainWindowFrame: NSRect? {
        get {
            guard let s = UserDefaults.standard.string(forKey: mainWindowFrameKey) else { return nil }
            let r = NSRectFromString(s)
            return r.width > 1 && r.height > 1 ? r : nil
        }
        set {
            if let r = newValue { UserDefaults.standard.set(NSStringFromRect(r), forKey: mainWindowFrameKey) }
            else { UserDefaults.standard.removeObject(forKey: mainWindowFrameKey) }
        }
    }

    private static let showStatusLabelsKey = "showStatusLabels"

    // Whether each row shows its status pill ("运行中 / 完成 / 需确认 / 闲置").
    // Defaults to on for a never-set install.
    static var showStatusLabels: Bool {
        get { UserDefaults.standard.object(forKey: showStatusLabelsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showStatusLabelsKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.statusLabels)
        }
    }

    private static let showModelLabelKey = "showModelLabel"

    // Whether each row's usage line ends with the session's model chip ("Opus 5" /
    // "Sonnet 5" / "Haiku 4.5", tinted per family). Defaults to on. Turning it off frees
    // the column for the live tool step, which shares that line while 运行中.
    static var showModelLabel: Bool {
        get { Pro.enabled(.metrics) && (UserDefaults.standard.object(forKey: showModelLabelKey) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: showModelLabelKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.modelLabel)
        }
    }

    private static let showDurationKey = "showDuration"

    // Whether the usage line opens with "⏱ 工作时长". Defaults to on. Off closes the
    // time column up, so ◆ tokens (and everything after it) shifts left — the columns
    // stay aligned across rows because the switch is global, never per-row.
    static var showDuration: Bool {
        get { Pro.enabled(.metrics) && (UserDefaults.standard.object(forKey: showDurationKey) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: showDurationKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.duration)
        }
    }

    private static let showTokensKey = "showTokens"

    // Whether the usage line carries "◆ tokens" (the session's current context in raw
    // tokens). Defaults to on. Off with 上下文占用 still on keeps the % — the ratio and
    // the raw figure are two readings of the same thing, so dropping one is reasonable.
    static var showTokens: Bool {
        get { Pro.enabled(.metrics) && (UserDefaults.standard.object(forKey: showTokensKey) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: showTokensKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.tokens)
        }
    }

    private static let showStepLabelKey = "showStepLabel"

    // Whether a row carries the blue step subtitle. Covers BOTH things that share that
    // column: the live tool step while 运行中 ("▸ Bash · git push") and the background
    // -shell notice that rides a done row ("后台命令 · 2 个 shell 运行中").
    //
    // Defaults OFF — it's the busiest text on a row, it changes on every tool call, and
    // the background-shell variant sticks around for as long as the command runs. Off,
    // rows keep the steady ⏱ time · ◆ tokens line instead.
    static var showStepLabel: Bool {
        get { UserDefaults.standard.object(forKey: showStepLabelKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: showStepLabelKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.stepLabel)
        }
    }

    private static let showShellBadgeKey = "showShellBadge"

    // Whether a row carries the bash / shell tag beside its status pill. The status stays
    // 运行中 while a command runs — the tag only says WHAT kind of work that is, so you can
    // tell "thinking / writing code" from "waiting on a command" without opening the
    // terminal. Two words, two sources: bash = a Bash tool call in flight, shell = a
    // backgrounded command still alive (BashOutput/KillShell land here too).
    //
    // Defaults ON, unlike 当前步骤: this is one steady word per row, not the per-tool-call
    // churn that made the step column default to off.
    static var showShellBadge: Bool {
        get { UserDefaults.standard.object(forKey: showShellBadgeKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showShellBadgeKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.shellBadge)
        }
    }

    // MARK: Popover size
    //
    // The menu-bar dropdown is user-resizable via a bottom-right grip. Width and the
    // list-height cap persist here (clamped to sane bounds). No didChange — the
    // popover reads them on open and resize() applies them live during the drag.
    private static let popoverWidthKey = "popoverWidth"
    private static let popoverListCapKey = "popoverListCap"

    // Lower bound matches the main window's minimum width so the dropdown never
    // gets narrower than the panel — and it doubles as the factory width: the
    // dropdown ships as narrow as it is allowed to be and grows by drag. Raising
    // Theme.minPanelWidth therefore also widens every existing dropdown: the getter
    // below clamps into this range on read, so a persisted narrower width migrates
    // itself the first time it's asked for.
    static let popoverWidthRange: ClosedRange<CGFloat> = Theme.minPanelWidth...680
    static let popoverListCapRange: ClosedRange<CGFloat> = 140...760

    static var popoverWidth: CGFloat {
        get {
            let v = (UserDefaults.standard.object(forKey: popoverWidthKey) as? Double).map { CGFloat($0) }
                    ?? popoverWidthRange.lowerBound
            return min(max(v, popoverWidthRange.lowerBound), popoverWidthRange.upperBound)
        }
        set {
            let v = min(max(newValue, popoverWidthRange.lowerBound), popoverWidthRange.upperBound)
            UserDefaults.standard.set(Double(v), forKey: popoverWidthKey)
        }
    }

    static var popoverListCap: CGFloat {
        get {
            let v = (UserDefaults.standard.object(forKey: popoverListCapKey) as? Double).map { CGFloat($0) } ?? 730
            return min(max(v, popoverListCapRange.lowerBound), popoverListCapRange.upperBound)
        }
        set {
            let v = min(max(newValue, popoverListCapRange.lowerBound), popoverListCapRange.upperBound)
            UserDefaults.standard.set(Double(v), forKey: popoverListCapKey)
        }
    }

    // MARK: Hidden projects
    //
    // Projects (keyed by cwd — the only identity stable across terminal restarts)
    // the user has manually hidden from the live monitor. A hidden cwd is dropped
    // in discoverSessions()/desktopRow() before any status/usage/probe work, so it
    // costs nothing and never toasts or counts toward the menu-bar needs badge.
    // Set isn't plist-representable, so it's stored as [String] (like folderOrder).
    private static let hiddenCwdsKey = "hiddenCwds"

    static var hiddenCwds: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: hiddenCwdsKey) as? [String] ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: hiddenCwdsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func isHidden(cwd: String) -> Bool { hiddenCwds.contains(cwd) }
    static func hide(cwd: String) { var s = hiddenCwds; s.insert(cwd); hiddenCwds = s }
    static func unhide(cwd: String) { var s = hiddenCwds; s.remove(cwd); hiddenCwds = s }

    // MARK: Custom project icons
    //
    // A user-chosen glyph shown on a project header's badge in place of the default
    // VSCode monogram / desktop asterisk. Keyed by cwd (the identity stable across
    // terminal restarts, same as hiddenCwds). Notion-style: right-click the header
    // badge → 编辑图标 → pick an emoji, or 上传图片… → pick an image file.
    //
    // Two kinds, one slot: a project has an emoji OR an image, never both — setting
    // either clears the other, so every reader can just switch on `customIcon(cwd:)`.
    // Emojis live in a plist [cwd:String] dictionary; images are too big for
    // UserDefaults, so the picked file is normalized to a small PNG under `iconsDir`
    // and only its file name is stored. Writing either posts didChange so the visible
    // list re-renders the badge in place.
    enum CustomIcon: Equatable {
        case emoji(String)
        case image(String)   // file name under iconsDir
    }

    private static let customIconsKey = "customIcons"
    private static let customIconImagesKey = "customIconImages"

    private static var customIcons: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: customIconsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: customIconsKey) }
    }

    private static var customIconImages: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: customIconImagesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: customIconImagesKey) }
    }

    static func customIcon(cwd: String) -> CustomIcon? {
        // Locked reads as "no custom icon", so rows fall back to the generated badge.
        // The assignment itself stays on disk and comes back on unlock.
        guard Pro.enabled(.customIcons) else { return nil }
        if let f = customIconImages[cwd], !f.isEmpty { return .image(f) }
        if let e = customIcons[cwd], !e.isEmpty { return .emoji(e) }
        return nil
    }

    // Set (non-empty emoji) or clear (nil/empty) the custom icon for a project. Either
    // way the image kind is dropped — the two are one slot.
    static func setCustomIcon(_ emoji: String?, cwd: String) {
        var d = customIcons
        if let emoji, !emoji.isEmpty { d[cwd] = emoji } else { d.removeValue(forKey: cwd) }
        customIcons = d
        dropIconImage(cwd: cwd)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // Point a project at an already-imported icon file (see importIconImage), dropping
    // any emoji it had.
    static func setCustomIconImage(_ file: String, cwd: String) {
        dropIconImage(cwd: cwd)
        var d = customIconImages
        d[cwd] = file
        customIconImages = d
        var e = customIcons
        e.removeValue(forKey: cwd)
        customIcons = e
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // Clear whichever kind the project had. Emoji-only clearing goes through
    // setCustomIcon(nil:) — this is the "移除自定义" path that must handle both.
    static func removeCustomIcon(cwd: String) { setCustomIcon(nil, cwd: cwd) }

    // Forget a project's icon image and delete the file it owned — nothing else can
    // reference it (one file per assignment), so leaving it behind is pure litter.
    private static func dropIconImage(cwd: String) {
        var d = customIconImages
        guard let old = d.removeValue(forKey: cwd), !old.isEmpty else { return }
        customIconImages = d
        iconImageCache.removeValue(forKey: old)
        try? FileManager.default.removeItem(atPath: "\(iconsDir)/\(old)")
    }

    // MARK: Icon image store
    //
    // Uploaded icons are normalized to a square `iconSide`-pixel PNG on the way in: the
    // badge is only 26pt, so this is plenty even at @3x, and it keeps a multi-megabyte
    // original from being reread and rescaled on every list redraw. Loaded images are
    // memoized because the badge re-renders on every poll.
    static let iconsDir = "\(NSHomeDirectory())/.claude/spectix/icons"
    private static let iconSide = 128
    private static var iconImageCache: [String: NSImage] = [:]

    static func iconImage(_ file: String) -> NSImage? {
        if let cached = iconImageCache[file] { return cached }
        guard let img = NSImage(contentsOfFile: "\(iconsDir)/\(file)") else { return nil }
        iconImageCache[file] = img
        return img
    }

    // Import a user-picked image file: center-crop to a square (aspect-fill, so the
    // badge slot is filled edge to edge like the VS/asterisk tiles), scale to
    // iconSide², write as PNG, and return the new file's name. nil if the file isn't
    // a readable image or the write fails.
    static func importIconImage(from url: URL) -> String? {
        guard let src = NSImage(contentsOf: url), src.size.width > 0, src.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: iconSide, pixelsHigh: iconSide,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: iconSide, height: iconSide)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = src.size
        let edge = min(s.width, s.height)
        src.draw(in: NSRect(x: 0, y: 0, width: iconSide, height: iconSide),
                 from: NSRect(x: (s.width - edge) / 2, y: (s.height - edge) / 2,
                              width: edge, height: edge),
                 operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: iconsDir, withIntermediateDirectories: true)
        guard (try? png.write(to: URL(fileURLWithPath: "\(iconsDir)/\(name)"))) != nil else { return nil }
        return name
    }

    // Most-recently-picked emojis, newest first — feeds the picker's "最近" row.
    // Capped so it stays a single tidy row. No didChange (nothing renders off it
    // directly; the picker reads it on open).
    private static let recentEmojisKey = "recentEmojis"
    private static let recentEmojisCap = 16

    static var recentEmojis: [String] {
        get { UserDefaults.standard.array(forKey: recentEmojisKey) as? [String] ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(recentEmojisCap)), forKey: recentEmojisKey) }
    }

    static func noteRecentEmoji(_ emoji: String) {
        var r = recentEmojis.filter { $0 != emoji }
        r.insert(emoji, at: 0)
        recentEmojis = r
    }

    // One-shot flag: the very first hide adds a "where to restore" hint to the undo
    // bar so the feature is teachable exactly once. No didChange — nothing re-renders
    // off it.
    private static let hideOnboardingKey = "hasSeenHideOnboarding"
    static var hasSeenHideOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: hideOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideOnboardingKey) }
    }

    // MARK: Feature tips
    //
    // One Bool key per tip rather than one array: plist-native, and `defaults delete
    // <domain> tipSeen-reorder` re-arms a single tip for testing. A tip is "seen" both
    // when it was shown and when the user found the feature on their own (see
    // TipCenter.markLearned) — either way there's nothing left to teach.
    static func tipSeen(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "tipSeen-\(id)") }
    static func markTipSeen(_ id: String) { UserDefaults.standard.set(true, forKey: "tipSeen-\(id)") }
    static func resetTips() { for id in Tips.ids { UserDefaults.standard.removeObject(forKey: "tipSeen-\(id)") } }

    // Defaults ON, so the check is "was it ever explicitly turned off". Turning it back
    // on re-arms every tip (resetTips, at the call site) — the only reason to flip this
    // switch on is wanting to see them.
    private static let featureTipsKey = "featureTips"
    static var featureTipsEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: featureTipsKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: featureTipsKey) }
    }

    // MARK: Demo mode

    private static let demoModeKey = "demoMode"

    // Replace every live figure — sessions, subscription quota, machine load, and the
    // two logs behind 统计/效能 — with a scripted fake world (see DemoData.swift), so
    // the UI can be recorded or screenshotted without waiting on real work and without
    // exposing real project names.
    //
    // DEV-ONLY (`Build.isDev`), same shape as ringAlwaysOn: a release build reads false
    // no matter what is stored, so `defaults write` can't put a shipped app into a state
    // where it shows invented numbers as if they were the user's own. That is the whole
    // reason for the gate — every other consequence of demo mode is cosmetic, but a
    // fabricated quota bar on someone else's Mac is a lie about their account.
    static var demoMode: Bool {
        get { Build.isDev && UserDefaults.standard.bool(forKey: demoModeKey) }   // default false
        set {
            UserDefaults.standard.set(newValue, forKey: demoModeKey)
            if newValue { Demo.restart(); Demo.ensureLogs() }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Sort mode
    //
    // How the session list groups sessions. `custom` (default) groups by project
    // (cwd) with the user's drag-reorder rank on top. `status` groups by status
    // bucket instead (需确认 → 完成 → 运行中 → 闲置) and disables drag-reorder.
    enum SortMode: String, CaseIterable {
        case custom, status
        var title: String {
            switch self {
            case .custom: return L("按项目分组", "By Project")
            case .status: return L("按状态分组", "By Status")
            }
        }
    }

    private static let sortModeKey = "sortMode"

    static var sortMode: SortMode {
        get { SortMode(rawValue: UserDefaults.standard.string(forKey: sortModeKey) ?? "") ?? .custom }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sortModeKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.sortMode)
        }
    }

    // MARK: Jump priority
    //
    // The order the "跳到下一个待确认" hotkey walks status buckets. The hotkey picks
    // the highest-priority *non-empty* bucket and cycles within it (see
    // jumpToNextAttention): with the default [paused, needs, done] an interrupted
    // session pins the pool until it's picked back up, then the reds, then the
    // finished ones. Only these three attention states participate — working/idle
    // are never jump targets. Stored as [String]; reads sanitize to exactly the
    // three keys (drop unknowns, append any missing) so a stale/partial default can
    // never shrink or corrupt the cycle. The order here IS the factory default.
    static let jumpStatuses = ["paused", "needs", "done"]
    private static let jumpPriorityKey = "jumpPriority"

    static var jumpPriority: [String] {
        get {
            let saved = UserDefaults.standard.array(forKey: jumpPriorityKey) as? [String] ?? jumpStatuses
            let valid = saved.filter { jumpStatuses.contains($0) }
            let deduped = valid.reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }
            return deduped + jumpStatuses.filter { !deduped.contains($0) }   // append any missing
        }
        set {
            UserDefaults.standard.set(newValue, forKey: jumpPriorityKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // Which of the three attention states the AUTOMATIC jump paths (idle auto-jump,
    // answered-chain) may target. The manual hotkey deliberately has no such filter —
    // excluding a bucket from an action you have to press is pointless ("don't want to
    // go? don't press"), while excluding it from something that happens on its own is
    // the whole question of "may this interrupt me". Membership only: the ORDER always
    // comes from jumpPriority, so there is exactly one source of truth for it (which
    // statusDisplayOrder also derives from).
    // Factory value is verbatim what both auto paths used to hardcode, so an upgrade
    // changes nothing until the user touches the pills.
    static let jumpAutoDefault = ["paused", "needs"]
    private static let jumpAutoStatusesKey = "jumpAutoStatuses"

    static var jumpAutoStatuses: [String] {
        get {
            guard let saved = UserDefaults.standard.array(forKey: jumpAutoStatusesKey) as? [String]
            else { return jumpAutoDefault }
            let valid = saved.filter { jumpStatuses.contains($0) }
            let deduped = valid.reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }
            // Empty would silently disable auto-jump while its two switches still read
            // "on" — a trap with no visible cause. The UI refuses to clear the last
            // pill; this covers a hand-written `defaults write` too.
            return deduped.isEmpty ? jumpAutoDefault : deduped
        }
        set { UserDefaults.standard.set(newValue, forKey: jumpAutoStatusesKey) }
    }

    // The only thing the two automatic jump paths should ever read: user's order,
    // user's membership. Strict bucketing downstream is unchanged.
    static var jumpAutoPriority: [String] {
        jumpPriority.filter { jumpAutoStatuses.contains($0) }
    }

    // The order status indicators render in — the group-header count dots (both the
    // per-folder pill and the global header pill) and the by-status group order. The
    // three attention states (needs/paused/done) follow the user's jumpPriority so the
    // lights tell the same story as the jump hotkey; working/idle are never jump
    // targets, so they always trail. Purely a display order for the indicators — it
    // never reorders the session rows themselves. Recomputed on read, so it tracks
    // jumpPriority live (that setter posts didChange → the list reloads).
    static var statusDisplayOrder: [String] {
        // "await" trails the jump buckets for the same reason working/idle do: it is
        // not a jump target. It still has to be listed, or the by-status grouping
        // (which iterates this) would drop every waiting session off the list.
        jumpPriority + ["await", "working", "idle"].filter { !jumpPriority.contains($0) }
    }

    // MARK: Appearance
    //
    // Whole-app light/dark override. `.system` (default) follows macOS; the other
    // two force NSApp.appearance. Views track the flip through the standard
    // effectiveAppearance machinery — no re-render notification needed.
    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return L("跟随系统", "System")
            case .light:  return L("浅色", "Light")
            case .dark:   return L("深色", "Dark")
            }
        }
    }

    private static let appearanceKey = "appearance"

    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
            applyAppearance()
        }
    }

    // Push the saved choice onto NSApp (nil = follow system). Called at launch
    // and on every change from the settings window.
    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Focus ring style
    //
    // The animation drawn around the target terminal pane after a jump
    // (FocusRing.swift). `off` disables it entirely; the other cases pick the
    // effect. Read at highlight/show time — no re-render notification needed.
    enum RingStyle: String, CaseIterable {
        case off, breath, ripple, sweep, corners, converge, neon, ants
        var title: String {
            switch self {
            case .off:      return L("不显示", "Off")
            case .breath:   return L("光晕呼吸", "Breath")
            case .ripple:   return L("波纹扩散", "Ripple")
            case .sweep:    return L("流光环绕", "Sweep")
            case .corners:  return L("四角对焦", "Corners")
            case .converge: return L("锁定收束", "Converge")
            case .neon:     return L("霓虹通电", "Neon")
            case .ants:     return L("虚线行军", "Marching Ants")
            }
        }
    }

    // MARK: Jump caption style
    //
    // The label drawn at the top-center of the one-shot focus ring (project + task
    // summary), so a glance at where you landed also names WHAT that session is.
    // Global (not per-status); read at ring-build time. The style popup carries its
    // own off switch: `.hidden` means no caption is drawn (there's no separate
    // on/off toggle — the style *is* the switch). The four visible treatments come
    // from the design shortlist Design/ring-caption.html:
    //   hidden      — 不显示（关闭跳转标签）
    //   outlineDot  — 通透药丸描边 + 前置红点（方案 21）
    //   accentRule  — 深底药丸 + 左侧竖条（方案 23）
    //   segmented   — accent 段项目 + 玻璃段任务（方案 2）
    //   titlebar    — 框顶外置标题栏，高亮动画环绕 bar+pane 整体 + 右侧 ✕ 手动关闭（titlebar-above-ring.html 方案 A）
    enum CaptionStyle: String, CaseIterable {
        case hidden, outlineDot, accentRule, segmented, titlebar
        var title: String {
            switch self {
            case .hidden:     return L("不显示", "Off")
            case .outlineDot: return L("描边圆点", "Outline + dot")
            case .accentRule: return L("深底竖条", "Accent rule")
            case .segmented:  return L("双段胶囊", "Segmented")
            case .titlebar:   return L("标题栏", "Title bar")
            }
        }
    }

    // Whether the jump caption is drawn at all. Now derived from the style popup
    // (`.hidden` = off) rather than a standalone toggle. Still subordinate to
    // `highlightsEnabled` (master off = nothing drawn at all). Read-only; callers
    // switch it by setting `captionStyle`.
    static var captionEnabled: Bool { captionStyle != .hidden }

    private static let captionStyleKey = "captionStyle"

    static var captionStyle: CaptionStyle {
        // Locked reads as .hidden: the style IS the switch, so this is where the caption
        // stands down — and it covers captionOnFocusClick too, which is subordinate to
        // captionEnabled. The chosen style stays on disk and comes back on unlock.
        get {
            guard Pro.enabled(.highlights) else { return .hidden }
            return CaptionStyle(rawValue: UserDefaults.standard.string(forKey: captionStyleKey) ?? "") ?? .titlebar
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: captionStyleKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Caption stay duration
    //
    // How long the CAPTION stays on screen — independent of the ring. The ring plays
    // its own animation and fades out on its rhythm as always; the caption lives this
    // much longer so there's time to read it. `forever` keeps the caption up until a
    // keystroke / click inside / app-switch dismisses it.
    enum CaptionDuration: String, CaseIterable {
        case s5, s10, s20, s30, forever
        var seconds: TimeInterval {
            switch self {
            case .s5: return 5
            case .s10: return 10
            case .s20: return 20
            case .s30: return 30
            case .forever: return -1
            }
        }
        var title: String {
            switch self {
            case .s5:      return L("5 秒", "5s")
            case .s10:     return L("10 秒", "10s")
            case .s20:     return L("20 秒", "20s")
            case .s30:     return L("30 秒", "30s")
            case .forever: return L("常驻显示", "Always")
            }
        }
    }

    private static let captionDurationKey = "captionDuration"

    static var captionDuration: CaptionDuration {
        get { CaptionDuration(rawValue: UserDefaults.standard.string(forKey: captionDurationKey) ?? "") ?? .forever }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: captionDurationKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Context gauge style
    //
    // How each session row visualizes its current context occupancy:
    // `capsule` (default, 变体 B) = the "used / limit" figure plus a colored percentage
    // capsule (tint tracks fullness, the absolute value stays orange). `bar` (变体 C) =
    // a right-aligned % with a full-width thin progress bar pinned along the row's
    // bottom edge (battery-style). Both tint green→amber→red by fullness. Changing it
    // posts didChange so the visible list re-renders in place — the list is the preview.
    enum ContextGaugeStyle: String, CaseIterable {
        case capsule, bar, off
        var title: String {
            switch self {
            case .capsule: return L("百分比胶囊", "Capsule")
            case .bar:     return L("底部细条", "Bottom bar")
            case .off:     return L("不显示", "Off")
            }
        }
    }

    private static let contextGaugeStyleKey = "contextGaugeStyle"

    static var contextGaugeStyle: ContextGaugeStyle {
        // Locked reads as .off rather than a dimmed gauge: the free row simply has no
        // gauge column, which is what the other metrics do when they're off too.
        get {
            guard Pro.enabled(.metrics) else { return .off }
            return ContextGaugeStyle(rawValue: UserDefaults.standard.string(forKey: contextGaugeStyleKey) ?? "") ?? .capsule
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: contextGaugeStyleKey)
            NotificationCenter.default.post(name: didChange, object: DisplayKey.contextGauge)
        }
    }

    // MARK: Per-status ring style + feature switches
    //
    // The ring is now customizable per session status: each of the five statuses
    // picks its own RingStyle (or `off`). This applies to every trigger — the
    // always-on rings, jump landings, and manual-click flashes. `checking` (the
    // transient watching-eye state) is never a ring target, so it's excluded.
    static let ringStyleStatuses = ["working", "done", "needs", "idle", "paused", "await"]

    // Statuses whose COLOR is user-adjustable (Settings → 状态颜色). Unlike
    // ringStyleStatuses this includes "checking" (the amber watching-eye overlay):
    // it's never a ring target, but it IS a visible dot/pill color worth theming.
    static let statusColorStatuses = ["needs", "working", "checking", "paused", "await", "done", "idle"]

    private static let ringStyleDefaults: [String: RingStyle] = [
        "working": .ripple, "done": .ripple, "needs": .converge,
        "idle": .breath, "paused": .ants, "await": .breath,
    ]

    static func ringStyle(for status: String) -> RingStyle {
        // Locked draws nothing at all. `highlightsEnabled` already stands the whole
        // feature down, so this is the second belt: it keeps the function honest on its
        // own terms instead of relying on every caller to consult the master switch
        // first. (Until T213 the locked tier fell back to the built-in defaults, so a
        // free jump still landed on a visible ring — that stopped making sense once the
        // free tier stopped jumping anywhere precise.)
        guard Pro.enabled(.highlights) else { return .off }
        if let raw = UserDefaults.standard.string(forKey: "ringStyle-\(status)"),
           let s = RingStyle(rawValue: raw) { return s }
        return ringStyleDefaults[status] ?? .breath
    }

    static func setRingStyle(_ style: RingStyle, for status: String) {
        UserDefaults.standard.set(style.rawValue, forKey: "ringStyle-\(status)")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Per-status color override (the single global status-color source)
    //
    // An optional custom color for a status, overriding the default semantic accent.
    // nil = follow the built-in accent. Status.accent(for:) reads this FIRST, so an
    // override flows to EVERY consumer of the status palette — the list rows, header
    // wash, status dots, count/agent pills, menu-bar capsule, toasts, the focus ring
    // and the caption — not just the ring. `fill` derives its white-text shade from
    // the override too. Stored as "#RRGGBB"; setting one posts didChange so the
    // whole UI (refresh() re-renders + always-on rings recolor) picks it up at once.
    // (Storage key is still "ringColor-<status>" for install continuity.)
    static func userColor(for status: String) -> NSColor? {
        guard let hex = UserDefaults.standard.string(forKey: "ringColor-\(status)") else { return nil }
        return NSColor(hexString: hex)
    }

    static func setUserColor(_ color: NSColor?, for status: String) {
        setUserColors([status: color])
    }

    // Batch variant for theme presets: writes every override, then posts a
    // single didChange (one full UI refresh instead of six).
    static func setUserColors(_ colors: [String: NSColor?]) {
        for (status, color) in colors {
            let key = "ringColor-\(status)"
            if let color { UserDefaults.standard.set(color.hexString, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        NotificationCenter.default.post(name: didChange, object: DisplayKey.statusColors)
    }

    private static let highlightsEnabledKey = "highlightsEnabled"

    // Master switch for the whole highlight feature. Off = nothing is ever drawn:
    // no always-on rings, no jump landing ring, no click flash. Default on so
    // existing installs keep their jump/click behavior. This is the settings
    // panel's one-tap "disable everything".
    //
    // It is also the one place the paid gate has to act for rings: locked reads as
    // off, and every ring path already routes through here, so a single gate stands
    // the whole feature down. The caption is gated separately — it can be drawn with
    // no ring at all (see captionOnFocusClick), so this switch alone wouldn't silence
    // it.
    static var highlightsEnabled: Bool {
        get { Pro.enabled(.highlights) && (UserDefaults.standard.object(forKey: highlightsEnabledKey) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: highlightsEnabledKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let ringAlwaysOnKey = "ringAlwaysOn"

    // Persistent mode: keep a steady status-colored ring on every VISIBLE Claude
    // terminal pane, not just a one-shot on jump/click. Default off (opt-in — it
    // continuously scans the VSCode accessibility tree). Subordinate to
    // `highlightsEnabled`.
    //
    // DEV-ONLY (`Build.isDev`): the continuous AX scan is the most expensive thing
    // the app does and its recolor path is the one always-on ring bug source
    // (docs/focus-ring.md), so it ships to nobody until that settles. In a release
    // build this getter is false regardless of what is stored, which switches off
    // every always-on branch in FocusRing at once — the same shape the paid gate
    // uses, and for the same reason: one getter, no scattered call-site checks.
    static var ringAlwaysOn: Bool {
        get { Build.isDev && Pro.enabled(.highlights) && UserDefaults.standard.bool(forKey: ringAlwaysOnKey) }   // default false
        set {
            UserDefaults.standard.set(newValue, forKey: ringAlwaysOnKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let cornerPipsKey = "cornerPips"

    // A status dot pinned in the top-right corner of every visible Claude terminal —
    // one per pane in the VSCode family, one per tab on a native Terminal/iTerm window.
    // Lets you read the state without leaving the terminal you are already looking at.
    //
    // Default off: it drives the same continuous AX scan the always-on rings do, and
    // that is not a cost to opt somebody into. Subordinate to `highlightsEnabled` — the
    // master switch means "don't draw on my terminals", and a pip is a drawing.
    //
    // NOT dev-gated, unlike `ringAlwaysOn` above. The two liabilities that keep the
    // always-on ring off release builds are both structural to THAT implementation —
    // its recolor ledger, and its .floating + "hide whenever the editor isn't frontmost"
    // policy. Pips own a separate ledger and sit at .normal anchored above the host
    // window, so neither is inherited (see StatusPip.swift).
    static var cornerPips: Bool {
        get { Pro.enabled(.highlights) && UserDefaults.standard.bool(forKey: cornerPipsKey) }   // default false
        set {
            UserDefaults.standard.set(newValue, forKey: cornerPipsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let ringOnFocusClickKey = "ringOnFocusClick"

    // Also flash the ring when the user manually clicks into a terminal (not
    // just on app-driven jumps). Subordinate to ringStyle — off kills both.
    static var ringOnFocusClick: Bool {
        get { Pro.enabled(.highlights) && (UserDefaults.standard.object(forKey: ringOnFocusClickKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: ringOnFocusClickKey) }
    }

    private static let captionOnFocusClickKey = "captionOnFocusClick"

    // Also show the caption when the user manually clicks into a terminal, even
    // when the ring itself is off (ringStyle .off, or ringOnFocusClick off). This
    // is what lets the label appear WITHOUT the ring: the caption's counterpart to
    // ringOnFocusClick. Subordinate to captionEnabled (captionStyle .hidden kills
    // it). Default on so clicking a terminal always names where you are.
    static var captionOnFocusClick: Bool {
        get { UserDefaults.standard.object(forKey: captionOnFocusClickKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: captionOnFocusClickKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let notifHighlightEnabledKey = "notifHighlightEnabled"

    // Whether a needs/done notification banner animates its icon in the matching
    // status's RingStyle (the ripple/converge/corners flourish the terminal ring
    // plays). Off = the banner still shows, its tile just holds a static status
    // frame with no animation. Independent of `highlightsEnabled` (that master is
    // the terminal rings) — this is the banner's own switch. Default on.
    static var notifHighlightEnabled: Bool {
        get { Pro.enabled(.highlights) && (UserDefaults.standard.object(forKey: notifHighlightEnabledKey) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: notifHighlightEnabledKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let autoJumpNextNeedsKey = "autoJumpNextNeeds"

    // When several sessions need you at once and you answer one, jump straight
    // to the next still-pending one (raise its terminal + draw the ring) so you
    // can clear them back-to-back. Default on; off stops the app stealing focus.
    static var autoJumpNextNeeds: Bool {
        get { Pro.enabled(.autoJump) && (UserDefaults.standard.object(forKey: autoJumpNextNeedsKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: autoJumpNextNeedsKey) }
    }

    private static let idleAutoJumpKey = "idleAutoJump"

    // When you've been idle (no mouse/keyboard) for `idleAutoJumpSeconds` and a
    // session is waiting on you ("needs"), auto-jump to its terminal — surfaces the
    // prompt the moment you step away, so you don't come back to a stalled session
    // you never noticed. Defaults OFF: it's the one setting that moves the frontmost
    // window without being asked, so it's opt-in rather than something a fresh
    // install springs on you.
    static var idleAutoJump: Bool {
        get { Pro.enabled(.autoJump) && (UserDefaults.standard.object(forKey: idleAutoJumpKey) as? Bool ?? false) }
        set { UserDefaults.standard.set(newValue, forKey: idleAutoJumpKey) }
    }

    private static let idleAutoJumpSecondsKey = "idleAutoJumpSeconds"

    // Idle-threshold presets (seconds of no input) the Settings popup offers.
    static let idleAutoJumpChoices = [0, 5, 10, 15, 30, 60]

    // How long you must be idle before an auto-jump fires. Default 5s.
    static var idleAutoJumpSeconds: Int {
        get {
            let v = UserDefaults.standard.object(forKey: idleAutoJumpSecondsKey) as? Int ?? 5
            return idleAutoJumpChoices.contains(v) ? v : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: idleAutoJumpSecondsKey) }
    }

    private static let breakReminderKey = "breakReminder"

    // The stretch-length nudge (BreakReminder.swift): a banner + the done chime once
    // you've been at the machine this long without a break. On by default — it moves
    // nothing and steals no focus, it only asks you to stand up.
    static var breakReminderEnabled: Bool {
        get { UserDefaults.standard.object(forKey: breakReminderKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: breakReminderKey) }
    }

    private static let breakReminderMinutesKey = "breakReminderMinutes"

    static let breakReminderChoices = [25, 30, 45, 60, 90, 120]

    static var breakReminderMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: breakReminderMinutesKey) as? Int ?? 60
            return breakReminderChoices.contains(v) ? v : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: breakReminderMinutesKey) }
    }

    private static let breakCountUpKey = "breakCountUp"

    // Which way the break timer's big figure runs: down to the break (default), or up
    // from the start of the round. Same figure the header chip shows — one switch, both
    // places, so they can never disagree.
    static var breakCountUp: Bool {
        get { UserDefaults.standard.bool(forKey: breakCountUpKey) }
        set { UserDefaults.standard.set(newValue, forKey: breakCountUpKey) }
    }

    private static let breakRestMinutesKey = "breakRestMinutes"

    static let breakRestChoices = [5, 10, 15, 20]

    // How long a break runs once you press 现在休息 (the cat's countdown).
    static var breakRestMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: breakRestMinutesKey) as? Int ?? 10
            return breakRestChoices.contains(v) ? v : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: breakRestMinutesKey) }
    }

    private static let usageProbeKey = "usageProbeEnabled"

    // The app-side `claude -p "/usage"` probe that keeps the header's
    // subscription-quota figures fresh. Off = the app never launches claude
    // itself (the hook's turn-end refresh still runs), so the % can go stale.
    static var usageProbeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: usageProbeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: usageProbeKey) }
    }

    // MARK: Alert sounds
    //
    // Which /System/Library/Sounds file the status hook plays on the two states the
    // user cares about. The hook (spectix-status.sh) actually plays the sound, so
    // the source of truth is a bare-name file it reads (~/.claude/spectix/sound-done
    // / sound-needs); the app only writes it. `soundOff` silences that state.
    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
                               "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
                               "Submarine", "Tink"]
    static let soundOff = "off"

    private static let soundDir = "\(NSHomeDirectory())/.claude/spectix"

    // Sound for the "done"(绿) transition. Defaults to Glass to match the hook.
    static var doneSound: String {
        get { readSound("sound-done", default: "Glass") }
        set { writeSound("sound-done", newValue) }
    }

    // Sound for the "needs"(红) transition. Defaults to Funk to match the hook.
    static var needsSound: String {
        get { readSound("sound-needs", default: "Funk") }
        set { writeSound("sound-needs", newValue) }
    }

    // Playback volume (0…1) the hook passes to `afplay -v` for both alert sounds.
    // 1.0 = full (afplay's default gain). Stored as a bare number in sound-volume;
    // defaults to full so an absent file behaves exactly as before.
    static var soundVolume: Double {
        get { min(1, max(0, Double(readSound("sound-volume", default: "1")) ?? 1)) }
        set { writeSound("sound-volume", String(format: "%.2f", min(1, max(0, newValue)))) }
    }

    private static func readSound(_ file: String, default def: String) -> String {
        let path = "\(soundDir)/\(file)"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return def }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? def : v
    }

    private static func writeSound(_ file: String, _ value: String) {
        try? FileManager.default.createDirectory(atPath: soundDir, withIntermediateDirectories: true)
        try? value.write(toFile: "\(soundDir)/\(file)", atomically: true, encoding: .utf8)
    }

    // MARK: Watch buzz (Bark push)
    //
    // A local macOS notification CANNOT reach an Apple Watch — watchOS only mirrors
    // notifications forwarded by the paired *iPhone*, and a Mac is not in that chain
    // (developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding).
    // So the only way to buzz the wrist without shipping an iOS+watchOS companion is
    // Mac → push service → APNs → iPhone → mirror → Watch. Bark is that service: free,
    // no account, the user just pastes the key its app shows them, and the server is
    // swappable (self-host) so we are not married to api.day.app.
    //
    // Same storage contract as the sounds above: the hook does the sending, the app
    // only writes the bare files it reads.
    static let barkDefaultServer = "https://api.day.app"

    // Base URL of the Bark server. Overridable so a self-hosted bark-server works.
    static var watchPushServer: String {
        get { readSound("push-server", default: barkDefaultServer) }
        set { writeSound("push-server", normalizeBarkServer(newValue)) }
    }

    // The device key from the Bark app. Empty = the whole feature is off; there is
    // deliberately no separate on/off toggle, since a key is the only thing that can
    // make it work and an enabled-but-keyless state would just be a silent no-op.
    static var watchPushKey: String {
        get { readSound("push-key", default: "") }
        set { writeSound("push-key", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var watchPushEnabled: Bool { !watchPushKey.isEmpty }

    // Whether "done"(绿) also buzzes. Off by default: `needs` is BLOCKING (the agent
    // sits there until you tap), `done` is merely informational, and a heavy user hits
    // done dozens of times an hour — buzzing on it is how you get the feature switched
    // off entirely.
    static var watchPushOnDone: Bool {
        get { readSound("push-done", default: "0") == "1" }
        set { writeSound("push-done", newValue ? "1" : "0") }
    }

    // Trim a pasted server URL down to a bare origin (no trailing slash), so both
    // "https://api.day.app" and "https://api.day.app/" behave the same in the hook,
    // which builds "$server/$key".
    static func normalizeBarkServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? barkDefaultServer : s
    }

    // The Bark app hands the user a whole test URL ("https://api.day.app/<key>/测试"),
    // not a bare key — and that is what they will paste. Split whatever they gave us
    // into (server, key) rather than making them do it: a paste that "should obviously
    // work" but doesn't is the #1 way this feature reads as broken.
    static func parseBarkPaste(_ raw: String) -> (server: String, key: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        guard s.lowercased().hasPrefix("http") else {
            // A bare key: keep whatever server is configured.
            let key = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return key.isEmpty ? nil : (watchPushServer, key)
        }
        guard let url = URL(string: s), let host = url.host else { return nil }
        // First non-empty path component is the device key; anything after it is the
        // sample title/body the Bark app tacked on, which we drop.
        let parts = url.path.split(separator: "/").map(String.init)
        guard let key = parts.first, !key.isEmpty else { return nil }
        let scheme = url.scheme ?? "https"
        let port = url.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", key)
    }
}
