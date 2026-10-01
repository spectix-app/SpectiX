import Cocoa

// MARK: - Menu-bar dropdown (popover)
//
// The status-item click shows this instead of a native NSMenu: it hosts the same
// drag-reorderable, collapsible session list as the main window. A menu can't —
// its modal tracking loop swallows the drag events reorder needs. Collapse a folder
// or drag to reorder here and the main window reflects it (shared ListModel). A
// The footer is a flat bottom bar isomorphic to the main window's tab bar
// (design/menu-popover-scheme6.html variant A): four icon+label entries that
// deep-link to the matching main-window tab (会话 / 最近项目 / 统计 / 设置),
// with the permission-fix entry appearing on the far left only when access is
// missing. Refresh / quit moved
// up to mini glass buttons in the header's top-right.
final class MenuPopoverController: NSViewController {

    private let model: ListModel
    private let listView: SessionListView
    private let hiddenBar = HiddenBar()   // 已隐藏 discoverability + undo, above the footer
    // Compact stats header: no count/chips/tally line — just the app logo and
    // the subscription quota row (会话/本周 %). The main window keeps the full one.
    private let statsHeader = HeaderStatsView(compact: true)
    private var warnButton: TabItemButton!   // permission fix (far left, warn)
    private var mainButton: TabItemButton!    // 会话 entry (opens home · sessions)

    var onJump: ((SessionRow) -> Void)?
    var onOpenWindow: (() -> Void)?
    var onOpenStats: (() -> Void)?
    var onOpenRecent: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onFixPermission: (() -> Void)?

    // Live width; seeded from the persisted value, mutated by the resize grip.
    private var popoverWidth: CGFloat = AppSettings.popoverWidth
    private let grip = ResizeGrip()
    // Base values captured at the start of a resize drag, so the grip's absolute
    // deltas apply against the pre-drag size (not accumulating per event).
    private var dragBaseWidth: CGFloat = 0
    private var dragBaseListCap: CGFloat = 0

    init(model: ListModel) {
        self.model = model
        self.listView = SessionListView(model: model)
        super.init(nibName: nil, bundle: nil)
        listView.onJump = { [weak self] row in self?.onJump?(row) }
        // The popover never SHOWS a feature tip (it's sized to content and dismissed on
        // the next click — no room, no dwell time), but discovering an affordance here
        // still retires that tip everywhere. See Tips.swift.
        listView.onLearned = { AppSettings.markTipSeen($0) }
        // A collapse/reorder changes the row count → resize the panel to fit.
        listView.onLayoutChange = { [weak self] in self?.resize() }
        statsHeader.onLayoutChange = { [weak self] in self?.resize() }
        // Hide → persist + show the undo bar; 恢复 opens 设置 › 已隐藏, 撤销 restores.
        listView.onHide = { [weak self] cwd, folder in
            let first = !AppSettings.hasSeenHideOnboarding
            AppSettings.hasSeenHideOnboarding = true
            AppSettings.hide(cwd: cwd)
            self?.hiddenBar.showUndo(folder: folder, cwd: cwd, onboarding: first)
        }
        hiddenBar.onOpenHidden = { [weak self] in self?.onOpenSettings?() }
        hiddenBar.onUndo = { cwd in AppSettings.unhide(cwd: cwd) }
        hiddenBar.onHeightChange = { [weak self] in self?.resize() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 360))

        // Opaque base + within-window frost — same recipe as the main window, so
        // the dropdown is fully opaque (no desktop bleeding through). Rounding
        // both (and the material mask) to the popover corner stops square corners
        // from leaking past the popover's rounded frame.
        let base = OpaquePane(radius: Theme.popoverRadius)
        base.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(base)

        let glass = Theme.surfacePane(material: .hudWindow, radius: Theme.popoverRadius)
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        statsHeader.emptyText = L("没有在跑的会话", "No running sessions")
        glass.addSubview(statsHeader)

        listView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(listView)

        hiddenBar.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hiddenBar)

        // Footer: flat bottom bar (variant A). Permission fix (warn, icon-only)
        // hugs the left and collapses when access is granted; the four deep-link
        // entries fill the rest equally.
        warnButton = TabItemButton(symbol: "exclamationmark.triangle", label: "", index: 0)
        warnButton.warn = true
        warnButton.toolTip = L("开启跳转权限（辅助功能）", "Enable jump permission (Accessibility)")
        warnButton.target = self
        warnButton.action = #selector(fixPermission)
        warnButton.isHidden = true
        warnButton.widthAnchor.constraint(equalToConstant: 38).isActive = true

        mainButton = makeEntry("macwindow", L("主界面", "Home"), #selector(openWindow), L("打开主界面 · 会话", "Open home · Sessions"))
        let statsEntry = makeEntry("chart.bar", L("统计", "Stats"), #selector(statsClicked), L("统计（任务 / 决定）", "Stats (tasks / decisions)"))
        let recentEntry = makeEntry("clock.arrow.circlepath", L("最近项目", "Recent"), #selector(recentClicked), L("最近项目", "Recent"))
        let settingsEntry = makeEntry("gearshape", L("设置", "Settings"), #selector(settingsClicked), L("设置（快捷键）", "Settings (hotkeys)"))

        let entries = NSStackView(views: [mainButton, statsEntry, recentEntry, settingsEntry])
        entries.orientation = .horizontal
        entries.distribution = .fillEqually
        entries.spacing = 4

        let footer = NSStackView(views: [warnButton, entries])
        footer.orientation = .horizontal
        footer.spacing = 4
        footer.distribution = .fill
        warnButton.setContentHuggingPriority(.required, for: .horizontal)
        entries.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(footer)

        NSLayoutConstraint.activate([
            base.topAnchor.constraint(equalTo: container.topAnchor),
            base.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            base.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            base.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statsHeader.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            statsHeader.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            statsHeader.topAnchor.constraint(equalTo: glass.topAnchor, constant: 12),

            // Same recipe as the main window: the side margin is spent INSIDE the
            // cell (Theme.cardCellInset) so the card's shadow has room to fade, so
            // the list itself insets by `pad - cardCellInset` (= 0). The popover
            // used to add 6 on top of that, putting its cards at 24 — wider than
            // the main window's 18 on a far narrower surface.
            listView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad - Theme.cardCellInset),
            listView.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -(Theme.pad - Theme.cardCellInset)),
            // 8 = the gap the list puts between projects (the header stacks as one more
            // card). Fixed here, outside the scroll view, so it survives scrolling; the
            // list's first header row drops its own 8 (HeaderCell.topGap).
            listView.topAnchor.constraint(equalTo: statsHeader.bottomAnchor, constant: 8),

            hiddenBar.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            hiddenBar.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            hiddenBar.topAnchor.constraint(equalTo: listView.bottomAnchor, constant: 4),

            footer.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),
            footer.topAnchor.constraint(equalTo: hiddenBar.bottomAnchor, constant: 6),
            footer.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -8),
        ])

        // Resize grip: a small drag handle pinned to the bottom-right corner, on
        // top of everything. Dragging it changes the popover width (dx) and the
        // list-height cap (dy, downward = taller), both persisted.
        grip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 16),
        ])
        grip.onBegin = { [weak self] in
            guard let self else { return }
            self.dragBaseWidth = self.popoverWidth
            self.dragBaseListCap = AppSettings.popoverListCap
        }
        grip.onDrag = { [weak self] dx, dyDown in
            guard let self else { return }
            let r = AppSettings.popoverWidthRange
            self.popoverWidth = min(max(self.dragBaseWidth + dx, r.lowerBound), r.upperBound)
            AppSettings.popoverListCap = self.dragBaseListCap + dyDown
            self.resize()
        }

        view = container
    }

    // A flat footer entry: reuses the tab bar's button, wired as a deep-link
    // action (never selected, no keyEquivalent).
    private func makeEntry(_ symbol: String, _ label: String, _ action: Selector, _ tip: String) -> TabItemButton {
        let b = TabItemButton(symbol: symbol, label: label, index: 0)
        b.target = self
        b.action = action
        b.toolTip = tip
        return b
    }

    func reload(_ rows: [SessionRow], usage: UsageSnapshot? = nil,
                header: HeaderAgentInfo? = nil) {
        _ = view  // force the view to load if it hasn't (macOS 13-safe; loadViewIfNeeded() is 14+)
        statsHeader.update(rows: rows, usage: usage,
                           codexUsage: header?.codexUsage,
                           claudeAccount: header?.claudeAccount,
                           codexAccount: header?.codexAccount,
                           claudeRemembered: header?.claudeRemembered ?? false,
                           codexRemembered: header?.codexRemembered ?? false)
        // Also shown when the grant is on paper only: AXIsProcessTrusted() can report true
        // while every AX call comes back empty (see AppController.axDegraded), and that
        // looks to the user exactly like "the Claude desktop rows are missing". Different
        // tooltip for that case — "turn the permission on" is confusing advice when the
        // switch is already on.
        warnButton.isHidden = AXIsProcessTrusted() && !AppController.axDegraded
        warnButton.toolTip = AXIsProcessTrusted()
            ? L("辅助功能权限已失效，点这里看怎么修", "Accessibility permission has gone stale — click for the fix")
            : L("开启跳转权限（辅助功能）", "Enable jump permission (Accessibility)")
        listView.reload(rows)
        hiddenBar.update(count: AppSettings.hiddenCwds.count)
        resize()
    }

    // Called just before the popover is shown: let the list scroll the active session
    // into view once on open, then hand scrolling back to the user for this showing.
    func prepareForShow() { listView.resetScrollFollow() }

    // A terminal was focused → reveal + highlight its session in the popover list.
    // The caller (AppController) gates this on the popover actually being shown.
    func focusSession(shellPid pid: pid_t) {
        listView.focusSession(shellPid: pid)
    }

    // Keyboard navigation while the popover is up (driven by AppController's key
    // monitor): ↑/↓ move the highlighted session, ⏎ jumps to it.
    func selectPrevSession() { listView.moveKeyboardSelection(-1) }
    func selectNextSession() { listView.moveKeyboardSelection(1) }
    func activateSelectedSession() { listView.activateKeyboardSelection() }

    // Size the popover to header + list content + footer, capped so a long list
    // scrolls rather than growing without bound.
    private func resize() {
        // 12 (top gap) + statsHeader (varies with the quota row) + 8 + list
        // + 6 + 30 (footer) + 8 (bottom).
        let headerH = statsHeader.fittingSize.height
        // Height follows the user-set cap directly (symmetric with width, which
        // tracks popoverWidth, not content). A short list just leaves room below
        // — like dragging a window taller. The cap's getter clamps to its range.
        let listH = AppSettings.popoverListCap
        // When the 已隐藏 bar is showing it adds its own height + the 4/6pt gaps.
        let hiddenH = hiddenBar.isHidden ? 0 : (HiddenBar.barHeight + 10)
        let desired = 64 + headerH + listH + hiddenH
        // Clamp to the screen's usable height so a tall listCap can never make the
        // popover taller than the space below the menu bar — otherwise NSPopover
        // shoves its top edge past the top of the screen to fit, clipping the first
        // project header (most visible in a menu-bar-hidden fullscreen Space).
        // Use the absolute screen height minus a fixed menu-bar band, NOT
        // visibleFrame, so the cap is identical whether the menu bar is currently
        // shown or auto-hidden.
        let screen = view.window?.screen ?? NSScreen.main
        let usable = screen.map { $0.frame.height - NSStatusBar.system.thickness - 12 } ?? .greatestFiniteMagnitude
        preferredContentSize = NSSize(width: popoverWidth, height: min(desired, usable))
    }

    @objc private func fixPermission() { onFixPermission?() }
    @objc private func openWindow()    { onOpenWindow?() }
    @objc private func statsClicked()  { onOpenStats?() }
    @objc private func recentClicked() { onOpenRecent?() }
    @objc private func settingsClicked(){ onOpenSettings?() }
}

// MARK: - Resize grip
//
// An invisible bottom-right drag zone that lets the user size the dropdown. No
// visible tick marks — the pointer turning into the diagonal resize cursor is
// the only affordance, matching how the main window's corner reads. Deltas are
// computed in absolute screen coordinates (NSEvent.mouseLocation) so the popover
// window repositioning itself as it grows can't corrupt the math. `onBegin`
// captures the pre-drag baseline; `onDrag` reports (dx, dyDown) where positive
// dyDown means the pointer moved down = taller.
final class ResizeGrip: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?

    private var startMouse: NSPoint = .zero

    // The system's NW↔SE diagonal resize cursor — the same one shown at a
    // window's corner. AppKit exposes no public diagonal resize cursor, so pull
    // the private factory (fall back to arrow if it ever disappears).
    private static let diagonalResize: NSCursor = {
        let sel = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if NSCursor.responds(to: sel),
           let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return c
        }
        return .arrow
    }()

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ResizeGrip.diagonalResize)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        // Screen y grows upward, so dragging the pointer down lowers y → negate
        // to make "down = positive = taller".
        onDrag?(now.x - startMouse.x, startMouse.y - now.y)
    }
}
