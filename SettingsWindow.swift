import Cocoa

// A wrapping label that adapts to its container: it syncs preferredMaxLayoutWidth
// to its actual width each layout pass (so text wraps to whatever width the flexible
// column gives it) and reports no intrinsic width (so a long single line never
// forces the column — and thus the window — wider). Replaces the old fixed
// preferredMaxLayoutWidth that assumed a 440pt column.
// The permission "grant" indicator: a fixed square that never deforms on resize.
// Deliberately NOT an NSButton — NSButton's cell imposes a hidden minimum height
// (~29pt) via an internal required constraint that overrides an explicit height=24,
// squeezing the box into a rectangle. A plain layer-backed NSView has no cell, so
// its `side`×`side` intrinsic size plus width/height constraints are absolute.
final class SquareToggle: NSView {
    var side: CGFloat = 24
    var onClick: (() -> Void)?
    private let check = NSImageView()

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        check.translatesAutoresizingMaskIntoConstraints = false
        check.imageScaling = .scaleProportionallyDown
        check.contentTintColor = .white
        addSubview(check)
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let g = NSClickGestureRecognizer(target: self, action: #selector(fire))
        addGestureRecognizer(g)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc private func fire() { onClick?() }

    // Green filled when granted, hollow outline otherwise.
    func setGranted(_ ok: Bool, checkmark: NSImage?) {
        layer?.backgroundColor = (ok ? NSColor.systemGreen : .clear).cgColor
        layer?.borderColor = (ok ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        check.image = ok ? checkmark : nil
    }
}

extension SettingsPane {
    /// The keystroke both this pane and the launch alert ask for. One constant so the
    /// two can't drift into telling the user different things.
    static let reloadShortcut = "⌘⇧P → Reload Window"

    /// A tertiary note with the shortcut pulled up to full-contrast semibold. The note
    /// is skimmed, not read, so the only part that has to survive a glance is the part
    /// the user has to actually type.
    static func noteWithShortcut(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: Theme.font(11, .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: para,
        ])
        if let r = text.range(of: reloadShortcut) {
            s.addAttributes([.font: Theme.font(11, .semibold),
                             .foregroundColor: NSColor.labelColor],
                            range: NSRange(r, in: text))
        }
        return s
    }
}

final class WrappingLabel: NSTextField {
    static func make(_ string: String) -> WrappingLabel {
        let l = WrappingLabel(labelWithString: string)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.cell?.wraps = true
        l.cell?.isScrollable = false
        return l
    }
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width = NSView.noIntrinsicMetric
        return s
    }
}

// MARK: - Settings pane ("设置")
//
// Tab 4 of the main window (scheme 6). Holds every preference: global hotkeys,
// display toggles, focus-ring style (with a live preview), sounds, and the
// macOS-permission rows. Rebinding a hotkey calls back through onRebind, which
// the host persists and re-registers. Frost/base come from the host window's
// glass; the pane itself is transparent and scrolls its content column, which is
// centered at a fixed width so a widened window just gains side margins.
//
// The ring preview and the permission poller run only while this tab is on
// screen — the host calls paneDidAppear()/paneDidDisappear() on tab switch and
// window close (they'd otherwise animate/poll invisibly behind other tabs).
final class SettingsPane: NSView {

    var onRebind: ((HotKeyAction, HotKeyCombo?) -> OSStatus)?
    private var recorders: [HotKeyAction: HotKeyRecorderButton] = [:]
    private lazy var recoLine = RecommendedHotKeysLine { [weak self] on in self?.applyRecommended(on) }

    // Scroll view + the 已隐藏 section, which rebuilds itself from AppSettings on
    // every appearance / hidden-set change (it sits at the top of the column so a
    // deep-link from the HiddenBar lands right on it).
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let hiddenContainer = NSView()
    private let hiddenStack = NSStackView()
    private var hiddenHeightC: NSLayoutConstraint!
    private var restoreHandlers: [SoundHandler] = []
    private var hiddenObserver: NSObjectProtocol?

    // Sticky section nav pinned above the scroll view: each pill maps to one
    // section header in the column. Clicking a pill smooth-scrolls to that
    // section; scrolling highlights the pill of the section at the top
    // (scroll-spy). `sectionHeaders` are the header labels the spy measures
    // against; `suppressSpy` mutes the spy during a click-driven animated scroll
    // so it doesn't flicker through intermediate sections.
    private var sectionBar: SettingsSectionBar!
    private var sectionHeaders: [NSView] = []
    private var spyObserver: NSObjectProtocol?
    private var suppressSpy = false

    // The 显示 section's live preview card. Observes AppSettings only while this tab
    // is on screen, same as the ring preview below it.
    private var livePreview: LivePreviewCard!

    // Which section the NEXT pane to appear should land on, instead of the top.
    // Static because a theme switch destroys this whole view tree and builds a new
    // one (main.swift's rebuildUIWholesale) — the request has to outlive the
    // instance that made it, or picking a theme would bounce the user to the top of
    // the settings column. Consumed once.
    static var deepLinkSection: Int?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Called by the host when this tab becomes / stops being visible.
    func paneDidAppear() {
        replayRingPreview()
        livePreview.startObserving()
        startPermRefresh()
        rebuildHiddenSection()
        recoLine.refresh()
        // Land at the top so a HiddenBar deep-link shows the 已隐藏 section (top of
        // the column) rather than wherever the pane was last scrolled — unless a
        // rebuild asked for a specific section (a theme switch does).
        if let target = Self.deepLinkSection {
            Self.deepLinkSection = nil
            jumpToSection(target)
        } else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            sectionBar.select(0)   // top of the column = first section
        }
        // Keep the section live while shown — restoring elsewhere or another hide
        // posts didChange.
        if hiddenObserver == nil {
            hiddenObserver = NotificationCenter.default.addObserver(
                forName: AppSettings.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.rebuildHiddenSection()
                // The 各状态样式 rows tint themselves with the status accent, so a
                // color edited in the card above has to reach them too (their dots
                // repaint themselves; the row bed is ours).
                self?.highlightActiveStatusRow()
            }
        }
    }
    func paneDidDisappear() {
        stopRingPreview()
        livePreview.stopObserving()
        stopPermRefresh()
        if let obs = hiddenObserver { NotificationCenter.default.removeObserver(obs); hiddenObserver = nil }
    }

    // Seed each recorder with the currently-bound combo for its action.
    func setCombo(_ action: HotKeyAction, _ combo: HotKeyCombo?) {
        recorders[action]?.setCombo(combo)
        recoLine.refresh()
    }

    // Bind (or undo) the recommended ⌘1/⌘2 pair. Routes through the same onRebind
    // path the recorders use so persistence + Carbon registration stay in one place.
    // A combo another app already owns still gets persisted — the user asked for it —
    // but that row's recorder says so instead of showing a hotkey that can't fire.
    private func applyRecommended(_ on: Bool) {
        for action in HotKeyAction.allCases {
            let combo = on ? action.recommendedCombo : action.defaultCombo
            let status = onRebind?(action, combo) ?? noErr
            recorders[action]?.setCombo(combo)
            if status != noErr { recorders[action]?.flashTaken() }
        }
        recoLine.refresh()
    }

    private func buildUI() {
        // Content lives in a scroll view whose document (`doc`) carries the whole
        // top-down layout; base/glass come from the host window's glass.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Section nav pinned above the scroll view (built once; titles mirror the
        // five section headers below, in column order).
        // Seven pills already saturate the bar: at the window's default 476pt width,
        // .fillEqually gives each 61.7pt while the widest English label, "Permissions",
        // measures 70.3 — so it bleeds into its neighbours until the window is dragged
        // past ~485pt (the pill doesn't clip its label). Chinese labels are far shorter
        // and always fit. An eighth section would widen that overlap to every label, so
        // a new setting joins an existing section rather than opening one.
        sectionBar = SettingsSectionBar(titles: [
            L("快捷键", "Hotkeys"), L("主题", "Theme"), L("显示", "Display"),
            L("高亮", "Highlights"), L("提示音", "Sounds"), L("权限", "Permissions"),
            L("关于", "About"),
        ])
        addSubview(sectionBar)
        sectionBar.onSelect = { [weak self] i in self?.scrollToSection(i) }

        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        // Scroll-spy: highlight the pill of whichever section sits at the top.
        scroll.contentView.postsBoundsChangedNotifications = true
        spyObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.updateSpy() }

        // Everything hangs off a centered fixed-width column so a widened window
        // just gains side margins (the old settings window was a fixed 440pt).
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)


        // ── 已隐藏 section (top of the column) — a self-sizing container the
        // rebuild fills; collapses to 0 height when nothing is hidden.
        hiddenContainer.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(hiddenContainer)
        hiddenStack.orientation = .vertical
        hiddenStack.spacing = 8
        hiddenStack.alignment = .leading
        hiddenStack.translatesAutoresizingMaskIntoConstraints = false
        hiddenContainer.addSubview(hiddenStack)
        hiddenHeightC = hiddenContainer.heightAnchor.constraint(equalToConstant: 0)
        hiddenHeightC.isActive = true

        // ── Language + Appearance lead the whole column, above every section. They
        // are the two settings that change how everything BELOW them reads and looks,
        // so they can't sit buried inside 显示. No section title and no eighth pill:
        // seven is the pill ceiling (see above), and two labelled rows read fine as a
        // preamble to the first titled section.
        //
        // Always "Language", never localised: someone stuck in a language they can't
        // read finds this row by recognising the English word, not by translating it.
        let languageRow = makePopupRow(
            title: "Language",
            subtitle: L("界面显示语言（切换后即时生效）", "Interface language (applies immediately)"),
            items: AppSettings.Language.allCases.map(\.title),
            current: AppSettings.language.title,
            onChange: { picked in
                guard let choice = AppSettings.Language.allCases.first(where: { $0.title == picked })
                else { return }
                AppSettings.language = choice
            })
        column.addSubview(languageRow)

        let appearanceRow = makePopupRow(
            title: L("外观", "Appearance"),
            subtitle: L("浅色 / 深色主题，或跟随系统", "Light / dark theme, or follow the system"),
            items: AppSettings.Appearance.allCases.map(\.title),
            current: AppSettings.appearance.title,
            onChange: { picked in
                guard let choice = AppSettings.Appearance.allCases.first(where: { $0.title == picked })
                else { return }
                AppSettings.appearance = choice
            })
        column.addSubview(appearanceRow)

        let section = NSTextField(labelWithString: L("全局快捷键", "Global Hotkeys"))
        section.font = Theme.font(12, Theme.sectionTitleWeight)
        section.textColor = .secondaryLabelColor
        section.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(section)

        // One card per bindable action.
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 8
        rows.alignment = .leading
        rows.distribution = .fill
        rows.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(rows)

        for action in HotKeyAction.allCases {
            let row = makeRow(action)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        // The suggested ⌘1/⌘2 pair, offered once for both rows — the value is in the
        // adjacent pair, not in either key alone, and its cost only needs saying once.
        column.addSubview(recoLine)

        // Wrapping: the second sentence is the only pointer to where the jump-priority
        // card moved to, so it must not truncate away.
        let hint = WrappingLabel.make(L("点右侧按钮后按下组合键（需配合 ⌘⌥⌃⇧）；Esc 取消，⌫ 清除。跳转顺序与自动跳转范围在「高亮」段的「跳转优先级」里调整。", "Click the button on the right, then press a combo (needs ⌘⌥⌃⇧); Esc to cancel, ⌫ to clear. Jump order and auto-jump scope live in Highlights › Jump Priority."))
        hint.font = Theme.font(11, .regular)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(hint)

        // ── Theme section: the whole-app skin. First after the hotkeys because it is
        // the most global appearance choice there is — everything in 显示 below tunes
        // details WITHIN whichever theme is picked here. ──
        let themeSection = NSTextField(labelWithString: L("主题", "Theme"))
        themeSection.font = Theme.font(12, Theme.sectionTitleWeight)
        themeSection.textColor = .secondaryLabelColor
        themeSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(themeSection)

        let themeCard = ThemeChooserCard()
        // Switching rebuilds every window (main.swift's themeDidChange), which throws
        // this very view away — so record where to land BEFORE the switch, and make
        // it on the next runloop turn rather than inside the click handler that is
        // still walking this view tree.
        themeCard.onPick = { id in
            Self.deepLinkSection = 1
            DispatchQueue.main.async { AppSettings.themeID = id }
        }
        // The theme card states which palette is in use, but the 状态颜色 card below
        // owns the list — so it answers, and 更改 just scrolls there (§显示, index 2).
        themeCard.currentPaletteName = { [weak self] in
            guard let self, let i = self.themeSelection else { return L("自定义", "Custom") }
            return Self.colorThemes()[i].name
        }
        themeCard.onEditColors = { [weak self] in self?.jumpToSection(2) }
        themeChooser = themeCard
        column.addSubview(themeCard)

        // ── Display section: toggles for what each row shows ──
        let displaySection = NSTextField(labelWithString: L("显示", "Display"))
        displaySection.font = Theme.font(12, Theme.sectionTitleWeight)
        displaySection.textColor = .secondaryLabelColor
        displaySection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(displaySection)

        // 显示 splits in two (方案 8): 应用 holds the settings that act on the whole app
        // and leads the section; 列表 follows with everything the preview card can
        // demonstrate. Language + 外观 used to open this group — they now lead the whole
        // column instead (top of buildUI), being the two settings that govern every
        // other one below them.
        let appSubhead = makeSubsectionHeader(L("应用", "App"),
                                              note: L("作用于整个 App", "Applies to the whole app"))
        column.addSubview(appSubhead)

        // Turning tips back on re-arms every one of them: the only reason to flip this
        // switch on is wanting to see them again, so "on" that shows nothing would be a
        // dead control. Also the one way to re-test them without touching defaults(1).
        let tipsRow = makeToggleRow(
            title: L("功能提示", "Feature tips"),
            subtitle: L("首次遇到时提示一次可拖动、可右键等用法；重新开启会再显示一遍",
                        "Hint each hidden affordance once, the first time it's relevant; switching back on replays them"),
            isOn: AppSettings.featureTipsEnabled,
            onChange: { on in
                AppSettings.featureTipsEnabled = on
                if on { AppSettings.resetTips() }
            })
        column.addSubview(tipsRow)

        // Closes the 应用 group: the only setting here that outlives the running app.
        // Its switch reflects the SYSTEM's login-item state, so a refusal must not leave
        // it lying — bounce it back to the truth and open the one place that can grant it.
        var launchRowRef: NSView?
        let launchRow = makeToggleRow(
            title: L("开机自动启动", "Launch at login"),
            subtitle: L("登录 macOS 后自动运行 SpectiX（系统设置 → 通用 → 登录项里也能改）",
                        "Start SpectiX when you log in to macOS (also listed in System Settings → General → Login Items)"),
            isOn: AppSettings.launchAtLogin,
            onChange: { on in
                guard !AppSettings.setLaunchAtLogin(on) else { return }
                if let sw = launchRowRef?.subviews.compactMap({ $0 as? NSSwitch }).first {
                    sw.state = AppSettings.launchAtLogin ? .on : .off
                }
                AppSettings.openLoginItemsSettings()
            })
        launchRowRef = launchRow
        column.addSubview(launchRow)

        // 演示模式 is dev-only (`Build.isDev`): a release build never creates the row,
        // and `AppSettings.demoMode` reads false there to match, so 列表 simply stacks
        // under 开机自动启动 instead (hence `underApp` below rather than a hard
        // reference to this row).
        let demoRow: NSView? = Build.isDev ? makeToggleRow(
            title: L("演示模式", "Demo mode"),
            subtitle: L("用一组虚构的会话、配额和统计替换全部真实数据，方便截图和录屏",
                        "Replace every real figure — sessions, quota, stats — with a scripted fake world, for screenshots and recordings"),
            isOn: AppSettings.demoMode,
            dev: true,
            onChange: { AppSettings.demoMode = $0 }) : nil
        let underApp: NSView = demoRow ?? launchRow
        if let demoRow {
            column.addSubview(demoRow)
            NSLayoutConstraint.activate([
                demoRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Theme.pad),
                demoRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
                demoRow.topAnchor.constraint(equalTo: launchRow.bottomAnchor, constant: 8),
            ])
        }

        let listSubhead = makeSubsectionHeader(L("列表", "List"),
                                               note: L("作用于会话列表", "Applies to the session list"))
        column.addSubview(listSubhead)

        // A real session list pinned above the switches that drive it (方案 3): every
        // toggle below acts on this one card, so it always shows the settings COMBINED,
        // and the element a setting controls flashes right after it changes.
        livePreview = LivePreviewCard()
        column.addSubview(livePreview)

        let toggleRow = makeToggleRow(
            title: L("状态标签", "Status labels"),
            subtitle: L("在每个会话后显示「运行 / 完成 / 确认 / 闲置」", "Show \"Busy / Done / Wait / Idle\" after each session"),
            isOn: AppSettings.showStatusLabels,
            onChange: { AppSettings.showStatusLabels = $0 })
        column.addSubview(toggleRow)

        // The metric switches follow the order the row paints them in, left to right:
        // ⏱ 时长 · ◆ tokens · % · [模型] · ▸ 步骤. Turning one off closes its column up and
        // slides everything to its right left — visible immediately in the card above.
        let durationRow = makeToggleRow(
            title: L("工作时长", "Working time"),
            subtitle: L("在每个会话行显示 ⏱ 本次累计工作时长；关闭后右边各列一并左移",
                        "Show ⏱ accumulated working time on each row; off closes its column up"),
            isOn: AppSettings.showDuration,
            pro: .metrics,
            onChange: { AppSettings.showDuration = $0 })
        column.addSubview(durationRow)

        let tokensRow = makeToggleRow(
            title: L("Tokens", "Tokens"),
            subtitle: L("在每个会话行显示 ◆ 当前上下文的 token 数（和下面的百分比同源，可以只留一个）",
                        "Show ◆ the session's context in raw tokens (same figure the percentage below is derived from — keeping just one is fine)"),
            isOn: AppSettings.showTokens,
            pro: .metrics,
            onChange: { AppSettings.showTokens = $0 })
        column.addSubview(tokensRow)

        let sortRow = makePopupRow(
            title: L("排序", "Sort"),
            subtitle: L("自定义手动拖拽；按状态时「确认」的会话自动置顶", "Custom = drag manually; By status auto-pins sessions needing attention"),
            items: AppSettings.SortMode.allCases.map(\.title),
            current: AppSettings.sortMode.title,
            onChange: { picked in
                guard let choice = AppSettings.SortMode.allCases.first(where: { $0.title == picked })
                else { return }
                AppSettings.sortMode = choice
            })
        column.addSubview(sortRow)

        let gaugeRow = makePopupRow(
            title: L("上下文占用", "Context gauge"),
            subtitle: L("每个会话行显示当前上下文占用（百分比胶囊 / 底部细条；列表即时预览）", "Show each session's context occupancy (percentage capsule / bottom bar; the list previews live)"),
            items: AppSettings.ContextGaugeStyle.allCases.map(\.title),
            current: AppSettings.contextGaugeStyle.title,
            pro: .metrics,
            onChange: { picked in
                guard let choice = AppSettings.ContextGaugeStyle.allCases.first(where: { $0.title == picked })
                else { return }
                AppSettings.contextGaugeStyle = choice
            })
        column.addSubview(gaugeRow)

        let modelRow = makeToggleRow(
            title: L("模型标签", "Model label"),
            subtitle: L("在每个会话行末尾显示当前模型胶囊（Opus 紫 / Sonnet 青 / Haiku 琥珀）",
                        "Show the current model as a chip at the end of each session row (Opus violet / Sonnet teal / Haiku amber)"),
            isOn: AppSettings.showModelLabel,
            pro: .metrics,
            onChange: { AppSettings.showModelLabel = $0 })
        column.addSubview(modelRow)

        let stepRow = makeToggleRow(
            title: L("当前步骤", "Current step"),
            subtitle: L("运行中显示正在跑的工具（▸ Bash · git push），以及后台 shell 提示；关闭后只留时长 / tokens",
                        "While running, show the tool in flight (▸ Bash · git push) plus background-shell notices; off keeps just time / tokens"),
            isOn: AppSettings.showStepLabel,
            onChange: { AppSettings.showStepLabel = $0 })
        column.addSubview(stepRow)

        let shellRow = makeToggleRow(
            title: L("命令标记", "Command tag"),
            subtitle: L("前台跑命令时状态照旧是「运行中」，标题右侧多一个 bash 小标签（后台命令有自己的「等待」状态）",
                        "A foreground command keeps the row 运行中; a small bash tag beside the title says so (a backgrounded command gets its own 等待 status)"),
            isOn: AppSettings.showShellBadge,
            onChange: { AppSettings.showShellBadge = $0 })
        column.addSubview(shellRow)

        let colorsCard = makeStatusColorsCard()
        column.addSubview(colorsCard)

        // ── Highlight section: master switch, always-on, per-status styles, and a
        // live preview. The three subordinate rows dim + disable when the master
        // (启用高亮) is off — off means nothing is ever drawn. ──
        let ringSection = NSTextField(labelWithString: L("高亮", "Highlights"))
        ringSection.font = Theme.font(12, Theme.sectionTitleWeight)
        ringSection.textColor = .secondaryLabelColor
        ringSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(ringSection)

        // The one failure that looks like a bug rather than a missing step: the ring is
        // drawn from what the editor extension reports, and an editor loads its
        // extensions at startup — so a window that was already open when SpectiX was
        // installed draws nothing, while jumps keep working normally (T226). One line,
        // because this is a note somebody skims on their way to the switch below, not
        // something they came here to read.
        let ringNote = WrappingLabel.make("")
        ringNote.attributedStringValue = Self.noteWithShortcut(L(
            "高亮不出现？在编辑器里按 \(Self.reloadShortcut) 重载一次。",
            "No highlight? Press \(Self.reloadShortcut) in your editor."))
        ringNote.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(ringNote)

        let masterRow = makeToggleRow(
            title: L("启用高亮", "Enable highlights"),
            subtitle: L("总开关；关闭后常驻圈、跳转落点、点击闪圈一律不画", "Master switch; off = nothing is ever drawn"),
            isOn: AppSettings.highlightsEnabled,
            pro: .highlights,
            onChange: { [weak self] on in
                AppSettings.highlightsEnabled = on
                self?.applyHighlightMaster(on)
            })
        column.addSubview(masterRow)

        // 常驻显示 is dev-only (`Build.isDev`): a release build doesn't create the
        // row at all, and `AppSettings.ringAlwaysOn` reads false there to match, so
        // the section simply closes over the gap. Everything below stacks under
        // `underMaster` rather than under this row for exactly that reason.
        let alwaysOnRow: NSView? = Build.isDev ? makeToggleRow(
            title: L("常驻显示", "Always-on"),
            subtitle: L("在每个可见的 Claude terminal 上常驻一圈状态色描边", "Keep a status-colored ring on every visible Claude terminal"),
            isOn: AppSettings.ringAlwaysOn,
            dev: true,
            onChange: { AppSettings.ringAlwaysOn = $0 }) : nil
        let underMaster: NSView = alwaysOnRow ?? masterRow

        // Ships to everybody, unlike 常驻显示 right above it — see AppSettings.cornerPips
        // for why the always-on ring's dev gate doesn't apply to pips.
        // The dot itself is demoed inside the per-status style preview (replayRingPreview)
        // rather than beside this row — one unified demo, per the user's call.
        let pipRow = makeToggleRow(
            title: L("终端状态点", "Terminal status dot"),
            subtitle: L("在每个终端左上角、以及终端标签列表里那一行上常驻一个状态点，不用切回来就知道哪个在等你",
                        "Keep a status dot in each terminal's top-left corner and on its row in the tab list"),
            isOn: AppSettings.cornerPips,
            pro: .highlights,
            onChange: { [weak self] on in
                AppSettings.cornerPips = on
                self?.replayRingPreview()   // the unified preview shows/hides the dot
            })
        column.addSubview(pipRow)

        if let alwaysOnRow {
            column.addSubview(alwaysOnRow)
            NSLayoutConstraint.activate([
                alwaysOnRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Theme.pad),
                alwaysOnRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
                alwaysOnRow.topAnchor.constraint(equalTo: masterRow.bottomAnchor, constant: 8),
            ])
        }

        let clickFlashRow = makeToggleRow(
            title: L("点击终端时也显示", "Also show on terminal click"),
            subtitle: L("手动点进某个 terminal 时，在它边框上闪一次", "Flash the border once when you manually click into a terminal"),
            isOn: AppSettings.ringOnFocusClick,
            pro: .highlights,
            onChange: { AppSettings.ringOnFocusClick = $0 })
        column.addSubview(clickFlashRow)

        let captionCard = makeCaptionCard()
        column.addSubview(captionCard)
        self.captionCard = captionCard

        let stylesCard = makeRingStylesCard()
        column.addSubview(stylesCard)

        // These two build their own layout instead of going through makeToggleRow, so
        // the paid lock is applied by hand rather than via a `pro:` argument.
        applyProLock(captionCard, .highlights)
        applyProLock(stylesCard, .highlights)

        highlightSubordinates = [alwaysOnRow, pipRow, clickFlashRow, captionCard, stylesCard].compactMap { $0 }

        // Drag-reorder + auto-membership card for the jump buckets. Sits here rather
        // than in the hotkey section because its 自动 pills govern the two auto-jump
        // switches right below it. Deliberately NOT in highlightSubordinates: killing
        // the master highlight switch stops the rings, not the jumping.
        //
        // It does follow the auto-jump PAID gate though: what it configures is which
        // sessions auto-jump visits and in what order, which is nothing at all once
        // auto-jump itself is locked.
        let priorityCard = JumpPriorityCard()
        column.addSubview(priorityCard)
        applyProLock(priorityCard, .autoJump)

        let autoJumpRow = makeToggleRow(
            title: L("连续确认自动跳转", "Auto-jump to next prompt"),
            subtitle: L("有多个待确认时，答完一个自动跳到下一个并高亮", "When several need you, jump to the next after you answer one"),
            isOn: AppSettings.autoJumpNextNeeds,
            pro: .autoJump,
            onChange: { AppSettings.autoJumpNextNeeds = $0 })
        column.addSubview(autoJumpRow)

        let idleJumpRow = makeIdleJumpRow()
        column.addSubview(idleJumpRow)
        applyProLock(idleJumpRow, .autoJump)

        // The needs/done notification banner's own highlight switch — it reuses the
        // per-status RingStyle above, so it belongs in the Highlights section.
        let notifHighlightRow = makeToggleRow(
            title: L("通知横幅高亮", "Notification banner highlight"),
            subtitle: L("需确认 / 完成横幅的图标按对应状态的高亮样式做动画（波纹 / 收束 / 四角…）；关闭后只留静态状态色",
                        "Animate the needs/done banner icon in its status's highlight style (ripple / converge / corners…); off = a static status frame only"),
            isOn: AppSettings.notifHighlightEnabled,
            pro: .highlights,
            onChange: { AppSettings.notifHighlightEnabled = $0; ToastManager.shared.refreshHighlights() })
        column.addSubview(notifHighlightRow)

        // ── Sound section: which system sound the hook plays on each transition ──
        let soundSection = NSTextField(labelWithString: L("提示音", "Sounds"))
        soundSection.font = Theme.font(12, Theme.sectionTitleWeight)
        soundSection.textColor = .secondaryLabelColor
        soundSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(soundSection)

        let doneSoundRow = makeSoundRow(
            title: L("完成提示音", "Done sound"),
            subtitle: L("轮次结束（绿）时播放", "Plays when a turn ends (green)"),
            current: AppSettings.doneSound,
            onChange: { AppSettings.doneSound = $0 })
        column.addSubview(doneSoundRow)

        let needsSoundRow = makeSoundRow(
            title: L("需确认提示音", "Needs-attention sound"),
            subtitle: L("出现权限弹窗 / 等你确认（红）时播放", "Plays on a permission prompt / when it needs you (red)"),
            current: AppSettings.needsSound,
            onChange: { AppSettings.needsSound = $0 })
        column.addSubview(needsSoundRow)

        let volumeRow = makeVolumeRow()
        column.addSubview(volumeRow)

        // The watch buzz lives under 提示音 rather than opening its own section: it is
        // another way of being told the same two transitions, and the nav bar above is
        // already at its seven-pill ceiling.
        let watchPushRow = makeWatchPushRow()
        column.addSubview(watchPushRow)

        let watchDoneRow = makeToggleRow(
            title: L("完成时也震手表", "Buzz on done too"),
            subtitle: L("默认只有「需确认」才震 —— 那是真的卡住等你；「完成」一天几十次，全震会把你震到关掉这个功能",
                        "Only needs-attention buzzes by default — that one is actually blocked on you; done fires dozens of times a day and buzzing on it is how you end up turning this off"),
            isOn: AppSettings.watchPushOnDone,
            onChange: { AppSettings.watchPushOnDone = $0 })
        column.addSubview(watchDoneRow)

        // The three ways this silently doesn't buzz, all of them Apple's behaviour and
        // none of them fixable from our side — so they get said up front instead of
        // becoming support mail.
        let watchHint = WrappingLabel.make(
            L("手表不震的常见原因：① 手机正解锁着用 —— 通知会留在手机上，这是系统设计；② 手表没戴稳或没开「腕部检测」；",
              "Why the watch may not buzz: (1) your iPhone is unlocked and in use — the notification stays on the phone, by design; (2) the watch isn't snug or Wrist Detection is off; ")
            + L("③ 专注模式吞了 —— 到 iPhone 设置 → 通知 → Bark 里打开「时效性通知」。推送正文只有项目名和状态，经 Bark 服务器明文传输（服务器地址可自建替换）。",
                "(3) a Focus swallowed it — turn on Time Sensitive Notifications for Bark in iPhone Settings → Notifications. The push carries only the project name and status, in the clear via Bark's server (which you can self-host)."))
        watchHint.font = Theme.font(11, .regular)
        watchHint.textColor = .tertiaryLabelColor
        watchHint.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(watchHint)

        // ── Break section: the one nudge that is about you, not a session ──
        let breakSection = NSTextField(labelWithString: L("休息提醒", "Breaks"))
        breakSection.font = Theme.font(12, Theme.sectionTitleWeight)
        breakSection.textColor = .secondaryLabelColor
        breakSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(breakSection)

        let breakRow = makeBreakReminderRow()
        column.addSubview(breakRow)

        // ── Permissions section: live status of the one macOS permission the app
        // actually needs, with why it's needed and a shortcut to grant it ──
        let permSection = NSTextField(labelWithString: L("系统权限", "System Permissions"))
        permSection.font = Theme.font(12, Theme.sectionTitleWeight)
        permSection.textColor = .secondaryLabelColor
        permSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(permSection)

        // Not just the TCC bit: the grant can read as on while every AX call comes back
        // empty (see AppController.axDegraded). Showing 已授权 then would send the user
        // hunting for the bug anywhere but here.
        let axWorks = { AXIsProcessTrusted() && !AppController.axDegraded }
        let axRow = makePermissionRow(
            title: L("辅助功能", "Accessibility"),
            subtitle: L("跳转时抬起目标 VSCode 窗口、画落点高亮圈、检测桌面版 Claude 状态", "Raise the target VSCode window on jump, draw the landing ring, detect Claude desktop status"),
            isGranted: axWorks,
            request: {
                // Clear a stale record before asking (AppController.resetAccessibilityGrant).
                // Without this the system stays silent — it already holds an answer for this
                // bundle id — and the row the user then finds in System Settings can be bound
                // to a copy of the app that no longer exists, so turning it off and on again
                // changes nothing. Only when the grant is genuinely broken: a working one
                // must never be thrown away by a stray click on this switch.
                if !axWorks() { AppController.resetAccessibilityGrant() }
                // Register the app in the Accessibility list, then land on the pane.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            })
        column.addSubview(axRow)

        let usageRow = makeWrapToggleRow(
            title: L("读取 Claude 用量", "Read Claude usage"),
            subtitle: L("后台运行 claude -p \"/usage\" 获取订阅配额（会话 % / 本周 %）显示在列表头部。", "Runs claude -p \"/usage\" in the background to fetch subscription quota (session % / week %) shown in the list header.")
                + L("只在本机执行、不需要系统权限、不上传任何数据；关闭后配额数字可能不及时。", "Runs locally only, needs no system permission, uploads nothing; when off the quota figures may lag."),
            isOn: AppSettings.usageProbeEnabled,
            onChange: { AppSettings.usageProbeEnabled = $0 })
        column.addSubview(usageRow)

        // The diagnostics export sits with the permissions because that is where
        // someone whose ring never shows ends up looking — and the file it writes is
        // what turns "it doesn't work" into which of the four look-alike failures it is
        // (DiagnosticsReport). Save panel, so it needs no folder permission of its own.
        let diagRow = makeActionRow(
            title: L("导出诊断记录", "Export diagnostics"),
            subtitle: L("高亮或跳转不对劲时点这里，把生成的文本文件发到反馈页。只含 SpectiX 自己的运行记录 —— 权限状态、扩展有没有加载、最近的跳转 / 高亮日志 —— 不含你的代码和对话。",
                        "If highlights or jumps misbehave, export this and attach it to your feedback. It holds only SpectiX's own records — permission state, whether the extension is loaded, recent jump / ring logs — never your code or conversations."),
            button: L("导出…", "Export…"),
            action: { [weak self] in DiagnosticsReport.export(from: self?.window) })
        column.addSubview(diagRow)

        let permHint = WrappingLabel.make(
            L("SpectiX 只需要以上两项系统权限。若弹出「文件与文件夹」「访问其他 App 的数据」等请求，", "SpectiX needs only the two system permissions above. If prompted for \"Files and Folders\", \"access other apps' data\", etc., ")
            + L("全部拒绝也不影响任何功能 —— 本 App 只读写 ~/.claude 与 ~/.codex 下的自有状态文件，外加 Codex 会话自己的记录文件（只读，用于显示 token 与配额）。", "you can deny them all without affecting anything — this app only reads/writes its own state files under ~/.claude and ~/.codex, plus Codex's own session log (read-only, for the token and quota figures)."))
        permHint.font = Theme.font(11, .regular)
        permHint.textColor = .tertiaryLabelColor
        permHint.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(permHint)

        // ── About section: version, and the one link that leaves this app. Last
        // because it is reference material, not a setting — nothing here changes
        // how the app behaves. ──
        let aboutSection = NSTextField(labelWithString: L("关于", "About"))
        aboutSection.font = Theme.font(12, Theme.sectionTitleWeight)
        aboutSection.textColor = .secondaryLabelColor
        aboutSection.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(aboutSection)

        let aboutCard = AboutCard()
        column.addSubview(aboutCard)

        // The section headers the scroll-spy measures against, in column order.
        sectionHeaders = [section, themeSection, displaySection, ringSection, soundSection,
                          permSection, aboutSection]

        let lead = column.leadingAnchor
        NSLayoutConstraint.activate([
            sectionBar.topAnchor.constraint(equalTo: topAnchor),
            sectionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: sectionBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),

            // Content column fills the document so a wider window widens every row.
            column.topAnchor.constraint(equalTo: doc.topAnchor),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: doc.trailingAnchor),

            hiddenContainer.topAnchor.constraint(equalTo: column.topAnchor, constant: 6),
            hiddenContainer.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            hiddenContainer.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            hiddenStack.topAnchor.constraint(equalTo: hiddenContainer.topAnchor),
            hiddenStack.leadingAnchor.constraint(equalTo: hiddenContainer.leadingAnchor),
            hiddenStack.trailingAnchor.constraint(equalTo: hiddenContainer.trailingAnchor),

            // ── Column preamble: the two app-wide settings, above every section ──
            languageRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            languageRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            languageRow.topAnchor.constraint(equalTo: hiddenContainer.bottomAnchor, constant: 6),

            appearanceRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            appearanceRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            appearanceRow.topAnchor.constraint(equalTo: languageRow.bottomAnchor, constant: 8),

            section.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            section.topAnchor.constraint(equalTo: appearanceRow.bottomAnchor, constant: 18),

            rows.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            rows.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            rows.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 8),

            recoLine.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            recoLine.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            recoLine.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 10),

            hint.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            hint.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            hint.topAnchor.constraint(equalTo: recoLine.bottomAnchor, constant: 10),

            themeSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            themeSection.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),

            themeCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            themeCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            themeCard.topAnchor.constraint(equalTo: themeSection.bottomAnchor, constant: 8),

            displaySection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            displaySection.topAnchor.constraint(equalTo: themeCard.bottomAnchor, constant: 18),

            // ── 应用 group: acts on the whole app, not on the list. ──
            appSubhead.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            appSubhead.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            appSubhead.topAnchor.constraint(equalTo: displaySection.bottomAnchor, constant: 6),

            tipsRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            tipsRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            tipsRow.topAnchor.constraint(equalTo: appSubhead.bottomAnchor, constant: 7),

            launchRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            launchRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            launchRow.topAnchor.constraint(equalTo: tipsRow.bottomAnchor, constant: 8),

            // ── 列表 group: the preview card and everything it can demonstrate ──
            listSubhead.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            listSubhead.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            listSubhead.topAnchor.constraint(equalTo: underApp.bottomAnchor, constant: 14),

            livePreview.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            livePreview.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            livePreview.topAnchor.constraint(equalTo: listSubhead.bottomAnchor, constant: 7),

            toggleRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            toggleRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            toggleRow.topAnchor.constraint(equalTo: livePreview.bottomAnchor, constant: 10),

            durationRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            durationRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            durationRow.topAnchor.constraint(equalTo: toggleRow.bottomAnchor, constant: 8),

            tokensRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            tokensRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            tokensRow.topAnchor.constraint(equalTo: durationRow.bottomAnchor, constant: 8),

            gaugeRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            gaugeRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            gaugeRow.topAnchor.constraint(equalTo: tokensRow.bottomAnchor, constant: 8),

            modelRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            modelRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            modelRow.topAnchor.constraint(equalTo: gaugeRow.bottomAnchor, constant: 8),

            stepRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            stepRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            stepRow.topAnchor.constraint(equalTo: modelRow.bottomAnchor, constant: 8),

            shellRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            shellRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            shellRow.topAnchor.constraint(equalTo: stepRow.bottomAnchor, constant: 8),

            sortRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            sortRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            sortRow.topAnchor.constraint(equalTo: shellRow.bottomAnchor, constant: 8),

            colorsCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            colorsCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            colorsCard.topAnchor.constraint(equalTo: sortRow.bottomAnchor, constant: 10),

            ringSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            ringSection.topAnchor.constraint(equalTo: colorsCard.bottomAnchor, constant: 18),

            ringNote.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            ringNote.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            ringNote.topAnchor.constraint(equalTo: ringSection.bottomAnchor, constant: 6),

            masterRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            masterRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            masterRow.topAnchor.constraint(equalTo: ringNote.bottomAnchor, constant: 8),

            pipRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            pipRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            pipRow.topAnchor.constraint(equalTo: underMaster.bottomAnchor, constant: 8),

            clickFlashRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            clickFlashRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            clickFlashRow.topAnchor.constraint(equalTo: pipRow.bottomAnchor, constant: 8),

            captionCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            captionCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            captionCard.topAnchor.constraint(equalTo: clickFlashRow.bottomAnchor, constant: 8),

            stylesCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            stylesCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            stylesCard.topAnchor.constraint(equalTo: captionCard.bottomAnchor, constant: 8),

            priorityCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            priorityCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            priorityCard.topAnchor.constraint(equalTo: stylesCard.bottomAnchor, constant: 8),

            autoJumpRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            autoJumpRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            autoJumpRow.topAnchor.constraint(equalTo: priorityCard.bottomAnchor, constant: 8),

            idleJumpRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            idleJumpRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            idleJumpRow.topAnchor.constraint(equalTo: autoJumpRow.bottomAnchor, constant: 8),

            notifHighlightRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            notifHighlightRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            notifHighlightRow.topAnchor.constraint(equalTo: idleJumpRow.bottomAnchor, constant: 8),

            soundSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            soundSection.topAnchor.constraint(equalTo: notifHighlightRow.bottomAnchor, constant: 18),

            doneSoundRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            doneSoundRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            doneSoundRow.topAnchor.constraint(equalTo: soundSection.bottomAnchor, constant: 8),

            needsSoundRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            needsSoundRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            needsSoundRow.topAnchor.constraint(equalTo: doneSoundRow.bottomAnchor, constant: 8),

            volumeRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            volumeRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            volumeRow.topAnchor.constraint(equalTo: needsSoundRow.bottomAnchor, constant: 8),

            watchPushRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            watchPushRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            watchPushRow.topAnchor.constraint(equalTo: volumeRow.bottomAnchor, constant: 8),

            watchDoneRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            watchDoneRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            watchDoneRow.topAnchor.constraint(equalTo: watchPushRow.bottomAnchor, constant: 8),

            watchHint.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            watchHint.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            watchHint.topAnchor.constraint(equalTo: watchDoneRow.bottomAnchor, constant: 10),

            breakSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            breakSection.topAnchor.constraint(equalTo: watchHint.bottomAnchor, constant: 18),

            breakRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            breakRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            breakRow.topAnchor.constraint(equalTo: breakSection.bottomAnchor, constant: 8),

            permSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            permSection.topAnchor.constraint(equalTo: breakRow.bottomAnchor, constant: 18),

            axRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            axRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            axRow.topAnchor.constraint(equalTo: permSection.bottomAnchor, constant: 8),

            usageRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            usageRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            usageRow.topAnchor.constraint(equalTo: axRow.bottomAnchor, constant: 8),

            permHint.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            permHint.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            diagRow.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            diagRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            diagRow.topAnchor.constraint(equalTo: usageRow.bottomAnchor, constant: 8),

            permHint.topAnchor.constraint(equalTo: diagRow.bottomAnchor, constant: 10),

            aboutSection.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            aboutSection.topAnchor.constraint(equalTo: permHint.bottomAnchor, constant: 18),

            aboutCard.leadingAnchor.constraint(equalTo: lead, constant: Theme.pad),
            aboutCard.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -Theme.pad),
            aboutCard.topAnchor.constraint(equalTo: aboutSection.bottomAnchor, constant: 8),
            aboutCard.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -Theme.pad),
        ])
        pinDocumentWidth(doc, filling: scroll)

        // Reflect the master switch's initial state (dim + disable subordinates
        // when highlights are off). Preview replay is left to paneDidAppear, which
        // fires once the pane has real geometry.
        let masterOn = AppSettings.highlightsEnabled
        for v in highlightSubordinates {
            v.alphaValue = masterOn ? 1 : 0.4
            setControlsEnabled(v, masterOn)
        }

        relaxLabelWidths()
    }

    // No label in this pane may set the window's minimum width — it truncates instead.
    //
    // The column lives in a scroll view whose document is pinned to the clip's width
    // (`doc.width == scroll.contentView.width` above). That constraint is bidirectional
    // and required, so a label's intrinsic width propagates all the way out: column →
    // doc → clip → scroll → pane → window. And because all four tabs stay mounted in the
    // same container (MainWindow's paneContainer, hidden ones included), a wide label
    // here jams the window's minimum width on EVERY tab.
    //
    // A label's default 750 compression resistance is enough to win that tug-of-war, so
    // every explanatory row in here has to drop to .defaultLow. Doing it in one sweep
    // rather than at each of the ~40 call sites is deliberate: this must hold for labels
    // added later too. In Chinese the descriptions are short enough that the ceiling went
    // unnoticed; the English wording is up to 780pt wide on one line, which pushed the
    // window's floor from 486pt to 622pt — far past the 384pt `minSize`, with no way to
    // drag it back. (Controls — switches, popups, recorder buttons — are untouched: they
    // keep their intrinsic width and stay fully readable.)
    private func relaxLabelWidths() { Self.relaxLabelWidths(in: self) }

    private static func relaxLabelWidths(in view: NSView) {
        for sub in view.subviews {
            if let label = sub as? NSTextField, !label.isEditable {
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            relaxLabelWidths(in: sub)
        }
    }

    deinit { if let o = spyObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: - Section nav (scroll-spy + click-to-scroll)

    // Y-offset of a section header within the (flipped) document — i.e. its
    // distance from the top of the scrollable content.
    private func headerTop(_ i: Int) -> CGFloat {
        doc.convert(sectionHeaders[i].bounds, from: sectionHeaders[i]).minY
    }

    // Pill click → smooth-scroll so the section header sits just below the nav.
    // Land on a section with no animation, for a pane that is only now appearing:
    // the column must be laid out first or every header still measures at y=0, and
    // animating a jump the user did not initiate just reads as a glitch.
    private func jumpToSection(_ i: Int) {
        guard sectionHeaders.indices.contains(i) else { return }
        layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, headerTop(i) - 12), maxY)))
        scroll.reflectScrolledClipView(clip)
        sectionBar.select(i)
    }

    private func scrollToSection(_ i: Int) {
        guard sectionHeaders.indices.contains(i) else { return }
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let y = min(max(0, headerTop(i) - 12), maxY)
        sectionBar.select(i)
        suppressSpy = true   // mute the spy so it doesn't flicker mid-animation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
            self.suppressSpy = false
        })
        scroll.reflectScrolledClipView(clip)
    }

    // Scroll driven → highlight the pill of the last section whose header has
    // reached (or passed) the top of the viewport.
    private func updateSpy() {
        guard !suppressSpy, !sectionHeaders.isEmpty else { return }
        let clip = scroll.contentView
        let offset = clip.bounds.origin.y
        var active = 0
        for i in sectionHeaders.indices where headerTop(i) - 28 <= offset { active = i }
        // At the very bottom the last (short) section may never reach the top —
        // force-select it so the final pill lights when scrolled all the way down.
        if offset + clip.bounds.height >= doc.frame.height - 4 { active = sectionHeaders.count - 1 }
        sectionBar.select(active)
    }

    // MARK: - 已隐藏 section
    //
    // One GlassCard per hidden project: a source badge, the project name + ~-path,
    // and a 恢复 button; a L("全部恢复", "Restore All") shortcut heads the list when there's more than
    // one. The count is neutral gray — red stays reserved for 需确认. The whole
    // section collapses (0 height) when nothing is hidden.
    private func rebuildHiddenSection() {
        hiddenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        restoreHandlers.removeAll()

        let cwds = AppSettings.hiddenCwds.sorted()
        guard !cwds.isEmpty else {
            hiddenContainer.isHidden = true
            hiddenHeightC.constant = 0
            return
        }
        hiddenContainer.isHidden = false

        let header = makeHiddenHeader(count: cwds.count)
        hiddenStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: hiddenStack.widthAnchor).isActive = true
        for cwd in cwds {
            let card = makeHiddenCard(cwd: cwd)
            hiddenStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: hiddenStack.widthAnchor).isActive = true
        }

        // These cards are built after buildUI's sweep, so they need their own pass —
        // a hidden project's ~-path is exactly the kind of label that would otherwise
        // set the window's floor (see relaxLabelWidths).
        Self.relaxLabelWidths(in: hiddenStack)

        hiddenStack.layoutSubtreeIfNeeded()
        // Container = stack content + a little breathing room before 全局快捷键.
        hiddenHeightC.constant = hiddenStack.fittingSize.height + 12
    }

    private func makeHiddenHeader(count: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L("已隐藏 · \(count)", "Hidden · \\(count)"))
        title.font = Theme.font(12, .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(title)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        if count > 1 {
            let all = makeTextButton(L("全部恢复", "Restore All")) { [weak self] in
                AppSettings.hiddenCwds = []
                self?.rebuildHiddenSection()
            }
            row.addSubview(all)
            NSLayoutConstraint.activate([
                all.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                all.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }
        return row
    }

    private func makeHiddenCard(cwd: String) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let isDesktop = AppController.isDesktopCwd(cwd)
        let badge = LogoBadge()
        badge.configure(isDesktop ? .desktop : .vscode)
        card.addSubview(badge)

        // A desktop sentinel IS its label ("Claude App" / "Claude Design").
        let name = NSTextField(labelWithString:
            isDesktop ? cwd : (cwd as NSString).lastPathComponent)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let path = NSTextField(labelWithString:
            isDesktop ? L("桌面版 Claude", "Claude Desktop") : (cwd as NSString).abbreviatingWithTildeInPath)
        path.font = Theme.font(11, .regular)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(path)

        let restore = makeTextButton(L("恢复", "Restore")) { [weak self] in
            AppSettings.unhide(cwd: cwd)
            self?.rebuildHiddenSection()
        }
        card.addSubview(restore)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 54),

            badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            badge.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            name.trailingAnchor.constraint(lessThanOrEqualTo: restore.leadingAnchor, constant: -10),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            path.trailingAnchor.constraint(lessThanOrEqualTo: restore.leadingAnchor, constant: -10),

            restore.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            restore.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    // A borderless blue text button wired to a closure (retained in restoreHandlers,
    // since NSControl holds its target weakly).
    private func makeTextButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Status.accent("working"),
            .font: Theme.font(12.5, .semibold),
        ])
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        let handler = SoundHandler { action() }
        restoreHandlers.append(handler)
        b.target = handler
        b.action = #selector(SoundHandler.fire(_:))
        return b
    }

    // Retains the closure targets for the switches (NSSwitch keeps only a weak target).
    private var toggleHandlers: [ToggleHandler] = []

    // Holder for a subsection heading's trailing rule. It exists only to re-resolve the
    // divider color when the theme flips: a CGColor snapshot taken at build time freezes
    // on whichever appearance was current then (the project's standing pattern — see
    // BottomTabBar.resolveColors).
    private final class SubsectionHeader: NSView {
        var rule: NSView?
        func resolveColors() { rule?.layer?.backgroundColor = Theme.divider.cg(in: self) }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            resolveColors()
        }
    }

    // A second-level heading inside a section: a small caps-ish label, a muted note
    // saying what the group acts on, then a hairline running to the right edge. Used to
    // split 显示 into 列表 (everything the preview card can demonstrate) and 应用
    // (language / appearance, which act on the whole app) — same visual language as the
    // section headers above it, one level down (design/settings-live-preview.html 方案 8).
    private func makeSubsectionHeader(_ title: String, note: String) -> NSView {
        let box = SubsectionHeader()
        box.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.font(11, .bold)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(name)

        let hint = NSTextField(labelWithString: note)
        hint.font = Theme.font(10.5, .regular)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(hint)

        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        box.rule = line
        box.resolveColors()

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 16),

            name.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 7),
            hint.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

            line.leadingAnchor.constraint(equalTo: hint.trailingAnchor, constant: 9),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return box
    }

    private func makeToggleRow(title: String, subtitle: String, isOn: Bool,
                               pro: ProFeature? = nil, dev: Bool = false,
                               onChange: @escaping (Bool) -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        let handler = ToggleHandler(onChange: onChange)
        toggleHandlers.append(handler)
        toggle.target = handler
        toggle.action = #selector(ToggleHandler.fire(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        // A marked row reads "title [PRO|DEV] … switch". The badge takes over the
        // title's trailing constraint, and the title (low compression resistance)
        // truncates into it rather than pushing the badge off the card. `pro` and
        // `dev` are never both set — a dev-only row hasn't got a tier yet.
        var titleTrail: NSLayoutXAxisAnchor = toggle.leadingAnchor
        var titleGap: CGFloat = -10
        // `Pro.showsBadge` is off while nothing is actually charged for — a PRO mark on
        // a row that works is noise. The `pro:` argument stays on every row that will
        // one day carry one, so turning them back on is a one-line change there.
        let mark: MarkBadge.Kind? = (pro != nil && Pro.showsBadge)
            ? .pro(locked: !Pro.enabled(pro!))
            : (dev ? .dev : nil)
        if let kind = mark {
            let badge = MarkBadge(kind)
            badge.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                badge.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            ])
            titleTrail = badge.leadingAnchor
            titleGap = -6
        }

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: titleTrail, constant: titleGap),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),

            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        if let feature = pro { applyProLock(card, feature) }
        return card
    }

    /// A locked paid row goes dim and inert — the exact treatment a subordinate row
    /// gets when its master switch is off (`highlightSubordinates`, 0.4 alpha +
    /// `setControlsEnabled`). Reusing it rather than inventing a second one keeps
    /// "you can't touch this" reading the same way everywhere in this panel.
    ///
    /// Disabling the control matters beyond looks: the getters already return the
    /// free-tier value, so a switch left live would flip, write to disk, and then
    /// snap back on the next read — the setter stays open on purpose (a lapsed
    /// license must not erase what the user chose), which is exactly what makes a
    /// live control misleading here.
    private func applyProLock(_ card: NSView, _ feature: ProFeature) {
        guard !Pro.enabled(feature) else { return }
        card.alphaValue = 0.4
        setControlsEnabled(card, false)
    }


    // The idle auto-jump row: one card carrying both an on/off switch and the
    // idle-threshold popup, so the feature and its "how long" knob sit together
    // (as requested). Popup writes a preset from AppSettings.idleAutoJumpChoices.
    private func makeIdleJumpRow() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L("闲置时自动跳转", "Auto-jump when idle"))
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString:
            L("无鼠标/键盘动作达到时长后，自动跳到待确认的终端",
              "After you're idle this long, jump to a terminal that needs you"))
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let toggle = NSSwitch()
        toggle.state = AppSettings.idleAutoJump ? .on : .off
        let th = ToggleHandler(onChange: { AppSettings.idleAutoJump = $0 })
        toggleHandlers.append(th)
        toggle.target = th
        toggle.action = #selector(ToggleHandler.fire(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: AppSettings.idleAutoJumpChoices.map { Self.secLabel($0) })
        popup.selectItem(withTitle: Self.secLabel(AppSettings.idleAutoJumpSeconds))
        popup.translatesAutoresizingMaskIntoConstraints = false
        let ph = SoundHandler { [weak popup] in
            guard let idx = popup?.indexOfSelectedItem, idx >= 0,
                  idx < AppSettings.idleAutoJumpChoices.count else { return }
            AppSettings.idleAutoJumpSeconds = AppSettings.idleAutoJumpChoices[idx]
        }
        soundHandlers.append(ph)
        popup.target = ph
        popup.action = #selector(SoundHandler.fire(_:))
        card.addSubview(popup)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            popup.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 88),
        ])
        return card
    }

    private static func secLabel(_ s: Int) -> String { L("\(s) 秒", "\(s)s") }

    // Same shape as the idle-jump row: a switch plus the stretch length. The clock
    // itself (BreakReminder.swift) counts you present while you type OR while a
    // session is running — that's why the subtitle says "在电脑前", not "在打字".
    private func makeBreakReminderRow() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L("番茄倒计时 · 工作 / 休息", "Break timer · work / rest"))
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString:
            L("倒计时从开始用 AI 起算，到 0 变红并弹横幅；点「现在休息」进入休息倒计时。header 的 🍅 芯片显示剩余时间",
              "Counts down from the first AI activity; at 0 it turns red and a banner fires. 现在休息 starts the rest countdown. The 🍅 chip shows time left"))
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let toggle = NSSwitch()
        toggle.state = AppSettings.breakReminderEnabled ? .on : .off
        let th = ToggleHandler(onChange: { AppSettings.breakReminderEnabled = $0 })
        toggleHandlers.append(th)
        toggle.target = th
        toggle.action = #selector(ToggleHandler.fire(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: AppSettings.breakReminderChoices.map { Self.minLabel($0) })
        popup.selectItem(withTitle: Self.minLabel(AppSettings.breakReminderMinutes))
        popup.translatesAutoresizingMaskIntoConstraints = false
        let ph = SoundHandler { [weak popup] in
            guard let idx = popup?.indexOfSelectedItem, idx >= 0,
                  idx < AppSettings.breakReminderChoices.count else { return }
            AppSettings.breakReminderMinutes = AppSettings.breakReminderChoices[idx]
        }
        soundHandlers.append(ph)
        popup.target = ph
        popup.action = #selector(SoundHandler.fire(_:))
        card.addSubview(popup)

        let rest = NSPopUpButton(frame: .zero, pullsDown: false)
        rest.addItems(withTitles: AppSettings.breakRestChoices.map { Self.restLabel($0) })
        rest.selectItem(withTitle: Self.restLabel(AppSettings.breakRestMinutes))
        rest.translatesAutoresizingMaskIntoConstraints = false
        let rh = SoundHandler { [weak rest] in
            guard let idx = rest?.indexOfSelectedItem, idx >= 0,
                  idx < AppSettings.breakRestChoices.count else { return }
            AppSettings.breakRestMinutes = AppSettings.breakRestChoices[idx]
        }
        soundHandlers.append(rh)
        rest.target = rh
        rest.action = #selector(SoundHandler.fire(_:))
        card.addSubview(rest)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            rest.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -12),
            rest.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            rest.widthAnchor.constraint(equalToConstant: 104),

            popup.trailingAnchor.constraint(equalTo: rest.leadingAnchor, constant: -6),
            popup.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 104),
        ])
        return card
    }

    private static func minLabel(_ m: Int) -> String { L("工作 \(m) 分", "Work \(m)m") }
    private static func restLabel(_ m: Int) -> String { L("休息 \(m) 分", "Rest \(m)m") }

    // Retains the closure targets for the sound popups (NSControl keeps only a weak target).
    private var soundHandlers: [SoundHandler] = []

    // L("无", "None") is the user-facing label for the off sentinel; every other item is a bare
    // system-sound name that doubles as its own title.
    private static var soundOffLabel: String { L("无", "None") }

    private func makeSoundRow(title: String, subtitle: String, current: String,
                              onChange: @escaping (String) -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: Self.soundOffLabel)
        popup.menu?.addItem(.separator())
        popup.addItems(withTitles: AppSettings.systemSounds)
        popup.selectItem(withTitle: current == AppSettings.soundOff ? Self.soundOffLabel : current)
        popup.translatesAutoresizingMaskIntoConstraints = false

        // On pick: map L("无", "None") back to the off sentinel, persist, and preview the choice.
        let handler = SoundHandler { [weak popup] in
            let picked = popup?.titleOfSelectedItem ?? Self.soundOffLabel
            let value = picked == Self.soundOffLabel ? AppSettings.soundOff : picked
            onChange(value)
            if value != AppSettings.soundOff {
                let preview = NSSound(named: NSSound.Name(value))
                preview?.volume = Float(AppSettings.soundVolume)
                preview?.play()
            }
        }
        soundHandlers.append(handler)
        popup.target = handler
        popup.action = #selector(SoundHandler.fire(_:))
        card.addSubview(popup)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            popup.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            popup.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 130),
        ])
        return card
    }

    // A card row with a slider that sets the shared playback volume for both alert
    // sounds. Live-updates the % label, persists on every tick, and previews the
    // level (done sound, or a neutral fallback) only when the drag is released.
    private func makeVolumeRow() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L("音量", "Volume"))
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: L("两个提示音的播放音量", "Playback volume for both alert sounds"))
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let pct = NSTextField(labelWithString: "\(Int((AppSettings.soundVolume * 100).rounded()))%")
        pct.font = Theme.font(11.5, .regular)
        pct.textColor = .secondaryLabelColor
        pct.alignment = .right
        pct.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pct)

        let slider = NSSlider(value: AppSettings.soundVolume, minValue: 0, maxValue: 1,
                              target: nil, action: nil)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(slider)

        let handler = SoundHandler { [weak slider, weak pct] in
            guard let slider = slider else { return }
            let v = slider.doubleValue
            AppSettings.soundVolume = v
            pct?.stringValue = "\(Int((v * 100).rounded()))%"
            // Preview only on release, so a drag doesn't machine-gun the sound.
            guard NSApp.currentEvent?.type == .leftMouseUp else { return }
            let picked = AppSettings.doneSound != AppSettings.soundOff ? AppSettings.doneSound
                : (AppSettings.needsSound != AppSettings.soundOff ? AppSettings.needsSound : "Glass")
            let preview = NSSound(named: NSSound.Name(picked))
            preview?.volume = Float(v)
            preview?.play()
        }
        soundHandlers.append(handler)
        slider.target = handler
        slider.action = #selector(SoundHandler.fire(_:))

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -12),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -12),

            pct.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            pct.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            pct.widthAnchor.constraint(equalToConstant: 40),

            slider.trailingAnchor.constraint(equalTo: pct.leadingAnchor, constant: -8),
            slider.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 110),
        ])
        return card
    }

    // The Apple Watch buzz row: a paste field for the Bark device key, a 测试 button,
    // and a result line. Taller than the other cards because this is the one setting
    // that can be "configured but silently not working" (wrong key, server down, Focus
    // eating it) — so it has to be able to say so, right here, without the user
    // reproducing a session transition to find out.
    private func makeWatchPushRow() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L("手表震动提醒", "Buzz my Apple Watch"))
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = WrappingLabel.make(
            L("会话等你确认时，让 Apple Watch 震一下 —— 人不在电脑前也知道。装免费的 Bark App，把它首页那串地址复制过来粘在下面。",
              "Buzz your Apple Watch when a session needs you, so you know even away from the desk. Install the free Bark app and paste the address from its home screen below."))
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let field = NSTextField()
        field.placeholderString = "https://api.day.app/xxxxxxxx/…"
        field.font = Theme.font(12, .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        // Show what is already stored as the full URL the user pasted, not a bare key —
        // it is the only form they recognise as "the thing from the app".
        if AppSettings.watchPushEnabled {
            field.stringValue = "\(AppSettings.watchPushServer)/\(AppSettings.watchPushKey)"
        }
        card.addSubview(field)

        let status = NSTextField(labelWithString: "")
        status.font = Theme.font(11, .regular)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(status)

        let test = NSButton(title: L("测试", "Test"), target: nil, action: nil)
        test.bezelStyle = .rounded
        test.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(test)

        // Install link. The App Store search for "Bark" surfaces an unrelated parental-
        // control app of the same name first, so never tell the user to search for it.
        let getApp = NSButton(title: L("装 Bark", "Get Bark"), target: nil, action: nil)
        getApp.bezelStyle = .inline
        getApp.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(getApp)

        let save: (String) -> Bool = { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {                       // cleared = turn the feature off
                AppSettings.watchPushKey = ""
                return true
            }
            guard let parsed = AppSettings.parseBarkPaste(trimmed) else { return false }
            AppSettings.watchPushServer = parsed.server
            AppSettings.watchPushKey = parsed.key
            return true
        }

        let fieldHandler = SoundHandler { [weak field, weak status] in
            guard let field = field else { return }
            if save(field.stringValue) {
                status?.stringValue = AppSettings.watchPushEnabled
                    ? L("已保存。点「测试」确认手机能收到。", "Saved. Hit Test to confirm your phone gets it.")
                    : L("已关闭手表提醒。", "Watch buzz is off.")
                status?.textColor = .tertiaryLabelColor
            } else {
                status?.stringValue = L("这不像 Bark 的地址 —— 直接粘 App 首页那一整串。",
                                        "That doesn't look like a Bark address — paste the whole string from its home screen.")
                status?.textColor = .systemRed
            }
        }
        soundHandlers.append(fieldHandler)
        field.target = fieldHandler
        field.action = #selector(SoundHandler.fire(_:))
        // Commit on focus loss too, not just Enter: pasting the key and then clicking
        // elsewhere is the normal way to use this field, and dropping that paste would
        // leave the user with a setting they believe they saved.
        field.cell?.sendsActionOnEndEditing = true

        let testHandler = SoundHandler { [weak field, weak status] in
            guard let field = field else { return }
            _ = save(field.stringValue)
            guard AppSettings.watchPushEnabled else {
                status?.stringValue = L("先粘上面那串地址。", "Paste the address above first.")
                status?.textColor = .systemRed
                return
            }
            status?.stringValue = L("发送中…", "Sending…")
            status?.textColor = .tertiaryLabelColor
            Self.sendWatchTest { ok, detail in
                status?.stringValue = ok
                    ? L("已发出 —— 手机应该马上响。手表没震？看下面几条。",
                        "Sent — your phone should ring. Watch didn't buzz? See the notes below.")
                    : L("发送失败：", "Send failed: ") + detail
                status?.textColor = ok ? .systemGreen : .systemRed
            }
        }
        soundHandlers.append(testHandler)
        test.target = testHandler
        test.action = #selector(SoundHandler.fire(_:))

        let getHandler = SoundHandler {
            if let url = URL(string: "https://apps.apple.com/app/id1403753865") {
                NSWorkspace.shared.open(url)
            }
        }
        soundHandlers.append(getHandler)
        getApp.target = getHandler
        getApp.action = #selector(SoundHandler.fire(_:))

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),

            getApp.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            getApp.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: getApp.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),

            field.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            field.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: test.leadingAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: 22),

            test.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            test.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            test.widthAnchor.constraint(equalToConstant: 64),

            status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            status.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    // Fire one test push, to prove the key works without waiting on a real session
    // transition.
    //
    // This shells out to /usr/bin/curl instead of using URLSession, and that is not a
    // style choice: SpectiX makes a public no-network guarantee (README "Privacy: no network"),
    // build.sh refuses to build a binary that so much as mentions a networking API, and
    // the guarantee's own stated verification is "list its linked libraries, observe its
    // sockets". The app must keep opening none. The socket here belongs to curl, the
    // same way the actual buzz belongs to the hook — SpectiX never speaks to the network
    // itself, and the whole path is dead until the user pastes a key.
    private static func sendWatchTest(_ done: @escaping (Bool, String) -> Void) {
        let server = AppSettings.watchPushServer
        let key = AppSettings.watchPushKey
        let body = L("测试成功 —— 手表提醒已经接通。", "Test OK — the watch buzz is wired up.")
        guard let json = try? JSONSerialization.data(withJSONObject: [
                  "title": "SpectiX",
                  "body": body,
                  "group": "SpectiX",
                  "level": "timeSensitive",
              ]),
              let jsonText = String(data: json, encoding: .utf8) else {
            done(false, L("地址无效", "invalid address")); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = spawnCapturing(["/usr/bin/curl", "-sS", "-m", "8", "-X", "POST",
                                      "\(server)/\(key)",
                                      "-H", "Content-Type: application/json; charset=utf-8",
                                      "-d", jsonText]) ?? ""
            // Bark answers HTTP 200 with {"code":200} on success and HTTP 200 with a
            // different code on a bad key — so "it returned 200" would call a typo'd
            // key a success. Read the body's own code instead.
            let body = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            let ok = (body?["code"] as? Int) == 200
            let detail: String
            if out.isEmpty { detail = L("连不上服务器", "couldn't reach the server") }
            else { detail = (body?["message"] as? String) ?? L("服务器没接受", "server rejected it") }
            DispatchQueue.main.async { done(ok, detail) }
        }
    }

    // Run a command and return its stdout. Blocks, so call it off the main thread.
    private static func spawnCapturing(_ argv: [String]) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            cargv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, nil, &cargv, environ)
        close(writeFD)
        guard rc == 0 else { close(readFD); return nil }
        var data = Data()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(readFD, buf, 4096)
            if n <= 0 { break }
            data.append(Data(bytes: buf, count: n))
        }
        close(readFD)
        waitpid(pid, nil, 0)
        return String(data: data, encoding: .utf8)
    }

    // A card row with a plain choice popup on the right (no off-sentinel mapping,
    // no sound preview — see makeSoundRow for that variant).
    private func makePopupRow(title: String, subtitle: String, items: [String], current: String,
                              pro: ProFeature? = nil,
                              onChange: @escaping (String) -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: items)
        popup.selectItem(withTitle: current)
        popup.translatesAutoresizingMaskIntoConstraints = false

        let handler = SoundHandler { [weak popup] in
            guard let picked = popup?.titleOfSelectedItem else { return }
            onChange(picked)
        }
        soundHandlers.append(handler)
        popup.target = handler
        popup.action = #selector(SoundHandler.fire(_:))
        card.addSubview(popup)

        // Same badge treatment as makeToggleRow: the badge takes over the title's
        // trailing constraint and the title truncates into it rather than pushing it
        // off the card.
        var titleTrail: NSLayoutXAxisAnchor = popup.leadingAnchor
        var titleGap: CGFloat = -10
        if let feature = pro, Pro.showsBadge {
            let badge = MarkBadge(.pro(locked: !Pro.enabled(feature)))
            badge.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                badge.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),
            ])
            titleTrail = badge.leadingAnchor
            titleGap = -6
        }

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: titleTrail, constant: titleGap),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),

            popup.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            popup.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 130),
        ])
        if let feature = pro { applyProLock(card, feature) }
        return card
    }

    // ── Focus ring card: style popup + a live, looping preview ──
    //
    // The preview is the real deal: a mock terminal pane with an actual RingView
    // (the same class the jump overlay uses) animating over it, replayed on a
    // timer so the user can *watch* each style before picking. 不显示 shows the
    // bare pane.
    private var previewStrip: NSView?
    private var previewPane: NSView?
    private var previewRing: RingView?
    private var previewTimer: Timer?

    // Per-status styles card state: the whole card collapses to just its header,
    // so `stylesBody` (the 5 rows + preview strip) hides and the card height swaps
    // between two precomputed constants. `editingStatus` is the status whose color
    // + style the preview currently plays (clicking a row / changing its popup
    // switches it). `highlightSubordinates` dim + disable when the master switch
    // is off.
    private var stylesCardHeightC: NSLayoutConstraint!
    private var stylesBody: [NSView] = []
    private var statusRowViews: [String: NSView] = [:]
    private var stylesExpandedH: CGFloat = 0
    private var stylesCollapsedH: CGFloat = 0
    private var stylesExpanded = true
    private var chevronLabel: NSTextField?

    // Status colors card state: theme preset cards + a "自定义" card that holds the
    // per-status chips + a swatch accordion inside it (scheme 8: 自定义即微调).
    // `themeSelection` is the highlighted theme (nil = the 自定义 card); `customExpanded`
    // shows the chips body; `colorEditingStatus` is the chip whose accordion is open.
    // Both the main card and the inner 自定义 card swap between precomputed heights.
    private var colorsCardHeightC: NSLayoutConstraint!
    private var customCardHeightC: NSLayoutConstraint!
    private var colorsCollapsedH: CGFloat = 0          // 自定义 collapsed (header only)
    private var colorsChipsH: CGFloat = 0              // 自定义 open, no chip editing
    private var colorsExpandedH: CGFloat = 0           // 自定义 open + accordion
    private var customCardCollapsedH: CGFloat = 0
    private var customCardChipsH: CGFloat = 0
    private var customCardExpandedH: CGFloat = 0
    private var themeSelection: Int?                   // nil = 自定义, 0..3 = preset index
    private var customExpanded = false
    private var colorEditingStatus: String?
    private var themeCards: [ThemeCard] = []          // presets, in colorThemes order
    // The 主题 card's palette line answers from `themeSelection`, which is only set
    // once the 状态颜色 card below is built — so it needs one refresh after that.
    private var themeChooser: ThemeChooserCard!
    private var customContainer: NSView!               // the clickable/expandable 自定义 card
    private var customCheck: NSTextField!              // "✓ 使用中" badge in its header
    private var customChevron: NSTextField!            // ▸ / ▾ expand affordance
    private var customStrip: [NSView] = []            // live 6-color strip in its header
    private var statusChips: [String: StatusChip] = [:]
    private var colorsAccordion: NSView!
    private var accordionTitle: NSTextField!
    private var accordionSwatchRow: NSView!
    private var editingStatus = "working"
    private var highlightSubordinates: [NSView] = []
    // Caption card (方案 2·A): one GlassCard folding the style segmented selector +
    // an inline reveal (duration + click switch). Picking 不显示 collapses the reveal
    // (height swaps between two precomputed constants); the style bar always shows.
    private var captionCard: NSView?                       // the whole card (a highlight subordinate)
    private var captionCardHeightC: NSLayoutConstraint!
    private var captionExpandedH: CGFloat = 0
    private var captionCollapsedH: CGFloat = 0
    private var captionRevealBody: [NSView] = []           // reveal rows hidden when 不显示
    private var captionStyleCells: [(AppSettings.CaptionStyle, SegCell)] = []
    private var captionDurationCells: [(AppSettings.CaptionDuration, SegCell)] = []

    // Chinese/English name for each session status, mirroring main.swift's label.
    private static func statusName(_ s: String) -> String {
        switch s {
        case "working": return L("运行", "Busy")
        case "done":    return L("完成", "Done")
        case "needs":   return L("确认", "Wait")
        case "idle":    return L("闲置", "Idle")
        case "paused":  return L("暂停", "Held")
        case "await":   return L("等待", "Hold")
        case "checking": return L("查看", "View")
        default:        return s
        }
    }

    // ── Per-status styles card: a collapsible header over one row per status (each a
    // StatusDot + name + style popup) and a live preview well. The preview plays
    // the real RingView for whichever status is being edited, in that status's
    // color — same class the jump/always-on overlay uses, so it's what-you-see.
    // Layout is deterministic (fixed row/preview heights) so expand/collapse just
    // swaps two precomputed card heights. 不显示 shows the bare pane.
    // Global "status colors" card. Two paths, both writing the same override store
    // (AppSettings.userColor), which recolors EVERYTHING (list/header/dots/pills/
    // menu bar/ring/caption): pick a whole theme preset, or open a per-status chip
    // and fine-tune it from preset swatches / the system color panel. A "自定义"
    // theme card lights up (showing the live 6-color strip) whenever the current
    // palette matches no preset. Lives in the Display section, not under the
    // highlight master switch — the colors apply even when highlights are off.

    // Theme presets, colors in statusColorStatuses order (needs/working/checking/
    // paused/done/idle). nil colors = the built-in default accents.
    //
    // ── 色盲友好 is DERIVED, not picked ───────────────────────────────────────
    // Its six values were searched, not chosen by eye, and re-tuning any one of
    // them by hand will quietly break the whole thing. The constraint they solve:
    // simulate all six under protanopia / deuteranopia / tritanopia (Viénot 1999)
    // and the SMALLEST pairwise CIEDE2000 distance, across all three, must stay
    // large. These clear 18.4. The palette this replaced — Okabe-Ito, which is a
    // fine palette for CHART CATEGORIES — scored 5.2, because its reddish purple
    // desaturates toward gray under deuteranopia and collided with idle's gray:
    // the two statuses a colorblind user saw as identical were 暂停 and 闲置.
    //
    // Two properties are load-bearing and easy to destroy while "improving" a hue:
    //   * The palette is split into a DARK trio (needs/working/idle, L*≈44) and a
    //     LIGHT trio (checking/paused/done, L*≈62). Lightness survives every form
    //     of color blindness, so that split is a second channel carrying the same
    //     information the hue does — it is why six statuses fit at all.
    //   * Every value clears ≥2.9:1 against BOTH a white card and a dark one. One
    //     stored hex serves both appearances (AppSettings.userColor is a single
    //     color), so a value tuned against only one background dies on the other.
    // Changing a value means re-running that simulation, not trusting how it looks
    // to full color vision — which is exactly what the 5.2 palette looked fine to.
    //
    // The 18.4 is measured on the ACCENT tone, which is what every carrier that has
    // nothing but color uses: the row dots, the header count pills, the focus ring,
    // the menu-bar capsule. `Status.fill` is deliberately not part of the target —
    // deepening a color for white text flattens the light trio back down onto the
    // dark one (needs~checking falls to ~5.8 under deuteranopia), and that tone is
    // only ever worn by StatusPill, which always spells the status out in text
    // beside it. Optimizing for the labelled carrier would cost the unlabelled ones.
    //
    // Users who had already picked the old 色盲友好 keep their stored colors and
    // simply show as 自定义 after this change; nothing is rewritten behind them.
    private static func colorThemes() -> [(name: String, colors: [String]?)] {
        // Every shipped theme's own accents are offered as a palette ANY theme can
        // wear. The theme picks the material (shadows, edges, pill shape), the palette
        // picks the colors, and the two are independent — wearing clay while keeping
        // the glass theme's brighter status hues is a legitimate combination, and
        // before this there was simply no way to ask for it.
        //
        // Read off `ThemeRegistry.all`, so a new theme shows up here for free.
        //
        // These resolve to FIXED hexes, i.e. they lose the light/dark pair the theme
        // itself carries (`themePick`) — `AppSettings.userColor` stores one hex per
        // status. That matches how the three hand-authored presets below already
        // behave, so it adds no new exception; 跟随主题 is the entry that keeps the
        // adaptive behaviour, by not overriding at all.
        let ownPalettes: [(name: String, colors: [String]?)] = ThemeRegistry.all.map { spec in
            (L("\(spec.nameZH)原色", "\(spec.nameEN) colors"),
             AppSettings.statusColorStatuses.map { spec.status.accent($0).hexString })
        }
        return [(L("跟随主题", "Follow theme"), nil)] + ownPalettes + [
            // Each row is positional against statusColorStatuses — applyTheme indexes
            // it by that array's offsets, so a short row is an out-of-range crash.
            (L("柔和", "Pastel"), ["#f48b94", "#7db8f0", "#f0c674", "#cba6f7", "#7fd1c4", "#8fd6a8", "#a6adc8"]),
            (L("霓虹", "Neon"), ["#ff2d55", "#00b0ff", "#ffd400", "#e040fb", "#00bfa5", "#00e676", "#78909c"]),
            (L("色盲友好", "Colorblind-safe"), ["#a84c31", "#016f99", "#d78500", "#b378fd", "#146b63", "#67a481", "#6a6566"]),
        ]
    }

    // Per-status preset swatches (first entry = the built-in default).
    private static let colorPresets: [String: [String]] = [
        "needs":    ["#ff5257", "#ff3b30", "#ff6b81", "#e0245e", "#ff7a45", "#c62828"],
        "working":  ["#459eff", "#0a84ff", "#5e8bff", "#38c5e8", "#6fb2ff", "#3a6fe0"],
        "checking": ["#ffb021", "#ff9f0a", "#ffd60a", "#ffbd59", "#e8960f", "#f5a623"],
        "paused":   ["#d67ae8", "#bf5af2", "#e08fff", "#a855f7", "#f472b6", "#9d4edd"],
        "await":    ["#00bfa5", "#1de9b6", "#26a69a", "#00acc1", "#2bd4c0", "#14b8a6"],
        "done":     ["#42d17d", "#30d158", "#63e6a4", "#2dd4bf", "#8bd450", "#19a15f"],
        "idle":     ["#9ea8b8", "#8e8e93", "#b8c0cc", "#7d8590", "#a8b3a2", "#6e7681"],
    ]

    private func makeStatusColorsCard() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let statuses = AppSettings.statusColorStatuses

        // Deterministic geometry. The main card holds the title + a 2-column theme
        // grid + a full-width 自定义 card; that inner card holds the per-status chips
        // and the swatch accordion, and grows/shrinks on its own. Both heights are
        // precomputed so a click just swaps constants.
        //
        // The grid's row count is DERIVED from the preset list, which now grows with
        // `ThemeRegistry.all` — hard-coding it (it was 2) would silently clip the last
        // row the day a theme is added.
        let headerH: CGFloat = 46                          // title + subtitle band
        let themeRowH: CGFloat = 54
        let chipH: CGFloat = 30
        let gap: CGFloat = 8
        let customHeaderH: CGFloat = 46                     // clickable header inside 自定义
        let accordionH: CGFloat = 68
        let themeRows = CGFloat((Self.colorThemes().count + 1) / 2)
        let themesTop = headerH
        let customTop = themesTop + themeRows * (themeRowH + gap)   // 自定义 card sits below the grid

        // 自定义 card heights: header only → + chips → + chips + accordion.
        let chipsTopInCard = customHeaderH + 4
        // Row count derived from the status list for the same reason the theme grid's
        // is: hard-coding it (it was 2) clips the last row the day a status is added.
        let chipRows = CGFloat((statuses.count + 2) / 3)
        let chipsBottomInCard = chipsTopInCard + chipH * chipRows + gap * (chipRows - 1)
        customCardCollapsedH = customHeaderH
        customCardChipsH = chipsBottomInCard + 10
        customCardExpandedH = chipsBottomInCard + 8 + accordionH + 12
        func mainH(_ inner: CGFloat) -> CGFloat { customTop + inner + 12 }
        colorsCollapsedH = mainH(customCardCollapsedH)
        colorsChipsH = mainH(customCardChipsH)
        colorsExpandedH = mainH(customCardExpandedH)

        let title = NSTextField(labelWithString: L("状态颜色", "Status colors"))
        title.font = Theme.rounded(14, .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let sub = NSTextField(labelWithString: L(
            "选一套配色，或点「自定义」逐状态调色；与主题相互独立，任意组合都行",
            "Pick a palette, or open Custom to tune each status; independent of the theme"))
        sub.font = Theme.font(11.5, .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])

        // ── palette preset cards: two columns, as many rows as presets ──
        themeCards = []
        for (i, theme) in Self.colorThemes().enumerated() {
            let tc = ThemeCard(title: theme.name)
            tc.onClick = { [weak self] in self?.applyTheme(i) }
            card.addSubview(tc)
            let row = CGFloat(i / 2), col = i % 2
            NSLayoutConstraint.activate([
                col == 0
                    ? tc.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset)
                    : tc.leadingAnchor.constraint(equalTo: card.centerXAnchor, constant: gap / 2),
                col == 0
                    ? tc.trailingAnchor.constraint(equalTo: card.centerXAnchor, constant: -gap / 2)
                    : tc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
                tc.topAnchor.constraint(equalTo: card.topAnchor, constant: themesTop + row * (themeRowH + gap)),
                tc.heightAnchor.constraint(equalToConstant: themeRowH),
            ])
            themeCards.append(tc)
        }

        // ── 自定义 card: clickable/selectable like a preset, expands to reveal the
        //    per-status chips + accordion inside it (scheme 8) ──
        let cc = NSView()
        cc.wantsLayer = true
        cc.layer?.cornerRadius = 10
        cc.layer?.cornerCurve = .continuous
        cc.layer?.masksToBounds = true
        cc.layer?.borderWidth = 1
        cc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cc)
        customContainer = cc
        customCardHeightC = cc.heightAnchor.constraint(equalToConstant: customCardCollapsedH)
        NSLayoutConstraint.activate([
            cc.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            cc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            cc.topAnchor.constraint(equalTo: card.topAnchor, constant: customTop),
            customCardHeightC,
        ])

        let cname = NSTextField(labelWithString: L("自定义", "Custom"))
        cname.font = Theme.rounded(12, .semibold)
        cname.textColor = .labelColor
        cname.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(cname)

        customCheck = NSTextField(labelWithString: "✓ " + L("使用中", "In use"))
        customCheck.font = Theme.font(10, .medium)
        customCheck.textColor = .controlAccentColor
        customCheck.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(customCheck)

        customStrip = []
        var lastDot: NSView = customCheck
        for i in 0..<statuses.count {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 7
            dot.translatesAutoresizingMaskIntoConstraints = false
            cc.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: lastDot.trailingAnchor, constant: i == 0 ? 8 : 5),
                dot.centerYAnchor.constraint(equalTo: cname.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14),
            ])
            customStrip.append(dot)
            lastDot = dot
        }

        customChevron = NSTextField(labelWithString: "▸")
        customChevron.font = Theme.font(10, .regular)
        customChevron.textColor = .tertiaryLabelColor
        customChevron.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(customChevron)

        NSLayoutConstraint.activate([
            cname.leadingAnchor.constraint(equalTo: cc.leadingAnchor, constant: 12),
            cname.centerYAnchor.constraint(equalTo: cc.topAnchor, constant: customHeaderH / 2),
            customCheck.leadingAnchor.constraint(equalTo: cname.trailingAnchor, constant: 8),
            customCheck.centerYAnchor.constraint(equalTo: cname.centerYAnchor),
            customChevron.trailingAnchor.constraint(equalTo: cc.trailingAnchor, constant: -12),
            customChevron.centerYAnchor.constraint(equalTo: cname.centerYAnchor),
        ])

        // Transparent hit area over the header only — so clicking a chip in the body
        // never toggles the whole card.
        let headerHit = NSView()
        headerHit.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(headerHit)
        NSLayoutConstraint.activate([
            headerHit.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            headerHit.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            headerHit.topAnchor.constraint(equalTo: cc.topAnchor),
            headerHit.heightAnchor.constraint(equalToConstant: customHeaderH),
        ])
        headerHit.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(customHeaderClicked)))

        // ── per-status chips: 3-wide grid inside the 自定义 card ──
        statusChips = [:]
        var rowChips: [StatusChip] = []
        for (i, s) in statuses.enumerated() {
            let chip = StatusChip(name: Self.statusName(s))
            chip.onClick = { [weak self] in self?.toggleColorChip(s) }
            cc.addSubview(chip)
            statusChips[s] = chip
            let row = CGFloat(i / 3), col = i % 3
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: cc.topAnchor, constant: chipsTopInCard + row * (chipH + gap)),
                chip.heightAnchor.constraint(equalToConstant: chipH),
            ])
            if col == 0 {
                chip.leadingAnchor.constraint(equalTo: cc.leadingAnchor, constant: 11).isActive = true
                rowChips = [chip]
            } else {
                chip.leadingAnchor.constraint(equalTo: rowChips[col - 1].trailingAnchor, constant: gap).isActive = true
                chip.widthAnchor.constraint(equalTo: rowChips[0].widthAnchor).isActive = true
                rowChips.append(chip)
                if col == 2 {
                    chip.trailingAnchor.constraint(equalTo: cc.trailingAnchor, constant: -11).isActive = true
                }
            }
        }
        // A partial last row has no col-2 chip to pin the trailing edge, which leaves
        // its width ambiguous; borrow it from the first row instead.
        let rem = statuses.count % 3
        if rem != 0, let ref = statusChips[statuses[0]],
           let lead = statusChips[statuses[statuses.count - rem]] {
            lead.widthAnchor.constraint(equalTo: ref.widthAnchor).isActive = true
        }

        // ── swatch accordion (hidden until a chip opens it) ──
        let acc = NSView()
        acc.wantsLayer = true
        acc.layer?.cornerRadius = 10
        acc.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        acc.layer?.borderWidth = 1
        acc.layer?.borderColor = Theme.hairline.cgColor
        acc.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(acc)
        colorsAccordion = acc

        accordionTitle = NSTextField(labelWithString: "")
        accordionTitle.font = Theme.font(11, .regular)
        accordionTitle.textColor = .secondaryLabelColor
        accordionTitle.translatesAutoresizingMaskIntoConstraints = false
        acc.addSubview(accordionTitle)

        accordionSwatchRow = NSView()
        accordionSwatchRow.translatesAutoresizingMaskIntoConstraints = false
        acc.addSubview(accordionSwatchRow)

        NSLayoutConstraint.activate([
            acc.leadingAnchor.constraint(equalTo: cc.leadingAnchor, constant: 11),
            acc.trailingAnchor.constraint(equalTo: cc.trailingAnchor, constant: -11),
            acc.topAnchor.constraint(equalTo: cc.topAnchor, constant: chipsBottomInCard + 8),
            acc.heightAnchor.constraint(equalToConstant: accordionH),

            accordionTitle.leadingAnchor.constraint(equalTo: acc.leadingAnchor, constant: 12),
            accordionTitle.topAnchor.constraint(equalTo: acc.topAnchor, constant: 8),
            accordionSwatchRow.leadingAnchor.constraint(equalTo: acc.leadingAnchor, constant: 12),
            accordionSwatchRow.trailingAnchor.constraint(equalTo: acc.trailingAnchor, constant: -12),
            accordionSwatchRow.topAnchor.constraint(equalTo: accordionTitle.bottomAnchor, constant: 4),
            accordionSwatchRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        colorsCardHeightC = card.heightAnchor.constraint(equalToConstant: colorsCollapsedH)
        colorsCardHeightC.isActive = true

        // Initial theme selection = whichever preset the stored palette matches, else 自定义.
        let curHex = statuses.map { Status.accent($0).hexString.lowercased() }
        themeSelection = nil
        for (i, theme) in Self.colorThemes().enumerated() {
            let hexes = (theme.colors ?? statuses.map { Status.defaultAccent($0).hexString })
                .map { $0.lowercased() }
            if hexes == curHex { themeSelection = i; break }
        }

        repaintColorsCard()
        return card
    }

    // Apply one whole theme preset (nil colors = clear every override) and collapse
    // the 自定义 card — picking a preset is a full switch, not a tweak.
    private func applyTheme(_ index: Int) {
        let statuses = AppSettings.statusColorStatuses
        let theme = Self.colorThemes()[index]
        var batch: [String: NSColor?] = [:]
        for (i, s) in statuses.enumerated() {
            // updateValue, not subscript: the value must be stored even when it's
            // nil (= clear the override), never dropped from the dictionary.
            batch.updateValue(theme.colors.map { NSColor(hexString: $0[i])! }, forKey: s)
        }
        AppSettings.setUserColors(batch)
        themeSelection = index
        customExpanded = false
        colorEditingStatus = nil
        NSColorPanel.shared.close()
        repaintColorsCard()
        layoutSubtreeIfNeeded()
    }

    // The 自定义 card header: toggle its body; opening it also selects 自定义.
    @objc private func customHeaderClicked() {
        customExpanded.toggle()
        if customExpanded {
            themeSelection = nil
        } else {
            colorEditingStatus = nil
            NSColorPanel.shared.close()
        }
        repaintColorsCard()
        layoutSubtreeIfNeeded()
    }

    private func toggleColorChip(_ status: String) {
        colorEditingStatus = (colorEditingStatus == status) ? nil : status
        if colorEditingStatus == nil { NSColorPanel.shared.close() }
        else { customExpanded = true }
        repaintColorsCard()
        layoutSubtreeIfNeeded()
    }

    // Repaint every dynamic piece of the colors card from the current palette:
    // chip tints, theme selection highlight, the 自定义 card's live strip + check,
    // its expand state, and the accordion for the open chip.
    private func repaintColorsCard() {
        let statuses = AppSettings.statusColorStatuses
        let current = statuses.map { Status.accent($0) }
        let defaults = statuses.map { Status.defaultAccent($0) }

        for (i, s) in statuses.enumerated() {
            statusChips[s]?.paint(color: current[i], selected: s == colorEditingStatus)
        }

        let sel = themeSelection            // nil = 自定义 selected
        for (i, tc) in themeCards.enumerated() {
            let colors = Self.colorThemes()[i].colors?.compactMap { NSColor(hexString: $0) } ?? defaults
            tc.set(colors: colors, selected: sel == i)
        }
        paintCustomHeader(selected: sel == nil, colors: current)

        // The body shows whenever the card is expanded or a chip is being edited.
        let expanded = customExpanded || colorEditingStatus != nil
        let showAccordion = colorEditingStatus != nil
        for chip in statusChips.values { chip.isHidden = !expanded }
        colorsAccordion.isHidden = !showAccordion
        customChevron.stringValue = expanded ? "▾" : "▸"

        customCardHeightC.constant = !expanded ? customCardCollapsedH
            : (showAccordion ? customCardExpandedH : customCardChipsH)
        colorsCardHeightC.constant = !expanded ? colorsCollapsedH
            : (showAccordion ? colorsExpandedH : colorsChipsH)
        if let s = colorEditingStatus { rebuildAccordion(for: s) }
        // The 主题 card names the palette in use; every path that changes it lands
        // here, so one refresh at the end covers preset picks, 自定义, and the build.
        themeChooser?.refreshPaletteLine()
    }

    // Paint the 自定义 card's selection styling (mirrors ThemeCard.set) + live strip.
    private func paintCustomHeader(selected: Bool, colors: [NSColor]) {
        customContainer.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : Theme.cardFill.cgColor
        customContainer.layer?.borderWidth = selected ? 1.5 : 1
        customContainer.layer?.borderColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            : Theme.hairline.cgColor
        customCheck.isHidden = !selected
        for (i, dot) in customStrip.enumerated() where i < colors.count {
            dot.layer?.backgroundColor = colors[i].cgColor
        }
    }

    private func rebuildAccordion(for status: String) {
        accordionTitle.stringValue = Self.statusName(status) + " · " + L("预设", "Presets")
        accordionSwatchRow.subviews.forEach { $0.removeFromSuperview() }

        let currentHex = Status.accent(status).hexString.lowercased()
        var lastAnchor = accordionSwatchRow.leadingAnchor
        var lastGap: CGFloat = 0
        for hex in Self.colorPresets[status] ?? [] {
            guard let c = NSColor(hexString: hex) else { continue }
            let sw = ColorSwatch(color: c, selected: hex.lowercased() == currentHex)
            sw.onClick = { [weak self] in
                AppSettings.setUserColor(c, for: status)
                self?.themeSelection = nil          // any single tweak → 自定义
                self?.repaintColorsCard()
            }
            accordionSwatchRow.addSubview(sw)
            NSLayoutConstraint.activate([
                sw.leadingAnchor.constraint(equalTo: lastAnchor, constant: lastGap),
                sw.centerYAnchor.constraint(equalTo: accordionSwatchRow.centerYAnchor),
            ])
            lastAnchor = sw.trailingAnchor
            lastGap = 8
        }

        // Rainbow ring → the system color panel, live-updating this status.
        let rainbow = ColorSwatch(rainbow: true)
        rainbow.toolTip = L("自定义…", "Custom…")
        rainbow.onClick = { [weak self] in self?.openColorPanel(for: status) }
        accordionSwatchRow.addSubview(rainbow)
        NSLayoutConstraint.activate([
            rainbow.leadingAnchor.constraint(equalTo: lastAnchor, constant: lastGap),
            rainbow.centerYAnchor.constraint(equalTo: accordionSwatchRow.centerYAnchor),
        ])

        let reset = NSButton(title: "⟲ " + L("默认", "Default"), target: self,
                             action: #selector(resetColorForEditingStatus))
        reset.isBordered = false
        reset.font = Theme.font(11, .regular)
        reset.contentTintColor = .secondaryLabelColor
        reset.translatesAutoresizingMaskIntoConstraints = false
        accordionSwatchRow.addSubview(reset)
        NSLayoutConstraint.activate([
            reset.trailingAnchor.constraint(equalTo: accordionSwatchRow.trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: accordionSwatchRow.centerYAnchor),
        ])
    }

    private func openColorPanel(for status: String) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = Status.accent(status)
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let s = colorEditingStatus else { return }
        AppSettings.setUserColor(sender.color, for: s)
        themeSelection = nil                    // any single tweak → 自定义
        repaintColorsCard()
    }

    @objc private func resetColorForEditingStatus() {
        guard let s = colorEditingStatus else { return }
        AppSettings.setUserColor(nil, for: s)
        // Back to the default preset only if every status is now default.
        let statuses = AppSettings.statusColorStatuses
        let allDefault = statuses.allSatisfy {
            Status.accent($0).hexString.lowercased() == Status.defaultAccent($0).hexString.lowercased()
        }
        themeSelection = allDefault ? 0 : nil
        repaintColorsCard()
    }

    // MARK: - 标签 card
    //
    // One card folding all three caption knobs (design/caption-card-redesign.html
    // 方案 2·A). The style bar always shows — it *is* the on/off switch, since
    // .hidden means "no caption" — and picking a visible style reveals the duration
    // segments + the click switch inline. Geometry is deterministic, so revealing
    // just swaps two precomputed card heights.
    private func makeCaptionCard() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let headerH: CGFloat = 46
        let styleBarH: CGFloat = 62
        let durLabelH: CGFloat = 32
        let segH: CGFloat = 30
        let clickRowH: CGFloat = 40
        let styleTop = headerH
        let durLabelTop = styleTop + styleBarH + 10
        let segTop = durLabelTop + durLabelH
        let clickTop = segTop + segH + 6
        captionCollapsedH = styleTop + styleBarH + 12
        captionExpandedH = clickTop + clickRowH + 10

        // ── header ──
        let title = NSTextField(labelWithString: L("标签", "Caption"))
        title.font = Theme.rounded(14, .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let sub = NSTextField(labelWithString: L(
            "跳转 / 点击终端时在落点弹出的会话标签",
            "The session label that pops at the jump target"))
        sub.font = Theme.font(11.5, .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])

        // ── style bar: 不显示 first — it carries the off switch ──
        let styleBar = makeSegBar()
        card.addSubview(styleBar)
        NSLayoutConstraint.activate([
            styleBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            styleBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            styleBar.topAnchor.constraint(equalTo: card.topAnchor, constant: styleTop),
            styleBar.heightAnchor.constraint(equalToConstant: styleBarH),
        ])

        captionStyleCells = []
        var lastStyleCell: SegCell?
        for style in AppSettings.CaptionStyle.allCases {
            let cell = SegCell(title: style.title, thumb: CaptionMini(style), filled: false)
            cell.onClick = { [weak self] in self?.pickCaptionStyle(style) }
            layoutSegCell(cell, in: styleBar, after: lastStyleCell)
            captionStyleCells.append((style, cell))
            lastStyleCell = cell
        }
        lastStyleCell?.trailingAnchor.constraint(
            equalTo: styleBar.trailingAnchor, constant: -3).isActive = true

        // ── reveal: duration + click switch ──
        captionRevealBody = []

        let durName = NSTextField(labelWithString: L("停留时间", "Caption duration"))
        durName.font = Theme.rounded(13, .medium)
        durName.textColor = .labelColor
        durName.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(durName)

        let durSub = NSTextField(labelWithString: L(
            "标签多久后自动消失（与高亮圈独立）",
            "How long the caption stays (independent of the ring)"))
        durSub.font = Theme.font(11, .regular)
        durSub.textColor = .tertiaryLabelColor
        durSub.lineBreakMode = .byTruncatingTail
        durSub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(durSub)

        let durBar = makeSegBar()
        card.addSubview(durBar)
        captionRevealBody += [durName, durSub, durBar]

        NSLayoutConstraint.activate([
            durName.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            durName.topAnchor.constraint(equalTo: card.topAnchor, constant: durLabelTop),
            durSub.leadingAnchor.constraint(equalTo: durName.leadingAnchor),
            durSub.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            durSub.topAnchor.constraint(equalTo: durName.bottomAnchor, constant: 1),

            durBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            durBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            durBar.topAnchor.constraint(equalTo: card.topAnchor, constant: segTop),
            durBar.heightAnchor.constraint(equalToConstant: segH),
        ])

        captionDurationCells = []
        var lastDurCell: SegCell?
        for d in AppSettings.CaptionDuration.allCases {
            let cell = SegCell(title: d.title, thumb: nil, filled: true)
            cell.onClick = { [weak self] in self?.pickCaptionDuration(d) }
            layoutSegCell(cell, in: durBar, after: lastDurCell)
            captionDurationCells.append((d, cell))
            lastDurCell = cell
        }
        lastDurCell?.trailingAnchor.constraint(
            equalTo: durBar.trailingAnchor, constant: -3).isActive = true

        let clickName = NSTextField(labelWithString: L("点击终端时也显示", "Also show on terminal click"))
        clickName.font = Theme.rounded(13, .medium)
        clickName.textColor = .labelColor
        clickName.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clickName)

        let clickSub = NSTextField(labelWithString: L(
            "手动点进某个 terminal 时弹出标签（与高亮圈独立）",
            "Pop the caption when you click into a terminal (independent of the ring)"))
        clickSub.font = Theme.font(11, .regular)
        clickSub.textColor = .tertiaryLabelColor
        clickSub.lineBreakMode = .byTruncatingTail
        clickSub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clickSub)

        let clickToggle = NSSwitch()
        clickToggle.state = AppSettings.captionOnFocusClick ? .on : .off
        let handler = ToggleHandler(onChange: { AppSettings.captionOnFocusClick = $0 })
        toggleHandlers.append(handler)
        clickToggle.target = handler
        clickToggle.action = #selector(ToggleHandler.fire(_:))
        clickToggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clickToggle)
        captionRevealBody += [clickName, clickSub, clickToggle]

        NSLayoutConstraint.activate([
            clickName.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            clickName.topAnchor.constraint(equalTo: card.topAnchor, constant: clickTop),
            clickName.trailingAnchor.constraint(lessThanOrEqualTo: clickToggle.leadingAnchor, constant: -10),
            clickSub.leadingAnchor.constraint(equalTo: clickName.leadingAnchor),
            clickSub.topAnchor.constraint(equalTo: clickName.bottomAnchor, constant: 1),
            clickSub.trailingAnchor.constraint(lessThanOrEqualTo: clickToggle.leadingAnchor, constant: -10),

            clickToggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            clickToggle.centerYAnchor.constraint(equalTo: card.topAnchor,
                                                 constant: clickTop + clickRowH / 2 - 4),
        ])

        captionCardHeightC = card.heightAnchor.constraint(equalToConstant: captionCollapsedH)
        captionCardHeightC.isActive = true

        repaintCaptionCard()
        return card
    }

    // The recessed track a row of SegCells sits in.
    private func makeSegBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        bar.layer?.cornerRadius = 9
        bar.layer?.cornerCurve = .continuous
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = Theme.hairline.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    // Equal-width cells chained left to right; the caller pins the last one's trailing.
    private func layoutSegCell(_ cell: SegCell, in bar: NSView, after prev: SegCell?) {
        bar.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: bar.topAnchor, constant: 3),
            cell.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -3),
            cell.leadingAnchor.constraint(equalTo: prev?.trailingAnchor ?? bar.leadingAnchor,
                                          constant: 3),
        ])
        if let p = prev { cell.widthAnchor.constraint(equalTo: p.widthAnchor).isActive = true }
    }

    private func pickCaptionStyle(_ style: AppSettings.CaptionStyle) {
        AppSettings.captionStyle = style
        repaintCaptionCard()
        layoutSubtreeIfNeeded()
        replayRingPreview()
    }

    private func pickCaptionDuration(_ d: AppSettings.CaptionDuration) {
        AppSettings.captionDuration = d
        repaintCaptionCard()
    }

    // Selection paint + the reveal: duration and the click switch only exist for a
    // visible style, so 不显示 collapses them away rather than dimming them.
    private func repaintCaptionCard() {
        let style = AppSettings.captionStyle
        for (s, cell) in captionStyleCells { cell.paint(selected: s == style) }
        let duration = AppSettings.captionDuration
        for (d, cell) in captionDurationCells { cell.paint(selected: d == duration) }

        let visible = style != .hidden
        captionRevealBody.forEach { $0.isHidden = !visible }
        captionCardHeightC?.constant = visible ? captionExpandedH : captionCollapsedH
    }

    private func makeRingStylesCard() -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Deterministic geometry.
        let headerH: CGFloat = 46
        let rowH: CGFloat = 34
        let previewH: CGFloat = 172   // taller so the caption floating above the pane has room
        let rowsTop = headerH + 2
        let previewTop = rowsTop + rowH * CGFloat(AppSettings.ringStyleStatuses.count) + 10
        stylesExpandedH = previewTop + previewH + 12
        stylesCollapsedH = headerH + 6

        // ── header (whole band toggles expand/collapse) ──
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        let title = NSTextField(labelWithString: L("各状态样式", "Per-status styles"))
        title.font = Theme.rounded(14, .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let sub = NSTextField(labelWithString: L("每个状态各选一种高亮样式；点状态看预览", "Pick a style per status; click one to preview"))
        sub.font = Theme.font(11.5, .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(sub)

        let chevron = NSTextField(labelWithString: stylesExpanded ? "▾" : "▸")
        chevron.font = Theme.font(12, .regular)
        chevron.textColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(chevron)
        chevronLabel = chevron

        header.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(toggleStylesExpand)))

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerH),

            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 9),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            chevron.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])

        // ── 5 per-status rows ──
        stylesBody = []
        statusRowViews = [:]
        for (i, s) in AppSettings.ringStyleStatuses.enumerated() {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 7
            row.layer?.cornerCurve = .continuous
            row.identifier = NSUserInterfaceItemIdentifier(s)
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            stylesBody.append(row)
            statusRowViews[s] = row

            let dot = StatusDot(diameter: 10, compact: true)
            dot.apply(s)
            dot.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(dot)

            let nameLabel = NSTextField(labelWithString: Self.statusName(s))
            nameLabel.font = Theme.rounded(13, .medium)
            nameLabel.textColor = .labelColor
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(nameLabel)

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: AppSettings.RingStyle.allCases.map(\.title))
            popup.selectItem(withTitle: AppSettings.ringStyle(for: s).title)
            popup.translatesAutoresizingMaskIntoConstraints = false
            let handler = SoundHandler { [weak self, weak popup] in
                guard let picked = popup?.titleOfSelectedItem,
                      let choice = AppSettings.RingStyle.allCases.first(where: { $0.title == picked })
                else { return }
                AppSettings.setRingStyle(choice, for: s)
                self?.editingStatus = s
                self?.replayRingPreview()
            }
            soundHandlers.append(handler)
            popup.target = handler
            popup.action = #selector(SoundHandler.fire(_:))
            row.addSubview(popup)

            // Clicking the label/dot area (not the popup) selects the row for the
            // preview — gesture on the label only so it never eats popup clicks.
            nameLabel.identifier = NSUserInterfaceItemIdentifier(s)
            nameLabel.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(pickStatusRow(_:))))

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                row.topAnchor.constraint(equalTo: card.topAnchor, constant: rowsTop + CGFloat(i) * rowH),
                row.heightAnchor.constraint(equalToConstant: rowH),

                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Theme.inset - 8),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 10),
                dot.heightAnchor.constraint(equalToConstant: 10),

                nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
                nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

                popup.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -(Theme.inset - 8)),
                popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                popup.widthAnchor.constraint(equalToConstant: 130),
            ])
        }

        // ── preview well (a recessed strip with room around the pane) ──
        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        strip.layer?.cornerRadius = 8
        strip.layer?.cornerCurve = .continuous
        strip.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(strip)
        stylesBody.append(strip)
        previewStrip = strip

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        pane.layer?.cornerRadius = 6
        pane.layer?.cornerCurve = .continuous
        pane.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(pane)
        previewPane = pane

        let prompt = NSTextField(labelWithString: "❯")
        prompt.font = Theme.font(11, .bold)
        prompt.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(prompt)

        var lastBar: NSView = prompt
        for barWidth in [0.52, 0.34] as [CGFloat] {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            bar.layer?.cornerRadius = 2.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: prompt.leadingAnchor,
                                             constant: lastBar === prompt ? 16 : 0),
                bar.topAnchor.constraint(equalTo: lastBar === prompt
                    ? pane.topAnchor : lastBar.bottomAnchor,
                    constant: lastBar === prompt ? 9 : 6),
                bar.widthAnchor.constraint(equalTo: pane.widthAnchor, multiplier: barWidth),
                bar.heightAnchor.constraint(equalToConstant: 5),
            ])
            lastBar = bar
        }

        stylesCardHeightC = card.heightAnchor.constraint(
            equalToConstant: stylesExpanded ? stylesExpandedH : stylesCollapsedH)
        stylesCardHeightC.isActive = true

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            strip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            strip.topAnchor.constraint(equalTo: card.topAnchor, constant: previewTop),
            strip.heightAnchor.constraint(equalToConstant: previewH),

            // Empty margin around the pane = travel room for glow / ripples.
            pane.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 30),
            pane.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -30),
            pane.topAnchor.constraint(equalTo: strip.topAnchor, constant: 48),   // extra room for the floating caption
            pane.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -26),

            prompt.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            prompt.topAnchor.constraint(equalTo: pane.topAnchor, constant: 4),
        ])

        // Body visibility follows the initial expand state.
        stylesBody.forEach { $0.isHidden = !stylesExpanded }
        return card
    }

    @objc private func toggleStylesExpand() {
        stylesExpanded.toggle()
        chevronLabel?.stringValue = stylesExpanded ? "▾" : "▸"
        stylesBody.forEach { $0.isHidden = !stylesExpanded }
        stylesCardHeightC.constant = stylesExpanded ? stylesExpandedH : stylesCollapsedH
        layoutSubtreeIfNeeded()
        if stylesExpanded { replayRingPreview() } else { stopRingPreview() }
    }

    @objc private func pickStatusRow(_ g: NSClickGestureRecognizer) {
        guard let s = g.view?.identifier?.rawValue else { return }
        editingStatus = s
        replayRingPreview()
    }

    // Tint the row of the status currently being previewed; clear the rest.
    private func highlightActiveStatusRow() {
        for (s, row) in statusRowViews {
            row.layer?.backgroundColor = (s == editingStatus)
                ? Status.accent(s).withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        }
    }

    // (Re)start the looping preview for the status being edited, in its color and
    // style. Each pass drops a fresh RingView over the mock pane and schedules the
    // next replay just after the animation finishes. Runs only while the card is
    // expanded (collapsed = nothing to watch).
    private func replayRingPreview() {
        previewTimer?.invalidate(); previewTimer = nil
        previewRing?.removeFromSuperview(); previewRing = nil
        highlightActiveStatusRow()
        guard stylesExpanded, AppSettings.highlightsEnabled else { return }
        let style = AppSettings.ringStyle(for: editingStatus)
        if style != .off, let strip = previewStrip, let pane = previewPane {
            strip.layoutSubtreeIfNeeded()
            // Same geometry as the real overlay: pane + 5pt pad, 24pt animation margin.
            // The titlebar caption draws inside the ring, so nothing is added on top.
            let target = pane.frame.insetBy(dx: -5, dy: -5)
            let previewTask = L("跳转标签预览", "caption preview")
            let pframe = target.insetBy(dx: -24, dy: -24)
            let ring = RingView(frame: pframe, margin: 24,
                                accent: Status.accent(editingStatus), style: style,
                                project: "SpectiX", task: previewTask, icon: .vscode)
            strip.addSubview(ring)
            previewRing = ring
            previewTimer = Timer.scheduledTimer(withTimeInterval: ring.lifetime + 0.5,
                                                repeats: false) { [weak self] _ in
                self?.replayRingPreview()
            }
        }
        // AFTER the ring: the ring's titlebar caption spans the pane's whole top edge,
        // and a dot added first sits underneath it — measured as "预览里没有点".
        syncPreviewPipDot()
    }

    // Master switch reflection: dim + disable the subordinate rows when highlights
    // are off, and pause/resume the live preview.
    private func applyHighlightMaster(_ on: Bool) {
        for v in highlightSubordinates {
            v.alphaValue = on ? 1 : 0.4
            setControlsEnabled(v, on)
        }
        if !on { stopRingPreview() }
        else if stylesExpanded { replayRingPreview() }
    }

    private func setControlsEnabled(_ view: NSView, _ enabled: Bool) {
        if let c = view as? NSControl { c.isEnabled = enabled }
        if let cell = view as? SegCell { cell.isEnabled = enabled }   // gesture-driven, not an NSControl
        view.subviews.forEach { setControlsEnabled($0, enabled) }
    }

    private func stopRingPreview() {
        previewTimer?.invalidate(); previewTimer = nil
        previewRing?.removeFromSuperview(); previewRing = nil
        previewPipDot?.removeFromSuperview(); previewPipDot = nil
    }

    // The corner status dot, demoed in the SAME mock terminal the ring styles play on —
    // one preview shows everything the selected status will look like. Rebuilt fresh on
    // every replay, like previewRing, and added to the STRIP after the ring so it draws
    // above the ring's titlebar caption (which spans the pane's whole top edge and
    // otherwise covers it). Rides the pane's top-left corner with the live feature's
    // insets (wide decor statuses sit a little further in so the glyphs' left edges
    // align — StatusPip.insetX mirrors this). Visible only while the 终端状态点 toggle
    // is on, so flipping that toggle is immediately observable here; keyless apply,
    // like the real pips.
    private var previewPipDot: StatusDot?

    private func syncPreviewPipDot() {
        previewPipDot?.removeFromSuperview(); previewPipDot = nil
        guard AppSettings.cornerPips, let strip = previewStrip, let pane = previewPane else { return }
        let dot = StatusDot(diameter: 11)
        dot.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(dot)   // last subview = topmost, above the ring
        let wide = editingStatus == "working" || editingStatus == "checking"
        let centerX: CGFloat = wide ? 7 : 2
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 11),
            dot.heightAnchor.constraint(equalToConstant: 11),
            dot.topAnchor.constraint(equalTo: pane.topAnchor, constant: 2.5),
            dot.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: centerX - 5.5),
        ])
        dot.apply(editingStatus)
        previewPipDot = dot
    }

    // ── Permission rows: a checkbox that IS the status + the action ──
    //
    // Green box + white ✓ when granted, empty outline when not; clicking it fires
    // the grant request (system prompt + deep link to the settings pane — or just
    // the pane when already granted, handy for reviewing the switch). A 1.5s timer
    // (running only while the window is up) re-checks, so flipping the switch in
    // System Settings reflects here without reopening. Accessibility takes effect on
    // the running process the moment it's granted — no relaunch needed.
    private struct PermissionRowRefs {
        let box: SquareToggle
        let isGranted: () -> Bool
    }
    private var permRows: [PermissionRowRefs] = []
    private var permTimer: Timer?

    private func makePermissionRow(title: String, subtitle: String,
                                   isGranted: @escaping () -> Bool,
                                   request: @escaping () -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        // Wrapping — the "why we need this" flows onto a second line, never truncates.
        let desc = WrappingLabel.make(subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.maximumNumberOfLines = 0
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let box = SquareToggle()
        box.side = 24
        box.onClick = { request() }
        card.addSubview(box)

        permRows.append(PermissionRowRefs(box: box, isGranted: isGranted))

        NSLayoutConstraint.activate([

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: box.leadingAnchor, constant: -10),

            box.widthAnchor.constraint(equalToConstant: 24),
            box.heightAnchor.constraint(equalToConstant: 24),
            box.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            box.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: box.leadingAnchor, constant: -10),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            desc.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])
        return card
    }

    // Same card shape as the permission rows, with a push button on the right instead
    // of a switch — for a row that DOES something once rather than holding a setting.
    private func makeActionRow(title: String, subtitle: String, button: String,
                               action: @escaping () -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = WrappingLabel.make(subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.maximumNumberOfLines = 0
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let btn = NSButton(title: button, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let handler = SoundHandler(onFire: action)
        soundHandlers.append(handler)
        btn.target = handler
        btn.action = #selector(SoundHandler.fire(_:))
        card.addSubview(btn)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -10),

            btn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            btn.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -10),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            desc.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])
        return card
    }

    // Same card shape as the permission rows (wrapping subtitle, control centered
    // on the right) but with a plain on/off switch — used for the usage probe row,
    // whose explanation is too long for makeToggleRow's single truncating line.
    private func makeWrapToggleRow(title: String, subtitle: String, isOn: Bool,
                                   onChange: @escaping (Bool) -> Void) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        let handler = ToggleHandler(onChange: onChange)
        toggleHandlers.append(handler)
        toggle.target = handler
        toggle.action = #selector(ToggleHandler.fire(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        let desc = WrappingLabel.make(subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.maximumNumberOfLines = 0
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        NSLayoutConstraint.activate([

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),

            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -10),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            desc.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])
        return card
    }

    private static let checkmark: NSImage? = NSImage(
        systemSymbolName: "checkmark", accessibilityDescription: L("已授权", "Granted"))?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))

    private func refreshPermissionRows() {
        for row in permRows {
            row.box.setGranted(row.isGranted(), checkmark: Self.checkmark)
        }
    }

    private func startPermRefresh() {
        refreshPermissionRows()
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionRows()
        }
    }

    private func stopPermRefresh() {
        permTimer?.invalidate(); permTimer = nil
    }

    private func makeRow(_ action: HotKeyAction) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: action.title)
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(name)

        let desc = NSTextField(labelWithString: action.subtitle)
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(desc)

        let recorder = HotKeyRecorderButton()
        recorder.onChange = { [weak self] combo in
            let status = self?.onRebind?(action, combo) ?? noErr
            if status != noErr { self?.recorders[action]?.flashTaken() }
            self?.recoLine.refresh()   // a hand-recorded ⌘1 counts as taking the offer
        }
        recorders[action] = recorder
        card.addSubview(recorder)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),

            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -10),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -10),

            recorder.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            recorder.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }
}

// The "推荐 ⌘1 / ⌘2" line under the two hotkey cards: a stated suggestion plus a
// one-click apply and, once applied, the one-click way back.
//
// It never hides. ⌘1/⌘2 is a binding with a real cost — Carbon grabs the keys
// before AppKit sees them, so every other app (and this window's own ⌘1/⌘2 tab
// switches) stops receiving them — and anyone who regrets that has to find the
// undo where they found the offer. State is derived from HotKeyStore, so there's
// no "did they already try it" flag to persist or get out of sync.
private final class RecommendedHotKeysLine: NSView {
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let apply = NSButton(title: "", target: nil, action: nil)
    private let onToggle: (Bool) -> Void

    // Both actions must match, or we're not "applied" — the recommendation is the
    // pair, not two separate offers.
    private var isApplied: Bool {
        HotKeyAction.allCases.allSatisfy { HotKeyStore.load($0) == $0.recommendedCombo }
    }

    init(onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // No fill: the two rows above are GlassCards, and matching their material
        // here would read as a third action of equal weight rather than an aside.
        toolTip = L("绑定后，⌘1 ⌘2 在任何 App 里都归 SpectiX —— 浏览器、编辑器的切换标签页，以及本窗口自己的 ⌘1 ⌘2 切 tab，都会收不到这两个键。",
                    "Once bound, ⌘1 ⌘2 belong to SpectiX everywhere — tab switching in browsers and editors, and this window's own ⌘1 ⌘2 tab switches, stop receiving them.")

        for label in [title, note] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        title.font = Theme.font(11.5, .regular)
        title.textColor = .secondaryLabelColor
        note.font = Theme.font(11, .regular)
        note.textColor = .tertiaryLabelColor
        note.stringValue = L("其它 App 的 ⌘1 ⌘2（如切换标签页）会被占用",
                             "Takes ⌘1 ⌘2 from other apps (e.g. tab switching)")

        apply.isBordered = false
        apply.font = Theme.rounded(11, .semibold)
        apply.target = self
        apply.action = #selector(clicked)
        apply.setContentCompressionResistancePriority(.required, for: .horizontal)
        apply.translatesAutoresizingMaskIntoConstraints = false
        addSubview(apply)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            apply.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            apply.centerYAnchor.constraint(equalTo: centerYAnchor),
            apply.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            apply.leadingAnchor.constraint(greaterThanOrEqualTo: note.trailingAnchor, constant: 8),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onToggle(!isApplied) }

    func refresh() {
        let applied = isApplied
        title.stringValue = applied
            ? L("✓ 已在用推荐快捷键 ⌘1 / ⌘2", "✓ Using the recommended ⌘1 / ⌘2")
            : L("推荐 ⌘1 唤起列表 · ⌘2 跳下一个", "Recommended: ⌘1 show list · ⌘2 jump to next")
        apply.title = applied ? L("还原默认", "Restore") : L("使用", "Use")
        apply.contentTintColor = applied ? .secondaryLabelColor : .controlAccentColor
        layer?.borderColor = Theme.hairline.cg(in: self)
    }

    // Theme.hairline is dynamic; a layer color has to be re-resolved by hand.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = Theme.hairline.cg(in: self)
    }
}

// Bridges an NSSwitch's target/action to a Swift closure. NSControl holds its
// target weakly, so the controller retains these in `toggleHandlers`.
private final class ToggleHandler {
    private let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    @objc func fire(_ sender: NSSwitch) { onChange(sender.state == .on) }
}

// Same weak-target bridge for the sound popups and buttons. Reads any needed
// state inside the closure (weak-captured), so the sender goes unused.
private final class SoundHandler {
    private let onFire: () -> Void
    init(onFire: @escaping () -> Void) { self.onFire = onFire }
    @objc func fire(_ sender: NSControl) { onFire() }
}

// A theme preset card: name + "✓ 使用中" check + a 6-dot color strip. The
// 自定义 variant passes a hint shown while unselected (its strip mirrors the
// live palette instead of a fixed preset).
// One cell of a segmented bar: an optional thumbnail stacked over a label.
// `filled` picks the selected look — an accent-filled pill (picking a value) vs an
// accent ring over a raised fill (picking a style, where the thumb carries the info).
private final class SegCell: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true
    private let label: NSTextField
    private let filled: Bool

    init(title: String, thumb: NSView?, filled: Bool) {
        self.filled = filled
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        label.font = Theme.font(filled ? 11.5 : 10.5, .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        if let thumb {
            thumb.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thumb)
            NSLayoutConstraint.activate([
                thumb.centerXAnchor.constraint(equalTo: centerXAnchor),
                thumb.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                label.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            ])
        } else {
            label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { if isEnabled { onClick?() } }

    func paint(selected: Bool) {
        if filled {
            layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            label.textColor = selected ? .white : .secondaryLabelColor
        } else {
            layer?.backgroundColor = selected
                ? NSColor.white.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor
            layer?.borderWidth = selected ? 1.5 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            label.textColor = selected ? .labelColor : .secondaryLabelColor
        }
    }
}

// A thumbnail of one caption style for the style bar — the real caption shrunk to
// its silhouette (text becomes bars), so the five options read at a glance. Drawn
// rather than composed: at this size a stack of subviews costs more than a path.
private final class CaptionMini: NSView {
    private let style: AppSettings.CaptionStyle

    init(_ style: AppSettings.CaptionStyle) {
        self.style = style
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 26) }

    // Hand-drawn, so the system won't repaint it on a light/dark switch by itself.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // The caption tracks the session's status color; 运行 blue stands in for it here.
    private var accent: NSColor { Status.accent("working") }
    private var deep: NSColor { NSColor.black.withAlphaComponent(0.72) }

    private func bar(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func draw(_ dirty: NSRect) {
        let w = bounds.width, h = bounds.height
        let boxW: CGFloat = 42

        switch style {
        case .hidden:
            let box = NSRect(x: (w - 26) / 2, y: (h - 15) / 2, width: 26, height: 15)
            let p = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            p.lineWidth = 1.5
            p.setLineDash([3, 2.5], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            p.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: box.minX + 1, y: box.maxY - 3))
            slash.line(to: NSPoint(x: box.maxX - 1, y: box.minY + 3))
            slash.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            slash.stroke()

        case .outlineDot:
            let box = NSRect(x: (w - boxW) / 2, y: (h - 16) / 2, width: boxW, height: 16)
            let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            accent.withAlphaComponent(0.10).setFill()
            p.fill()
            p.lineWidth = 1.5
            accent.setStroke()
            p.stroke()
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: box.minX + 5, y: box.midY - 3, width: 6, height: 6)).fill()
            bar(NSRect(x: box.minX + 15, y: box.midY - 1.5, width: 20, height: 3),
                NSColor.white.withAlphaComponent(0.6))

        case .accentRule:
            let box = NSRect(x: (w - boxW) / 2, y: (h - 16) / 2, width: boxW, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).addClip()
            deep.setFill()
            box.fill()
            accent.setFill()
            NSRect(x: box.minX, y: box.minY, width: 3, height: box.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            bar(NSRect(x: box.minX + 9, y: box.midY - 1.5, width: 22, height: 3),
                NSColor.white.withAlphaComponent(0.6))

        case .segmented:
            let box = NSRect(x: (w - boxW) / 2, y: (h - 16) / 2, width: boxW, height: 16)
            let split = box.minX + 18
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).addClip()
            deep.setFill()
            box.fill()
            accent.setFill()
            NSRect(x: box.minX, y: box.minY, width: 18, height: box.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            bar(NSRect(x: box.minX + 4, y: box.midY - 1.5, width: 10, height: 3),
                NSColor.black.withAlphaComponent(0.55))
            bar(NSRect(x: split + 4, y: box.midY - 1.5, width: 14, height: 3),
                NSColor.white.withAlphaComponent(0.6))

        case .titlebar:
            let x = (w - boxW) / 2
            let top = (h - 24) / 2
            let barRect = NSRect(x: x, y: top, width: boxW, height: 11)
            let p = NSBezierPath(roundedRect: barRect.insetBy(dx: 0.7, dy: 0.7), xRadius: 3, yRadius: 3)
            deep.setFill()
            p.fill()
            p.lineWidth = 1.4
            accent.setStroke()
            p.stroke()
            bar(NSRect(x: barRect.midX - 9, y: barRect.midY - 1.25, width: 18, height: 2.5),
                NSColor.white.withAlphaComponent(0.6))

            let body = NSBezierPath(roundedRect: NSRect(x: x + 0.75, y: top + 12.75,
                                                        width: boxW - 1.5, height: 10.5),
                                    xRadius: 3, yRadius: 3)
            body.lineWidth = 1.5
            body.setLineDash([3, 2.5], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            body.stroke()
        }
    }
}

private final class ThemeCard: NSView {
    var onClick: (() -> Void)?
    private let check = NSTextField(labelWithString: "✓ " + L("使用中", "In use"))
    private var dots: [NSView] = []

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(12, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        check.font = Theme.font(10, .medium)
        check.textColor = .controlAccentColor
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            check.centerYAnchor.constraint(equalTo: name.centerYAnchor),
        ])

        for i in 0..<6 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 7
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11 + CGFloat(i) * 19),
                dot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14),
            ])
            dots.append(dot)
        }

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    func set(colors: [NSColor], selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : Theme.cardFill.cgColor
        layer?.borderWidth = selected ? 1.5 : 1
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            : Theme.hairline.cgColor
        check.isHidden = !selected
        for (i, dot) in dots.enumerated() where i < colors.count {
            dot.layer?.backgroundColor = colors[i].cgColor
        }
    }
}

// A per-status capsule chip — the same tint treatment the app's pills use, so
// the chip itself previews the color. Click toggles its swatch accordion.
private final class StatusChip: NSView {
    var onClick: (() -> Void)?
    private let dot = NSView()
    private let label: NSTextField

    init(name: String) {
        label = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = Theme.rounded(12, .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    func paint(color: NSColor, selected: Bool) {
        layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        label.textColor = color
        dot.layer?.backgroundColor = color.cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
    }
}

// A 28pt round color swatch for the accordion. Selected = an outer ring with a
// gap. The rainbow variant (conic gradient ring) opens the system color panel.
private final class ColorSwatch: NSView {
    var onClick: (() -> Void)?

    init(color: NSColor? = nil, selected: Bool = false, rainbow: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        if rainbow {
            let g = CAGradientLayer()
            g.type = .conic
            g.frame = CGRect(x: 3, y: 3, width: 22, height: 22)
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 0.5, y: 0)
            g.colors = [NSColor.systemRed, .systemYellow, .systemGreen, .systemTeal,
                        .systemBlue, .systemPurple, .systemRed].map { $0.cgColor }
            // Punch out the middle so it reads as a ring on any background.
            let mask = CAShapeLayer()
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: 0, y: 0, width: 22, height: 22))
            path.addEllipse(in: CGRect(x: 6, y: 6, width: 10, height: 10))
            mask.path = path
            mask.fillRule = .evenOdd
            g.mask = mask
            layer?.addSublayer(g)
        } else if let color {
            let inner = CALayer()
            inner.frame = CGRect(x: 3, y: 3, width: 22, height: 22)
            inner.cornerRadius = 11
            inner.backgroundColor = color.cgColor
            layer?.addSublayer(inner)
        }

        if selected {
            layer?.cornerRadius = 14
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// Scroll documents lay out top-down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings section nav bar
//
// A horizontal pill nav pinned above the settings scroll view. Each pill maps to
// one section header in the scrolling column; clicking scrolls there and
// scrolling highlights the pill of the section at the top (scroll-spy, wired by
// SettingsPane). Modeled on BottomTabBar but text-only with a bottom hairline.
final class SettingsSectionBar: NSView {

    var onSelect: ((Int) -> Void)?

    private let border = NSView()
    private var pills: [SectionPill] = []

    init(titles: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        border.wantsLayer = true
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (i, t) in titles.enumerated() {
            let p = SectionPill(text: t, index: i)
            p.target = self
            p.action = #selector(pillClicked(_:))
            pills.append(p)
            stack.addArrangedSubview(p)
        }
        pills.first?.isOn = true

        NSLayoutConstraint.activate([
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pillClicked(_ sender: SectionPill) {
        select(sender.index)
        onSelect?(sender.index)
    }

    // Light exactly one pill (called both on click and by the scroll-spy).
    func select(_ index: Int) {
        for (i, p) in pills.enumerated() { p.isOn = i == index }
    }

    private func resolveColors() { border.layer?.backgroundColor = Theme.divider.cg(in: self) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// One nav pill: a centered 12pt label in a rounded-7 slice that brightens on
// hover and tints blue when selected. An NSButton so the click routes through
// AppKit; the inner label is inert (hitTest returns self).
final class SectionPill: NSButton {

    let index: Int
    var isOn = false { didSet { applyStyle() } }

    private let label = NSTextField(labelWithString: "")
    private var hovering = false

    init(text: String, index: Int) {
        self.index = index
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = Theme.rounded(12, .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyStyle() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        let blue = Status.accent("working")
        let fg: NSColor = isOn ? blue : (hovering ? .labelColor : .secondaryLabelColor)
        if isOn {
            layer?.backgroundColor = blue.withAlphaComponent(0.14).cgColor
        } else if hovering {
            layer?.backgroundColor = Theme.cardFill.cg(in: self)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        label.textColor = fg
    }
}
