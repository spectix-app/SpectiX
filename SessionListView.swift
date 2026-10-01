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
    private var items: [DisplayItem] = []
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
            }
        }
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
        items = newItems
        // Header-only groups (open VSCode windows with no session) count as content —
        // gate on the rendered items, not on `rows`, or the "no sessions" placeholder
        // would sit on top of them.
        emptyLabel.isHidden = !newItems.isEmpty
        tableView.reloadData()
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
            case .header(_, _, let counts, _):
                let live = counts.filter { $0.1 > 0 }.map { $0.0 }
                st = live.contains("needs") ? "needs" : (live.contains("done") ? "done" : nil)
            case .child(let r):
                let b = Status.bucket(r.status)
                st = (b == "needs" || b == "done") ? b : nil
            case .agent:
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
                return "H¦\(folder)¦\(kind.collapseKey)¦\(collapsed)¦\(c)¦\(source)¦\(pinned)"
            case .child(let r):
                let isFirst = i == 0 || items[i - 1].isHeader
                let isLast = i == items.count - 1 || items[i + 1].isHeader
                let fields: [String] = [
                    "C", r.status, r.taskTitle, String(r.seq), String(r.isDesktop), r.step,
                    String(r.bgAgents), String(r.bgShells),
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
            case .child, .agent:          return nil
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
    // into its most urgent session, status bucket → toggle collapse). Returns false when
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
            case .status:           toggleCollapse(kind.collapseKey)
            }
            return true
        }
        guard pinnedShellPid > 0,
              let r = model.rows.first(where: { $0.shellPid == pinnedShellPid }) else { return false }
        fireJump(r)
        return true
    }

    // MARK: Drag-to-reorder (collapse-all while a header drags)

    func rowIsHeader(_ row: Int) -> Bool {
        guard row >= 0, row < items.count else { return false }
        if case .header = items[row] { return true }
        return false
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
        guard originalRow >= 0, originalRow < items.count,
              case .header(_, let kind, _, _) = items[originalRow],
              let cwd = kind.projectCwd else { return nil }
        model.beginDragCollapseAll()
        refreshItems()
        // The dragged folder's new row index in the now all-collapsed list.
        return items.firstIndex { if case .header(_, let k, _, _) = $0 { return k.projectCwd == cwd }; return false }
    }

    func endHeaderDrag() {
        model.endDragCollapse()
        refreshItems()
    }

    // MARK: Drag-to-reorder (drop side)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let src = sourceRow(from: info) else { return [] }
        // Retarget an onto-row drop to an insertion so the whole row height is a valid
        // drop target, not just the thin gaps between rows.
        tableView.setDropRow(constrainedDropRow(source: src, proposed: row), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let src = sourceRow(from: info) else { return false }
        let target = constrainedDropRow(source: src, proposed: row)
        switch items[src] {
        case .header: reorderFolder(from: src, toRow: target)
        case .child:  reorderChild(from: src, toRow: target)
        case .agent:  return false   // agent nodes are not draggable
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
        case .agent:
            return proposed   // unreachable — agent rows never start a drag
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
        var b = items.indices.filter { if case .header = items[$0] { return true }; return false }
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

    private func reorderFolder(from src: Int, toRow target: Int) {
        guard case .header(_, let kind, _, _) = items[src], let cwd = kind.projectCwd else { return }
        var keys: [String] = items.compactMap { if case .header(_, let k, _, _) = $0 { return k.projectCwd }; return nil }
        guard let from = keys.firstIndex(of: cwd) else { return }
        var to = items[0..<min(target, items.count)].reduce(0) { n, it in
            if case .header = it { return n + 1 }; return n
        }
        keys.remove(at: from)
        if from < to { to -= 1 }
        keys.insert(cwd, at: min(max(to, 0), keys.count))
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
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let folder, let kind, let counts, let collapsed):
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HeaderCell) ?? HeaderCell(id: id)
            // Status buckets have no project cwd → no source badge (the cell uses the
            // bucket's .status tile); project headers get their group's derived source.
            let source = kind.projectCwd.map { model.source(forCwd: $0) } ?? .vscode
            let pinned = kind.projectCwd.map { model.isPinned($0) } ?? false
            cell.configure(folder: folder, counts: counts, collapsed: collapsed, kind: kind, source: source, pinned: pinned,
                           isFirst: row == 0)
            return cell
        case .child(let r):
            let id = NSUserInterfaceItemIdentifier("child")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ChildCell) ?? ChildCell(id: id)
            // First child = the row above is a header (rounds nothing extra, skips the
            // between-rows line); last child = the row below is a header or end-of-list
            // (rounds the enclosure's bottom — an expanded agent sublist below extends
            // the enclosure instead, so its presence keeps this row un-rounded).
            let isFirst = row == 0 || rowIsHeader(row - 1)
            let isLast = row == items.count - 1 || rowIsHeader(row + 1)
            cell.configure(r, isFirst: isFirst, isLast: isLast,
                           agentExpanded: model.isAgentExpanded(r.tty))
            return cell
        case .agent(let a, let parent):
            let id = NSUserInterfaceItemIdentifier("agent")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AgentCell) ?? AgentCell(id: id)
            // First node = the row above is the session row this sublist hangs under —
            // the boundary where the card's agent segment starts, so it draws the seam.
            let isFirstNode = row == 0 || !items[row - 1].isAgent
            let isLastNode = row == items.count - 1 || !items[row + 1].isAgent
            let isLastRow = row == items.count - 1 || rowIsHeader(row + 1)
            cell.configure(a, parentStatus: parent.status, parentModel: parent.model,
                           isFirstNode: isFirstNode, isLastNode: isLastNode, isLastRow: isLastRow)
            return cell
        }
    }

    // No row-level selection background — the card owns its visuals.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TransparentRowView()
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
        case .header(_, let kind, _, _):
            let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? HeaderCell
            var onChevron = false
            if let cell { onChevron = cell.chevronHit(tableView.lastClickInWindow) }
            switch kind {
            case .project(let cwd):
                // Chevron → collapse; anywhere else → jump into the folder's window.
                if onChevron { toggleCollapse(kind.collapseKey) } else { jumpToPriority(cwd) }
            case .status:
                // A status bucket spans many windows — nothing to raise, so the whole
                // header toggles collapse.
                toggleCollapse(kind.collapseKey)
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
        // Only project headers get a menu; a status bucket isn't a project.
        guard row >= 0, row < items.count,
              case .header(let folder, let kind, _, _) = items[row],
              let cwd = kind.projectCwd else { return nil }

        // Right-click ON the leading badge → the icon-editing menu (Notion-style);
        // anywhere else on the header → the hide-project menu.
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HeaderCell
        if let cell, let loc = NSApp.currentEvent?.locationInWindow, cell.badgeHit(loc) {
            return iconMenu.menu(cwd: cwd, anchor: cell.iconAnchor)
        }

        onLearned?("headerMenu")
        let menu = NSMenu()
        let display = AppController.isDesktopCwd(cwd) ? cwd : folder
        // Pin-to-top: only in custom mode (status mode headers are buckets, not projects,
        // and its order is fixed by urgency). Pinned folders float to the top of the list.
        if AppSettings.sortMode == .custom {
            let pinned = model.isPinned(cwd)
            let pinTitle = pinned ? L("取消置顶", "Unpin") : L("置顶「\(display)」", "Pin \"\(display)\"")
            let pin = NSMenuItem(title: pinTitle, action: #selector(pinClicked(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = ["cwd": cwd]
            menu.addItem(pin)
        }
        let title = L("隐藏「\(display)」", "Hide \"\(display)\"")
        let item = NSMenuItem(title: title, action: #selector(hideClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["cwd": cwd, "folder": display]
        menu.addItem(item)
        return menu
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
}
