import Cocoa

// MARK: - Grouped project list (shared by the main window and the menu dropdown)
//
// One visual line in the list. Every folder (= VSCode window) renders the same
// way regardless of session count: a header (folder name + aggregate count
// badges) followed by one indented child per terminal. A lone session is just a
// header with a single child — keeps the layout uniform.
// What a header groups by. Project headers are keyed by cwd (a VSCode window / the
// desktop app) and support raise-on-click, hide, and drag-reorder. Status headers
// are keyed by a status bucket and are collapse-only (a bucket spans many windows,
// so there's no single window to raise or project to hide).
enum HeaderKind: Equatable {
    case project(cwd: String)
    case status(String)         // bucket key: "needs" / "done" / "working" / "idle"

    // Stable key for the collapse set (cwds and buckets never collide — buckets
    // carry a "status:" prefix).
    var collapseKey: String {
        switch self {
        case .project(let cwd): return cwd
        case .status(let s):    return "status:" + s
        }
    }
    // The project cwd when this is a project header; nil for status buckets.
    var projectCwd: String? {
        if case .project(let c) = self { return c }
        return nil
    }
}

enum DisplayItem {
    case header(folder: String, kind: HeaderKind, counts: [(String, Int)], collapsed: Bool)
    case child(SessionRow)                                        // session under a header
    case agent(AgentInfo, parent: SessionRow)                     // expanded sublist node under a child

    var isHeader: Bool { if case .header = self { return true }; return false }
    var isAgent: Bool { if case .agent = self { return true }; return false }
}

// Which app a project header's badge represents. Derived from the group's sessions,
// not stored on the item: desktop group → .desktop; a group with any VSCode session
// (terminalApp == nil) → .vscode (mixed VSCode+terminal in one cwd prefers VS, per
// the decided spec); an all-native-terminal group → .terminal.
enum HeaderSource { case vscode, cursor, windsurf, terminal, desktop }

// The grouping / ordering / collapse state, owned once by AppController and shared
// by both surfaces (main window + menu). Collapsing a folder or reordering it in
// one place is therefore reflected in the other. The custom order is persisted to
// UserDefaults so a drag-reorder survives app restart; the collapse set is in-memory
// only (rides reloads, resets on restart).
//
// Custom mode (default): group by project (cwd). Base order is FIXED — folders
// alphabetical by cwd, children by session number — so nothing floats on a status
// change (status only recolors). A drag-reorder layers a custom rank on top:
// reordered folders/children sort by their saved rank; everything else keeps the
// base order, slotted after the ranked items.
// Status mode (AppSettings.sortMode): group by status bucket instead of by project
// — 需确认 → 完成 → 运行中 → 闲置. Sessions from different projects mix under one
// bucket (each child surfaces its project name). Empty buckets are omitted; drag-
// reorder is disabled (MainWindow gates dragging to .custom).
final class ListModel {
    private(set) var rows: [SessionRow] = []
    // Projects whose VSCode window is open but which have no live session (see
    // AppController.openProjectsWithoutSessions). They render as header-only groups.
    // Set separately from update(_:) because the view layer re-pushes rows on every
    // reload and has no business knowing about this second source.
    // Each entry carries its editor because there's no session row to read one off —
    // the header badge and the click-to-jump both need to know which app owns the window.
    private(set) var emptyProjects: [(cwd: String, editor: EditorApp)] = []
    private var collapsed: Set<String> = []            // active cwds/buckets the user manually hid
    // A project whose sessions are ALL idle collapses by default (no action needed on
    // an idle folder). idleExpanded holds the all-idle projects the user explicitly
    // clicked open; it's reset per-folder the moment the folder goes active again, so a
    // folder that later returns to all-idle re-collapses. Kept separate from `collapsed`
    // so the two intents (hide-an-active-folder vs open-an-idle-folder) don't collide.
    private var idleExpanded: Set<String> = []
    // Delayed default-collapse: a project that transitions active→idle stays expanded
    // for `idleCollapseDelay` before it auto-collapses, giving you a beat to glance at the
    // just-finished sessions. idleSince[cwd] marks when the project became all-idle;
    // wasActive remembers cwds seen non-idle this session so a project idle from first
    // sight (app launch) collapses immediately instead of flashing open for a minute.
    private var idleSince: [String: Date] = [:]
    private var wasActive: Set<String> = []
    private static let idleCollapseDelay: TimeInterval = 60
    // Custom order, persisted (didSet → save). folderOrder is keyed by cwd (stable
    // across restarts); childOrder by tty (a terminal reopens with a new tty, so a
    // stale rank is simply ignored by `ranked`, not harmful).
    private var folderOrder: [String] = [] { didSet { save() } }
    private var childOrder: [String: [String]] = [:] { didSet { save() } }
    // Sessions whose agent sublist is expanded (clicked the 🤖 badge), keyed by tty.
    // In-memory like the collapse set — rides reloads, resets on restart. A stale
    // entry (agents all pruned / session gone) simply emits nothing.
    private var agentExpanded: Set<String> = []
    // Pinned project cwds, in pin order. A pinned folder floats to the very top of
    // the custom-mode list (ahead of the drag rank) and stays fixed there regardless
    // of status/activity. Keyed by cwd like folderOrder, so it survives restart and a
    // stale entry (project closed) is simply inert until the project reappears.
    private var pinnedFolders: [String] = [] { didSet { save() } }

    private static let folderOrderKey = "listFolderOrder"
    private static let childOrderKey = "listChildOrder"
    private static let pinnedFoldersKey = "listPinnedFolders"

    init() {
        let d = UserDefaults.standard
        // Assigning in an initializer does not fire didSet — no need to re-save what we just read.
        folderOrder = (d.array(forKey: Self.folderOrderKey) as? [String]) ?? []
        childOrder = (d.dictionary(forKey: Self.childOrderKey) as? [String: [String]]) ?? [:]
        pinnedFolders = (d.array(forKey: Self.pinnedFoldersKey) as? [String]) ?? []
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(folderOrder, forKey: Self.folderOrderKey)
        d.set(childOrder, forKey: Self.childOrderKey)
        d.set(pinnedFolders, forKey: Self.pinnedFoldersKey)
    }

    func update(_ newRows: [SessionRow]) {
        rows = newRows
        // Drop the "user opened this idle folder" flag once the folder is no longer
        // all-idle, so it re-collapses by default the next time it goes fully idle.
        idleExpanded = idleExpanded.filter { allIdle($0) }
        // Maintain the delayed-collapse clocks. A project going all-idle starts its clock
        // now — but only if it was active before (a real active→idle transition); one idle
        // from first sight collapses immediately (distantPast). A project that's active
        // again drops its clock so the next all-idle transition re-times ("重新计算时间").
        let cwds = Set(rows.map { $0.cwd })
        for cwd in cwds {
            if allIdle(cwd) {
                if idleSince[cwd] == nil {
                    idleSince[cwd] = wasActive.contains(cwd) ? Date() : .distantPast
                }
            } else {
                wasActive.insert(cwd)
                idleSince[cwd] = nil
            }
        }
        // Forget vanished projects so the maps don't grow unbounded.
        idleSince = idleSince.filter { cwds.contains($0.key) }
        wasActive = wasActive.intersection(cwds)
    }

    func setEmptyProjects(_ projects: [(cwd: String, editor: EditorApp)]) { emptyProjects = projects }

    // The editor owning a sessionless project's window; nil once the project has sessions
    // (its rows carry the editor themselves) or the window closed.
    func emptyProjectEditor(_ cwd: String) -> EditorApp? {
        emptyProjects.first { $0.cwd == cwd }?.editor
    }

    // MARK: Grouping

    /// Display names for a set of project paths at once: the leaf folder on its
    /// own, or — when two paths share a leaf — "<nearest ancestor that differs> / <leaf>".
    /// A monorepo checked out twice through git worktrees puts the same
    /// `apps/<name>` under two roots, so both group headers (and both rows in the
    /// recent-projects list) would otherwise render as the same word. Shared by
    /// the session list headers and RecentProjectsWindow so a project reads the
    /// same in both places.
    static func folderNames(_ paths: [String]) -> [String: String] {
        var byLeaf: [String: [String]] = [:]
        for p in paths { byLeaf[(p as NSString).lastPathComponent, default: []].append(p) }

        var out: [String: String] = [:]
        for (leaf, group) in byLeaf {
            guard group.count > 1 else { out[group[0]] = leaf; continue }
            let segs = group.map { $0.components(separatedBy: "/").filter { !$0.isEmpty } }
            var resolved = false
            // depth 1 is the leaf's parent. Walk up until one level separates the
            // whole group — the shallowest prefix that disambiguates is also the
            // shortest one to read.
            for depth in 1..<max(segs.map(\.count).max() ?? 1, 2) {
                let ancestors = segs.map { $0.count > depth ? $0[$0.count - 1 - depth] : "" }
                // An empty segment means that path bottomed out at the root — no
                // ancestor to name, so let it fall through to the full-path form
                // rather than render a leading " / ".
                guard !ancestors.contains(where: \.isEmpty),
                      Set(ancestors).count == group.count else { continue }
                for (i, p) in group.enumerated() { out[p] = "\(ancestors[i]) / \(leaf)" }
                resolved = true
                break
            }
            // No single level splits them (three checkouts, two sharing a parent).
            // The full path always does.
            if !resolved {
                for p in group { out[p] = (p as NSString).abbreviatingWithTildeInPath }
            }
        }
        return out
    }

    func items() -> [DisplayItem] {
        switch AppSettings.sortMode {
        case .custom: return projectItems()
        case .status: return statusItems()
        }
    }

    // Group by VSCode window (cwd): folders alphabetical with the user's drag rank
    // layered on top, children by session number (or custom child order).
    private func projectItems() -> [DisplayItem] {
        var groups: [String: [SessionRow]] = [:]
        for r in rows { groups[r.cwd, default: []].append(r) }
        // An open VSCode window with no session becomes an empty group — same cwd key as
        // the real group it turns into once a session starts, so the header keeps its
        // icon, rank and position across that transition instead of jumping.
        for p in emptyProjects where groups[p.cwd] == nil { groups[p.cwd] = [] }

        let keys = groups.keys.sorted(by: folderSortsBefore)
        let names = Self.folderNames(keys)
        var out: [DisplayItem] = []
        for key in keys {
            let g = sortedSessions(groups[key]!, cwd: key)
            let folder = names[key] ?? (key as NSString).lastPathComponent
            // A sessionless group has nothing to expand, so it's permanently collapsed and
            // reports a single zero bucket — HeaderCell reads that shape as "empty" and
            // renders the dimmed grey ●0 header.
            let isCollapsed = g.isEmpty ? true : isCollapsed(key)
            out.append(.header(folder: folder, kind: .project(cwd: key),
                               counts: g.isEmpty ? [("idle", 0)] : Self.counts(g),
                               collapsed: isCollapsed))
            if !isCollapsed { for s in g { out.append(.child(s)); appendAgents(s, to: &out) } }
        }
        return out
    }

    // The expanded agent sublist right under its session row — one .agent node per
    // roster entry. Emitted only while that row is expanded AND has agents, so a
    // stale expansion flag (agents pruned, session recycled) renders nothing.
    private func appendAgents(_ s: SessionRow, to out: inout [DisplayItem]) {
        guard agentExpanded.contains(s.tty), !s.agents.isEmpty else { return }
        for a in s.agents { out.append(.agent(a, parent: s)) }
    }

    func isAgentExpanded(_ tty: String) -> Bool { agentExpanded.contains(tty) }

    func toggleAgentExpanded(_ tty: String) {
        if agentExpanded.contains(tty) { agentExpanded.remove(tty) }
        else { agentExpanded.insert(tty) }
    }

    // Group by status bucket: 需确认 → 完成 → 运行中 → 闲置. Empty buckets are omitted;
    // within a bucket, sessions sort by project then session number.
    private func statusItems() -> [DisplayItem] {
        var groups: [String: [SessionRow]] = [:]
        for r in rows { groups[Self.bucket(r.status), default: []].append(r) }

        var out: [DisplayItem] = []
        for key in AppSettings.statusDisplayOrder {
            guard let g0 = groups[key], !g0.isEmpty else { continue }
            let g = g0.sorted { a, b in
                a.cwd == b.cwd ? a.seq < b.seq : a.cwd < b.cwd
            }
            let isCollapsed = collapsed.contains("status:" + key)
            out.append(.header(folder: Self.bucketLabel(key), kind: .status(key),
                               counts: [(key, g.count)], collapsed: isCollapsed))
            if !isCollapsed { for s in g { out.append(.child(s)); appendAgents(s, to: &out) } }
        }
        return out
    }

    // seen + idle collapse into the one gray "闲置" bucket; paused is its own bucket.
    private static func bucket(_ s: String) -> String {
        switch s { case "needs", "done", "paused", "await", "working": return s; default: return "idle" }
    }
    private static func bucketLabel(_ key: String) -> String {
        switch key {
        case "needs":   return L("确认", "Wait")
        case "done":    return L("完成", "Done")
        case "paused":  return L("暂停", "Held")
        case "await":   return L("等待", "Hold")
        case "working": return L("运行", "Busy")
        default:        return L("闲置", "Idle")
        }
    }

    // The folder's sessions in display order (custom child order, else by seq).
    func orderedSessions(_ cwd: String) -> [SessionRow] {
        sortedSessions(rows.filter { $0.cwd == cwd }, cwd: cwd)
    }

    private func sortedSessions(_ g: [SessionRow], cwd: String) -> [SessionRow] {
        if let ord = childOrder[cwd] {
            return g.sorted { a, b in ranked(a.tty, b.tty, in: ord) { _, _ in a.seq < b.seq } }
        }
        return g.sorted { $0.seq < $1.seq }
    }

    // Comparator that puts items present in `order` first (in that order), and
    // breaks ties among unranked items with `fallback`.
    private func ranked<T: Equatable>(_ a: T, _ b: T, in order: [T], fallback: (T, T) -> Bool) -> Bool {
        switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return fallback(a, b)
        }
    }

    // Aggregate badge counts for a folder header: colored buckets, nonzero only,
    // urgency order. Every row folds onto a palette bucket (checking->needs,
    // seen->idle) so the buckets always sum to the group's session count.
    private static func counts(_ g: [SessionRow]) -> [(String, Int)] {
        return AppSettings.statusDisplayOrder.compactMap { st in
            let n = g.filter { Status.bucket($0.status) == st }.count
            return n > 0 ? (st, n) : nil
        }
    }

    // The badge source for a project header, derived from that cwd's live sessions. A
    // sessionless group has no rows to derive from, so it reads the editor recorded with
    // the open window instead — a Cursor window with nothing running must not wear a
    // VS Code badge. nil group (cwd vanished mid-reload) → .vscode, the neutral default.
    func source(forCwd cwd: String) -> HeaderSource {
        let g = rows.filter { $0.cwd == cwd }
        if g.isEmpty, let editor = emptyProjectEditor(cwd) { return editor.headerSource }
        return Self.source(g)
    }

    private static func source(_ g: [SessionRow]) -> HeaderSource {
        if g.contains(where: { $0.isDesktop }) { return .desktop }
        // Mixed editor + native-terminal in one project prefers the editor badge; the
        // editor kind (VSCode / Cursor / Windsurf) comes from that first editor-hosted row.
        // ★ Test `editor != nil`, not `terminalApp == nil`: an unsupported host (Warp,
        // Ghostty, tmux…) is neither, and the old test swept it into the editor branch —
        // which is exactly the "treat every unknown host as VSCode" assumption this task
        // removes. Those rows fall through to the generic terminal badge instead.
        if let editor = g.first(where: { $0.editor != nil })?.editor { return editor.headerSource }
        return g.isEmpty ? .vscode : .terminal
    }

    // MARK: Collapse

    // A project cwd with sessions and every one of them idle/seen. Status buckets
    // (keyed "status:…") are never all-idle — they follow the manual `collapsed` set.
    private func allIdle(_ cwd: String) -> Bool {
        let g = rows.filter { $0.cwd == cwd }
        return !g.isEmpty && g.allSatisfy { $0.status == "idle" || $0.status == "seen" }
    }

    func isCollapsed(_ key: String) -> Bool {
        guard allIdle(key) else { return collapsed.contains(key) }
        if idleExpanded.contains(key) { return false }   // manually opened → stays open
        // Default-collapse only after the project has been all-idle for the delay window.
        guard let since = idleSince[key] else { return false }
        return Date().timeIntervalSince(since) >= Self.idleCollapseDelay
    }

    func toggleCollapse(_ key: String) {
        // Toggle relative to what's actually on screen (the all-idle default flips during
        // the delay window, so we can't assume "collapsed" is the default).
        let currentlyCollapsed = isCollapsed(key)
        if allIdle(key) {
            if currentlyCollapsed {
                idleExpanded.insert(key)              // open it, and keep it open past the delay
            } else {
                idleExpanded.remove(key)              // collapse it now, expiring the grace clock
                idleSince[key] = .distantPast
            }
        } else if collapsed.contains(key) {
            collapsed.remove(key)
        } else {
            collapsed.insert(key)
        }
    }

    // Expand the group holding `pid`'s session so its child row is visible (used when
    // the user focuses a terminal — the list reveals + highlights that session). The
    // collapse key follows the active grouping: custom → cwd, status → "status:"+bucket.
    // Returns true only if a collapsed group was actually opened, so the caller can skip
    // a needless re-layout when nothing moved.
    func expandGroup(containingShellPid pid: pid_t) -> Bool {
        guard let row = rows.first(where: { $0.shellPid == pid }) else { return false }
        switch AppSettings.sortMode {
        case .custom:
            let key = row.cwd
            guard isCollapsed(key) else { return false }
            if allIdle(key) { idleExpanded.insert(key) } else { collapsed.remove(key) }
            return true
        case .status:
            let key = "status:" + Self.bucket(row.status)
            guard collapsed.contains(key) else { return false }
            collapsed.remove(key)
            return true
        }
    }

    // While a header drag is in flight, collapse every folder so the user reorders a
    // clean list of folder rows; the prior per-folder state is stashed and restored
    // verbatim when the drag ends (drop or cancel).
    private var collapseBackup: Set<String>?

    func beginDragCollapseAll() {
        guard collapseBackup == nil else { return }
        collapseBackup = collapsed
        collapsed = Set(orderedFolders())
    }

    func endDragCollapse() {
        if let backup = collapseBackup { collapsed = backup; collapseBackup = nil }
    }

    // MARK: Ordering

    // Full ordered list of folder cwds (base order + custom rank on top).
    func orderedFolders() -> [String] {
        var keys = Set<String>()
        for r in rows { keys.insert(r.cwd) }
        for p in emptyProjects { keys.insert(p.cwd) }   // empty groups reorder like any other
        return keys.sorted(by: folderSortsBefore)
    }

    func setFolderOrder(_ keys: [String]) { folderOrder = keys }
    func setChildOrder(_ ttys: [String], for cwd: String) { childOrder[cwd] = ttys }

    // MARK: Pin

    // Folder ordering with the pin tier on top: pinned cwds sort first (by pin order),
    // then everything else falls back to the drag rank (folderOrder) / alphabetical.
    private func folderSortsBefore(_ a: String, _ b: String) -> Bool {
        switch (pinnedFolders.firstIndex(of: a), pinnedFolders.firstIndex(of: b)) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return ranked(a, b, in: folderOrder, fallback: <)
        }
    }

    func isPinned(_ cwd: String) -> Bool { pinnedFolders.contains(cwd) }

    // Proof the user already knows the list is drag-reorderable — a saved rank can only
    // come from an actual drag. Persisted, so it also speaks for every past launch (the
    // "reorder" tip must never fire at someone who has been dragging for months).
    var hasCustomOrder: Bool { !folderOrder.isEmpty || !childOrder.isEmpty }

    func togglePin(_ cwd: String) {
        if let i = pinnedFolders.firstIndex(of: cwd) { pinnedFolders.remove(at: i) }
        else { pinnedFolders.append(cwd) }
    }
}
