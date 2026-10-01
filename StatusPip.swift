import Cocoa

// One measured terminal pane, as handed back by TerminalFocusRing.scanPanesForPips.
// `rect` is an AX frame (global, top-left origin); `window` is the CG window number the
// pane lives in, which is both what a pip anchors above and — with `windowBounds` — how
// a pip follows that window being dragged without re-measuring anything.
struct PipPane {
    let rect: CGRect
    let window: Int
    let windowBounds: CGRect
}

// One pass of TerminalFocusRing.scanPanesForPips.
//
// `panes` are visible terminal panes; `tabs` are rows of the terminal TAB STRIP (the
// vertical column of terminal icons beside the panel), which is where a terminal that is
// stacked behind another one can still show a status — its pane isn't in the tree at all.
//
// The two halves have opposite freshness rules, which is why they are reported apart.
// Panes are expensive to find and are re-measured only on a throttled deep pass, so a
// pane missing from a result usually means "not looked at". Tab rows are re-read on every
// pass from a cached element, so once `tabsFresh` is set the row set IS the truth and a
// caller may prune on it — which is also what makes dots disappear when the panel is
// collapsed.
struct PipScan {
    let panes: [pid_t: PipPane]
    let tabs: [pid_t: PipPane]
    /// Per host window, the session whose terminal that window is actually SHOWING —
    /// read off the tab strip's `selected` row. The only available answer to "which of
    /// these stacked panes is the one in front", since they share a window and so cannot
    /// be told apart by window z-order.
    let selectedByWindow: [Int: pid_t]
    let tabsFresh: Bool
    let complete: Bool
}

// MARK: - Corner status pips
//
// A status dot pinned to the top-left corner of every visible Claude terminal, so the
// state is readable without looking away from the terminal you are already in. One pip
// per pane in the VSCode family; one per tab on a native Terminal/iTerm window.
//
// ★ Why this is NOT folded into FocusRing's always-on rings, which measure the very same
// panes (改这里前必读 — the two look similar and are not):
//
//   • Visibility policy is opposite. An always-on ring sits at `.floating` and therefore
//     MUST hide itself the moment the editor stops being frontmost, or it floats over
//     whatever app you switched to. A pip sits at `.normal` anchored directly above its
//     host window, so "another app covers the terminal" already covers the pip for free —
//     which is the only way "always visible" can actually mean always.
//   • Shipping status. `ringAlwaysOn` is dev-only because its recolor ledger is a
//     long-running bug source (docs/focus-ring.md ★). Pips ship to everybody, so they
//     keep their own much smaller ledger and cannot be broken by that one.
//
// What IS shared, and deliberately so: pane measurement and pane IDENTITY, via
// `TerminalFocusRing.scanPanesForPips`. That inherits the "a pane whose owner the
// evidence doesn't single out is dropped, never guessed" rule — so a duplicate-named
// session shows NO pip rather than somebody else's status. Missing a dot is acceptable;
// a dot that lies is not.
final class TerminalStatusPips {
    static let shared = TerminalStatusPips()

    // A pip is either the dot in a visible pane's top-left corner, or the badge on that
    // terminal's row in the tab strip. One session can own both at once — the pane dot
    // says "here", the tab badge says "and here it is in the list" — so the ledger is
    // keyed by both, and every mechanism below (recolor, follow, z-order, de-stack)
    // works on either without knowing which it has.
    private enum PipKind: Hashable { case pane, tab }
    private struct PipKey: Hashable {
        let pid: pid_t
        let kind: PipKind
    }

    private struct Pip {
        let window: NSPanel
        let dot: StatusDot
        var status: String
        var axRect: CGRect      // pane frame this pip corners (AX global, top-left origin)
        var hostWindow: Int     // CG window number we order above
        var hostBounds: CGRect  // host bounds when axRect was measured — see followHostMoves
        var accentHex: String   // color currently drawn; repaint when a custom color changes
    }

    private var pips: [PipKey: Pip] = [:]
    private var lastStatusByPid: [pid_t: String] = [:]
    private var lastScan: Date = .distantPast
    private var lastDeepScan: Date = .distantPast
    private var deepMisses = 0
    // Set when a host window resizes (panes inside it relaid out) or a deep pass was cut
    // short — either way the recorded geometry can no longer be trusted. Opens the deep
    // gate exactly once; the pass that runs clears it.
    private var geometryStale = false
    private var lastDeepKeys: Set<pid_t> = []
    private var scanning = false
    private var parked = false
    // The click-time exemption from riding at `.normal` — see the ★ in syncAlpha. Set by
    // a click that lands on a host, cleared by anything else.
    private var promotedHost = 0
    private var promotedUntil = Date.distantPast
    private var watch: Timer?
    private var clickGlobal: Any?
    private var clickLocal: Any?
    private var settingsObservers: [NSObjectProtocol] = []
    // Last-logged values, so pipLog only ever records a flip (see pipLog).
    private var loggedGate = ""
    private var loggedEditorRows = -1
    private var loggedScan = ""
    private var loggedPips = -1
    private var loggedStacked = -1
    // Last known visible terminal per host window (see PipScan.selectedByWindow). Kept
    // between scans: it is only ever consulted to break a tie, and a slightly stale
    // answer still beats the pid ordering it replaced.
    private var selectedByWindow: [Int: pid_t] = [:]
    private var tickCount = 0
    private var lastRateLog = Date()

    // The dot itself, and the box around it. The box has to be MUCH bigger than the dot:
    // StatusDot's decor deliberately spills past its own bounds and hosts don't clip it
    // (Components.swift) — the needs sonar swells to scale 2.6 (radius 1.3×d) and the
    // breath glow peaks at shadowRadius 10. Sized to the larger of those, plus slack.
    // Too small and the animation gets guillotined into a square.
    private static let dotSize: CGFloat = 11
    // Smaller in the tab strip: it rides ON a 17pt terminal glyph inside a 22pt row, as a
    // badge rather than as the row's whole content. Big enough to read as a status color,
    // small enough that the glyph underneath still says "terminal".
    private static let tabDotSize: CGFloat = 9
    private static func dotSize(_ kind: PipKind) -> CGFloat {
        kind == .tab ? tabDotSize : dotSize
    }
    private static let boxSize: CGFloat = 48
    // Dot center, measured in from the pane's top-LEFT corner. Left, not right: the
    // right end of a terminal pane's top edge is where VSCode draws the terminal's own
    // tab title, and a dot parked there sits on top of it.
    //
    // ★ The X inset is per-status because what should align is the glyph's LEFT EDGE,
    // not its center. working/checking draw wide decor (the typing wave spans ±1.03×w,
    // the eye ±0.92×w — Components.swift), a single dot spans ±0.5×w; center both at one
    // x and the single-dot statuses read ~6pt more indented, which the user saw and
    // called out. Numbers chosen so both groups' left edges land flush at the corner.
    private static let insetXWide: CGFloat = 7    // working / checking (decor left edge ≈ −4)
    private static let insetXNarrow: CGFloat = 2  // single-dot statuses (left edge ≈ −3.5)
    private static let insetY: CGFloat = 8
    // Tab strip geometry, measured off VSCode's own layout (AXProbe): a row is 37×22 with
    // its 17pt terminal glyph centered, so the glyph's center sits 19pt in from the row's
    // left edge — which is ALSO where it stays once the strip is dragged wider and the
    // rows grow a text label to the right of the glyph. Hence the min(): row-center while
    // the strip is narrow, one-glyph-in once it isn't. The badge then hangs off the
    // glyph's lower-right corner.
    private static let tabIconInset: CGFloat = 19
    // Lower-LEFT of the glyph, not lower-right: user's call after seeing both. The strip
    // is only 45pt wide, so a badge hanging off the right side crowds the row's edge.
    private static let tabBadgeDX: CGFloat = -5
    private static let tabBadgeDY: CGFloat = 5
    // Two pips this close together (AX points, both axes) are stacked on each other's
    // dots. Comfortably under the tab strip's 22pt row pitch, so neighbouring rows are
    // never mistaken for a stack.
    private static let stackSlop: CGFloat = 16
    // How long a click buys its host's pips a seat at `.floating`. Just past the tail of
    // reassertBurst, which is what re-anchors them at `.normal` afterwards; the app-raise
    // that follows an activating click was measured landing hundreds of ms after the
    // mouseDown, so a shorter window would hand the dot back mid-raise.
    private static let promotionWindow: TimeInterval = 1.0

    private static func insetX(for status: String) -> CGFloat {
        status == "working" || status == "checking" ? insetXWide : insetXNarrow
    }
    private static let scanInterval: TimeInterval = 2.0
    // Floor under the deep window walk. Only ever reached while some session still has
    // no pip, so this is the cost of a session that can't be resolved, not of normal use.
    private static let deepScanInterval: TimeInterval = 5.0
    private static let deepScanCap: TimeInterval = 80.0

    // The flip between AX's global top-left origin and Cocoa's bottom-left one. Single
    // source on purpose: this used to be spelled out at each site with DIFFERENT
    // fallbacks (one fell back to the first screen's height, the other to 0), and the
    // `?? 0` variant would flip every screen rect to the wrong y — no host would test as
    // visible and every dot would silently vanish.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }

    private init() {}

    // MARK: Driver

    // Called on the main thread after each rows refresh, beside updateAlwaysOn.
    // Cheap when off: one settings read and an early return.
    func update(rows: [SessionRow]) {
        let master = AppSettings.highlightsEnabled, on = AppSettings.cornerPips
        let gate = "master=\(master) pips=\(on)"
        if gate != loggedGate {
            loggedGate = gate
            pipLog("gate \(gate)")
        }
        guard master, on else {
            if !pips.isEmpty || watch != nil || !settingsObservers.isEmpty { teardown() }
            return
        }
        installObservers()

        let prev = lastStatusByPid
        var statusByPid: [pid_t: String] = [:]
        for r in rows where !r.isDesktop && r.shellPid > 0 && r.editor != nil {
            statusByPid[r.shellPid] = r.status
        }
        if statusByPid.count != loggedEditorRows {
            loggedEditorRows = statusByPid.count
            pipLog("rows total=\(rows.count) editorSessions=\(statusByPid.count)")
        }
        lastStatusByPid = statusByPid

        tickCount &+= 1
        if Date().timeIntervalSince(lastRateLog) >= 5 {
            let inv = pips.map { "\($0.key.pid)\($0.key.kind == .tab ? "T" : "")@\(Int($0.value.window.frame.origin.x)),\(Int($0.value.window.frame.origin.y))/w\($0.value.hostWindow)/\($0.value.status)" }.sorted().joined(separator: " ")
            pipLog("RATE ticks=\(tickCount) in \(String(format: "%.1f", Date().timeIntervalSince(lastRateLog)))s pips=\(pips.count) [\(inv)]")
            tickCount = 0
            lastRateLog = Date()
        }
        // Cheap pass, every tick: retint what exists, drop what died, and slide pips
        // whose host window merely MOVED. None of this touches the accessibility tree.
        recolor(statusByPid)
        followHostMoves()
        ensureWatch()

        // Memo pass, also every tick and also AX-free: panes already resolved back when
        // the evidence named an owner. This is the PRIMARY source, not a fallback — a
        // live background walk finds panes it cannot name (see recallPanesForPips), so
        // without this the common case draws nothing at all.
        let recalled = TerminalFocusRing.shared.recallPanesForPips(Array(statusByPid.keys))
        if !recalled.isEmpty {
            apply(recalled, kind: .pane, statusByPid: statusByPid, authoritative: false)
        }

        // Expensive pass (AX walk), throttled. A session that just became visible owns no
        // pip yet — creation only happens here — so a brand-new pane would otherwise sit
        // bare for up to the throttle while its row is already colored. Detect that rising
        // edge and scan now. Flips between two live statuses stay on the cheap path.
        let newcomer = statusByPid.contains { pid, _ in
            pips[PipKey(pid: pid, kind: .pane)] == nil && prev[pid] == nil
        }
        guard !scanning,
              newcomer || Date().timeIntervalSince(lastScan) >= Self.scanInterval else { return }

        // The deep window walk is what finds panes when the focus isn't sitting in a
        // terminal — which is most of the time, and always while the editor is in the
        // background. Gate it on there being something left to find: once every session
        // owns a pip, `unplaced` is false and the steady state does no deep scans at all.
        // Its own floor on top of that, so a session that can never resolve (a duplicate
        // name we refuse to guess at) doesn't buy a tree walk every couple of seconds.
        // Back off when deep passes keep coming back empty. On this machine they always
        // will while sessions share the "✳ Claude Code" title, and a tree walk every 5s
        // for an answer that cannot arrive is exactly the cost that keeps the always-on
        // ring off release builds. Resets whenever the session set changes — a new or
        // departed session can change what resolves.
        if Set(statusByPid.keys) != lastDeepKeys {
            lastDeepKeys = Set(statusByPid.keys)
            deepMisses = 0
        }
        // `unplaced` alone was not enough: once every session owned a pip it went false
        // forever, and nothing ever re-measured. But panes DO move inside a window that
        // hasn't moved — drag the terminal panel's divider, toggle the sidebar, add a
        // split — and neither cheap path can see it (followHostMoves handles pure window
        // moves only; a memo recalled for an unchanged window returns its now-stale rect).
        // `geometryStale` is set by followHostMoves the moment a host window RESIZES, which
        // is the observable that accompanies a relayout, so a resize buys exactly one deep
        // pass instead of leaving the dots parked at their old corners indefinitely.
        let unplacedBefore = Set(statusByPid.keys.filter { pips[PipKey(pid: $0, kind: .pane)] == nil })
        let unplaced = !unplacedBefore.isEmpty
        let backoff = min(Self.deepScanCap, Self.deepScanInterval * pow(2, Double(deepMisses)))
        let deep = (unplaced || geometryStale) && Date().timeIntervalSince(lastDeepScan) >= backoff
        lastScan = Date()
        if deep { lastDeepScan = Date() }
        scanning = true
        if deep { geometryStale = false }
        // The scan runs on FocusRing's queue and calls back on the main thread — it writes
        // FocusRing state that may only be touched there (see scanPanesForPips).
        TerminalFocusRing.shared.scanPanesForPips(statusByPid: statusByPid, deep: deep) { [weak self] result in
            guard let self = self else { return }
            self.scanning = false
            // nil = no editor running at all (see scanPanesForPips). Keep what we have
            // rather than tearing down — an editor quitting takes its sessions out of
            // `rows`, and recolor() buries those pips on the next tick.
            // Deliberately NOT keyed on `deep`: deep and shallow passes alternate, so
            // including it made every single pass look like a flip and defeated the
            // whole "log flips only" rule — 2259 lines in three days, most of them
            // `deep=true` / `deep=false` toggling with an unchanged result.
            let seen = result.map { "panes=\($0.panes.count) tabs=\($0.tabs.count)" } ?? "no-editor"
            if seen != self.loggedScan {
                self.loggedScan = seen
                self.pipLog("scan \(seen)")
            }
            guard let result = result else { return }
            // Three things must ALL hold before a pass may bury pips:
            //   • it was a deep pass (a shallow one saw a single container);
            //   • it ran to completion — a pass cut short by the AX budget never reached
            //     the later windows, and those look identical to windows with no panes;
            //   • it produced something. An empty deep result has two indistinguishable
            //     causes: there really are no panes, or it found them and could not name
            //     any (the same-name case — measured containers=3 textareas=7 resolved=0).
            // Miss any one and pips get deleted and rebuilt on a loop, which is a visible
            // flicker: logged as pips=0 ↔ pips=1.
            let produced = !result.panes.isEmpty
            let mayPrune = deep && result.complete && produced
            self.apply(result.panes, kind: .pane, statusByPid: statusByPid, authoritative: mayPrune,
                       vouchedFor: Set(recalled.keys))
            // Tab rows carry none of that hedging: they are re-read whole on every pass
            // from a cached element, so once the scan says the read is fresh, a row that
            // isn't in it is a row that isn't there — the terminal was closed, or the
            // panel was collapsed. Pruning on it is what keeps badges from outliving the
            // strip they were drawn on.
            if result.tabsFresh { self.selectedByWindow = result.selectedByWindow }
            self.apply(result.tabs, kind: .tab, statusByPid: statusByPid,
                       authoritative: result.tabsFresh)
            if deep {
                // Back off on lack of PROGRESS, not lack of output. `produced` was the
                // right signal only while a failed pass produced nothing at all; once a
                // window holds one resolvable session beside two unresolvable ones, every
                // pass "produces" and the counter never advances — buying a full tree walk
                // every 5s forever for an answer that cannot arrive, which is the exact
                // cost that keeps always-on rings off release builds. What matters is
                // whether this pass placed a session that had no pip before it ran.
                let placedSomethingNew = unplacedBefore.contains {
                    self.pips[PipKey(pid: $0, kind: .pane)] != nil
                }
                self.deepMisses = placedSomethingNew ? 0 : min(self.deepMisses + 1, 4)
                // A truncated pass didn't finish the job; don't let its partial result
                // stand in for a completed geometry refresh.
                if !result.complete { self.geometryStale = true }
            }
        }
    }

    // MARK: Cheap passes (no AX)

    // Keep the tint current between scans and bury pips whose session is gone. A rebuild
    // fires on a status flip OR a custom-color change (same status, new hex), so editing a
    // status color in Settings repaints the live pips right away.
    private func recolor(_ statusByPid: [pid_t: String]) {
        for (key, pip) in pips {
            guard let status = statusByPid[key.pid] else { remove(key, reason: "session-gone"); continue }
            let hex = Status.accent(status).hexString
            guard status != pip.status || hex != pip.accentHex else { continue }
            pipLog("REPAINT pid=\(key.pid) \(pip.status) -> \(status)")
            pip.dot.apply(status)
            var p = pip
            p.status = status
            p.accentHex = hex
            // The inset group may have changed with the status (wide decor vs single
            // dot) — reseat so the glyph's left edge stays put while its center moves.
            p.window.setFrameOrigin(Self.boxOrigin(forAX: p.axRect, status: status, kind: key.kind))
            pips[key] = p
        }
    }

    // Drag the host window and every pane inside keeps its position RELATIVE to it, so a
    // pure move can be followed exactly without asking the accessibility tree anything —
    // one CGWindowList read for all pips. A RESIZE relays out the panes, which this can't
    // predict, so those are left to the next scan rather than guessed at.
    //
    // This is what lets pips track a window the user drags while the editor is in the
    // background, where the AX scan deliberately refuses to run.
    private func followHostMoves() {
        guard !pips.isEmpty else { return }
        let bounds = hostBoundsByWindow(Set(pips.values.map { $0.hostWindow }))
        for (key, pip) in pips {
            guard let now = bounds[pip.hostWindow] else { continue }
            let sameSize = abs(now.width - pip.hostBounds.width) < 0.5
                && abs(now.height - pip.hostBounds.height) < 0.5
            let moved = abs(now.origin.x - pip.hostBounds.origin.x) >= 0.5
                || abs(now.origin.y - pip.hostBounds.origin.y) >= 0.5
            if !sameSize {
                // A resize relaid out the panes inside; their new rects are not derivable
                // from the window's. Ask for a deep pass, and take the new bounds as the
                // baseline NOW — leaving the pre-resize bounds recorded would make the
                // next pure drag translate by (drag + the resize's own origin shift),
                // which a resize from the left or top edge produces.
                var p = pip
                p.hostBounds = now
                pips[key] = p
                geometryStale = true
                continue
            }
            guard moved else { continue }
            let dx = now.origin.x - pip.hostBounds.origin.x
            let dy = now.origin.y - pip.hostBounds.origin.y
            var p = pip
            p.axRect = pip.axRect.offsetBy(dx: dx, dy: dy)
            p.hostBounds = now
            p.window.setFrameOrigin(Self.boxOrigin(forAX: p.axRect, status: p.status, kind: key.kind))
            pips[key] = p
        }
    }

    private func hostBoundsByWindow(_ wanted: Set<Int>) -> [Int: CGRect] {
        guard !wanted.isEmpty, let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var out: [Int: CGRect] = [:]
        for info in list {
            guard let num = info[kCGWindowNumber as String] as? Int, wanted.contains(num),
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { continue }
            out[num] = b
        }
        return out
    }

    // MARK: Expensive pass

    // Reconcile pips with a fresh scan: bury panes that are no longer visible, raise pips
    // for new ones, slide the rest. Color is owned by recolor().
    private func apply(_ panes: [pid_t: PipPane], kind: PipKind, statusByPid: [pid_t: String],
                       authoritative: Bool, vouchedFor: Set<pid_t> = []) {
        guard AppSettings.highlightsEnabled, AppSettings.cornerPips else { teardown(); return }
        // Only a DEEP pass is entitled to bury pips. A shallow one looked at a single
        // terminal container — the one the focus happened to be in — so a pane missing
        // from its result means "not measured", not "not visible". Pruning on that would
        // wipe every pip in the other windows on each cheap tick.
        //
        // ★ And even a deep pass may only bury a pane NOTHING ELSE still vouches for
        // (改这里前必读). "Missing from the deep result" has the same two indistinguishable
        // causes per-pane that an empty result has in aggregate: the pane is gone, or it
        // was found and could not be named — which is the normal outcome for every
        // session still titled "✳ Claude Code". The memo, meanwhile, is a positive
        // statement about that exact pane (measured when the evidence did single an owner
        // out, and re-gated each tick on its host window still being onscreen and
        // unmoved). Silence is not a contradiction, so a pid the memo pass just recalled
        // survives. Without this the two passes fight over the same dot every few seconds
        // — measured as pips=2 → pruned-by-deep → pips=1 → recalled → pips=2, which is
        // exactly the blinking dot this rule exists to stop.
        if authoritative {
            for key in Array(pips.keys)
            where key.kind == kind && panes[key.pid] == nil && !vouchedFor.contains(key.pid) {
                remove(key, reason: "pruned-by-deep")
            }
        }
        for (pid, pane) in panes {
            guard let status = statusByPid[pid] else { continue }
            let key = PipKey(pid: pid, kind: kind)
            if pips[key] != nil {
                move(key, pane: pane)
            } else {
                create(key, pane: pane, status: status)
            }
        }
        if pips.count != loggedPips {
            loggedPips = pips.count
            pipLog("pips=\(pips.count) windows=\(Set(pips.values.map { $0.hostWindow }).count)")
        }
    }

    private func create(_ key: PipKey, pane: PipPane, status: String) {
        let axRect = pane.rect
        let hostWindow = pane.window
        let frame = CGRect(origin: Self.boxOrigin(forAX: axRect, status: status, kind: key.kind),
                           size: CGSize(width: Self.boxSize, height: Self.boxSize))
        let w = Self.makeWindow(frame: frame)
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.letShadowsEscape()
        let d = Self.dotSize(key.kind)
        let dot = StatusDot(diameter: d)
        dot.frame = NSRect(x: (Self.boxSize - d) / 2, y: (Self.boxSize - d) / 2, width: d, height: d)
        host.addSubview(dot)
        w.contentView = host
        // Keyless on purpose. StatusDot's entrance-animation bookkeeping is global and
        // keyed by session (Components.swift), so passing the row's key here would let
        // whichever dot renders first eat the entrance and leave the other one static.
        // Keyless dots draw the steady animation and never claim an entrance.
        dot.apply(status)
        w.alphaValue = 0
        w.orderFrontRegardless()
        w.order(.above, relativeTo: hostWindow)
        pips[key] = Pip(window: w, dot: dot, status: status, axRect: axRect,
                        hostWindow: hostWindow, hostBounds: pane.windowBounds,
                        accentHex: Status.accent(status).hexString)
        // Fade in only if nothing is currently parking the pips, so one born while a
        // takeover is up doesn't animate itself into view over Mission Control — and not
        // if it is born underneath another pip's dot, or the de-stack rule below would
        // have to blink it straight back out.
        let snap = windowSnapshot()
        if !snap.systemTakeover, snap.visible.contains(hostWindow), !stackedBehind(snap).contains(key) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                w.animator().alphaValue = 1
            }
        }
        ensureWatch()
    }

    private func move(_ key: PipKey, pane: PipPane) {
        guard var p = pips[key] else { return }
        let origin = Self.boxOrigin(forAX: pane.rect, status: p.status, kind: key.kind)
        if abs(origin.x - p.window.frame.origin.x) >= 0.5
            || abs(origin.y - p.window.frame.origin.y) >= 0.5 {
            pipLog("MOVE pid=\(key.pid) \(Int(p.window.frame.origin.x)),\(Int(p.window.frame.origin.y)) -> \(Int(origin.x)),\(Int(origin.y)) rect=\(Int(pane.rect.minX)),\(Int(pane.rect.minY)),\(Int(pane.rect.width))x\(Int(pane.rect.height))")
            p.window.setFrameOrigin(origin)
        }
        if pane.window != p.hostWindow { p.window.order(.above, relativeTo: pane.window) }
        p.axRect = pane.rect
        p.hostWindow = pane.window
        p.hostBounds = pane.windowBounds
        pips[key] = p
    }

    private func remove(_ key: PipKey, reason: String) {
        guard let p = pips.removeValue(forKey: key) else { return }
        p.window.orderOut(nil)
        pipLog("remove pid=\(key.pid) kind=\(key.kind) reason=\(reason)")
    }

    // MARK: Geometry

    // Where the dot itself lands, kept in the global top-left space that AX frames and
    // kCGWindowBounds share — so it can be hit-tested straight against the window list
    // (syncAlpha's level rule) without another coordinate flip.
    private static func dotCenter(forAX r: CGRect, status: String, kind: PipKind) -> CGPoint {
        switch kind {
        case .pane:
            return CGPoint(x: r.minX + insetX(for: status), y: r.minY + insetY)
        case .tab:
            return CGPoint(x: r.minX + min(r.width / 2, tabIconInset) + tabBadgeDX,
                           y: r.midY + tabBadgeDY)
        }
    }

    // Bottom-left origin of the box, given the AX rect the pip belongs to: a pane's
    // frame (dot in its top-left corner) or a tab strip row's frame (badge on its glyph).
    // Mirrors FocusRing.cocoaRect: AX frames are global top-left-origin (y down from the
    // primary display's top), NSWindow wants Cocoa coords (y up from its bottom).
    private static func boxOrigin(forAX r: CGRect, status: String, kind: PipKind) -> CGPoint {
        let center = dotCenter(forAX: r, status: status, kind: kind)
        // Rounded, and not for tidiness: a 37pt-wide tab row puts the box origin on a
        // half point, AppKit snaps the panel to the backing grid anyway, and the next
        // pass then reads back an origin 0.5pt from the one it asked for — which reads as
        // "moved" forever, so every pass reordered and relogged a window that never
        // actually went anywhere.
        return CGPoint(x: (center.x - boxSize / 2).rounded(),
                       y: (primaryHeight - center.y - boxSize / 2).rounded())
    }

    // ★ NSPanel + .nonactivatingPanel, NOT a bare NSWindow — the configuration proven in
    // this app to appear on any Space (a bare NSWindow ordered by a background app during
    // a Space transition can be assigned to a non-active Space and never become visible;
    // see FocusRing.makeOverlayWindow).
    //
    // Level is `.normal`, unlike the always-on ring's `.floating`: a pip rides just above
    // its host window, so anything covering the terminal covers the pip too. That is the
    // behavior the feature was specified with — the dot belongs to the terminal, not to
    // the screen. It also means a click into the host raises it ABOVE us, which is what
    // the reassert burst below exists to undo.
    private static func makeWindow(frame: CGRect) -> NSPanel {
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isFloatingPanel = false
        w.level = .normal
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // No .canJoinAllSpaces: a pip belongs to its host window's Space, and macOS then
        // hides/shows it with that Space for free.
        w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        return w
    }

    // MARK: Visibility

    // Poll while any pip exists. Covers the cases where the host window is technically
    // still "frontmost" but you cannot see it: Mission Control, Show Desktop, App Exposé,
    // minimize, ⌘H, another Space, dragged off-screen. Only ownerPID / layer / bounds /
    // alpha / windowNumber are read, so this needs no screen-recording permission.
    private func ensureWatch() {
        guard watch == nil, !pips.isEmpty else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.pips.isEmpty else { self.stopWatch(); return }
            self.syncAlpha()
        }
        RunLoop.main.add(t, forMode: .common)
        watch = t
        armReassert()
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
        disarmReassert()
    }

    // One funnel for every reason a pip should be invisible, so no single reason can
    // un-hide a pip another still wants hidden.
    private func syncAlpha() {
        let snapshot = windowSnapshot()
        parked = snapshot.systemTakeover
        let buriedByStack = stackedBehind(snapshot)
        if buriedByStack.count != loggedStacked {
            loggedStacked = buriedByStack.count
            let sel = selectedByWindow.map { "w\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
            pipLog("stacked hidden=\(buriedByStack.count) of \(pips.count) showing[\(sel)]")
        }
        for (key, pip) in pips {
            let visible = !parked && snapshot.visible.contains(pip.hostWindow)
                && !buriedByStack.contains(key)
            let want: CGFloat = visible ? 1 : 0
            let wasWrong = pip.window.alphaValue != want
            if wasWrong { pipLog("ALPHA \(pip.window.alphaValue) -> \(want) parked=\(parked) vis=\(visible)") }
            if wasWrong { pip.window.alphaValue = want }
            guard visible else { continue }
            // ★ A pip's RESTING level is `.normal`, and it is only ever lifted to
            // `.floating` for the ~1s after a click landed on its own host (改这里前必读).
            //
            // The lift exists because a click raises the host above everything at its
            // level INCLUDING a `.normal` pip, and the raise lands 100-500ms after the
            // mouseDown we observe — no after-the-fact reordering closes that gap, so
            // some frames always show the dot buried unless it sits out that one fight.
            //
            // What it must NOT become is the resting state. Riding `.floating` whenever
            // "nothing covers the dot right now" reads fine in a screenshot and is wrong
            // in motion: coming back down then depends on a 0.25s tick noticing the
            // cover, so dragging a window over a terminal leaves the dots painted on top
            // of it for a visible beat (user: "移动上去后过 0.x 秒才消失"). At `.normal`
            // there is nothing to notice and nothing to wait for — the window server
            // covers the pip in the same frame it covers the terminal, which is the whole
            // specified behavior of this feature.
            //
            // So the exemption is scoped to the one event that needs it, and every way
            // out of it is immediate: clicking anything that is not this host cancels it
            // on the mouseDown (cancelPromotion), and the hit test below drops it the
            // moment something is actually over the dot — per pip and per point, since a
            // window overlapping just the corner a dot sits in leaves the host frontmost
            // by every window-level measure while still covering the dot.
            let center = Self.dotCenter(forAX: pip.axRect, status: pip.status, kind: key.kind)
            let exempt = pip.hostWindow == promotedHost && Date() < promotedUntil
                && snapshot.frontWindow(at: center) == pip.hostWindow
            let wantLevel: NSWindow.Level = exempt ? .floating : .normal
            if pip.window.level != wantLevel {
                pipLog("LEVEL pid=\(key.pid) \(key.kind) -> \(wantLevel == .floating ? "floating" : "normal") host=w\(pip.hostWindow)")
                pip.window.level = wantLevel
                // A level change re-inserts the panel within the new level; re-anchor so
                // a demoted pip lands just above its host, not at the level's back.
                pip.window.order(.above, relativeTo: pip.hostWindow)
            }
            // ★ Reorder ONLY when the snapshot proves the pip is behind its host — never
            // unconditionally (改这里前必读). The old every-tick order(.above:) looked
            // idempotent and was not: order(.above, relativeTo:) places the panel
            // DIRECTLY above the host, so with two pips riding one window each tick
            // swapped their z — a window-server reorder of every pip 4×/s, forever.
            // Constant restacking of a layer-backed panel is visible churn, and it also
            // made every tick's cost scale with pip count for no benefit. The z-order is
            // already in the snapshot this tick paid for; use it.
            let pi = snapshot.order.firstIndex(of: pip.window.windowNumber)
            let hi = snapshot.order.firstIndex(of: pip.hostWindow)
            let buried = pi == nil || hi == nil || pi! > hi!
            if wantLevel == .normal, buried || wasWrong {
                if buried { pipLog("BURIED host=\(pip.hostWindow) pipIdx=\(pi ?? -1) hostIdx=\(hi ?? -1)") }
                pip.window.order(.above, relativeTo: pip.hostWindow)
            }
        }
    }

    // ★ Pips whose dot is sitting on another pip's dot, all but the front one (改这里前
    // 必读). Opening terminals as TABS rather than splits — one pane visible, the rest
    // stacked behind it, and the same again in a second editor window parked at the same
    // screen position — puts several sessions' panes at the same few pixels: measured as
    // three sessions all anchored within 3pt of each other. Each dot then rides above its
    // OWN host window, which is the one thing that normally keeps a background window's
    // dot out of sight; when the windows overlap exactly, the dots don't hide each other,
    // they pile into an unreadable smear at one corner.
    //
    // So resolve it here rather than at measure time: the geometry is legitimate (every
    // one of those panes really is at that rect), it is only the DRAWING that has to pick
    // one. Front-most host wins, which is the one whose terminal you can actually see;
    // the rest are hidden until they come forward, and nothing is deleted — a pip merely
    // hidden comes straight back the moment its window is raised.
    private func stackedBehind(_ snapshot: Snapshot) -> Set<PipKey> {
        guard pips.count > 1 else { return [] }
        // ★ Two levels of "which one is in front", answering different halves of the
        // problem — and they have to run in this order (改这里前必读):
        //
        //   ① WITHIN one window — the tab strip's selected row. Terminals opened as TABS
        //      put every one of their panes in one window at one rect, so window z-order
        //      says nothing about them, and the pane memo keeps vouching for the ones
        //      that are no longer on screen (its gates ask whether the host window moved,
        //      never whether this pane is still the one being shown). Picking among them
        //      by pid, as this first did, picks an arbitrary session: the user sat on an
        //      idle terminal reading a blue "running" dot that belonged to a terminal
        //      hidden behind it.
        //   ② ACROSS windows — window z-order. Two editor windows parked at the same
        //      screen position each show a terminal; the front window's is the visible one.
        //
        // ★ ① deliberately only looks at panes that COINCIDE with another pane of the
        // same window. That is what a tab stack looks like, and it is what keeps SPLITS
        // working: a split shows two panes at once but marks only one row selected, and
        // those two sit at different rects — so they never form a stack and neither is
        // ever hidden by this. Widen the test to "every pane of the window" and half of
        // every split goes dark.
        var hidden: Set<PipKey> = []
        let panes = pips.filter { $0.key.kind == .pane
            && snapshot.visible.contains($0.value.hostWindow) }

        // ⓪ A pane dot that lands on its own window's tab strip is provably stale: no live
        // pane overlaps the strip. It happens when the strip sits on the LEFT and appears
        // after the memo was taken (a second terminal opened) — every pane shifts right by
        // the strip's width, but the host window's bounds don't change, so recallPane's
        // gates still vouch for the old rect. The dot then piles onto that row's badge.
        var strip: [Int: CGRect] = [:]
        for (key, pip) in pips where key.kind == .tab {
            strip[pip.hostWindow] = strip[pip.hostWindow].map { $0.union(pip.axRect) } ?? pip.axRect
        }
        for (key, pip) in panes {
            guard let s = strip[pip.hostWindow] else { continue }
            let dot = Self.dotCenter(forAX: pip.axRect, status: pip.status, kind: .pane)
            if dot.x >= s.minX && dot.x <= s.maxX
                && pip.axRect.maxY > s.minY && pip.axRect.minY < s.maxY {
                hidden.insert(key)
            }
        }

        for (key, pip) in panes where !hidden.contains(key) {
            guard let showing = selectedByWindow[pip.hostWindow], showing != key.pid else { continue }
            let coincides = panes.contains { other in
                other.key != key && other.value.hostWindow == pip.hostWindow
                    && abs(other.value.axRect.minX - pip.axRect.minX) < Self.stackSlop
                    && abs(other.value.axRect.minY - pip.axRect.minY) < Self.stackSlop
            }
            if coincides { hidden.insert(key) }
        }

        // Front-to-back by host window; anything ① already buried is out of the running.
        // The pid ordering is only a stable tiebreak for pips ① had no opinion about.
        let z = { (window: Int) in snapshot.order.firstIndex(of: window) ?? Int.max }
        let ranked = pips.filter { snapshot.visible.contains($0.value.hostWindow)
                                   && !hidden.contains($0.key) }
            .sorted { a, b in
                let za = z(a.value.hostWindow), zb = z(b.value.hostWindow)
                return za == zb ? a.key.pid < b.key.pid : za < zb
            }
        var kept: [CGPoint] = []
        for (key, pip) in ranked {
            let at = pip.axRect.origin
            if kept.contains(where: { abs($0.x - at.x) < Self.stackSlop
                                   && abs($0.y - at.y) < Self.stackSlop }) {
                hidden.insert(key)
            } else {
                kept.append(at)
            }
        }
        return hidden
    }

    // One CGWindowList pass answering everything a tick needs to know about the stack: is
    // a full-screen system takeover up (Mission Control / Show Desktop / App Exposé all
    // show as a screen-sized Dock-owned window above layer 0), which of our host windows
    // are actually on a display, and — for the level rule — who is in front at any given
    // point on screen.
    private struct Snapshot {
        let systemTakeover: Bool
        let visible: Set<Int>
        let order: [Int]
        /// Every on-screen, non-transparent layer-0 window except our own pip panels,
        /// front to back. `frontWindow(at:)` reads it; nothing else should need it.
        let blockers: [(num: Int, rect: CGRect)]

        /// The window you would actually click at this point — i.e. whatever is covering
        /// it. Nil only if the point is over bare desktop.
        func frontWindow(at point: CGPoint) -> Int? {
            blockers.first { $0.rect.contains(point) }?.num
        }
    }

    private func windowSnapshot() -> Snapshot {
        let empty = Snapshot(systemTakeover: false, visible: [], order: [], blockers: [])
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return empty }
        let dockPid = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? -1
        // Screen frames flipped into CG's global top-left space, to ask "is this window
        // on any display at all".
        let mainH = Self.primaryHeight
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: mainH - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
        guard !screens.isEmpty else { return empty }
        let wanted = Set(pips.values.map { $0.hostWindow })
        // ★ What gets skipped here is our own PIP PANELS, by window number — not our own
        // process (改这里前必读). Excluding the whole pid was the bug behind "the dots
        // float over the app in front": SpectiX's own window covering a terminal then
        // read as no cover at all, the host underneath looked frontmost, and its pips
        // were promoted to `.floating` right on top of our window. Only the pips
        // themselves have to be skipped, and only because a pip sitting above its host is
        // exactly what we are trying to measure.
        let mine = Set(pips.values.map { $0.window.windowNumber })
        var takeover = false
        var visible: Set<Int> = []
        var order: [Int] = []
        var blockers: [(num: Int, rect: CGRect)] = []
        for info in list {
            guard let num = info[kCGWindowNumber as String] as? Int else { continue }
            order.append(num)
            guard let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if layer == 0, alpha > 0.01, !mine.contains(num) { blockers.append((num, b)) }
            if !takeover, (info[kCGWindowOwnerPID as String] as? pid_t) == dockPid, layer > 0,
               screens.contains(where: { b.width >= $0.width * 0.95 && b.height >= $0.height * 0.95 }) {
                takeover = true
            }
            guard wanted.contains(num) else { continue }
            if alpha > 0.01, screens.contains(where: { $0.intersects(b) }) { visible.insert(num) }
        }
        return Snapshot(systemTakeover: takeover, visible: visible, order: order, blockers: blockers)
    }

    // MARK: Anchor reassert

    // ★ A pip rides just above its host at `.normal`, so ANY click into that window —
    // editor, sidebar, titlebar, not just a terminal — makes AppKit order the host front,
    // i.e. above us, and the pip is covered until the next 0.25s tick pulls it back. That
    // blackout reads as a blink. The same bug FocusRing's anchored caption hit; the same
    // fix: re-assert straight off the click. The raise can land slightly after the
    // mouseDown we observe, so fire a short burst — an order(.above:) is an idempotent
    // window-server reorder, cheap enough to repeat a few times per click.
    private func armReassert() {
        guard clickGlobal == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let onClick: (NSEvent) -> Void = { [weak self] _ in
            self?.promotePipsUnderClick()
            self?.reassertBurst()
        }
        clickGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: onClick)
        clickLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            onClick(event); return event
        }
    }

    private func disarmReassert() {
        if let m = clickGlobal { NSEvent.removeMonitor(m); clickGlobal = nil }
        if let m = clickLocal { NSEvent.removeMonitor(m); clickLocal = nil }
    }

    // Granting the level exemption described in syncAlpha, at mouseDown time: a click
    // landing on a host window's own surface (the frontmost layer-0 window at that point)
    // is about to raise that host to the top, so its pips step out of the way NOW, before
    // the raise, rather than being pulled back after it.
    //
    // A click anywhere else CANCELS instead, in the same event — that is what makes
    // "drag a window over the terminal" hide the dots with no lag at all: grabbing that
    // window's title bar is itself a click on a non-host window, so the pips are back at
    // `.normal` before the drag has moved a pixel. Our own windows are "somewhere else"
    // like any other app's — see the ★ in windowSnapshot.
    private func promotePipsUnderClick() {
        guard !pips.isEmpty else { return }
        let loc = NSEvent.mouseLocation  // Cocoa coords, bottom-left origin
        let point = CGPoint(x: loc.x, y: Self.primaryHeight - loc.y)
        let snapshot = windowSnapshot()
        guard let num = snapshot.frontWindow(at: point),
              pips.values.contains(where: { $0.hostWindow == num }) else {
            cancelPromotion()
            return
        }
        promotedHost = num
        promotedUntil = Date().addingTimeInterval(Self.promotionWindow)
        for pip in pips.values where pip.hostWindow == num && pip.window.level != .floating {
            pip.window.level = .floating
        }
    }

    // Back to resting level immediately, without waiting for a tick — the whole point of
    // the exemption being click-scoped.
    private func cancelPromotion() {
        promotedHost = 0
        promotedUntil = .distantPast
        for pip in pips.values where pip.window.level != .normal {
            pip.window.level = .normal
            pip.window.order(.above, relativeTo: pip.hostWindow)
        }
    }

    private func reassertBurst() {
        guard !pips.isEmpty else { return }
        // Tail extends to 0.8s: a click that ACTIVATES the editor app raises its whole
        // window set, and that lands hundreds of ms after the mouseDown we observe —
        // measured as BURIED still true at the next 0.25s tick with the old 0.18s tail.
        for delay in [0.0, 0.05, 0.12, 0.25, 0.45, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.parked else { return }
                for pip in self.pips.values where pip.window.alphaValue > 0 {
                    pip.window.order(.above, relativeTo: pip.hostWindow)
                }
            }
        }
    }

    // MARK: Observers

    private func installObservers() {
        guard settingsObservers.isEmpty else { return }
        // Activating ANY app reorders the window list wholesale: activating the editor
        // raises every editor window above every pip in one shot (measured: BURIED for
        // all hosts in the same tick). The mouseDown monitor alone can miss it — the
        // raise lands later than the click. The activation notification is the
        // authoritative signal, so re-assert straight off it.
        settingsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil,
            queue: .main) { [weak self] _ in
                // syncAlpha first, and not just the burst: switching apps by ⌘-Tab is the
                // one way to cover a dot without a click, so the level exemption has to be
                // re-tested off this notification too rather than waiting up to a tick.
                // Activating the host's OWN app re-tests clean and keeps the exemption.
                self?.syncAlpha()
                self?.reassertBurst()
            })
        // A custom status color changed — recolor() picks it up on the next tick via the
        // accent-hex comparison, so nothing to do here beyond staying subscribed.
        // A THEME change is different: StatusDot bakes its palette at build time, and the
        // app's convention is that a theme switch rebuilds UI wholesale rather than
        // repainting in place. Do the same for pips.
        settingsObservers.append(NotificationCenter.default.addObserver(
            forName: AppSettings.themeDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildAllContent()
            })
        // A pip panel is ordered onto whichever Space was current when it was created, and
        // deliberately carries no .canJoinAllSpaces (it belongs to its host window's Space).
        // Drag the host to another desktop and the panel stays behind on the old one, while
        // syncAlpha still reads the host as visible and dutifully sets alpha 1 on a panel
        // nobody can see — and since the session still owns a pip, nothing reconsiders it.
        // Rebuild on a Space change: drop the panels and let the next tick place them on
        // the Space their hosts are actually on now.
        settingsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
            queue: .main) { [weak self] _ in
                guard let self = self, !self.pips.isEmpty else { return }
                for key in Array(self.pips.keys) { self.remove(key, reason: "space-change") }
                self.geometryStale = true
                self.lastDeepScan = .distantPast
            })
    }

    private func rebuildAllContent() {
        for (key, pip) in pips {
            let d = Self.dotSize(key.kind)
            let dot = StatusDot(diameter: d)
            dot.frame = NSRect(x: (Self.boxSize - d) / 2, y: (Self.boxSize - d) / 2,
                               width: d, height: d)
            let host = NSView(frame: NSRect(origin: .zero,
                                            size: CGSize(width: Self.boxSize, height: Self.boxSize)))
            host.letShadowsEscape()
            host.addSubview(dot)
            pip.window.contentView = host
            dot.apply(pip.status)
            var p = pip
            p.accentHex = Status.accent(pip.status).hexString
            pips[key] = Pip(window: p.window, dot: dot, status: p.status, axRect: p.axRect,
                            hostWindow: p.hostWindow, hostBounds: p.hostBounds,
                            accentHex: p.accentHex)
        }
    }

    // MARK: Diagnostics

    // ~/.claude/spectix/pip-diag.log, same shape as FocusRing's ring-diag.log. Every
    // call site logs FLIPS only, never per-tick state — this runs on the app's 2.5s
    // refresh, and a line each time would be 128KB of "nothing changed" per hour.
    // The questions it exists to answer: are the two switches on, is anything in rows
    // to draw for, did the scan see panes, and did any pip actually get built.
    private func pipLog(_ line: String) {
        let path = "\(NSHomeDirectory())/.claude/spectix/pip-diag.log"
        guard let data = "\(Self.logStamp.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 128 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }

    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func teardown() {
        for pid in Array(pips.keys) { remove(pid, reason: "teardown") }
        stopWatch()
        lastStatusByPid = [:]
        lastScan = .distantPast
        // Reset the deep-scan backoff too. Leaving it meant switching the feature off and
        // back on inherited a backoff that could be at its 80s cap, so the first deep pass
        // after re-enabling was up to 80 seconds away and only memo recall placed dots
        // meanwhile. The log baselines likewise, or the first line after re-enabling gets
        // swallowed as "unchanged".
        lastDeepScan = .distantPast
        deepMisses = 0
        lastDeepKeys = []
        geometryStale = false
        loggedGate = ""
        loggedEditorRows = -1
        loggedScan = ""
        loggedPips = -1
        parked = false
        // Two different centers feed this array (NotificationCenter for the theme,
        // NSWorkspace's own for the Space change); removing from the wrong one is a no-op,
        // so each observer is offered to both.
        for o in settingsObservers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        settingsObservers = []
    }
}
