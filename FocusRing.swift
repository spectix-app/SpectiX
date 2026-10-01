import Cocoa
import ApplicationServices

// MARK: - Terminal focus ring
//
// After a jump lands you in a VSCode window, a glowing ring is drawn around the
// terminal pane of the TARGET session — so with many terminals (splits, tabs,
// windows) you can spot where you landed at a glance. The ring breathes three
// times (~3.8s) and fades out ON the rhythm — never cut mid-pulse. Every jump
// click re-runs highlight(), which replaces the ring and restarts the cycle.
// It ends early on any keystroke OR a click INSIDE the ringed pane (answering a
// permission prompt right there — the ring already did its job); clicks outside
// do NOT dismiss (clicking other terminals while hunting is exactly when you
// need it).
//
// HOW THE PANE IS LOCATED — VSCode is Electron, whose renderer accessibility
// tree stays collapsed by default (the focused-element query returns NoValue).
// Setting the Electron-specific "AXManualAccessibility" attribute expands it;
// then kAXFocusedUIElementAttribute lands on xterm's hidden input textarea
// (AXDOMClassList contains "xterm-helper-textarea" — locale-independent, unlike
// its description). That element is cursor-sized (~7×14); walking kAXParent up
// to the first ancestor with a real extent yields ".xterm-screen" — the pane's
// on-screen frame. prewarm() expands the tree at app launch so jump-time
// resolution is near-instant. We deliberately LEAVE manual accessibility on
// (same precedent as the Claude-desktop AX probe): toggling it off would
// re-trigger VSCode's one-time "screen reader detected?" prompt and a full tree
// rebuild on every jump.
//
// ★ IDENTITY GUARD — the focused textarea is only trusted as the target when
// the companion extension's active-terminal report ("<shellPid>:<nonce>", written
// on every terminal focus) says the target shellPid is the CURRENTLY focused
// terminal, with an mtime fresh for this jump. Without this, "whatever terminal
// happens to be focused" gets ringed: the extension's term.show can lose a race
// against the user clicking some OTHER terminal while hunting, which drew the
// ring around the wrong pane (the original bug). With it, a foreign click just
// keeps the poll waiting — and if the user does click into the right terminal
// mid-hunt, the ring lights up there and confirms it.
//
// Fallback: no companion extension (no pane focus to find) or the pane never
// resolves → ring the focused VSCode window instead, which still answers
// "which window did I land in". Skipped when the freshest focus report is some
// OTHER terminal — the user has demonstrably moved on.
// AXObserver requires a C-convention callback (no captures), so this free
// function bounces to the singleton via the refcon we register with. Runs on the
// main run loop (where the observer source is added), so overlay mutation is safe.
private func ringAXObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                    _ notification: CFString,
                                    _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let ring = Unmanaged<TerminalFocusRing>.fromOpaque(refcon).takeUnretainedValue()
    ring.handleAXLayoutNotification(notification as String)
}

final class TerminalFocusRing {
    static let shared = TerminalFocusRing()

    private let queue = DispatchQueue(label: "spectix.focusring", qos: .userInitiated)
    private let tokenPath = "\(NSHomeDirectory())/.claude/spectix/active-terminal"
    private var generation = 0          // bumps on every highlight/dismiss; stale polls abort
    private var window: NSWindow?
    // Tiny mouse-accepting panel floated over the titlebar caption's ✕ glyph — the
    // ring overlay itself is click-through, so this is what actually takes the click.
    private var closeButton: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var timeoutWork: DispatchWorkItem?
    // Space-follow (see bindToActiveSpace): the overlay is born canJoinAllSpaces so the
    // jump's Space switch can't hide it; one runloop tick later — still at alpha 0,
    // before the fade-in, so the reseat is invisible — we re-bind it to the target's
    // Space so macOS shows/hides it natively as you leave and return. `spaceBound`
    // guards the bind to fire exactly once per highlight.
    private var spaceBound = false
    // Z-order anchor: CG window number of the target app's window the overlay rides
    // on. With an anchor the overlay lives at .normal level ordered just ABOVE that
    // window, so any app IN FRONT of the terminal covers the ring/caption too —
    // they stick to the terminal's depth instead of floating over everything
    // (which .floating did, T39 follow-up). 0 = unresolved → .floating fallback.
    // The track loop reasserts the ordering (a raise of the target app lifts its
    // window above ours) and refreshes the number every ~2s.
    private var anchorWindowNumber: Int = 0
    private var anchorResolvedAt: Date = .distantPast
    // Click monitors that re-assert the anchor ordering immediately (see
    // armAnchorReassert) — separate from localMonitor/globalMonitor, which arm the
    // dismiss hooks and are skipped entirely when a caption is up.
    private var anchorClickGlobal: Any?
    private var anchorClickLocal: Any?
    // Passive mouse-moved monitors driving the caption's hover expansion (see
    // armCaptionHover) — a third pair, again independent of the two above.
    private var hoverMonitors: [Any] = []
    private var captionHovered = false
    private var armedAt: Date = .distantPast
    // When the overlay actually became visible. armedAt is stamped when highlight()
    // STARTS, but the pane resolve in between can take seconds (a cold a11y-tree
    // expansion), so anything meant to grant the overlay a settle grace "on arrival"
    // must count from here, not from the arm (see applyCaptionFocus).
    private var shownAt: Date = .distantPast
    private var shownTarget: CGRect?   // ringed pane, Cocoa screen coords (set once shown)
    private var currentTarget: pid_t = 0   // shellPid of the highlight in flight/visible
    // Whether the in-flight arm came from a JUMP (armJump) vs a manual click
    // (flashFocused → highlight). The 1.5s foreign-pid suppression in flashFocused
    // exists ONLY to swallow the raise's restore-focus side effect during a jump;
    // gating it on this flag lets rapid manual clicks across different terminals
    // each ring immediately instead of the second one being eaten (the "next
    // terminal doesn't highlight when clicking fast" bug).
    private var armedByJump = false
    // Caption drawn at the top-center of the one-shot ring — the target's project
    // and task summary, set by highlight/highlightWindow and read by show/reposition
    // when the RingView is (re)built. Empty = no caption (always-on overlays never
    // carry one); the style is AppSettings.captionStyle.
    private var currentProject = ""
    private var currentTask = ""
    // The project badge shown at the head of the caption — the same tile the list
    // header/toast uses (SessionRow.badgeMode), so the label on the terminal is
    // recognizable as that project at a glance. nil = title only (window fallbacks
    // and always-on overlays, which carry no caption anyway).
    private var currentIcon: LogoBadge.Mode?
    // Live-tracking state for a 常驻 (forever) caption+ring: the status/color the
    // overlay was last DRAWN with (so refreshLiveCaption only rebuilds on a real
    // change) and whether the current draw was ring-eligible (so recolor can honor
    // a live style flip to/from .off — idle drops the ring, working restores it —
    // without resurrecting a ring on a caption-only click draw).
    private var currentStatus = ""
    private var shownStatus = ""
    private var shownAccentHex = ""
    private var ringEligibleForCaption = true
    // Per-draw decisions for the current one-shot, set by highlight/highlightWindow
    // and read by show/reposition/armDismissListeners. The ring and the caption are
    // gated independently now: `drawsRing` false = caption-only (style .off but a
    // label to show); `drawsCaption` false = plain ring (caption suppressed for this
    // draw). At least one is always true when a highlight actually starts.
    private var drawsRing = true
    private var drawsCaption = false
    // ★ Focus-follow visibility for a 常驻 (forever) caption: "常驻显示" means it stays
    // up for as long as you are ON that terminal — not that it hangs over the screen
    // while you work elsewhere. `captionParked` = currently faded out because focus
    // left the pane (alpha, NOT orderOut: re-ordering would re-seat the window on the
    // CURRENT Space and leak the overlay off its terminal's Space). `unfocusedTicks`
    // debounces the AX side of the test — a single failed pane resolve is often just
    // a tree hiccup, so only a second consecutive miss parks it (leaving the app
    // outright is unambiguous and parks immediately).
    private var captionParked = false
    private var unfocusedTicks = 0
    // ★ Host whitelist — the backstop that makes "高亮/标签只在受支持的 App 上出现" true no
    // matter which upstream check slipped (改这里前必读).
    //
    // Every park reason above keys off something INDIRECT (focus reports, AX pane
    // identity, anchor window numbers, Dock layers). Each is individually reasonable and
    // each has a failure mode where it silently says "still fine" — and because the
    // overlays are `.floating` whenever their anchor window can't be resolved, one such
    // miss puts a glowing ring or a 常驻 caption on top of Chrome, Finder, Warp, whatever
    // you actually switched to. That is the user-visible bug ("很多奇奇怪怪的地方也突然显示
    // 高亮"), and chasing it one predicate at a time just moves the leak around.
    //
    // So the visible-alpha decision carries one direct, un-fakeable precondition: the app
    // in FRONT right now must be this overlay's own host, and that host must be one of the
    // six we support. Everything else — including hosts we might add later but haven't
    // taught the ring about — draws nothing. Deliberately a hard list, not a heuristic.
    private static let supportedHostBundleIds: Set<String> = {
        var s = Set(EditorApp.allCases.map { $0.rawValue })   // VS Code / Cursor / Windsurf
        s.insert(TerminalApp.terminal.rawValue)               // Terminal.app
        s.insert(TerminalApp.iterm.rawValue)                  // iTerm
        s.insert("com.anthropic.claudefordesktop")            // Claude desktop app
        return s
    }()

    // Raw test: the app in front right now is this overlay's host, and that host is one
    // of the six supported ones.
    private func hostFrontNow() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return bid == ringAppBundleId && Self.supportedHostBundleIds.contains(bid)
    }

    // ★ The grace belongs to JUMPS ONLY (改这里前必读). A jump raises the target app and
    // then resolves the pane, so show() can land in a beat where we aren't frontmost yet;
    // parking there blinks the overlay on arrival, hence one second of faith from when it
    // appeared (`shownAt` — armedAt is already stale by then, see applyCaptionFocus).
    //
    // Every OTHER draw is reactive to something you did inside the host — you clicked
    // that terminal, or you just interrupted a turn in it — so the host is frontmost
    // already and the grace buys nothing. It does cost something, though: flashPaused
    // fires with no click at all, so a graced draw would flash a full second over
    // whatever app you were actually in. No grace, no flash.
    private func hostIsFrontmost() -> Bool {
        if armedByJump, Date().timeIntervalSince(shownAt) <= 1 { return true }
        return hostFrontNow()
    }
    // ★ Mission Control / Show Desktop park (see systemOverlayActive): while the系统
    // pulls every window off the desktop, our overlays are windows too and would sit
    // there over the shuffled thumbnails / bare wallpaper. Parked at alpha 0 for the
    // duration and restored to whatever they were showing before — the caption's
    // focus-follow state is frozen while parked, so "回来如果之前就显示那就显示" holds.
    private var systemParked = false
    // Same idea, narrower trigger: the one-shot's own anchor window is off screen
    // (minimized / ⌘H / another Space / pushed off every display), so the pane it
    // marks isn't there to mark. One-shot only — see probeVisibility.
    private var targetOffScreen = false
    // Last visibility written to ring-diag.log, so the 0.2s alpha sync logs FLIPS only.
    private var loggedVisible: Bool?
    private var systemWatch: Timer?
    // The app the current ring belongs to — the activation dismiss-guard keeps the
    // ring alive while THIS app is frontmost (VSCode for terminal jumps, Claude
    // desktop for the desktop-app ring) and dismisses when you switch elsewhere.
    private var ringAppBundleId = "com.microsoft.VSCode"

    private static let padX: CGFloat = 14    // hug the terminal's left/right edges, not just the text area
    private static let padY: CGFloat = 5     // vertical breathing room stays tight (original feel)
    static let winPad: CGFloat = -5  // the desktop-window ring sits INSIDE the frame edge — a fullscreen window fills the screen, so an outward ring would be clipped offscreen
    static let termWinPad: CGFloat = 4  // native terminal windows aren't fullscreen — a small outward pad gives the jump ring a slightly roomier frame
    private static let margin: CGFloat = 24  // room inside the window for the glow / ripples
    // Per-ring outward pad for the one-shot ring — the terminal pane wants the
    // asymmetric 14/5 (loose sides, tight top/bottom), but the desktop window
    // wants an even, snug hug, so highlight()/highlightWindow() set these before
    // show()/reposition() read them.
    private var ringPadX: CGFloat = 14
    private var ringPadY: CGFloat = 5

    // ★ Pane-frame memo — what makes a JUMP's ring/caption appear at 0ms (改 paneMemo /
    // recallPane / present 的 predicted 分支前必读).
    //
    // A jump's ring used to wait out three serial things before it could be drawn: the
    // window raise's AX IPC, the extension receiving focus-request and running term.show
    // (which writes the active-terminal token), and Electron's a11y tree catching up so
    // kAXFocusedUIElement finally resolves to that pane — only then does poll()'s triple
    // identity check pass, ~250-450ms in. That whole wait answers WHERE, never WHICH: the
    // target shellPid came from the row that was clicked, exact from the first instant.
    //
    // And WHERE we already measured, the last time this pane was ringed — a pane only
    // moves when the window moves/resizes or its splits are rearranged. So remember the
    // rect, draw from memory immediately on the next jump, and let the poll keep running
    // to confirm and (if needed) slide the ring onto the measured rect.
    //
    // "圈错比不圈更糟" still rules, so a memo is only usable after recallPane's three
    // gates, and a prediction the poll never confirms is taken back (predictionGuard).
    private struct PaneMemo {
        let axRect: CGRect        // pane frame, AX global top-left coords
        let windowNumber: Int     // the editor window it was measured in
        let windowBounds: CGRect  // that window's CG bounds at measure time (staleness test)
        let at: Date
    }
    private var paneMemo: [pid_t: PaneMemo] = [:]
    private static let memoTTL: TimeInterval = 30 * 60
    // Throttle for the memo warm-up scan (see warmPaneMemo).
    private var lastWarmScan: Date = .distantPast
    private static let warmInterval: TimeInterval = 3

    // Budgets for the background-window sweep (see sweepOtherWindows). Everything it
    // finds is a nice-to-have — a miss only costs the old ~250-450ms resolve — so every
    // number here errs toward giving up rather than toward completeness.
    private static let sweepInterval: TimeInterval = 30      // between rounds
    private static let sweepBackoffCap: TimeInterval = 300   // barren window's ceiling
    private static let sweepBudget: TimeInterval = 0.4       // whole round
    private static let sweepWindowBudget: TimeInterval = 0.15
    private static let sweepTimeout: Float = 0.5             // AX messaging, per call
    private static let sweepWindowCap = 3
    private static let sweepJumpGrace: TimeInterval = 3       // keep off `queue` around a jump
    /// Per-window sweep bookkeeping. `bounds`/`sessionKey` are what the last verdict was
    /// based on: when either changes the answer may too, so the backoff is dropped.
    private struct SweepProbe {
        let nextAt: Date
        let misses: Int
        let bounds: CGRect
        let sessionKey: String
    }
    /// Touched on `queue` only.
    private var lastSweep: Date = .distantPast
    private var sweepProbes: [CGWindowID: SweepProbe] = [:]
    /// Which manifest file (= which VSCode window's extension host) a window's terminals
    /// live in — see loadManifests. Touched on `queue` only.
    private var windowManifest: [CGWindowID: String] = [:]
    /// The `monaco-list-rows` element of each window's terminal TAB LIST — the vertical
    /// strip of terminal icons down the side of the panel. Cached as an AXUIElement, not
    /// re-found each pass, because finding it costs a tree walk while re-reading it costs
    /// one children call: the rows move (scroll, a terminal opened or closed, the strip
    /// widened) far more often than a deep pass is allowed to run, so a dot on a row has
    /// to be re-measured on the cheap schedule or it drifts onto the wrong row. The
    /// reference stays valid for as long as the DOM node lives; when it dies the read
    /// comes back empty and the entry is dropped, which is also how "the panel was
    /// collapsed" is noticed. Touched on `queue` only.
    private var tabLists: [CGWindowID: AXUIElement] = [:]
    // shellPid of a prediction that is on screen but not yet confirmed by poll (0 = none).
    private var predictedTarget: pid_t = 0
    private var predictionGuard: DispatchWorkItem?

    private init() {}

    // Expand each running VSCode-family editor's renderer a11y tree ahead of time
    // (first expansion takes 1-3s; done at jump time it loses the race against the
    // user's next click). Warms every running editor (VSCode / Cursor / Windsurf);
    // an editor started later gets warmed by the first jump's poll instead (one slow
    // jump, still correct). Idempotent — reruns are cheap AX writes.
    func prewarm() {
        queue.async {
            for editor in EditorApp.allCases {
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: editor.rawValue).first else { continue }
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.5)
                AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
        }
    }

    // Start highlighting: arm the dismiss listeners NOW (a keystroke while the
    // pane is still resolving means the user is already typing — the ring's
    // purpose is over before it appeared), then resolve the target rect async.
    // `targetShellPid` is the terminal the companion extension was asked to
    // focus; pass 0 when it wasn't (no extension) to go straight to the window
    // fallback.
    func highlight(vscodePid pid: pid_t, targetShellPid: pid_t, status: String,
                   editorBundleId: String = EditorApp.vscode.rawValue,
                   strictToken: Bool = true, fromJump: Bool = false,
                   project: String = "", task: String = "", icon: LogoBadge.Mode? = nil,
                   ringEligible: Bool = true, captionEligible: Bool = true) {
        guard AppSettings.highlightsEnabled else { return }
        let style = AppSettings.ringStyle(for: status)
        // Ring and caption are gated independently. The ring draws when its per-status
        // style isn't .off AND the caller allows it (jumps always do; a manual click
        // only when ringOnFocusClick). The caption draws when it's enabled, has text,
        // AND the caller allows it (jumps always; a manual click only when
        // captionOnFocusClick) — so a label can appear with the ring off, and a ring
        // with the label off. Nothing to draw → bail before the AX work (the path a
        // click on a plain non-session terminal, status "idle" styled .off, takes).
        let showRing = ringEligible && style != .off
        let showCaption = captionEligible && AppSettings.captionEnabled
            && !(project.isEmpty && task.isEmpty)
        guard showRing || showCaption else { return }
        // Record the arm source before the always-on branch so both ring modes see
        // it. A manual click (fromJump: false) clears the jump-suppression window so
        // the NEXT rapid click on a different terminal isn't swallowed.
        armedByJump = fromJump
        drawsRing = showRing
        drawsCaption = showCaption
        // Always-on active: only when a ring is actually wanted (a caption-only draw
        // has style .off, which owns no managed overlay). The target pane already
        // carries a steady ring, so EMPHASIZE it (replay the entrance flourish on the
        // managed overlay) rather than stacking a separate one-shot on top (Phase C3).
        // Falls through to the one-shot ring only when always-on is off, or there's no
        // shellPid to address a managed overlay by (no extension → window ring).
        //
        // ★ It hands off the RING only (改这里前必读). Returning outright is what made the
        // 常驻标签 disappear the moment 常驻高亮 was switched on: the caption is created by
        // show(), which this skipped, so one setting silently killed the other — exactly
        // the "一损俱损" the independent ring/caption gating below was written to end. So
        // emphasize the managed ring, then carry on with drawsRing off to draw the label
        // alone. Bonus: the caption's accent comes from the CALLER's status (the row you
        // clicked), so it is right even for a pane whose owner the always-on scan hasn't
        // pinned yet (see paneIdentityCache).
        if showRing, AppSettings.ringAlwaysOn, targetShellPid > 0 {
            emphasize(shellPid: targetShellPid)
            guard showCaption else { return }
            drawsRing = false
        }
        let accent = Status.accent(status)
        ringLog("arm target=\(targetShellPid) editor=\(pid) jump=\(fromJump) "
                + "ring=\(drawsRing) caption=\(showCaption) status=\(status) strict=\(strictToken)")
        dismiss("replaced-by-arm")
        generation += 1
        let gen = generation
        armedAt = Date()
        currentTarget = targetShellPid
        currentProject = project; currentTask = task; currentIcon = icon
        currentStatus = status; ringEligibleForCaption = ringEligible
        ringAppBundleId = editorBundleId
        ringPadX = Self.padX; ringPadY = Self.padY
        armDismissListeners()
        // ★ Draw from memory NOW, don't wait for the poll to answer a question we already
        // know the answer to (see paneMemo). Excludes only the paused/interrupt flash
        // (strictToken false), which the user didn't aim at anything.
        //
        // ★ Manual clicks used to be excluded too, on the reasoning that "a click's focus
        // is already parked on the pane, so its poll confirms on the first tick anyway"
        // (改这里前必读 — that reasoning held for one kind of click and not the other).
        // It is true when you click INSIDE a pane you can already see. It is false when
        // you click a row of the terminal TAB STRIP to switch terminals: that pane was
        // not on screen a moment ago, so Electron has to build its DOM and then its
        // accessibility subtree before kAXFocusedUIElement can resolve to anything —
        // measured on this machine at `poll miss` × 12-18 ticks, i.e. **2.5-4.7 seconds**
        // of nothing before the ring and its label appear. Long enough that the user
        // reported it as "点了图标过去了，但高亮和 title 都没显示" — by the time it lands
        // you have already found the terminal yourself, and a keystroke dismisses it.
        // The memo answers WHERE without asking the tree, and the target shellPid comes
        // from the extension's exact active-terminal token, so this is the same quality of
        // evidence a jump has.
        if targetShellPid > 0, strictToken {
            if let memo = recallPane(targetShellPid, pid: pid) {
                ringLog("recall hit target=\(targetShellPid) win=\(memo.windowNumber) rect=\(fmt(memo.axRect))")
                predictedTarget = targetShellPid
                // A click needs the longer leash: see armPredictionGuard.
                armPredictionGuard(gen: gen, pid: pid, target: targetShellPid,
                                   accent: accent, style: style,
                                   after: fromJump ? Self.jumpPredictionGrace
                                                   : Self.clickPredictionGrace)
                present(memo.axRect, accent: accent, style: style, gen: gen, pid: pid,
                        target: targetShellPid, isPane: true, predicted: true)
            } else {
                // No memo → nothing is on screen until the poll confirms. When the poll then
                // never confirms either, this is the line that says the blank screen started here.
                ringLog("recall miss target=\(targetShellPid) → blank until poll confirms")
            }
        }
        queue.async { [weak self] in
            self?.poll(pid: pid, gen: gen, attempt: 0, target: targetShellPid,
                       accent: accent, style: style, strictToken: strictToken)
        }
    }

    // Ring the Claude-desktop app's window on a jump to the desktop row. There's
    // no terminal pane or companion extension here — just the whole app window —
    // so this skips the pane resolve and goes straight to the window path (reusing
    // present/track). `bundleId` arms the activation dismiss-guard for THIS app so
    // fronting Claude desktop doesn't instantly dismiss the ring the way a
    // non-VSCode activation would on the terminal path.
    // `pad` is the ring's outward inset from the window frame: negative hugs INSIDE the
    // edge (desktop default — a fullscreen app window would clip an outward ring), a
    // native terminal window isn't fullscreen so it passes a small positive pad for a
    // slightly roomier frame.
    // `fromJump` buys the 1s grace in hostIsFrontmost — needed only when the caller's
    // raise is ASYNC and the ring can therefore be drawn before the host reaches the
    // front (the editor chat panel: raiseEditorWindow runs its AX IPC on jumpQueue).
    // The desktop and native-terminal paths raise synchronously before calling, so they
    // leave it false and stay strict. It also suppresses the flashFocused that VSCode's
    // activation triggers by restoring focus to its last-active terminal — a ring we do
    // not want, on a terminal we did not jump to.
    func highlightWindow(appPid pid: pid_t, bundleId: String, status: String,
                         pad: CGFloat = TerminalFocusRing.winPad,
                         windowID: CGWindowID? = nil, fromJump: Bool = false,
                         project: String = "", task: String = "", icon: LogoBadge.Mode? = nil,
                         ringEligible: Bool = true, captionEligible: Bool = true) {
        guard AppSettings.highlightsEnabled else { return }
        let style = AppSettings.ringStyle(for: status)
        // Same independent ring/caption gating as highlight() — a window jump can land
        // just the caption when the ring style is .off but the label is enabled.
        let showRing = ringEligible && style != .off
        let showCaption = captionEligible && AppSettings.captionEnabled
            && !(project.isEmpty && task.isEmpty)
        guard showRing || showCaption else { return }
        let accent = Status.accent(status)
        ringLog("armWindow app=\(pid) bundle=\(bundleId) wid=\(windowID.map(String.init) ?? "nil") "
                + "jump=\(fromJump) ring=\(showRing) caption=\(showCaption) status=\(status)")
        dismiss("replaced-by-armWindow")
        generation += 1
        let gen = generation
        armedAt = Date()
        currentTarget = 0
        armedByJump = fromJump
        drawsRing = showRing
        drawsCaption = showCaption
        currentProject = project; currentTask = task; currentIcon = icon
        currentStatus = status; ringEligibleForCaption = ringEligible
        ringAppBundleId = bundleId
        ringPadX = pad; ringPadY = pad
        armDismissListeners()
        queue.async { [weak self] in
            self?.pollWindow(pid: pid, wid: windowID, gen: gen, attempt: 0,
                             accent: accent, style: style)
        }
    }

    // Resolve the target window's frame and ring it, retrying a few ticks while the
    // just-activated/deminiaturized window settles. No extension token to consult
    // (that's terminal-only), so unlike poll() this never suppresses on a foreign
    // focus report.
    //
    // `wid` names a SPECIFIC window (the desktop app has several — chat and Design —
    // and the caller's raise is still in flight, so "whatever is focused" would ring
    // the window we're leaving). Without it we keep the app-level guess.
    private func pollWindow(pid: pid_t, wid: CGWindowID?, gen: Int, attempt: Int,
                            accent: NSColor, style: AppSettings.RingStyle) {
        guard gen == currentGeneration() else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let rect = wid.flatMap({ windowFrame(axApp, wid: $0) }) ?? focusedWindowFrame(axApp) {
            present(rect, accent: accent, style: style, gen: gen, pid: pid, target: 0, isPane: false)
            return
        }
        if attempt >= 3 { return }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollWindow(pid: pid, wid: wid, gen: gen, attempt: attempt + 1,
                             accent: accent, style: style)
        }
    }

    // Frame of the app window carrying `wid`, or nil when that window is gone (caller
    // then falls back to the focused window).
    private func windowFrame(_ axApp: AXUIElement, wid: CGWindowID) -> CGRect? {
        guard let wins = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for win in wins {
            var got = CGWindowID(0)
            guard _AXUIElementGetWindow(win, &got) == .success, got == wid else { continue }
            return axFrame(win)
        }
        return nil
    }

    // A jump toward `target` just launched. Seed the dedup state NOW, before the
    // window raise: activating a VSCode window makes it restore focus to its
    // previously-active terminal, and the extension reports that transient focus
    // like any manual click. The jump's own highlight() only arms currentTarget
    // ~400ms in — too late — so without this early arm flashFocused rings the OLD
    // terminal first, then the real target (the "ring flashes on the previous
    // terminal before jumping" bug).
    func armJump(target: pid_t) {
        currentTarget = target
        armedAt = Date()
        armedByJump = true
    }

    // The user manually clicked into a terminal (reported by the extension's
    // active-terminal write) — flash the ring there once. Skipped when a jump
    // to this same terminal is already highlighting it: the extension's focus
    // report always trails a jump, and restarting the animation would stutter.
    // With always-on active this routes through highlight → emphasize, so a
    // manual click replays the flourish on that pane's steady ring.
    func flashFocused(vscodePid pid: pid_t, shellPid: pid_t, status: String,
                      editorBundleId: String = EditorApp.vscode.rawValue,
                      project: String = "", task: String = "", icon: LogoBadge.Mode? = nil,
                      ringEligible: Bool = true, captionEligible: Bool = true) {
        let sinceArm = Date().timeIntervalSince(armedAt)
        if shellPid == currentTarget && sinceArm < 8 { return }
        // A FOREIGN pid right after a JUMP armed is the raise's restore-focus
        // side effect (VSCode re-focuses its last-active terminal before
        // term.show selects the target) — not a user click. Gated on armedByJump:
        // after a manual click this must NOT fire, or rapid clicks across
        // different terminals would swallow every one after the first. Short
        // window only: a genuine click elsewhere later still flashes.
        if armedByJump && currentTarget > 0 && sinceArm < 1.5 { return }
        // The two toggles ride through as eligibility: ringOnFocusClick → ringEligible,
        // captionOnFocusClick → captionEligible, so a click can flash the ring, the
        // caption, or both per the user's independent switches.
        highlight(vscodePid: pid, targetShellPid: shellPid, status: status,
                  editorBundleId: editorBundleId, project: project, task: task, icon: icon,
                  ringEligible: ringEligible, captionEligible: captionEligible)
    }

    // A session just entered "paused" (interrupted — No/Esc on a permission prompt,
    // or Ctrl+C on a running turn). Flash a one-shot fuchsia ring on its terminal
    // pane, but ONLY if you're still parked there (you just pressed the key). Unlike
    // flashFocused, the interrupt wrote NO fresh active-terminal token, so this uses
    // the lenient token path (strictToken: false → anyFocusReport ignores mtime); the
    // live xterm-textarea check inside focusedTerminalPaneFrame still guarantees it
    // draws nothing once focus has moved elsewhere, so it never rings the wrong pane.
    func flashInterrupted(vscodePid pid: pid_t, shellPid: pid_t,
                          editorBundleId: String = EditorApp.vscode.rawValue,
                          project: String = "", task: String = "", icon: LogoBadge.Mode? = nil) {
        NSLog("TB-DBG flashInterrupted called shellPid=%d currentTarget=%d sinceArm=%.1f",
              shellPid, currentTarget, Date().timeIntervalSince(armedAt))
        if shellPid == currentTarget && Date().timeIntervalSince(armedAt) < 8 { return }
        highlight(vscodePid: pid, targetShellPid: shellPid, status: "paused",
                  editorBundleId: editorBundleId, strictToken: false,
                  project: project, task: task, icon: icon)
    }

    // The transient ring's reason to exist is a session sitting at needs/paused
    // (a permission prompt / an interrupt). Once it leaves that state — you answered
    // the prompt, or typed after the interrupt — kill the breathing ring on THAT
    // terminal at once instead of letting it ride out its lifetime. Gated on
    // `currentTarget == shellPid` so an unrelated session's transition never clears a
    // ring you still need, and on `window != nil` so it only ever touches the one-shot
    // ring — never an always-on managed overlay (those recolor on status change, they
    // don't dismiss). No-op off the main thread's expectations: called from the poll's
    // notifyTransitions, already on main.
    func dismissIfTarget(_ shellPid: pid_t) {
        guard shellPid > 0, currentTarget == shellPid, window != nil else { return }
        // A live caption owns the overlay's lifetime independently of the ring's
        // reason-to-exist: it stays for its full caption duration (or 常驻 = forever)
        // no matter that the target just left needs/paused. Answering the prompt must
        // NOT tear the caption down (the "确认后 title 立马消失" bug) — same principle
        // as armDismissListeners skipping the user-action dismiss hooks with a caption
        // up. Only the plain breathing ring (no caption this draw) dies here.
        guard !drawsCaption else { return }
        dismiss("target-left-needs")
    }

    // `reason` exists purely for ring-diag.log: a dozen call sites tear the overlay down and
    // the user-visible result is identical for all of them, so "圈消失了" is unanswerable
    // without knowing WHICH one fired (a keystroke and an unconfirmed prediction want opposite
    // fixes). Default only covers callers where the reason is genuinely "someone asked".
    func dismiss(_ reason: String = "explicit") {
        if window != nil {
            // shownAt is only stamped by show(); a reposition-only draw leaves it unset, so
            // guard rather than print an astronomical age.
            let alive = shownAt == .distantPast
                ? "n/a" : String(format: "%.1fs", Date().timeIntervalSince(shownAt))
            ringLog("dismiss reason=\(reason) target=\(currentTarget) alive=\(alive)")
        }
        generation += 1   // abort any in-flight poll
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        disarmAnchorReassert()
        disarmCaptionHover()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        timeoutWork?.cancel(); timeoutWork = nil
        predictedTarget = 0
        predictionGuard?.cancel(); predictionGuard = nil
        spaceBound = false
        captionParked = false
        loggedVisible = nil
        unfocusedTicks = 0
        targetOffScreen = false   // per-overlay; systemParked is global and stays
        shownAt = .distantPast
        shownTarget = nil
        anchorWindowNumber = 0
        anchorResolvedAt = .distantPast
        closeButton?.orderOut(nil); closeButton = nil
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    // MARK: Z-order anchoring (stick to the target window's depth)

    // CG window (number + bounds) of `pid`'s layer-0 window containing the AX rect's
    // center (AX frames and kCGWindowBounds share the global top-left coordinate space),
    // falling back to that app's frontmost on-screen window. nil when none is on screen
    // (app hidden / other Space) — callers must NOT overwrite a still-valid anchor with
    // that. Thread-safe (pure CGWindowList query), callable off-main. The bounds ride
    // along for the pane memo's staleness test (a window that moved or resized relaid
    // out every pane inside it).
    private func editorWindowInfo(pid: pid_t, containingAX rect: CGRect) -> (number: Int, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var frontmost: (number: Int, bounds: CGRect)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: d) else { continue }
            if frontmost == nil { frontmost = (num, bounds) }
            if bounds.contains(center) { return (num, bounds) }
        }
        return frontmost
    }

    // MARK: Pane memo (instant jump ring — see paneMemo)

    // Record where a pane was actually measured, so the next jump to it can draw there
    // before the poll confirms. Main thread only (paneMemo has no lock).
    private func rememberPane(_ shellPid: pid_t, axRect: CGRect,
                              window: (number: Int, bounds: CGRect)?) {
        guard shellPid > 0, let win = window, win.number > 0 else { return }
        paneMemo[shellPid] = PaneMemo(axRect: axRect, windowNumber: win.number,
                                      windowBounds: win.bounds, at: Date())
    }

    // A memo safe to draw from, or nil. Three gates, each about "could the remembered
    // rect have moved since we measured it":
    //   ① fresh enough — past the TTL it's a coin flip, and a jump is not the place to bet;
    //   ② its window is still ON SCREEN — the onscreen window list covers only the CURRENT
    //      Space, so this also confines predictions to same-Space jumps: a cross-Space jump
    //      has a switch animation to wait out anyway, and drawing at the target's absolute
    //      coords before the switch would put a ring somewhere arbitrary on the Space you
    //      are leaving (and bindToActiveSpace would then bind it to the WRONG Space);
    //   ③ that window's bounds are UNCHANGED — moving or resizing it relayouts every pane
    //      inside, which is precisely how a remembered rect goes wrong.
    // A split rearranged inside an unmoved window still slips through; the poll's
    // confirmation slides the ring over within ~0.3s, and a prediction that never gets
    // confirmed is withdrawn by predictionGuard.
    private func recallPane(_ shellPid: pid_t, pid: pid_t) -> PaneMemo? {
        guard let memo = paneMemo[shellPid],
              Date().timeIntervalSince(memo.at) < Self.memoTTL,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowNumber as String] as? Int) == memo.windowNumber,
                  (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: d) else { continue }
            return bounds.equalTo(memo.windowBounds) ? memo : nil
        }
        return nil   // window not on screen (other Space / minimized) → don't guess
    }

    // A prediction is an unverified claim. Give poll() 2s to confirm it (it normally
    // lands in ~0.3s, and a slow term.show can be re-sent up to ~1.9s by
    // verifyTerminalFocus); if it doesn't, the pane isn't where we drew — the splits
    // changed, the terminal moved to another tab — and a ring on the wrong rect is worse
    // than no ring, so take it back rather than let it breathe out its full lifetime.
    //
    // ★ Withdrawing RESTARTS the resolve (改这里前必读). dismiss() bumps the generation,
    // which is how it aborts the in-flight poll — so withdrawing alone would end the
    // highlight outright, and a jump whose pane simply took a while to settle would end
    // up showing NOTHING, worse than the wait this whole path exists to remove. Re-arm
    // the dismiss hooks (dismiss just removed them) and poll again from attempt 0, i.e.
    // hand the highlight back to exactly the state it had before the prediction.
    // `armedAt` is deliberately NOT re-stamped: the extension's token was written for
    // this jump and freshFocusReport must keep accepting it.
    // ★ How long a prediction may stand before the poll has to have confirmed it.
    // A JUMP's poll normally lands in ~0.3s, so 2s is already generous. A CLICK that
    // switched terminals via the tab strip has to wait out a cold accessibility subtree
    // (measured 2.5-4.7s), and 2s there is not a safety margin — it undercuts the very
    // poll that would confirm the ring, withdraws it, and restarts the resolve from
    // attempt 0, which is the "圈闪一下就没了、过几秒又回来" shape. The guard exists to
    // take back a ring the poll says is WRONG; withdrawing while the poll is still
    // legitimately running says nothing of the sort. So the click's leash covers the
    // poll's own budget (28 ticks ≈ 6s) plus a margin.
    private static let jumpPredictionGrace: TimeInterval = 2
    private static let clickPredictionGrace: TimeInterval = 6.5

    private func armPredictionGuard(gen: Int, pid: pid_t, target: pid_t,
                                    accent: NSColor, style: AppSettings.RingStyle,
                                    after: TimeInterval = jumpPredictionGrace) {
        predictionGuard?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, gen == self.generation, self.predictedTarget > 0 else { return }
            // The "圈显示了一下就消失" shape: 2s passed and no poll tick ever confirmed the
            // predicted rect. The withdrawal itself is fine — the reason the poll never
            // confirmed is what the poll lines above are for.
            self.ringLog("prediction UNCONFIRMED target=\(target) → withdraw + re-poll")
            self.predictedTarget = 0
            self.dismiss("prediction-withdraw")
            let next = self.generation
            self.armDismissListeners()
            self.queue.async { [weak self] in
                self?.poll(pid: pid, gen: next, attempt: 0, target: target,
                           accent: accent, style: style)
            }
        }
        predictionGuard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    // Re-place the overlay directly above its anchor window. Idempotent and cheap
    // (a pure window-server reorder); called every track tick so a raise of the
    // target app — which lifts its window above ours — puts the ring/caption back
    // within ~0.2s, while an app in front of the terminal stays in front.
    private func reassertAnchor() {
        guard anchorWindowNumber > 0, let w = window else { return }
        w.order(.above, relativeTo: anchorWindowNumber)
        closeButton?.order(.above, relativeTo: w.windowNumber)
    }

    // ★ Re-assert on click, not just on the 0.2s tick (the "常驻 title 点别的地方就闪
    // 一下" bug —改 reassert 节奏前必读). The anchored overlay rides just ABOVE the
    // target window at .normal level, so ANY click into that window (editor, sidebar,
    // titlebar — not just terminals) makes AppKit order that window front, i.e. ABOVE
    // us, and the ring/caption is COVERED until the next track tick pulls it back:
    // a ~0.2s blackout the user reads as a blink. A timed caption rarely outlives a
    // click, but a 常驻 one does — so every click into the editor blinked it, all day.
    // Fix = re-assert straight off the click. The raise can land slightly AFTER the
    // mouseDown we observe (AppKit orders the window during event dispatch, and the
    // target app's own ordering is async to us), so fire a short burst instead of a
    // single call — reassertAnchor is an idempotent window-server reorder, cheap
    // enough to spam a few times per click. Deliberately NOT a faster track loop:
    // that tick also does AX tree queries, which are anything but cheap.
    private func armAnchorReassert() {
        guard anchorClickGlobal == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let onClick: (NSEvent) -> Void = { [weak self] _ in self?.reassertBurst() }
        anchorClickGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: onClick)
        anchorClickLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            onClick(event); return event
        }
    }

    private func disarmAnchorReassert() {
        if let m = anchorClickGlobal { NSEvent.removeMonitor(m); anchorClickGlobal = nil }
        if let m = anchorClickLocal { NSEvent.removeMonitor(m); anchorClickLocal = nil }
    }

    // Anchor unresolved (0) = the overlay is on the .floating fallback path, which no
    // raise can cover — nothing to re-assert.
    private func reassertBurst() {
        guard anchorWindowNumber > 0, window != nil else { return }
        for delay in [0.0, 0.04, 0.10, 0.18] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reassertAnchor()
            }
        }
    }

    // MARK: Dismiss triggers

    // Typing ends the highlight, and so does a click INSIDE the ringed pane
    // (e.g. mouse-answering a permission prompt there — the ring's job is done;
    // letting it breathe on over the pane you're now using reads as stale).
    // Clicks OUTSIDE deliberately do NOT dismiss: clicking around other
    // terminals is the hunt the ring exists to guide. Global monitor covers
    // events delivered to other apps (VSCode itself — needs Accessibility,
    // which the app already holds); the local one covers our own windows.
    // Cmd-Tab never reaches monitors (system-reserved), so switching away is
    // caught by the app-activation observer instead.
    private func armDismissListeners() {
        // Leaving the target's Space no longer DISMISSES the overlay — it FOLLOWS the
        // Space instead (bindToActiveSpace re-binds it to the target Space so macOS
        // hides it when you leave and shows it again when you return). So there is no
        // activeSpaceDidChange dismiss hook here; teardown is the hold timer (caption
        // duration / ring lifetime), typing/click, app-switch, or the next highlight.
        //
        // With a caption showing, its lifetime is governed SOLELY by the caption
        // duration (or forever) — the user asked that typing not dismiss it and that
        // "常驻" stay up. So skip these user-action dismiss hooks (keystroke / click /
        // app-switch); teardown is the hold timer or the next highlight replacing it.
        // These hooks stay for the plain ring (caption off / suppressed this draw).
        guard !drawsCaption else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown]
        let onEvent: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            if event.type == .keyDown { self.dismiss("keydown"); return }
            if let r = self.shownTarget, r.contains(NSEvent.mouseLocation) { self.dismiss("click-inside") }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: onEvent)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            onEvent(event)
            return event
        }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier
            // OUR OWN activation is never "the user moved on" — it's the click that
            // ordered this jump. Clicking a row in an inactive window activates
            // SpectiX, and that notification lands just AFTER we arm here, so
            // treating it like any other app killed the ring the instant it was drawn
            // (the "no ring after clicking a 需确认 row" bug). Ignore self and wait for
            // a real switch away.
            if bid == Bundle.main.bundleIdentifier { return }
            if bid != self?.ringAppBundleId { self?.dismiss("app-switch → \(bid ?? "nil")") }
        })
    }

    // MARK: Target resolution (background queue — AX calls can block)

    private func poll(pid: pid_t, gen: Int, attempt: Int, target: pid_t,
                      accent: NSColor, style: AppSettings.RingStyle, strictToken: Bool = true) {
        guard gen == currentGeneration() else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // strictToken=false (paused/interrupt flash): accept the last-focused pid even
        // from a stale token — the interrupt didn't rewrite it. focusedTerminalPane
        // still requires focus to BE an xterm textarea, so a moved-on focus draws nothing.
        //
        // ★ Double identity check: the token alone is NOT enough. Electron's AX tree
        // update LAGS the extension's token write — right after term.show the token
        // already names the target while kAXFocusedUIElement still resolves to the
        // PREVIOUSLY focused terminal's textarea, so both conditions pass yet describe
        // different panes (the "ring lights on the old terminal, then slides over"
        // bug). paneOwner() reads the focused pane's own title and maps it through the
        // extension manifest back to a shellPid — the pane's identity card. A foreign
        // owner keeps polling (the next tick sees the settled focus); an unresolvable
        // title (non-Claude pane, unknown locale) degrades to the token-only behavior.
        let report = strictToken ? freshFocusReport() : anyFocusReport()
        if !strictToken, attempt == 0 {
            let pane = focusedTerminalPane(axApp)
            let title = pane.flatMap { paneTitle(of: $0.textarea) }
            let owner = pane.flatMap { paneOwner($0.textarea, window: focusedWindowID(axApp)) }
            NSLog("TB-DBG flashInterrupt poll target=%d report=%@ pane=%@ title=%@ owner=%@",
                  target, report.map(String.init) ?? "nil",
                  pane != nil ? "yes" : "no", title ?? "nil",
                  owner.map { $0.map(String.init).joined(separator: ",") } ?? "nil")
        }
        // Diagnostics sample the two EXPENSIVE judgements (focused-pane resolve + manifest
        // owner lookup) on every 4th tick only (~0.5s). They are most of a miss tick's cost,
        // and the working path must not pay twice for a line nobody reads when it works.
        // Attempt 0 always prints, so a highlight that misses from the first tick still says so.
        let sampled = attempt % 4 == 0
        if target > 0, report == target, let pane = focusedTerminalPane(axApp) {
            let owner = paneOwner(pane.textarea, window: focusedWindowID(axApp))
            if owner.map({ $0.contains(target) }) != false {
                ringLog("poll HIT a=\(attempt) target=\(target) rect=\(fmt(pane.frame)) owner=\(fmt(owner))")
                present(pane.frame, accent: accent, style: style, gen: gen, pid: pid, target: target,
                        isPane: true, strictToken: strictToken)
                return
            }
            // Token right, focus IS a terminal pane, but the pane belongs to someone else.
            // Repeating for the full ~6s means focus never reached the window we raised —
            // check raiseEditorWindow's `focus wid=… → ok/err` line in jump-diag.log.
            if sampled {
                ringLog("poll miss a=\(attempt) target=\(target) report=\(fmt(report)) "
                        + "pane=true owner=\(fmt(owner)) ← owner veto")
            }
        } else if target > 0, report == target, let rect = tabRowPane(of: target, axApp: axApp) {
            ringLog("poll HIT via tab row a=\(attempt) target=\(target) rect=\(fmt(rect))")
            present(rect, accent: accent, style: style, gen: gen, pid: pid, target: target,
                    isPane: true, strictToken: strictToken)
            return
        } else if sampled {
            let pane = focusedTerminalPane(axApp)
            let owner = pane.flatMap { paneOwner($0.textarea, window: focusedWindowID(axApp)) }
            ringLog("poll miss a=\(attempt) target=\(target) report=\(fmt(report)) "
                    + "pane=\(pane != nil) owner=\(fmt(owner))")
        }
        // Pane path: poll up to ~6s — covers a cold tree expansion AND the user
        // hunting through wrong terminals before landing on the right one (the
        // ring then lights up as confirmation). Early ticks are fast (0.12s): the
        // token typically lands ~200-400ms into a jump and the ring should appear
        // on the very next tick, not a coarse 0.25s later. Window path (no
        // extension): just let the raise/Space switch settle a couple of ticks.
        let limit = target > 0 ? 28 : 2
        if attempt >= limit {
            // ★ The window ring is for the NO-PANE case ONLY (target 0 = no extension,
            // so the window IS the intended landing from the start). When a specific
            // pane WAS requested, a timeout means we never confirmed it — and framing
            // the whole editor instead is the "高亮圈住整个 VSCode 页面而不是里面的
            // terminal" bug: click a terminal, then click into the editor/sidebar and
            // the token stays fresh naming that terminal (only another TERMINAL rewrites
            // it) while the focused element is no longer an xterm textarea, so every
            // tick misses and ~6s later a giant frame lands over the whole window —
            // long after you already found the terminal yourself. Draw nothing.
            guard target == 0 else {
                ringLog("poll GIVE UP a=\(attempt) target=\(target) report=\(fmt(report)) → draw nothing")
                return
            }
            // A fresh report naming a DIFFERENT terminal = the user consciously
            // went elsewhere; a window ring would only mislead. Otherwise (no
            // report at all — extension dead, or AX never yielded the textarea)
            // the window is still honest, useful guidance.
            if let r = report, r != target { return }
            if let rect = focusedWindowFrame(axApp) {
                present(rect, accent: accent, style: style, gen: gen, pid: pid, target: target,
                        isPane: false, strictToken: strictToken)
            }
            return
        }
        // Fast early ticks are pane-path only; the window fallback keeps the coarse
        // 0.25s so the raise/Space switch settles before its frame is read.
        let tick = (target > 0 && attempt < 8) ? 0.12 : 0.25
        queue.asyncAfter(deadline: .now() + tick) { [weak self] in
            self?.poll(pid: pid, gen: gen, attempt: attempt + 1, target: target,
                       accent: accent, style: style, strictToken: strictToken)
        }
    }

    private func currentGeneration() -> Int {
        var g = 0
        DispatchQueue.main.sync { g = self.generation }
        return g
    }

    // The extension's "<shellPid>:<nonce>" active-terminal report, but only when
    // written for THIS jump (mtime ≥ armedAt − 3s slack: the extension may write
    // during raiseVSCodeWindow, slightly before highlight() stamps armedAt).
    // Stale reports are yesterday's news — never identity evidence.
    private func freshFocusReport() -> pid_t? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenPath),
              let mtime = attrs[.modificationDate] as? Date,
              mtime >= armedAt.addingTimeInterval(-3),
              let text = try? String(contentsOfFile: tokenPath, encoding: .utf8),
              let head = text.split(separator: ":").first,
              let pid = pid_t(head), pid > 0 else { return nil }
        return pid
    }

    // Like freshFocusReport but WITHOUT the mtime freshness gate: the last-focused
    // terminal's shellPid regardless of when the token was written. For the paused/
    // interrupt flash, which no jump/click triggered (so no fresh token exists) — yet
    // if you're still on that terminal (you just pressed No/Ctrl+C), its pid is still
    // the last one reported. Safe because focusedTerminalPaneFrame independently
    // requires focus to still BE an xterm textarea: move focus away and this pid may
    // match but the pane resolve fails, so nothing is drawn.
    private func anyFocusReport() -> pid_t? {
        guard let text = try? String(contentsOfFile: tokenPath, encoding: .utf8),
              let head = text.split(separator: ":").first,
              let pid = pid_t(head), pid > 0 else { return nil }
        return pid
    }

    // Focused element must be xterm's hidden input textarea, then walk up to the
    // first ancestor with a real on-screen extent (= .xterm-screen, the pane).
    // Returns the textarea too so callers can verify the pane's OWNER (paneOwner).
    private func focusedTerminalPane(_ axApp: AXUIElement) -> (frame: CGRect, textarea: AXUIElement)? {
        guard let focused = copyAttr(axApp, kAXFocusedUIElementAttribute) else { return nil }
        let el = focused as! AXUIElement
        let classes = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
        guard classes.contains(where: { $0.contains("xterm-helper-textarea") }) else { return nil }
        guard let frame = paneFrame(fromTextarea: el) else { return nil }
        return (frame, el)
    }

    // Is keyboard focus sitting on `target`'s own row in the terminal tab strip?
    //
    // Both shapes have to be recognised, because which one you get depends on where in
    // the row the click landed: the focused element may be the ROW itself (its
    // AXDescription reads `Terminal N <title>`) or the LIST that owns it, in which case
    // the selected row carries the description instead. So walk up a few levels looking
    // for the strip's container, then take the identity from the focused element if it
    // has one and from the selected row otherwise.
    //
    // Identity is checked the same two ways a pane's is (see resolveOwner): the learned
    // pin for `终端 N` first, then the manifest candidates for the row's title. Neither
    // answering = don't hold. Called on `queue`, and only on the tick where the pane
    // check already missed, so it costs nothing in the steady state.
    private func focusIsOnTabRow(of target: pid_t, axApp: AXUIElement) -> Bool {
        focusedTabRow(of: target, axApp: axApp) != nil
    }

    // The pane shown for `target` when focus sits on its tab-strip row. VSCode's default
    // `terminal.integrated.tabs.focusMode` is doubleClick: a single click on a row swaps
    // the pane in but leaves keyboard focus on the list, so focusedTerminalPane never
    // resolves and, with no memo (first visit since launch), the ring and caption never
    // appear until you click into the pane itself. The row's `Terminal N` and the pane's
    // `终端 N` are the same instanceId, so matching on N names the pane exactly — no
    // title guessing, and a split's other pane can't be picked by mistake.
    private func tabRowPane(of target: pid_t, axApp: AXUIElement) -> CGRect? {
        guard let row = focusedTabRow(of: target, axApp: axApp), let index = row.index else { return nil }
        var cur = row.strip
        var terminalPart: AXUIElement?
        for _ in 0..<10 {
            let classes = (copyAttr(cur, "AXDOMClassList") as? [String]) ?? []
            if classes.contains("integrated-terminal") { terminalPart = cur; break }
            guard let parent = copyAttr(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
        }
        guard let part = terminalPart else { return nil }
        var textareas: [AXUIElement] = []
        collectXtermTextareas(part, into: &textareas, depth: 0)
        for ta in textareas where paneIdentity(of: ta)?.index == index {
            return paneFrame(fromTextarea: ta)
        }
        return nil
    }

    private func focusedTabRow(of target: pid_t, axApp: AXUIElement) -> (strip: AXUIElement, index: Int?)? {
        guard let focused = copyAttr(axApp, kAXFocusedUIElementAttribute) else { return nil }
        var el = focused as! AXUIElement
        var strip: AXUIElement?
        for _ in 0..<6 {
            let classes = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
            if classes.contains("tabs-list-container") { strip = el; break }
            guard let parent = copyAttr(el, kAXParentAttribute) else { break }
            el = parent as! AXUIElement
        }
        guard let strip = strip else { return nil }
        let desc = (copyAttr(focused as! AXUIElement, kAXDescriptionAttribute) as? String) ?? ""
        let ident = tabRowIdentity(desc) ?? selectedTabRowIdentity(strip)
        guard let ident = ident else { return nil }
        if let index = ident.index, let wid = focusedWindowID(axApp),
           let pinned = paneIdentityCache[wid]?[index] {
            return pinned == target ? (strip, index) : nil
        }
        // No pin for this row's number: fall back to the manifest, the same permissive
        // check paneOwner makes — with several sessions sharing one name every candidate
        // "matches", which here costs at most one extra tick of a held overlay.
        guard let pids = loadManifestNameToPid()[normalize(ident.title)],
              pids.contains(target) else { return nil }
        return (strip, ident.index)
    }

    // The `monaco-list-row` marked selected inside the tab strip, as an identity.
    private func selectedTabRowIdentity(_ strip: AXUIElement, depth: Int = 0) -> PaneIdentity? {
        guard depth < 6, let kids = copyAttr(strip, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for kid in kids {
            let classes = (copyAttr(kid, "AXDOMClassList") as? [String]) ?? []
            if classes.contains("monaco-list-row"), classes.contains("selected"),
               let desc = copyAttr(kid, kAXDescriptionAttribute) as? String,
               let ident = tabRowIdentity(desc) {
                return ident
            }
            if let hit = selectedTabRowIdentity(kid, depth: depth + 1) { return hit }
        }
        return nil
    }

    // The shellPids owning a pane, resolved from its own title via the extension
    // manifest (paneTitle → terminals-<wid>.json). nil = unverifiable (title absent
    // or unmatched) — callers must treat that as "no evidence", NOT as a mismatch.
    //
    // A name shared by several sessions makes this list useless as an identity check
    // (every candidate "matches"), so a learned pin for the pane's number collapses it
    // to the ONE real owner — see paneIdentityCache. No pin yet → the full candidate
    // list, i.e. the old permissive behavior, which the caller pairs with the token.
    private func paneOwner(_ textarea: AXUIElement, window: CGWindowID?) -> [pid_t]? {
        guard let ident = paneIdentity(of: textarea) else { return nil }
        guard let pids = loadManifestNameToPid()[normalize(ident.title)],
              !pids.isEmpty else { return nil }
        if pids.count > 1, let index = ident.index, let window,
           let pinned = paneIdentityCache[window]?[index], pids.contains(pinned) {
            return [pinned]
        }
        return pids
    }

    private func focusedWindowFrame(_ axApp: AXUIElement) -> CGRect? {
        if let win = copyAttr(axApp, kAXFocusedWindowAttribute), let f = axFrame(win as! AXUIElement) {
            return f
        }
        // Chromium (Claude desktop) doesn't always report a focused window — fall
        // back to the main window, then the first window, so the desktop ring still
        // resolves. Harmless on the VSCode path (only reached when focused is nil).
        if let win = copyAttr(axApp, kAXMainWindowAttribute), let f = axFrame(win as! AXUIElement) {
            return f
        }
        if let wins = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement], let first = wins.first {
            return axFrame(first)
        }
        return nil
    }

    private func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let posV = copyAttr(el, kAXPositionAttribute),
              let sizeV = copyAttr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posV as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeV as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // AX frames are global top-left-origin (y down from the primary display's top);
    // NSWindow wants Cocoa coords (y up from the primary display's bottom).
    private func cocoaRect(fromAX r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    // `predicted` = drawn from the pane memo before anything confirmed it (see paneMemo).
    // Such a draw must not be trusted as a measurement (it would re-record itself) and
    // must not clear the guard that withdraws it.
    private func present(_ axRect: CGRect, accent: NSColor, style: AppSettings.RingStyle,
                         gen: Int, pid: pid_t, target: pid_t, isPane: Bool,
                         strictToken: Bool = true, predicted: Bool = false) {
        let rect = cocoaRect(fromAX: axRect)
        // Resolve the pane's host window BEFORE showing: show() reads the anchor to
        // pick the window level (.normal when anchored), and the overlay is then
        // ordered just above that window instead of floating over every app.
        let win = editorWindowInfo(pid: pid, containingAX: axRect)
        let anchor = win?.number ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self = self, gen == self.generation else { return }
            self.ringLog("present predicted=\(predicted) target=\(target) isPane=\(isPane) "
                         + "rect=\(self.fmt(axRect)) anchor=\(anchor) "
                         + "reuse=\(self.window != nil ? "reposition" : "show")")
            self.anchorWindowNumber = anchor
            self.anchorResolvedAt = Date()
            if !predicted {
                // Measured for real: this rect becomes the memory the next jump draws
                // from, and it retires any prediction currently riding on the old one.
                if isPane { self.rememberPane(target, axRect: axRect, window: win) }
                self.predictedTarget = 0
                self.predictionGuard?.cancel(); self.predictionGuard = nil
            }
            // A prediction is already up for this same generation → slide it onto the
            // measured rect instead of rebuilding: show() would restart the breathing
            // animation and re-arm the teardown timer, a stutter right after the ring
            // appeared. reposition no-ops when the prediction was exact (the common case).
            if self.window != nil {
                self.reposition(to: rect, accent: accent, style: style, gen: gen)
                return
            }
            self.show(around: rect, accent: accent, style: style)
            // Keep the ring glued to the pane if the window moves/resizes while it's up.
            self.queue.async { [weak self] in
                self?.track(pid: pid, target: target, accent: accent, style: style, gen: gen,
                            isPane: isPane, strictToken: strictToken)
            }
        }
    }

    // MARK: Follow the pane as the window moves/resizes

    // While the ring is up, drag or resize the VSCode window and the pane moves
    // with it — so re-resolve the target's frame every ~0.2s and slide/resize the
    // overlay to match. Gated by the SAME identity check as the initial resolve:
    // for the pane path we only chase while the extension still reports the target
    // as focused (report == target); if the user has moved focus to another
    // terminal we leave the ring put rather than jump it onto the wrong pane.
    // Halts automatically when the generation bumps (dismiss / new highlight).
    private func track(pid: pid_t, target: pid_t, accent: NSColor,
                       style: AppSettings.RingStyle, gen: Int, isPane: Bool, strictToken: Bool = true) {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, gen == self.currentGeneration() else { return }
            // The pane can die mid-track (you closed the terminal): its shell is gone
            // and the rect now belongs to whatever reflowed into that screen space,
            // yet a 常驻 caption schedules no teardown. refreshLiveCaption also prunes
            // this, but only on the 2.5s rows poll — one cheap signal-0 probe per tick
            // makes the overlay leave WITH the terminal. ESRCH only: EPERM means the
            // process is alive under another uid.
            if isPane, target > 0, kill(target, 0) != 0, errno == ESRCH {
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.dismiss("shell-gone")
                }
                return
            }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            // Re-assert the Electron a11y-tree expansion on THIS handle, exactly as
            // poll() and rescanAlwaysOn() do. Without it a whole-window resize (which
            // relayouts Chromium's render tree) can leave kAXFocusedUIElement resolving
            // to NoValue on a fresh handle, so focusedTerminalPane() returns nil and the
            // overlay freezes at its old frame instead of following the resized pane.
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var axRect: CGRect?
            // Is focus STILL parked on the ringed pane this tick? Same triple identity
            // check the initial resolve uses, reused to drive the 常驻 caption's
            // focus-follow visibility. The window-fallback path has no pane identity to
            // check, so there the frontmost-app test alone decides.
            var paneFocused = !isPane
            if isPane {
                let report = strictToken ? self.freshFocusReport() : self.anyFocusReport()
                if report == target, let pane = self.focusedTerminalPane(axApp),
                   self.paneOwner(pane.textarea, window: focusedWindowID(axApp)).map({ $0.contains(target) }) != false {
                    axRect = pane.frame
                    paneFocused = true
                } else if self.focusIsOnTabRow(of: target, axApp: axApp) {
                    // ★ Focus on a row of the terminal TAB STRIP is not "you left this
                    // terminal" (改这里前必读). With terminals opened as tabs rather than
                    // splits, clicking that strip is HOW you go to a terminal — yet the
                    // click lands keyboard focus on the list, not on the pane's textarea,
                    // so the check above misses and the 常驻 caption+ring park themselves
                    // one second later. Reported as 「通过 app 跳转过去后，再点一下终端图标，
                    // 高亮就消失了」, and it is worst right after a jump: you land, you
                    // click the strip to confirm where you are, and the marker you were
                    // looking at vanishes. Hold the overlay (but do NOT move it — a row
                    // rect is not a pane rect), and only while the row still names THIS
                    // session, so clicking some other terminal's row still parks.
                    paneFocused = true
                }
            } else {
                axRect = self.focusedWindowFrame(axApp)
            }
            if let r = axRect {
                let cocoa = self.cocoaRect(fromAX: r)
                DispatchQueue.main.async { self.reposition(to: cocoa, accent: accent, style: style, gen: gen) }
                // Refresh the anchor every ~2s (the pane can migrate to another
                // window; ordering above a closed window is a no-op). Only overwrite
                // on success — an off-screen miss must not drop a valid anchor.
                if Date().timeIntervalSince(self.anchorResolvedAt) > 2 {
                    let win = self.editorWindowInfo(pid: pid, containingAX: r)
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        if let win, win.number > 0 { self.anchorWindowNumber = win.number }
                        self.anchorResolvedAt = Date()
                        // Same beat, same query: keep the pane memo current so a jump
                        // right after you dragged/resized the window still predicts the
                        // pane's NEW rect (recallPane would otherwise reject the stale
                        // bounds and fall back to the slow path).
                        if isPane { self.rememberPane(target, axRect: r, window: win) }
                    }
                }
            }
            // Every tick, anchored or not (cheap no-op when not): keeps the overlay
            // glued just above its window after the target app is raised again, and
            // parks/unparks a 常驻 caption with the terminal's focus.
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.applyCaptionFocus(paneFocused: paneFocused, appPid: pid)
                // applyCaptionFocus freezes itself (and so skips syncOneShotAlpha) while
                // the pane isn't on screen — but the host-frontmost backstop must keep
                // being evaluated exactly then, since "frozen" is one of the states the
                // overlay used to linger over another app in.
                self.syncOneShotAlpha()
                self.reassertAnchor()
            }
            self.track(pid: pid, target: target, accent: accent, style: style, gen: gen,
                       isPane: isPane, strictToken: strictToken)
        }
    }

    // ★ 常驻 caption follows the terminal's FOCUS (the "focus 到别的地方标签还挂着" report,
    // 改 track 的可见性判定前必读). `forever` schedules no teardown, so before this the
    // label sat over the pane all day no matter where you actually were — but "常驻显示"
    // means "stays as long as I'm ON this terminal", not "never goes away". Two signals,
    // both already computed by the track tick: the target app must be FRONTMOST, and
    // (pane path) focus must still resolve to the ringed pane. Either failing parks the
    // overlay; both holding brings it straight back — the label is a where-am-I marker
    // for the terminal you're in, so it must return the moment you click back in.
    //   • alpha, not orderOut: an orderFrontRegardless on the way back would re-seat the
    //     window on whatever Space is current, undoing bindToActiveSpace's per-Space
    //     binding (an overlay leaking onto an unrelated Space is exactly what that fix
    //     was for). The ✕ hotspot is a separate click-taking panel, so it also stops
    //     taking mouse events while parked, or an invisible square would swallow clicks.
    //   • armedAt grace: show() runs while a jump's raise is still settling (we may not
    //     be frontmost for a beat) — parking there would blink the overlay on arrival.
    //   • Only `forever`: a timed caption fades on its own well before this matters, and
    //     a plain ring's whole point is to survive the hunt across other windows.
    private func applyCaptionFocus(paneFocused: Bool, appPid: pid_t) {
        guard window != nil, drawsCaption, AppSettings.captionDuration == .forever else {
            captionParked = false
            unfocusedTicks = 0
            return
        }
        // Frozen while the target isn't on screen at all (Mission Control / Show Desktop
        // / minimized / another Space): focus reads say nothing there — the app stays
        // "frontmost" while its panes are gone from the desktop — and freezing is exactly
        // what makes the caption come back in the state it left.
        guard !systemParked, !targetOffScreen else { return }
        let appFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == appPid
        if appFront && paneFocused {
            unfocusedTicks = 0
            guard captionParked else { return }
            captionParked = false
            syncOneShotAlpha()
            return
        }
        // Grace counts from when the overlay APPEARED (shownAt), not from the arm:
        // highlight() stamps armedAt and only then starts polling for the pane, which
        // can burn seconds on a cold a11y tree — by the time the caption is on screen
        // an armedAt-based grace has long expired, so the very first shaky tick parked
        // it and the label blinked 显示 → 消失 → 显示 right after a click.
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        // ★ A prediction that nothing has ruled on yet is not a focus miss (改这里前必读).
        // Drawing from the memo puts the label up before the accessibility tree can say
        // where the pane is — and on a tab-strip switch that tree stays cold for seconds
        // — so every tick in between reads as "pane not focused" and the 1s grace above
        // expires long before the truth arrives: the label appeared, vanished at ~1.4s,
        // and came back when the poll finally confirmed. The prediction guard already
        // owns the question "was this right"; hold the label until it or the poll answers.
        // Still gated on being IN the app: leaving it is an unambiguous signal that the
        // rule below parks on immediately, and an unresolved prediction must not buy a
        // label the right to hang on a terminal you have already walked away from.
        if predictedTarget != 0, appFront { return }
        unfocusedTicks += 1
        // Left the app = unambiguous, park now. A pane-resolve miss while still in the
        // app needs a second tick to rule out an AX hiccup.
        guard !appFront || unfocusedTicks >= 2, !captionParked else { return }
        captionParked = true
        syncOneShotAlpha()
    }

    // MARK: Visibility guard — never draw over a terminal that isn't on screen

    // ★ 「terminal 没有显示的时候，高亮和标签就不要显示；回来如果之前就显示那就显示」
    // (改 park 判据前必读). The ring/caption are markers ON a terminal pane, so the only
    // thing that licenses them is that pane being VISIBLE — yet every pre-existing
    // dismiss/park signal keys off something else (app activation, focus, Space change,
    // layout events), and each of those misses cases where the pane is simply not on
    // screen: Mission Control, Show Desktop, App Exposé, a minimized window, ⌘H, the
    // window pushed off the displays. In all of them the target app stays "frontmost"
    // and its AX tree keeps answering, so the overlay just hung there over thumbnails,
    // bare wallpaper, or another app. Two window-server probes, both from ONE
    // CGWindowList pass, cover the whole family:
    //
    //   ① system takeover — the Dock owns an on-screen window at layer > 0 that covers
    //      (essentially) a whole display. Probed on macOS 15:
    //        normal          → Dock owns only the wallpaper, at a deeply negative layer
    //        Mission Control → full-screen Dock windows at layer 20 (×2) and 18, plus a
    //                          small layer-17 window per Space thumbnail
    //        Show Desktop    → a single full-screen Dock window at layer 18
    //      The Dock's own strip is layer 20 too but nowhere near screen-sized, so a
    //      plain visible Dock never trips it; App Exposé matches for free. This one
    //      parks EVERY overlay (one-shot and always-on) — the takeover covers all
    //      displays and all Spaces.
    //   ② anchor gone — the target's own window (anchorWindowNumber, already resolved
    //      for z-order) is absent from the on-screen list, fully transparent, or lies
    //      outside every display. That is minimize / ⌘H / another Space / off-screen,
    //      i.e. "the pane you'd be pointing at isn't there". Parks the ONE-SHOT only:
    //      the always-on rings are per-pane and already handled by their own hide paths
    //      (app switch, miniaturize, layout settle).
    //
    // Only ownerPID / layer / bounds / alpha / windowNumber are read, so no
    // screen-recording permission is needed (same fields editorWindowInfo uses).
    // Thread-safe, callable off the main thread; `anchor` is passed in because it's
    // main-thread state.
    private func probeVisibility(anchor: Int) -> (system: Bool, anchorGone: Bool) {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return (false, false) }
        let dockPid = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? -1
        // Screen frames in CG's global top-left space (NSScreen is bottom-left), the
        // same flip cocoaRect does — needed to ask "is this window on any display".
        let mainH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? 0
        let screensCG = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: mainH - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
        guard !screensCG.isEmpty else { return (false, false) }
        var system = false
        var anchorSeen = false
        var anchorVisible = false
        for info in list {
            guard let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if !system, (info[kCGWindowOwnerPID as String] as? pid_t) == dockPid, layer > 0,
               screensCG.contains(where: { b.width >= $0.width * 0.95 && b.height >= $0.height * 0.95 }) {
                system = true
            }
            if anchor > 0, (info[kCGWindowNumber as String] as? Int) == anchor {
                anchorSeen = true
                let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
                anchorVisible = alpha > 0.01 && screensCG.contains { $0.intersects(b) }
            }
        }
        return (system, anchor > 0 && (!anchorSeen || !anchorVisible))
    }

    // Poll while any overlay is on screen (0.25s — fast enough that the takeover /
    // minimize animation covers the transition, cheap enough to run beside the track
    // loop). Self-stopping: it shuts down once nothing is left to hide, EXCEPT while
    // parked, since the unpark can only come from this very timer.
    private func ensureSystemWatch() {
        guard systemWatch == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.window != nil || !self.overlays.isEmpty || self.systemParked else {
                self.stopSystemWatch()
                return
            }
            let anchor = self.window != nil ? self.anchorWindowNumber : 0
            self.queue.async { [weak self] in
                guard let self = self else { return }
                let probe = self.probeVisibility(anchor: anchor)
                DispatchQueue.main.async {
                    self.applyVisibility(system: probe.system, anchorGone: probe.anchorGone)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        systemWatch = t
    }

    private func stopSystemWatch() {
        systemWatch?.invalidate()
        systemWatch = nil
    }

    // Park/unpark from the probe. alpha only (never orderOut): re-ordering on the way
    // back would re-seat the one-shot on whatever Space is current, undoing
    // bindToActiveSpace — the same reason the caption's focus-park uses alpha.
    private func applyVisibility(system: Bool, anchorGone: Bool) {
        let overlaysNeedSync = system != systemParked
        systemParked = system
        targetOffScreen = anchorGone
        // Unconditionally (the old early-return fired only when a park flag flipped):
        // this 0.25s tick is also what notices you switched to another app, and that
        // shows up in hostIsFrontmost(), not in either flag. Cheap — one frontmost read
        // plus an alpha assignment, and the timer only runs while an overlay exists.
        syncOneShotAlpha()
        if overlaysNeedSync {
            for ov in overlays.values { ov.window.alphaValue = alwaysOnAlpha }
        }
    }

    // The one-shot overlay is visible only when NO park reason holds — the caption's
    // focus-follow, a system takeover and an off-screen target are independent, so all
    // funnel through here instead of assigning alpha at each site (any one of them
    // restoring on its own would un-hide an overlay another still wants hidden).
    private func syncOneShotAlpha() {
        guard let w = window else { return }
        // hostIsFrontmost() last: it's the backstop the other three can't cover, and it
        // is deliberately NOT frozen by systemParked/targetOffScreen the way
        // applyCaptionFocus is — "you are looking at a different app" is knowable even
        // when the pane's own visibility isn't.
        let visible = !captionParked && !systemParked && !targetOffScreen && hostIsFrontmost()
        // FLIPS only — this runs every 0.2s track tick. An overlay that goes invisible here
        // is still fully alive (no dismiss line follows), which is the other way "圈不见了"
        // happens; the four flags say which reason parked it. hostIsFrontmost is re-read
        // inside the branch on purpose, to keep the short-circuit above free on hot ticks.
        if loggedVisible != visible {
            loggedVisible = visible
            ringLog("alpha=\(visible ? 1 : 0) capPark=\(captionParked) sysPark=\(systemParked) "
                    + "offScreen=\(targetOffScreen) host=\(hostIsFrontmost())")
        }
        w.alphaValue = visible ? 1 : 0
        closeButton?.alphaValue = visible ? 1 : 0
        closeButton?.ignoresMouseEvents = !visible
        if visible { reassertAnchor() }
        // A parked bar is invisible, so an expansion left standing on it would come back
        // with it — collapse on the way out, and re-test the pointer on the way in (no
        // mouse-moved event fires while it's hidden).
        syncCaptionHover()
    }

    // Alpha an always-on overlay should carry right now: hidden during a layout
    // settle (overlaysHidden) or a system takeover, else fully visible.
    private var alwaysOnAlpha: CGFloat {
        (overlaysHidden || systemParked || !editorIsFrontmost()) ? 0 : 1
    }

    // The always-on rings live on panes inside an editor window, so they may only be
    // visible while that editor is the app in front. Same backstop as hostIsFrontmost()
    // for the one-shot, and it closes the same class of leak: `hideAllOverlays()` parks
    // them when you switch away, but any subsequent applyDesired cleared `overlaysHidden`
    // and put them straight back — floating over whatever app you had switched to.
    private func editorIsFrontmost() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return EditorApp(rawValue: bid) != nil
    }

    // Slide (and if needed resize) the overlay to a new frame, reusing show()'s
    // pad/margin geometry. A pure move just repositions the window so the running
    // animation is untouched; a size change rebuilds the stroke to fit the new
    // extent. No-op when nothing moved (avoids churn every tick).
    // Whether this pass draws the titlebar-style caption — the only style with a ✕,
    // so it's what decides if the click-catcher panel is attached/placed.
    private var drawsTitlebarCaption: Bool {
        drawsCaption && RingView.hasTitlebar(project: currentProject, task: currentTask)
    }

    private func reposition(to rect: CGRect, accent: NSColor,
                            style: AppSettings.RingStyle, gen: Int) {
        guard gen == generation, let w = window else { return }
        let target = rect.insetBy(dx: -ringPadX, dy: -ringPadY)
        let frame = target.insetBy(dx: -Self.margin, dy: -Self.margin)
        let sameSize = abs(frame.width - w.frame.width) < 0.5
            && abs(frame.height - w.frame.height) < 0.5
        let sameOrigin = abs(frame.origin.x - w.frame.origin.x) < 0.5
            && abs(frame.origin.y - w.frame.origin.y) < 0.5
        if sameSize && sameOrigin { return }
        shownTarget = target
        if sameSize {
            w.setFrameOrigin(frame.origin)
        } else {
            w.setFrame(frame, display: true)
            // Repaint with the CURRENT status color/style — not the color captured when
            // the track loop started. A 常驻 caption may have recolored since (via
            // refreshLiveCaption), so a stale-param rebuild on a pane resize would flicker
            // it back to the previous stage's color. currentStatus is kept live by
            // highlight/refreshLiveCaption; empty (unset) falls back to the captured param.
            let liveAccent = currentStatus.isEmpty ? accent : Status.accent(currentStatus)
            let liveStyle = currentStatus.isEmpty ? style : AppSettings.ringStyle(for: currentStatus)
            w.contentView = RingView(frame: NSRect(origin: .zero, size: frame.size),
                                     margin: Self.margin, accent: liveAccent, style: liveStyle,
                                     project: currentProject, task: currentTask, icon: currentIcon,
                                     drawRing: drawsRing, suppressCaption: !drawsCaption)
            resyncCaptionHover()
        }
        closeButton?.setFrameOrigin(Self.closeButtonFrame(target: target).origin)
    }

    // MARK: Overlay window (main thread)

    private func show(around rect: CGRect, accent: NSColor, style: AppSettings.RingStyle) {
        guard drawsRing || drawsCaption else { return }
        let target = rect.insetBy(dx: -ringPadX, dy: -ringPadY)
        // The titlebar caption is drawn INSIDE the ring, so the frame is just the
        // padded pane plus the animation margin — no extra band on top.
        let frame = target.insetBy(dx: -Self.margin, dy: -Self.margin)

        let w = Self.makeOverlayWindow(frame: frame)
        // Anchored: ride at .normal level ordered just above the target's window
        // (kept there by reassertAnchor from the track loop), so an app in front of
        // the terminal covers the ring/caption too. isFloatingPanel must go with it
        // or AppKit can snap the panel back to .floating. Unresolved anchor keeps
        // the .floating fallback from makeOverlayWindow.
        if anchorWindowNumber > 0 {
            (w as? NSPanel)?.isFloatingPanel = false
            w.level = .normal
        }
        // The overlay is created on whatever Space is current at click time, but a jump
        // usually switches to the target window's Space (often on another display) — an
        // overlay bound to the ORIGIN Space would then be invisible where the pane now is
        // (the "ring shows on the external monitor but not from the main screen" bug).
        // .canJoinAllSpaces + .stationary (the toast panel's combination) makes the
        // transient ring visible on the destination Space regardless; it's positioned at
        // the pane's absolute coords, so it only ever shows over that pane's display.
        // (Always-on rings at makeOverlayWindow's other caller are per-Space and
        // intentionally do NOT get these.)
        // This is TEMPORARY: the moment the ring finishes fading in, bindToActiveSpace
        // clears canJoinAllSpaces to bind the window to the target's Space, so it
        // follows that Space (hidden when you leave, shown when you return) instead of
        // floating on every Space forever.
        w.collectionBehavior.insert(.canJoinAllSpaces)
        w.collectionBehavior.insert(.stationary)
        let ring = RingView(frame: NSRect(origin: .zero, size: frame.size),
                            margin: Self.margin, accent: accent, style: style,
                            project: currentProject, task: currentTask, icon: currentIcon,
                            drawRing: drawsRing, suppressCaption: !drawsCaption)
        w.contentView = ring
        w.alphaValue = 0
        w.orderFrontRegardless()
        window = w
        captionParked = false
        unfocusedTicks = 0
        shownAt = Date()
        shownTarget = target
        shownStatus = currentStatus
        shownAccentHex = accent.hexString
        attachCloseButton(target: target)
        armCaptionHover()
        // Armed unconditionally: the anchor may still be 0 here and only resolve on a
        // later track tick (off-screen at present() time), and reassertBurst no-ops
        // while it is.
        armAnchorReassert()
        spaceBound = false
        // ★ Bind to the target's Space BEFORE fading in, while every piece is still at
        // alpha 0 (改 bind 时机前必读). show() runs AFTER the jump's raise + Space switch
        // (the pane frame already resolved, so the active Space is the target's here),
        // so there is nothing to "settle" — the bind only ever had to dodge the fade,
        // because it re-seats the window with orderOut → orderFrontRegardless.
        // Doing that on the fade's completion made the just-appeared overlay blink
        // 显示 → 消失 → 显示 on every fresh click (the reseat drops the window off screen
        // for a beat, and a repeat click on the SAME terminal is deduped away, which is
        // why it read as "第一次点击才闪"). At alpha 0 the same reseat is invisible, so
        // run it one runloop tick after the window is ordered in — the pane is fully
        // bound to its Space before the user sees anything, which also closes the
        // canJoinAllSpaces leak window 0.12s earlier than before.
        ensureSystemWatch()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window === w else { return }
            self.bindToActiveSpace()
            // Born straight into a park when the draw landed while the target wasn't on
            // screen (Mission Control up, window just minimized), or while you were
            // looking at a different app entirely: stay at 0 and let the unpark fade it
            // in for real. That last clause is what keeps an UNPROMPTED draw
            // (flashPaused, which needs no click) from flashing over whatever you're in —
            // the alpha sync alone can't, since this fade doesn't go through it.
            let parked = self.systemParked || self.targetOffScreen || !self.hostIsFrontmost()
            let appear: CGFloat = parked ? 0 : 1
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                w.animator().alphaValue = appear
                // The ✕ panel rides the same fade: it is born at alpha 0 too so the
                // reseat can't flash it either.
                self.closeButton?.animator().alphaValue = appear
            }
        }

        // Teardown timing. The RING always plays its animation and fades on its own
        // rhythm (ring.lifetime); it's the CAPTION — a static layer that never fades
        // itself — that decides how long the overlay lives. With a caption showing,
        // keep the window up for the caption's duration (the ring is already invisible
        // by then, so only the label remains); `forever` (< 0) schedules no teardown at
        // all. Without a caption (plain ring, or caption suppressed this draw), fall
        // back to the ring's own lifetime.
        let hold = drawsCaption ? AppSettings.captionDuration.seconds : ring.lifetime
        guard hold > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss("hold-timeout \(hold)s") }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    // Keep a 常驻 (forever) caption+ring tracking the live session. The one-shot
    // overlay is drawn once at jump/click time with the status color + task title
    // snapshotted THEN and, unlike the always-on managed overlays, never followed the
    // session onward — so a pane that started a new turn kept showing the previous
    // stage's color (and a stale title): the "已经开始跑了圈还是白色/上一个阶段的颜色"
    // report. Called on the main thread after each rows refresh: re-tint + re-label the
    // live overlay in place from the target's current row, rebuilding its RingView only
    // when something actually changed (a needless rebuild would restart the breathing
    // loop every poll). Only the forever caption lives long enough to go stale — timed
    // captions fade before status moves — and only the pane path carries a live shellPid
    // (currentTarget > 0), so window-fallback rings are left alone.
    func refreshLiveCaption(rows: [SessionRow]) {
        guard AppSettings.highlightsEnabled,
              AppSettings.captionDuration == .forever,
              drawsCaption, currentTarget > 0,
              let w = window, let shown = shownTarget else { return }
        // ★ The session behind a 常驻 overlay can DIE (terminal closed, claude quit):
        // the pane is gone, but a forever caption schedules no teardown and nothing
        // else prunes the one-shot overlay, so the label stayed pinned over whatever
        // now occupies that screen rect — the "关闭 terminal 了后 terminal 标签还是会一直
        // 显示" report. Tear it down, mirroring recolorOverlays dropping an always-on
        // overlay whose session left the row set. A missing shellPid is trustworthy:
        // rows come from a full process scan every refresh, not an incremental diff.
        guard let row = rows.first(where: { $0.shellPid == currentTarget }) else {
            dismiss("row-gone")
            return
        }
        let style = AppSettings.ringStyle(for: row.status)
        let accent = Status.accent(row.status)
        guard row.status != shownStatus
            || accent.hexString != shownAccentHex
            || row.folder != currentProject
            || row.taskTitle != currentTask
            || row.badgeMode != currentIcon else { return }
        currentStatus = row.status
        shownStatus = row.status
        shownAccentHex = accent.hexString
        currentProject = row.folder
        currentTask = row.taskTitle
        currentIcon = row.badgeMode
        // A live style flip toggles the ring on a ring-eligible draw (idle → .off drops
        // it, working restores it); a caption-only draw (not ring-eligible) never grows
        // a ring. drawsRing gates the RingView build below.
        drawsRing = ringEligibleForCaption && style != .off
        // The frame is the unchanged pane rect plus the margin — the caption lives
        // inside the ring, so no title change can resize the window (mirrors show/
        // reposition).
        let frame = shown.insetBy(dx: -Self.margin, dy: -Self.margin)
        if abs(frame.height - w.frame.height) > 0.5 {
            w.setFrame(frame, display: true)
        }
        w.contentView = RingView(frame: NSRect(origin: .zero, size: frame.size),
                                 margin: Self.margin, accent: accent, style: style,
                                 project: currentProject, task: currentTask, icon: currentIcon,
                                 drawRing: drawsRing, suppressCaption: !drawsCaption)
        resyncCaptionHover()
        closeButton?.setFrameOrigin(Self.closeButtonFrame(target: shown).origin)
    }

    // MARK: Space follow

    // Clear canJoinAllSpaces so the window belongs to the target's Space ONLY, then
    // reorder so macOS re-assigns it to the current (target) Space. From then on macOS
    // shows it when that Space is active and hides it otherwise — the overlay FOLLOWS
    // the terminal's Space (hidden when you leave, back when you return) instead of
    // floating on unrelated Spaces. The ✕ panel travels with the ring (same treatment).
    private func bindToActiveSpace() {
        guard !spaceBound, window != nil else { return }
        spaceBound = true
        for w in [window, closeButton].compactMap({ $0 }) {
            w.collectionBehavior.remove(.canJoinAllSpaces)
            // Re-seat on the current Space now that it no longer joins all Spaces.
            // The overlay is still at alpha 0 when show() calls this (it fades in
            // right after), so the drop-and-reorder is never visible — doing it on
            // the fade's completion instead is what made a fresh overlay blink.
            w.orderOut(nil)
            w.orderFrontRegardless()
        }
        // The reseat's orderFrontRegardless put the overlay above everything at its
        // level — drop it straight back to just above its anchor window.
        reassertAnchor()
    }

    // A clear, click-through, top-most overlay window sized to a padded pane
    // frame — shared by the one-shot jump/click ring and the always-on overlays.
    // NSPanel + .nonactivatingPanel (NOT a bare NSWindow): the exact configuration
    // the toast/popover panels use, the one PROVEN in this app to show up on any
    // Space — a bare NSWindow ordered by a background app during/after a Space
    // transition can end up assigned to a non-active Space (isOnActiveSpace=false)
    // and never becomes visible (the "ring never shows after a cross-Space jump" bug).
    private static func makeOverlayWindow(frame: CGRect) -> NSWindow {
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // .floating (3) — just above ordinary windows, used by the always-on
        // overlays (they hide whenever the editor isn't frontmost, so they never
        // cover another app). The one-shot ring/caption overrides this to .normal
        // + order(.above, relativeTo: anchor) in show() so it sits at the target
        // window's own depth. Deliberately NOT assistiveTechHigh (~1500), which
        // floated the ring over every app.
        w.level = .floating
        w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        return w
    }

    // MARK: Titlebar ✕ (manual close)

    // Screen rect of the titlebar's ✕ hotspot for `target` (the padded pane rect —
    // the bar spans exactly its width, tucked INSIDE its top edge).
    private static func closeButtonFrame(target: CGRect) -> CGRect {
        CGRect(x: target.maxX - RingView.closeSize - RingView.closeInset,
               y: target.maxY - RingView.titlebarHeight
                   + (RingView.titlebarHeight - RingView.closeSize) / 2,
               width: RingView.closeSize, height: RingView.closeSize)
    }

    // Float the tiny click-catcher over the bar's ✕ glyph. Only this panel takes
    // mouse events — the ring overlay stays click-through everywhere else, so
    // clicking the terminal (answering a prompt) keeps working. Same Space/level
    // treatment as the overlay so the two always travel together.
    private func attachCloseButton(target: CGRect) {
        guard drawsTitlebarCaption else { return }
        let p = NSPanel(contentRect: Self.closeButtonFrame(target: target),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        let level = window?.level ?? .floating
        p.isFloatingPanel = level == .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        p.level = level
        p.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
        let v = RingCloseButtonView(frame: NSRect(origin: .zero,
                                                  size: NSSize(width: RingView.closeSize,
                                                               height: RingView.closeSize)))
        v.onClick = { [weak self] in self?.dismiss("close-button") }
        p.contentView = v
        // Born transparent and faded in by show()'s animation group, so the Space
        // reseat (bindToActiveSpace) happens while it is invisible — see show().
        p.alphaValue = 0
        p.orderFrontRegardless()
        closeButton = p
    }

    // MARK: Caption hover (reveal a title too long for the pane)

    // A narrow pane truncates the title, so hovering the bar expands it in place to the
    // full text. Detected with PASSIVE mouse-moved monitors rather than a tracking panel
    // over the bar: the overlay is click-through by design (you must be able to click the
    // terminal underneath, including the row the bar covers), and any panel wide enough
    // to track the hover would also swallow those clicks. A monitor observes without
    // consuming, costing one rect test per mouse move while a caption is up.
    private func armCaptionHover() {
        guard drawsCaption else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.syncCaptionHover() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
            hoverMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved],
                                                    handler: { handler($0); return $0 }) {
            hoverMonitors.append(l)
        }
        // The pointer can already be resting on the bar when it appears (you clicked the
        // row and the label drew under the cursor), and no move event would follow.
        syncCaptionHover()
    }

    private func disarmCaptionHover() {
        hoverMonitors.forEach { NSEvent.removeMonitor($0) }
        hoverMonitors = []
        captionHovered = false
    }

    // The caption's CURRENT screen rect — it grows with the expansion, which is what
    // gives the hover its hysteresis: once expanded, the pointer is still inside the
    // (taller) label, so it doesn't immediately collapse and re-expand.
    private func syncCaptionHover() {
        guard let w = window, let ring = w.contentView as? RingView,
              !captionParked, !systemParked, !targetOffScreen, ring.captionCanExpand else {
            if captionHovered {
                captionHovered = false
                (window?.contentView as? RingView)?.setCaptionExpanded(false)
            }
            return
        }
        let inside = w.convertToScreen(ring.captionHitRect).contains(NSEvent.mouseLocation)
        guard inside != captionHovered else { return }
        captionHovered = inside
        ring.setCaptionExpanded(inside)
    }

    // A rebuilt RingView is always born collapsed (refreshLiveCaption / reposition), so
    // the cached hover flag has to follow or the next move event would see "no change"
    // and leave a hovered bar collapsed.
    private func resyncCaptionHover() {
        captionHovered = false
        syncCaptionHover()
    }

    // MARK: - Always-on rings (persistent status-colored overlays)
    //
    // When AppSettings.ringAlwaysOn is on, every VISIBLE Claude terminal pane in
    // the focused VSCode window carries a steady status-colored ring. Two update
    // paths, both driven off the app's 2.5s poll via updateAlwaysOn(rows:):
    //   • cheap RECOLOR (no AX) — every poll: re-tint existing overlays and drop
    //     ones whose session vanished, straight from `rows`.
    //   • AX RESCAN (throttled ~2s) — walk the accessibility tree to discover which
    //     panes are visible and where, then add/remove/reposition overlays. Overlay
    //     *creation* only happens here, so a session crossing into ring-eligibility
    //     (idle/off → 运行中, or brand-new) bypasses the throttle for one immediate
    //     scan — otherwise its ring lags up to the throttle behind the row's color.
    // Overlays live in `overlays` keyed by shellPid; all mutation is main-thread.
    // Phase C layers window resize/move + focus-change observers on top of this.

    private struct Overlay {
        let window: NSWindow
        var status: String
        var axRect: CGRect   // last AX frame (global top-left) the overlay was placed at
        var accentHex: String   // the color currently drawn — repaint when the custom color changes
    }
    private var overlays: [pid_t: Overlay] = [:]
    private var lastAXScan: Date = .distantPast
    private static let axScanInterval: TimeInterval = 2.0

    // Phase C state: last status map (snapshotted on main so off-poll rescans —
    // resize settle, focus/space change, jump emphasis — have data to work with),
    // the AX resize/move observer, its currently-observed window, layout-settle
    // debounce, hidden flag (overlays parked at alpha 0 during a drag), the
    // NSWorkspace observers, and a pending jump/click emphasis request.
    private var lastStatusByPid: [pid_t: String] = [:]
    private var axObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var observerPid: pid_t = 0
    private var layoutDebounce: DispatchWorkItem?
    private var overlaysHidden = false
    private var alwaysOnObservers: [NSObjectProtocol] = []
    private var pendingEmphasis: pid_t = 0
    private var pendingEmphasisAt: Date = .distantPast
    private static let windowNotifs = [
        kAXWindowResizedNotification, kAXWindowMovedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    // The running VSCode-family editor whose panes the always-on rings track: the
    // frontmost one if any editor is active, else the first running editor. nil when
    // none is running (teardown). With two editors open the rings follow whichever is
    // front — matching the always-on feature's "focused editor window" scope.
    private func activeEditorApp() -> NSRunningApplication? {
        let bundleIds = Set(EditorApp.allCases.map { $0.rawValue })
        let running = NSWorkspace.shared.runningApplications.filter {
            bundleIds.contains($0.bundleIdentifier ?? "")
        }
        return running.first(where: { $0.isActive }) ?? running.first
    }

    // Strict counterpart for the SCAN: only an editor that is actually in front. The
    // lenient `?? running.first` above is fine for bookkeeping (installResizeObserver
    // wants a pid whether or not you're looking at it) but was wrong as a scan target —
    // a BACKGROUND editor still answers kAXFocusedUIElement with its last-focused xterm
    // textarea, so the scan happily harvested panes and built overlays for a window you
    // weren't even looking at.
    private func frontmostEditorApp() -> NSRunningApplication? {
        activeEditorApp().flatMap { $0.isActive ? $0 : nil }
    }

    // Driver, called on the main thread after each rows refresh. Honors the
    // master + always-on switches (B4 lifecycle), keeps the layout observers
    // installed, recolors cheaply from rows, and kicks a throttled AX rescan for
    // pane membership/position.
    func updateAlwaysOn(rows: [SessionRow]) {
        guard AppSettings.highlightsEnabled, AppSettings.ringAlwaysOn else {
            if !overlays.isEmpty || axObserver != nil || !alwaysOnObservers.isEmpty {
                teardownAlwaysOn()
            }
            return
        }
        let prevStatusByPid = lastStatusByPid
        var statusByPid: [pid_t: String] = [:]
        for r in rows where !r.isDesktop && r.shellPid > 0 { statusByPid[r.shellPid] = r.status }
        lastStatusByPid = statusByPid

        installAlwaysOnObservers()
        if let ed = activeEditorApp() {
            installResizeObserver(pid: ed.processIdentifier)
        }

        recolorOverlays(statusByPid)

        // A session that JUST became ring-eligible (idle/off → working, or a brand-new
        // pane) owns no overlay yet — recolorOverlays only re-tints/prunes existing
        // overlays, and overlay *creation* lives on the throttled AX rescan below. Making
        // a freshly-started pane wait up to axScanInterval for its ring reads as a lag:
        // the pane sits with no ring (or a stale one-shot from the last jump) while the
        // row already flipped 运行中 ("已经开始跑了圈还是白色/上一个阶段的颜色"). Detect that
        // rising edge and rescan NOW, bypassing the throttle, so the event-driven refresh
        // paints the ring near-instantly. Eligible↔eligible flips stay on recolor (already
        // immediate), so this never hammers AX during a working↔needs oscillation.
        let needsImmediateScan = statusByPid.contains { pid, status in
            guard overlays[pid] == nil,
                  AppSettings.ringStyle(for: status) != .off else { return false }
            // Brand-new pid (no prior status) never had an overlay; an existing pid whose
            // prior status carried no ring likewise crossed into eligibility just now.
            guard let prev = prevStatusByPid[pid] else { return true }
            return AppSettings.ringStyle(for: prev) == .off
        }

        if needsImmediateScan || Date().timeIntervalSince(lastAXScan) >= Self.axScanInterval {
            lastAXScan = Date()
            queue.async { [weak self] in self?.rescanAlwaysOn(statusByPid: statusByPid) }
        }
    }

    // Cheap path (no AX): keep the tint current between rescans and prune overlays
    // whose session is gone or whose status now maps to `.off`. Position is left
    // to the rescan — panes don't move without a layout event. A rebuild fires on
    // a status flip OR a custom-color change (same status, new hex) so editing a
    // ring color in Settings repaints the live always-on overlays right away.
    private func recolorOverlays(_ statusByPid: [pid_t: String]) {
        for (pid, ov) in overlays {
            guard let status = statusByPid[pid] else { removeOverlay(pid); continue }
            if AppSettings.ringStyle(for: status) == .off { removeOverlay(pid); continue }
            let hex = Status.accent(status).hexString
            if status != ov.status || hex != ov.accentHex { restyleOverlay(pid, status: status) }
        }
    }

    // Change an overlay's status, then rebuild its content so the flip replays the
    // entrance flourish (reads as an event). Frame unchanged.
    private func restyleOverlay(_ pid: pid_t, status: String) {
        guard overlays[pid] != nil else { return }
        overlays[pid]?.status = status
        rebuildOverlayContent(pid)
    }

    // Rebuild an overlay's RingView in its current status color/style, replaying
    // the entrance flourish once (then holding steady). Used by restyle (status
    // flip), resize (frame change), and jump/click emphasis (Phase C3).
    private func rebuildOverlayContent(_ pid: pid_t) {
        guard let ov = overlays[pid] else { return }
        let style = AppSettings.ringStyle(for: ov.status)
        guard style != .off else { removeOverlay(pid); return }
        let accent = Status.accent(ov.status)
        let size = ov.window.frame.size
        ov.window.contentView = RingView(frame: NSRect(origin: .zero, size: size),
                                         margin: Self.margin, accent: accent,
                                         style: style, persistent: true)
        overlays[pid]?.accentHex = accent.hexString
    }

    private func removeOverlay(_ pid: pid_t) {
        guard let ov = overlays.removeValue(forKey: pid) else { return }
        let w = ov.window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func teardownAlwaysOn() {
        Array(overlays.keys).forEach { removeOverlay($0) }
        removeResizeObserver()
        removeAlwaysOnObservers()
        overlaysHidden = false
        pendingEmphasis = 0
    }

    // Background AX scan: find the focused VSCode window's visible terminal panes,
    // map each to a shellPid via the extension manifest, and hand the desired set
    // (shellPid -> pane frame) to applyDesired on the main thread. Returns without
    // touching overlays when focus isn't in a terminal (keep the last good set).
    private func rescanAlwaysOn(statusByPid: [pid_t: String]) {
        loadPanePinsIfNeeded()
        defer { savePanePinsIfDirty() }
        // No editor in front → don't scan and don't touch the overlay set. Not a
        // teardown: you may be glancing at another app and coming right back, and
        // alwaysOnAlpha already keeps them invisible meanwhile. Tearing down here would
        // also fight `hideAllOverlays()`, which is what parks them on the way out.
        guard NSWorkspace.shared.runningApplications.contains(where: {
            EditorApp(rawValue: $0.bundleIdentifier ?? "") != nil
        }) else {
            DispatchQueue.main.async { [weak self] in self?.teardownAlwaysOn() }
            return
        }
        guard let app = frontmostEditorApp() else { return }
        let panes = scanPanes(app, statusByPid: statusByPid)
        // Only ring-eligible sessions get an overlay; the rest were still worth
        // measuring (scanPanes feeds the jump memo for every pane it resolved).
        let desired = panes.filter { pid, _ in
            guard let status = statusByPid[pid] else { return false }
            return AppSettings.ringStyle(for: status) != .off
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyDesired(desired, statusByPid: statusByPid)
        }
    }

    // The measuring half of the scan, shared by the always-on rescan and the jump
    // memo's warm-up: every terminal pane visible in this editor's focused window,
    // resolved to its owning shellPid. Frames are AX global coords. Runs off-main
    // (AX IPC); the memo write it schedules hops back to the main thread.
    private func scanPanes(_ app: NSRunningApplication,
                           statusByPid: [pid_t: String]) -> [pid_t: CGRect] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 2.0)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focus = focusedTerminalGroupsContainer(axApp) else { return [:] }
        var textareas: [AXUIElement] = []
        collectXtermTextareas(focus.container, into: &textareas, depth: 0)

        // Which of the collected panes IS the focused one. Matching on the terminal
        // number is the reliable half (it is unique inside this window); CFEqual only
        // backs it up, because Electron can hand back a different AXUIElement wrapper
        // for the very same element.
        let focusedIndex = paneIdentity(of: focus.textarea)?.index
        // Pane numbers only mean anything inside one window (see paneIdentityCache).
        let window = focusedWindowID(axApp)
        // The token names the terminal the user is IN, so it only identifies a pane while
        // this editor is frontmost — otherwise it describes somebody else's window.
        let learnFrom = learnableOwner(window: window, focusedIndex: focusedIndex,
                                       editorActive: app.isActive)
        let manifests = loadManifests()
        pruneWindowManifest(manifests.byFile)
        let found = resolvePanes(textareas, statusByPid: statusByPid,
                                 nameToPid: manifests.merged, window: window,
                                 focused: (textarea: focus.textarea, index: focusedIndex),
                                 learnFrom: learnFrom)
        // The focused window is where resolution has the token behind it, so it is also
        // where the window -> manifest binding is most trustworthy (see windowManifest).
        learnWindowManifest(window, from: found.keys, fileOf: manifests.fileOf)
        rememberScanned(found, editorPid: app.processIdentifier, window: window)
        return found
    }

    // MARK: Pane geometry for the corner pips (StatusPip.swift)

    // Every visible terminal pane of the frontmost editor, plus the CG window number
    // they all share — the geometry a corner pip needs to place itself and to anchor
    // above its host. Deliberately a thin re-export of `scanPanes` rather than a second
    // walk: pips inherit its identity rules for free (a pane whose owner the evidence
    // doesn't single out is dropped, never guessed — see resolveOwner), and when
    // always-on happens to be on too, both features read one shared AX pass.
    //
    // Off-main (AX IPC), like scanPanes itself.
    //
    // ★ Uses the LENIENT `activeEditorApp()`, not the strict `frontmostEditorApp()` the
    // always-on rescan is forced onto (改这里前必读 — the asymmetry is the point). The
    // strict gate exists because a BACKGROUND editor still answers kAXFocusedUIElement
    // with its last-focused xterm textarea, and a `.floating` ring built from that
    // harvest ends up drawn over whatever app you actually switched to. A pip cannot hit
    // that bug: it sits at `.normal` ordered above its host window, so a pane belonging
    // to a background window produces a pip that is equally in the background — covered
    // by the same things that cover the terminal, which is exactly the specified
    // behavior. Requiring frontmost here would instead break the feature's main case:
    // an editor beside another app (split screen, second display) whose window you can
    // plainly see would never get a dot, because the dots only ever get CREATED here.
    //
    // Identity stays safe off-front on its own: scanPanes passes `editorActive` into
    // `learnableOwner`, so a background scan refuses to learn ownership from the focus
    // token and resolves only via existing pins and unique names — panes it can't pin
    // are dropped, never guessed.
    //
    // nil = no editor running at all. Callers should KEEP their previous set on nil
    // rather than tear down; an empty dictionary is the real "nothing there".
    //
    // ★ TWO entry points, and the cheap one is not sufficient on its own (改这里前必读):
    //
    //   • FOCUSED — the focused element walked up to its enclosing terminal container.
    //     One hop, near-free, and what `scanPanes` is built on. But it yields nothing at
    //     all unless the focus is currently INSIDE a terminal, and it can only ever see
    //     one window. For a jump that is fine (you just put the focus there). For pips it
    //     is not: with the editor in the background and its last focus in a source file,
    //     it returns zero panes, so no pip ever gets built — measured, not assumed.
    //   • DEEP — walk each onscreen editor window's tree to FIND its terminal containers,
    //     the same discovery `sweepOtherWindows` does for the jump memo. Thousands of AX
    //     round trips per window, so it is bounded here (per-window and whole-round
    //     deadlines, front-to-back window order) and callers must gate it: ask for it only
    //     while some session still has no pane. Once every session is placed, the steady
    //     state costs zero deep scans.
    // ★ Where pips get their geometry in the common case, and the reason they work at all
    // when the focus is not sitting in a terminal (改这里前必读).
    //
    // A background walk of the live tree finds the panes but cannot NAME them: Claude Code
    // titles every session without a task summary "✳ Claude Code", so several panes carry
    // one title, and `resolveOwner` refuses to pick between same-named candidates without
    // the focus token to learn from (docs/focus-ring.md ★ 27). Measured on this machine:
    // containers=3 textareas=7 resolved=0 — every pane found, none named. Loosening that
    // rule is not on the table; a dot showing another session's status is worse than no dot.
    //
    // The memo sidesteps it because each entry was written at a moment when the evidence
    // DID single an owner out (a jump, or a warm scan while the editor was in front), so
    // reading one back is recall, not a guess. `recallPane`'s three gates (TTL, host window
    // still onscreen, its bounds unchanged) are exactly the "is this rectangle still true"
    // question a pip needs answered, and they cost one CGWindowList pass — no AX at all.
    //
    // Main thread only: paneMemo has no lock.
    func recallPanesForPips(_ pids: [pid_t]) -> [pid_t: PipPane] {
        guard let app = activeEditorApp() else { return [:] }
        let editorPid = app.processIdentifier
        // ONE window snapshot for the whole set, not one per session. `recallPane` takes
        // its own each call, which is fine for the handful a jump needs but is a full
        // CGWindowList pass per session here — seven sessions meant seven snapshots every
        // refresh. The gates applied below are recallPane's, verbatim.
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var onscreen: [Int: CGRect] = [:]
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == editorPid,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { continue }
            onscreen[num] = b
        }
        var out: [pid_t: PipPane] = [:]
        for pid in pids {
            guard let memo = paneMemo[pid],
                  Date().timeIntervalSince(memo.at) < Self.memoTTL,      // ① fresh enough
                  let bounds = onscreen[memo.windowNumber],              // ② host still onscreen
                  bounds.equalTo(memo.windowBounds)                      // ③ host unmoved/unresized
            else { continue }
            out[pid] = PipPane(rect: memo.axRect, window: memo.windowNumber,
                               windowBounds: memo.windowBounds)
        }
        return out
    }

    // ★ Runs on FocusRing's OWN `queue`, and callers get the result on the main thread
    // (改这里前必读). It is not merely convenient: `resolvePanes` → `resolveOwner` writes
    // `paneIdentityCache`, `learnableOwner` writes `lastFocusObservation`, and
    // learn/pruneWindowManifest write `windowManifest` — all three are documented
    // "touched on `queue` only". Letting a caller drive this from a queue of its own put
    // two unsynchronized serial queues on the same Swift Dictionaries (a crash), and
    // interleaved writes to `lastFocusObservation` would break the "same observation
    // twice in a row before pinning" rule that keeps a pane from being pinned to the
    // wrong session. One queue, no exceptions.
    //
    // `complete` reports whether the deep pass actually walked every candidate window or
    // gave up on the budget below. Callers must not treat a truncated result as the full
    // picture — the windows it never reached look exactly like windows with no panes.
    func scanPanesForPips(statusByPid: [pid_t: String], deep: Bool,
                          completion: @escaping (PipScan?) -> Void) {
        queue.async { [weak self] in
            let out = self?.scanPanesForPipsSync(statusByPid: statusByPid, deep: deep)
            DispatchQueue.main.async { completion(out) }
        }
    }

    private func scanPanesForPipsSync(statusByPid: [pid_t: String],
                                      deep: Bool) -> PipScan? {
        loadPanePinsIfNeeded()
        defer { savePanePinsIfDirty() }
        guard let app = activeEditorApp() else { return nil }
        let editorPid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(editorPid)
        AXUIElementSetMessagingTimeout(axApp, deep ? Self.sweepTimeout : 2.0)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let onscreen = onscreenWindows(of: editorPid)   // front-to-back, current Space
        var boundsOf: [CGWindowID: CGRect] = [:]
        for w in onscreen { boundsOf[CGWindowID(w.number)] = w.bounds }
        let manifests = loadManifests()
        pruneWindowManifest(manifests.byFile)
        var out: [pid_t: PipPane] = [:]

        func absorb(_ found: [pid_t: CGRect], window: CGWindowID) {
            guard let wb = boundsOf[window] else { return }
            for (pid, rect) in found {
                out[pid] = PipPane(rect: rect, window: Int(window), windowBounds: wb)
            }
            learnWindowManifest(window, from: found.keys, fileOf: manifests.fileOf)
            rememberScanned(found, editorPid: editorPid, window: window)
        }

        // Cheap pass. Identity is only learnable from the focus token while the editor is
        // actually in front; in the background this resolves via existing pins and unique
        // names only, and drops what it can't pin (see resolveOwner).
        let focusedWid = focusedWindowID(axApp)
        if let focus = focusedTerminalGroupsContainer(axApp), let wid = focusedWid {
            var textareas: [AXUIElement] = []
            collectXtermTextareas(focus.container, into: &textareas, depth: 0)
            let focusedIndex = paneIdentity(of: focus.textarea)?.index
            let learnFrom = learnableOwner(window: wid, focusedIndex: focusedIndex,
                                           editorActive: app.isActive)
            absorb(resolvePanes(textareas, statusByPid: statusByPid,
                                nameToPid: manifests.merged, window: wid,
                                focused: (textarea: focus.textarea, index: focusedIndex),
                                learnFrom: learnFrom), window: wid)
        }
        // Tab rows ride along on EVERY pass, deep or not: reading them is one children
        // call per cached list (see tabLists), and they are the half of the feature that
        // has to stay fresh — a pane sits still for minutes, a tab row moves the moment
        // you open or close a terminal.
        func tabs() -> (rows: [pid_t: PipPane], selected: [Int: pid_t], fresh: Bool) {
            readTabRows(statusByPid: statusByPid, manifests: manifests, boundsOf: boundsOf)
        }

        // A shallow pass never claims completeness: it only ever looked at the one
        // container the focus happened to be in.
        if !deep {
            let t = tabs()
            return PipScan(panes: out, tabs: t.rows, selectedByWindow: t.selected,
                           tabsFresh: t.fresh, complete: false)
        }

        // Expensive pass over every onscreen window, including the focused one — with the
        // focus outside a terminal, the cheap pass found nothing even there.
        guard let wins = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
            let t = tabs()
            return PipScan(panes: out, tabs: t.rows, selectedByWindow: t.selected,
                           tabsFresh: t.fresh, complete: false)
        }
        var ranked: [(win: AXUIElement, wid: CGWindowID, bounds: CGRect, rank: Int)] = []
        for win in wins {
            var wid = CGWindowID(0)
            guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0,
                  let rank = onscreen.firstIndex(where: { $0.number == Int(wid) })
            else { continue }
            ranked.append((win, wid, onscreen[rank].bounds, rank))
        }
        ranked.sort { $0.rank < $1.rank }   // AXWindows order is not z-order; the CG list's is
        let deadline = Date().addingTimeInterval(Self.sweepBudget)
        var truncated = false
        for c in ranked {
            if Date() >= deadline { truncated = true; break }
            var containers: [AXUIElement] = []
            findTerminalContainers(c.win, into: &containers, depth: 0, clip: c.bounds,
                                   deadline: min(deadline, Date().addingTimeInterval(Self.sweepWindowBudget)))
            var textareas: [AXUIElement] = []
            for container in containers { collectXtermTextareas(container, into: &textareas, depth: 0) }
            guard !textareas.isEmpty else { continue }
            // Prefer this window's OWN manifest where we've learned it: the colliding
            // "Claude Code" names are spread across windows, so scoping usually leaves a
            // single candidate (see windowManifest). Pin by title-set first, so a window
            // nobody ever clicked into can still resolve (see pinWindowManifest).
            pinWindowManifest(c.wid, axTitles: textareas.compactMap {
                paneIdentity(of: $0).map { normalize($0.title) }
            }, byFile: manifests.byFile)
            let table = windowManifest[c.wid].flatMap { manifests.byFile[$0] } ?? manifests.merged
            absorb(resolvePanes(textareas, statusByPid: statusByPid, nameToPid: table,
                                window: c.wid, focused: nil, learnFrom: nil), window: c.wid)
            // Same walk, one more thing to take from it: where this window's terminal tab
            // strip is. Only a deep pass ever goes looking; every pass re-reads what it
            // found (see tabLists).
            if tabLists[c.wid] == nil, let ta = textareas.first,
               let list = findTabRowsContainer(fromTextarea: ta) {
                tabLists[c.wid] = list
            }
        }
        let t = tabs()
        return PipScan(panes: out, tabs: t.rows, selectedByWindow: t.selected,
                       tabsFresh: t.fresh, complete: !truncated)
    }

    // MARK: Terminal tab strip
    //
    // The vertical list of terminal icons beside the panel — VSCode's "Terminal tabs".
    // A status dot on each row is the only place a HIDDEN terminal's state can be shown:
    // a pane pip needs a visible pane, and with terminals stacked as tabs all but one
    // pane is gone from the tree entirely. Rows carry the same `Terminal N <title>`
    // identity the panes do, so they resolve through exactly the same machinery — and
    // inherit the same refusal to guess when the evidence names no single owner.

    // Up from a pane textarea to the terminal part of the workbench, then back down to
    // the tab strip's row container. Bounded both ways: the strip is a fixed few levels
    // from the pane in VSCode's DOM, and searching the whole window for it would be the
    // tree walk this cache exists to avoid.
    private func findTabRowsContainer(fromTextarea el: AXUIElement) -> AXUIElement? {
        var cur = el
        for _ in 0..<14 {
            guard let parent = copyAttr(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
            let classes = (copyAttr(cur, "AXDOMClassList") as? [String]) ?? []
            guard classes.contains("integrated-terminal") else { continue }
            return findByClass("monaco-list-rows", under: cur, depth: 0, limit: 8,
                               within: "tabs-list-container")
        }
        return nil
    }

    // First descendant carrying `wanted`, but only inside a subtree that has passed
    // through `within` — VSCode has several monaco lists on screen and only the one under
    // the tab strip's container is the terminal one.
    private func findByClass(_ wanted: String, under el: AXUIElement, depth: Int,
                             limit: Int, within gate: String?) -> AXUIElement? {
        guard depth < limit else { return nil }
        let classes = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
        var gate = gate
        if let g = gate, classes.contains(g) { gate = nil }
        if gate == nil, classes.contains(wanted) { return el }
        guard let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for kid in kids {
            if let hit = findByClass(wanted, under: kid, depth: depth + 1, limit: limit, within: gate) {
                return hit
            }
        }
        return nil
    }

    // "Terminal 5 ◐ jx 0270 …" / "终端 5 ◐ …" — the row's accessibility description. Same
    // two halves as a pane's (see PaneIdentity): the number is VSCode's terminal
    // instanceId and the rest is the tab name. No trailing "Run the command" here, so it
    // gets its own parse rather than sharing paneIdentity's.
    private func tabRowIdentity(_ desc: String) -> PaneIdentity? {
        let t = desc.trimmingCharacters(in: .whitespaces)
        for prefix in ["Terminal ", "终端 ", "终端"] {
            guard t.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            var rest = String(t.dropFirst(prefix.count))
            let digits = rest.prefix(while: { $0.isNumber })
            guard let index = Int(digits) else { continue }
            rest = String(rest.dropFirst(digits.count))
            if rest.hasPrefix("，") || rest.hasPrefix(",") { rest.removeFirst() }
            let title = rest.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : PaneIdentity(index: index, title: title)
        }
        return nil
    }

    // Re-read every cached tab strip. `fresh` says whether this read is entitled to be
    // treated as the whole truth — false before any deep pass has found a strip, because
    // "no rows" would then be indistinguishable from "never looked", and a caller that
    // pruned on it would delete dots it is about to re-create.
    private func readTabRows(statusByPid: [pid_t: String], manifests: Manifests,
                             boundsOf: [CGWindowID: CGRect])
        -> (rows: [pid_t: PipPane], selected: [Int: pid_t], fresh: Bool) {
        guard !tabLists.isEmpty else { return ([:], [:], false) }
        var out: [pid_t: PipPane] = [:]
        // Which terminal each window is actually SHOWING. monaco marks the active row
        // `selected` (`focused` is merely where the keyboard cursor is in the list, which
        // is not the same thing), and with terminals opened as tabs that row is the one
        // and only pane on screen in that window — the answer to "两个都有显示的话就显示
        // 当前的" that no window z-order can give, because the stacked panes share a
        // window. Verified against the pane's own `Terminal N` description.
        var selected: [Int: pid_t] = [:]
        for (wid, list) in tabLists {
            // A window that left the screen keeps its cache (it may come back with the
            // same DOM); one whose list element died loses it, so the next deep pass
            // re-finds it.
            guard let bounds = boundsOf[wid] else { continue }
            guard let rows = copyAttr(list, kAXChildrenAttribute) as? [AXUIElement], !rows.isEmpty else {
                tabLists[wid] = nil
                continue
            }
            let table = windowManifest[wid].flatMap { manifests.byFile[$0] } ?? manifests.merged
            for row in rows {
                guard let desc = copyAttr(row, kAXDescriptionAttribute) as? String,
                      let ident = tabRowIdentity(desc),
                      let rect = axFrame(row), rect.width > 2, rect.height > 2,
                      rect.intersects(bounds),
                      let pids = table[normalize(ident.title)], !pids.isEmpty else { continue }
                let live = pids.filter { statusByPid[$0] != nil }
                guard let pid = resolveOwner(index: ident.index,
                                             candidates: live.isEmpty ? pids : live,
                                             window: wid, focusedOwner: nil) else { continue }
                out[pid] = PipPane(rect: rect, window: Int(wid), windowBounds: bounds)
                if let classes = copyAttr(row, "AXDOMClassList") as? [String],
                   classes.contains("selected") {
                    selected[Int(wid)] = pid
                }
            }
        }
        return (out, selected, !tabLists.isEmpty)
    }

    // The per-pane half of a scan, shared by the focused window and the background
    // sweep: title -> candidates -> the ONE owner the evidence singles out (unresolved
    // panes are dropped, never guessed — see paneIdentityCache). `focused`/`learnFrom`
    // are nil for a background window: nothing there is focused, so there is no token
    // to learn from and only unique names / existing pins resolve.
    private func resolvePanes(_ textareas: [AXUIElement],
                              statusByPid: [pid_t: String],
                              nameToPid: [String: [pid_t]],
                              window: CGWindowID?,
                              focused: (textarea: AXUIElement, index: Int?)?,
                              learnFrom: pid_t?) -> [pid_t: CGRect] {
        var found: [pid_t: CGRect] = [:]
        for ta in textareas {
            guard let frame = paneFrame(fromTextarea: ta),
                  let ident = paneIdentity(of: ta) else { continue }
            guard let pids = nameToPid[normalize(ident.title)], !pids.isEmpty else { continue }
            // Sessions we have a live status for are the only ones worth ringing; fall
            // back to the raw list so a pane whose session just appeared still resolves
            // when it is the only candidate.
            let live = pids.filter { statusByPid[$0] != nil }
            let isFocused = focused.map {
                (ident.index != nil && ident.index == $0.index) || CFEqual(ta, $0.textarea)
            } ?? false
            guard let pid = resolveOwner(index: ident.index,
                                         candidates: live.isEmpty ? pids : live,
                                         window: window,
                                         focusedOwner: isFocused ? learnFrom : nil)
            else { continue }
            found[pid] = frame
        }
        return found
    }


    // Every measurement is memo material — this is what lets the FIRST jump to a pane
    // draw instantly instead of only the second one (see paneMemo).
    //
    // ★ The host window must be the one we actually scanned, never inferred from the
    // rect (改这里前必读). `editorWindowInfo` picks the frontmost onscreen window whose
    // bounds CONTAIN the pane's center — fine while only the focused window was ever
    // scanned (it is this app's frontmost by definition), but a background window's pane
    // sitting under another VSCode window would be recorded against the window on TOP of
    // it. recallPane's three gates would all pass and the prediction would draw a ring on
    // a different window's content — 圈错比不圈更糟. The scan knows the window id, so pass
    // it; the inference stays only as the fallback for when it doesn't.
    private func rememberScanned(_ found: [pid_t: CGRect], editorPid: pid_t, window: CGWindowID?) {
        guard !found.isEmpty else { return }
        let known = window.flatMap { wid in
            onscreenWindows(of: editorPid).first { $0.number == Int(wid) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (shellPid, rect) in found {
                self.rememberPane(shellPid, axRect: rect,
                                  window: known
                                      ?? self.editorWindowInfo(pid: editorPid, containingAX: rect))
            }
        }
    }

    // ★ Measure the panes BEFORE the jump asks for them (改 warmPaneMemo 前必读). The memo
    // above only fills in as a side effect of rings actually being drawn, so the FIRST
    // jump to a given pane still paid the full ~250-450ms resolve — and "the first jump"
    // is most jumps for a session you just started. Nothing about that measurement needs
    // the click, though: while you work in the editor, its terminal layout is sitting
    // there to be read.
    //
    // So warm the memo from the rows refresh, under three conditions that keep the AX
    // tree walk (the most expensive thing this app can do — the reason always-on rings
    // are dev-only) from becoming a background drain:
    //   ① something is actually COLD — a session in this editor with no usable memo. In
    //      the steady state every pane is warm and this costs one dictionary lookup per
    //      session and zero AX calls;
    //   ② the editor is FRONTMOST — that's when a jump is imminent and when the focused
    //      window's tree is the one you'd jump within. Also keeps us off the AX tree while
    //      you're in another app entirely;
    //   ③ throttled to `warmInterval`, so a pane that simply can't be resolved (unnamed
    //      terminal, manifest miss) can't turn into a rescan loop.
    // Always-on does this same measuring on its own schedule, so it opts out entirely.
    //
    // Panes the focused window's tree doesn't contain are handed to `sweepOtherWindows`,
    // under its own much stricter budget — read that comment before touching this.
    func warmPaneMemo(rows: [SessionRow]) {
        guard AppSettings.highlightsEnabled, !AppSettings.ringAlwaysOn,
              Date().timeIntervalSince(lastWarmScan) >= Self.warmInterval,
              let app = frontmostEditorApp() else { return }
        let editorPid = app.processIdentifier
        var statusByPid: [pid_t: String] = [:]
        var cold: Set<pid_t> = []
        for r in rows where !r.isDesktop && r.shellPid > 0 && r.editor?.rawValue == app.bundleIdentifier {
            statusByPid[r.shellPid] = r.status
            if recallPane(r.shellPid, pid: editorPid) == nil { cold.insert(r.shellPid) }
        }
        guard !cold.isEmpty else { return }
        lastWarmScan = Date()
        // A jump owns `queue` while it polls; a sweep queued in front of that poll would
        // delay the very resolve this whole feature exists to skip. armedAt/predictedTarget
        // are main-thread state, so the verdict is taken here and carried in.
        let jumpIdle = Date().timeIntervalSince(armedAt) >= Self.sweepJumpGrace
            && predictedTarget == 0
        let snapshot = statusByPid
        let coldPids = cold
        queue.async { [weak self] in
            guard let self = self else { return }
            let found = self.scanPanes(app, statusByPid: snapshot)
            guard jumpIdle, coldPids.contains(where: { found[$0] == nil }),
                  Date().timeIntervalSince(self.lastSweep) >= Self.sweepInterval else { return }
            self.lastSweep = Date()
            self.sweepOtherWindows(app, statusByPid: snapshot)
        }
    }

    // ★ Warm the panes in the editor's OTHER windows (改 sweepOtherWindows 前必读).
    // `scanPanes` can only see the focused window — its entry point is the focused
    // element, walked up to the enclosing terminal container — so a jump to a pane in
    // any other window still paid the full ~250-450ms resolve, every time. Nothing about
    // those panes is unknowable, though: their windows are sitting right there.
    //
    // This is the expensive path (no focused element to start from → the container has to
    // be FOUND by walking the window's tree), so it is fenced in five ways:
    //   ① only after the focused scan left a session cold — the common case, "everything
    //      I might jump to is in the window I'm looking at", never gets here;
    //   ② `sweepInterval` (30s) on top of warmInterval's 3s, plus a per-window backoff
    //      that doubles out to 5min for windows that keep yielding nothing (a window with
    //      no terminals at all must not be re-walked every 30s). The backoff resets when
    //      that window is moved/resized or the cold set changes — both mean "the answer
    //      may be different now";
    //   ③ same Space only — CGWindowListCopyWindowInfo(.optionOnScreenOnly) lists the
    //      current Space, which is exactly the scope recallPane's gate ② allows a
    //      prediction in anyway. Warming an off-Space pane is work nobody can spend;
    //   ④ at most `sweepWindowCap` windows per round, front-to-back (the next window you
    //      jump into is far likelier to be the one just behind), under a hard wall-clock
    //      budget — an AX walk that gets slow gets abandoned, never queued deeper;
    //   ⑤ never while a jump is in flight (see the caller).
    // Identity is unchanged and still refuses to guess: with no focused pane there is no
    // token to learn from, so only a unique name or a pin already learned in that window
    // resolves. The rest stay cold and take the old path — same as today, just less often.
    private func sweepOtherWindows(_ app: NSRunningApplication, statusByPid: [pid_t: String]) {
        let editorPid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(editorPid)
        // Deliberately NOT scanPanes' 2.0s: one stuck attribute read would blow the whole
        // round's budget, and every pane here is optional by construction.
        AXUIElementSetMessagingTimeout(axApp, Self.sweepTimeout)
        guard let wins = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement], wins.count > 1
        else { return }
        let focused = focusedWindowID(axApp)
        let onscreen = onscreenWindows(of: editorPid)   // front-to-back, current Space
        var candidates: [(win: AXUIElement, wid: CGWindowID, bounds: CGRect, rank: Int)] = []
        for win in wins {
            var wid = CGWindowID(0)
            guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0, wid != focused,
                  let rank = onscreen.firstIndex(where: { $0.number == Int(wid) })
            else { continue }
            candidates.append((win, wid, onscreen[rank].bounds, rank))
        }
        // AXWindows order is not z-order; the CG list's is.
        candidates.sort { $0.rank < $1.rank }

        let sessionKey = statusByPid.keys.sorted().map(String.init).joined(separator: ",")
        let manifests = loadManifests()
        pruneWindowManifest(manifests.byFile)
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.sweepBudget)
        var swept = 0
        var warmed = 0
        for c in candidates {
            guard swept < Self.sweepWindowCap, Date() < deadline else { break }
            if let p = sweepProbes[c.wid], p.bounds.equalTo(c.bounds), p.sessionKey == sessionKey,
               Date() < p.nextAt { continue }
            swept += 1
            var containers: [AXUIElement] = []
            findTerminalContainers(c.win, into: &containers, depth: 0, clip: c.bounds,
                                   deadline: min(deadline, Date().addingTimeInterval(Self.sweepWindowBudget)))
            var textareas: [AXUIElement] = []
            for container in containers { collectXtermTextareas(container, into: &textareas, depth: 0) }
            // Prefer this window's OWN manifest when we've learned which one it is: the
            // colliding "Claude Code" names are spread across windows, so scoping usually
            // leaves a single candidate (see windowManifest). Pin by title-set first, so
            // a window nobody ever clicked into can still resolve (see pinWindowManifest).
            pinWindowManifest(c.wid, axTitles: textareas.compactMap {
                paneIdentity(of: $0).map { normalize($0.title) }
            }, byFile: manifests.byFile)
            let table = windowManifest[c.wid].flatMap { manifests.byFile[$0] } ?? manifests.merged
            let found = resolvePanes(textareas, statusByPid: statusByPid, nameToPid: table,
                                     window: c.wid, focused: nil, learnFrom: nil)
            learnWindowManifest(c.wid, from: found.keys, fileOf: manifests.fileOf)
            noteSweep(c.wid, produced: found.count, bounds: c.bounds, sessionKey: sessionKey)
            rememberScanned(found, editorPid: editorPid, window: c.wid)
            warmed += found.count
        }
        // The only window onto a path that runs at most every 30s, behind a cold-pane gate,
        // in windows you aren't looking at. Elapsed is the number that matters — it is what
        // the budgets above exist to bound.
        // ★ Unconditional, and reports `candidates` next to `swept` (改这里前必读). Gating it
        // on `swept > 0` makes a round that got here with nothing to sweep — every window
        // still backed off, or (LOCKED screen) CGWindowList's onscreen list empty so no
        // window ranks — look exactly like a round that never ran, which is the one
        // confusion this line exists to prevent. It cost an hour of misdiagnosis once.
        // ★ A FILE, not NSLog: this bundle is ad-hoc signed and its NSLog never reaches the
        // unified log (same reason main.swift's popoverLog exists — 别退回 NSLog，那等于没有日志).
        sweepLog("windows=\(swept)/\(candidates.count) panes=\(warmed) " +
                 "\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
    }

    // One line per sweep into ~/.claude/spectix/focusring-sweep.log, self-trimming.
    private static let sweepLogStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func sweepLog(_ line: String) {
        let path = "\(NSHomeDirectory())/.claude/spectix/focusring-sweep.log"
        guard let data = "\(Self.sweepLogStamp.string(from: Date())) sweep: \(line)\n"
            .data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 128 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? data.write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    // MARK: Highlight diagnostics

    // One line per decision in a highlight's life — armed, predicted,每个 poll 的裁决,
    // withdrawn, dismissed and why — into ~/.claude/spectix/ring-diag.log, self-trimming.
    //
    // ★ Every step of this pipeline runs on `queue` and leaves NO visible trace: a highlight
    // that draws nothing looks identical to one that was never armed, and a ring withdrawn
    // by predictionGuard looks identical to one dismissed by a keystroke. That blind spot is
    // what made "跳转后不显示高亮 / 显示一下就消失" undiagnosable — the answer turned out to be
    // the third identity check vetoing every tick (see paneOwner + raiseEditorWindow's focus
    // step), which is visible ONLY as `owner=` naming panes in a window you didn't jump to.
    // Keep the poll lines printing all three judgements separately; a single "miss" tells you
    // nothing about WHICH of token / pane-shape / owner failed.
    // ★ A FILE, not NSLog — ad-hoc signed bundle, its NSLog never reaches the unified log
    // (same reason as sweepLog above, 别退回 NSLog).
    // Rects go in the log at whole-pixel precision — the reader compares them against
    // window bounds by eye, and 14 decimals per corner buries the line.
    private func fmt(_ r: CGRect) -> String {
        "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))×\(Int(r.height))"
    }

    private func fmt(_ pid: pid_t?) -> String { pid.map(String.init) ?? "nil" }

    // "nil" and "[]" mean different things here: nil = the pane's title matched nothing in the
    // manifest (no evidence, callers must not read it as a mismatch), a list = the candidates
    // it did resolve to. Keep them distinguishable in the log.
    private func fmt(_ pids: [pid_t]?) -> String {
        pids.map { $0.map(String.init).joined(separator: ",") } ?? "nil"
    }

    // ★ Locked, unlike sweepLog: that one is called from a single timer, this one is called
    // from BOTH the main thread (dismiss / present's main hop) and the background `queue`
    // (poll / track). seekToEndOfFile+write over two separate fds is not atomic across
    // threads, so racing writers overwrite each other — and what gets lost is exactly the
    // interleaving of poll verdicts against dismissals that these lines exist to show.
    private static let ringLogLock = NSLock()

    private func ringLog(_ line: String) {
        let path = "\(NSHomeDirectory())/.claude/spectix/ring-diag.log"
        Self.ringLogLock.lock()
        defer { Self.ringLogLock.unlock() }
        // Stamped inside the lock so the timestamps can't come out in a different order
        // than the lines themselves.
        guard let data = "\(Self.sweepLogStamp.string(from: Date())) \(line)\n"
            .data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 128 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? data.write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    // Record how a window's sweep went and when it may be swept again: productive windows
    // come back at the base interval, barren ones back off 30s → 1m → 2m → 5min.
    private func noteSweep(_ wid: CGWindowID, produced: Int, bounds: CGRect, sessionKey: String) {
        let misses = produced > 0 ? 0 : (sweepProbes[wid]?.misses ?? 0) + 1
        let wait = min(Self.sweepInterval * pow(2, Double(misses)), Self.sweepBackoffCap)
        sweepProbes[wid] = SweepProbe(nextAt: Date().addingTimeInterval(wait), misses: misses,
                                      bounds: bounds, sessionKey: sessionKey)
    }

    // Find the `terminal-groups-container`s in a window whose focused element we can't
    // start from. Stops AT a container (its panes are collectXtermTextareas' job) and
    // reads a frame only near the root — deeper down that extra IPC costs more than the
    // nodes it skips. ★ Deliberately no class-based pruning: a terminal can live in the
    // editor area or be dragged into a side bar, and pruning those subtrees would silently
    // lose exactly the panes this is for.
    private func findTerminalContainers(_ el: AXUIElement, into out: inout [AXUIElement],
                                        depth: Int, clip: CGRect, deadline: Date) {
        guard depth < 45, out.count < 8, Date() < deadline else { return }
        let node = classesAndChildren(el)
        if node.classes.contains(where: { $0.contains("terminal-groups-container") }) {
            out.append(el)
            return
        }
        if depth > 0, depth <= 4, let f = axFrame(el), f.isEmpty || !f.intersects(clip) { return }
        for kid in node.kids {
            findTerminalContainers(kid, into: &out, depth: depth + 1, clip: clip, deadline: deadline)
        }
    }

    // Class list + children in ONE round trip. The tree walk reads both on every node, and
    // at a few thousand nodes per window halving the IPC count is the single cheapest win
    // available here.
    private func classesAndChildren(_ el: AXUIElement) -> (classes: [String], kids: [AXUIElement]) {
        let names = ["AXDOMClassList", kAXChildrenAttribute as String] as CFArray
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(),
                                                     &out) == .success,
              let values = out as? [AnyObject], values.count == 2 else { return ([], []) }
        // Missing attributes come back as an AXValue carrying an error, which simply
        // fails these casts.
        return (values[0] as? [String] ?? [], values[1] as? [AXUIElement] ?? [])
    }

    // Onscreen (= current Space), layer-0 windows of `pid`, front-to-back. One
    // CGWindowList pass, shared by the sweep's Space filter and the memo's host-window
    // attribution.
    private func onscreenWindows(of pid: pid_t) -> [(number: Int, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [(number: Int, bounds: CGRect)] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: d) else { continue }
            out.append((num, bounds))
        }
        return out
    }

    // Reconcile overlays with the freshly scanned pane set: remove overlays whose
    // pane is no longer visible, create overlays for newly visible panes, and slide
    // existing ones to their current frame. Status color is owned by recolor.
    private func applyDesired(_ desired: [pid_t: CGRect], statusByPid: [pid_t: String]) {
        guard AppSettings.highlightsEnabled, AppSettings.ringAlwaysOn else {
            teardownAlwaysOn(); return
        }
        for pid in Array(overlays.keys) where desired[pid] == nil { removeOverlay(pid) }
        for (pid, axRect) in desired {
            let status = statusByPid[pid] ?? "working"
            if overlays[pid] != nil {
                repositionOverlay(pid, axRect: axRect)
            } else {
                createOverlay(pid, axRect: axRect, status: status)
            }
        }
        // Un-hide after a resize/switch parked overlays at alpha 0 (createOverlay
        // fades itself in; existing ones need restoring). Instant, matching the
        // instant hide, so the redraw snaps back without a lag.
        if overlaysHidden {
            overlaysHidden = false
            // …unless a system takeover still wants them gone (alwaysOnAlpha decides).
            for ov in overlays.values where ov.window.alphaValue != alwaysOnAlpha {
                ov.window.alphaValue = alwaysOnAlpha
            }
        }
        // Phase C3: a jump/click asked to emphasize a pane whose overlay may have
        // only just appeared in this scan — replay its flourish once it exists,
        // giving up after the request goes stale.
        if pendingEmphasis > 0 {
            if Date().timeIntervalSince(pendingEmphasisAt) > 8 {
                pendingEmphasis = 0
            } else if overlays[pendingEmphasis] != nil {
                rebuildOverlayContent(pendingEmphasis)
                pendingEmphasis = 0
            }
        }
    }

    private func createOverlay(_ pid: pid_t, axRect: CGRect, status: String) {
        let style = AppSettings.ringStyle(for: status)
        guard style != .off else { return }
        let accent = Status.accent(status)
        let rect = cocoaRect(fromAX: axRect)
        let frame = rect.insetBy(dx: -Self.padX, dy: -Self.padY).insetBy(dx: -Self.margin, dy: -Self.margin)
        let w = Self.makeOverlayWindow(frame: frame)
        w.contentView = RingView(frame: NSRect(origin: .zero, size: frame.size),
                                 margin: Self.margin, accent: accent,
                                 style: style, persistent: true)
        w.alphaValue = 0
        w.orderFrontRegardless()
        // Fade in only when NOTHING is parking the overlays. This used to test
        // `!systemParked` alone, so a ring born while you were in another app (a status
        // flip trips updateAlwaysOn's rising edge, which deliberately bypasses the 2s
        // scan throttle) faded itself up over that app — the always-on half of the
        // "奇怪的地方突然显示高亮" report. alwaysOnAlpha now owns every park reason.
        if alwaysOnAlpha > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                w.animator().alphaValue = 1
            }
        }
        overlays[pid] = Overlay(window: w, status: status, axRect: axRect, accentHex: accent.hexString)
        ensureSystemWatch()
    }

    // Move (and if the pane resized, rebuild) an existing overlay to a new frame.
    // A pure move keeps the running steady microglow untouched.
    private func repositionOverlay(_ pid: pid_t, axRect: CGRect) {
        guard var ov = overlays[pid] else { return }
        let rect = cocoaRect(fromAX: axRect)
        let frame = rect.insetBy(dx: -Self.padX, dy: -Self.padY).insetBy(dx: -Self.margin, dy: -Self.margin)
        let w = ov.window
        let sameSize = abs(frame.width - w.frame.width) < 0.5 && abs(frame.height - w.frame.height) < 0.5
        let sameOrigin = abs(frame.origin.x - w.frame.origin.x) < 0.5 && abs(frame.origin.y - w.frame.origin.y) < 0.5
        if sameSize && sameOrigin { return }
        if sameSize {
            w.setFrameOrigin(frame.origin)
        } else {
            w.setFrame(frame, display: true)
            let style = AppSettings.ringStyle(for: ov.status)
            guard style != .off else { return }
            let accent = Status.accent(ov.status)
            w.contentView = RingView(frame: NSRect(origin: .zero, size: frame.size),
                                     margin: Self.margin, accent: accent,
                                     style: style, persistent: true)
            ov.accentHex = accent.hexString
        }
        ov.axRect = axRect
        overlays[pid] = ov
    }

    // MARK: Phase C3 — emphasize a managed overlay on jump/click

    // A jump or manual click landed on `shellPid`. Instead of a separate one-shot
    // ring, replay the entrance flourish on that pane's steady overlay. If the
    // overlay isn't there yet (the pane was only just focused/made visible),
    // record the request and let the next rescan replay it once it appears; kick
    // an immediate rescan so it happens promptly. Also seeds currentTarget/armedAt
    // so flashFocused's "jump already handled this" dedup works.
    private func emphasize(shellPid: pid_t) {
        currentTarget = shellPid
        armedAt = Date()
        if overlays[shellPid] != nil {
            rebuildOverlayContent(shellPid)
            pendingEmphasis = 0
            return
        }
        pendingEmphasis = shellPid
        pendingEmphasisAt = Date()
        lastAXScan = .distantPast
        let map = lastStatusByPid
        queue.async { [weak self] in self?.rescanAlwaysOn(statusByPid: map) }
        // A click/jump is the one moment the owner is known EXACTLY — shellPid came from
        // the row, not from a name lookup — so pin the pane directly instead of waiting
        // for learnableOwner to catch two agreeing token observations. Deferred a beat so
        // the focus (and, on a jump, term.show) has landed; the second pass covers a slow
        // one. Without this, clicking a pane nobody has pinned draws no ring at all.
        for delay in [0.35, 1.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pinFocusedPane(to: shellPid)
                self?.rescanAlwaysOn(statusByPid: map)
            }
        }
    }

    // Record "the pane focused right now belongs to `shellPid`". Only trusted when that
    // pane's tab name actually lists shellPid as a candidate — otherwise focus has moved
    // on (or the AX tree still shows the pane we came from) and pinning would teach the
    // cache a lie. See paneIdentityCache.
    private func pinFocusedPane(to shellPid: pid_t) {
        guard let app = activeEditorApp(), app.isActive else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let focus = focusedTerminalGroupsContainer(axApp),
              let ident = paneIdentity(of: focus.textarea), let index = ident.index,
              let window = focusedWindowID(axApp),
              let pids = loadManifestNameToPid()[normalize(ident.title)],
              pids.contains(shellPid) else { return }
        paneIdentityCache[window, default: [:]][index] = shellPid
        panePinsDirty = true
        savePanePinsIfDirty()
    }

    // MARK: Phase C1/C2 — layout & focus observers

    // NSWorkspace-level triggers (C2): app activation and Space changes. Leaving
    // VSCode hides the overlays (they float top-most and would otherwise cover
    // whatever app you switched to); returning re-scans and un-hides. Idempotent.
    private func installAlwaysOnObservers() {
        guard alwaysOnObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        alwaysOnObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Any VSCode-family editor coming to the front re-scans its panes; switching
            // to a non-editor app hides the overlays (they float top-most).
            if EditorApp(rawValue: app?.bundleIdentifier ?? "") != nil { self?.kickRescan() }
            else { self?.hideAllOverlays() }
        })
        alwaysOnObservers.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.kickRescan() })
    }

    private func removeAlwaysOnObservers() {
        alwaysOnObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        alwaysOnObservers = []
    }

    // AX observer (C1): fires immediately on window resize/move/miniaturize and
    // focused-window change — none of which NSWorkspace reports. Registered on the
    // VSCode app element for focused-window-change, and on the focused window for
    // resize/move/(de)miniaturize. Re-registered on the new window when focus moves.
    private func installResizeObserver(pid: pid_t) {
        if observerPid == pid, axObserver != nil { refreshObservedWindow(); return }
        removeResizeObserver()
        var obs: AXObserver?
        guard AXObserverCreate(pid, ringAXObserverCallback, &obs) == .success,
              let obs = obs else { return }
        axObserver = obs
        observerPid = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            obs, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        refreshObservedWindow()
    }

    // Point the window-level notifications at the currently focused window. No-op
    // when it hasn't changed; otherwise unhooks the old window and hooks the new.
    private func refreshObservedWindow() {
        guard let obs = axObserver, observerPid > 0 else { return }
        let axApp = AXUIElementCreateApplication(observerPid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let winRef = copyAttr(axApp, kAXFocusedWindowAttribute) else { return }
        let window = winRef as! AXUIElement
        if let prev = observedWindow, CFEqual(prev, window) { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let prev = observedWindow {
            for n in Self.windowNotifs { AXObserverRemoveNotification(obs, prev, n as CFString) }
        }
        for n in Self.windowNotifs { AXObserverAddNotification(obs, window, n as CFString, refcon) }
        observedWindow = window
    }

    private func removeResizeObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        observedWindow = nil
        observerPid = 0
        layoutDebounce?.cancel()
        layoutDebounce = nil
    }

    // Called from the C callback (main thread). Resize/move/deminiaturize and
    // focused-window change all mean "the panes moved" → hide now, redraw when it
    // settles. Miniaturize just hides (nothing to redraw until restored).
    fileprivate func handleAXLayoutNotification(_ name: String) {
        guard AppSettings.highlightsEnabled, AppSettings.ringAlwaysOn else { return }
        switch name {
        case kAXWindowMiniaturizedNotification:
            hideAllOverlays()
        case kAXFocusedWindowChangedNotification:
            refreshObservedWindow()
            onLayoutEvent()
        default:   // resized / moved / deminiaturized
            onLayoutEvent()
        }
    }

    // Hide the overlays instantly, then (re)arm a debounce: while events keep
    // arriving (an active drag) we stay hidden; ~0.35s after the last one we
    // rescan and redraw at the settled positions.
    private func onLayoutEvent() {
        hideAllOverlays()
        layoutDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleLayout() }
        layoutDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func settleLayout() {
        lastAXScan = .distantPast
        let map = lastStatusByPid
        queue.async { [weak self] in self?.rescanAlwaysOn(statusByPid: map) }
    }

    // Park every overlay at alpha 0 (instant — a fade would lag the drag). The
    // next applyDesired restores them. `overlaysHidden` tells applyDesired to.
    private func hideAllOverlays() {
        guard !overlays.isEmpty else { return }
        overlaysHidden = true
        for ov in overlays.values { ov.window.alphaValue = 0 }
    }

    // Force the throttle open and rescan now (C2 focus/space triggers).
    private func kickRescan() {
        guard AppSettings.highlightsEnabled, AppSettings.ringAlwaysOn else { return }
        lastAXScan = .distantPast
        let map = lastStatusByPid
        queue.async { [weak self] in self?.rescanAlwaysOn(statusByPid: map) }
    }

    // MARK: Always-on AX helpers

    // The focused element must be an xterm textarea; walk up to the enclosing
    // `terminal-groups-container` (the subtree holding all visible split panes of
    // the focused window's active terminal group). nil when focus isn't in a
    // terminal — the caller then leaves the last overlay set in place.
    //
    // The focused textarea comes back with it: among the panes collected from the
    // container, it is the ONE whose owner the active-terminal token identifies, which
    // is how resolveOwner learns a number→session pin (see paneIdentityCache).
    private func focusedTerminalGroupsContainer(
        _ axApp: AXUIElement
    ) -> (container: AXUIElement, textarea: AXUIElement)? {
        guard let focused = copyAttr(axApp, kAXFocusedUIElementAttribute) else { return nil }
        let textarea = focused as! AXUIElement
        var el = textarea
        let classes = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
        guard classes.contains(where: { $0.contains("xterm-helper-textarea") }) else { return nil }
        for _ in 0..<40 {
            let cls = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
            if cls.contains(where: { $0.contains("terminal-groups-container") }) {
                return (el, textarea)
            }
            guard let parent = copyAttr(el, kAXParentAttribute) else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }

    // DFS the subtree collecting every xterm-helper-textarea (one per pane).
    private func collectXtermTextareas(_ el: AXUIElement, into out: inout [AXUIElement], depth: Int) {
        guard depth < 45 else { return }
        let classes = (copyAttr(el, "AXDOMClassList") as? [String]) ?? []
        if classes.contains(where: { $0.contains("xterm-helper-textarea") }) { out.append(el) }
        guard let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for kid in kids { collectXtermTextareas(kid, into: &out, depth: depth + 1) }
    }

    // Walk up from a textarea to the first ancestor with a real on-screen extent
    // (= .xterm-screen, the pane frame). Shared with the one-shot focused-pane path.
    private func paneFrame(fromTextarea el: AXUIElement) -> CGRect? {
        var cur = el
        for _ in 0..<6 {
            guard let parent = copyAttr(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
            if let f = axFrame(cur), f.width >= 100, f.height >= 40 { return f }
        }
        return nil
    }

    // What VSCode's accessibility label says a pane IS: "终端 N，<title> 运行命令"
    // (or "Terminal N, <title> Run the command: …"). Both halves matter and the number is
    // NOT decoration — see paneIdentityCache for why the title alone is not an
    // identity.
    private struct PaneIdentity {
        /// The "终端 N" number = VSCode's terminal instanceId. Unique within its
        /// window and stable for that terminal's whole life. nil when the label
        /// carries no number (unknown locale / older VSCode).
        let index: Int?
        /// The tab name, tail stripped. Still needs normalize() before matching.
        let title: String
    }

    // ★ This tail is VSCode's wording, and VSCode CHANGES it (改这里前必读). It read
    // "<title> run command" for years; by 2026-08 it reads "<title> Run the command:
    // Toggle Screen Reader Accessibility Mode …". Nothing announces the change — the
    // parse simply returns nil for every pane, no pane resolves an owner, and every
    // feature built on pane identity (rings, pips, pane-level jump) silently degrades
    // to "only the pane you just clicked is known". Measured on the day it broke: the
    // deep sweep found 8 panes across 4 windows and named 0 of them.
    // So: match case-insensitively, ADD new spellings rather than replacing old ones
    // (older VSCode builds are still out there), and order longest-first so a prefix
    // never shadows the longer form it lives inside.
    private static let paneDescTails = [" 运行命令", " run the command", " run command"]

    // A pane's identity, read from the textarea's AXDescription. Present only when the
    // desc carries one of the tails above (idle/stale panes lack it). The leading status
    // glyph is stripped later by normalize().
    private func paneIdentity(of textarea: AXUIElement) -> PaneIdentity? {
        guard let desc = copyAttr(textarea, kAXDescriptionAttribute) as? String else { return nil }
        guard let tail = Self.paneDescTails
                .compactMap({ desc.range(of: $0, options: .caseInsensitive) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        var head = String(desc[desc.startIndex..<tail.lowerBound])
        var index: Int?
        if let comma = head.range(of: "，") ?? head.range(of: ", ") {
            let digits = head[head.startIndex..<comma.lowerBound]
                .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            index = Int(digits)
            head = String(head[comma.upperBound...])
        }
        let title = head.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : PaneIdentity(index: index, title: title)
    }

    private func paneTitle(of textarea: AXUIElement) -> String? {
        paneIdentity(of: textarea)?.title
    }

    // Canonical form for matching pane titles to manifest names: trim, then drop a
    // single leading status glyph (spinner ⠂…, ✳ etc. — any leading char that's
    // neither alphanumeric nor CJK).
    private func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let first = t.unicodeScalars.first,
           !CharacterSet.alphanumerics.contains(first), !isCJK(first) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private func isCJK(_ u: UnicodeScalar) -> Bool {
        switch u.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F,
             0xFF00...0xFFEF, 0x2E80...0x2EFF: return true
        default: return false
        }
    }

    // MARK: Pane identity — which session owns THIS pane
    //
    // ★ Why a name is not an identity (改 resolveOwner / paneIdentityCache 前必读):
    // the manifest keys panes by their tab NAME, and Claude Code titles every session
    // that has no task summary to show "✳ Claude Code" — glyph included, and normalize()
    // strips the glyph on purpose (so one terminal keeps matching as its status flips).
    // So four live sessions collapse onto the single key "Claude Code". The old code
    // then took `pids.first(where: hasStatus)`, i.e. ALWAYS the same candidate, and every
    // colliding pane got that one session's color — an idle session painting a running
    // pane gray ("高亮全都是默认的灰色"), plus `desired[pid]` collapsing two panes into one
    // overlay so the ring could sit on the wrong terminal and a clicked row's emphasize()
    // never found its overlay ("点击后不一定能跳对").
    //
    // The fix keys on the ONE thing that is unique per pane — `终端 N`, VSCode's terminal
    // instanceId — and learns `N -> shellPid` from the ONE source that is never ambiguous:
    // the extension's active-terminal token, which focusByPid writes by exact pid match.
    // Every time you land in a terminal, that pane's number is pinned. Panes nobody has
    // ever focused stay unresolved and are simply NOT drawn: guessing is what caused the
    // bug, and 圈错比不圈更糟 (see the window-fallback note at the top of this file).
    //
    // ★ Keyed by WINDOW id, not editor pid (改这里前必读). `终端 N` restarts at 1 in every
    // window while one VSCode process hosts them all, so keying by pid made every window's
    // pane #1 share a slot: the TB window pinned `1 → its own shell`, and the .claude
    // window's pane #1 then resolved to that foreign pid, failed the candidate test and
    // drew no ring at all. Window ids are globally unique, which is exactly the scope the
    // number has.
    //
    // Stale pins are harmless without any pruning: a pin is only honored while it is still
    // one of the pane's live candidates, so a closed terminal (or a reopened window
    // restarting the counter at 1) simply falls through to "unresolved". Touched only on
    // `queue`, which is serial and carries both poll() and rescanAlwaysOn().
    private var paneIdentityCache: [CGWindowID: [Int: pid_t]] = [:]

    // ★ The cache survives app restarts on disk (改这里前必读). A pin is learned from a
    // click or a jump — and it used to die with the process, so every SpectiX restart
    // sent the user back to clicking each same-named terminal once before its dot /
    // ring / pane-jump worked again. Persisting is safe for the same reason stale pins
    // always were: a loaded pin is only ever HONORED while it is still one of the
    // pane's live candidates (paneOwner / resolveOwner both check), so a recycled pid,
    // a closed terminal, or a restarted editor window all just fall through to
    // "unresolved" — the merge below can't make anything up, only remember. CG window
    // ids are stable for the lifetime of the editor's window, which is exactly the
    // lifetime the pins are scoped to. Load/save on `queue` only, like the cache.
    private var panePinsLoaded = false
    private var panePinsDirty = false
    private var panePinsPath: String { "\(NSHomeDirectory())/.claude/spectix/pane-pins.json" }

    private func loadPanePinsIfNeeded() {
        guard !panePinsLoaded else { return }
        panePinsLoaded = true
        guard let data = FileManager.default.contents(atPath: panePinsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]]
        else { return }
        for (w, pins) in obj {
            guard let wid = UInt32(w) else { continue }
            for (i, pid) in pins {
                guard let index = Int(i) else { continue }
                // Live learning wins over the disk copy.
                if paneIdentityCache[CGWindowID(wid), default: [:]][index] == nil {
                    paneIdentityCache[CGWindowID(wid), default: [:]][index] = pid_t(pid)
                }
            }
        }
    }

    private func savePanePinsIfDirty() {
        guard panePinsDirty else { return }
        panePinsDirty = false
        var obj: [String: [String: Int]] = [:]
        for (wid, pins) in paneIdentityCache {
            var m: [String: Int] = [:]
            for (i, pid) in pins { m[String(i)] = Int(pid) }
            obj[String(wid)] = m
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: panePinsPath), options: .atomic)
        }
    }

    // The CG window id of the editor window focus is currently in — the scope a pane
    // number is unique within.
    private func focusedWindowID(_ axApp: AXUIElement) -> CGWindowID? {
        guard let win = copyAttr(axApp, kAXFocusedWindowAttribute) else { return nil }
        var wid = CGWindowID(0)
        guard _AXUIElementGetWindow(win as! AXUIElement, &wid) == .success,
              wid != 0 else { return nil }
        return wid
    }

    // The single session owning a pane, or nil when the evidence doesn't single one out.
    // `focusedOwner` is the token's pid and must be passed ONLY for the pane that is
    // actually focused — that is what makes it proof rather than a guess, and pinning it
    // against any other pane's number would poison the cache.
    private func resolveOwner(index: Int?, candidates: [pid_t],
                              window: CGWindowID?, focusedOwner: pid_t?) -> pid_t? {
        if candidates.count == 1 { return candidates[0] }
        if let owner = focusedOwner, candidates.contains(owner) {
            if let index, let window {
                paneIdentityCache[window, default: [:]][index] = owner
                panePinsDirty = true
            }
            return owner
        }
        if let index, let window, let pinned = paneIdentityCache[window]?[index],
           candidates.contains(pinned) { return pinned }
        return nil
    }

    /// Last (window, focused pane number, token pid) seen — the previous half of the
    /// agreement `learnableOwner` needs. The window is part of it because focus moving
    /// between windows must never be mistaken for a repeat. Touched only on `queue`.
    private var lastFocusObservation: (window: CGWindowID, index: Int, pid: pid_t)?

    // The token pid, but only once AX and the token AGREE TWICE IN A ROW about the same
    // pane. Electron's AX tree can lag the extension's write (poll()'s double identity
    // check documents the same hazard): for one tick the token already names the new
    // terminal while kAXFocusedUIElement still resolves to the previous pane, and pinning
    // then teaches the cache the wrong number. Two consecutive matching observations mean
    // the tree settled.
    //
    // ★ Do NOT go back to gating on the token file's mtime (改这里前必读). "Wait until the
    // write is ≥0.6s old" sounds equivalent and is not: measured, that condition was
    // essentially never true (`token=-` on nearly every scan), because focusing a terminal
    // and switching windows both rewrite the token and the rescan fires several times a
    // second — so the cache never learned anything and every colliding pane went
    // unresolved, i.e. no ring at all. Agreement is about the DATA settling; a timestamp
    // only says when a file was last touched.
    private func learnableOwner(window: CGWindowID?, focusedIndex: Int?,
                                editorActive: Bool) -> pid_t? {
        guard editorActive, let window, let index = focusedIndex,
              let pid = anyFocusReport() else {
            lastFocusObservation = nil
            return nil
        }
        defer { lastFocusObservation = (window, index, pid) }
        guard let prev = lastFocusObservation,
              prev.window == window, prev.index == index, prev.pid == pid else { return nil }
        return pid
    }

    // The extension writes one manifest per window (`terminals-<extHostPid>.json`, and
    // each VSCode window runs its own extension host), so the per-file split is the
    // window split — which is what lets a background window's colliding "Claude Code"
    // panes resolve at all (see windowManifest).
    private struct Manifests {
        /// All windows merged, name -> [shellPid]. Names are normalize()d so pane-title
        /// lookups line up.
        let merged: [String: [pid_t]]
        /// file name -> that window's own name -> [shellPid].
        let byFile: [String: [String: [pid_t]]]
        /// shellPid -> the file that listed it. Unambiguous because pids are unique
        /// system-wide, which is what makes the window binding evidence and not a guess.
        let fileOf: [pid_t: String]
    }

    private func loadManifests() -> Manifests {
        let dir = "\(NSHomeDirectory())/.claude/spectix"
        var merged: [String: [pid_t]] = [:]
        var byFile: [String: [String: [pid_t]]] = [:]
        var fileOf: [pid_t: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return Manifests(merged: merged, byFile: byFile, fileOf: fileOf) }
        for f in files where f.hasPrefix("terminals-") && f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            for entry in arr {
                let pidVal = (entry["pid"] as? Int) ?? (entry["pid"] as? NSNumber)?.intValue
                guard let pid = pidVal, let name = entry["name"] as? String else { continue }
                merged[normalize(name), default: []].append(pid_t(pid))
                byFile[f, default: [:]][normalize(name), default: []].append(pid_t(pid))
                fileOf[pid_t(pid)] = f
            }
        }
        return Manifests(merged: merged, byFile: byFile, fileOf: fileOf)
    }

    // Merged-only, kept separate on purpose: `track()` calls this every 0.2s from the
    // MAIN thread, where building the extra tables would be waste and touching
    // `windowManifest` would race the scans on `queue`.
    private func loadManifestNameToPid() -> [String: [pid_t]] {
        let dir = "\(NSHomeDirectory())/.claude/spectix"
        var map: [String: [pid_t]] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return map }
        for f in files where f.hasPrefix("terminals-") && f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            for entry in arr {
                let pidVal = (entry["pid"] as? Int) ?? (entry["pid"] as? NSNumber)?.intValue
                guard let pid = pidVal, let name = entry["name"] as? String else { continue }
                map[normalize(name), default: []].append(pid_t(pid))
            }
        }
        return map
    }

    // A window whose editor was reloaded gets a new extension host = a new manifest file;
    // the old binding would then find no candidates and quietly stop resolving anything.
    // `queue` only, like the binding itself.
    private func pruneWindowManifest(_ byFile: [String: [String: [pid_t]]]) {
        guard !windowManifest.isEmpty else { return }
        windowManifest = windowManifest.filter { byFile[$0.value] != nil }
    }


    // ★ The click-free half of window→manifest binding (改这里前必读). learnWindowManifest
    // needs one RESOLVED pane to bind a window to its manifest file — but resolution in a
    // background window mostly needs the binding first (the colliding "✳ Claude Code"
    // names only separate once candidates are scoped to one window). Chicken and egg,
    // and the egg used to be a click. This breaks it with evidence, not a guess: the AX
    // pane-title multiset of the window is matched against every manifest file's name
    // multiset, and ONLY a unique fit pins. A window showing just "zsh" fits many files —
    // no pin; one distinctive task title narrows it to the one extension host that lists
    // it. Validation runs first and unpins a binding the titles no longer fit (terminal
    // tabs can be dragged between windows; a stale pin resolves panes against another
    // window's sessions, and a dot showing somebody else's status is the one forbidden
    // outcome). Touched on `queue` only, like every windowManifest access.
    private func pinWindowManifest(_ window: CGWindowID, axTitles: [String],
                                   byFile: [String: [String: [pid_t]]]) {
        guard !axTitles.isEmpty else { return }
        var need: [String: Int] = [:]
        for t in axTitles { need[t, default: 0] += 1 }
        func fits(_ names: [String: [pid_t]]) -> Bool {
            need.allSatisfy { (names[$0.key]?.count ?? 0) >= $0.value }
        }
        if let file = windowManifest[window], let names = byFile[file], !fits(names) {
            windowManifest[window] = nil
        }
        guard windowManifest[window] == nil else { return }
        let fitting = byFile.filter { fits($0.value) }
        if fitting.count == 1 { windowManifest[window] = fitting.first!.key }
    }

    // Bind a window to the manifest its terminals are listed in, learned from any pane
    // we already resolved there — the pid is unique system-wide, so the file that lists
    // it IS this window's. Only ever narrows the candidate set; a window we never learn
    // keeps using the merged table.
    private func learnWindowManifest(_ window: CGWindowID?, from pids: Dictionary<pid_t, CGRect>.Keys,
                                     fileOf: [pid_t: String]) {
        guard let window, windowManifest[window] == nil else { return }
        for pid in pids {
            if let file = fileOf[pid] { windowManifest[window] = file; return }
        }
    }
}

// The ring itself, in the user's chosen style (AppSettings.ringStyle(for:)):
//
// .breath — a glowing stroke that snaps onto the target then breathes three
//   times (bright at the start and at each rebound), the last breath continuing
//   down to zero so the disappearance rides the rhythm, never cutting a pulse.
// .ripple — a steady glowing stroke anchors the pane while sonar waves born on
//   its edge swell outward and thin to nothing, then the anchor fades out.
// .sweep — a comet: one bright glowing arc orbits the pane edge three laps,
//   then fades out.
// .corners — camera-viewfinder brackets fly in and snap onto the four corners,
//   blink twice like a locked focus box, then fade.
// .converge — reverse sonar: rings born wide at the window margin collapse
//   onto the pane edge, brightening on approach; the anchor they land on
//   builds up glow and fades out last.
// .neon — the stroke sputters unevenly to life like a neon tube powering on,
//   holds a steady saturated glow, then dims away.
// .ants — a classic marching-ants dashed border crawling around the pane.
//
// Every animation ends at opacity 0 and holds there; `lifetime` is when it's
// all over — show() (and the settings preview) schedule teardown/replay off it.
// Internal (not private): the settings window instantiates it over a mock pane
// so the user picks a style by watching the real thing.
final class RingView: NSView {
    let lifetime: TimeInterval
    private static let steadyHold: Float = 0.8   // resting opacity of the always-on microglow

    // Titlebar geometry (caption style .titlebar): the bar sits INSIDE the ring,
    // its top edge on the pane's top edge — the label rides on the terminal itself
    // instead of floating above the highlight, so it reads as part of the target.
    // The overlay frame therefore needs no extra room above the margin band.
    static let titlebarHeight: CGFloat = 32
    static let closeSize: CGFloat = 22    // ✕ hotspot square (click-catcher panel)
    static let closeInset: CGFloat = 5    // hotspot gap from the bar's right edge
    // Whether this caption renders as the in-ring titlebar (vs. one of the pill
    // styles, or nothing at all) — the ✕ catcher panel is only attached for it.
    static func hasTitlebar(project: String, task: String) -> Bool {
        AppSettings.captionEnabled && AppSettings.captionStyle == .titlebar
            && !(project.isEmpty && task.isEmpty)
    }
    // The project's source badge, drawn at the head of the caption (nil = title only).
    private let icon: LogoBadge.Mode?

    init(frame: NSRect, margin: CGFloat, accent: NSColor, style: AppSettings.RingStyle,
         persistent: Bool = false, project: String = "", task: String = "",
         icon: LogoBadge.Mode? = nil,
         drawRing: Bool = true, suppressCaption: Bool = false) {
        // Caption-only draws (drawRing false) skip the ring entirely; a titlebar
        // caption then renders as a static bar (no animated outline wraps it).
        self.icon = icon
        let flourishLife: TimeInterval
        switch style {
        case .ripple:   flourishLife = 3.6
        case .sweep:    flourishLife = 3.8
        case .corners:  flourishLife = 3.4
        case .converge: flourishLife = 3.6
        case .neon:     flourishLife = 3.6
        case .ants:     flourishLife = 3.4
        default:        flourishLife = 0.25 + 5 * 0.7 + 0.1
        }
        // Persistent overlays never self-destruct — the always-on manager owns
        // their teardown, so no lifetime timer should fire.
        lifetime = persistent ? .infinity : flourishLife
        super.init(frame: frame)
        wantsLayer = true
        // Steady base first so the flourish (which fades to 0) plays on top and
        // reveals the microglow beneath as it clears.
        if persistent { addSteadyBase(margin: margin, accent: accent, style: style) }
        // Caption-only draw: no ring strokes at all, just the label below.
        if drawRing {
            switch style {
            case .ripple:   buildRipple(margin: margin, accent: accent)
            case .sweep:    buildSweep(margin: margin, accent: accent)
            case .corners:  buildCorners(margin: margin, accent: accent)
            case .converge: buildConverge(margin: margin, accent: accent)
            case .neon:     buildNeon(margin: margin, accent: accent)
            case .ants:     buildAnts(margin: margin, accent: accent)
            default:        buildBreath(margin: margin, accent: accent)
            }
        }
        if !suppressCaption, AppSettings.captionEnabled, !(project.isEmpty && task.isEmpty) {
            addCaption(project: project, task: task, margin: margin, accent: accent)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Ring geometry

    // The pane rect the ring strokes trace: the view bounds inset by the animation
    // margin. The titlebar caption lives INSIDE this rect, so nothing is reserved
    // above it.
    private func paneRect(_ margin: CGFloat) -> CGRect {
        bounds.insetBy(dx: margin, dy: margin)
    }

    // Rounded-rect stroke path over the pane. Every ring path (base stroke,
    // entrance snap, sonar waves) goes through here so they all wrap the same box.
    private func ringPath(_ rect: CGRect, r: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // MARK: - Caption (project · task) at the ring's top-center
    //
    // Names the target — the project plus this session's task summary — so a glance
    // at where you landed also tells you WHAT it's doing. Four styles from the design
    // shortlist (Design/ring-caption.html), picked in Settings. The pill styles sit in
    // the top margin band just above the pane edge (never covering terminal content);
    // `titlebar` is an external bar the animated ring outline wraps together
    // with the pane (one box, top corners hugging the bar).
    private static let capPjColor = NSColor.white
    private static let capTkColor = NSColor(calibratedWhite: 0.62, alpha: 1)   // ≈ #9e9e9e
    private static let capBand: CGFloat = 22   // pill height; fits inside the 24pt margin
    private static let capPillBadge: CGFloat = 15   // source badge inside a 22pt pill
    private static let capBarBadge: CGFloat = 19    // …and inside the 32pt titlebar
    // ★ Narrow-pane floor (改 caption 布局前必读): the title must always be the LAST
    // thing to lose room. Every style budgets its fixed chrome first (✕ slot, dot/rule,
    // padding), then drops the badge if what remains can't seat at least this much
    // text, and only then truncates. The old layout skipped both steps and handed the
    // remainder — often near zero, sometimes negative — straight to the text layer, so
    // a slim terminal drew a bar with no label at all and read as "标签没显示".
    private static let capMinText: CGFloat = 34
    private static let capMaxLines = 3   // hover expansion ceiling

    // Caption inputs kept so a hover expand/collapse can re-lay the label in place
    // without rebuilding the whole RingView (which would restart the ring animation).
    private var capProject = ""
    private var capTask = ""
    private var capAccent: NSColor = .white
    private var capMargin: CGFloat = 0
    private var captionRoot: CALayer?
    private var captionExpanded = false
    // The caption's own rect in view coords (empty when nothing is drawn) — what the
    // hover hit-test converts to screen space. It follows the expansion, which is what
    // gives the hover its hysteresis.
    private(set) var captionHitRect: CGRect = .zero
    // The title had to truncate, so a hover has something to reveal. Every style grows
    // DOWNWARD into the pane: the titlebar from the pane's top edge, the pills from
    // their fixed top edge in the margin band (there is nothing but margin above them).
    private(set) var captionCanExpand = false

    private func addCaption(project: String, task: String, margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        capProject = project; capTask = task; capMargin = margin; capAccent = accent
        captionHitRect = .zero
        captionCanExpand = false
        // Floor = the ✕ slot plus a sliver of title. Anything narrower can't say
        // anything useful, and the styles below assume a positive text budget.
        guard inset.width > Self.closeSize + Self.closeInset * 2 + Self.capMinText else { return }
        // Crisp text needs the text layer's contentsScale to match the Retina backing.
        // NSScreen.main can be the wrong (non-Retina) screen at draw time, so take the
        // sharpest available scale (never below 2 = Retina) rather than risk a 1× blur.
        let scale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 2)
        let maxW = inset.width - 8
        switch AppSettings.captionStyle {
        case .hidden:     break // caption off; belt-and-suspenders (callers gate on captionEnabled)
        case .titlebar:   addTitlebar(project: project, task: task, inset: inset, accent: accent, scale: scale)
        case .segmented:  addSegmented(project: project, task: task, inset: inset, maxW: maxW, accent: accent, scale: scale)
        case .accentRule: addAccentRule(project: project, task: task, inset: inset, maxW: maxW, accent: accent, scale: scale)
        case .outlineDot: addOutlineDot(project: project, task: task, inset: inset, maxW: maxW, accent: accent, scale: scale)
        }
    }

    // Hover expand/collapse: re-lay the caption alone, leaving the ring's animation
    // layers untouched (a full RingView rebuild would restart the breathing loop).
    // Expanding is refused unless the title actually truncated — there is nothing to
    // reveal otherwise, and a bar that grows for no reason just eats terminal rows.
    // Returns whether anything changed.
    @discardableResult
    func setCaptionExpanded(_ on: Bool) -> Bool {
        if on && !captionCanExpand { return false }
        guard on != captionExpanded else { return false }
        captionExpanded = on
        captionRoot?.removeFromSuperlayer()
        captionRoot = nil
        // No implicit animation: CALayer would cross-fade the swap into a flicker.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addCaption(project: capProject, task: capTask, margin: capMargin, accent: capAccent)
        CATransaction.commit()
        return true
    }

    // MARK: Caption source badge (left of the title)

    // The project's badge — the SAME tile the list header shows (custom emoji, else
    // VS/CU/WS monogram, desktop asterisk, native-terminal glyph) — drawn as a layer
    // so the label on the terminal names its project the way the row does. nil (no
    // icon passed) → the caption lays out exactly as before, title flush left.
    private static let capBadgeGap: CGFloat = 7

    // Width the badge claims in a caption line, gap included; 0 when there's none —
    // or when the caller dropped it to buy the title room (`show: false`).
    private func badgeSlot(_ side: CGFloat, show: Bool = true) -> CGFloat {
        (icon == nil || !show) ? 0 : side + Self.capBadgeGap
    }

    // Place the badge at `x`, vertically centered in a `height`-tall line whose bottom
    // sits at `yOffset`, and return the x the text should start at (unchanged when
    // there's no badge). `yOffset` is what keeps the icon on the FIRST line once a
    // hover-expanded titlebar has grown downward beneath it.
    private func addBadge(to parent: CALayer, x: CGFloat, side: CGFloat,
                          height: CGFloat, scale: CGFloat,
                          show: Bool = true, yOffset: CGFloat = 0) -> CGFloat {
        guard show, let mode = icon else { return x }
        let b = Self.badgeLayer(mode, side: side, scale: scale)
        b.frame = CGRect(x: x, y: (yOffset + (height - side) / 2).rounded(), width: side, height: side)
        parent.addSublayer(b)
        return x + side + Self.capBadgeGap
    }

    // A CALayer rendering of LogoBadge: gradient tile + one glyph. The glyph is
    // rasterized into an image rather than drawn by a CATextLayer so emoji keep their
    // color and an SF Symbol can be tinted white the way the view-based badge does.
    private static func badgeLayer(_ mode: LogoBadge.Mode, side: CGFloat, scale: CGFloat) -> CALayer {
        let r = LogoBadge.recipe(mode)
        let tile = CAGradientLayer()
        tile.cornerRadius = side * 0.27
        tile.cornerCurve = .continuous
        tile.startPoint = CGPoint(x: 0.1, y: 0.95)   // same ~140° diagonal as the header badge
        tile.endPoint = CGPoint(x: 0.9, y: 0.05)
        tile.colors = r.colors.map(\.cgColor)
        tile.contentsScale = scale
        let box = CGSize(width: side, height: side)
        // An uploaded icon replaces the tile rather than riding on it (same edge-to-edge,
        // rounded-clipped treatment as the header badge), so it short-circuits the glyphs.
        if let img = r.image {
            tile.contents = img
            tile.contentsGravity = .resizeAspectFill
            tile.masksToBounds = true
            return tile
        }
        var glyph: NSImage?
        if let m = r.monogram {
            glyph = centeredImage(NSAttributedString(string: m, attributes: [
                .font: Theme.rounded(side * 0.42, .heavy),
                .foregroundColor: NSColor.white]), box: box)
        } else if let s = r.symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.48, weight: .bold)
            glyph = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
                .map { tinted($0, .white) }
        } else if let e = r.emoji {
            glyph = centeredImage(NSAttributedString(string: e, attributes: [
                .font: NSFont.systemFont(ofSize: side * 0.6)]), box: box)
        }
        if let g = glyph {
            let inner = CALayer()
            inner.frame = CGRect(origin: .zero, size: box)
            inner.contents = g
            inner.contentsGravity = .center
            inner.contentsScale = scale
            tile.addSublayer(inner)
        }
        return tile
    }

    // Rasterize `attr` centered in a `box`-sized image.
    private static func centeredImage(_ attr: NSAttributedString, box: CGSize) -> NSImage {
        let img = NSImage(size: box)
        img.lockFocus()
        let s = attr.size()
        attr.draw(at: NSPoint(x: ((box.width - s.width) / 2).rounded(),
                              y: ((box.height - s.height) / 2).rounded()))
        img.unlockFocus()
        return img
    }

    // Recolor a template-ish symbol image (SF Symbols render black by default when
    // drawn outside an NSImageView that would tint them).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let r = NSRect(origin: .zero, size: image.size)
        image.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    // A one-line "project<sep>task" attributed string: project semibold in `pj`,
    // task regular in the muted color. Empty task → just the project.
    private func captionAttr(_ project: String, _ task: String, sep: String,
                             pj: NSColor, pjWeight: NSFont.Weight = .semibold,
                             size: CGFloat = 12) -> NSAttributedString {
        let s = NSMutableAttributedString(string: project, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: pjWeight), .foregroundColor: pj])
        if !task.isEmpty {
            s.append(NSAttributedString(string: sep + task, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .regular),
                .foregroundColor: Self.capTkColor]))
        }
        return s
    }

    // `attr` cut down to what fits in `width`, with an ellipsis appended — the truncation
    // CATextLayer refuses to do on a one-line frame (see captionText). Cuts land on
    // composed-character boundaries so an emoji or a combining sequence is never halved,
    // and the ellipsis inherits the attributes of the character it replaces, so a cut
    // inside the project name stays semibold-white and one inside the task stays muted.
    // Binary search over those boundaries: ~7 width measurements for a 100-char title.
    private static func truncateToFit(_ attr: NSAttributedString, width: CGFloat) -> NSAttributedString {
        guard ceil(attr.size().width) > width else { return attr }
        let ns = attr.string as NSString
        guard ns.length > 0 else { return attr }
        var bounds: [Int] = [0]
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            i = r.location + r.length
            bounds.append(i)
        }
        func candidate(_ k: Int) -> NSAttributedString {
            let len = bounds[k]
            let m = NSMutableAttributedString(
                attributedString: attr.attributedSubstring(from: NSRange(location: 0, length: len)))
            m.append(NSAttributedString(string: "…",
                                        attributes: attr.attributes(at: max(0, len - 1),
                                                                    effectiveRange: nil)))
            return m
        }
        var lo = 0, hi = bounds.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ceil(candidate(mid).size().width) <= width { lo = mid } else { hi = mid - 1 }
        }
        // lo == 0 means even a bare "…" overruns the budget; drawing it still beats a
        // blank pill, and the frame below clips it to whatever room there is.
        return candidate(lo)
    }

    // A single-line text layer for `attr`, truncated to fit `maxWidth`; returns it plus
    // the width it actually uses.
    //
    // ★ 截断必须自己做，绝不能交给 `truncationMode`（「位置不够就只剩图标、没有文字」的真正
    // 根因，改这几行前必读）: when `string` is an NSAttributedString, a CATextLayer on a
    // frame exactly ONE line tall renders NOTHING once the text needs tail truncation —
    // not the truncated head, not the ellipsis, just an empty box. Measured by rendering
    // offscreen and counting non-transparent pixels:
    //   • attributed + `.end`, one line tall → 0 px, for 中文 / 英文 / 长单词, at every
    //     budget 200pt→20pt, under BOTH isWrapped values and every paragraph
    //     lineBreakMode (byTruncatingTail / byCharWrapping / byClipping)
    //   • the SAME text as a plain String (+ font/fontSize/foregroundColor properties)
    //     → draws correctly at every one of those widths
    //   • attributed + `.end` on a 2- or 3-line frame → draws correctly
    // So it is the attributed-string path specifically, not truncation as such — which is
    // also why an earlier fix that flipped `isWrapped` to true changed nothing and the bug
    // outlived it. It is why a wide pane looked fine while a slim one showed the badge
    // beside an empty pill, and why hovering "fixed" it (the expansion is 2-3 lines tall,
    // so captionBlock below keeps `.end` and must NOT be unified with this path).
    // CrispTextLayer is on the plain-String side of that line and needs no such handling.
    private func captionText(_ attr: NSAttributedString, maxWidth: CGFloat,
                             scale: CGFloat) -> (CATextLayer, CGFloat) {
        // Clamped at 0: a negative budget (fixed chrome wider than the pane) would give
        // the layer a negative frame and silently draw nothing. Callers keep the budget
        // above capMinText; this is the belt-and-suspenders.
        let budget = max(0, maxWidth)
        let fitted = Self.truncateToFit(attr, width: budget)
        let w = min(ceil(fitted.size().width), budget)
        let t = CATextLayer()
        t.string = fitted
        // Already one line and already short enough — nothing left to wrap or truncate.
        t.truncationMode = .none
        t.isWrapped = false
        t.contentsScale = scale
        return (t, w)
    }

    // The wrapped variant used by the hover expansion: `attr` laid out at exactly
    // `width` over at most `lines` lines (last one still tail-truncating), returning
    // the layer and the height it needs. `.end` is kept here on purpose — the one-line
    // blind spot that forced captionText to truncate by hand does not apply to a frame
    // two or more lines tall (measured: it draws).
    private func captionBlock(_ attr: NSAttributedString, width: CGFloat, lines: Int,
                              fontSize: CGFloat, scale: CGFloat) -> (CATextLayer, CGFloat) {
        let t = CATextLayer()
        t.string = attr
        t.truncationMode = .end
        t.isWrapped = true
        t.contentsScale = scale
        let box = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin])
        let line = Self.lineHeight(fontSize)
        return (t, min(ceil(box.height), line * CGFloat(max(1, lines))))
    }

    // One line of `fontSize` system text, rounded up — the unit both the vertical
    // centering and the expansion's height budget count in.
    private static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: fontSize)
        return ceil(f.ascender - f.descender)
    }

    // Center a finished pill horizontally in the band. Its TOP edge is the anchor —
    // resting height puts the bottom 1pt above the ring's top stroke, and a hover
    // expansion then grows downward over the terminal, because upward there is only the
    // 24pt margin the overlay window ends at.
    private func placePill(_ pill: CALayer, width: CGFloat, height: CGFloat, inset: CGRect) {
        let top = inset.maxY + 1 + Self.capBand
        pill.frame = CGRect(x: (bounds.width - width) / 2, y: top - height,
                            width: width, height: height).integral
        layer?.addSublayer(pill)
        captionRoot = pill
        captionHitRect = pill.frame
    }

    // Text budget for a pill style: what's left of `maxW` after the style's own fixed
    // chrome, and whether the badge still earns its place in it. Same priority as the
    // titlebar — chrome, then badge, then the title truncates last.
    private func pillTextBudget(maxW: CGFloat, chrome: CGFloat,
                                badgeSide: CGFloat) -> (slot: CGFloat, show: Bool, text: CGFloat) {
        let free = maxW - chrome
        let show = free >= badgeSide + Self.capBadgeGap + Self.capMinText
        let slot = badgeSlot(badgeSide, show: show)
        return (slot, show, max(0, free - slot))
    }

    // Whether a hover has anything to reveal here, and how many lines it may spend.
    // `room` is the height the style can grow into (half the pane — a label that eats
    // more of the terminal than it explains is a bad trade). Refusing to expand at one
    // line is deliberate: re-laying the same truncated line is a twitch, not a reveal.
    private func expansionPlan(natural: CGFloat, textMax: CGFloat,
                               fontSize: CGFloat, room: CGFloat) -> (can: Bool, lines: Int) {
        let lines = min(Self.capMaxLines, Int(room / Self.lineHeight(fontSize)))
        return (natural > textMax && textMax > 0 && lines >= 2, lines)
    }

    // The caption's text body laid per the hover state: one truncated line collapsed, a
    // wrapped block expanded. Returns the layer with the width and height it occupies.
    private func captionBody(_ attr: NSAttributedString, textMax: CGFloat, fontSize: CGFloat,
                             expand: Bool, lines: Int,
                             scale: CGFloat) -> (CATextLayer, CGFloat, CGFloat) {
        guard expand else {
            let (t, w) = captionText(attr, maxWidth: textMax, scale: scale)
            return (t, w, Self.lineHeight(fontSize))
        }
        let (t, h) = captionBlock(attr, width: textMax, lines: lines, fontSize: fontSize, scale: scale)
        return (t, textMax, h)
    }

    // Seat a caption's text inside a `boxH`-tall pill/bar: centered on the single line
    // when collapsed, hanging from the top padding when expanded (so line one stays
    // exactly where the collapsed title was and the block grows downward).
    private func seatCaptionText(_ t: CATextLayer, x: CGFloat, width: CGFloat, textH: CGFloat,
                                 fontSize: CGFloat, band: CGFloat, boxH: CGFloat, expand: Bool) {
        if expand {
            let vpad = ((band - Self.lineHeight(fontSize)) / 2).rounded()
            t.frame = CGRect(x: x.rounded(), y: (boxH - vpad - textH).rounded(),
                             width: width, height: textH)
        } else {
            t.frame = CGRect(x: x, y: 0, width: width, height: band)
            alignVertically(t, fontSize: fontSize, height: band, yOffset: boxH - band)
        }
    }

    // 21 — 通透药丸描边 + 前置红点。
    private func addOutlineDot(project: String, task: String, inset: CGRect,
                               maxW: CGFloat, accent: NSColor, scale: CGFloat) {
        let h = Self.capBand, padL: CGFloat = 11, padR: CGFloat = 12, gap: CGFloat = 7, dotD: CGFloat = 7
        let bs = Self.capPillBadge
        let (slot, showBadge, textMax) = pillTextBudget(maxW: maxW, chrome: padL + padR + dotD + gap,
                                                        badgeSide: bs)
        let attr = captionAttr(project, task, sep: "  ", pj: Self.capPjColor)
        let (can, lines) = expansionPlan(natural: ceil(attr.size().width), textMax: textMax,
                                         fontSize: 12, room: inset.height * 0.5)
        captionCanExpand = can
        let expand = captionExpanded && can
        let (txt, tw, th) = captionBody(attr, textMax: textMax, fontSize: 12,
                                        expand: expand, lines: lines, scale: scale)
        let w = padL + dotD + gap + slot + tw + padR
        let H = expand ? th + (h - Self.lineHeight(12)) : h
        let pill = CALayer()
        pill.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.62).cgColor
        // A grown pill keeps the resting capsule's end caps rather than turning into a
        // stadium as tall as it is wide.
        pill.cornerRadius = min(h, H) / 2
        pill.borderWidth = 1.3
        pill.borderColor = accent.cgColor
        // Neutral drop shadow only — an accent glow here reads as leftover ring
        // highlight around the label after the ring itself has faded.
        pill.shadowColor = NSColor.black.cgColor; pill.shadowOpacity = 0.45; pill.shadowRadius = 6; pill.shadowOffset = CGSize(width: 0, height: -2)
        // The dot and badge stay on the first line however far the pill has grown.
        let dot = CALayer()
        dot.frame = CGRect(x: padL, y: (H - h) + (h - dotD) / 2, width: dotD, height: dotD)
        dot.backgroundColor = accent.cgColor; dot.cornerRadius = dotD / 2
        dot.shadowColor = accent.cgColor; dot.shadowOpacity = 0.9; dot.shadowRadius = 4; dot.shadowOffset = .zero
        pill.addSublayer(dot)
        let tx = addBadge(to: pill, x: padL + dotD + gap, side: bs, height: h, scale: scale,
                          show: showBadge, yOffset: H - h)
        seatCaptionText(txt, x: tx, width: tw, textH: th, fontSize: 12, band: h, boxH: H, expand: expand)
        pill.addSublayer(txt)
        placePill(pill, width: w, height: H, inset: inset)
    }

    // 23 — 深底药丸 + 左侧红竖条。
    private func addAccentRule(project: String, task: String, inset: CGRect,
                               maxW: CGFloat, accent: NSColor, scale: CGFloat) {
        let h = Self.capBand, padL: CGFloat = 9, padR: CGFloat = 12, gap: CGFloat = 9, barW: CGFloat = 3, barH: CGFloat = 13
        let bs = Self.capPillBadge
        let (slot, showBadge, textMax) = pillTextBudget(maxW: maxW, chrome: padL + padR + barW + gap,
                                                        badgeSide: bs)
        let attr = captionAttr(project, task, sep: "  ", pj: Self.capPjColor)
        let (can, lines) = expansionPlan(natural: ceil(attr.size().width), textMax: textMax,
                                         fontSize: 12, room: inset.height * 0.5)
        captionCanExpand = can
        let expand = captionExpanded && can
        let (txt, tw, th) = captionBody(attr, textMax: textMax, fontSize: 12,
                                        expand: expand, lines: lines, scale: scale)
        let w = padL + barW + gap + slot + tw + padR
        let H = expand ? th + (h - Self.lineHeight(12)) : h
        let pill = CALayer()
        pill.backgroundColor = NSColor(calibratedRed: 0.114, green: 0.114, blue: 0.129, alpha: 0.98).cgColor
        pill.cornerRadius = 8
        pill.borderWidth = 1; pill.borderColor = NSColor(calibratedWhite: 0.24, alpha: 1).cgColor
        pill.shadowColor = NSColor.black.cgColor; pill.shadowOpacity = 0.5; pill.shadowRadius = 8; pill.shadowOffset = CGSize(width: 0, height: -2)
        // The rule grows with the text block so it reads as a margin marker for the
        // whole label, not a tick next to the first line only.
        let bar = CALayer()
        let ruleH = expand ? max(barH, th) : barH
        bar.frame = CGRect(x: padL, y: (H - ruleH) / 2, width: barW, height: ruleH)
        bar.backgroundColor = accent.cgColor; bar.cornerRadius = barW / 2
        bar.shadowColor = accent.cgColor; bar.shadowOpacity = 0.8; bar.shadowRadius = 4; bar.shadowOffset = .zero
        pill.addSublayer(bar)
        let tx = addBadge(to: pill, x: padL + barW + gap, side: bs, height: h, scale: scale,
                          show: showBadge, yOffset: H - h)
        seatCaptionText(txt, x: tx, width: tw, textH: th, fontSize: 12, band: h, boxH: H, expand: expand)
        pill.addSublayer(txt)
        placePill(pill, width: w, height: H, inset: inset)
    }

    // 2 — accent 段项目 + 玻璃段任务（无任务时只画 accent 段）。
    //
    // ★ 窄 pane 转两行（T181，改这块前必读）: two side-by-side segments need BOTH columns
    // to seat readable text, and below ~114pt of usable width no split of it can. The old
    // layout handed the task whatever was left and, under 16pt, dropped the segment
    // outright — so a slim pane showed the project and nothing else. Worse,
    // `captionCanExpand` was assigned only INSIDE that branch, so the dropped case left it
    // false and `setCaptionExpanded` refused the hover: the one path that could still have
    // revealed the title was shut off by the same bug. Under the threshold the label now
    // becomes ONE card — accent project segment on top, task on a full-width row beneath —
    // which every pane clearing addCaption's entry guard can seat (maxW > 58 ⇒ the row's
    // budget maxW − padA*2 > 36 > capMinText). ★ The switch keys off pane geometry ONLY,
    // never `captionExpanded`: if a hover could change the row count, the hit rect would
    // shrink out from under the cursor and the label would twitch open/closed. Wide panes
    // (maxW ≥ 114) lay out exactly as before, pixel for pixel.
    private func addSegmented(project: String, task: String, inset: CGRect,
                              maxW: CGFloat, accent: NSColor, scale: CGFloat) {
        let h = Self.capBand, padA: CGFloat = 11, padB: CGFloat = 12, rowPadV: CGFloat = 4
        let line = Self.lineHeight(12)
        let row2 = line + rowPadV * 2   // 23 — resting height of the stacked task row
        let bs = Self.capPillBadge
        let pjAttr = NSAttributedString(string: project, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white])
        let tkAttr = NSAttributedString(string: task, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1)])
        let tkNatural = ceil(tkAttr.size().width)
        // The project segment gets half the band; its own padding comes out of that
        // half first (it used not to, so a long project name pushed the segment past
        // the budget and squeezed the task segment to nothing).
        let inlineBudget = pillTextBudget(maxW: maxW * 0.5, chrome: padA * 2, badgeSide: bs)
        // What side-by-side would leave the task, priced without building a layer (same
        // width formula captionText uses) — it is an input to the layout decision below.
        let pwInline = min(ceil(pjAttr.size().width), max(0, inlineBudget.text))
        let tkMaxInline = maxW - (pwInline + inlineBudget.slot + padA * 2) - padB * 2
        let stackBelow = Self.capMinText * 2 + padA * 2 + padB * 2   // 114
        let stacked = !task.isEmpty && maxW < stackBelow
            && tkNatural > tkMaxInline           // a task that already fits needs no second row
            && inset.height >= (h + row2) * 2    // the resting card must stay under half the pane
        // Stacking hands the project the FULL width instead of half, which is why the
        // badge often survives on a narrow pane here where side-by-side had to drop it.
        let (slot, showBadge, pjMax) = stacked
            ? pillTextBudget(maxW: maxW, chrome: padA * 2, badgeSide: bs)
            : inlineBudget
        let (pjT, pw) = captionText(pjAttr, maxWidth: pjMax, scale: scale)
        let segAW = pw + slot + padA * 2
        let pill = CALayer()
        pill.cornerRadius = 8
        // Neutral drop shadow only (no accent glow — see addOutlineDot).
        pill.shadowColor = NSColor.black.cgColor; pill.shadowOpacity = 0.5; pill.shadowRadius = 6; pill.shadowOffset = CGSize(width: 0, height: -2)
        let segA = CALayer()
        segA.backgroundColor = accent.cgColor
        segA.cornerRadius = 8
        segA.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]   // left corners
        var totalW = segAW
        // Height of the accent segment itself: the whole block side-by-side (it grows
        // with the expansion), just the first row when stacked. `H - segAH` is therefore
        // the one offset that keeps the badge and project name on line one in both.
        var H = h, segAH = h
        if task.isEmpty {
            captionCanExpand = false   // nothing to reveal; the project name never expands
            segA.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                  .layerMaxXMinYCorner, .layerMaxXMaxYCorner]   // all — solo pill
        } else {
            // ★ The old `tkMax >= 16 else drop the whole segment` guard is gone, and is
            // now provably dead anyway: stacked gives maxW − 22 > 36, and side-by-side is
            // only reached at maxW ≥ 114 with segAW ≤ maxW/2, i.e. tkMax ≥ maxW/2 − 24 ≥ 33.
            let tkMax = stacked ? maxW - padA * 2 : maxW - segAW - padB * 2
            let room = stacked ? inset.height * 0.5 - h - rowPadV * 2 : inset.height * 0.5
            let (can, lines) = expansionPlan(natural: tkNatural, textMax: tkMax,
                                             fontSize: 12, room: room)
            captionCanExpand = can   // ★ 无条件赋值 —— 藏在 tkMax 分支里正是 hover 也没出口的成因
            let expand = captionExpanded && can
            let (tkT, tw, th) = captionBody(tkAttr, textMax: tkMax, fontSize: 12,
                                            expand: expand, lines: lines, scale: scale)
            if stacked {
                let rowBH = expand ? th + rowPadV * 2 : row2
                H = h + rowBH
                totalW = max(segAW, tw + padA * 2)
                // The card itself backs the task row — no second segment and no seam: the
                // accent block's lower edge already reads as the divider.
                pill.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
                // Seated in the ROW's box, not the whole card, so line one lands exactly
                // where the collapsed line was and the expansion only grows below it.
                seatCaptionText(tkT, x: padA, width: tw, textH: th, fontSize: 12,
                                band: row2, boxH: rowBH, expand: expand)
                pill.addSublayer(tkT)
                // A project name that fills the row rounds the card's top-right corner
                // too; a short one leaves that corner to the card's own gray.
                if segAW >= totalW - 0.5 {
                    segA.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // top corners
                } else {
                    segA.maskedCorners = [.layerMinXMaxYCorner]   // top-left only
                }
            } else {
                H = expand ? th + (h - line) : h
                segAH = H
                let segBW = tw + padB * 2
                let segB = CALayer()
                segB.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
                segB.cornerRadius = 8
                segB.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]   // right corners
                segB.frame = CGRect(x: segAW, y: 0, width: segBW, height: H)
                seatCaptionText(tkT, x: padB, width: tw, textH: th, fontSize: 12,
                                band: h, boxH: H, expand: expand)
                segB.addSublayer(tkT)
                pill.addSublayer(segB)
                totalW = segAW + segBW
            }
        }
        let pjX = addBadge(to: segA, x: padA, side: bs, height: h, scale: scale,
                           show: showBadge, yOffset: segAH - h)
        pjT.frame = CGRect(x: pjX, y: 0, width: pw, height: h)
        alignVertically(pjT, fontSize: 12, height: h, yOffset: segAH - h)
        segA.addSublayer(pjT)
        segA.frame = CGRect(x: 0, y: H - segAH, width: segAW, height: segAH)
        pill.insertSublayer(segA, at: 0)
        placePill(pill, width: totalW, height: H, inset: inset)
    }

    // 28 — 框内顶部标题栏 + 底部红细线，居中标题（项目 accent + 任务灰）。
    // In-ring titlebar: the bar sits INSIDE the highlight, its top edge on the
    // pane's top edge, so its rounded top corners land exactly on the ring's own
    // (same 10pt radius). It keeps a 1.6pt accent border — the top/side edges ride
    // under the breathing stroke, the bottom edge is the seam against the terminal
    // content and still frames the bar once the ring fades. The ✕ glyph on the
    // right only MARKS the close spot — the click lands on TerminalFocusRing's tiny
    // catcher panel floated over it (this overlay window is click-through).
    //
    // ★ 宽度自适应（改这块前必读）: the bar spans the pane, so a narrow terminal is the
    // hard case. Budget order is fixed — ✕ slot, then the badge, then the title, which
    // truncates with an ellipsis and is NEVER dropped. The first version reserved the
    // ✕ slot on BOTH sides (to keep the title optically centered) AND the badge, then
    // fed whatever was left to the text layer without a floor: on a slim pane that
    // remainder went to ~0 and the label vanished, which read as "标签位置不够就直接不
    // 显示了". Centering is now conditional — it only applies while the whole block
    // fits clear of both slots, otherwise the title left-aligns and spends every
    // available point on characters.
    private func addTitlebar(project: String, task: String, inset: CGRect,
                             accent: NSColor, scale: CGFloat) {
        let headH = Self.titlebarHeight, fs: CGFloat = 14
        let slot = Self.closeSize + Self.closeInset * 2
        let padL = Self.closeInset * 2
        let s = NSMutableAttributedString(string: project, attributes: [
            .font: NSFont.systemFont(ofSize: fs, weight: .bold), .foregroundColor: NSColor.white])
        if !task.isEmpty {
            s.append(NSAttributedString(string: " · " + task, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)]))
        }
        // Room for "badge + title": the full width less the left padding and the ✕ slot.
        let avail = inset.width - padL - slot
        let bs = Self.capBarBadge
        // The badge goes first when space runs out — an icon with no room left for the
        // name it labels is worse than no icon.
        let showBadge = avail >= bs + Self.capBadgeGap + Self.capMinText
        let badge = badgeSlot(bs, show: showBadge)
        let textMax = avail - badge
        let natural = ceil(s.size().width)
        let truncated = natural > textMax

        // Expanded (hover): the full title wraps and the bar grows downward into the
        // pane, on the same plan every caption style uses.
        let line = Self.lineHeight(fs)
        let vpad = ((headH - line) / 2).rounded()
        let (can, lines) = expansionPlan(natural: natural, textMax: textMax,
                                         fontSize: fs, room: inset.height * 0.5 - 2 * vpad)
        captionCanExpand = can
        let expand = captionExpanded && can
        let (txt, tw, textH) = captionBody(s, textMax: textMax, fontSize: fs,
                                           expand: expand, lines: lines, scale: scale)
        let barH = expand ? max(headH, textH + 2 * vpad) : headH

        let bar = CALayer()
        bar.frame = CGRect(x: inset.minX, y: inset.maxY - barH, width: inset.width, height: barH)
        bar.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.97).cgColor
        bar.cornerRadius = 10   // same radius as ringPath so the stroke hugs the bar's corners
        bar.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // round the top edge only
        bar.borderWidth = 1.6
        bar.borderColor = accent.cgColor
        // Badge + title travel as one block, centered while that keeps it clear of the
        // ✕ slot on both sides, left-aligned once it can't. `head` is the first line's
        // bottom edge, so the badge and ✕ stay on it however far the bar has grown.
        let blockW = tw + badge
        let head = barH - headH
        let x = (!truncated && blockW <= inset.width - 2 * slot)
            ? ((inset.width - blockW) / 2).rounded() : padL
        let tx = addBadge(to: bar, x: x, side: bs, height: headH, scale: scale,
                          show: showBadge, yOffset: head)
        seatCaptionText(txt, x: tx, width: tw, textH: textH, fontSize: fs,
                        band: headH, boxH: barH, expand: expand)
        bar.addSublayer(txt)
        let (xg, xw) = captionText(NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Self.capTkColor]), maxWidth: slot, scale: scale)
        xg.frame = CGRect(x: inset.width - Self.closeInset - (Self.closeSize + xw) / 2,
                          y: 0, width: xw, height: headH)
        alignVertically(xg, fontSize: 13, height: headH, yOffset: head)
        bar.addSublayer(xg)
        layer?.addSublayer(bar)
        captionRoot = bar
        captionHitRect = bar.frame
    }

    // CATextLayer draws from the top of its frame; nudge it so a single line of
    // `fontSize` sits vertically centered in a `height`-tall box whose bottom edge is
    // at `yOffset` (non-zero only inside a hover-expanded titlebar).
    private func alignVertically(_ t: CATextLayer, fontSize: CGFloat, height: CGFloat,
                                 yOffset: CGFloat = 0) {
        let lineH = Self.lineHeight(fontSize)
        var f = t.frame
        f.origin.x = f.origin.x.rounded()
        f.origin.y = (yOffset + (height - lineH) / 2).rounded()   // pixel-align to keep text sharp
        f.size.height = lineH
        t.frame = f
    }

    // The resting stroke for persistent mode: fades in and holds at steadyHold
    // (model opacity, so it survives with no removal). Added beneath the flourish.
    private func addSteadyBase(margin: CGFloat, accent: NSColor, style: AppSettings.RingStyle) {
        let inset = paneRect(margin)
        let shape: CAShapeLayer
        switch style {
        case .corners:
            shape = makeStroke(cornerBracketsPath(inset: inset, arm: 18), accent, width: 3, glow: 0.55)
            shape.lineCap = .round
            shape.lineJoin = .round
        case .ants:
            let rect = ringPath(inset, r: 10)
            shape = makeStroke(rect, accent, width: 2.5, glow: 0.5)
            shape.lineDashPattern = [12, 7]
        default:
            let rect = ringPath(inset, r: 10)
            shape = makeStroke(rect, accent, width: 2.5, glow: 0.6)
        }
        shape.shadowRadius = 8
        shape.opacity = Self.steadyHold
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0.0
        fadeIn.toValue = Self.steadyHold
        fadeIn.duration = 0.4
        shape.add(fadeIn, forKey: "steadyIn")
        layer?.addSublayer(shape)
    }

    // Viewfinder corner brackets (shared by the flourish and the steady base).
    private func cornerBracketsPath(inset: CGRect, arm: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for (sx, sy) in [(CGFloat(1), CGFloat(1)), (-1, 1), (-1, -1), (1, -1)] {
            let cx = sx > 0 ? inset.minX : inset.maxX
            let cy = sy > 0 ? inset.minY : inset.maxY
            p.move(to: CGPoint(x: cx + sx * arm, y: cy))
            p.addLine(to: CGPoint(x: cx, y: cy))
            p.addLine(to: CGPoint(x: cx, y: cy + sy * arm))
        }
        return p
    }

    private func makeStroke(_ path: CGPath, _ accent: NSColor, width: CGFloat,
                            glow: Float) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = accent.cgColor
        shape.lineWidth = width
        shape.shadowColor = accent.cgColor
        shape.shadowOpacity = glow
        shape.shadowRadius = 10
        shape.shadowOffset = .zero
        return shape
    }

    // Shared fade envelope: quick in, long hold, out — the final 0 held until
    // teardown so nothing flashes back to full opacity.
    private func addFade(_ shape: CAShapeLayer, peak: Float, duration: TimeInterval) {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, peak, peak, 0.0]
        fade.keyTimes = [0, 0.05, 0.85, 1]
        fade.duration = duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        shape.add(fade, forKey: "fade")
    }

    private func buildBreath(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let path = ringPath(inset, r: 10)
        let shape = makeStroke(path, accent, width: 3.5, glow: 0.9)
        layer?.addSublayer(shape)

        let snap = CABasicAnimation(keyPath: "path")
        snap.fromValue = ringPath(paneRect(margin * 0.3), r: 14)
        snap.duration = 0.22
        snap.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(snap, forKey: "snap")

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1.0, 0.45, 1.0, 0.45, 1.0, 0.0]   // three peaks, then out
        pulse.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        pulse.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
        pulse.duration = 5 * 0.7
        pulse.beginTime = CACurrentMediaTime() + 0.25
        pulse.fillMode = .forwards            // hold the final 0 until teardown —
        pulse.isRemovedOnCompletion = false   // no flash back to full opacity
        shape.add(pulse, forKey: "pulse")
    }

    private func buildRipple(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let basePath = ringPath(inset, r: 10)

        // Steady anchor stroke on the pane edge; born fast, gone at the end.
        let base = makeStroke(basePath, accent, width: 3, glow: 0.8)
        layer?.addSublayer(base)
        addFade(base, peak: 1.0, duration: 3.5)

        // Sonar waves: born on the pane edge, swelling out to the window margin
        // while thinning and fading to nothing. One wave every 0.7s.
        let grown = ringPath(inset.insetBy(dx: -(margin - 4), dy: -(margin - 4)), r: 16)
        for i in 0..<4 {
            let wave = makeStroke(basePath, accent, width: 2.5, glow: 0)
            wave.opacity = 0   // model value: invisible before and after its group
            layer?.addSublayer(wave)

            let swell = CABasicAnimation(keyPath: "path")
            swell.fromValue = basePath
            swell.toValue = grown
            let thin = CABasicAnimation(keyPath: "lineWidth")
            thin.fromValue = 2.5
            thin.toValue = 0.5
            let vanish = CAKeyframeAnimation(keyPath: "opacity")
            vanish.values = [0.85, 0.85, 0.0]
            vanish.keyTimes = [0, 0.15, 1]

            let group = CAAnimationGroup()
            group.animations = [swell, thin, vanish]
            group.duration = 1.1
            group.beginTime = CACurrentMediaTime() + 0.1 + Double(i) * 0.7
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wave.add(group, forKey: "wave")
        }
    }

    private func buildSweep(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let path = ringPath(inset, r: 10)
        // Rounded-rect perimeter: straight runs + the four quarter-circles, measured
        // on the outline the comet actually orbits (bar + pane when titled).
        let box = inset
        let perimeter = 2 * (box.width + box.height) - 10 * (8 - 2 * CGFloat.pi)

        // The comet: one bright arc (22% of the border) chasing its own tail.
        let comet = makeStroke(path, accent, width: 4, glow: 1.0)
        comet.lineCap = .round
        comet.lineDashPattern = [NSNumber(value: Double(perimeter) * 0.22),
                                 NSNumber(value: Double(perimeter) * 0.78)]
        layer?.addSublayer(comet)
        addFade(comet, peak: 1.0, duration: 3.6)

        let orbit = CABasicAnimation(keyPath: "lineDashPhase")
        orbit.byValue = -perimeter   // one full lap per repeat
        orbit.duration = 1.2
        orbit.repeatCount = 3
        comet.add(orbit, forKey: "orbit")
    }

    private func buildCorners(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let shape = makeStroke(cornerBracketsPath(inset: inset, arm: 18), accent, width: 4, glow: 0.9)
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)

        // Fly in from outside (scale about center pulls all four inward), ...
        let snap = CABasicAnimation(keyPath: "transform.scale")
        snap.fromValue = 1.25
        snap.toValue = 1.0
        snap.duration = 0.3
        snap.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(snap, forKey: "snap")

        // ... then blink twice like a camera confirming focus lock, and fade.
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0.0, 1.0, 1.0, 0.3, 1.0, 0.3, 1.0, 0.0]
        blink.keyTimes = [0, 0.08, 0.3, 0.42, 0.54, 0.66, 0.8, 1]
        blink.duration = 3.2
        blink.fillMode = .forwards
        blink.isRemovedOnCompletion = false
        shape.add(blink, forKey: "blink")
    }

    private func buildConverge(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let basePath = ringPath(inset, r: 10)
        let grown = ringPath(inset.insetBy(dx: -(margin - 4), dy: -(margin - 4)), r: 16)

        // The anchor builds up glow as each wave lands on it, then fades last.
        let base = makeStroke(basePath, accent, width: 3, glow: 0.8)
        layer?.addSublayer(base)
        let rise = CAKeyframeAnimation(keyPath: "opacity")
        rise.values = [0.0, 0.35, 0.7, 1.0, 1.0, 0.0]
        rise.keyTimes = [0, 0.2, 0.4, 0.6, 0.85, 1]
        rise.duration = 3.4
        rise.fillMode = .forwards
        rise.isRemovedOnCompletion = false
        base.add(rise, forKey: "rise")

        // Reverse sonar: born wide and faint at the window margin, collapsing
        // onto the pane edge while thickening, vanishing at contact.
        for i in 0..<3 {
            let wave = makeStroke(grown, accent, width: 1.5, glow: 0)
            wave.opacity = 0   // model value: invisible before and after its group
            layer?.addSublayer(wave)

            let collapse = CABasicAnimation(keyPath: "path")
            collapse.fromValue = grown
            collapse.toValue = basePath
            let thicken = CABasicAnimation(keyPath: "lineWidth")
            thicken.fromValue = 1.5
            thicken.toValue = 3.0
            let land = CAKeyframeAnimation(keyPath: "opacity")
            land.values = [0.0, 0.85, 0.0]
            land.keyTimes = [0, 0.8, 1]

            let group = CAAnimationGroup()
            group.animations = [collapse, thicken, land]
            group.duration = 0.9
            group.beginTime = CACurrentMediaTime() + 0.1 + Double(i) * 0.6
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            wave.add(group, forKey: "wave")
        }
    }

    private func buildNeon(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let path = ringPath(inset, r: 10)
        let shape = makeStroke(path, accent, width: 3.5, glow: 1.0)
        shape.shadowRadius = 12
        layer?.addSublayer(shape)

        // Uneven sputter while "powering on", steady glow, then the tube dims.
        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        flicker.values =   [0.0, 1.0, 0.15, 0.9, 0.1, 1.0, 0.45, 1.0, 1.0, 0.0]
        flicker.keyTimes = [0, 0.03, 0.06, 0.10, 0.14, 0.19, 0.24, 0.30, 0.85, 1]
        flicker.duration = 3.4
        flicker.fillMode = .forwards
        flicker.isRemovedOnCompletion = false
        shape.add(flicker, forKey: "flicker")
    }

    private func buildAnts(margin: CGFloat, accent: NSColor) {
        let inset = paneRect(margin)
        let path = ringPath(inset, r: 10)
        let shape = makeStroke(path, accent, width: 3, glow: 0.6)
        shape.lineDashPattern = [12, 7]
        layer?.addSublayer(shape)
        addFade(shape, peak: 0.95, duration: 3.2)

        // Crawl: ~10 dash cycles over the whole life, linear so it never stalls.
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.byValue = -19.0 * 10
        march.duration = 3.2
        shape.add(march, forKey: "march")
    }
}

// The clickable ✕ of the external titlebar caption. At rest it draws nothing —
// the gray glyph in the RingView beneath shows through — and on hover it paints
// the highlight circle with a white ✕ over it (covering the gray one), so the
// spot lights up exactly like a native window control.
private final class RingCloseButtonView: NSView {
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    // The panel is never key (nonactivating) — take the very first click instead
    // of letting AppKit swallow it as a window-raising click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        // Opaque bar-tinted circle so it fully hides the resting glyph beneath.
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let s = NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white])
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                           y: (bounds.height - sz.height) / 2))
    }
}
