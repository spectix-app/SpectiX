import Cocoa

// MARK: - The menu-bar pill (改这块前必读)
//
// ★ NOTHING HERE MAY WRITE A PROPERTY OF THE STATUS-BAR BUTTON PER FRAME.
//
// This used to be an NSImage handed to `statusItem.button.image` by a 0.1s timer, so
// the working dot could breathe. On macOS 26 every write to an NSStatusBarButton
// property registers a KVO dependency pair inside AppKit that is never released —
// measured 2026-09-15 on a plain status item: +5.0 live objects per `.image`, +4.0
// per `.title`, +4.0 per `.imagePosition`, and +160 per width change. The SAME writes
// on an ordinary NSButton leak nothing, so it is AppKit's bug, not ours, and there is
// no way to flush it. At 10 Hz that was ~13 objects per frame ≈ 1 GB/day; a 22-hour
// session was carrying 1.25M each of NSKeyValueDependency, NSKeyValueDependencyContext,
// __NSMallocBlock__ and __NSExactBlockVariable__.
//
// So the pill is a VIEW hosted inside the button, and the breathing is a CALayer
// animation the window server plays on its own. The button's own properties are
// written once, at setup. The bed and the figures repaint only when the counts
// actually change (or the palette does), which is at most once per 2.5s poll and
// usually never. `tools/menubar-leak-probe.sh` is the check — nothing else can see
// this regression, it compiles and runs and merely eats memory for days.
//
// Look — the capsule's style (glass bed, Status.accent dots and figures, the hollow
// `await` ring) is documented in docs/design-system.md; it is deliberately identical
// to what the image renderer drew, this change is about how it gets on screen.

/// One "● n" segment of the capsule.
struct MenuSeg: Equatable {
    let count: Int          // number to draw next to the dot
    let status: String      // dot + figure share one color, derived from the bed at draw time
    let drawNum: Bool       // false → bare dot (the no-session placeholder)
    let pulse: Bool         // working: this dot breathes (the one animated layer)
}

final class MenuCapsuleView: NSView {
    private let capH: CGFloat = 16      // capsule height (menu bar gives ~22pt)
    private let imgH: CGFloat = 18      // view height, capsule centered with 1pt breathing room
    private let padH: CGFloat = 7       // capsule inner horizontal padding
    private let dotD: CGFloat = 6       // status dot diameter
    private let dotGap: CGFloat = 4     // dot → figure
    private let segGap: CGFloat = 7     // segment → segment

    /// The breathing dot. A layer rather than a redrawn frame — see the header.
    private let pulseDot = CALayer()
    private var paletteObserver: NSObjectProtocol?

    private(set) var segs: [MenuSeg] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 18))
        wantsLayer = true
        pulseDot.isHidden = true
        pulseDot.cornerRadius = dotD / 2
        pulseDot.cornerCurve = .continuous
        layer?.addSublayer(pulseDot)

        // A user-edited status color (Settings → 配色) leaves the COUNTS untouched, so
        // `apply` would skip the repaint and the pill would keep yesterday's palette
        // until a session started or stopped. Same subscription the list's dots use.
        paletteObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
            self?.layoutPulse()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let o = paletteObserver { NotificationCenter.default.removeObserver(o) } }

    // Clicks belong to the button underneath (it owns target/action and the popover
    // toggle); this view is paint, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // The menu bar always follows the SYSTEM appearance, and it can flip while we sit
    // there — the bed and every accent are picked from it at draw time.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        layoutPulse()
    }

    /// Width this set of segments needs. The status item's length is set from it —
    /// only when it changes, because a width write is the single most expensive leak
    /// on the old code path (+160 objects).
    func width(for segs: [MenuSeg]) -> CGFloat {
        var content: CGFloat = 0
        for (i, s) in segs.enumerated() {
            if i > 0 { content += segGap }
            content += dotD
            if let ns = figure(s) { content += dotGap + ceil(ns.size().width) }
        }
        return ceil(content + padH * 2)
    }

    /// New counts. A no-op when nothing changed, which is the common case: the poll
    /// runs every 2.5s and the numbers move maybe a few times an hour.
    func apply(_ next: [MenuSeg]) -> Bool {
        guard next != segs else { return false }
        segs = next
        needsDisplay = true
        layoutPulse()
        return true
    }

    // MARK: Drawing

    private func figure(_ s: MenuSeg) -> NSAttributedString? {
        guard s.drawNum else { return nil }
        return NSAttributedString(string: "\(s.count)", attributes: [
            .font: Theme.roundedMono(11, .bold),
            .foregroundColor: Status.accent(s.status),
        ])
    }

    private var isDark: Bool {
        (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua) == .darkAqua
    }

    /// Left edge of the capsule inside the (wider, system-padded) button.
    private var originX: CGFloat { ((bounds.width - width(for: segs)) / 2).rounded() }

    /// x of each segment's dot slot, in view coordinates.
    private func dotOrigins() -> [CGFloat] {
        var xs: [CGFloat] = []
        var x = originX + padH
        for (i, s) in segs.enumerated() {
            if i > 0 { x += segGap }
            xs.append(x)
            x += dotD
            if let ns = figure(s) { x += dotGap + ceil(ns.size().width) }
        }
        return xs
    }

    override func draw(_ dirtyRect: NSRect) {
        // The bed is a NEAR-TRANSPARENT wash, so the translucent menu bar (and the
        // wallpaper behind it) shows through — the chosen look, see docs/design-system.md
        // (T167 tried an opaque white bed and it was reverted 2026-08-09).
        let dark = isDark
        let bed    = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.06)
        let stroke = dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.10)

        let capRect = NSRect(x: originX + 0.5, y: (bounds.height - capH) / 2,
                             width: width(for: segs) - 1, height: capH)
        let path = NSBezierPath(roundedRect: capRect, xRadius: capH / 2, yRadius: capH / 2)
        bed.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = 1; path.stroke()

        let midY = bounds.height / 2
        let xs = dotOrigins()
        for (i, s) in segs.enumerated() {
            let x = xs[i]
            let color = Status.accent(s.status)
            // The breathing dot is the layer above; leave its slot empty so the two
            // never double-paint.
            if !s.pulse {
                color.setFill()
                let oval = NSRect(x: x, y: midY - dotD / 2, width: dotD, height: dotD)
                if s.status == "await" {
                    // Hollow like its row dot; no gap at 6pt.
                    let ring = NSBezierPath(ovalIn: oval.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    color.setStroke()
                    ring.stroke()
                } else {
                    NSBezierPath(ovalIn: oval).fill()
                }
            }
            if let ns = figure(s) {
                let nsz = ns.size()
                ns.draw(at: NSPoint(x: x + dotD + dotGap, y: midY - nsz.height / 2))
            }
        }
    }

    // MARK: The one animation

    /// Park the breathing dot over its slot and (re)start its loop.
    ///
    /// It breathes exactly like the list's compact dots (Components `buildBreath`):
    /// scale 0.5→1 and alpha 0.45→1 on a 1.4s ease-in-out swing that auto-reverses.
    /// `beginTime` is Motion.epoch — the origin every CALayer loop in the app anchors
    /// to — so the menu bar inhales in unison with the dropdown instead of drifting.
    private func layoutPulse() {
        guard let idx = segs.firstIndex(where: { $0.pulse }) else {
            pulseDot.isHidden = true
            pulseDot.removeAnimation(forKey: "breath")
            return
        }
        let x = dotOrigins()[idx]
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit move/fade on a reposition
        pulseDot.isHidden = false
        pulseDot.frame = NSRect(x: x, y: bounds.height / 2 - dotD / 2, width: dotD, height: dotD)
        pulseDot.backgroundColor = Status.accent(segs[idx].status).cgColor
        CATransaction.commit()

        // Re-adding an identical epoch-anchored loop would rejoin the same phase, but
        // it still costs a layer transaction on every counts change; leave a running
        // loop alone.
        guard pulseDot.animation(forKey: "breath") == nil else { return }

        let g = CAAnimationGroup()
        g.duration = 1.4
        g.repeatCount = .infinity
        g.autoreverses = true
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.beginTime = Motion.epoch

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5; scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45; fade.toValue = 1.0
        g.animations = [scale, fade]
        pulseDot.add(g, forKey: "breath")
    }
}
