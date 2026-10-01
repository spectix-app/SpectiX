import Cocoa

// MARK: - Motion clock
//
// One phase origin shared by every perpetual loop in the lists (status dots, the
// agent axis nodes, the 🤖 badge halo). NSTableView.reloadData() runs on every
// refresh tick whose rendered figures changed — and the ⏱ column changes by the
// second for a young session — which detaches the row views and strips their layer
// animations. Re-adding a loop anchored to "now" restarts it from frame 0, so the
// indicator visibly blinks in lockstep with the time refresh. Anchoring beginTime
// here instead means a rebuilt loop rejoins mid-phase (and all instances of a loop
// run in unison), making the rebuild invisible.
enum Motion {
    static let epoch: CFTimeInterval = CACurrentMediaTime()
}

// MARK: - Letting a card's shadow leave its cell (改这块前必读)
//
// A list card's shadow is bigger than the padding its cell gives it — a group
// header sits 8pt below its cell's top edge and 6pt inside its sides — and a
// CLIPPED soft shadow does not fade out, it STOPS, in a straight line. That was the
// "shadow squares beside the list" bug: every card wore a rectangle of shadow with
// square corners cut exactly where its cell ended. It showed in the clay theme at
// rest (its surfaces are bounded by light) and in the default theme's hover lift
// (blur 22 against 6pt of room) alike.
//
// Safe to unclip because these cells host nothing that overflows on purpose: every
// label is constrained inside the card, and the card's fill is clipped by its own
// rounded layer. Overlap with the NEIGHBOURING card is handled by paint order —
// later rows paint over earlier ones, so a downward shadow disappears behind the
// card below (see GroupCard.castsDrop for which slice casts what).
extension NSView {
    func letShadowsEscape() {
        wantsLayer = true
        layer?.masksToBounds = false
        if #available(macOS 14.0, *) { clipsToBounds = false }
    }
}

// MARK: - StatusDot
//
// A filled dot that casts a soft colored glow (a same-color layer shadow), plus a
// per-status motion identity. The animation language: every moving state answers
// "who is acting right now" —
//   working   Claude is typing  → the dot splits into a chat "…" wave
//   needs     it knocks for you → heartbeat double-thump + radiating sonar ring
//   checking  you are looking   → the watching eye
//   done      it landed         → one-shot pop + ✓ stroke-in, then calm
//   idle/seen asleep            → still
// Terminal states never loop — so when scanning the list, whatever still moves is
// exactly what needs attention. Reused in rows, chips, and toasts.

final class StatusDot: NSView {
    private let core = CALayer()
    private var diameter: CGFloat
    // Compact dots (the 7pt capsule-badge dots) must keep every effect inside
    // their own footprint: the typing split and the sonar ring reach ~2× the dot
    // width and would collide with the count label beside them. Compact working
    // keeps the legacy breathing pulse; compact needs beats without the ring;
    // compact done skips the ✓ (unreadable at 7pt).
    private let compact: Bool

    // Decor (eye / typing / ring / check) is bounds-dependent, and apply() can run
    // before layout gives real bounds (a fresh recycled cell configures at zero
    // size) — so building defers to layout(), tracked by what was last built.
    private var status = ""
    private var builtStatus: String?
    private var builtSize: CGSize = .zero

    // The accent the current decor was painted in. A dot outside the list is built
    // ONCE (the settings cards, the priority chips) and apply() short-circuits on an
    // unchanged status — so recoloring a status in Settings left those dots wearing
    // the old color until the window was rebuilt, visibly disagreeing with the very
    // 状态颜色 card that had just set it. Compared as hex, not by NSColor identity:
    // a default accent is a dynamic color whose instance differs every read.
    private var builtAccent: String?
    private var paletteObserver: NSObjectProtocol?

    // One-shot transition bookkeeping, global per session key. Entrance effects
    // (the done landing pop, the typing split-in) must play once per session
    // *transition*, not once per view build: reloadData() recycles cells on every
    // refresh and reshuffles which view instance shows which session, so per-view
    // or time-window bookkeeping replays the one-shots on churn — done dots
    // pop repeatedly, working dots flash their split-in. The first apply() that
    // sees the new status for a key consumes the entrance; every later build for
    // that key (recycled cells, the other window, a reopened popover) renders the
    // calm steady state.
    private static var lastStatus: [String: String] = [:]
    private var pendingPop = false     // play the done landing on next build
    private var pendingIntro = false   // play the entrance morph (typing split-in /
                                       // eye) on next build

    // Debounce the one-shot entrance effects (done landing pop, working split-in
    // grow, checking eye morph). A genuine turn boundary is seconds-to-minutes apart; a sub-window
    // re-entry into a state is spurious status flicker (a done row's background-
    // command probe toggling on/off across polls, a needs↔working blip), and
    // replaying the grow/pop on every flip is exactly the "蓝色 indicator 一直在刷新
    // animation" bug — the dot visibly re-animates its entrance every couple seconds.
    // Trailing debounce, keyed per session: every eligible transition stamps the
    // clock, and the entrance plays only when the previous one for this key is older
    // than the window — so sustained oscillation shows the calm steady loop with no
    // repeated pop, while a real, isolated transition still gets its entrance.
    private static var lastEntranceAt: [String: CFTimeInterval] = [:]
    private static let entranceDebounce: CFTimeInterval = 3.0

    // Shared phase origin for the looping animations (typing wave, heartbeat,
    // sonar, eye scan) — see `Motion`.
    private static var epoch: CFTimeInterval { Motion.epoch }

    // Clay's bead shading: a diagonal body gradient plus the inset top highlight /
    // bottom shade that turn a flat disc into a sphere. Both are STATIC sublayers of
    // `core`, so they ride every existing animation (the done pop's scale, the
    // typing split) without touching a single loop — see docs/design-system.md's
    // 循环动效铁律. Hidden under a hairline theme, and on compact 7pt dots where the
    // shading is pure noise.
    private let sphere = CAGradientLayer()
    private let shade = CAGradientLayer()

    init(diameter: CGFloat = 11, compact: Bool = false) {
        self.diameter = diameter
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        core.cornerCurve = .continuous
        core.shadowOffset = .zero
        core.shadowOpacity = 1
        layer?.addSublayer(core)

        for g in [sphere, shade] {
            g.masksToBounds = true
            g.isHidden = true
            core.addSublayer(g)
        }
        // 150° in the design ≈ light falling from the upper left.
        sphere.startPoint = CGPoint(x: 0.15, y: 1)
        sphere.endPoint   = CGPoint(x: 0.85, y: 0)
        shade.startPoint  = CGPoint(x: 0.5, y: 1)   // y-up: top
        shade.endPoint    = CGPoint(x: 0.5, y: 0)

        // Repaint on a palette edit. didChange also fires for unrelated settings, so
        // the actual accent is the gate — a no-op for every dot whose color didn't
        // move, and epoch-anchored loops rejoin their phase, so a live wave/heartbeat
        // recolors without visibly restarting.
        paletteObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.recolorIfNeeded() }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let paletteObserver { NotificationCenter.default.removeObserver(paletteObserver) }
    }

    private func recolorIfNeeded() {
        guard builtStatus != nil, builtAccent != Status.accent(status).hexString else { return }
        rebuild()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        core.frame = bounds
        core.cornerRadius = bounds.width / 2
        if bounds.width > 0, builtStatus != status || builtSize != bounds.size {
            buildDecor()
        }
    }

    /// `key` is the session identity (SessionRow.id); it drives the once-per-
    /// transition entrance effects. Keyless dots (badges, chips) never play them.
    func apply(_ status: String, key: String? = nil) {
        if let key, Self.lastStatus[key] != status {
            let prev = Self.lastStatus[key]
            Self.lastStatus[key] = status
            // prev == nil is first sight (app launch, existing sessions) — render
            // the steady state, don't celebrate completions that already happened.
            if prev != nil, status == "done" || status == "working" || status == "checking" {
                let now = CACurrentMediaTime()
                let recent = now - (Self.lastEntranceAt[key] ?? -.greatestFiniteMagnitude)
                    < Self.entranceDebounce
                Self.lastEntranceAt[key] = now   // stamp every attempt (trailing debounce)
                if !recent {
                    if status == "done" { pendingPop = true } else { pendingIntro = true }
                }
            }
        }
        // Same status re-applied on a refresh tick (or a recycled cell picking up
        // a different session in the same status): normally leave the running loop
        // alone — rebuilding would visibly restart it. Exception: if the status
        // wants perpetual motion but the layer has none, the loop was dropped (see
        // motionAlive) and must be restored, or the dot freezes mid-wave.
        let motionStale = perpetual(status) && builtStatus == status && !motionAlive()
        guard status != self.status || pendingPop || pendingIntro || motionStale else { return }
        self.status = status
        rebuild()
    }

    // working / needs / checking run an infinite loop; idle / seen / done are still.
    private func perpetual(_ s: String) -> Bool {
        s == "working" || s == "needs" || s == "checking"
    }

    // Is the expected loop actually attached? AppKit strips a layer's animations
    // whenever the view leaves its window, and NSTableView.reloadData detaches and
    // reattaches recycled row views on every 2.5s refresh — so a still-working row
    // silently loses its typing wave and, blocked by apply()'s same-status guard,
    // never gets it back (the "blue dots freeze while fully visible" bug). The
    // loops live either on `core` (compact breath, needs heartbeat) or on the
    // named decor sublayers and their minis (typing minis, eye pupil, sonar ring).
    private func motionAlive() -> Bool {
        if core.animationKeys()?.isEmpty == false { return true }
        for sub in layer?.sublayers ?? [] where ["typing", "eye", "ring"].contains(sub.name ?? "") {
            if sub.animationKeys()?.isEmpty == false { return true }
            for mini in sub.sublayers ?? [] where mini.animationKeys()?.isEmpty == false { return true }
        }
        return false
    }

    // Re-entering a window after a table recycle is exactly when the loop was
    // dropped; re-assert it here so recovery is same-frame rather than waiting for
    // the next refresh tick. Epoch-anchored loops rebuild seamlessly (they rejoin
    // the same phase), so this is invisible when the animation was in fact alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, builtStatus == status, perpetual(status), !motionAlive() {
            buildDecor()
        }
    }

    private func rebuild() {
        if bounds.width > 0 { buildDecor() }
        else { builtStatus = nil; needsLayout = true }  // layout() builds
    }

    /// Clay turns the dot into a bead: a body gradient lit from the upper left, a
    /// bright lip along the top edge, a soft shade along the bottom, and a wider but
    /// much fainter halo than glass's hard glow — which idle drops altogether
    /// (`.dot.idle::after { opacity: 0 }`).
    private func styleSphere(accent: NSColor, quiet: Bool) {
        let bead = !compact && Theme.shadow(in: self) != nil
        sphere.isHidden = !bead
        shade.isHidden = !bead
        guard bead else { return }

        core.shadowRadius = 5
        core.shadowOpacity = quiet ? 0 : 0.30

        let r = core.bounds.width / 2
        for g in [sphere, shade] { g.frame = core.bounds; g.cornerRadius = r }
        // Design: linear-gradient(150deg, color-mix(currentColor 72%, white), currentColor).
        sphere.colors = [accent.themeBlended(0.72, into: .white).cg(in: self),
                         accent.cg(in: self)]
        // …plus inset 0 1.5px 1.5px white(.55) over inset 0 -1.5px 2px dark(.28) —
        // ~11% of a 14pt dot at each end, so the stops sit there.
        shade.colors = [NSColor.white.withAlphaComponent(0.55).cgColor,
                        NSColor.clear.cgColor,
                        NSColor.clear.cgColor,
                        NSColor.black.withAlphaComponent(0.28).cgColor]
        shade.locations = [0, 0.16, 0.80, 1]
    }

    // Tear down to the plain core, then dress it for the current status.
    //
    // Implicit actions are disabled for the whole build: `core` is a plain sublayer
    // (not a view-backing layer), so bare property sets crossfade over ~0.25s by
    // default. reloadData() recycles cells across rows on every refresh, and a cell
    // recycled from a needs/done row onto an idle row would smear its old red/green
    // through that fade — the "idle rows blink red/green/blue for a frame" bug. A
    // status change must SNAP; the explicit animations provide the motion.
    private func buildDecor() {
        builtStatus = status
        builtSize = bounds.size
        let pop = pendingPop
        let intro = pendingIntro
        pendingPop = false
        pendingIntro = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer?.sublayers?
            .filter { ["eye", "typing", "ring", "check", "pause", "await"].contains($0.name ?? "") }
            .forEach { $0.removeFromSuperlayer() }
        core.removeAllAnimations()
        core.opacity = 1

        let c = Status.accent(status)
        builtAccent = c.hexString
        let quiet = status == "idle" || status == "seen"
        core.backgroundColor = c.cgColor
        core.shadowColor = c.cgColor
        core.shadowRadius = quiet ? 1.5 : 4
        // A circular outline for a circular layer — identical rendering, but the
        // glow stops being recomputed from layer alpha on a list that reloads once
        // a second.
        core.shadowPath = CGPath(ellipseIn: core.bounds, transform: nil)
        // buildAwait zeroes this on its hollow core; a cell recycled from await onto
        // any filled status must get its glow back (styleSphere only touches beads).
        core.shadowOpacity = 1
        styleSphere(accent: c, quiet: quiet)

        switch status {
        case "checking": buildEye(intro: intro)
        case "working":  compact ? buildBreath() : buildTyping(intro: intro)
        case "needs":    buildHeartbeat(ring: !compact)
        case "paused":   buildPause(bars: !compact)
        case "done":     buildDone(pop: pop, check: !compact)
        case "await":    buildAwait(accent: c, spin: !compact)
        default:         break   // idle / seen: asleep, perfectly still
        }

        CATransaction.commit()
    }

    // Legacy breathing pulse — scale + glow swell. Kept for compact badge dots,
    // where the typing split wouldn't fit.
    private func buildBreath() {
        let g = CAAnimationGroup()
        g.duration = 1.4
        g.repeatCount = .infinity
        g.autoreverses = true
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Epoch-anchored like every other perpetual loop (typing / heartbeat /
        // pause). CountPill.configure() throws away and recreates its compact dots on
        // every reload, so an un-anchored breath restarts from frame 0 each tick —
        // the summary indicator visibly jitters. Anchoring rejoins the shared
        // phase so a rebuilt dot is seamless (and all breath dots pulse in unison).
        g.beginTime = Self.epoch

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5; scale.toValue = 1.0
        let glow = CABasicAnimation(keyPath: "shadowRadius")
        glow.fromValue = 1.5; glow.toValue = 10
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45; fade.toValue = 1.0

        g.animations = [scale, glow, fade]
        core.add(g, forKey: "pulse")
    }

    // "Claude is typing": the core splits into three mini dots that rise and
    // brighten in sequence — the universal chat "…" indicator, meaning the model
    // is generating. Spans past the dot bounds like the eye does; hosts don't clip.
    // `intro` plays the split-out grow — only on a real transition into working,
    // never on a rebuild of an already-working session.
    private func buildTyping(intro: Bool) {
        let b = bounds
        let cp = CGPoint(x: b.midX, y: b.midY)
        let color = Status.accent("working")

        let row = CALayer()
        row.name = "typing"
        row.frame = b
        row.masksToBounds = false
        layer?.addSublayer(row)
        core.opacity = 0

        let d = b.width * 0.58           // mini-dot diameter
        let dx = b.width * 0.74          // center-to-center spacing
        let rise = b.height * 0.28
        for i in -1...1 {
            let mini = CALayer()
            mini.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            mini.position = CGPoint(x: cp.x + CGFloat(i) * dx, y: cp.y)
            mini.cornerRadius = d / 2
            mini.backgroundColor = color.cgColor
            mini.shadowColor = color.cgColor
            mini.shadowOffset = .zero
            mini.shadowOpacity = 1
            mini.shadowRadius = 2
            mini.opacity = 0.45
            row.addSublayer(mini)

            if intro {
                // Intro: the minis grow out of the core's spot — the "split" morph.
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0; grow.toValue = 1
                grow.duration = 0.22
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mini.add(grow, forKey: "in")
            }

            // The wave: rise + brighten one after another, then rest a beat so the
            // loop reads as typing cadence rather than a metronome. Phase-anchored
            // to the shared epoch (a beginTime in the past just means the loop is
            // already mid-cycle) so every build joins the same ongoing wave.
            let up = CAKeyframeAnimation(keyPath: "position.y")
            up.values = [cp.y, cp.y + rise, cp.y, cp.y]
            up.keyTimes = [0, 0.16, 0.32, 1]
            let lit = CAKeyframeAnimation(keyPath: "opacity")
            lit.values = [0.45, 1, 0.45, 0.45]
            lit.keyTimes = up.keyTimes
            let g = CAAnimationGroup()
            g.animations = [up, lit]
            g.duration = 1.15
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.beginTime = Self.epoch + Double(i + 1) * 0.14
            mini.add(g, forKey: "wave")
        }
    }

    // "It knocks for you": an urgent lub-dub double thump with a breath of quiet
    // between beats — deliberately a different rhythm from working's smooth wave,
    // so peripheral vision alone separates them. Full-size dots also radiate a
    // sonar ring on each beat: the session is calling you.
    private func buildHeartbeat(ring: Bool) {
        let cycle: CFTimeInterval = 1.8
        // Epoch-anchored like the typing wave: rebuilds join mid-cycle seamlessly
        // (and all needs dots beat in unison, which reads as one call for attention).
        let t0 = Self.epoch

        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values =   [1, 1.28, 1, 1.2, 1, 1]
        beat.keyTimes = [0, 0.09, 0.18, 0.27, 0.38, 1]
        let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
        glow.values =   [4, 9, 4, 7.5, 4, 4]
        glow.keyTimes = beat.keyTimes
        let g = CAAnimationGroup()
        g.animations = [beat, glow]
        g.duration = cycle
        g.repeatCount = .infinity
        g.beginTime = t0
        core.add(g, forKey: "beat")

        guard ring else { return }
        let sonar = CAShapeLayer()
        sonar.name = "ring"
        sonar.frame = bounds
        sonar.path = CGPath(ellipseIn: bounds, transform: nil)
        sonar.fillColor = NSColor.clear.cgColor
        sonar.strokeColor = Status.accent("needs").cgColor
        sonar.lineWidth = 1.2
        sonar.opacity = 0                 // model stays invisible between emissions
        layer?.insertSublayer(sonar, below: core)

        // One emission per heartbeat cycle, synced to the first thump: the ring
        // swells + fades over 0.9s, then the group idles (presentation falls back
        // to the invisible model) until the next beat.
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 1; swell.toValue = 2.6
        swell.duration = 0.9
        swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55; fade.toValue = 0
        fade.duration = 0.9
        let rg = CAAnimationGroup()
        rg.animations = [swell, fade]
        rg.duration = cycle
        rg.repeatCount = .infinity
        rg.beginTime = t0
        sonar.add(rg, forKey: "sonar")
    }

    // "It landed": green core wearing a white ✓. On the transition into done the
    // core pops and the check strokes itself in; afterwards it just sits there —
    // done is a terminal state, obvious the moment it happens and silent after.
    private func buildDone(pop: Bool, check: Bool) {
        if pop {
            // A quick scale pop (anchor is the layer center) so the green "lands".
            let p = CAKeyframeAnimation(keyPath: "transform.scale")
            p.values = [1.0, 1.22, 1.0]
            p.keyTimes = [0, 0.4, 1]
            p.duration = 0.34
            p.timingFunction = CAMediaTimingFunction(name: .easeOut)
            core.add(p, forKey: "pop")
        }
        guard check else { return }

        // White checkmark over the green core. Points are in the dot's y-up layer
        // space: down to the low vertex, then up to the tall right arm.
        let w = bounds.width, h = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: w * 0.26, y: h * 0.54))
        path.addLine(to: CGPoint(x: w * 0.43, y: h * 0.34))
        path.addLine(to: CGPoint(x: w * 0.74, y: h * 0.68))
        let mark = CAShapeLayer()
        mark.name = "check"
        mark.frame = bounds
        mark.path = path
        mark.fillColor = NSColor.clear.cgColor
        mark.strokeColor = NSColor.white.cgColor
        mark.lineWidth = max(1.5, w * 0.14)
        mark.lineCap = .round
        mark.lineJoin = .round
        mark.strokeEnd = 1
        layer?.addSublayer(mark)

        if pop {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.26
            draw.beginTime = CACurrentMediaTime() + 0.08   // let the green land first
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            draw.fillMode = .backwards
            mark.add(draw, forKey: "draw")
        }
    }

    // "It's paused": the fuchsia core wears two white bars (⏸) and breathes slowly —
    // suspended-but-alive. Set when a turn is interrupted (cmd+c/Esc): Claude Code
    // emits no hook on interrupt, so the session comes to rest and only the ~60s
    // idle ping flips the stale working/needs to paused. The slow breathe (2.6s cycle)
    // sits between working's active typing and idle's dead stillness — frozen, but the
    // process is still there. Epoch-anchored so rebuilds join the same cycle and all
    // paused dots pulse in unison.
    //
    // Bar geometry (design/paused-icon-redesign.html 方案 A): the first cut used
    // barW = 0.16·d with a 0.20·d gap, which on the row dot is a 1.4px bar behind
    // a 1.8px gap — the ⏸ mushed into a gray smear instead of reading as two strokes.
    // Widening to 0.25·d with a tightened 0.16·d gap trades gap for ink — the glyph as a
    // whole grows 0.52·d → 0.66·d, and on the (now 14pt) row dot each bar lands on ~3.5px
    // instead of 1.4px. The breathe floor also rises 0.55 → 0.66 (the old trough dimmed
    // the row dot to near-extinguished, which read as "dying" rather than "held").
    // Height caps at 0.46·d: the bars have to clear the disc's curved shoulders, and past
    // that the outer bar's corners visibly crowd the rim.
    //
    // `bars` is false for compact dots (the 6pt CountPill / settings legend): two
    // sub-pixel strokes there collapse into one white blob that's *harder* to identify
    // than the bare fuchsia core. Same call the other statuses make — compact working
    // drops the typing split, compact done drops the ✓ — so paused is no longer the
    // one status with no small-size fallback.
    private func buildPause(bars drawBars: Bool) {
        var barsLayer: CAShapeLayer?
        if drawBars {
            let b = bounds
            let barW = b.width * 0.25
            let barH = b.height * 0.46
            let gap  = b.width * 0.16
            let cx = b.midX, cy = b.midY
            let r = barW * 0.42          // softened ends, still square enough to read as ⏸

            let bars = CAShapeLayer()
            bars.name = "pause"
            bars.frame = b
            let path = CGMutablePath()
            for sign in [-1.0, 1.0] as [CGFloat] {
                let x = cx + sign * (gap * 0.5 + barW * 0.5) - barW * 0.5
                path.addRoundedRect(in: CGRect(x: x, y: cy - barH * 0.5, width: barW, height: barH),
                                    cornerWidth: r, cornerHeight: r)
            }
            bars.path = path
            bars.fillColor = NSColor.white.cgColor
            layer?.addSublayer(bars)
            barsLayer = bars
        }

        // Slow breathe on the whole dot (core + bars in unison).
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.66
        breathe.duration = 1.3
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = Self.epoch
        core.add(breathe, forKey: "breathe")
        barsLayer?.add(breathe, forKey: "breathe")
    }

    // "Waiting on a command": a background shell is still running and the model will
    // pick up by itself when it exits (design/waiting-status-10-proposals.html 方案 13).
    // The disc goes hollow — a filled dot would claim "the model is busy" (blue) or
    // "yours now" (green), and this is neither — and the ring keeps a quarter gap that
    // circles once every 4s: unclosed = not finished, slow = nothing to rush for.
    // Compact dots keep the hollow reading but close the gap and don't spin: a 6pt
    // arc with a moving gap reads as flicker beside a count figure.
    private func buildAwait(accent: NSColor, spin: Bool) {
        core.backgroundColor = NSColor.clear.cgColor
        // shadowPath is set, so the glow would draw even under a clear fill.
        core.shadowOpacity = 0
        sphere.isHidden = true
        shade.isHidden = true

        let w = bounds.width
        let line = max(1.5, w * 0.15)
        let ring = CAShapeLayer()
        ring.name = "await"
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = accent.cgColor
        ring.lineWidth = line
        ring.lineCap = .round
        if spin {
            // 270° of a full-circle path: the gap is the untouched quarter.
            ring.strokeStart = 0.125
            ring.strokeEnd = 0.875
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * CGFloat.pi     // clockwise on screen
            turn.duration = 4
            turn.repeatCount = .infinity
            turn.beginTime = Self.epoch        // rebuilds rejoin the same phase
            ring.add(turn, forKey: "turn")
        }
        layer?.addSublayer(ring)
    }

    // "You are looking": the dot morphs into a watching eye — the red core
    // dissolves into a red pupil, an almond sclera (amber-outlined) draws itself
    // around it, and the eye comes alive: the pupil darts left↔right and the whole
    // eye blinks on a slow loop. The "查看中" beat, distinct from the green ✓ of an
    // actually-answered prompt. Loops until a status change tears it down.
    // `intro` plays the circle→eyeball morph — only on a real transition into
    // checking, never on a rebuild of an already-checking session (same rule as
    // buildTyping's split-in): a rebuild happens on every reloadData, and replaying
    // the fade-in there is the "the dot flashes whenever the row refreshes its ⏱
    // time" bug. Without it the layers' model values already ARE the settled eye.
    private func buildEye(intro: Bool) {
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        let hw = b.width * 0.92          // eye reaches well past the 14pt dot bounds
        let arch = b.height * 0.82

        // The eye group owns the blink (a vertical squash about its center). Default
        // anchorPoint (0.5,0.5) + frame == bounds puts its center on the dot center.
        let eye = CALayer()
        eye.name = "eye"
        eye.frame = b
        eye.masksToBounds = false
        layer?.addSublayer(eye)

        // Almond sclera: two symmetric quad arcs meeting at the left/right corners.
        let path = CGMutablePath()
        let left = CGPoint(x: c.x - hw, y: c.y), right = CGPoint(x: c.x + hw, y: c.y)
        path.move(to: left)
        path.addQuadCurve(to: right, control: CGPoint(x: c.x, y: c.y + arch))
        path.addQuadCurve(to: left,  control: CGPoint(x: c.x, y: c.y - arch))
        let sclera = CAShapeLayer()
        sclera.frame = b
        sclera.masksToBounds = false
        sclera.path = path
        sclera.fillColor = NSColor.white.withAlphaComponent(0.92).cgColor
        sclera.strokeColor = Status.accent("checking").cgColor
        sclera.lineWidth = 1.3
        sclera.lineJoin = .round
        eye.addSublayer(sclera)

        // Red pupil — the surviving soul of the dot.
        let pd = b.height * 0.64
        let pupil = CALayer()
        pupil.name = "pupil"
        pupil.bounds = CGRect(x: 0, y: 0, width: pd, height: pd)
        pupil.position = c
        pupil.cornerRadius = pd / 2
        pupil.backgroundColor = Status.accent("needs").cgColor
        eye.addSublayer(pupil)

        // Intro: the red core fades out as the sclera strokes itself in and the pupil
        // shrinks from dot-size into place — the literal "circle becomes an eyeball".
        core.opacity = 0
        if intro {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = 0.28
            eye.add(fadeIn, forKey: "in")
            let stroke = CABasicAnimation(keyPath: "strokeEnd")
            stroke.fromValue = 0; stroke.toValue = 1; stroke.duration = 0.34
            stroke.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sclera.add(stroke, forKey: "draw")
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = b.height / pd; shrink.toValue = 1; shrink.duration = 0.30
            shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pupil.add(shrink, forKey: "shrink")
        }

        // A genuine entrance keeps its own origin so the scan starts once the morph has
        // settled; a rebuild anchors to the shared epoch and rejoins the ongoing scan
        // mid-phase, so nothing visibly restarts (see Motion).
        let t0 = intro ? CACurrentMediaTime() + 0.34 : Self.epoch

        // Pupil darts right, holds, left, holds, recenters — a slow "reading" scan.
        let amp = hw * 0.42
        let dart = CAKeyframeAnimation(keyPath: "position.x")
        dart.values = [c.x, c.x + amp, c.x + amp, c.x - amp, c.x - amp, c.x]
        dart.keyTimes = [0, 0.18, 0.40, 0.58, 0.80, 1]
        dart.duration = 2.4
        dart.calculationMode = .cubic
        dart.repeatCount = .infinity
        dart.beginTime = t0
        pupil.add(dart, forKey: "dart")

        // Blink: mostly open, a quick vertical squash near the end of each cycle.
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.08, 1, 1]
        blink.keyTimes = [0, 0.86, 0.92, 0.98, 1]
        blink.duration = 3.2
        blink.repeatCount = .infinity
        blink.beginTime = t0
        eye.add(blink, forKey: "blink")
    }
}

// MARK: - Capsule label (status pill)

final class CapsuleLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bg = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerCurve = .continuous
        layer?.addSublayer(bg)

        label.font = Theme.font(11.5, .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bg.frame = bounds
        bg.cornerRadius = bounds.height / 2
    }

    // `bg` is a plain sublayer, so a bare color set would implicitly crossfade
    // (~0.25s); a pill recycled onto a different-status row would smear the old
    // color through the fade — same flash class as StatusDot.buildDecor. Snap it.
    private func setBg(_ color: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Resolved under this view's appearance: a theme's pill tones are dynamic
        // (light/dark), and a bare `.cgColor` would snapshot whichever appearance
        // happened to be current when the pill was configured.
        bg.backgroundColor = color.cg(in: self)
        CATransaction.commit()
    }

    /// Status pill: "运行中" as a filled chip. How it carries the label is a theme
    /// decision — a solid status color + white text reads as an opaque island over
    /// frosted glass, but on a warm opaque canvas that block is the heaviest thing
    /// on the row, so clay lays the deepened color as TEXT on a pale bed instead.
    /// Either way the tone comes from `Status.fill`, which knows which pill style is
    /// asking and derives an un-tuned color (a user override, another theme's preset)
    /// in the direction THAT style needs — deeper for white text, or away from the
    /// bed for a written label.
    func configure(status: String, text: String) {
        label.stringValue = text
        switch Status.pillStyle {
        case .solidWhiteText:
            label.textColor = .white
            setBg(Status.fill(status))
        case .tintedDeepText(let bed):
            label.textColor = Status.fill(status)
            setBg(Status.pillBed(status, mix: bed))
        }
    }
}

/// The mark that sits next to a Settings row title. Two kinds share one geometry:
///
/// **`.pro`** — the paid-tier marker. One amber, two readings:
/// - *unlocked* (the free beta): a tinted outline. It announces "this one is paid"
///   while the feature still works, which is the whole point of showing it early —
///   the day licensing lands, nothing gets taken away that wasn't already labelled.
/// - *locked* (1.0+): a solid deepened bed with white text. Loud on purpose: it's
///   the answer to "why won't this switch move?".
///
/// **`.dev`** — the row exists only in a development build (`Build.isDev`). Neutral
/// gray on purpose, NOT a second accent: it is a note to whoever builds the app, not
/// an offer to the user, and it must not compete with the amber that IS an offer. No
/// user ever sees it — a release binary doesn't build the rows it marks.
///
/// Sits next to a row title, so it's sized off the 14pt title rather than the 11.5pt
/// subtitle — small enough to read as a mark, not a second word.
final class MarkBadge: NSView {
    enum Kind {
        case pro(locked: Bool)
        case dev

        // Kerned caps at badge size read as a mark rather than a word.
        var text: String {
            switch self {
            case .pro: return "PRO"
            case .dev: return "DEV"
            }
        }
        /// Solid bed + white text (vs. a tinted outline).
        var isSolid: Bool {
            switch self {
            case .pro(let locked): return locked
            case .dev:             return false
            }
        }
        var tint: NSColor {
            switch self {
            case .pro: return Theme.proAccent
            case .dev: return .secondaryLabelColor
            }
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let bg = CALayer()
    private let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerCurve = .continuous
        bg.cornerRadius = 5
        bg.borderWidth = 1
        layer?.addSublayer(bg)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bg.frame = bounds
    }

    // The badge's tones are appearance-dynamic (amber brightens in dark, deepens in
    // light) and `.cg(in:)` snapshots whichever appearance was current. Re-resolve on
    // a light/dark flip, or a badge built in one appearance keeps the other's amber.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let tint = kind.tint
        label.attributedStringValue = NSAttributedString(string: kind.text, attributes: [
            .font: Theme.font(9.5, .bold),
            .kern: 0.7,
            .foregroundColor: kind.isSolid ? NSColor.white : tint,
        ])
        // Snap, don't crossfade — same reason CapsuleLabel does (a recycled badge
        // would otherwise smear the outgoing tone through a ~0.25s implicit fade).
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if kind.isSolid {
            // Deepened so white text clears contrast, exactly as the status pills do.
            bg.backgroundColor = tint.deepenedForWhiteText().cg(in: self)
            bg.borderColor = NSColor.clear.cgColor
        } else {
            bg.backgroundColor = tint.withAlphaComponent(0.14).cg(in: self)
            bg.borderColor = tint.withAlphaComponent(0.55).cg(in: self)
        }
        CATransaction.commit()
    }
}

// MARK: - AgentBadge (方案 A: inline "🤖 ×N" running-subagent chip)
//
// An iris-gradient capsule with white text — 🤖 glyph + "×N" + a disclosure chevron —
// plus a breathing pulse halo (方案 A + C). Iris (Theme.agentAccent), NOT the working
// blue: since the expandable agent sublist (T49) the badge is the agent-dimension
// control, deliberately distinct from every session-status color. Shown on a session
// row whenever it has background subagents in flight (SessionRow.bgAgents > 0),
// REGARDLESS of the row's status. It STANDS IN for the status pill (they never show
// together — see ChildCell.configure), taking the pill's right-edge slot at the same
// size: when agents are live, the badge IS that row's status label. Clicking it
// expands/collapses the agent sublist (hit-tested by SessionListView.rowClicked via
// ChildCell.agentBadgeHit — the cell claims all clicks, so the badge itself never
// sees mouseDown). Collapses to zero intrinsic width when count == 0 so it costs no
// layout space on the common (no-agent) row.
final class AgentBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()   // ⌄ / ⌃ — says "this capsule opens"
    private let bg = CAGradientLayer()   // iris gradient fill, white text
    private let pulse = CALayer()  // 方案 C: breathing halo behind the capsule
    private var count = 0
    private var expanded = false

    // Sized to match CapsuleLabel (the status pill) exactly — when a row has agents the
    // badge STANDS IN for the status pill (they never show together), so it must read as
    // the same-weight island in the same spot.
    private static let hPad: CGFloat = 10
    private static let height: CGFloat = 22
    private static let pulseKey = "agentPulse"

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Pulse halo sits BELOW the capsule fill so the glyph/count stay crisp while a
        // soft iris glow breathes outward behind them (方案 C layered onto 方案 A).
        pulse.cornerCurve = .continuous
        pulse.opacity = 0
        layer?.addSublayer(pulse)
        bg.cornerCurve = .continuous
        // 135° iris gradient (design mock's `linear-gradient(135deg, #7c8cff, #5a6bf5)`).
        bg.startPoint = CGPoint(x: 0, y: 1)
        bg.endPoint   = CGPoint(x: 1, y: 0)
        layer?.addSublayer(bg)

        label.font = Theme.rounded(11.5, .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Disclosure chevron INSIDE the capsule, right of the count. A real SF Symbol
        // image (not an 8pt glyph appended to the attributed string — that earlier
        // attempt was too small to see and sat on the text baseline, reading as
        // vertically off-center): an image view centers on its own and the symbol
        // configuration gives it a usable weight at 9pt.
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleNone
        addSubview(chevron)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Tighter right inset than the left: the chevron's own glyph carries
            // whitespace, so a full hPad after it reads as a lopsided capsule.
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.hPad - 2)),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // CoreAnimation drops a layer's animations when its view leaves the window (cell
    // recycling / scroll). On return, configure() may early-out if count is unchanged
    // and never re-add the pulse — so restart it here whenever we're back on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, count > 0 { startPulse() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        bg.cornerRadius = bounds.height / 2
        // Halo shares the capsule frame; its transform.scale animation (anchored at the
        // layer center) grows it outward from behind the fill.
        pulse.frame = bounds
        pulse.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    // Show "🤖 ×N ⌄" for count > 0, hide (zero-width) otherwise. A count > 0 also runs
    // the breathing pulse halo (方案 C). The chevron flips ⌄/⌃ with `expanded` — the
    // badge is a disclosure control and has to look like one; the pulse alone left
    // people guessing whether it was clickable.
    func configure(count: Int, expanded: Bool = false) {
        guard count != self.count || expanded != self.expanded else { return }
        self.count = count
        self.expanded = expanded
        isHidden = count <= 0
        guard count > 0 else { stopPulse(); invalidateIntrinsicContentSize(); return }
        let s = NSMutableAttributedString(string: "🤖 ",
            attributes: [.font: Theme.rounded(12, .medium)])
        s.append(NSAttributedString(string: "×\(count)",
            attributes: [.foregroundColor: NSColor.white, .font: Theme.rounded(11.5, .bold)]))
        label.attributedStringValue = s
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                                accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.colors = [Theme.agentAccent.cgColor, Theme.agentDeep.cgColor]
        pulse.backgroundColor = Theme.agentAccent.withAlphaComponent(0.55).cgColor
        CATransaction.commit()
        startPulse()
        invalidateIntrinsicContentSize()
    }

    // A soft iris halo that scales up and fades out on a loop — the "×N agents are
    // live" heartbeat. Idempotent: re-adding under the same key while already running
    // is a no-op, so cell reconfigure churn never restarts or stacks it.
    private func startPulse() {
        guard pulse.animation(forKey: Self.pulseKey) == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.42
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.9
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Epoch-anchored like the axis node's blink: idempotence only holds while the
        // animation survives, and leaving the window strips it — the re-add on the next
        // reload would otherwise restart the halo from its first frame (see Motion).
        group.beginTime = Motion.epoch
        pulse.add(group, forKey: Self.pulseKey)
    }

    private func stopPulse() {
        pulse.removeAnimation(forKey: Self.pulseKey)
    }
}

// MARK: - AgentCell (expanded subagent sublist node — design 方案 9)
//
// One background subagent, shown under its session row when the 🤖 badge is
// expanded. An iris axis thread runs down the left with a glowing node per agent
// (iris pulse = running, solid green = returned); the body is two lines — task
// name (left) + type chip (right) above, "⏱ elapsed · tokens" (left) + live tool
// step (right) below — and the far right carries the agent's own mini status pill.
// The cell hosts a GroupCard slice so the sublist visually CONTINUES the session's
// enclosure (the last node rounds the group bottom).

// Small rounded tag shared by the agent type chip (tinted + hairline border) and
// the mini status pill (tint only). NSTextField can't pad itself, hence the wrap.
final class AgentTag: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bg = CALayer()

    init(fontSize: CGFloat, height: CGFloat, hPad: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerCurve = .continuous
        layer?.addSublayer(bg)
        label.font = Theme.rounded(fontSize, .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Breakable padding: an owner collapses the tag to zero width when there is no
        // text to show, and required insets would fight that width constraint.
        let lead = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad)
        let trail = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad)
        lead.priority = .defaultHigh
        trail.priority = .defaultHigh
        NSLayoutConstraint.activate([
            lead, trail,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        bg.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    func configure(text: String, textColor: NSColor, fill: NSColor, border: NSColor? = nil) {
        label.stringValue = text
        label.textColor = textColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.backgroundColor = fill.cgColor
        bg.borderColor = border?.cgColor
        bg.borderWidth = border == nil ? 0 : 1
        CATransaction.commit()
    }
}

// The iris thread + glowing node down the sublist's left edge. The line runs the
// full row height (the last node stops at its dot so the thread visibly ends);
// the dot blinks while the agent runs and holds solid green once returned.
final class AgentAxisView: NSView {
    private let line = CALayer()
    private let dot = CALayer()
    private var running = false
    private var stopsAtNode = false
    private static let blinkKey = "agentNodeBlink"
    // The blink's dim end — also the dot's resting model value while running (see configure).
    private static let blinkDim: Float = 0.35

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        dot.cornerCurve = .continuous
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Same CoreAnimation drop as AgentBadge's pulse: re-add the blink whenever the
    // recycled cell returns to a window with a running agent.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, running { startBlink() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let cx = bounds.midX
        let d: CGFloat = 9
        dot.frame = CGRect(x: cx - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        dot.cornerRadius = d / 2
        // Layer space is y-up: the visual "top → node/bottom" run is maxY down.
        let bottom = stopsAtNode ? bounds.midY : 0
        line.frame = CGRect(x: cx - 1, y: bottom, width: 2, height: bounds.maxY - bottom)
        CATransaction.commit()
    }

    func configure(running: Bool, stopsAtNode: Bool) {
        self.running = running
        self.stopsAtNode = stopsAtNode
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.backgroundColor = Theme.agentAccent.withAlphaComponent(0.32).cgColor
        let c = running ? Theme.agentAccent : Status.accent("done")
        dot.backgroundColor = c.cgColor
        dot.shadowColor = c.cgColor
        dot.shadowOpacity = running ? 0.8 : 0
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        // Park the MODEL opacity at the blink's dim end while running (default is 1.0).
        // reloadData() detaches the cell on every refresh tick — every second while ⏱ is
        // under a minute, and again on each tool step — and CoreAnimation strips the loop
        // with it, so for one frame the dot paints its model value before the re-add
        // (epoch-anchored) snaps it back mid-phase. At the default 1.0 that frame is a
        // full-brightness spike: the node visibly flashes in lockstep with the refresh,
        // which phase anchoring alone cannot fix (it keeps the phase, not the model).
        // Parking at the trough makes the gap invisible — same trick as the typing minis
        // (opacity 0.45) and the sonar ring (0). A returned node holds solid green.
        dot.opacity = running ? Self.blinkDim : 1
        CATransaction.commit()
        if running { startBlink() } else { dot.removeAnimation(forKey: Self.blinkKey) }
        needsLayout = true
    }

    private func startBlink() {
        guard dot.animation(forKey: Self.blinkKey) == nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = Self.blinkDim
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Epoch-anchored (see Motion): the sublist reloads whenever an agent's ⏱ elapsed
        // ticks over — every second while it's under a minute — and an un-anchored blink
        // restarts from full opacity on each of those rebuilds, so the node visibly
        // flashes in lockstep with the time refresh. Anchoring rejoins the phase (and all
        // running nodes blink in unison); configure() parks the model value at the trough
        // so the detach frame between strip and re-add is invisible too.
        a.beginTime = Motion.epoch
        dot.add(a, forKey: Self.blinkKey)
    }
}

final class AgentCell: NSTableCellView, Hoverable {
    private let card = GroupCard(radius: Theme.group)
    private let axis = AgentAxisView()
    private let nameLabel = NSTextField(labelWithString: "")
    // 10pt sits between the metrics row (10.5) and nothing smaller on screen — 9 read as
    // fine print next to the 11.5pt status pill it shares an edge with.
    private let chip = AgentTag(fontSize: 10, height: 16, hPad: 7)     // agent 职位 (type)
    private let usage = UsageMetricsView()   // the SAME 第二列 the session rows use
    private let stepLabel = NSTextField(labelWithString: "")           // live tool step, right-aligned
    // The SAME status pill the session rows wear (CapsuleLabel + Status.label/fill), so
    // an agent node's right edge reads exactly like the row above it: 运行 blue / 完成
    // green, two CJK characters wide, and gone entirely when 设置 › 显示状态标签 is off.
    private let pill = CapsuleLabel()
    private lazy var pillCollapse = pill.widthAnchor.constraint(equalToConstant: 0)
    // A launch without a subagent_type has no 职位 to show: collapse the tag away rather
    // than leaving its padding as a gap in the right column.
    private lazy var chipCollapse = chip.widthAnchor.constraint(equalToConstant: 0)

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        letShadowsEscape()

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        axis.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(axis)

        nameLabel.font = Theme.font(12, .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        // Hug the text so a short name occupies only what it needs; still the first thing
        // to truncate when the row runs out of space.
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nameLabel)

        chip.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chip)

        card.addSubview(usage)

        stepLabel.font = Theme.rounded(10.5, .medium)   // same size as a row's step column
        stepLabel.lineBreakMode = .byTruncatingTail
        stepLabel.maximumNumberOfLines = 1
        stepLabel.alignment = .right
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stepLabel)

        pill.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pill)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cardCellInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.cardCellInset),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Thread centered under the session row's status dot (cell x = 44).
            axis.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 31),
            axis.widthAnchor.constraint(equalToConstant: 14),
            axis.topAnchor.constraint(equalTo: card.topAnchor),
            axis.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            // 55 = a session row's own title/meta x (6 card inset + 9 rail + 14 + 8 dot
            // + 14 + 10), so an agent node's name and metrics columns land on exactly
            // the same verticals as the row it hangs under.
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 55),
            nameLabel.bottomAnchor.constraint(equalTo: card.centerYAnchor, constant: -1),

            // 职位 tag right-aligns into the status pill's column instead of trailing the
            // name (design/agent-name-tag-5-proposals.html, 方案 5). Chasing the end of a
            // variable-length name put the tag at a different x on every node — four names,
            // four positions, no column for the eye to follow, which is exactly what read
            // as "messy". Pinned to the right it joins the pill in one straight attribute
            // band, and the name gets the whole left side to stretch into.
            chip.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -8),
            chip.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            // The name yields first (its compression resistance is low), so a long title
            // truncates against the tag rather than pushing it out of the row.
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -8),

            usage.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usage.topAnchor.constraint(equalTo: card.centerYAnchor, constant: 1),
            usage.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

            // Step right-aligned on the meta line, sharing the pill's right column.
            stepLabel.leadingAnchor.constraint(greaterThanOrEqualTo: usage.trailingAnchor, constant: 10),
            stepLabel.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -8),
            stepLabel.centerYAnchor.constraint(equalTo: usage.centerYAnchor),

            pill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            pill.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        card.setHover(.none, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Same first-click / whole-card hit claim as ChildCell, so a click anywhere on
    // the node jumps to the parent session on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    func setHovered(_ lift: HoverLift, groupCenter: NSPoint?, groupRole: SliceRole?, animated: Bool) {
        card.setHover(lift,
                      groupCenter: groupCenter.map { card.convert($0, from: self) },
                      groupRole: groupRole,
                      animated: animated)
    }

    func setSelected(_ on: Bool, animated: Bool) { card.setSelected(on, animated: animated) }

    // `isLastNode` ends the iris thread at this node's dot (last agent of the
    // sublist); `isLastRow` makes this slice round the whole enclosure's bottom
    // (the sublist extends its session group, so the LAST agent of the LAST
    // session carries the bottom corners).
    // `worker-coder` → "coder", `manager-frontend` → "frontend", `general-purpose` →
    // "general". The family is already what the tint says, so spelling it out again only
    // spends width in a column that has little to spare. Types outside the convention
    // (Explore, project-local ones) show verbatim — trimming them would invent meaning.
    private static func shortType(_ t: String) -> String {
        for p in ["worker-", "manager-"] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return t == "general-purpose" ? "general" : t
    }

    // The tag is colored by the type's FAMILY — the prefix convention agents are named
    // by — not by anything the agent is doing (its state already has the pill, and a
    // second status-colored thing on the same edge would just compete with it):
    //   worker-*   → iris   (the agent dimension's own color)
    //   manager-*  → teal   (the ones that dispatch other agents)
    //   everything else (Explore, general-purpose, project-local) → neutral gray
    // So a glance down the sublist counts workers vs managers without reading a word.
    private static func typeTint(_ t: String) -> NSColor {
        if t.hasPrefix("manager-") { return Theme.agentManagerAccent }
        if t.hasPrefix("worker-")  { return Theme.agentAccent }
        return Theme.agentNeutralAccent
    }

    func configure(_ a: AgentInfo, parentStatus: String, parentModel: String,
                   isFirstNode: Bool, isLastNode: Bool, isLastRow: Bool) {
        // Every node draws the between-rows hairline, including the first one: it separates
        // the sublist from the session row it hangs under, so a run of agents reads as
        // discrete entries instead of one tall block of text.
        // 方案 16「父子连体卡」: the nodes were ALREADY slices of the session row's own
        // enclosure, which is why the sublist read as "more rows" — a shared card with a
        // shared fill has nothing to say it's a layer. `nested` tints the whole segment
        // iris and the first node turns its hairline into the iris seam, so the card
        // visibly splits into 会话 / agents while keeping every column aligned.
        card.configure(role: isLastRow ? .bottom : .middle, isHeaderBand: false, topDivider: true,
                       nested: true, seamTop: isFirstNode)
        card.setAccent(parentStatus)
        axis.configure(running: true, stopsAtNode: isLastNode)

        nameLabel.stringValue = a.desc.isEmpty ? (a.type.isEmpty ? "Agent" : a.type) : a.desc

        // 职位 tag — hidden (and collapsed) when the launch carried no subagent_type.
        // Filled AND outlined: borderless with a 0.12 wash disappeared into the glass at
        // this size (9pt in a 16pt capsule), which is not the same thing as "quiet".
        let hasType = !a.type.isEmpty
        chip.isHidden = !hasType
        chipCollapse.isActive = !hasType
        if hasType {
            let tint = Self.typeTint(a.type)
            chip.configure(text: Self.shortType(a.type),
                           textColor: tint,
                           fill: tint.withAlphaComponent(0.22),
                           border: tint.withAlphaComponent(0.48))
        }

        // The metrics line is the session row's own 第二列 component (UsageMetricsView),
        // not a look-alike: same columns, fonts, tints and chips, so reading down the
        // list an agent node's ⏱ / ◆ / % / model land on the parent row's verticals.
        //
        // Elapsed keeps counting for as long as the node exists — the node disappears
        // the moment the agent finishes, so there is no frozen end state to render
        // (always: true keeps every slot rendered from the first frame — a fixed set of
        // columns reads as a table down the sublist, where appearing segments made each
        // node a different shape).
        let now = Date().timeIntervalSince1970
        let elapsed = a.start > 0 ? max(0, Int(now - a.start)) : 0
        // The agent's model: its own override when the launch passed one, otherwise the
        // session's (an agent with no `model` arg inherits the parent's).
        //
        // Context occupancy is the agent's REAL one, tailed from its own transcript
        // (AgentInfo.ctxTokens) against the parent's window — it used to be a hardcoded
        // 0% holding the column, which read as "every agent sits at 0%". Unknown yet
        // (no reply on record) → -1, and the capsule stays empty rather than lying.
        usage.configure(meta: UsageMetricsView.usageText(workSec: elapsed,
                                                         ctxTokens: a.ctxTokens, always: true),
                        pct: a.ctxPct,
                        model: a.model.isEmpty ? parentModel : a.model.capitalized)

        // The step column obeys 设置 › 显示 › 当前步骤 here too. It used to be exempt (the
        // live step is the whole point of expanding the sublist), but a switch labelled
        // "当前步骤" that leaves steps on screen is just a broken switch — off means off,
        // wherever the step is drawn. The right edge still says 运行/完成 via the pill.
        if !AppSettings.showStepLabel {
            stepLabel.stringValue = ""
        } else {
            stepLabel.stringValue = a.step.isEmpty ? "" : "▸ " + a.step
            stepLabel.textColor = Status.accent("working")
        }
        // A listed agent is by definition still working, so it speaks the list's own
        // 运行 (blue) and obeys the same 显示状态标签 switch: off → the pill collapses to
        // zero width and the step column reclaims the space, exactly as on a row.
        let st = "working"
        let showPill = AppSettings.showStatusLabels
        pill.isHidden = !showPill
        pillCollapse.isActive = !showPill
        if showPill { pill.configure(status: st, text: Status.label(st)) }
        card.setHover(.none, animated: false)
    }
}

// MARK: - HiddenBar (hidden-projects discoverability + undo)
//
// A slim strip shown below the session list (main window + popover) whenever the
// user has hidden ≥1 project. Two faces:
//   • passive — "N 个项目已隐藏" + a "恢复" button that opens 设置 › 已隐藏.
//   • undo    — right after a hide, "已隐藏「X」" + an "撤销" button that puts it
//               back; auto-reverts to passive after a few seconds.
// Collapses to zero height (isHidden + 0 height constraint) when nothing is hidden
// and no undo is pending, so it costs no space in the common case. Neutral gray —
// red stays reserved for 需确认.
final class HiddenBar: NSView {
    var onOpenHidden: (() -> Void)?
    var onUndo: ((String) -> Void)?
    // Popover sizes to content, so it re-measures when the bar collapses/expands.
    var onHeightChange: (() -> Void)?

    static let barHeight: CGFloat = 30

    private let pill = CALayer()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var heightC: NSLayoutConstraint!

    private var hiddenCount = 0
    private var undoCwd: String?
    private var undoFolder = ""
    private var undoOnboarding = false
    private var undoTimer: Timer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        pill.cornerRadius = 8
        pill.cornerCurve = .continuous
        pill.borderWidth = 1
        layer?.addSublayer(pill)

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = Theme.font(11.5, .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        button.isBordered = false
        button.target = self
        button.action = #selector(actionTapped)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        heightC = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightC,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        pill.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }
    private func applyChrome() {
        pill.backgroundColor = Theme.cardFill.cg(in: self)
        pill.borderColor = Theme.hairline.cg(in: self)
    }

    // True while the transient undo prompt owns the bar. The tip bar sits right above
    // and stands down while this is up: two teaching strips at once is noise, and on a
    // narrow window it's also two truncated sentences.
    var isShowingUndo: Bool { undoCwd != nil }

    // Called on every reload with the current hidden-project count. Doesn't disturb
    // an in-progress undo prompt (it has its own timer).
    func update(count: Int) {
        hiddenCount = count
        if undoCwd == nil { render() }
    }

    // Show the transient "已隐藏「X」· 撤销" prompt after a hide.
    func showUndo(folder: String, cwd: String, onboarding: Bool) {
        undoCwd = cwd
        undoFolder = folder
        undoOnboarding = onboarding
        render()
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.clearUndo()
        }
    }

    private func clearUndo() {
        undoTimer?.invalidate(); undoTimer = nil
        undoCwd = nil
        render()
    }

    private func render() {
        applyChrome()
        if undoCwd != nil {
            let base = L("已隐藏「\(undoFolder)」", "Hidden \"\(undoFolder)\"")
            label.stringValue = undoOnboarding ? base + L(" · 可在 设置 › 已隐藏 恢复", " · Restore in Settings › Hidden") : base
            button.attributedTitle = tinted(L("撤销", "Undo"))
            setVisible(true)
        } else if hiddenCount > 0 {
            label.stringValue = L("\(hiddenCount) 个项目已隐藏", "\(hiddenCount) hidden")
            button.attributedTitle = tinted(L("恢复", "Restore"))
            setVisible(true)
        } else {
            setVisible(false)
        }
    }

    private func setVisible(_ on: Bool) {
        let changed = isHidden == on
        isHidden = !on
        heightC.constant = on ? Self.barHeight : 0
        if changed { onHeightChange?() }
    }

    // Blue "working" accent — the affordance color, distinct from the neutral label.
    private func tinted(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: Status.accent("working"),
            .font: Theme.font(11.5, .semibold),
        ])
    }

    @objc private func actionTapped() {
        if let cwd = undoCwd {
            clearUndo()
            onUndo?(cwd)
        } else {
            onOpenHidden?()
        }
    }

    override func resetCursorRects() { addCursorRect(button.frame, cursor: .pointingHand) }
}

// MARK: - Chip chrome (CountPill / QuotaCapsule)
//
// The two chips are built the same way — one rounded `fill` layer carrying an
// opaque background, plus (for a light-bounded theme) a `glow` sibling BEHIND it
// for the counter-lobe, since a layer carries exactly one shadow. These two
// functions are the whole difference between a hairline theme and a clay one, so
// neither chip has to know which it is in.

/// Frames and shadow outlines. Pre-rendered paths, as everywhere else: the header
/// re-renders on every refresh tick.
private func layoutChipSurface(fill: CALayer, glow: CALayer, bounds: CGRect, radius: CGFloat) {
    fill.frame = bounds
    glow.frame = bounds
    glow.cornerRadius = radius
    glow.cornerCurve = .continuous
    guard bounds.width > 0, bounds.height > 0 else { return }
    let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)
    fill.shadowPath = path
    glow.shadowPath = path
}

/// Colors. A hairline theme strokes the chip; a light-bounded one raises it with
/// the design's `.clay-sm` — the card's own recipe at chip scale, so a chip reads
/// as the same substance as the surface it sits on rather than a sticker on it.
/// A bare chip pane: fill, border/shadow lobe, rounded corners, nothing else. For
/// hosts that want the surface UNDER a set of subviews they lay out themselves —
/// QuotaTrio uses one so the strip itself can stay a plain, non-layer-backed view.
final class ChipShellView: NSView {
    private let glow = CALayer()
    private let fill = CALayer()
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        fill.cornerRadius = Theme.chip
        fill.cornerCurve = .continuous
        layer?.addSublayer(glow)
        layer?.addSublayer(fill)
        applyChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChipSurface(fill: fill, glow: glow, bounds: bounds, radius: Theme.chip)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }
    private func applyChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        styleChipSurface(fill: fill, glow: glow, in: self)
        CATransaction.commit()
    }
}

private func styleChipSurface(fill: CALayer, glow: CALayer, in view: NSView) {
    fill.backgroundColor = Theme.cardFill.cg(in: view)
    guard let lighting = Theme.shadow(in: view)?.small else {
        fill.borderWidth = 1
        fill.borderColor = Theme.hairline.cg(in: view)
        fill.shadowOpacity = 0
        glow.shadowOpacity = 0
        return
    }
    fill.borderWidth = 0
    fill.applyShadowLobe(lighting.drop)
    // `glow` needs no fill of its own: it sits exactly behind `fill`, whose opaque
    // background hides the interior of the lobe.
    if let counter = lighting.counterGlow { glow.applyShadowLobe(counter) }
    else { glow.shadowOpacity = 0 }
}

// MARK: - CountPill (combined status counts on a group header)
//
// ONE glass chip holding every nonzero status bucket as a "● n" segment (design
// mock `.cpill`), instead of one tinted capsule per status — the counts read as a
// single quiet gauge on the header's right edge.

final class CountPill: NSView {
    private let glow = CALayer()   // clay counter-lobe, behind bg
    private let bg = CALayer()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        bg.cornerRadius = Theme.chip
        bg.cornerCurve = .continuous
        bg.borderWidth = 1
        layer?.addSublayer(glow)
        layer?.addSublayer(bg)

        stack.orientation = .horizontal
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        applyChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChipSurface(fill: bg, glow: glow, bounds: bounds, radius: Theme.chip)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    private func applyChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        styleChipSurface(fill: bg, glow: glow, in: self)
        CATransaction.commit()
    }

    /// The summary variant: fold a row list into one chip per non-empty status
    /// bucket, in the user's configured order. It lives here rather than in the
    /// callers so both hosts — the popover's header row and the main window's
    /// title row — derive the same counts from the same rows.
    func configure(rows: [SessionRow], placeholder: String?) {
        let counts = AppSettings.statusDisplayOrder.compactMap { status -> (String, Int)? in
            let n = rows.filter { Status.bucket($0.status) == status }.count
            return n > 0 ? (status, n) : nil
        }
        configure(placeholder: placeholder, counts: counts)
    }

    // `placeholder` stands in when there are no buckets to draw — the summary
    // header passes "—" so its chip still anchors the header's left edge on an
    // empty list (per-group headers pass nil and hide themselves instead).
    func configure(placeholder: String? = nil, counts: [(String, Int)]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if counts.isEmpty, let placeholder = placeholder, !placeholder.isEmpty {
            let tl = NSTextField(labelWithString: placeholder)
            tl.font = Theme.rounded(11, .bold)
            tl.textColor = .labelColor
            stack.addArrangedSubview(tl)
        }
        for (status, count) in counts {
            let dot = StatusDot(diameter: 6, compact: true)
            dot.apply(status)
            let label = NSTextField(labelWithString: "\(count)")
            label.font = Theme.rounded(11, .bold)
            label.textColor = Status.accent(status)
            stack.addArrangedSubview(dot)
            stack.setCustomSpacing(4, after: dot)
            stack.addArrangedSubview(label)
        }
    }
}

// MARK: - MetricCard (stacked gauges on one pane of glass)
//
// Three of these side by side ARE the header strip: this machine (CPU over
// memory — clickable, it opens Activity Monitor), Claude, and Codex (each the 5h
// session window over the weekly subscription limit, clickable to show which
// account the figures belong to). Every line reads
// [icon] [pct%] [micro bar] [footnote].
//
// EVERY COLUMN IS A FIXED SLOT, and that is the whole point. The pct field and
// the footnote carry constant widths, so all six micro bars inside a card share
// one left edge — the rows read as one grid instead of independently-sized chips.
// Any change that lets a column size itself to its content breaks every row at
// once. (Across cards the left edges only agree while the strip is at rest; a
// focused card is deliberately wider than its neighbours — see QuotaTrio.)
//
// The footnote is set in a TRUE monospaced face — NOT Theme.roundedMono. That one
// gives tabular DIGITS only, and the digits were never the problem: the letters
// were. "3h20m" and "5d02h" are both five characters, but in the rounded face `m`
// is wider than `d` is wider than `h`, so the figures inside them landed in
// different columns and only the right edge ever agreed. The countdown formatter
// (resetCountdown) pads to a constant SIX characters for the same reason — a bare
// "12m" would pull the column apart again on its own.

/// The countdown beside a gauge: "2h/35m" under a day out, "5d/02h" over it.
/// ★ Never MORE than six characters — see the fixed-slot note above; six exactly for
/// everything under ten days, which is every case either CLI's window produces except
/// Codex's long one ("26d"). The slash is deliberate:
/// "1h44m" read as one run-together number, and the two units are two things.
/// What goes in the countdown slot when there is nothing to count down to: the
/// window hasn't started (a 5-hour window begins at the account's first message, so
/// an untouched account has no reset instant at all), or the reset time was never
/// recorded. ★ Six characters like every other value in this slot — an empty slot
/// reads as a rendering fault, not as "unknown".
let unknownCountdown = "?h/??m"

func resetCountdown(_ epoch: Double) -> String {
    let s = max(0, Int(epoch - Date().timeIntervalSince1970))
    let days = s / 86_400
    // ★ Ten days out the hours go, because "26d/09h" is SEVEN characters and does not
    // fit: it measures 41.5pt against a 36pt slot (measured 2026-09-14), and the field
    // resists compression, so what Auto Layout breaks is the SLOT's width constraint
    // and both ends lose — the field was handed 40pt, taking 4 of them out of the one
    // elastic thing on its row (its own bar, which then ends short of the column the
    // other three share), and 40 still isn't 41.5 so it was clipped anyway. Measured,
    // not reasoned: tools/header-preview.sh reports it. Codex hands out exactly this
    // value — the user's 2026-09-11 screenshot reads "26d/09h". A bare "26d" is
    // shorter than six, but the
    // field is right-aligned inside a fixed slot, so it moves nothing; and at 26 days
    // the hours were never the part anyone reads.
    if days >= 10 { return String(format: "%dd", min(days, 999)) }
    if days >= 1 { return String(format: "%dd/%02dh", days, (s % 86_400) / 3600) }
    return String(format: "%dh/%02dm", s / 3600, (s % 3600) / 60)
}
//

/// One gauge line: [icon] [pct%] [micro bar] [footnote].
final class MetricLine: NSView {
    /// Column geometry. The two presets differ only in how much room the line has:
    /// `.grid` gets half a header, `.trio` gets a third. Everything `.trio` shaves
    /// (a point of leading, a point of type) is what buys the bar enough width to
    /// still read as a bar at that size.
    struct Style {
        let height: CGFloat
        let iconW: CGFloat
        let gap: CGFloat
        let pctW: CGFloat
        // ★ Right-aligning the percentage lines up the digits' RIGHT edges, and pays for
        // it with a variable gap on the LEFT: the column is sized for "100%", so a
        // 2-digit reading floats ~7pt off the icon (measured). The grid can afford that —
        // its four lines read as one table. The trio can't: its cards are ~70pt at rest,
        // so the same gap reads as a hole between an icon and its own number.
        let pctAlign: NSTextAlignment
        let footW: CGFloat
        let pctFont: NSFont
        let barMin: CGFloat
        let barMinPriority: NSLayoutConstraint.Priority

        static let grid = Style(height: 23, iconW: 12, gap: 6, pctW: 30, pctAlign: .right, footW: 37,
                                pctFont: Theme.roundedMono(11.5, .bold),
                                barMin: 60, barMinPriority: .required)
        // barMin drops to 6 here AND stops being required: a trio card that has
        // given up width to its focused neighbour is ~73pt wide, far under the
        // 60pt floor the grid's bar insists on. Left required, that floor would
        // make the strip's own width arithmetic unsatisfiable and Auto Layout
        // would break a card's width to keep a progress bar happy.
        // ★ The account panel's rows use this SAME preset, to the point — same icon
        // box, same gaps, same figure slot, same face, same countdown slot — because
        // the panel hangs directly under the card it belongs to and the two are read
        // in one glance. A second preset "to fit the panel better" is what makes the
        // two stop looking like the same instrument.
        // Slots tuned by the user in the round-8 preview (2026-09-11), then widened
        // to what the App's own fonts need (NSTextField intrinsic width, measured):
        // pctW 23 → 25 ("35%" is 25.0 in rounded bold 10.5; 23 clips the sign),
        // footW 35 → 36 ("5d/02h" is 35.5 in monospaced 9.5). "100%" is 32 and does
        // NOT fit — it never did at 29 either — which is why a three-digit reading
        // drops the sign (see `configure`), and why a countdown of ten days or more
        // drops its hours (see `resetCountdown`). Both slots are sized for what they
        // can now actually be handed; widening either is what puts the dead air back.
        static let trio = Style(height: 17, iconW: 12, gap: 2, pctW: 25, pctAlign: .left, footW: 36,
                                pctFont: Theme.roundedMono(10.5, .bold),
                                barMin: 6, barMinPriority: .defaultHigh)
    }

    private let style: Style
    private let iconView = NSImageView()
    private let pctField = NSTextField(labelWithString: "")
    private let bar: MicroProgressBar
    private let footField = NSTextField(labelWithString: "")

    init(symbol: String, accessibility: String, style: Style = .grid) {
        self.style = style
        self.bar = MicroProgressBar(minWidth: style.barMin, minWidthPriority: style.barMinPriority)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pctField.font = style.pctFont
        pctField.alignment = style.pctAlign
        footField.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
        footField.textColor = .labelColor
        footField.alignment = .right
        for f in [pctField, footField] {
            // ⚠️ Load-bearing. These two used to be arranged subviews of an
            // NSStackView, which sets this for you; the switch to explicit
            // constraints inherited the views but not that favour. Left on, their
            // autoresizing-derived constraints fight the ones below, the line's
            // width chain never resolves, and the header's fitting width collapses
            // (measured: 51pt instead of ~430). This window is content-sized, so
            // AppKit then shrank the whole window to ~130pt — which looked like
            // "the grid is squeezed to icons" and "the window won't resize".
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byClipping
            f.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // Explicit constraints, not an NSStackView. The bar has to eat ALL the space
        // its fixed neighbours don't, and a stack won't guarantee that: the default
        // `.gravityAreas` distribution packs its views and leaves the slack sitting
        // at the end, so the bar stayed at its 48pt preferred width and the row had
        // a gap before the footnote. Pinning the bar to both neighbours makes its
        // width a consequence of the card's width — no priority tug-of-war to lose.
        for v in [iconView, pctField, bar, footField] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: style.height),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: style.iconW),
            iconView.heightAnchor.constraint(equalToConstant: style.iconW),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            pctField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: style.gap),
            pctField.widthAnchor.constraint(equalToConstant: style.pctW),
            pctField.centerYAnchor.constraint(equalTo: centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: pctField.trailingAnchor, constant: style.gap),
            bar.trailingAnchor.constraint(equalTo: footField.leadingAnchor, constant: -style.gap),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),

            footField.trailingAnchor.constraint(equalTo: trailingAnchor),
            footField.widthAnchor.constraint(equalToConstant: style.footW),
            footField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `pct == nil` = the figure isn't known yet (CPU needs two samples before it
    /// can report anything, and a fresh account has no quota snapshot). The line
    /// keeps its height either way, so the header never changes size under you.
    /// `stale` = this is a REMEMBERED figure for the account shown, not a current
    /// measurement (right after a switch, before anything has measured the new
    /// account). Half a step back, not a grey — the same treatment, and the same
    /// 0.72, the account panel's rows use for the identical fact. It must not read
    /// with the confidence of a live figure, and it must still be readable.
    func configure(pct: Int?, foot: String, tooltip: String? = nil, stale: Bool = false) {
        toolTip = tooltip
        alphaValue = stale && pct != nil ? 0.72 : 1
        guard let pct = pct else {
            iconView.contentTintColor = .tertiaryLabelColor
            pctField.stringValue = "—"
            pctField.textColor = .tertiaryLabelColor
            bar.configure(pct: 0)
            footField.stringValue = ""
            return
        }
        let tint = Status.usageTint(pct)
        iconView.contentTintColor = tint
        // ★ At three digits the sign goes. "100%" measures 30.5pt in this face and the
        // figure slot is 25 (NSTextField intrinsic width, both measured) — it was
        // clipped at the old 29 too, so this is not something the round-8 retune broke.
        // The two ways to keep the sign both cost more than it is worth: widening the
        // slot puts 6pt of dead air between EVERY two-digit reading and its bar, which
        // is the "too much space in the middle" the user threw out twice (2026-09-10,
        // 09-11), and letting just this row's slot grow would step its bar out of the
        // column that all four bars share. "100" is 20.5 and fits with room. Nothing is
        // lost: every other row in the column carries the sign, and the bar beside this
        // one is full. `>=` because the API hands us this figure unclamped.
        pctField.stringValue = pct >= 100 ? "\(pct)" : "\(pct)%"
        pctField.textColor = tint
        bar.configure(pct: pct)
        footField.stringValue = foot
    }
}

/// The subscription label beside an agent's name ("Max 20x" / "Plus"). A view and
/// not a bordered NSTextField: a text field draws its border at its own frame with
/// no way to inset the text, and at 8.5pt the label needs the 4pt of air more than
/// it needs the border.
private final class PlanChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let fill = CALayer()
    private var zeroWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        fill.cornerRadius = 4
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        label.font = .systemFont(ofSize: 8.5, weight: .medium)
        // Full label colour: at 8.5pt on a tinted chip the tertiary grey was the one
        // string in the header the user could not read.
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        zeroWidth = widthAnchor.constraint(equalToConstant: 0)
        // 999, not required: `zeroWidth` has to be able to win over them (a 0-wide
        // chip can't also hold 8pt of padding).
        let padL = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        let padR = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        for c in [padL, padR] { c.priority = .init(999) }
        NSLayoutConstraint.activate([
            padL, padR,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// nil = there is no plan to name (signed out, or a tier the reader didn't
    /// recognise). The chip then takes NO width — a hidden view still occupies its
    /// slot in Auto Layout, and an empty 8pt pill beside the name looks like a
    /// rendering fault, not like "unknown".
    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = text == nil
            zeroWidth.isActive = text == nil
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    private func resolveColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = Theme.barTrack.cg(in: self)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

/// Two MetricLines on one pane of glass. In `.grid` form a hairline separates them,
/// starting at the percentage column so it reads as a rule under the top row rather
/// than a cut across the card. In `.trio` form an identity row (name + plan) takes
/// that job instead and the card wears a 2pt brand edge along its top.
final class MetricCard: NSView {
    private let glow = CALayer()   // clay counter-lobe, behind bg
    private let bg = CALayer()
    private let divider = CALayer()
    private let accentEdge = CALayer()
    private let accent: NSColor?
    private let nameLabel = NSTextField(labelWithString: "")
    private let planChip = PlanChip()
    private let spinner = NSProgressIndicator()
    private var spinnerWidth: NSLayoutConstraint?
    private var spinnerGap: NSLayoutConstraint?
    let top: MetricLine
    let bottom: MetricLine

    /// A usage request for this card's account is in flight — the one a switch fires.
    /// ★ It answers a question the dimmed figures below can't: "is this number old, or
    /// is it old AND about to be replaced". Without it a switch looks like it did
    /// nothing for the second the request takes.
    ///
    /// Collapsed to zero width when off rather than merely hidden: a squeezed trio
    /// card is ~70pt wide, and 16pt held open for an invisible view comes straight
    /// out of the name beside it.
    var fetching = false {
        didSet {
            guard fetching != oldValue, let spinnerWidth, let spinnerGap else { return }
            spinnerWidth.constant = fetching ? 12 : 0
            spinnerGap.constant = fetching ? -4 : 0
            spinner.isHidden = !fetching
            if fetching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    /// Height is FIXED in trio form and that is the feature: hover redistributes
    /// width only, so the session list below never moves. 2 (brand edge) + 6 + 15
    /// (identity) + 2 + 17 + 17 + 7 = 66.
    static let trioHeight: CGFloat = 64
    /// Horizontal inset of a trio card's name row and both lines. 5, tuned by the
    /// user in design/header-account-quota-5-proposals.html round 8 (2026-09-11)
    /// together with a zero column gap: 10pt content-to-content across the seam.
    static let trioInset: CGFloat = 5

    /// Advertises with a pointing hand: the machine card opens Activity Monitor, an
    /// agent card opens its account panel. A card with nothing behind it stays inert
    /// rather than promising a panel that would come up empty.
    var clickable = false {
        didSet {
            guard clickable != oldValue else { return }   // written on every refresh tick
            window?.invalidateCursorRects(for: self)
            // Trio cards get their hover from QuotaTrio (one tracking area for the
            // whole strip, so the pointer crossing a gap doesn't flicker). A second
            // tracking area here would fight it.
            if clickable && accent == nil && trackingAreas.isEmpty {
                addTrackingArea(NSTrackingArea(rect: .zero,
                                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self))
            }
        }
    }
    private var hovering = false

    /// ★ Trio form drawn inside ONE shared shell rather than as three separate cards
    /// (2026-09-04, user's call): the strip paints the pane and its border, each card
    /// paints only its own contents, the hairline seam on its leading edge, and its
    /// hover block. Three panes 7pt apart read as three unrelated widgets; one pane
    /// with two hairlines reads as one instrument with three columns, which is what
    /// they are.
    var seamless = false {
        didSet {
            guard seamless != oldValue else { return }
            applyChrome(); needsLayout = true
        }
    }
    /// Every column but the first carries the seam that separates it from the one
    /// before. Drawn by the CARD, not the strip, so it travels with the card when a
    /// hover re-deals the widths — a seam painted on the strip would lag the animation.
    var showsLeadingSeam = false {
        didSet { seam.isHidden = !showsLeadingSeam; needsLayout = true }
    }
    private let seam = CALayer()
    /// Half the gap between two columns: the seam is drawn this far OUTSIDE the
    /// card's own leading edge, which puts it in the middle of the space between
    /// this column and the one before. The card's layer doesn't clip, so a negative
    /// x is fine — and drawing it here rather than on the strip is what keeps it
    /// glued to the column while a hover animates the widths.
    /// ★ 0 — the columns touch and the seam sits on the shared edge; the air on
    /// either side of it is the cards' own `trioInset`. History: 8 (32pt content to
    /// content) was "too much space" and 4 (24pt) still was (user, 2026-09-10); the
    /// user then dialled it to 0 with a 5pt inset in the round-8 preview
    /// (2026-09-11). The 2026-09-04 "shoved together" rejection was 0 gap with the
    /// seam flush against the CONTENT — no inset — which is not this.
    static let seamInset: CGFloat = 0
    /// Half the CURRENT gap, handed down by the strip — it collapses to zero when the
    /// strip is too narrow to afford the space between columns, and the seam has to
    /// come back to the edge with it.
    var seamOffset: CGFloat = seamInset {
        didSet { if seamOffset != oldValue { needsLayout = true } }
    }

    /// Set by QuotaTrio on the card the pointer is over (or the one whose panel is
    /// open) — the same chrome `hovering` gives the grid cards.
    var focused = false {
        didSet { if focused != oldValue { applyChrome() } }
    }

    override func resetCursorRects() {
        if clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyChrome() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyChrome() }

    /// `identity` non-nil switches the card to trio form. `accent` is both the name's
    /// color and the top edge's — one hue naming the card twice, which is what
    /// replaces the avatar circle the design started with.
    init(top: MetricLine, bottom: MetricLine, identity: String? = nil, accent: NSColor? = nil) {
        self.top = top
        self.bottom = bottom
        self.accent = identity == nil ? nil : (accent ?? .tertiaryLabelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        bg.cornerRadius = Theme.chip
        bg.cornerCurve = .continuous
        bg.borderWidth = 1
        layer?.addSublayer(glow)
        layer?.addSublayer(bg)
        layer?.addSublayer(divider)
        layer?.addSublayer(accentEdge)
        seam.isHidden = true
        layer?.addSublayer(seam)

        // Both lines are pinned to the SAME two edges, explicitly. This used to be a
        // vertical NSStackView with `alignment = .width`, which does not do what it
        // reads like: the lines kept their intrinsic widths instead of filling the
        // card, and the two ended up sitting at different x — the top row flush left,
        // the bottom row shoved right. Every column in a line is measured from the
        // line's own edges, so a line that doesn't span the card takes all four
        // gauges out of column with each other. Don't put a stack back here.
        addSubview(top)
        addSubview(bottom)

        guard let identity else {
            divider.isHidden = false
            NSLayoutConstraint.activate([
                top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                top.topAnchor.constraint(equalTo: topAnchor, constant: 4),

                bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                bottom.topAnchor.constraint(equalTo: top.bottomAnchor),
                bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
            applyChrome()
            return
        }

        divider.isHidden = true
        nameLabel.stringValue = identity
        nameLabel.font = Theme.rounded(10.5, .semibold)
        // The machine column has no brand hue; its NAME still reads in full label
        // colour, and only its top edge keeps the quiet grey the hue slot falls back to.
        nameLabel.textColor = accent ?? .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        // The name yields before the plan does: "Claude" clipped to "Clau…" still
        // says which card this is, whereas a clipped "Max 2…" says something false.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)
        addSubview(planChip)
        // Same mini spinner the account panel's refresh button uses — it is the same
        // request being waited on, and one instrument shouldn't grow two faces.
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.toolTip = L("正在向服务器查这个账号现在的额度",
                            "Asking the server for this account's current usage")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // Its intrinsic size must lose to the width constraint that collapses it.
        spinner.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(spinner)
        let sw = spinner.widthAnchor.constraint(equalToConstant: 0)
        let sg = spinner.trailingAnchor.constraint(equalTo: planChip.leadingAnchor, constant: 0)
        spinnerWidth = sw
        spinnerGap = sg
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.trioHeight),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trioInset),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.heightAnchor.constraint(equalToConstant: 15),

            // The spinner sits between the name and the plan chip, so the chain is
            // name → spinner → chip. Collapsed (width 0, gap 0) it folds out of that
            // chain exactly, leaving the original name→chip spacing behind.
            sw,
            sg,
            spinner.heightAnchor.constraint(equalToConstant: 12),
            spinner.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4),

            planChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trioInset),
            planChip.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trioInset),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trioInset),
            top.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trioInset),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trioInset),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor),
        ])
        applyChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// nil = don't draw the chip at all (see PlanChip.text).
    func setPlan(_ text: String?) { planChip.text = text }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if seamless {
            // A hover block inset from the shell, not a pane: run to the edges it
            // would paint over the strip's own border and its rounded corners.
            bg.frame = bounds.insetBy(dx: 3, dy: 3)
            bg.cornerRadius = 6
            seam.frame = CGRect(x: -seamOffset - 0.5, y: 10, width: 1,
                                height: max(0, bounds.height - 20))
        } else {
            layoutChipSurface(fill: bg, glow: glow, bounds: bounds, radius: Theme.chip)
        }
        // Starts at the percentage column, runs out to the card's edge.
        let inset = 10 + MetricLine.Style.grid.iconW + MetricLine.Style.grid.gap
        divider.frame = CGRect(x: inset, y: bounds.height / 2 - 0.5,
                               width: max(0, bounds.width - inset), height: 1)
        // Inset by half the corner radius so the edge stops before the curve starts
        // — run full width it pokes out of the rounded corners as two square ears.
        // Seamless has no corners of its own; there the edge lines up with the
        // content instead, which is what makes the three read as one row of columns.
        let r = seamless ? 16 : min(Theme.chip, bounds.width / 2)
        accentEdge.frame = CGRect(x: r / 2, y: bounds.height - 2,
                                  width: max(0, bounds.width - r), height: 2)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    private func applyChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if seamless {
            glow.shadowOpacity = 0
            bg.shadowOpacity = 0
            bg.borderWidth = 0
            bg.backgroundColor = (hovering || focused) ? Theme.cardFillHover.cg(in: self) : nil
            seam.backgroundColor = Theme.hairline.cg(in: self)
        } else {
            styleChipSurface(fill: bg, glow: glow, in: self)
        }
        divider.backgroundColor = Theme.hairline.cg(in: self)
        if let accent {
            accentEdge.backgroundColor = accent.cg(in: self)
            accentEdge.cornerRadius = 1
        } else {
            accentEdge.isHidden = true
        }
        if !seamless, hovering || focused {
            bg.backgroundColor = Theme.cardFillHover.cg(in: self)
            bg.borderColor = (accent ?? Status.usageGreen).withAlphaComponent(0.45).cg(in: self)
        }
        CATransaction.commit()
    }
}

// MARK: - GlassCard
//
// One reusable pane of frosted glass: an adaptive low-alpha fill and a border.
// The border wears the status accent whenever the session is in an active state
// (working/needs/checking/done) and stays a neutral hairline for idle — so state
// reads from the ring alone. On hover it brightens, the ring intensifies, and
// (optionally) it casts a soft same-color glow. Rows, the folder header, and
// child rows all host one, so the whole list reads as a single material. Colors
// are resolved under the view's own appearance and re-resolved on light/dark
// switches.

final class GlassCard: NSView {
    private var status = "idle"
    private var accent = Status.accent("idle")
    private var hovering = false
    private let glows: Bool
    private let radius: CGFloat

    // Clay's two extra lobes. A CALayer carries exactly ONE shadow, so the
    // upper-left counter-glow needs its own layer beneath the card; `rim` is the
    // 1pt top-edge light (dark clay leans on it in place of that counter-glow).
    // Both stay invisible under a `.hairline` theme.
    //
    // The glow layer carries the card's OWN FILL: a shadow is drawn across the whole
    // blurred path, interior included, and is hidden only by its layer's own opaque
    // content. A transparent glow layer would therefore wash its counter-glow across
    // the card's face instead of only escaping past its upper-left edge.
    private let counterGlow = CALayer()
    private let rim = CALayer()

    init(radius: CGFloat = Theme.card, glows: Bool = true) {
        self.glows = glows
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        // Below index 0 = behind every subview the caller adds (and behind the
        // card's own fill, which the backing layer paints).
        counterGlow.cornerRadius = radius
        counterGlow.cornerCurve = .continuous
        layer?.insertSublayer(counterGlow, at: 0)
        layer?.insertSublayer(rim, at: 1)

        apply(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Geometry only — never animate a resize.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        counterGlow.frame = bounds
        // Sublayers live in the layer's y-UP space, so the rim sits at maxY = the
        // on-screen top. Inset past the corners so it doesn't cut across them.
        rim.frame = CGRect(x: radius, y: bounds.height - 1,
                           width: max(0, bounds.width - 2 * radius), height: 1)
        // Pre-rendered shadow outline: CoreAnimation must never derive a shadow from
        // layer alpha in a list that reloads every second.
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        layer?.shadowPath = path
        counterGlow.shadowPath = path
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    func setAccent(_ status: String) {
        self.status = status
        accent = Status.accent(status)
        apply(animated: false)
    }

    func setHover(_ on: Bool, animated: Bool = true) {
        hovering = on
        apply(animated: animated)
    }

    private func apply(animated: Bool) {
        let fill   = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        // Active statuses wear their accent as a resting ring so state reads at a
        // glance; idle/seen keep the neutral hairline ("has a ring = has news").
        // Light mode needs a higher alpha — the accents wash out over the bright
        // frosted fill that dark mode's glass doesn't have.
        let border: CGColor
        switch status {
        case "needs", "working", "checking", "paused", "done", "await":
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            border = accent.withAlphaComponent(hovering ? 0.80 : (dark ? 0.40 : 0.55)).cgColor
        default:
            border = (hovering ? Theme.hairlineHover : Theme.hairline).cg(in: self)
        }
        // A light-bounded theme replaces the stroke AND the accent hover glow with its
        // own lighting — two shadows can't share the backing layer, and on a warm
        // opaque surface a colored bloom fights the material. (No shipped call site
        // gives a GlassCard an accent anyway: rows are GroupCards.)
        let lighting = Theme.shadow(in: self).map { hovering ? $0.raised : $0 }
        let work = {
            self.layer?.backgroundColor = fill
            if let lighting {
                self.layer?.borderWidth = 0
                self.layer?.applyShadowLobe(lighting.drop)
                self.counterGlow.backgroundColor = fill   // see the property's note
                if let glow = lighting.counterGlow { self.counterGlow.applyShadowLobe(glow) }
                else { self.counterGlow.shadowOpacity = 0 }
                self.rim.isHidden = lighting.rimHighlight == nil
                self.rim.backgroundColor = lighting.rimHighlight?.cgColor
                return
            }
            self.layer?.borderWidth = 1
            self.layer?.borderColor = border
            self.rim.isHidden = true
            self.counterGlow.shadowOpacity = 0
            self.counterGlow.backgroundColor = nil
            if self.glows {
                self.layer?.shadowColor = self.accent.cgColor
                self.layer?.shadowOpacity = self.hovering ? 0.35 : 0
                self.layer?.shadowRadius = 10
                self.layer?.shadowOffset = .zero
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; work() }
        } else {
            // Color changes shouldn't cross-fade on first layout / appearance flip.
            CATransaction.begin(); CATransaction.setDisableActions(true); work(); CATransaction.commit()
        }
    }
}

// MARK: - GroupCard (slice of a project enclosure)
//
// The grouped list renders each project as ONE rounded glass container: a header
// band on top, its session rows stacked flush beneath, no gaps inside — gaps live
// only between projects. But the list is an NSTableView of independent cells, so
// there's no single view to draw the enclosure. Instead every cell hosts a
// GroupCard that paints its own *slice* of the container:
//
//   solo    the whole box (a collapsed header, or a lone row)   ▢ all corners
//   top     the header band                                     ⬒ round top only
//   middle  an interior session                                 ▯ no rounding
//   bottom  the last session                                    ⬓ round bottom only
//
// Because header and child cells share the same horizontal inset, the per-slice
// left/right border segments line up into one continuous vertical edge, and the
// rounded top/bottom corners bookend it — the seam is invisible, the box reads as
// a single enclosure. State is NOT carried by the border (a neutral hairline);
// it's the header's status band + each child's rail + dot that speak color.
//
// Every layer write is wrapped in setDisableActions: these are bare sublayers, and
// with reloadData() recycling cells across rows a stale implicit crossfade is the
// classic "row flashes a stale color for a frame" bug. Snap; hover is the only
// explicit animation.

enum SliceRole { case solo, top, middle, bottom }

// How a slice reacts to hover:
//  • card  — floats out as an independent rounded card: ALL corners round, a shadow on
//            every side, and a slight scale-up. Used by a hovered child row (方案 C).
//            Overrides the role's sliced corners for the duration of the hover.
//            (A collapsed solo header takes .group instead — it IS its whole group,
//            so it lifts with the H1 treatment, not the child row's card float.)
//  • group — one member of a whole-group lift: hovering an expanded header raises the
//            header AND all its rows together (方案 H1). Every slice scales about the
//            GROUP's shared center (one affine map → seams stay flush), only the header
//            band brightens/deepens (rows keep their resting fill, mirroring the H1
//            mock), and each slice casts an OUTER-edge-only, downward-offset shadow so
//            the union reads as one card shedding below — not a dark ring.
//  • none  — resting.
enum HoverLift { case none, card, group }

final class GroupCard: NSView {
    // The selection halo (design/selected-row-glow-5-proposals.html 方案 2). It needs a
    // layer of its own because a layer carries exactly ONE shadow and both of the
    // others are already spoken for: the backing layer wears the hover lift's drop (or
    // clay's), and `glow` wears clay's counter-glow.
    private let selGlow = CALayer()
    // ★ And it needs a mask (改这块前必读). A CALayer's shadow is a solid blurred
    // silhouette of its shadowPath — solid INSIDE the path too, not just around it.
    // `glow` gets away with that because clay's surfaces are opaque and cover it; the
    // default theme's cardFill is white at 0.06, so an unmasked halo shows straight
    // through and floods the whole row in its status color. This mask is an even-odd
    // "everything except the row itself", so only the light that escapes survives. The
    // interior tint is the fill's job instead (see `fillColor`).
    private let selGlowMask = CAShapeLayer()
    private let glow = CALayer()          // clay counter-glow (a layer carries ONE shadow)
    private let fill = CALayer()          // adaptive frosted fill, corners masked per role
    private let band = CAGradientLayer()  // header status wash (active header only)
    private let rim = CALayer()           // clay 1pt top-edge light (top / solo slice only)
    private let border = CAShapeLayer()   // the slice's outline segments
    private let divider = CAShapeLayer()  // internal hairline (under header / above a child)

    // ★ The hover lift scales THESE, never the view's own backing layer (改这块前必读).
    // The backing layer carries the cell's label subviews, and scaling it made the GPU
    // up-sample their already-rasterized text bitmaps. On a Retina screen the pixel
    // density hides the damage; on a 1× display (a non-Retina external monitor, e.g.
    // 3440×1440) it reads as 虚化 — macOS glyph rendering is aligned to the whole-pixel
    // grid, and ANY non-integral bitmap scale breaks that alignment. Supersampling the
    // backing store only softens the aliasing, it cannot restore the alignment.
    // → The box grows; the text stays put and therefore stays pixel-crisp at every scale.
    // Order is paint order: the counter-glow lives BEHIND the fill (it is only ever
    // seen where it escapes the slice), the rim light sits on top of the wash.
    // selGlow leads: its halo is cast OUTSIDE the slice, so it must sit under
    // everything the slice paints or the fill would clip the light it sheds inward.
    private var decorationLayers: [CALayer] { [selGlow, glow, fill, band, rim, border, divider] }

    private var role: SliceRole = .solo
    private var isBand = false            // this slice is a header band
    private var topDivider = false        // draw the internal hairline at the top edge
    // 方案 16: this slice is an agent-sublist segment of its session row's card (iris
    // fill), and `seamTop` marks the first one — the only node that draws the iris seam.
    private var nested = false
    private var seamTop = false
    private var status = "idle"
    private var lift: HoverLift = .none
    // ★ Selection is NOT a lift (改这块前必读). The pin (focused terminal / arrow-key
    // nav) and the pointer hover used to share one channel, so pointing anywhere in the
    // list stole the selected row's highlight and gave it a hover's look. The halo is
    // therefore its own axis: a selected row keeps it while the pointer roams, and a
    // merely hovered row never gets one — that separation is the whole point of the
    // feature, so do not fold this back into HoverLift.
    private var selected = false
    // The group's shared center in THIS slice's coordinate space, set alongside a
    // .group lift — the anchor every slice scales about so the union grows as one card.
    private var groupCenter: NSPoint?
    // Where this slice sits in the LIFTED group, which is not always where it sits in
    // the enclosure: an expanded session row and its agent segment lift out of the
    // MIDDLE of the project card (方案 16), and a shadow cast for the enclosure's roles
    // would inset both of the cluster's own edges away — a lift with no shadow at all.
    // nil ⇒ the group IS the whole enclosure (a header's group), so `role` already fits.
    private var groupRole: SliceRole?

    private let radius: CGFloat
    // Card-lift shadow: the mock C row float's `0 6px 22px` — wide and soft, matching
    // the group lift's shadow family (a tight high-opacity shadow reads as a dark ring).
    private let cardShadowBlur: CGFloat = 22
    // Group-lift shadow, per role (blur, downward offset, opacity scale). Mirrors the
    // H1 mock's single `0 12px 34px` under-shadow: strongest below the group (bottom /
    // solo slice, offset down), soft on the sides (middle), faint above (top) — an even
    // no-offset glow reads as a dark ring instead. liftShadowPath() insets seam-facing
    // edges past each slice's blur reach so nothing bleeds across a seam.
    private var groupShadowParams: (blur: CGFloat, down: CGFloat, opacity: Float) {
        switch shadowRole {
        case .solo, .bottom: return (22, 7, 1.0)
        case .top:           return (18, 0, 0.65)
        case .middle:        return (12, 0, 0.65)
        }
    }

    init(radius: CGFloat = Theme.group) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true

        fill.cornerCurve = .continuous
        fill.masksToBounds = true
        band.cornerCurve = .continuous
        band.masksToBounds = true
        band.startPoint = CGPoint(x: 0.5, y: 1.0)   // top (layer y-up)
        band.endPoint   = CGPoint(x: 0.5, y: 0.0)
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1
        divider.lineWidth = 1

        // anchorPoint (0,0) matches the AppKit backing-layer convention the lift
        // transforms are written against (translate-to-center → scale → translate back),
        // so decorationLayers can wear the very same CATransform3D the backing layer
        // used to. A bare CALayer would otherwise default to a centered anchor and
        // double-apply that centering.
        decorationLayers.forEach { $0.anchorPoint = .zero; layer?.addSublayer($0) }
        selGlowMask.anchorPoint = .zero
        selGlowMask.fillRule = .evenOdd
        selGlow.mask = selGlowMask
        // The backing layer casts the hover-lift shadow (shadowPath-driven, so the bare
        // sublayers' own frames don't matter). masksToBounds stays false so it isn't clipped.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
        apply(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Frames + geometry-dependent paths don't animate on resize/appearance.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds; band.frame = bounds
        border.frame = bounds; divider.frame = bounds
        glow.frame = bounds; selGlow.frame = bounds
        fill.cornerRadius = radius
        band.cornerRadius = radius
        glow.cornerRadius = radius
        // y-up: maxY is the on-screen TOP. Inset past the corners so the rim light
        // doesn't cut across them.
        rim.frame = CGRect(x: radius, y: bounds.height - 1,
                           width: max(0, bounds.width - 2 * radius), height: 1)
        // Both outlines MUST be rebuilt here, not only in apply(): a recycled cell
        // configures (and so applies) while its bounds are still zero, which yields a
        // degenerate path, and nothing else would ever replace it — that is the
        // "between-rows line sometimes missing" bug.
        border.path = slicePath()
        divider.path = dividerPath()
        refreshShadowGeometry()
        // Geometry-dependent lift attributes (centered scale) track a resize while a
        // hover is held.
        if lift != .none {
            decorationLayers.forEach { $0.transform = liftTransform }
        }
        CATransaction.commit()
    }

    /// Shadow outlines, for whichever kind of shadow this theme casts. Both are
    /// pre-rendered paths — this list reloads once a second, so CoreAnimation must
    /// never be left to derive a shadow from layer alpha.
    private func refreshShadowGeometry() {
        // The selection halo is orthogonal to both of the others: it is cast whether or
        // not the row is lifted and whatever the theme's lighting, so it is set first
        // and unconditionally rather than inside either branch below.
        let halo = selected ? selectionGlowPath() : nil
        selGlow.shadowPath = halo
        // ★ The mask's own frame is the OUTSET box, not `bounds` (改这块前必读). A mask
        // only masks what it actually renders, and whether a layer renders outside its
        // own bounds while serving as one is not a contract worth betting the whole
        // effect on — get it wrong and the halo is clipped to the row, where the
        // even-odd hole has already removed all of it. So the mask is made big enough
        // to hold the blur (13pt) plus the lift's displacement, and the paths are
        // shifted into its coordinate space instead.
        let outset: CGFloat = 40
        selGlowMask.frame = bounds.insetBy(dx: -outset, dy: -outset)
        selGlowMask.path = halo.map { inner in
            let shift = CGAffineTransform(translationX: outset, y: outset)
            let p = CGMutablePath()
            p.addRect(CGRect(origin: .zero, size: selGlowMask.frame.size))
            p.addPath(inner, transform: shift)
            return p
        }
        if let lighting = currentLighting {
            layer?.shadowPath = castsDrop ? clayShadowPath(lighting.drop) : nil
            glow.shadowPath = castsGlow ? lighting.counterGlow.flatMap { clayShadowPath($0) } : nil
        } else if lift != .none {
            layer?.shadowPath = liftShadowPath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    /// Which corners this slice rounds. These bare sublayers live in the layer's
    /// y-UP space (same as slicePath): maxY = on-screen top, minY = on-screen
    /// bottom. Mapping them the other way rounds the WRONG end — the .top slice's
    /// fill keeps square on-screen-top corners and leaks past the rounded border
    /// (the expanded-header 白角 bug).
    private var maskedCorners: CACornerMask {
        // A card-lift slice floats free of the enclosure → round all four corners
        // regardless of its role's normal sliced corners. A SELECTED slice does the
        // same without lifting: its halo needs a closed outline to ring, and a slice
        // whose sides are haloed but whose top and bottom run into its neighbours
        // reads as a leak rather than as a selection. Shape, outline and halo path all
        // key off this same pair of conditions — they must not drift apart.
        if lift == .card || selected {
            return [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        switch role {
        case .solo:   return [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                              .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top:    return [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // on-screen top
        case .bottom: return [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // on-screen bottom
        case .middle: return []
        }
    }

    // The border outline for this slice, in the view's y-UP layer space. A stroke
    // is centered on its path, so inset by half the line width to keep the whole
    // 1px inside the bounds (and aligned with the neighbouring slice's segments).
    private func slicePath() -> CGPath {
        let i: CGFloat = 0.5
        let x0 = i, x1 = bounds.width - i
        let y0 = i, y1 = bounds.height - i    // y1 = on-screen TOP (y-up)
        let p = CGMutablePath()
        // Bounds is .zero at init (frame == .zero) and can be degenerate mid-layout;
        // a negative-size rounded rect trips a CoreGraphics assertion (SIGABRT crash
        // on launch). Skip until layout() re-runs slicePath() with real bounds.
        guard x1 > x0, y1 > y0 else { return p }
        // Corner radius can't exceed half of either side, else CGPathAddRoundedRect asserts.
        let r = min(radius, (x1 - x0) / 2, (y1 - y0) / 2)
        // Card-lift under a light-bounded theme: a full outline reads as a drawn box
        // on a material that is meant to be shaped by light, so only the TOP edge is
        // kept — and only because it is genuinely missing: the row has detached from
        // the enclosure so it no longer shares a seam upward, and no shadow covers
        // for it either (the drop travels down-right, and the counter-glow is white
        // on a near-white card up there). Below and to the sides the drop already
        // separates it, so those stay unstroked.
        // A selected slice keeps its full accent ring in every theme (see `hair`), so
        // it skips both the light-bounded top-edge-only outline and the sliced roles.
        if selected {
            p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                             cornerWidth: r, cornerHeight: r)
            return p
        }
        if lift == .card, lightBounded {
            p.move(to: CGPoint(x: x0, y: y1 - r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: y1), control: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x1 - r, y: y1))
            p.addQuadCurve(to: CGPoint(x: x1, y: y1 - r), control: CGPoint(x: x1, y: y1))
            return p
        }
        // A header band never strokes its TOP edge (nor the corners leading into it):
        // the status wash already draws where the project starts, and a hairline over
        // it reads as a stray bright line above every header. The sides stop short of
        // the corner radius so no curve is left dangling. The bottom closes only when
        // the header IS the whole box — collapsed (.solo) or floated by a card lift;
        // an expanded header (.top) continues into its rows.
        if isBand {
            let closedBottom = lift == .card || role == .solo
            p.move(to: CGPoint(x: x0, y: y1 - r))
            p.addLine(to: CGPoint(x: x0, y: closedBottom ? y0 + r : y0))
            if closedBottom {
                p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
                p.addLine(to: CGPoint(x: x1 - r, y: y0))
                p.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
            } else {
                p.move(to: CGPoint(x: x1, y: y0))
            }
            p.addLine(to: CGPoint(x: x1, y: y1 - r))
            return p
        }
        // Card-lift: closed rounded rect on all four corners (floating card), whatever
        // the slice's role.
        if lift == .card {
            p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                             cornerWidth: r, cornerHeight: r)
            return p
        }
        switch role {
        case .solo:
            p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                             cornerWidth: r, cornerHeight: r)
        case .top:
            // ⬒ left up → round top-left → top edge → round top-right → right down.
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x0, y: y1 - r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: y1), control: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x1 - r, y: y1))
            p.addQuadCurve(to: CGPoint(x: x1, y: y1 - r), control: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x1, y: y0))
        case .middle:
            // ▯ two bare side edges.
            p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x0, y: y1))
            p.move(to: CGPoint(x: x1, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1))
        case .bottom:
            // ⬓ left down → round bottom-left → bottom edge → round bottom-right → right up.
            p.move(to: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x0, y: y0 + r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1 - r, y: y0))
            p.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y1))
        }
        return p
    }

    // The internal hairline: for a header band it sits at the BOTTOM edge (the line
    // under the header); for a child it sits at the TOP edge (between rows). Empty
    // unless enabled for this slice.
    private func dividerPath() -> CGPath {
        let p = CGMutablePath()
        // A floated card stands alone — no between-rows / under-header hairline. So
        // does a selected slice, for the same reason it rounds all four corners: the
        // hairline would run straight through its accent ring.
        if lift == .card || selected { return p }
        let x0: CGFloat = 0.5, x1 = bounds.width - 0.5
        if isBand, role == .top {                 // under-header line (solo has no rows below)
            p.move(to: CGPoint(x: x0, y: 0.5)); p.addLine(to: CGPoint(x: x1, y: 0.5))
        } else if !isBand, topDivider {            // between-rows line at the top edge
            p.move(to: CGPoint(x: x0, y: bounds.height - 0.5))
            p.addLine(to: CGPoint(x: x1, y: bounds.height - 0.5))
        }
        return p
    }

    /// `isHeaderBand`: this is the header slice (draws the status wash + under-line).
    /// `topDivider`: draw the between-rows hairline (a child that isn't the first).
    /// `nested`: an agent-sublist segment — iris-tinted fill (方案 16).
    /// `seamTop`: ...and the first one, so its top hairline is the iris seam.
    func configure(role: SliceRole, isHeaderBand: Bool, topDivider: Bool,
                   nested: Bool = false, seamTop: Bool = false) {
        self.role = role
        self.isBand = isHeaderBand
        self.topDivider = topDivider
        self.nested = nested
        self.seamTop = seamTop
        // The halo resets with the cell's identity: this card may have just been
        // recycled onto a different session, and one carried over would light the wrong
        // row. Assigned directly rather than through setSelected — the apply() below
        // already covers it. The table re-asserts the pin immediately after a reload
        // (hoverDidReload → applyPin), so the row that IS selected lights again in the
        // same runloop, with no flash in between.
        self.selected = false
        needsLayout = true       // paths depend on role
        apply(animated: false)
    }

    func setAccent(_ status: String) {
        self.status = status
        apply(animated: false)
    }

    /// `groupCenter`: for a .group lift, the group's shared center converted into this
    /// slice's coordinate space (the scale anchor). Ignored for other lifts.
    /// `groupRole`: this slice's place in that group — see the `groupRole` property.
    /// Light (or clear) this slice's selection halo. Independent of `setHover` on
    /// purpose — see the `selected` field.
    func setSelected(_ on: Bool, animated: Bool = true) {
        guard on != selected else { return }
        selected = on
        apply(animated: animated)
    }

    /// The halo's outline: always the closed rounded box, matching what `maskedCorners`
    /// and `slicePath()` switch to while selected.
    private func selectionGlowPath() -> CGPath? {
        // Bounds is .zero at init and degenerate mid-layout; a negative-size rounded
        // rect trips the same CoreGraphics assertion slicePath() guards against.
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // ★ NOT baked with liftTransform, unlike liftShadowPath() (改这块前必读).
        // That one rides the backing layer, which deliberately does not wear the lift;
        // selGlow is a decorationLayer and DOES (they all get it in apply()), so baking
        // it here too would scale the halo twice and slide it off its own row.
        let r = min(radius, bounds.width / 2, bounds.height / 2)
        return CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    func setHover(_ lift: HoverLift, groupCenter: NSPoint? = nil,
                  groupRole: SliceRole? = nil, animated: Bool = true) {
        // A held group can change shape under the pointer (an agent node appears, a row
        // reorders), which moves the anchor and the group's edges without the lift
        // itself changing — so that case has to re-apply too, or the slice keeps
        // scaling about a stale center.
        let reshaped = lift == .group
            && (groupCenter != self.groupCenter || groupRole != self.groupRole)
        if lift == .group {
            self.groupCenter = groupCenter
            self.groupRole = groupRole
        }
        guard lift != self.lift || reshaped else { return }
        self.lift = lift
        // apply() rewrites every lift-dependent attribute itself; do NOT request layout
        // here — a layout pass mid-hover would snap the scale transform to its end value
        // (disableActions) and kill the lift animation.
        apply(animated: animated)
        // Re-boost contentsScale at the moment the scale transform kicks in. configure()
        // boosts too, but AppKit resets contentsScale to the plain backing scale on any
        // backing/layout pass between configure and hover (notably when a popover first
        // shows its content) — leaving the magnified text upsampled (虚化). Re-applying
        // here guarantees the boost is live whenever the lift is; idempotent at rest.
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // Scale-up about the slice's own center. The backing layer's anchorPoint is (0,0)
    // in AppKit, so a bare CATransform3DScale would grow from the bottom-left corner —
    // translate to center, scale, translate back.
    private var cardScaleTransform: CATransform3D {
        let s: CGFloat = 1.018
        let w = bounds.width, h = bounds.height
        var t = CATransform3DMakeTranslation(w / 2, h / 2, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -w / 2, -h / 2, 0)
    }

    // Whole-group scale (方案 H1): every slice scales about the GROUP's shared center,
    // not its own — one affine map for all slices, so the union grows as a single card
    // and the seams between slices stay perfectly flush.
    private var groupScaleTransform: CATransform3D {
        guard let c = groupCenter else { return CATransform3DIdentity }
        // 1.012 was invisible on the popover's narrow cards — a 264pt card grew 1.6pt per
        // side, and arrow-key nav (which can only land on headers, so it ONLY ever gets
        // this lift) read as "nothing happened". Bounded above by cardCellInset: the card
        // has 18pt of cell margin to grow into before the scroll clip starts slicing the
        // lift shadow flat (see docs/design-system.md).
        let s: CGFloat = 1.03
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }

    private var liftTransform: CATransform3D {
        switch lift {
        case .card:  return cardScaleTransform
        case .group: return groupScaleTransform
        case .none:  return CATransform3DIdentity
        }
    }

    /// The role every shadow is cast for: the LIFTED group's geometry while a .group
    /// lift is held (an agent cluster's edges are not the enclosure's), the enclosure's
    /// otherwise. Only the shadows follow it — corners, dividers and the rim light
    /// still belong to the slice's real place in the card.
    private var shadowRole: SliceRole { (lift == .group ? groupRole : nil) ?? role }

    // The shadow outline. A card-lift casts on all four sides. A group-lift member insets
    // the edges that face INTO the group (y-up: top slice's on-screen bottom = minY,
    // bottom slice's on-screen top = maxY) by more than the blur radius, so the shadow
    // only escapes the group's OUTER edges — no dark line bleeds across a slice seam.
    private func liftShadowPath() -> CGPath? {
        // The shadow rides the backing layer, which no longer wears the lift transform —
        // so bake that transform into the path instead. Matters most for a group lift,
        // where a slice far from the group's center is displaced by a visible amount and
        // an untransformed shadow would visibly lag behind its own box.
        var m = CATransform3DGetAffineTransform(liftTransform)
        switch lift {
        case .none:
            return nil
        case .card:
            return CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: &m)
        case .group:
            let p = groupShadowParams
            // Seam-facing inset = blur reach + how far the downward offset pushes the
            // blur toward that seam + margin. The seam BELOW a slice (y-up: its minY)
            // receives the offset; the seam ABOVE (maxY) moves away from it.
            let below = p.blur + p.down + 3
            let above = p.blur - p.down + 3
            var r = bounds
            switch shadowRole {
            case .solo:   break                                                    // all sides (lone box)
            case .top:    r.origin.y += below; r.size.height -= below              // shed up + sides, not down
            case .bottom: r.size.height -= above                                   // shed down + sides, not up
            case .middle: r.origin.y += below; r.size.height -= below + above      // sides only
            }
            guard r.height > 0 else { return nil }
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: &m)
        }
    }

    /// This theme's lighting for the slice's current state, or nil when the theme
    /// bounds surfaces with a stroke instead (then the backing shadow is the hover
    /// lift's, exactly as before). Clay wears its shadow AT REST and expresses the
    /// lift by deepening it — that is the material's own vocabulary for "raised".
    private var currentLighting: ShadowSpec? {
        Theme.shadow(in: self).map { lift != .none ? $0.raised : $0 }
    }

    /// Does this theme bound its surfaces with light rather than a stroke?
    private var lightBounded: Bool { Theme.shadow(in: self) != nil }

    // ── Which slice casts which lobe (改这块前必读) ────────────────────────────
    //
    // A lobe is cast ONLY by the slice that owns the outer edge that lobe travels
    // toward: the drop goes down-right, so the bottom slice casts it; the
    // counter-glow goes up-left, so the top slice does; a solo box casts both; an
    // interior slice casts NOTHING.
    //
    // The obvious alternative — every slice casting and insetting its seams so it
    // doesn't light its neighbour — is what produced the "shadow squares beside the
    // list" bug: each slice's side band starts and stops at its own seam insets, so
    // the enclosure's left and right edges read as a column of separate blocks
    // instead of one slab. Only the end slices casting keeps the group reading as a
    // single object lit from the upper left. A card-lifted slice is exempt: it has
    // floated out of the enclosure and owns all four of its edges.
    private var castsDrop: Bool { lift == .card || shadowRole == .bottom || shadowRole == .solo }
    private var castsGlow: Bool { lift == .card || shadowRole == .top || shadowRole == .solo }

    /// One lobe's outline. Even an end slice must not shed light back INTO the
    /// enclosure, so its seam-facing edge is pulled past the distance this lobe
    /// actually spills that way (a 6pt-down drop with 7pt blur travels 13pt down but
    /// only 1pt up; the counter-glow the reverse).
    private func clayShadowPath(_ lobe: ShadowLobe) -> CGPath? {
        var m = CATransform3DGetAffineTransform(liftTransform)
        // A card-lift floats free of the enclosure → it sheds on all four sides.
        if lift == .card {
            return CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                          transform: &m)
        }
        var r = bounds
        let sr = shadowRole
        if sr == .top || sr == .middle {            // neighbour below (y-up: minY)
            let d = lobe.spillDown + 1
            r.origin.y += d; r.size.height -= d
        }
        if sr == .bottom || sr == .middle {         // neighbour above (maxY)
            r.size.height -= lobe.spillUp + 1
        }
        guard r.width > 0, r.height > 0 else { return nil }
        let rr = min(radius, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: &m)
    }

    private func apply(animated: Bool) {
        // A card-lift floats out on its own → OPAQUE fill so its rounded corners don't
        // see through to the darker baseFill behind (四角漏底). A group-lift stays glass
        // (its corners live on the group's outer edge, over real background already),
        // and only the HEADER slice brightens — rows keep their resting fill (H1: the
        // lift reads from scale + shadow + header band, not from every row lighting up).
        // The resting fill — iris-tinted for an agent segment (方案 16), so the sublist
        // reads as a distinct band of the SAME card instead of a few shorter rows.
        let rest = nested ? Theme.agentSegmentFill : Theme.cardFill
        // The OPAQUE fill a slice takes once it is drawn as a closed rounded box.
        let float = nested
            ? Theme.agentSegmentFill.themeShifted(like: Theme.cardFill, to: Theme.cardFloat)
            : Theme.cardFloat
        let fillBase: NSColor
        switch lift {
        // An agent segment floats as ITSELF: `cardFloat` is the neutral card tone and
        // would wash the sublist's iris away exactly when you point at it, which reads
        // as the row changing identity rather than lifting. So it takes the STEP from
        // fill to float instead of the float's own value — in dark mode the segment is
        // already lighter than `cardFloat`, and moving toward it would darken the row
        // on hover. (Opaque either way, so the floated corners can't see through.)
        case .card:  fillBase = float
        // The group's HEAD brightens, the rest keep their resting fill (H1: the lift
        // reads from scale + shadow, not from every row lighting up). For a header's
        // group that head is the band; for an agent cluster it is the session row you
        // are actually pointing at, which would otherwise be the one slice in the list
        // that answers a hover with no change of its own.
        case .group: fillBase = isBand || groupRole == .top ? Theme.cardFillHover : rest
        case .none:  fillBase = rest
        }
        // A selected row takes a little of its status color into its face, so the halo
        // reads as the row being lit rather than as a light parked behind it. The mock
        // tints the RESTING glass 7% (方案 2 `color-mix(... 7%)`), not the float: mixed
        // into `float` at 12% the row came out as a bright pastel slab, a shade darker
        // and brighter than every neighbour (2026-09-04 用户截图). The resting fill is
        // translucent, though, and selection rounds all four corners whether or not
        // the row is lifted (maskedCorners) — a translucent fill behind those new
        // corners sees straight through to the darker baseFill, exactly the 四角漏底
        // the card lift spends an opaque fill to avoid. So the tint is laid over the
        // resting fill FLATTENED onto baseFill: the same tone the row has at rest, opaque.
        let fillColor = (selected ? Status.accent(status).themeBlended(0.07, into: rest.themeOver(Theme.baseFill))
                                  : fillBase).cg(in: self)
        // Only the opaque card-float darkens its edge (it needs definition); a group-lift
        // keeps the resting hairline so the enclosure edge doesn't read as a dark ring.
        // A selected row's edge is the halo's inner lip — the 1pt accent line that the
        // mock's `0 0 0 1px` draws. It overrides a light-bounded theme's "no stroke"
        // rule (clay): selection has to be legible as a state, and light alone cannot
        // say "this one" when every neighbour is lit by the same material.
        let hair = selected
            ? Status.accent(status).withAlphaComponent(isDark ? 0.62 : 0.55).cg(in: self)
            : (lift == .card ? Theme.hairlineHover : Theme.hairline).cg(in: self)
        // The segment's opening hairline is the iris seam; every other one stays neutral.
        let div = (seamTop ? Theme.agentSeam : Theme.divider).cg(in: self)

        // Every header wears its status wash — active projects in their saturated
        // accent, an all-idle project in the neutral cool gray (Status.accent("idle")),
        // so a fully-idle folder still reads as "idle" at a glance rather than blank.
        // Gray is desaturated, so at the same alpha it stays quiet next to the red/
        // blue/green active bands. Non-header slices clear the band entirely.
        let bandColors: [CGColor]
        if isBand {
            // The wash deepens while the header is lifted (.group for an expanded
            // header's whole-group lift, .card for a hovered collapsed solo header).
            let a = Theme.bandAlphas(dark: isDark, hovered: lift != .none)
            let accent = Status.accent(status)
            bandColors = [accent.withAlphaComponent(a.top).cgColor,
                          accent.withAlphaComponent(a.bottom).cgColor]
        } else {
            bandColors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        }

        let lighting = currentLighting

        // Corners / paths / shadow outline SNAP (no crossfade) — morphing a sliced
        // outline into a full rounded rect would look like the border crawling.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.maskedCorners = maskedCorners
        band.maskedCorners = maskedCorners
        glow.maskedCorners = maskedCorners
        border.path = slicePath()
        divider.path = dividerPath()
        // The halo's outline and mask are geometry, so they snap here whatever the
        // theme — the branches below only cover the lift's / clay's own shadows.
        refreshShadowGeometry()
        if lighting == nil, lift != .none {
            // Keep the last outline / offset / radius while fading OUT (lift == .none)
            // so the shadow dissolves with its real shape instead of snapping.
            layer?.shadowPath = liftShadowPath()
            // Both lifts cast a downward drop shadow (y-up: negative height = down);
            // the group's per-role params concentrate it under the group (H1).
            layer?.shadowOffset = lift == .card ? CGSize(width: 0, height: -6)
                                                : CGSize(width: 0, height: -groupShadowParams.down)
            layer?.shadowRadius = lift == .card ? cardShadowBlur : groupShadowParams.blur
        }
        CATransaction.commit()

        let work = {
            self.fill.backgroundColor = fillColor
            self.band.colors = bandColors
            // Light bounds a clay surface — the outline stroke would read as a drawn
            // edge on top of a lit one. The INTERNAL hairlines stay: the design keeps
            // its `--border` line between rows so the slab reads as sliced.
            //
            // A FLOATED row is the exception, in every theme. It has detached from the
            // enclosure, so it no longer shares a seam with the row above — and no
            // shadow separates them either, because a drop travels down-right and the
            // counter-glow is white-on-near-white up there. Without the outline the
            // hovered row simply merges upward and you cannot tell where it starts.
            self.border.strokeColor = (self.selected || lighting == nil || self.lift == .card)
                ? hair : NSColor.clear.cgColor
            // ★ The halo's blur MUST stay inside Theme.cardCellInset (18pt): a scroll
            // view's clip rect crops at its own edge, and a cropped soft shadow does
            // not fade — it stops in a straight line down the side of the list. The
            // mock's outer 44px lobe is what this budget spends away; 13 + the 1pt lip
            // is what fits. Opacity carries the rest, and dark mode can take more of
            // it — the same accent over a light frost turns milky before it glows.
            self.selGlow.shadowColor = Status.accent(self.status).cg(in: self)
            self.selGlow.shadowOffset = .zero
            self.selGlow.shadowRadius = 13
            self.selGlow.shadowOpacity = self.selected ? (self.isDark ? 0.90 : 0.55) : 0
            self.divider.strokeColor = div
            self.decorationLayers.forEach { $0.transform = self.liftTransform }

            if let lighting {
                if self.castsDrop { self.layer?.applyShadowLobe(lighting.drop) }
                else { self.layer?.shadowOpacity = 0 }
                if self.castsGlow, let counter = lighting.counterGlow {
                    self.glow.applyShadowLobe(counter)
                } else {
                    self.glow.shadowOpacity = 0
                }
                // Only the slab's real top edge catches the rim light; a middle
                // slice's "top" is a seam.
                self.rim.isHidden = lighting.rimHighlight == nil
                    || !(self.role == .top || self.role == .solo)
                self.rim.backgroundColor = lighting.rimHighlight?.cgColor
                return
            }

            self.glow.shadowOpacity = 0
            self.rim.isHidden = true
            let op: Float
            // Lift shadows are DARK MODE ONLY (the mock is dark-only): on a light
            // background any black shadow reads as a dirty grey ring, and the hairline +
            // scale already carry the lift there.
            switch self.lift {
            case .none:  op = 0
            case .card:  op = self.isDark ? 0.45 : 0
            // Only the slice that owns the group's bottom edge sheds — see castsDrop.
            // Letting the interior slices shed too (they used to, at 0.65) is what put
            // a column of separate shadow blocks down each side of a lifted group.
            case .group: op = self.isDark && self.castsDrop
                            ? 0.38 * self.groupShadowParams.opacity : 0
            }
            self.layer?.shadowOpacity = op
        }
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; work() }
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true); work(); CATransaction.commit()
        }
    }
}

// MARK: - DiscButton (round collapse toggle on a group header)
//
// A 25pt circle with a chevron that points down (expanded) or right (collapsed).
// Replaces the bare chevron glyph on the folder header — bigger, obviously
// tappable, with its own hover darkening and a pointing-hand cursor. Purely a
// visual affordance: the table still routes the actual toggle through hit-testing
// the disc's frame (see HeaderCell.chevronHit), so this view stays dumb.

final class DiscButton: NSView {
    private let disc = CALayer()
    private let chevron = CALayer()
    private var collapsed = false
    private var hovering = false
    private var trackingInstalled = false

    private static let side: CGFloat = 25

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        disc.cornerRadius = Self.side / 2
        disc.cornerCurve = .continuous
        disc.borderWidth = 1
        layer?.addSublayer(disc)
        chevron.contentsGravity = .resizeAspect
        layer?.addSublayer(chevron)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.frame = bounds
        let s: CGFloat = 13
        chevron.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        renderChevron()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        chevron.contentsScale = window?.backingScaleFactor ?? 2
        renderChevron()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !trackingInstalled else { return }
        trackingInstalled = true
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; apply() }
    override func mouseExited(with event: NSEvent)  { hovering = false; apply() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func configure(collapsed: Bool) {
        guard collapsed != self.collapsed else { return }
        self.collapsed = collapsed
        renderChevron()
    }

    private func apply() {
        let fill = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        let rim = (hovering ? Theme.hairlineHover : Theme.hairline).cg(in: self)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A faint dark well on light glass; the adaptive fill already inverts for dark.
        disc.backgroundColor = fill
        disc.borderColor = rim
        CATransaction.commit()
        renderChevron()
    }

    // Draw the chevron glyph tinted by hover state into the layer contents.
    private func renderChevron() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        guard let base = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                 accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        else { return }
        let color: NSColor = hovering ? .labelColor : .secondaryLabelColor
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true
        }
        chevron.contents = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Glass icon button (e.g. refresh)

final class GlassButton: NSButton {
    private var hovering = false
    // The glyph is drawn into a CALayer we own (not the button cell, not a
    // backing layer AppKit re-geometries) so a rotation animation spins exactly
    // around its center — anchorPoint of a plain CALayer is (0.5, 0.5).
    private let iconLayer = CALayer()
    private let baseImage: NSImage?
    private var iconColor: NSColor = .secondaryLabelColor

    init(symbol: String, action: Selector, target: AnyObject) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        applyGlass()

        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        renderIcon()

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        // Don't implicitly animate the recenter on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
        renderIcon()
    }

    // SF Symbols are template images; tint them by drawing the glyph then
    // flooding its alpha with the current color.
    private func renderIcon() {
        guard let base = baseImage else { return }
        let color = iconColor
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        iconLayer.contents = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent)  { setHover(false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlass()
    }

    // Resolve the adaptive fill/border under the current appearance.
    private func applyGlass() {
        layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        layer?.borderColor = (hovering ? Theme.hairlineHover : Theme.hairline).cg(in: self)
    }

    private func setHover(_ on: Bool) {
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            applyGlass()
        }
        iconColor = on ? .labelColor : .secondaryLabelColor
        renderIcon()
    }

}

// MARK: - SegmentedPill (header tool cluster)
//
// The main window's stats / settings / refresh buttons fused into ONE glass
// capsule, split by interior hairlines — a single compact control instead of
// three loose squares. The pill owns the glass chrome (fill, border, capsule
// rounding); each segment is a `bare` GlassButton that keeps only its glyph and
// a hover brighten of its own slice, so the refresh segment's spin state machine
// rides along untouched.

final class SegmentedPill: NSView {
    private var dividers: [NSView] = []

    private static let segWidth: CGFloat = 34
    private static let height: CGFloat = 28

    init(buttons: [GlassButton]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true    // hover fills clip to the capsule ends

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (i, button) in buttons.enumerated() {
            if i > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(divider)
                divider.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
                dividers.append(divider)
            }
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: Self.segWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func resolveColors() {
        layer?.backgroundColor = Theme.cardFill.cg(in: self)
        layer?.borderColor = Theme.hairline.cg(in: self)
        for d in dividers { d.layer?.backgroundColor = Theme.hairline.cg(in: self) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - MicroProgressBar (header quota bars)
//
// A tiny 48×3 rounded track with a fill tinted by how full the quota is
// (Status.usageTint) — the at-a-glance companion to the percentage figure.
// Bare sublayers, so every write snaps inside setDisableActions: the 2.5s
// full-reload reconfigures this in place and an implicit crossfade (or a fill
// width animating on every tick) would read as flicker.

/// Clay's inset "well" lip for a progress track — the design's `.well`, flattened:
/// at 3pt tall its four-lobe inset shadow is invisible noise, so only the dark lip
/// along the top edge survives, which is all that sells "recessed" at this size.
/// Collapses to nothing under a theme that bounds with hairlines.
private func styleWellLip(_ lip: CAGradientLayer, in view: NSView) {
    guard Theme.shadow(in: view) != nil else { lip.isHidden = true; return }
    lip.isHidden = false
    lip.startPoint = CGPoint(x: 0.5, y: 1)   // y-up: the top edge
    lip.endPoint = CGPoint(x: 0.5, y: 0)
    lip.colors = [NSColor.black.withAlphaComponent(0.22).cgColor, NSColor.clear.cgColor]
    lip.locations = [0, 0.7]
}

final class MicroProgressBar: NSView {
    private let track = CALayer()
    private let lip = CAGradientLayer()   // clay: the well's recessed top edge
    private let fill = CALayer()
    private var pct = 0

    init(minWidth: CGFloat = 60, minWidthPriority: NSLayoutConstraint.Priority = .required) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        track.cornerRadius = 1.5
        lip.cornerRadius = 1.5
        fill.cornerRadius = 1.5
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        // Above the fill: a well's lip is cast by the track's own edge, so it reads
        // over whatever sits in the groove.
        layer?.addSublayer(lip)
        // The bar is the only elastic column in a MetricLine: every neighbour has a
        // fixed width, so it takes whatever the card has left over and yields first
        // when the header is cramped. No upper cap — inside a card it should fill
        // the gap, which is what puts all four bars on one pair of vertical lines.
        //
        // ⚠️ This width is ALSO WHAT SETS THE MAIN WINDOW'S NATURAL WIDTH, which is
        // not obvious and cost a long hunt. That window is content-sized: AppKit
        // asks Auto Layout for a fitting width and resizes the window to it. Every
        // other column in the header is a fixed constant, so this one constraint is
        // the only thing in the whole header expressing "I would like some room",
        // and the window ends up 267pt + 2× whatever it says.
        //
        // At the old 48pt AND at .defaultLow the header asked for less than the
        // window's 384pt minimum, so the window snapped to that minimum and sprang
        // back every time it was dragged wider — it looked like resizing was
        // broken. (Before the 2×2 grid the header held two labelled quota capsules
        // whose text propped it to ~477pt; nothing replaced that.) 100pt at
        // .defaultHigh restores roughly that width while still yielding to a user
        // who drags the window narrower, down to the 384 floor.
        //
        // ⚠️ That is no longer true for the header, which now passes a floor of 6:
        // the demand moved up to QuotaTrio.wantWidth, because a trio bar has to be
        // able to shrink and something else has to do the asking.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The trio strip passes a smaller, yielding floor — see MetricLine.Style.trio
        // for why 60 required would make its width arithmetic unsatisfiable.
        let barMin = widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        barMin.priority = minWidthPriority
        NSLayoutConstraint.activate([
            barMin,
            heightAnchor.constraint(equalToConstant: 3),
        ])
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        lip.frame = bounds
        fill.frame = fillFrame()
        CATransaction.commit()
    }

    private func fillFrame() -> CGRect {
        CGRect(x: 0, y: 0,
               width: bounds.width * CGFloat(pct) / 100, height: bounds.height)
    }

    func configure(pct: Int) {
        self.pct = min(max(pct, 0), 100)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = Status.usageTint(self.pct).cg(in: self)
        fill.frame = fillFrame()
        CATransaction.commit()
    }

    private func resolveColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = Theme.barTrack.cg(in: self)
        fill.backgroundColor = Status.usageTint(pct).cg(in: self)
        styleWellLip(lip, in: self)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - PctCapsule (context occupancy, 变体 B)
//
// A compact rounded chip showing "<pct>%", tinted green→amber→red by fullness
// (Status.usageTint) over a pale wash of the same hue — the low-density companion to
// the "used / limit" figure beside it. Collapses to intrinsic .zero when pct < 0
// (occupancy unknown), so the row falls back to the bare token figure with no chip.
final class PctCapsule: NSView {
    private var pct = 0
    private var known = false
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.rounded(10, .bold)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(pct: Int) {
        known = pct >= 0
        self.pct = max(0, min(100, pct))
        label.stringValue = known ? "\(self.pct)%" : ""
        label.textColor = Status.usageTint(self.pct)
        invalidateIntrinsicContentSize()
        needsLayout = true
        resolveColors()
    }

    // Zero size when unknown so the inline chip disappears from the meta flow.
    override var intrinsicContentSize: NSSize {
        guard known else { return .zero }
        let w = label.intrinsicContentSize.width + 12
        return NSSize(width: w, height: 16)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func resolveColors() {
        // Pale wash of the tint (alpha varies with appearance handled by usageTint).
        layer?.backgroundColor = known
            ? Status.usageTint(pct).withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - ModelChip (the session's current model, last column of the usage line)
//
// A compact tinted capsule reading "Opus 5" / "Sonnet 5" / "Haiku 4.5", the label in its
// family's semantic hue over a pale wash of the same (Status.modelTint: Opus 紫 /
// Sonnet 青 / Haiku 琥珀). Same material and metrics as PctCapsule, its neighbour on that
// line, so the two read as one family of chips. No ✦ marker: the fill already separates
// it from the bare ⏱/◆ figures, and a glyph inside a colored capsule only crowds it.
// Collapses to intrinsic .zero on an empty label (model unknown, or the display setting
// is off) so the row shows no empty chip.
final class ModelChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.rounded(10, .bold)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // "" hides the chip entirely (intrinsic .zero) — see configure() in ChildCell.
    func configure(model: String) {
        label.stringValue = model
        tint = Status.modelTint(model)
        label.textColor = tint
        invalidateIntrinsicContentSize()
        needsLayout = true
        resolveColors()
    }

    override var intrinsicContentSize: NSSize {
        guard !label.stringValue.isEmpty else { return .zero }
        return NSSize(width: label.intrinsicContentSize.width + 12, height: 16)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func resolveColors() {
        layer?.backgroundColor = label.stringValue.isEmpty
            ? NSColor.clear.cgColor
            : tint.withAlphaComponent(0.18).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - UsageMetricsView (the shared 第二列: ⏱ 时长 · ◆ tokens · % · 模型)
//
// ONE component for the metrics column, used by every list that shows it — the session
// row (ChildCell) and the expanded agent sublist node (AgentCell). Owning the geometry
// here is the point: the column x's, fonts, tints and visibility rules live in a single
// place, so an agent node can never drift into its own dialect of the same line (it did:
// hand-rolled 10pt gray text with two-space separators, a plain ✦ model word and a bare
// "0%" — none of it lining up with the row above).
//
// Fixed sub-columns (x measured from the block's leading edge, see the numbers below)
// mean the ⏱ / ◆ / % / model slots start at the same x in EVERY row of EVERY list, so
// the figures read as a table down the window instead of a ragged run of text.
final class UsageMetricsView: NSView {
    // The x's are MEASURED, not guessed (same fonts as the real renders, widest strings):
    // "⏱ 1.8h" 34.8 → time slot 42 (7pt gap); "◆ 999k" 40.3 from 42 → 82.3 → % at 96;
    // the capsule maxes at 41.0 ("100%") → 137, so the model starts at 144; the widest
    // current chip "Haiku 4.5" is 60.7 (legacy "Sonnet 3.5" 67.5) → 70pt slot → 214.
    static let timeColX: CGFloat = 42
    static let pctColX: CGFloat = 96
    static let modelColX: CGFloat = 144
    static let modelSlotW: CGFloat = 70
    /// Width the inline % capsule owns, i.e. how far the model column trails the %.
    static let pctSlotW: CGFloat = modelColX - pctColX   // 48

    // How much of the block the "⏱ 时长 ◆ tokens" text run occupies — it is what every
    // column after it is measured from, so switching a metric off closes its slot up and
    // slides the % / model / step columns left. Per-SETTING, never per-row: all rows keep
    // agreeing on where each column starts.
    static var metaColW: CGFloat {
        switch (AppSettings.showDuration, AppSettings.showTokens) {
        case (true, true):   return pctColX     // ⏱ slot 42 + "◆ 999k" 40.3 + gap
        case (true, false),
             (false, true):  return 48          // one metric alone: 40.3 + 6 gap, rounded
        case (false, false): return 0           // both off — the text run is empty
        }
    }
    /// Where the inline % capsule sits (变体 B); the model column trails it by pctSlotW.
    static var modelColStart: CGFloat {
        AppSettings.contextGaugeStyle == .capsule ? metaColW + pctSlotW : metaColW
    }

    // Width the owner reserves for the whole block so whatever follows it (the live tool
    // step) begins at a constant x across rows. It shrinks with every setting that empties
    // a column: 变体 C/off have no inline capsule (the chip closes up into the % slot), the
    // model label can be switched off entirely, and so can either metric in the text run.
    static var reservedWidth: CGFloat {
        AppSettings.showModelLabel ? modelColStart + modelSlotW : modelColStart
    }

    private let metaLabel = NSTextField(labelWithString: "")
    private let pctCapsule = PctCapsule()
    private let modelChip = ModelChip()

    // The two chips, exposed read-only so the settings live-preview card can flash the
    // exact element a display setting controls ("this is what you just changed"). Nothing
    // else reaches in — the chips stay privately owned and configured.
    var pctChipView: NSView { pctCapsule }
    var modelChipView: NSView { modelChip }
    /// The "⏱ 时长 ◆ tokens" text run — the preview flashes it for either metric switch
    /// (both live in this one label, so they share a target).
    var metaTextView: NSView { metaLabel }
    // Both chips sit at their fixed column below required priority, so the ≥ chain
    // (which guards against overlap when something upstream runs long — a project-name
    // prefix, a 3-digit %) wins over the column: a nudged column beats an overlap.
    private lazy var pctFixedX: NSLayoutConstraint = {
        let c = pctCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.pctColX)
        c.priority = .defaultHigh
        return c
    }()
    private lazy var modelFixedX: NSLayoutConstraint = {
        let c = modelChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.modelColX)
        c.priority = .defaultHigh
        return c
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = Theme.rounded(10.5, .medium)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        // Single line: inside the narrow fixed column the time·token pair would otherwise
        // wrap onto two stacked rows instead of truncating. maximumNumberOfLines=1 (not
        // usesSingleLineMode) keeps it one line while still honoring the paragraph tab
        // stops that align the ⏱ time / ◆ token columns — single-line mode collapses them.
        metaLabel.maximumNumberOfLines = 1
        metaLabel.usesSingleLineMode = false
        // The text yields first when the block is squeezed; the chips never shrink.
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaLabel)

        for chip in [pctCapsule, modelChip] as [NSView] {
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(chip)
        }

        // The block defaults to the reserved width but GROWS with its content (the ≥
        // chain is required, the width is not), so a long meta run — e.g. the project
        // name prefixed in status-group mode — pushes the chips right instead of being
        // truncated. An owner that needs a hard cap (a row where the live step shares
        // the line) constrains the block's trailing edge and the text truncates again.
        let w = widthAnchor.constraint(equalToConstant: Self.reservedWidth)
        w.priority = .defaultLow
        widthC = w

        NSLayoutConstraint.activate([
            w,
            heightAnchor.constraint(equalToConstant: 16),   // the chips' height

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            metaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pctFixedX,
            pctCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: metaLabel.trailingAnchor, constant: 6),
            pctCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),

            modelFixedX,
            modelChip.leadingAnchor.constraint(greaterThanOrEqualTo: pctCapsule.trailingAnchor, constant: 6),
            modelChip.leadingAnchor.constraint(greaterThanOrEqualTo: metaLabel.trailingAnchor, constant: 6),
            modelChip.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Nothing may spill past the block's own edge — subviews are clipped there.
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pctCapsule.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            modelChip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private var widthC: NSLayoutConstraint!

    // `meta` is the pre-rendered "⏱ … ◆ …" run (usageText) or any replacement phrase
    // (a desktop row's status words); `pct` < 0 hides the capsule, an empty `model`
    // hides the chip. The style/setting gates live here so every caller obeys them.
    //
    // `freeMeta` marks a caller whose meta is a phrase rather than the metric columns
    // (the desktop row): it keeps the full text slot no matter which metrics are switched
    // off, since those switches say nothing about a row that has no metrics to begin with.
    func configure(meta: NSAttributedString, pct: Int, model: String, freeMeta: Bool = false) {
        metaLabel.attributedStringValue = meta
        // Only 变体 B (capsule) carries the inline % — 变体 C paints a bar on the row's
        // bottom edge instead (the owner's business), off shows nothing.
        pctCapsule.configure(pct: AppSettings.contextGaugeStyle == .capsule ? pct : -1)
        modelChip.configure(model: AppSettings.showModelLabel ? model : "")
        pctFixedX.constant = Self.metaColW
        modelFixedX.constant = Self.modelColStart
        widthC.constant = freeMeta ? max(Self.reservedWidth, Self.pctColX) : Self.reservedWidth
    }

    // "⏱ 12m · 56k" — running time (green) and CURRENT context occupancy in raw tokens
    // (Claude orange). The window denominator ("/1M") is intentionally dropped — the %
    // gauge already conveys the ratio and the "/limit" only crowded the line.
    //
    // A never-run session shows no subtitle at all — the empty meta line reads cleaner
    // than a "尚未运行" placeholder. `always` overrides that for the agent sublist, where
    // a fixed set of columns ("⏱ 0s ◆ 0" from the first frame) reads as a table and a
    // slot that appears later would make every node a different shape.
    //
    // Either metric can be switched off (设置 › 显示 › 列表 › 工作时长 / Tokens); with both
    // off the run is empty and every column after it closes up (see metaColW).
    static func usageText(workSec: Int, ctxTokens: Int, always: Bool = false) -> NSAttributedString {
        let showTime = AppSettings.showDuration
        let showTok = AppSettings.showTokens
        guard showTime || showTok else { return NSAttributedString() }
        guard always || workSec > 0 || ctxTokens > 0 else { return NSAttributedString() }
        // 方案 A (design/row-metrics-align.html): fixed-width columns. A single left
        // tab stop pins the ◆ token marker to a constant x (timeColX), so the ⏱ time
        // figure gets a reserved slot and no matter its width ("45s" / "12m" / "9.9h")
        // the token column starts at the same place — rows line up vertically across
        // every list. Tabular (mono) digits keep the figures themselves from jittering.
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: timeColX, options: [:])]
        para.lineBreakMode = .byTruncatingTail
        // Deep/bright self-adjusting tones stay legible over the glass on their own —
        // no outline, which on small numerals always reads as cheap.
        func tinted(_ c: NSColor) -> [NSAttributedString.Key: Any] {
            [.foregroundColor: c, .font: Theme.roundedMono(10.5, .bold), .paragraphStyle: para]
        }
        // Each metric wears its own icon (⏱ 时长 / ◆ token), tinted with the same hue as
        // its value (time green / token orange) at a slightly smaller size.
        func iconTint(_ c: NSColor) -> [NSAttributedString.Key: Any] {
            [.foregroundColor: c, .font: Theme.rounded(9.5, .medium), .paragraphStyle: para]
        }
        let out = NSMutableAttributedString()
        if showTime {
            out.append(NSAttributedString(string: "⏱ ", attributes: iconTint(Status.usageGreen)))
            out.append(NSAttributedString(string: fmtDur(workSec), attributes: tinted(Status.usageGreen)))
        }
        if showTok {
            // \t jumps to the fixed token column when the time slot precedes it; alone,
            // tokens start at the run's own origin. Always render the slot once running —
            // "◆ 0" while the first count is still pending, so the metric is visible from
            // the start instead of appearing later.
            out.append(NSAttributedString(string: showTime ? "\t◆ " : "◆ ",
                                          attributes: iconTint(Status.claudeOrange)))
            out.append(NSAttributedString(string: fmtTok(ctxTokens), attributes: tinted(Status.claudeOrange)))
        }
        return out
    }

    // "62%" tinted by fullness — 变体 C's right-aligned occupancy figure.
    static func pctString(_ pct: Int) -> NSAttributedString {
        NSAttributedString(string: "\(pct)%", attributes: [
            .foregroundColor: Status.usageTint(pct), .font: Theme.rounded(10.5, .bold)])
    }

    static func fmtDur(_ sec: Int) -> String {
        switch sec {
        case 3600...: return String(format: "%.1fh", Double(sec) / 3600)
        case 60...:   return "\(sec / 60)m"
        default:      return "\(sec)s"
        }
    }
    static func fmtTok(_ n: Int) -> String {
        // No decimals — round to a whole k/M so the token column stays narrow ("618k",
        // not "618.4k"). The rounding boundary (e.g. 999_600 → "1000k") is rare enough
        // that the extra digit doesn't warrant a carry into the next unit.
        switch n {
        case 1_000_000...: return "\(Int((Double(n) / 1_000_000).rounded()))M"
        case 1_000...:     return "\(Int((Double(n) / 1_000).rounded()))k"
        default:           return "\(n)"
        }
    }
}

// MARK: - ContextBarView (context occupancy, 变体 C)
//
// A thin, full-width rounded progress bar (battery-style) pinned along a row's bottom
// edge: track + a fill whose width and tint (Status.usageTint) track occupancy. Width
// is driven by the row (leading/trailing constraints), unlike the fixed-width
// MicroProgressBar. Hidden by the cell (isHidden) when occupancy is unknown.
final class ContextBarView: NSView {
    private let track = CALayer()
    private let lip = CAGradientLayer()   // clay: the well's recessed top edge
    private let fill = CALayer()
    private var pct = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        track.cornerRadius = 1.5
        lip.cornerRadius = 1.5
        fill.cornerRadius = 1.5
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        layer?.addSublayer(lip)
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        lip.frame = bounds
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(pct) / 100, height: bounds.height)
        CATransaction.commit()
    }

    func configure(pct: Int) {
        self.pct = min(max(pct, 0), 100)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = Status.usageTint(self.pct).cg(in: self)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(self.pct) / 100, height: bounds.height)
        CATransaction.commit()
    }

    private func resolveColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = Theme.barTrack.cg(in: self)
        fill.backgroundColor = Status.usageTint(pct).cg(in: self)
        styleWellLip(lip, in: self)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - Scroll document width (改任何 pane 的 scroll view 前必读)

/// Pin a scroll view's document to the clip's width — as a floor, never as a lock.
///
/// Every pane (设置 / 统计 / 最近项目) is a column inside a scroll view, and the column
/// has to span the clip so rows reach both edges. Writing that as a plain `==` makes it
/// BIDIRECTIONAL, and because all four panes stay mounted in the main window's shared
/// container (hidden ones included, their constraints still live), one over-wide label
/// anywhere inside propagates the whole way out: column → doc → clip → scroll → pane →
/// window. The window's minimum width jams above its 384pt `minSize` and no amount of
/// dragging brings it back — measured at 409pt from the English 设置 column alone, and a
/// deep project path in 最近项目 does the same thing.
///
/// `>=` required + `==` at 999 keeps the everyday look identical (the column still fills
/// the clip) while giving content that genuinely doesn't fit somewhere to go — it
/// overflows into a horizontal scroll instead of shoving the window wider.
func pinDocumentWidth(_ doc: NSView, filling scroll: NSScrollView) {
    doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true
    let snug = doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    snug.priority = .defaultLow
    snug.isActive = true
    squeeze(scroll).isActive = true
}

/// "Be as narrow as you can" — the counterweight that makes an optional width pin
/// actually optional.
///
/// A window's minimum size comes from a fitting-size pass over its constraints, and
/// that pass grants any optional constraint nothing is arguing with. So dropping a
/// width pin to a low priority achieves nothing by itself: with no opposing wish on
/// record, the pin is still satisfied and the content still sets the floor. Pair the
/// pin (at `.defaultLow`) with this one step above it, and the fitting pass resolves
/// the other way — while both stay far below the required leading/trailing pins that
/// give the view its real width in ordinary layout, so nothing visible changes.
func squeeze(_ view: NSView) -> NSLayoutConstraint {
    let c = view.widthAnchor.constraint(equalToConstant: 0)
    c.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
    return c
}

// MARK: - HairlineView

// Appearance-adaptive 1px divider (the accounts panel's section rules).
final class HairlineView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func resolveColors() {
        layer?.backgroundColor = Theme.hairline.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - Agent palette (⚠️ 待并入 Theme)
//
// Claude has a palette token (Status.claudeOrange, tuned per theme and per
// appearance). Codex has none, and one can't be added from this file — a real
// token lives in ThemeSpec.palette so every theme can restate it. These two are
// the interim: same shape (dynamic light/dark) so moving them into the palette is
// a cut-and-paste, not a rewrite.

/// Codex's brand mint. The dark tone is the design's #2DFFB0; on a light backdrop
/// that value is unreadable at 10.5pt, so the light appearance takes a deepened
/// teal — the same legibility trick Status.claudeOrange documents.
private let codexMint = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.176, green: 1.0, blue: 0.690, alpha: 1)
        : NSColor(srgbRed: 0.0, green: 0.541, blue: 0.376, alpha: 1)
}

/// The wash that pushes the session list back while an account panel is open. Near
/// black in both appearances on purpose: this is "the list is a backdrop now", and
/// a light-gray veil over a light theme says nothing at all.
private let accountScrimFill = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 0.55)

// MARK: - QuotaTrio (this machine / Claude / Codex, side by side)
//
// ── Why the widths are arithmetic instead of a stack view ───────────────────
// Three columns at flex-grow 1; while one is focused (hovered, or its account
// panel is open) it goes to 3 and the other two drop to 1 — the same total width,
// redealt. Nothing in AppKit expresses that: NSStackView knows exactly one
// proportion (`.fillEqually`), a constraint `multiplier` is not animatable, and
// animating a card's `frame` moves the layer while the constraint-driven contents
// (bars, countdown) snap to their final places on frame 0. So every card owns two
// constraints against this view — leading offset and width — and this view deals
// both from its own bounds whenever the bounds or the focus change.
// `animator().constant` runs a real layout pass per frame, which is what makes the
// bars travel WITH the card edge.
//
// The countdown is always open (2026-09-10: the bar alone read as empty space), so
// the steal buys the focused card a longer bar and nothing else. The user tuned
// the whole strip in design/header-account-quota-5-proposals.html round 8
// (2026-09-11) and kept the steal at 3:1.
//
// Card height is a constant and never changes, in either state: the whole point
// of the horizontal steal is that the list below doesn't move.
final class QuotaTrio: NSView {

    enum Slot { case machine, claude, codex }

    /// ★ The three are columns of ONE pane now, but they still stand APART inside it
    /// — the seam sits in the middle of this gap, not against a column's edge. Zero
    /// gap with a seam flush to the content read as three things shoved together,
    /// which is the opposite of what the single pane is for.
    /// Kept equal to `MetricCard.seamInset * 2` so the seam lands exactly halfway.
    private static let gap: CGFloat = MetricCard.seamInset * 2
    /// flex-grow 3 / 1, tuned by the user in the round-8 preview.
    private static let focusGrow: CGFloat = 3
    private static let restGrow: CGFloat = 1
    /// A card that has given up width still has to show every fixed sub-column of
    /// its lines plus a stub of bar (that is the whole bargain — nothing
    /// disappears). Below this the 1 share stops being honoured (see `widths`),
    /// and below three of these the gap goes (see `apply`). Derived, not typed,
    /// so retuning the line's slots can't leave it stale.
    private static let minCard: CGFloat = {
        let s = MetricLine.Style.trio
        return MetricCard.trioInset * 2 + s.iconW + s.gap * 3 + s.pctW + s.barMin + s.footW
    }()
    private static let duration: TimeInterval = 0.2
    private static let curve = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)

    private struct Entry {
        let slot: Slot
        let card: MetricCard
        let leading: NSLayoutConstraint
        let width: NSLayoutConstraint
    }
    private var entries: [Entry] = []
    private var lastWidth: CGFloat = -1

    /// The one pane all three columns sit in. Owned here rather than by any card,
    /// because it must not move or resize when a hover re-deals the widths.
    ///
    /// ★ A separate, layer-backed SUBVIEW — not layers on the strip itself. Making
    /// the strip layer-backed (measured 2026-09-04) stopped Auto Layout from running
    /// a second pass after `apply()` re-dealt the constants from inside `layout()`:
    /// one pass ran with every width still 0, no follow-up came, and the three cards
    /// drew on top of each other at x=0. Keeping the strip a plain view is what makes
    /// that follow-up pass happen; the pane lives in a child that doesn't care.
    private let shell = ChipShellView()

    /// nil = nothing clickable was hit. The machine card reports too — its click
    /// opens Activity Monitor rather than a panel, but the hit test is the same.
    var onClick: ((Slot) -> Void)?

    /// The slot whose account panel is open. It holds the focus while the pointer
    /// wanders off, so the card the panel belongs to stays the wide one.
    var pinned: Slot? {
        didSet { if pinned != oldValue { apply(animated: true) } }
    }
    private var hovered: Slot? {
        didSet { if hovered != oldValue { apply(animated: true) } }
    }
    private var focus: Slot? { pinned ?? hovered }

    /// Asks the content-sized main window for a sensible width.
    ///
    /// ⚠️ Load-bearing, and not obvious: MicroProgressBar's `>= 60` used to be the
    /// only constraint in the whole header expressing "I'd like some room", so it
    /// was what set the window's natural width (see the note on that constraint).
    /// The trio's bars drop that floor to 6 to survive being squeezed, which takes
    /// the demand with it — this constraint puts it back at strip level, where it
    /// belongs. `.defaultHigh` so dragging the window narrower still wins.
    private lazy var wantWidth: NSLayoutConstraint = {
        let c = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        c.priority = .defaultHigh
        return c
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // First subview, so the cards added later sit above it.
        addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantWidth.isActive = true
        heightAnchor.constraint(equalToConstant: MetricCard.trioHeight).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the strip. Cards that aren't in `slots` are REMOVED from the view
    /// hierarchy, not hidden: a hidden view still takes part in Auto Layout, and a
    /// card pinned to zero width would make its own row's fixed columns
    /// unsatisfiable — which is a broken constraint in the console and a mangled
    /// layout on screen, not an invisible card.
    func setSlots(_ slots: [(Slot, MetricCard)]) {
        guard slots.map(\.0) != entries.map(\.slot) else { return }
        for e in entries { e.card.removeFromSuperview() }
        entries = slots.enumerated().map { i, pair in
            let (slot, card) = pair
            card.seamless = true
            card.showsLeadingSeam = i > 0
            addSubview(card)
            let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
            let width = card.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([leading, width,
                                         card.topAnchor.constraint(equalTo: topAnchor)])
            return Entry(slot: slot, card: card, leading: leading, width: width)
        }
        if let p = pinned, !slots.contains(where: { $0.0 == p }) { pinned = nil }
        wantWidth.constant = CGFloat(entries.count) * 110
            + CGFloat(max(0, entries.count - 1)) * Self.gap
        lastWidth = -1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Re-dealing the widths mutates constraints, which schedules another layout
        // pass; the width guard is what stops that from looping. It also keeps a
        // resize from stomping on an in-flight hover animation with a final value.
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        apply(animated: false)
    }

    /// flex-grow, done by hand. Returns one width per entry, summing to exactly the
    /// space available after the gaps.
    private func widths(_ available: CGFloat) -> [CGFloat] {
        let n = entries.count
        let even = { (0..<n).map { _ in (available / CGFloat(n)).rounded() } }
        guard let f = focus, let fi = entries.firstIndex(where: { $0.slot == f }) else {
            return even()
        }
        let grows = (0..<n).map { $0 == fi ? Self.focusGrow : Self.restGrow }
        let sum = grows.reduce(0, +)
        var w = grows.map { (available * $0 / sum).rounded() }
        // At popover width the 1 share lands under what a card needs to keep its
        // fixed columns, and CSS's answer (overflow: hidden) has no Auto Layout
        // equivalent — the row would simply break a required column. So the floor
        // wins and the focused card gives the difference back. The steal therefore
        // reads weaker on a narrow window than in the preview; a broken constraint
        // would read worse.
        for i in w.indices where i != fi { w[i] = max(w[i], Self.minCard) }
        w[fi] = available - w.enumerated().filter { $0.offset != fi }.map(\.element).reduce(0, +)
        guard w[fi] >= Self.minCard else { return even() }
        return w
    }

    private func apply(animated: Bool) {
        let n = entries.count
        guard n > 0, bounds.width > 1 else { return }
        // ★ The gap is the FIRST thing to go when the strip is squeezed. Every column
        // has a required minimum built out of its own fixed sub-columns; deal it less
        // than that and Auto Layout breaks the width constraint instead, at which
        // point all three fall back to their intrinsic size at leading offsets meant
        // for narrower ones — i.e. they OVERLAP. Three columns sitting flush is a far
        // better failure than three columns printed on top of each other. This is what
        // the popover hits: it is ~100pt narrower than the main window.
        var gap = Self.gap
        if bounds.width - gap * CGFloat(n - 1) < CGFloat(n) * Self.minCard { gap = 0 }
        let available = bounds.width - gap * CGFloat(n - 1)
        guard available > CGFloat(n) else { return }
        var w = widths(available)
        // The last card absorbs the rounding residue, so the strip lands flush on
        // both edges instead of drifting a point per hover.
        w[n - 1] += available - w.reduce(0, +)

        let run = {
            var x: CGFloat = 0
            for (i, e) in self.entries.enumerated() {
                if animated {
                    e.leading.animator().constant = x
                    e.width.animator().constant = w[i]
                } else {
                    e.leading.constant = x
                    e.width.constant = w[i]
                }
                e.card.focused = e.slot == self.focus
                e.card.seamOffset = gap / 2
                x += w[i] + gap
            }
        }
        guard animated else { run(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = Self.curve
            run()
        }
    }

    // ---- pointer ----
    //
    // One tracking area for the whole strip rather than one per card: with separate
    // areas, crossing from one column to the next fires exit-then-enter and blinks
    // the widths back through the resting state on the way past.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hovered = slot(at: event) }
    override func mouseEntered(with event: NSEvent) { hovered = slot(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        guard let s = slot(at: event) else { return }
        onClick?(s)
    }

    /// The gap between two cards counts as no card — which matches the design,
    /// where hovering the container without hovering a card leaves all three at the
    /// same grow value and therefore at equal widths.
    private func slot(at event: NSEvent) -> Slot? {
        let p = convert(event.locationInWindow, from: nil)
        return entries.first { $0.card.frame.contains(p) }?.slot
    }
}

// MARK: - AccountPanel (which account these numbers belong to, and how to switch)
//
// The address is the reason this exists at all — it's the one field with no chance
// of fitting on a 110pt card. It also switches accounts: a click puts that
// account's stored credential back as the CLI's live one (AccountBook.switchTo →
// CredentialVault), so every CLI opened afterwards is on it. No copy yet, or a
// stale one: the CLI's own login in Terminal, address pre-filled. A session that
// is already running keeps the account it started with — the footnote's job.
//
// This app never signs anyone in. Adding an account starts the CLI's own login;
// the address that comes out of it is remembered, and its credential copied, from
// then on. The only file that handles a secret is CredentialVault.swift.
final class AccountPanel: NSView {
    /// ★ No width of its own (2026-09-04, user's call): the panel is exactly as wide
    /// as the card it hangs under, and follows it live — the card grows when focused
    /// and shrinks back, and the panel tracks it in the same animation. The host
    /// pins `widthAnchor` to the card's; nothing here may add a floor or a ceiling,
    /// because either one would fight that pin the moment the strip is squeezed.
    /// Addresses are clipped in the middle when the card is narrow; that is the deal.

    /// Fired with the shell command to run in a terminal — a switch to a remembered
    /// address, or a fresh sign-in. The host owns dismissal, so the panel never
    /// decides when the overlay goes away.
    var onRun: ((String) -> Void)?

    private let bg = CALayer()
    private let kind: AgentKind
    private let note: NSTextField
    private let accent: NSColor
    private let title: String
    /// Rebuilt in place when an address is forgotten: the header count and the row
    /// list both change, and tearing the whole overlay down and back up to show it
    /// would flash the scrim behind it.
    private let stack = NSStackView()

    /// Presses in flight. The button spins while this is non-zero and the rows are
    /// rebuilt once when it returns to zero, not once per account.
    private var probing = 0
    /// Accounts the last press could not fetch — no usable token, or the service
    /// refused. Shown on the button rather than in the rows, which keep their old
    /// figure (still true of that account, just not new).
    private var probeMissed = 0

    init(kind: AgentKind, title: String, accent: NSColor) {
        self.kind = kind
        self.accent = accent
        self.title = title
        // Bilingual by the same rule as every other user-facing string; this one is
        // the promise the panel must not break, so it is always visible, never a
        // tooltip.
        // ★ One line, not two. The promise still has to be visible — it is the whole
        // reason a user doesn't file "I switched and nothing happened" as a bug — but at
        // two lines of grey it was taller than the content it qualified.
        note = NSTextField(wrappingLabelWithString:
            L("对新开的终端生效；在跑的会话先结束再切。", "Applies to new terminals; finish running sessions first."))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        letShadowsEscape()
        bg.cornerRadius = 11
        bg.cornerCurve = .continuous
        bg.borderWidth = 1
        layer?.addSublayer(bg)

        note.font = .systemFont(ofSize: 10)
        // ★ Full label colour, not a tertiary grey, and the same goes for every other
        // small text in this panel. At 9-10pt over the panel's own fill the system
        // greys measured as unreadable to the user — the hierarchy here is carried by
        // SIZE, which still works, so nothing is lost by making all of it legible.
        note.textColor = .labelColor
        note.isSelectable = false
        // A wrapping label would otherwise demand its whole single-line width and
        // shove the panel past maxWidth.
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .vertical
        // .width, not .leading: every row has to span the panel so its hover fill and
        // its trailing copy button land where the eye expects them.
        stack.alignment = .width
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        rebuild()
        applyChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A click on a remembered address. The stored copy goes back as the live
    /// credential and the panel redraws with the tick moved — that redraw IS the
    /// confirmation. No copy (or a rejected one): the CLI's own login, in Terminal,
    /// with the address pre-filled.
    private func pick(_ entry: RememberedAccount) {
        if Demo.enabled { Demo.pick(kind, email: entry.email); rebuild(); return }
        if AccountBook.switchTo(kind, email: entry.email) {
            rebuild()
            // ★ Ask the server for the account we just switched TO (2026-09-09, user's
            // call). Everything else that knows this account's quota is now stale by
            // definition, and the local route back to a current figure is slow: the
            // `claude -p /usage` probe measured 5.1s and waits out a throttle of up to
            // 15s first. Until it lands the header has nothing current to show for the
            // account under the pointer — which is the whole reason a switch used to
            // look like it hadn't taken.
            //
            // The credential this asks with is the copy that was just restored as the
            // live one, so this is the one probe whose answer needs no disclaimer.
            // Codex has no such endpoint; its card simply waits.
            if kind == .claude { probe([entry]) }
        } else {
            onRun?(AccountBook.switchCommand(kind, email: entry.email))
        }
    }

    /// The refresh press: one request per askable account, all at once, one rebuild
    /// when the last comes back. A press while one is running is ignored — the rows
    /// it would update are about to be updated anyway.
    private func probe(_ accounts: [RememberedAccount]) {
        guard probing == 0 else { return }
        probing = accounts.count
        probeMissed = 0
        rebuild()                                  // the button starts spinning
        for a in accounts {
            AccountBook.probeUsage(kind, email: a.email) { [weak self] ok in
                guard let self else { return }
                if !ok { self.probeMissed += 1 }
                self.probing -= 1
                if self.probing == 0 { self.rebuild() }
            }
        }
    }

    /// Fill the stack from the book and the current sign-in — on open, and again
    /// after a row forgets its address or a switch lands.
    private func rebuild() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()      // the note is re-added below; the rest are dropped
        }

        // Header: name hard-pinned LEFT, account count right. Explicit constraints
        // rather than relying on the label's alignment inside a .width stack — that
        // rendered the title flush RIGHT, which read as a stray tag rather than a title.
        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(11.5, .semibold)
        name.textColor = accent
        name.alignment = .left
        name.translatesAutoresizingMaskIntoConstraints = false

        let current = Demo.enabled ? Demo.account(kind)
            : kind == .claude ? AgentAccounts.claude() : AgentAccounts.codex()
        let book = Demo.enabled ? Demo.book(kind) : AccountBook.list(kind)
        let count = NSTextField(labelWithString:
            book.count == 1 ? L("1 个账号", "1 account")
                            : L("\(book.count) 个账号", "\(book.count) accounts"))
        count.font = .systemFont(ofSize: 9.5)
        count.textColor = .labelColor
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false

        let head = NSView()
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(name)
        head.addSubview(count)
        NSLayoutConstraint.activate([
            head.heightAnchor.constraint(equalToConstant: 16),
            // +6/-6 to match the inset every row keeps for its hover fill, so the
            // title sits on the same vertical line as the addresses under it.
            name.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: head.centerYAnchor),
        ])
        // The one control that reaches the network — through curl, on this press and
        // at no other moment — so it exists only where it has something to fetch:
        // Claude, with at least one address that is not signed in but has a stored
        // copy to ask with. Sits between the title and the count.
        let askable = Demo.enabled ? [] : book.filter {
            $0.email != current?.email && CredentialVault.has(kind, email: $0.email)
        }
        if kind == .claude, !askable.isEmpty {
            let refresh = RefreshQuotaButton(missed: probeMissed, busy: probing > 0) { [weak self] in
                self?.probe(askable)
            }
            head.addSubview(refresh)
            NSLayoutConstraint.activate([
                refresh.centerYAnchor.constraint(equalTo: head.centerYAnchor),
                refresh.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -6),
                refresh.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            ])
        } else {
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8).isActive = true
        }

        let headRule = HairlineView()
        headRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        var rows: [NSView] = [head, headRule]
        for (n, entry) in book.enumerated() {
            // A hairline between addresses. Each row is three lines tall now, so
            // spacing alone stopped being enough to say where one account ends — two
            // stacked accounts read as one six-line block without it.
            if n > 0 {
                let sep = HairlineView()
                sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rows.append(sep)
            }
            let isCurrent = entry.email == current?.email
            rows.append(AccountRow(kind: kind, entry: entry, isCurrent: isCurrent, accent: accent,
                                   onPick: { [weak self] in self?.pick(entry) },
                                   onForgot: { [weak self] in self?.rebuild() }))
        }

        let rule = HairlineView()
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rows.append(rule)
        // One click: a terminal running the CLI's own login with no address, which
        // opens the browser itself. The address that comes back lands in the book on
        // the next refresh, and from then on it is a one-click switch.
        rows.append(AddAccountRow { [weak self] in
            guard let self, !Demo.enabled else { return }   // a fake list has nowhere to sign in to
            // Deferred: reached from a mouse-up, and the launcher blocks on osascript,
            // which would otherwise run inside event dispatch with that click's event
            // still in flight.
            let cmd = AccountBook.addCommand(self.kind)
            DispatchQueue.main.async { self.onRun?(cmd) }
        })
        // The footnote gets the same 6pt inset the rows keep, so the panel has ONE
        // left edge from title to footnote instead of two a hair apart.
        let noteBox = NSView()
        noteBox.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        noteBox.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: noteBox.leadingAnchor, constant: 6),
            note.trailingAnchor.constraint(equalTo: noteBox.trailingAnchor, constant: -6),
            note.topAnchor.constraint(equalTo: noteBox.topAnchor),
            note.bottomAnchor.constraint(equalTo: noteBox.bottomAnchor),
        ])
        rows.append(noteBox)

        for v in rows { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(7, after: head)
        stack.setCustomSpacing(7, after: headRule)
        stack.setCustomSpacing(7, after: rule)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        CATransaction.commit()
        // The panel's width is content-driven, so the wrapping footnote can only be
        // told how wide it may be after the fact. The guard is what keeps this from
        // being an endless layout loop.
        let w = bounds.width - 34      // 11pt stack inset + 6pt row inset, both sides
        if w > 0, abs(note.preferredMaxLayoutWidth - w) > 0.5 {
            note.preferredMaxLayoutWidth = w
            note.invalidateIntrinsicContentSize()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }
    private func applyChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // cardFloat, not cardFill: this floats over a dimmed list, and a
        // translucent fill would let that list read through the panel.
        bg.backgroundColor = Theme.cardFloat.cg(in: self)
        bg.borderColor = Theme.hairline.cg(in: self)
        bg.shadowColor = NSColor.black.cgColor
        bg.shadowOpacity = 0.62
        bg.shadowRadius = 22
        bg.shadowOffset = CGSize(width: 0, height: -16)   // y-up layer space: downward
        CATransaction.commit()
    }
}

/// "1h52m" / "23m" / "3d" — the shortest form that still names its unit. These sit in
/// a 9pt trailing note where a spelled-out duration would not fit.
private func briefSpan(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t >= 86_400 { return "\(t / 86_400)d" }
    if t >= 3_600 {
        let h = t / 3_600, m = (t % 3_600) / 60
        return m > 0 ? "\(h)h\(m)m" : "\(h)h"
    }
    if t >= 60 { return "\(t / 60)m" }
    return "\(t)s"
}

/// One remembered address. Clicking it switches to that account; the current one is
/// ticked and inert (there is nothing to switch to).
private final class AccountRow: NSView {
    private let kind: AgentKind
    private let entry: RememberedAccount
    private let isCurrent: Bool
    private let onPick: () -> Void
    private let onForgot: () -> Void
    private let fill = CALayer()
    private var hovering = false
    private var trackingInstalled = false

    private var command: String { AccountBook.switchCommand(kind, email: entry.email) }

    init(kind: AgentKind, entry: RememberedAccount, isCurrent: Bool, accent: NSColor,
         onPick: @escaping () -> Void,
         onForgot: @escaping () -> Void) {
        self.kind = kind
        self.entry = entry
        self.isCurrent = isCurrent
        self.onPick = onPick
        self.onForgot = onForgot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        fill.cornerRadius = 6
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)

        // No tick any more. The signed-in account is the GREEN one — a colour the eye
        // catches in the same glance that reads the address, where a glyph in a
        // reserved gutter charged every row 16pt of indent to say the same thing once.
        let primary = NSTextField(labelWithString: entry.email)
        primary.font = isCurrent ? .systemFont(ofSize: 11.5, weight: .semibold)
                                 : .systemFont(ofSize: 11.5)
        primary.textColor = isCurrent ? Status.usageGreen : .labelColor
        primary.lineBreakMode = .byTruncatingMiddle
        // ★ Hugging 1, not .defaultLow. Every NSView already sits at .defaultLow
        // (250), so setting it there is a tie — and on a tie the stack hands the
        // spare width to EVERY view, which spread the row out and left the address
        // floating in from the edge. One view has to want the space strictly more
        // than the others, and the trailing controls have to refuse it outright.
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let plan = PlanChip()
        plan.text = entry.plan
        plan.setContentHuggingPriority(.required, for: .horizontal)

        // The built-in launcher can only drive Terminal.app, and plenty of people live
        // in an editor's integrated terminal — so the exact command has to be takeable.
        let copy = CopyCommandButton { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(self.command, forType: .string)
        }
        copy.setContentHuggingPriority(.required, for: .horizontal)

        let head = NSStackView(views: [primary, plan, copy])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 6
        // ★ .fill, not the default .gravityAreas. Under gravityAreas a stack with room
        // to spare centres its contents as a block, which is exactly what a short
        // address did: it sat indented while a long one in the row above began at the
        // edge. Both lines below carry the same fix.
        head.distribution = .fill

        // ── the quota lines ─────────────────────────────────────────────────────
        // ★ Only the signed-in account has CURRENT figures (see AccountUsage). Every
        // other row shows either what was true when it was last live — set back half a
        // step, never dressed up as live — or, once the clock has passed that window's
        // end, the one thing certain without a reading: it is full again. That last
        // case is why this exists: it says "you can switch to this one now" without
        // anyone having to sign in to check.
        //
        // Same shape as the header's own gauges — icon, figure, bar, countdown — on
        // purpose. It is the same fact at two zoom levels, and someone who has learnt
        // to read one shouldn't have to learn a second grammar for the other.
        let stored = isCurrent || Demo.enabled || CredentialVault.has(kind, email: entry.email)
        let now = Date().timeIntervalSince1970
        let u = entry.usage
        // "Current" alone is not enough to call a figure live: right after a switch
        // the probe hasn't re-run, so the newest reading this account has is still its
        // own old one. A reading the panel's refresh button fetched for THIS address
        // (`probed`) is live on its own terms, for as long as a fetched figure can
        // reasonably stand in for a current one.
        let probed = u?.probed == true && now - (u?.readAt ?? 0) < AccountBook.probeFreshFor
        let live = probed || (isCurrent && (u?.readAt ?? 0) > AccountBook.lastSwitch(kind))

        func gauge(_ symbol: String, _ window: String, _ pct: Int?, _ resetsAt: Double?) -> MetricLine {
            let line = MetricLine(symbol: symbol, accessibility: window, style: .trio)
            let rolled = (resetsAt ?? 0) > 0 && now >= resetsAt!
            line.configure(
                pct: rolled ? 0 : pct,
                foot: rolled || resetsAt == nil ? unknownCountdown : resetCountdown(resetsAt!),
                tooltip: rolled ? L("\(window)已经重置，现在满额可用",
                                    "\(window) has rolled over — full again")
                    : pct == nil ? L("没记录过这个账号的\(window)", "No \(window) reading for this account")
                    : probed ? L("\(window)：刚向服务器查的（\(briefSpan(now - (u?.readAt ?? now)))前）",
                                 "\(window): fetched from the server \(briefSpan(now - (u?.readAt ?? now))) ago")
                    : live ? L("\(window)：这个账号正在用，数字是刚测的",
                               "\(window): signed in — measured just now")
                    : L("\(window)：\(briefSpan(now - (u?.readAt ?? now)))前的数字，不是现在的",
                        "\(window): what it was \(briefSpan(now - (u?.readAt ?? now))) ago, not a current reading"))
            // Half a step back, not a grey: a remembered figure must not read with the
            // same confidence as a measured one, and must still be readable.
            if !live && !rolled && pct != nil { line.alphaValue = 0.72 }
            return line
        }
        let sess = gauge("clock", L("5 小时会话窗口", "5-hour window"), u?.sessionPct, u?.sessionResetsAt)
        let week = gauge("calendar", L("本周窗口", "Weekly window"), u?.weekPct, u?.weekResetsAt)

        var lines: [NSView] = [head, sess, week]
        // An address with no stored copy has to say that its first click goes through
        // a sign-in, or the browser popping up reads as the switch having failed.
        if !stored {
            let warn = NSTextField(labelWithString: L("首次切换需登录一次", "First switch signs in once"))
            warn.font = .systemFont(ofSize: 9)
            warn.textColor = .labelColor
            warn.lineBreakMode = .byTruncatingTail
            warn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(warn)
        }

        let row = NSStackView(views: lines)
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            // .leading alignment leaves each line at its natural width, which parks a
            // short one in the middle of the row. All of them span it instead — and the
            // gauges must, or their bars have no width to grow into.
            head.widthAnchor.constraint(equalTo: row.widthAnchor),
            sess.widthAnchor.constraint(equalTo: row.widthAnchor),
            week.widthAnchor.constraint(equalTo: row.widthAnchor),
        ])
        // The signed-in row also gets a green tick, in the gutter the panel already
        // leaves to the left of every address. ★ An overlay, NOT a column: it hangs
        // off the address's leading edge into that gutter (past this view's own
        // bounds, which don't clip), so no row moves and no row reserves space for
        // it — the earlier leading-tick column shoved every address 16pt in.
        if isCurrent {
            let tick = NSImageView()
            tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            tick.contentTintColor = Status.usageGreen
            tick.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tick)
            NSLayoutConstraint.activate([
                tick.widthAnchor.constraint(equalToConstant: 10),
                tick.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -3),
                tick.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            ])
        }
        var tip = isCurrent ? L("当前账号", "Current account")
                : stored ? L("切换到这个账号（不用重新登录）", "Switch to this account (no sign-in)")
                : command
        // The display name moved here from a second line: two accounts of one person
        // carry the same name, so it repeated itself down the panel while costing a
        // line the quota figures now use.
        if let n = entry.displayName, !n.isEmpty,
           !entry.email.lowercased().hasPrefix(n.lowercased()) {
            tip = "\(n) · \(tip)"
        }
        toolTip = tip
        applyFill()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }
    private func applyFill() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The current row lights up too. It has nothing to switch TO, but a row that
        // stays dead under the pointer reads as a rendering bug rather than as "this
        // is the one you're on" — and the cursor stays an arrow (see resetCursorRects)
        // so the highlight never promises a click that does nothing.
        let tint: CGColor? = hovering ? Theme.cardFillHover.cg(in: self) : nil
        fill.backgroundColor = tint
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !trackingInstalled else { return }
        trackingInstalled = true
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyFill() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyFill() }
    override func resetCursorRects() {
        if !isCurrent { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCurrent, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick()
    }

    /// Right-click. Forgetting drops the address from the book and deletes the stored
    /// credential copy; the CLI's own sign-in stays whatever it is. The current row
    /// still gets a menu, disabled, because a right-click that produces nothing at all
    /// reads as a broken one (and forgetting the current address would only have it
    /// written back on the next refresh).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(
            title: isCurrent ? L("当前账号不可移除", "Can't remove the current account")
                             : L("从列表移除", "Remove from list"),
            action: #selector(forget), keyEquivalent: "")
        item.target = self
        item.isEnabled = !isCurrent
        menu.addItem(item)
        return menu
    }

    @objc private func forget() {
        if Demo.enabled { Demo.forget(kind, email: entry.email) } else { AccountBook.forget(kind, email: entry.email) }
        onForgot()
    }
}

/// The one row that isn't an address. Same hover behaviour so it reads as part of the
/// list rather than as a footer.
private final class AddAccountRow: NSView {
    private let onTap: () -> Void
    private let fill = CALayer()
    private var hovering = false
    private var trackingInstalled = false

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        fill.cornerRadius = 6
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        glyph.contentTintColor = .labelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L("添加账号", "Add account"))
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        applyFill()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }
    private func applyFill() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let tint: CGColor? = hovering ? Theme.cardFillHover.cg(in: self) : nil
        fill.backgroundColor = tint
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !trackingInstalled else { return }
        trackingInstalled = true
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyFill() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyFill() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap()
    }
}

/// Copy-to-clipboard for a row's launch command. An NSButton rather than a custom
/// view so it eats its own click — the row underneath must not also fire and open a
/// session the user didn't ask for.
private final class CopyCommandButton: NSButton {
    private let onCopy: () -> Void

    init(onCopy: @escaping () -> Void) {
        self.onCopy = onCopy
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        toolTip = L("复制登录命令", "Copy sign-in command")
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func fire() {
        onCopy()
        // The only feedback available without a toast in this overlay: the glyph
        // confirms, then goes back so a second copy still looks like a fresh action.
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        }
    }
}

/// The panel's one network control: fetch the current figures of every remembered
/// Claude account that has a stored copy. Spins while a press is in flight; after a
/// press that could not fetch everything, the glyph says so until the next press.
private final class RefreshQuotaButton: NSView {
    private let onPress: () -> Void
    private let busy: Bool

    init(missed: Int, busy: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.busy = busy
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        let inner: NSView
        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .mini
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            inner = spinner
        } else {
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: missed > 0 ? "exclamationmark.arrow.circlepath" : "arrow.clockwise",
                                  accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
            glyph.contentTintColor = missed > 0 ? Status.modelHaiku : .labelColor
            inner = glyph
        }
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
            inner.centerXAnchor.constraint(equalTo: centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The tooltip is the disclosure: what is sent, where, and that only this
        // press does it. It has to say so because nothing else in the app reaches
        // the network on its own.
        toolTip = missed > 0
            ? L("有 \(missed) 个账号没查到 —— 它的凭证副本已失效或被服务器拒绝；切过去登录一次就会刷新",
                "\(missed) account(s) couldn't be fetched — the stored copy has expired or was refused; switching to it and signing in once refreshes it")
            : L("查其他账号现在的额度。把该账号副本里的登录 token 发给 api.anthropic.com —— 只在你按这个按钮、或点另一个账号切过去的时候，别的时候不联网",
                "Fetch the other accounts' current usage. The access token from each stored copy is sent to api.anthropic.com — only on this press, or when you click another account to switch to it; nothing reaches the network otherwise")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { if !busy { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseUp(with event: NSEvent) {
        guard !busy, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }
}

/// The dim behind an open account panel. Swallows the click that lands on it — the
/// list underneath is a backdrop while the panel is up, not a target.
private final class AccountScrim: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = accountScrimFill.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {}
}

// MARK: - HeaderStatsView
//
// The shared stats header — two rows. The first carries the identity and the
// counts (the app logo in the popover, the status-bucket count pill in the main
// window); the second is the QuotaTrio:
//
//     [logo]  /  [count pill]
//     本机     │  Claude  Max 20x │  Codex  Plus
//     CPU      │  clock   session │  clock  session
//     memory   │  cal.    weekly  │  cal.   weekly
//
// The machine card is clickable (Activity Monitor); an agent card is clickable
// when its account could be read, and opens a panel naming that account.
//
// A card is DROPPED (not hidden) when there's nothing behind it: no Codex on this
// machine is the common case, and the strip goes back to two cards filling the
// full width. Don't reintroduce a width-driven hide inside a card: the micro bars
// are the elastic column and they absorb a cramped header on their own.
final class HeaderStatsView: NSView {

    /// Fills the count pill when the list is empty (no status buckets to draw).
    var emptyText = "—"

    private let compact: Bool
    private let logoView = NSImageView()
    private let countPill = CountPill()   // every status bucket, one chip
    private let breakChip = BreakChip()   // "🍅 48:12", left of the counts (BreakReminder)
    /// The break-timer strip under the metric grid (BreakReminder.swift). Both hosts
    /// get it through here; it is zero-height until a chip click or the clock's 0.
    let breakPanel = BreakPanel()
    /// The strip opened or closed — the popover re-sizes, the window re-fits.
    var onLayoutChange: (() -> Void)?

    private let cpuLine = MetricLine(symbol: "cpu",
                                     accessibility: L("CPU 占用", "CPU usage"), style: .trio)
    private let memLine = MetricLine(symbol: "memorychip",
                                     accessibility: L("内存占用", "Memory usage"), style: .trio)
    private let claudeSessionLine = MetricLine(symbol: "clock",
                                               accessibility: L("会话配额", "Session quota"), style: .trio)
    private let claudeWeekLine = MetricLine(symbol: "calendar",
                                            accessibility: L("本周配额", "Weekly quota"), style: .trio)
    private let codexSessionLine = MetricLine(symbol: "clock",
                                              accessibility: L("会话配额", "Session quota"), style: .trio)
    private let codexWeekLine = MetricLine(symbol: "calendar",
                                           accessibility: L("本周配额", "Weekly quota"), style: .trio)

    // The machine card's name is deliberately NOT tinted: the design gives it the
    // CPU blue from its own palette, and this app has no such token — inventing a
    // second unowned brand color to decorate the one card that has no brand is a
    // worse trade than a quiet gray.
    private lazy var systemCard = MetricCard(top: cpuLine, bottom: memLine,
                                             identity: L("本机", "This Mac"), accent: nil)
    private lazy var claudeCard = MetricCard(top: claudeSessionLine, bottom: claudeWeekLine,
                                             identity: "Claude", accent: Status.claudeOrange)
    private lazy var codexCard = MetricCard(top: codexSessionLine, bottom: codexWeekLine,
                                            identity: "Codex", accent: codexMint)
    private let trio = QuotaTrio()

    /// Which accounts the two agent cards are currently describing — kept so a
    /// click knows whether it has a panel to open, and so an open panel can be
    /// refreshed (or dismissed) when the account underneath changes.
    private var accounts: [QuotaTrio.Slot: AgentAccount] = [:]
    /// Slots whose panel may open: signed in, OR the book remembers addresses for
    /// that CLI. ★ The second half is the whole point of remembering — a CLI that is
    /// signed out (or whose credential file is unreadable) is exactly when the user
    /// needs the panel to get an account BACK. Gating on the live account alone
    /// locked them out at the one moment it mattered (2026-09-04).
    private var openable: Set<QuotaTrio.Slot> = []

    // ---- open account panel ----
    private var openSlot: QuotaTrio.Slot?
    private var scrim: AccountScrim?
    private var panel: AccountPanel?
    private var clickMonitor: Any?

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        systemCard.clickable = true
        systemCard.toolTip = L("打开活动监视器", "Open Activity Monitor")
        trio.onClick = { [weak self] slot in self?.activate(slot) }
        addSubview(trio)
        addSubview(breakPanel)
        breakPanel.onLayoutChange = { [weak self] in self?.onLayoutChange?() }
        breakPanel.onAction = { [weak self] in self?.breakChip.refresh() }
        breakChip.onClick = { [weak self] in self?.breakPanel.toggle() }

        if compact {
            // Popover: the app logo anchors the row; the cards trail it. The row
            // stays visible without a usage snapshot (the logo holds it up).
            logoView.image = NSApp.applicationIconImage
            logoView.imageScaling = .scaleProportionallyUpOrDown
            logoView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(logoView)
            addSubview(countPill)
            addSubview(breakChip)
            NSLayoutConstraint.activate([
                logoView.widthAnchor.constraint(equalToConstant: 20),
                logoView.heightAnchor.constraint(equalToConstant: 20),
                logoView.leadingAnchor.constraint(equalTo: leadingAnchor),
                logoView.topAnchor.constraint(equalTo: topAnchor),

                // Counts sit at the far right of the identity row, opposite the logo.
                countPill.trailingAnchor.constraint(equalTo: trailingAnchor),
                countPill.centerYAnchor.constraint(equalTo: logoView.centerYAnchor),
                countPill.leadingAnchor.constraint(greaterThanOrEqualTo: logoView.trailingAnchor,
                                                   constant: 10),
                breakChip.trailingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: -8),
                breakChip.centerYAnchor.constraint(equalTo: countPill.centerYAnchor),
                breakChip.leadingAnchor.constraint(greaterThanOrEqualTo: logoView.trailingAnchor,
                                                   constant: 10),

                trio.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 10),
            ])
        } else {
            // Main window: the strip IS the header. Its logo, wordmark and count pill
            // all live in the WINDOW's title row (MainWindowController owns them), so
            // there's no identity row to build here — putting a second one in would
            // just repeat what sits 10pt above it.
            NSLayoutConstraint.activate([
                trio.topAnchor.constraint(equalTo: topAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            // The strip owns its own row and spans the full width. Don't move it back
            // up beside the logo/count pill: at popover width that squeezes the cards
            // until the bars collapse to nothing.
            trio.leadingAnchor.constraint(equalTo: leadingAnchor),
            trio.trailingAnchor.constraint(equalTo: trailingAnchor),
            // No hairline under the cards (removed 2026-09-10): the strip ends where
            // the cards end, and the host supplies the same 8pt the list puts between
            // projects — so the header reads as one more card in the stack, not a
            // separate band ruled off from it.
            breakPanel.topAnchor.constraint(equalTo: trio.bottomAnchor),
            breakPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            breakPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            breakPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Opening a bundle through LaunchServices — deliberately NOT a spawn. The app
    /// asks for accessibility and nothing else (docs/permissions.md), and handing
    /// a system app to LaunchServices needs no entitlement and triggers no prompt.
    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func update(rows: [SessionRow],
                usage: UsageSnapshot?,
                codexUsage: UsageSnapshot? = nil,
                claudeAccount: AgentAccount? = nil,
                codexAccount: AgentAccount? = nil,
                claudeRemembered: Bool = false,
                codexRemembered: Bool = false) {
        // Popover only — the main window's count pill rides in its title row
        // instead, so MainWindowController refreshes it itself.
        if compact {
            countPill.configure(rows: rows, placeholder: emptyText)
            breakChip.refresh()
        }
        breakPanel.refresh()

        // ---- this machine ----
        // CPU's footnote is "how many cores are busy" (pct × cores ÷ 100) — the one
        // thing a single normalized percentage throws away, and it's free: we
        // already have both numbers. Memory's is plain used GB. Neither is a second
        // measurement; they're the same figure restated as an absolute, which is
        // what lets them sit in the same column as the quota countdowns.
        // A subview's tooltip WINS over its ancestor's, so both of these have to
        // carry the "you can click this" hint themselves — the card's own tooltip
        // never gets a chance to show while the pointer is over a line.
        let clickHint = L("　·　点击打开活动监视器", "　·　Click to open Activity Monitor")
        if let l = SystemMonitor.shared.latest {
            let busy = Self.fmtCores(pct: l.cpuPct, cores: l.cores).dropLast()   // "3.4c" → "3.4"
            cpuLine.configure(pct: l.cpuPct,
                              foot: Self.fmtCores(pct: l.cpuPct, cores: l.cores),
                              tooltip: L("\(l.cores) 个核心中约 \(busy) 个在忙", "About \(busy) of \(l.cores) cores busy")
                                       + clickHint)
            memLine.configure(pct: l.memPct,
                              foot: Self.fmtGB(l.memUsedBytes),
                              tooltip: L("已用 \(Self.fmtGB(l.memUsedBytes)) / 共 \(Self.fmtGB(l.memTotalBytes))",
                                         "\(Self.fmtGB(l.memUsedBytes)) used of \(Self.fmtGB(l.memTotalBytes))")
                                       + clickHint)
        } else {
            cpuLine.configure(pct: nil, foot: "", tooltip: clickHint)
            memLine.configure(pct: nil, foot: "", tooltip: clickHint)
        }
        systemCard.setPlan(SystemMonitor.shared.latest.map { "\($0.cores)C" })

        // ---- the two subscriptions ----
        // A card earns its place with EITHER a quota snapshot or an account: quota
        // with no account is the normal state before the config file is read, and an
        // account with no quota is what a non-subscription plan looks like (its
        // lines then read "—", which MetricLine already draws).
        accounts = [:]
        if let a = claudeAccount { accounts[.claude] = a }
        if let a = codexAccount { accounts[.codex] = a }
        openable = []
        if claudeAccount != nil || claudeRemembered { openable.insert(.claude) }
        if codexAccount != nil || codexRemembered { openable.insert(.codex) }

        fill(session: claudeSessionLine, week: claudeWeekLine, usage: usage)
        fill(session: codexSessionLine, week: codexWeekLine, usage: codexUsage)
        claudeCard.setPlan(claudeAccount?.plan)
        codexCard.setPlan(codexAccount?.plan)
        // Only ever true for Claude: Codex's quota has no endpoint to ask.
        claudeCard.fetching = usage?.fetching == true
        codexCard.fetching = codexUsage?.fetching == true
        claudeCard.clickable = openable.contains(.claude)
        codexCard.clickable = openable.contains(.codex)

        var slots: [(QuotaTrio.Slot, MetricCard)] = [(.machine, systemCard)]
        if Self.shows(usage, claudeAccount, claudeRemembered) { slots.append((.claude, claudeCard)) }
        if Self.shows(codexUsage, codexAccount, codexRemembered) { slots.append((.codex, codexCard)) }
        trio.setSlots(slots)

        // The CLI behind an open panel can drop out of the strip entirely (nothing
        // signed in AND nothing remembered); a panel with no card under it is worse
        // than no panel. A mere sign-out keeps it open — the panel still lists the
        // remembered addresses, which is how the user signs back in.
        if let s = openSlot, !openable.contains(s) { dismissPanel() }
    }

    /// `remembered` is why a logged-OUT CLI still shows a card: the panel is the only
    /// way back to the addresses the book knows, and it hangs off this card.
    private static func shows(_ usage: UsageSnapshot?, _ account: AgentAccount?,
                              _ remembered: Bool) -> Bool {
        usage?.sessionPct != nil || usage?.weekPct != nil || account != nil || remembered
    }

    private func fill(session: MetricLine, week: MetricLine, usage: UsageSnapshot?) {
        // Carried over from before an account switch — this account's own last known
        // figures, not a measurement of right now. Said twice on purpose: the dimming
        // is what catches the eye, the sentence is what answers "dimmed why".
        let stale = usage.map { !$0.live } ?? false
        let note = stale ? L("　·　这个账号记着的数字，不是刚测的",
                             "　·　remembered for this account, not a current reading") : ""
        session.configure(pct: usage?.sessionPct,
                          foot: usage?.sessionResetsAt.flatMap { Self.fmtResetIn($0) } ?? unknownCountdown,
                          tooltip: L("5 小时会话窗口", "5-hour session window") + note,
                          stale: stale)
        let wk = usage?.weekResetsAt.flatMap { Self.weekRemaining($0) }
        week.configure(pct: usage?.weekPct, foot: wk?.short ?? unknownCountdown,
                       tooltip: wk.map { $0.detail + note } ?? (note.isEmpty ? nil : note),
                       stale: stale)
    }

    // ---- account panel ----

    private func activate(_ slot: QuotaTrio.Slot) {
        guard slot != .machine else { openActivityMonitor(); return }
        if openSlot == slot { dismissPanel() } else { showPanel(slot) }
    }

    private func showPanel(_ slot: QuotaTrio.Slot) {
        teardown()
        let card: MetricCard = slot == .claude ? claudeCard : codexCard
        guard openable.contains(slot), let host = superview else { return }

        let kind: AgentKind = slot == .claude ? .claude : .codex
        let scrim = AccountScrim()
        let panel = AccountPanel(kind: kind,
                                 title: slot == .claude ? "Claude" : "Codex",
                                 accent: slot == .claude ? Status.claudeOrange : codexMint)
        // Dismiss BEFORE launching: runInTerminal blocks on osascript, and an overlay
        // still standing over a frozen window looks like the click hung.
        panel.onRun = { [weak self] cmd in
            self?.dismissPanel()
            (NSApp.delegate as? AppController)?.runInTerminal(cmd)
        }
        // Hosted in the header's OWN superview — the same container that holds the
        // session list — so the panel floats over the list instead of being clipped
        // by the header, and nothing in the list moves to make room for it.
        host.addSubview(scrim)
        scrim.addSubview(panel)
        // Aligned under the card it belongs to, but the panel is wider than a card,
        // so the ≤ against the trailing edge has to win — otherwise the rightmost
        // card's panel hangs off the window.
        //
        // ★ Below windowSizeStayPut (500), not .defaultHigh. AppKit holds a window's
        // size at exactly 500, so any wish above that is granted by GROWING THE
        // WINDOW: with Codex the rightmost card and this at 750, opening its panel
        // dragged the whole main window wider to fit the panel under the card. At
        // 499 the panel slides left instead, which is what the ≤ above was for.
        let aligned = panel.leadingAnchor.constraint(equalTo: card.leadingAnchor)
        aligned.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        // Same width as the card, live: the card is the focused (wide) one while its
        // panel is open, and if the window is resized both move together. Just below
        // required so a card squeezed under the panel's hard content minimum
        // (fixed gauge columns) lets the panel overhang rather than breaking layout.
        let sameWidth = panel.widthAnchor.constraint(equalTo: card.widthAnchor)
        sameWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sameWidth,
            scrim.topAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            panel.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 6),
            aligned,
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: scrim.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: scrim.trailingAnchor, constant: -8),
        ])
        self.scrim = scrim
        self.panel = panel
        openSlot = slot
        trio.pinned = slot

        scrim.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            scrim.animator().alphaValue = 1
        }

        // The scrim only covers what's BELOW the header; a click on the header
        // itself (or on the window's title row) has to close the panel too. The
        // monitor doesn't swallow the event — a click on another agent card still
        // reaches QuotaTrio, which is what makes the two panels swap directly.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] ev in
            guard let self, let win = self.window, ev.window === win else { return ev }
            if self.trio.bounds.contains(self.trio.convert(ev.locationInWindow, from: nil)) {
                return ev   // a card: let QuotaTrio toggle/swap
            }
            // ⚠️ The panel is a CHILD of the scrim, so without this test its own rows
            // fall into the "clicked the scrim" branch below and get swallowed after
            // the panel has already been torn down — every row would be dead.
            if let p = self.panel,
               p.bounds.contains(p.convert(ev.locationInWindow, from: nil)) {
                return ev
            }
            let onScrim = self.scrim.map { $0.bounds.contains($0.convert(ev.locationInWindow, from: nil)) } ?? false
            self.dismissPanel()
            // ⚠️ The scrim's own click has to be SWALLOWED here, not passed on: the
            // dismissal removes the scrim, so an event let through would then hit
            // whichever session row was underneath and jump to it.
            return onScrim ? nil : ev
        }
    }

    /// Everything except the pin, so swapping from one panel to the other moves the
    /// focus once instead of springing back through the resting widths on the way.
    private func teardown() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        scrim?.removeFromSuperview()   // takes the panel with it
        scrim = nil
        panel = nil
        openSlot = nil
    }

    private func dismissPanel() {
        teardown()
        trio.pinned = nil
    }

    /// The popover tears its content down on every close, and the monitor would
    /// outlive it — a stray global handler holding a dead view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissPanel() }
    }

    // ---- footnote formatters ----
    //
    // All the footnotes are FIVE CHARACTERS WIDE in a monospaced face, and that's
    // not cosmetic: it's the only reason the micro bars in a card share a right
    // edge. A bare "12m" or "5d" pulls its own row's bar out of column with the
    // others, which is exactly the bug this layout was rebuilt to fix. Any new
    // footnote format has to hold the width — including at its boundaries.

    /// "3.4c" — 34% of ten cores. One decimal always, so 9→10 cores doesn't jump
    /// a character.
    private static func fmtCores(pct: Int, cores: Int) -> String {
        String(format: "%.1fc", Double(pct) * Double(cores) / 100)
    }

    /// "9.4G" / "15.9G" — htop's convention: one decimal, single-letter unit, no
    /// space. Drops to zero decimals past 100G so the field can't overflow.
    private static func fmtGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0fG", gb) : String(format: "%.1fG", gb)
    }

    /// "3h20m" / "0h12m" — the session window is five hours, so the hour figure is
    /// always one digit and the string is always five characters.
    private static func fmtResetIn(_ epoch: Double) -> String? { resetCountdown(epoch) }

    /// Weekly countdown. `short` is the five-character figure beside the calendar
    /// glyph — "5d02h" over a day out, "9h24m" under one; `detail` is the hover
    /// tooltip that spells the same thing out in words.
    private static func weekRemaining(_ epoch: Double) -> (short: String, detail: String)? {
        let s = Int(epoch - Date().timeIntervalSince1970)
        if s <= 0 { return (resetCountdown(0), L("本周配额即将重置", "Weekly quota resetting")) }
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days >= 1 {
            return (resetCountdown(epoch),
                    L("本周配额 \(days) 天 \(hours) 小时后重置",
                      "Weekly quota resets in \(days)d \(hours)h"))
        }
        return (resetCountdown(epoch),
                L("本周配额 \(hours) 小时 \(mins) 分后重置",
                  "Weekly quota resets in \(hours)h \(mins)m"))
    }
}
