import Cocoa
import UniformTypeIdentifiers

// MARK: - Session list (shared by the main window and the menu-bar popover)
//
// The grouped, drag-reorderable list: a folder header per VSCode window followed
// by its indented session children. Owns the table, its drag-to-reorder + collapse
// behavior, and the empty-state label; reads/writes the shared ListModel so both
// surfaces stay in sync (reorder or collapse in one, the other reflects it on its
// next reload). Hosts supply only the chrome around it (titles, chips, footer) and
// call reload().
final class SessionListView: NSView, NSTableViewDataSource, NSTableViewDelegate, ReorderCoordinator {

    private let model: ListModel
    private var items: [DisplayItem] = [] { didSet { rebuildGroupIndex() } }
    // For each row, the id of the project group whose block it sits in (title row
    // included), else nil. Drives the rail and which drops land inside a group.
    private var rowGroup: [String?] = []
    // The header a drag is resting on, and since when — the drag-merge dwell (T387).
    private var mergeDwell: (row: Int, since: Date)?
    // The on-screen render of the last reload, one string per row. A hook writing a
    // session's state-<tty>/step-<tty> makes FSEvents fire refresh() many times a
    // second, but most carry identical VISIBLE content; rebuilding the table on those
    // no-ops tore hover down and re-applied it every time — the "hover flickers while
    // another session works" jitter. reload() skips reloadData when this is unchanged.
    private var lastRenderKey: [String] = []
    var onJump: ((SessionRow) -> Void)?
    // The user just used an affordance a feature tip would have taught (see Tips.swift).
    // Fired from both surfaces — discovering "click to jump" in the popover counts, even
    // though the tip itself only ever shows in the main window.
    var onLearned: ((String) -> Void)?
    // A project header's "隐藏" was picked. The host persists the hide (so it can
    // also drive the undo bar); nil = no host wired, fall back to hiding directly.
    var onHide: ((_ cwd: String, _ folder: String) -> Void)?
    // Fired after an in-place collapse/reorder so a content-sized host (the popover)
    // can resize to the new row count.
    var onLayoutChange: (() -> Void)?

    private let tableView = ReorderTableView()
    private let scroll = OverlayScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let edgeGlow = OverflowEdgeGlow(edge: .bottom)
    private let topEdgeGlow = OverflowEdgeGlow(edge: .top)

    static let headerHeight: CGFloat = 42
    static let firstHeaderHeight: CGFloat = headerHeight - 8   // no own top gap, see HeaderCell.topGap

    // The badge right-click menu; it holds the icon-editing context (only one menu
    // is open at a time).
    private let iconMenu = ProjectIconMenu()

    init(model: ListModel) {
        self.model = model
        super.init(frame: .zero)
        setup()
        // Re-render in place when a display preference (e.g. status labels) flips.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: AppSettings.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Re-derive items, not just reloadData — a sort-mode flip must re-order the
    // cached items in place, not merely re-render them.
    @objc private func settingsChanged() { refreshItems() }

    private func setup() {
        // ── List ──
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // Force a floating (overlay) scroller even when the system pref is "Always
        // show scroll bars" — a legacy scroller reserves a ~16pt right gutter that
        // shifts the cards left (the "右边空太多/和 refresh 不对齐" bug). Pinning the
        // scroller alone isn't enough: gutter reservation follows the SCROLL VIEW's
        // scrollerStyle, which AppKit resets to .legacy after setup whenever the
        // system pref says so — OverlayScrollView pins that too.
        scroll.verticalScroller = OverlayScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The bottom inset also has to clear the last card's shadow: the clip rect
        // crops it in a straight line otherwise (same budget as Theme.cardCellInset).
        // Top inset 0: the 8pt between the stats header's metric cards and the first
        // project (the same 8 as between projects) lives in the HOST, outside this
        // scroll view, so it stays put while the rows scroll under the clip line; the
        // first header row drops its own 8 (HeaderCell.topGap) so nothing doubles up.
        // The bottom inset stays: nothing down there supplies its own.
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 0)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        // NSTableColumn.maxWidth defaults to 400: in any host wider than that the
        // lone column stops stretching and the leftover width piles up as a fat
        // right gap (cards hug the left edge, 左右不对齐). Uncap it so the column
        // always tracks the table width.
        col.maxWidth = .greatestFiniteMagnitude
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = Theme.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none   // cells draw their own hover
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.registerForDraggedTypes([reorderType])
        tableView.coordinator = self
        // Reaching for the mouse exits keyboard-nav mode — the pin stops beating hover.
        tableView.onPointerMoved = { [weak self] in self?.kbActive = false }
        tableView.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        scroll.documentView = tableView
        addSubview(scroll)

        emptyLabel.stringValue = L("没有在跑的会话", "No sessions running")
        emptyLabel.font = Theme.font(13, .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        edgeGlow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edgeGlow)
        topEdgeGlow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topEdgeGlow)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            edgeGlow.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeGlow.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeGlow.bottomAnchor.constraint(equalTo: bottomAnchor),
            edgeGlow.heightAnchor.constraint(equalToConstant: OverflowEdgeGlow.height),

            // Mirror of the bottom one: the bar rides the list's top edge — which is
            // also the clip line the rows scroll under (the fixed 8pt gap to the stats
            // header sits above it, in the host).
            topEdgeGlow.leadingAnchor.constraint(equalTo: leadingAnchor),
            topEdgeGlow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topEdgeGlow.topAnchor.constraint(equalTo: topAnchor),
            topEdgeGlow.heightAnchor.constraint(equalToConstant: OverflowEdgeGlow.height),
        ])

        // Scrolling alone changes what's below the fold, and it fires no reload — the
        // glow has to follow the clip view directly.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @objc private func didScroll() { updateEdgeGlow() }

    // A resize changes the fold line without touching rows or scroll offset.
    override func layout() {
        super.layout()
        updateEdgeGlow()
    }

    // Total height of all rows — for hosts that size to content (the popover).
    var contentHeight: CGFloat {
        items.enumerated().reduce(0) { h, e in
            switch e.element {
            case .header: return h + (e.offset == 0 ? Self.firstHeaderHeight : Self.headerHeight)
            case .child:  return h + 50
            case .agent:  return h + Theme.agentRowHeight
            case .service: return h + ServiceCell.rowHeight
            case .group(_, _, _, let collapsed, _):
                return h + GroupTitleCell.height(collapsed: collapsed, isFirst: e.offset == 0)
            }
        }
    }

    // MARK: Project groups (T387)

    private func rebuildGroupIndex() {
        var span: String?
        rowGroup = items.map { it in
            switch it {
            case .group(let id, _, _, _, _):
                span = id
            case .header(_, let kind, _, _):
                // A header stays in the open block only if it belongs to that group.
                if let s = span, kind.projectCwd.flatMap({ model.group(containing: $0)?.id }) != s { span = nil }
            case .child, .agent, .service:
                break
            }
            return span
        }
    }

    private func isGroupTitle(_ row: Int) -> Bool {
        if case .group = items[row] { return true }
        return false
    }

    // This row's stretch of its group's rail: from the title down to the last row
    // of the last member.
    private func rail(forRow row: Int) -> GroupRail {
        guard row < rowGroup.count, let g = rowGroup[row] else { return .none }
        let starts = isGroupTitle(row)
        let ends = row == items.count - 1 || rowGroup[row + 1] != g
        switch (starts, ends) {
        case (true, true):  return .only
        case (true, false): return .start
        case (false, true): return .end
        default:            return .middle
        }
    }

    private func applyRail(_ rowView: NSTableRowView, row: Int) {
        // The rail starts level with the title's icon, below the row's own top gap.
        (rowView as? TransparentRowView)?.setGroupRail(rail(forRow: row), topInset: row == 0 ? 2 : 10)
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        applyRail(rowView, row: row)
    }

    private func subject(_ row: Int) -> GroupSubject? {
        switch items[row] {
        case .header(_, let kind, _, _): return kind.projectCwd.map { .project($0) }
        case .group(let id, _, _, _, _): return .group(id)
        default: return nil
        }
    }

    // Projects top to bottom as the list shows them (rows before `end`), a collapsed
    // group standing for its open members.
    private func projectOrder(upTo end: Int? = nil) -> [String] {
        items[0..<min(end ?? items.count, items.count)].flatMap { it -> [String] in
            switch it {
            case .header(_, let kind, _, _): return kind.projectCwd.map { [$0] } ?? []
            case .group(let id, _, _, true, _): return model.liveMembers(id)
            default: return []
            }
        }
    }

    // Can the header at `src` be merged into the header / group title at `target`?
    private func canMerge(_ src: Int, onto target: Int) -> Bool {
        guard target != src, target >= 0, target < items.count,
              subject(src) != nil, subject(target) != nil else { return false }
        let srcGroup = rowGroup[src], tgtGroup = rowGroup[target]
        // Already together: a member onto its own group (title or sibling), or a group
        // onto anything inside itself.
        if srcGroup != nil, srcGroup == tgtGroup { return false }
        return true
    }

    private var mergeReady: Bool {
        guard let d = mergeDwell else { return false }
        return Date().timeIntervalSince(d.since) >= ProjectGroupStyle.dwell - 0.02
    }

    private func mergeState(forRow row: Int) -> MergeState {
        guard let d = mergeDwell, d.row == row else { return .none }
        guard mergeReady else { return .counting(since: d.since) }
        return .ready(joining: rowGroup[row] != nil)
    }

    private func applyMergeState(row: Int) {
        guard row >= 0, row < items.count else { return }
        let v = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        let s = mergeState(forRow: row)
        (v as? HeaderCell)?.setMergeState(s)
        (v as? GroupTitleCell)?.setMergeState(s)
    }

    private func startDwell(on row: Int) {
        guard mergeDwell?.row != row else { return }
        clearDwell()
        let since = Date()
        mergeDwell = (row, since)
        applyMergeState(row: row)
        // Flip to "ready" on time even if the pointer stops moving and AppKit sends no
        // further drag updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + ProjectGroupStyle.dwell) { [weak self] in
            guard let self, let d = self.mergeDwell, d.row == row, d.since == since else { return }
            self.applyMergeState(row: row)
        }
    }

    private func clearDwell() {
        guard let d = mergeDwell else { return }
        mergeDwell = nil
        applyMergeState(row: d.row)
    }

    private func merge(_ src: Int, onto target: Int) {
        guard let s = subject(src), let t = subject(target) else { return }
        let flat = projectOrder()
        let moved = model.merge(s, onto: t)
        model.setFolderOrder(model.rebuildOrder(flat: flat, moved: moved))
    }

    func reload(_ rows: [SessionRow]) {
        model.update(rows)
        let newItems = model.items()
        let key = Self.renderKey(newItems, model: model)
        // Nothing visible changed (the common case under the FSEvents write storm) →
        // don't rebuild the table: a no-op reloadData would only flash the hover lift.
        // applyPin still runs so a terminal-focus pin lands, but it's a cheap diff.
        guard key != lastRenderKey else { applyPin(); updateEdgeGlow(); return }
        lastRenderKey = key
        let old = items
        items = newItems
        // Header-only groups (open VSCode windows with no session) count as content —
        // gate on the rendered items, not on `rows`, or the "no sessions" placeholder
        // would sit on top of them.
        emptyLabel.isHidden = !newItems.isEmpty
        reloadRows(replacing: old)
        tableView.hoverDidReload()
        applyPin()
        updateEdgeGlow()
    }

    // Re-read the model after an in-place collapse/reorder (rows unchanged).
    private func refreshItems() {
        items = model.items()
        // Settings (sort mode / status labels / gauge style) also drive the render but
        // aren't in the key; a settings-driven refresh always rebuilds, then records the
        // new baseline so the next identical poll still short-circuits.
        lastRenderKey = Self.renderKey(items, model: model)
        tableView.reloadData()
        tableView.hoverDidReload()
        applyPin()
        updateEdgeGlow()
        onLayoutChange?()
    }

    // MARK: Below-the-fold status glow

    private func updateEdgeGlow() {
        edgeGlow.update(status: overflowStatus(.bottom))
        topEdgeGlow.update(status: overflowStatus(.top))
    }

    // The most urgent status that has scrolled out of sight past the list's bottom
    // (or top) edge — "needs" beats "done", and nothing else qualifies: working/idle
    // ask nothing of you, so counting them would leave the glow permanently lit and
    // therefore meaningless.
    private func overflowStatus(_ edge: OverflowEdgeGlow.Edge) -> String? {
        let visible = tableView.visibleRect
        guard !items.isEmpty, visible.height > 1 else { return nil }
        // A sliver of a row peeking over the edge doesn't count as seen.
        let hidden: (Int) -> Bool
        switch edge {
        case .bottom:
            let fold = visible.maxY - 14
            hidden = { self.tableView.rect(ofRow: $0).minY > fold }
        case .top:
            let fold = visible.minY + 14
            hidden = { self.tableView.rect(ofRow: $0).maxY < fold }
        }
        var found: String?
        for (i, it) in items.enumerated() where hidden(i) {
            let st: String?
            switch it {
            // A collapsed group emits no children, so its header's counts are the only
            // trace of what's inside — read them, or a collapsed 需确认 folder down
            // there stays invisible, which is the whole bug this fixes.
            case .header(_, _, let counts, _), .group(_, _, let counts, _, _):
                let live = counts.filter { $0.1 > 0 }.map { $0.0 }
                st = live.contains("needs") ? "needs" : (live.contains("done") ? "done" : nil)
            case .child(let r):
                let b = Status.bucket(r.status)
                st = (b == "needs" || b == "done") ? b : nil
            case .agent, .service:
                st = nil
            }
            if st == "needs" { return "needs" }
            if st == "done" { found = "done" }
        }
        return found
    }

    // One string per row capturing exactly what the cell paints, so reload() can skip a
    // rebuild when the derived rows render identically. Must include every field a cell
    // reads (miss one → a real change wouldn't repaint). Settings that alter rendering
    // are handled by refreshItems (see above), not folded in here.
    private static func renderKey(_ items: [DisplayItem], model: ListModel) -> [String] {
        items.enumerated().map { i, it in
            switch it {
            case .header(let folder, let kind, let counts, let collapsed):
                let source = kind.projectCwd.map { model.source(forCwd: $0) } ?? .vscode
                let pinned = kind.projectCwd.map { model.isPinned($0) } ?? false
                let c = counts.map { "\($0.0):\($0.1)" }.joined(separator: ",")
                let branch = kind.projectCwd.flatMap { AppSettings.showsBranch(cwd: $0) ? GitBranch.current(cwd: $0) : nil } ?? ""
                return "H¦\(folder)¦\(kind.collapseKey)¦\(collapsed)¦\(c)¦\(source)¦\(pinned)¦\(branch)"
            case .group(let id, let name, let counts, let collapsed, let members):
                let c = counts.map { "\($0.0):\($0.1)" }.joined(separator: ",")
                return "G¦\(id)¦\(name)¦\(collapsed)¦\(c)¦\(members.joined(separator: ","))"
            case .child(let r):
                let isFirst = i == 0 || items[i - 1].isHeader
                let isLast = i == items.count - 1 || items[i + 1].isHeader
                let fields: [String] = [
                    "C", r.status, r.taskTitle, String(r.seq), String(r.isDesktop), r.step,
                    String(r.bgAgents), String(r.bgShells),
                    r.services.map { "\($0.port)\($0.stale)" }.joined(separator: ","),
                    UsageMetricsView.fmtDur(r.workSec), UsageMetricsView.fmtTok(r.ctxTokens), String(r.ctxPct),
                    r.model,
                    r.cwd, String(describing: r.terminalApp), String(isFirst), String(isLast),
                    // A tty can change agent between polls (quit claude, start codex in
                    // the same terminal). Everything else on the row can legitimately be
                    // identical across that swap — same folder, same seq, both idle with
                    // no model resolved yet — so without this the row keeps the previous
                    // agent's chip until some unrelated field happens to change.
                    r.agentKind.rawValue,
                    String(model.isAgentExpanded(r.tty)),   // badge chevron direction
                ]
                return fields.joined(separator: "¦")
            case .agent(let a, let parent):
                // Elapsed is rendered coarsely (fmtDur), so this key only churns when
                // the visible figure would actually change — same policy as workSec.
                let now = Date().timeIntervalSince1970
                let elapsed = a.start > 0 ? max(0, Int(now - a.start)) : 0
                let isLastNode = i == items.count - 1 || !items[i + 1].isAgent
                let isLastRow = i == items.count - 1 || items[i + 1].isHeader
                let fields: [String] = [
                    "A", a.id, a.type, a.desc, a.step,
                    // Tokens likewise: the node paints fmtTok's coarse figure, so keying
                    // on the raw count would rebuild the list on every unchanged render.
                    // Same reason ctxPct (not ctxTokens) stands in for the % capsule: the
                    // agent's occupancy climbs continuously while it works, but only the
                    // rounded percent is on screen — exactly the row key's policy above.
                    UsageMetricsView.fmtDur(elapsed), UsageMetricsView.fmtTok(a.ctxTokens),
                    String(a.ctxPct), parent.status,
                    // Both models: the agent's own override AND the parent's, since the
                    // node falls back to the parent's label when the agent has none.
                    a.model, parent.model,
                    String(isLastNode), String(isLastRow),
                ]
                return fields.joined(separator: "¦")
            case .service(let s, let cwd):
                let isLastRow = i == items.count - 1 || items[i + 1].isHeader
                // Uptime keyed coarsely, like every other clock in this key: a rebuild
                // under the cursor would drop a click on 打开 / 停止.
                let up = ServiceCell.uptime(Date().timeIntervalSince1970 - s.start)
                return ["S", cwd, "\(s.ports)", s.kind, String(s.stale), up,
                        String(isLastRow)].joined(separator: "¦")
            }
        }
    }

    // MARK: Terminal-focus → list sync
    //
    // The user focused a terminal (AppController.checkFocusFlash feeds us its shellPid):
    // reveal that session's row (expand its group if collapsed) and highlight it exactly
    // like a hover, held until another terminal is focused. Pinned by shellPid, not row
    // index, so it tracks the right session across collapses/reorders/refreshes.
    var pinnedShellPid: pid_t = 0
    // A collapsed group's header can also be pinned (keyboard nav lands on it — it's the
    // only way to reach a collapsed group). Mutually exclusive with pinnedShellPid: the
    // pin is EITHER a child session OR a header, never both. Keyed by collapseKey so it
    // tracks the right header across reorders. Terminal-focus always pins a child.
    private var pinnedHeaderKey: String? = nil
    // One-shot scroll permit, set on surface open (resetScrollFollow). Forces the next
    // applyPin to scroll to the active session even when the pinned target is unchanged
    // (the user may have scrolled it out of view before reopening). Consumed on use.
    private var scrollPinOnce = false
    // The pin target we last auto-scrolled to. A CHANGED target (terminal switch) re-scrolls
    // to follow the newly-focused session; an UNCHANGED target on a plain poll/reload does
    // NOT scroll, so the user's manual scroll survives the 2.5s refresh.
    private var lastScrolledTarget: KBTarget? = nil
    // True while the user is arrow-key navigating: the pin should beat a stationary
    // hover (see ReorderTableView.pinBeatsHover). Cleared by the first mouse move
    // (tableView.onPointerMoved) and by a terminal-focus pin, which is mouse-neutral.
    private var kbActive = false
    // Grant one auto-scroll: the next applyPin scrolls the pin into view once, then stops.
    // Called when a surface (re)appears — land on the active session on open, then leave
    // scrolling to the user (terminal switches only re-highlight, they don't re-scroll).
    func resetScrollFollow() { scrollPinOnce = true }

    func focusSession(shellPid pid: pid_t) {
        kbActive = false   // a terminal-focus pin is not keyboard nav — hover may override it
        pinnedHeaderKey = nil   // a terminal focus is a child pin, never a header
        // Unknown terminal (non-session, or a project not in the list) → drop the pin.
        guard rows(containing: pid) else { pinnedShellPid = 0; applyPin(); return }
        pinnedShellPid = pid
        if model.expandGroup(containingShellPid: pid) {
            refreshItems()   // group opened → rows changed; refreshItems re-asserts the pin
        } else {
            applyPin()
        }
    }

    private func rows(containing pid: pid_t) -> Bool {
        model.rows.contains { $0.shellPid == pid }
    }

    // Re-derive the pinned session's current row index (it shifts as groups collapse or
    // reorder) and hand it to the table; scroll it into view when present.
    private func applyPin(scroll: Bool = false) {
        let idx: Int?
        if let key = pinnedHeaderKey {
            idx = items.firstIndex {
                if case .header(_, let k, _, _) = $0 { return k.collapseKey == key }
                return false
            }
        } else if pinnedShellPid > 0 {
            idx = items.firstIndex {
                if case .child(let r) = $0 { return r.shellPid == pinnedShellPid }
                return false
            }
        } else {
            tableView.setPinnedRow(-1); lastScrolledTarget = nil; return
        }
        tableView.setPinnedRow(idx ?? -1, beatsHover: kbActive)
        // Scroll on: keyboard nav (explicit), the open permit (surface just appeared), or a
        // changed pin target (terminal switch → follow it). A plain poll/reload re-asserts the
        // SAME target and hits none of these → no scroll → the user's manual scroll survives.
        if let idx, scroll || scrollPinOnce || currentTarget != lastScrolledTarget {
            tableView.scrollRowToVisible(idx)
            scrollPinOnce = false
            lastScrolledTarget = currentTarget
        }
    }

    // MARK: Keyboard navigation (popover: ↑/↓ select a row, ⏎ activates it)
    //
    // Reuses the focus-pin channel: a keyboard selection is just "one highlighted row
    // that survives reloads", identical to the terminal-focus pin. Selectable rows are
    // ONLY the headers — arrow keys hop header-to-header (both collapsed and expanded),
    // never into individual child sessions. Tracked by a stable identity (collapseKey),
    // not row index, so the selection rides collapses/reorders/refreshes.
    // Mouse hover still previews on top; the selection re-lights when the pointer leaves.
    private enum KBTarget: Equatable {
        case child(pid_t)
        case header(String)   // collapseKey
    }

    // Ordered selectable targets, top to bottom — every header, children excluded.
    private var selectableTargets: [KBTarget] {
        items.compactMap {
            switch $0 {
            case .child, .agent, .service, .group: return nil
            case .header(_, let k, _, _): return .header(k.collapseKey)
            }
        }
    }

    // The current selection as a target, derived from whichever pin is set.
    private var currentTarget: KBTarget? {
        if let key = pinnedHeaderKey { return .header(key) }
        if pinnedShellPid > 0 { return .child(pinnedShellPid) }
        return nil
    }

    // Point the pin at a target (clearing the other pin channel).
    private func select(_ t: KBTarget) {
        switch t {
        case .child(let pid): pinnedShellPid = pid; pinnedHeaderKey = nil
        case .header(let key): pinnedHeaderKey = key; pinnedShellPid = 0
        }
    }

    // Move the selection by delta (+1 = down, -1 = up), clamped at the ends. With no
    // current selection, ↓ picks the first row and ↑ the last. No-op with nothing to pick.
    func moveKeyboardSelection(_ delta: Int) {
        let targets = selectableTargets
        guard !targets.isEmpty else { return }
        let next: Int
        if let cur = currentTarget, let ci = targets.firstIndex(of: cur) {
            next = min(max(ci + delta, 0), targets.count - 1)
        } else {
            next = delta > 0 ? 0 : targets.count - 1
        }
        kbActive = true          // the selection must beat a stationary hover
        select(targets[next])
        applyPin(scroll: true)   // keep the moving selection visible
    }

    // Activate the keyboard selection — mirrors a mouse click on that row. A child jumps
    // to its session; a collapsed header behaves like a header-body click (project → jump
    // into its most urgent session). Returns false when
    // there's nothing to activate (so the caller can fall back, e.g. jump the first row).
    @discardableResult
    func activateKeyboardSelection() -> Bool {
        if let key = pinnedHeaderKey {
            guard case .header(_, let kind, _, _)? = items.first(where: {
                if case .header(_, let k, _, _) = $0 { return k.collapseKey == key }
                return false
            }) else { return false }
            switch kind {
            case .project(let cwd): jumpToPriority(cwd)
            }
            return true
        }
        guard pinnedShellPid > 0,
              let r = model.rows.first(where: { $0.shellPid == pinnedShellPid }) else { return false }
        fireJump(r)
        return true
    }

    // MARK: Drag-to-reorder (collapse-all while a header drags)

    // Project headers and group titles: both drag by their icon and start a card run.
    func rowIsHeader(_ row: Int) -> Bool {
        guard row >= 0, row < items.count else { return false }
        return items[row].isHeader
    }

    // The header + its child rows (down to the next header / end of list). Used by the
    // table to lift a whole group together when its header is hovered (方案 H1).
    func groupRows(headerRow: Int) -> [Int] {
        guard rowIsHeader(headerRow) else { return [] }
        return Array(headerRow..<groupEnd(headerAt: headerRow))
    }

    // A session row plus the agent nodes hanging under it — the sublist is drawn as
    // that row's own agent segment (方案 16), not as rows of its own, so the pair has
    // to lift as one. Empty unless `childRow` is a session row with an expanded
    // sublist (a childless row keeps the single-card float).
    func agentClusterRows(childRow: Int) -> [Int] {
        guard childRow >= 0, childRow < items.count, case .child = items[childRow] else { return [] }
        var end = childRow + 1
        while end < items.count, items[end].isAgent { end += 1 }
        return end > childRow + 1 ? Array(childRow..<end) : []
    }

    func beginHeaderDrag(originalRow: Int) -> Int? {
        guard originalRow >= 0, originalRow < items.count, let dragged = subject(originalRow) else { return nil }
        model.beginDragCollapseAll()
        refreshItems()
        // The dragged row's new index in the now all-collapsed list (groups stay open so
        // their members remain drop targets).
        return items.indices.first { subject($0) == dragged }
    }

    func endHeaderDrag() {
        clearDwell()
        model.endDragCollapse()
        refreshItems()
    }

    // MARK: Drag-to-reorder (drop side)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let src = sourceRow(from: info) else { return [] }
        // Resting a dragged header on another header (or a group title) for the dwell
        // merges them on release (T387). Until the dwell completes the drop stays a
        // plain reorder, so a quick pass over a header never merges by accident.
        if items[src].isHeader, op == .on, canMerge(src, onto: row) {
            startDwell(on: row)
            if mergeReady {
                applyMergeState(row: row)
                tableView.setDropRow(row, dropOperation: .on)
                return .move
            }
        } else {
            clearDwell()
        }
        // Retarget an onto-row drop to an insertion so the whole row height is a valid
        // drop target, not just the thin gaps between rows.
        tableView.setDropRow(constrainedDropRow(source: src, proposed: row), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let src = sourceRow(from: info) else { return false }
        // The dwell may have completed after AppKit's last validateDrop, so trust the
        // clock rather than the drop operation.
        if let d = mergeDwell, mergeReady, items[src].isHeader {
            clearDwell()
            merge(src, onto: d.row)
            refreshItems()
            return true
        }
        clearDwell()
        let target = constrainedDropRow(source: src, proposed: row)
        switch items[src] {
        case .header, .group: reorderFolder(from: src, toRow: target)
        case .child:  reorderChild(from: src, toRow: target)
        case .agent, .service: return false   // sublist / server rows are not draggable
        }
        refreshItems()
        return true
    }

    private func sourceRow(from info: NSDraggingInfo) -> Int? {
        guard let s = info.draggingPasteboard.string(forType: reorderType),
              let r = Int(s), r >= 0, r < items.count else { return nil }
        return r
    }

    // A child may only drop within its own group; a header snaps to a folder boundary.
    private func constrainedDropRow(source src: Int, proposed: Int) -> Int {
        switch items[src] {
        case .child:
            let h = parentHeaderIndex(of: src)
            return min(max(proposed, h + 1), groupEnd(headerAt: h))
        case .header:
            return folderBoundaries().min(by: { abs($0 - proposed) < abs($1 - proposed) }) ?? proposed
        case .group(let id, _, _, _, _):
            // A whole group lands only between top-level blocks — never inside another
            // group, nor inside its own span.
            let b = folderBoundaries().filter { $0 == items.count || rowGroup[$0] == nil || isGroupTitle($0) }
                .filter { $0 == items.count || rowGroup[$0] != id || isGroupTitle($0) }
            return b.min(by: { abs($0 - proposed) < abs($1 - proposed) }) ?? proposed
        case .agent, .service:
            return proposed   // unreachable — these rows never start a drag
        }
    }

    // Index of the header at/above `row`.
    private func parentHeaderIndex(of row: Int) -> Int {
        var i = row
        while i > 0 { if case .header = items[i] { return i }; i -= 1 }
        return 0
    }

    // First index past the group whose header is at `h` (next header, or items.count).
    private func groupEnd(headerAt h: Int) -> Int {
        var i = h + 1
        while i < items.count { if case .header = items[i] { break }; i += 1 }
        return i
    }

    // Table rows where a folder may start: every header, plus end-of-list.
    private func folderBoundaries() -> [Int] {
        var b = items.indices.filter { items[$0].isHeader }
        b.append(items.count)
        return b
    }

    private func reorderChild(from src: Int, toRow target: Int) {
        guard case .child(let moved) = items[src] else { return }
        let h = parentHeaderIndex(of: src)
        var ttys: [String] = []
        var to = 0
        var i = h + 1
        // Walk to the group's end collecting child ttys; agent nodes interleave with
        // their sessions when a sublist is expanded, so skip (don't stop at) them.
        // The drop row has to be counted the same way: table rows and child indices
        // drift apart by one per expanded agent node, so `to` counts the children
        // above the drop row rather than subtracting row numbers.
        while i < items.count, !items[i].isHeader {
            if case .child(let c) = items[i] {
                ttys.append(c.tty)
                if i < target { to += 1 }
            }
            i += 1
        }
        guard let from = ttys.firstIndex(of: moved.tty) else { return }
        ttys.remove(at: from)
        if from < to { to -= 1 }
        ttys.insert(moved.tty, at: min(max(to, 0), ttys.count))
        model.setChildOrder(ttys, for: moved.cwd)
    }

    // Move a project header or a whole group to the boundary above row `target`. A
    // project dropped between a group's members joins (or reorders within) that group;
    // dropped anywhere else it leaves its group (T387).
    private func reorderFolder(from src: Int, toRow target: Int) {
        let flat = projectOrder()
        let moving: [String]
        switch subject(src) {
        case .project(let cwd):
            if target < items.count, let g = rowGroup[target], !isGroupTitle(target),
               case .header(_, let k, _, _) = items[target], let before = k.projectCwd {
                if before == cwd { return }
                model.insert(cwd, intoGroup: g, before: before)
                model.setFolderOrder(model.rebuildOrder(flat: flat, moved: [cwd]))
                return
            }
            model.removeFromGroup(cwd)
            moving = [cwd]
        case .group(let id):
            moving = model.liveMembers(id)
        case nil:
            return
        }
        // Projects above the drop line, not counting the ones being moved.
        let above = Set(projectOrder(upTo: target))
        var keys = flat.filter { !moving.contains($0) }
        let to = keys.filter(above.contains).count
        keys.insert(contentsOf: moving, at: min(to, keys.count))
        model.setFolderOrder(keys)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        // 42, not 46: the header band's content is centred in the slice, so the
        // slice's height IS the gap between the project name and the hairline under
        // it. At 46 that gap read wider than the one between the hairline and the
        // first session row's title below it (7pt) — the group looked detached from
        // its own rows. 42 puts both at ~8.
        // The first header has no 8pt top gap of its own (HeaderCell.topGap) — the
        // host supplies it outside the scroll view — so its row is 8 shorter.
        case .header: return row == 0 ? Self.firstHeaderHeight : Self.headerHeight
        case .child:  return 54
        case .agent:  return Theme.agentRowHeight
        case .service: return ServiceCell.rowHeight
        case .group(_, _, _, let collapsed, _): return GroupTitleCell.height(collapsed: collapsed, isFirst: row == 0)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: NSView
        switch items[row] {
        case .header:
            let id = NSUserInterfaceItemIdentifier("header")
            cell = (tableView.makeView(withIdentifier: id, owner: self) as? HeaderCell) ?? HeaderCell(id: id)
        case .child:
            let id = NSUserInterfaceItemIdentifier("child")
            cell = (tableView.makeView(withIdentifier: id, owner: self) as? ChildCell) ?? ChildCell(id: id)
        case .agent:
            let id = NSUserInterfaceItemIdentifier("agent")
            cell = (tableView.makeView(withIdentifier: id, owner: self) as? AgentCell) ?? AgentCell(id: id)
        case .service:
            let id = NSUserInterfaceItemIdentifier("service")
            cell = (tableView.makeView(withIdentifier: id, owner: self) as? ServiceCell) ?? ServiceCell(id: id)
        case .group:
            let id = NSUserInterfaceItemIdentifier("group")
            cell = (tableView.makeView(withIdentifier: id, owner: self) as? GroupTitleCell) ?? GroupTitleCell(id: id)
        }
        configureCell(cell, row: row)
        return cell
    }

    @discardableResult
    private func configureCell(_ view: NSView, row: Int) -> Bool {
        switch items[row] {
        case .header(let folder, let kind, let counts, let collapsed):
            guard let cell = view as? HeaderCell else { return false }
            let source = kind.projectCwd.map { model.source(forCwd: $0) } ?? .vscode
            let pinned = kind.projectCwd.map { model.isPinned($0) } ?? false
            cell.configure(folder: folder, counts: counts, collapsed: collapsed, kind: kind, source: source, pinned: pinned,
                           isFirst: row == 0)
            cell.setMergeState(mergeState(forRow: row))
        case .group(_, let name, let counts, let collapsed, let members):
            guard let cell = view as? GroupTitleCell else { return false }
            cell.configure(name: name, counts: counts, collapsed: collapsed, members: members, isFirst: row == 0)
            cell.setMergeState(mergeState(forRow: row))
        case .child(let r):
            guard let cell = view as? ChildCell else { return false }
            // First child = the row above is a header (rounds nothing extra, skips the
            // between-rows line); last child = the row below is a header or end-of-list
            // (rounds the enclosure's bottom — an expanded agent sublist below extends
            // the enclosure instead, so its presence keeps this row un-rounded).
            let isFirst = row == 0 || rowIsHeader(row - 1)
            let isLast = row == items.count - 1 || rowIsHeader(row + 1)
            cell.configure(r, isFirst: isFirst, isLast: isLast,
                           agentExpanded: model.isAgentExpanded(r.tty))
        case .agent(let a, let parent):
            guard let cell = view as? AgentCell else { return false }
            // First node = the row above is the session row this sublist hangs under —
            // the boundary where the card's agent segment starts, so it draws the seam.
            let isFirstNode = row == 0 || !items[row - 1].isAgent
            let isLastNode = row == items.count - 1 || !items[row + 1].isAgent
            let isLastRow = row == items.count - 1 || rowIsHeader(row + 1)
            cell.configure(a, parentStatus: parent.status, parentModel: parent.model,
                           isFirstNode: isFirstNode, isLastNode: isLastNode, isLastRow: isLastRow)
        case .service(let s, _):
            guard let cell = view as? ServiceCell else { return false }
            cell.configure(s, isLastRow: row == items.count - 1 || rowIsHeader(row + 1))
        }
        return true
    }

    // ★ T318: reloadData detaches every visible cell from the window and re-attaches
    // it, and on macOS 26 each control re-entering a window registers an
    // NSKeyValueDependency that is never freed (measured ~35/s steady state — the ⏱
    // text alone changes the render key every second). When the row shapes are
    // unchanged (same count, same kind per row → same heights and cell classes),
    // reconfigure the cells already on screen instead. Rows scrolled off-screen have
    // no view and get configured by viewFor when they come back.
    private func reloadRows(replacing old: [DisplayItem]) {
        let sameShape = old.count == items.count && zip(old, items).allSatisfy { a, b in
            switch (a, b) {
            case (.header, .header), (.child, .child), (.agent, .agent), (.service, .service): return true
            // Same height too: a collapse flip changes the title row's height.
            case (.group(_, _, _, let a, _), .group(_, _, _, let b, _)): return a == b
            default: return false
            }
        }
        if sameShape {
            // Every row view the table holds, not just the visible rect — it keeps a few
            // prepared rows past the edges, and those would scroll in stale.
            var inPlace = true
            tableView.enumerateAvailableRowViews { rowView, row in
                guard inPlace, row < items.count, let v = rowView.view(atColumn: 0) as? NSView else { return }
                inPlace = configureCell(v, row: row)
                applyRail(rowView, row: row)
            }
            if inPlace { return }
        }
        tableView.reloadData()
    }

    // No row-level selection background — the card owns its visuals.
    // Recycled, not built per call: a fresh row view per row per reload is another
    // view inserted into the window each time (T318).
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("transparentRow")
        if let v = tableView.makeView(withIdentifier: id, owner: self) as? TransparentRowView { return v }
        let v = TransparentRowView()
        v.identifier = id
        return v
    }

    // Single click: jump to VSCode only. Status is NOT changed by the click — a row
    // greys to "闲置" solely on ground truth (the extension reporting focus, or the
    // hook clearing needs). A header click splits by where it lands: only the
    // disclosure chevron toggles collapse; anywhere else jumps into the folder's
    // most urgent session — 需确认 first, then 完成, else the first session.
    @objc private func rowClicked() {
        let r = tableView.clickedRow
        guard r >= 0 && r < items.count else { return }
        switch items[r] {
        case .child(let row):
            // A click on the 🤖 badge toggles the agent sublist instead of jumping —
            // hit-tested here because ChildCell claims every click for itself (its
            // hitTest returns the cell), same pattern as the header chevron. Gated on
            // the BADGE being visible (bgAgents), not on the roster being parseable:
            // with an older hook the count can come from the bg-<tty> fallback with no
            // roster behind it, and a visible badge that silently jumps instead of
            // toggling is the worst of both.
            if row.bgAgents > 0,
               let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? ChildCell,
               cell.agentBadgeHit(tableView.lastClickInWindow) {
                onLearned?("agents")
                model.toggleAgentExpanded(row.tty)
                refreshItems()
                onLayoutChange?()
            } else {
                fireJump(row)
            }
        case .agent(_, let parent):
            // An agent node jumps to its parent session — the terminal where the
            // wake-up will land.
            fireJump(parent)
        case .service:
            break   // its own buttons act; the row body has nowhere to jump
        case .group(let id, _, _, _, _):
            // A group has no window of its own to jump to — the whole row folds it.
            toggleCollapse(ListModel.groupKey(id))
        case .header(_, let kind, _, _):
            let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? HeaderCell
            var onChevron = false
            if let cell { onChevron = cell.chevronHit(tableView.lastClickInWindow) }
            switch kind {
            case .project(let cwd):
                // Chevron → collapse; anywhere else → jump into the folder's window.
                if onChevron { toggleCollapse(kind.collapseKey) } else { jumpToPriority(cwd) }
            }
        }
    }

    // Every jump funnels through here so "the user knows rows are clickable" is recorded
    // once, no matter which of the five entry points (row, agent node, header, pinned
    // hotkey, sessionless project) got them there.
    private func fireJump(_ row: SessionRow) {
        onLearned?("jump")
        onJump?(row)
    }

    // Pick the folder's most urgent session and jump to it: needs > done > first.
    private func jumpToPriority(_ cwd: String) {
        let g = model.orderedSessions(cwd)
        guard let pick = g.first(where: { $0.status == "needs" })
            ?? g.first(where: { $0.status == "done" })
            ?? g.first else {
            // A sessionless project (open editor window, nothing running) has no session
            // to reveal — jump to the window itself. focus() already degrades correctly
            // on shellPid 0: it skips the terminal-pane reveal and just raises the
            // window, exactly the "take me to that window" the click asks for.
            //
            // ★ `editor` MUST be set (改这里前必读): focus() bails outright on a row with
            // no editor — that's its refusal to guess at an unsupported host — so leaving
            // it nil made this click silently do nothing. The model knows which editor
            // owns the window; .vscode is only the fallback for a project that stopped
            // being sessionless between the render and the click.
            var row = SessionRow(title: (cwd as NSString).lastPathComponent,
                                 folder: (cwd as NSString).lastPathComponent,
                                 cwd: cwd, shellPid: 0, tty: "", status: "idle",
                                 taskTitle: "", seq: 0)
            row.editor = model.emptyProjectEditor(cwd) ?? .vscode
            fireJump(row)
            return
        }
        fireJump(pick)
    }

    private func toggleCollapse(_ key: String) {
        model.toggleCollapse(key)
        refreshItems()
    }

    // MARK: Right-click context menu (hide project)
    //
    // Only folder headers get a menu — hiding is per-project (cwd), so a right-click
    // on a header reads as "hide this whole project". Child rows return nil (a
    // per-terminal temporary hide is a v2 concern; there's no stable per-terminal id).
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        if case .group(let id, let name, _, _, _) = items[row] { return groupMenu(id: id, name: name) }
        if case .child(let r) = items[row] { return sessionMenu(r) }
        // Only project headers get a menu; a status bucket isn't a project.
        guard case .header(let folder, let kind, _, _) = items[row],
              let cwd = kind.projectCwd else { return nil }

        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HeaderCell
        onLearned?("headerMenu")
        let menu = NSMenu()
        let display = AppController.isDesktopCwd(cwd) && AppSettings.customName(cwd: cwd) == nil ? cwd : folder
        let rename = NSMenuItem(title: L("重命名…", "Rename…"), action: #selector(renameClicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = ["cwd": cwd, "folder": folder]
        menu.addItem(rename)
        if let cell { menu.addItem(iconMenu.item(cwd: cwd, anchor: cell.iconAnchor)) }
        if GitBranch.current(cwd: cwd) != nil {
            let branch = NSMenuItem(title: L("显示当前分支", "Show Current Branch"),
                                    action: #selector(branchClicked(_:)), keyEquivalent: "")
            branch.target = self
            branch.state = AppSettings.showsBranch(cwd: cwd) ? .on : .off
            branch.representedObject = ["cwd": cwd]
            menu.addItem(branch)
        }
        menu.addItem(.separator())
        // Pin-to-top: pinned folders float to the top of the list.
        let pinned = model.isPinned(cwd)
        let pinTitle = pinned ? L("取消置顶", "Unpin") : L("置顶「\(display)」", "Pin \"\(display)\"")
        let pin = NSMenuItem(title: pinTitle, action: #selector(pinClicked(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = ["cwd": cwd]
        menu.addItem(pin)
        if rowGroup[row] != nil, case .group(_, let gname, _, _, _)? = groupTitle(above: row) {
            let leave = NSMenuItem(title: L("移出「\(gname)」", "Remove from \"\(gname)\""),
                                   action: #selector(leaveGroupClicked(_:)), keyEquivalent: "")
            leave.target = self
            leave.representedObject = ["cwd": cwd]
            menu.addItem(leave)
        }
        let title = L("隐藏「\(display)」", "Hide \"\(display)\"")
        let item = NSMenuItem(title: title, action: #selector(hideClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["cwd": cwd, "folder": display]
        menu.addItem(item)
        return menu
    }

    private func sessionMenu(_ r: SessionRow) -> NSMenu? {
        guard TerminalCloser.canClose(r) else { return nil }
        let menu = NSMenu()
        let close = NSMenuItem(title: L("关闭终端…", "Close Terminal…"),
                               action: #selector(closeTerminalClicked(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = r.id
        menu.addItem(close)
        return menu
    }

    @objc private func closeTerminalClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let r = items.lazy.compactMap({ item -> SessionRow? in
                  if case .child(let r) = item, r.id == id { return r }
                  return nil
              }).first else { return }
        let alert = NSAlert()
        alert.messageText = L("关闭这个终端？", "Close this terminal?")
        let running = r.status == "working"
        alert.informativeText = r.display + "\n\n" + (running
            ? L("这个会话还在运行，关掉会中断它，无法撤销。", "This session is still running. Closing it stops the work and can't be undone.")
            : L("终端里的会话会一起结束，无法撤销。", "The session in it ends too. This can't be undone."))
        if running { alert.alertStyle = .warning }
        alert.addButton(withTitle: L("关闭", "Close"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        PopoverHold.begin()
        let ok = alert.runModal() == .alertFirstButtonReturn
        PopoverHold.end()
        guard ok else { return }
        TerminalCloser.close(r)
    }

    private func groupTitle(above row: Int) -> DisplayItem? {
        var i = row
        while i >= 0 { if isGroupTitle(i) { return items[i] }; i -= 1 }
        return nil
    }

    private func groupMenu(id: String, name: String) -> NSMenu {
        let menu = NSMenu()
        let rename = NSMenuItem(title: L("重命名组…", "Rename Group…"),
                                action: #selector(renameGroupClicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = ["id": id, "name": name]
        menu.addItem(rename)
        menu.addItem(.separator())
        let ungroup = NSMenuItem(title: L("解散组", "Ungroup"),
                                 action: #selector(ungroupClicked(_:)), keyEquivalent: "")
        ungroup.target = self
        ungroup.representedObject = ["id": id]
        menu.addItem(ungroup)
        return menu
    }

    @objc private func renameGroupClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let name = info["name"] else { return }
        let alert = NSAlert()
        alert.messageText = L("重命名组", "Rename group")
        alert.informativeText = L("留空恢复默认名。", "Leave empty for the default name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = model.group(id)?.name ?? ""
        field.placeholderString = name
        alert.accessoryView = field
        alert.addButton(withTitle: L("确定", "OK"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        PopoverHold.begin()
        let ok = alert.runModal() == .alertFirstButtonReturn
        PopoverHold.end()
        guard ok else { return }
        model.renameGroup(id, to: field.stringValue)
        refreshItems()
    }

    @objc private func ungroupClicked(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? [String: String])?["id"] else { return }
        model.dissolveGroup(id)
        refreshItems()
    }

    @objc private func leaveGroupClicked(_ sender: NSMenuItem) {
        guard let cwd = (sender.representedObject as? [String: String])?["cwd"] else { return }
        // Park it right below the group it leaves, so it doesn't jump elsewhere.
        let flat = projectOrder()
        let mates = model.group(containing: cwd)?.members ?? []
        model.removeFromGroup(cwd)
        var keys = flat.filter { $0 != cwd }
        let lastMate = keys.lastIndex { mates.contains($0) } ?? (keys.count - 1)
        keys.insert(cwd, at: min(lastMate + 1, keys.count))
        model.setFolderOrder(keys)
        refreshItems()
    }

    @objc private func branchClicked(_ sender: NSMenuItem) {
        guard let cwd = (sender.representedObject as? [String: String])?["cwd"] else { return }
        AppSettings.toggleBranch(cwd: cwd)
    }

    // Prompt for a new header title; an empty field restores the folder name.
    @objc private func renameClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cwd = info["cwd"], let folder = info["folder"] else { return }
        let alert = NSAlert()
        alert.messageText = L("重命名项目", "Rename project")
        alert.informativeText = L("留空恢复为文件夹名。", "Leave empty to use the folder name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let custom = AppSettings.customName(cwd: cwd)
        field.stringValue = custom ?? ""
        field.placeholderString = custom == nil ? folder : (cwd as NSString).lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: L("确定", "OK"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        PopoverHold.begin()
        let ok = alert.runModal() == .alertFirstButtonReturn
        PopoverHold.end()
        guard ok else { return }
        AppSettings.setCustomName(field.stringValue, cwd: cwd)
    }

    // Toggle the project's pin and re-derive the list in place — pinned folders jump to
    // the top (or fall back to their drag rank when unpinned). Order is persisted by the
    // model; onLayoutChange lets a content-sized host (popover) resize to the new layout.
    @objc private func pinClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cwd = info["cwd"] else { return }
        model.togglePin(cwd)
        refreshItems()
        onLayoutChange?()
    }

    // Fade the project's rows out, then hand the hide to the host (which persists it
    // and shows the undo bar). No host wired → hide directly. Either way AppSettings
    // posts didChange, so the controller re-scans and the faded rows are replaced.
    @objc private func hideClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cwd = info["cwd"], let folder = info["folder"] else { return }
        fadeOutRows(cwd: cwd) { [weak self] in
            guard let self else { return }
            if let onHide = self.onHide { onHide(cwd, folder) }
            else { AppSettings.hide(cwd: cwd) }
        }
    }

    // Alpha-fade the header + child rows belonging to `cwd` over ~0.2s so the group
    // dissolves instead of snapping out when the re-scan drops it.
    private func fadeOutRows(cwd: String, completion: @escaping () -> Void) {
        var rowViews: [NSTableRowView] = []
        for (i, it) in items.enumerated() {
            let match: Bool
            switch it {
            case .header(_, let k, _, _):  match = k.projectCwd == cwd
            case .child(let r):            match = r.cwd == cwd
            case .agent(_, let parent):    match = parent.cwd == cwd
            case .service(_, let c):       match = c == cwd
            case .group:                   match = false
            }
            if match, let rv = tableView.rowView(atRow: i, makeIfNecessary: false) { rowViews.append(rv) }
        }
        guard !rowViews.isEmpty else { completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            for rv in rowViews { rv.animator().alphaValue = 0 }
        }, completionHandler: completion)
    }
}

// MARK: - Below-the-fold status glow
//
// A long list scrolls its tail out of sight, and a project that turns 需确认 or 完成
// down there is invisible — precisely the two states that want you to act. This is
// the quietest possible signal for it: a 3pt bar plus its glow along the list's
// bottom edge, tinted by the most urgent hidden status. Deliberately wordless and
// countless (the chosen design of the five) — it reads in peripheral vision and
// never competes with the rows for attention.
final class OverflowEdgeGlow: NSView {
    enum Edge { case top, bottom }

    static let height: CGFloat = 26
    private static let barHeight: CGFloat = 3

    private let edge: Edge
    private let glow = CAGradientLayer()
    private let bar = CALayer()
    private var shown = false

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        // The bar sits on the list edge and the glow fades away from it, inward.
        // Layer coordinates are y-up here (the view isn't flipped).
        switch edge {
        case .bottom:
            glow.startPoint = CGPoint(x: 0.5, y: 0); glow.endPoint = CGPoint(x: 0.5, y: 1)
        case .top:
            glow.startPoint = CGPoint(x: 0.5, y: 1); glow.endPoint = CGPoint(x: 0.5, y: 0)
        }
        layer?.addSublayer(glow)
        layer?.addSublayer(bar)
        breathe(glow); breathe(bar)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Decoration, not a control: clicks belong to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        let barY = edge == .bottom ? 0 : bounds.height - Self.barHeight
        bar.frame = NSRect(x: 0, y: barY, width: bounds.width, height: Self.barHeight)
        CATransaction.commit()
    }

    // nil = nothing actionable below the fold → fade out.
    func update(status: String?) {
        if let st = status {
            // Read Status.accent every time: a theme switch or a user color override
            // must recolor the glow along with everything else it feeds.
            let c = Status.accent(st)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bar.backgroundColor = c.cgColor
            glow.colors = [c.withAlphaComponent(0.34).cgColor, c.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
        let want = status != nil
        guard want != shown else { return }
        shown = want
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = want ? 1 : 0
        }
    }

    // A perpetual loop, so both rules in docs/design-system.md apply: the phase is
    // epoch-anchored, and the MODEL value parks at the dim end so any frame drawn
    // between a detach and the re-add shows the trough, never a bright spike.
    private func breathe(_ l: CALayer) {
        l.opacity = 0.45
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.45
        a.toValue = 1.0
        a.duration = 1.3
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.beginTime = Motion.epoch
        l.add(a, forKey: "breathe")
    }
}

// A scroller that always behaves as an overlay (floating) scroller, regardless of
// the system "Show scroll bars" preference. A legacy scroller reserves a fixed
// gutter on the trailing edge, which would push the list cards inward; overlay
// scrollers float over the content and reserve nothing.
// NSScrollView reserves the legacy right gutter based on ITS OWN scrollerStyle,
// which AppKit snaps back to NSScroller.preferredScrollerStyle (= .legacy under
// "Always show scroll bars") after our one-shot assignment in setup. Pin it here
// so the gutter is never reserved and the table spans the full list width.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

final class OverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

// Kills the default blue selection fill so our glass cards stand alone.
final class TransparentRowView: NSTableRowView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-backed so the table can raise a hovered row's zPosition above its
        // neighbours — otherwise the lift shadow is clipped by the rows painted on top.
        wantsLayer = true
        // …and unclipped, or the card's shadow is cut off in a straight line at the
        // row's own edge instead of fading out (see NSView.letShadowsEscape).
        letShadowsEscape()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
    // A merge target shows its own ring (MergeRingView), not AppKit's blue drop box.
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}

    // The project-group rail segment (see setGroupRail in ProjectGroupViews.swift).
    lazy var railLayer: CALayer = {
        let l = CALayer()
        l.isHidden = true
        layer?.addSublayer(l)
        return l
    }()
    var railState: (GroupRail, CGFloat) = (.none, 0)

    override func layout() {
        super.layout()
        if railState.0 != .none { setGroupRail(railState.0, topInset: railState.1) }
    }
}
