import Cocoa

// Renders the header's quota strip (the 本机 / Claude / Codex columns) offscreen to PNG.
//
// Why: the strip's bugs are all "only visible" ones — a bar squeezed to a dot, a slot
// clipping "100%", a footnote drifting off its column, a card showing one account's
// figures under another's name — and this machine cannot screenshot the real window
// (see tools/panel-preview/main.swift). This is the REAL HeaderStatsView fed demo-mode
// figures, at the widths the two hosts actually give it.
//
// The four account states are driven through `HeaderStatsView.update` with exactly the
// snapshots AppController passes it — `live == false` IS what the app sends after a
// switch, `fetching` IS what it sends while the request is in flight — so a state that
// renders here is the state the app draws. Nothing is faked at the view layer.
//
// Same blind spots as the other previews: no blur behind it, and no mid-animation
// frames — the fetching card shows its spinner's first frame, not its spin. The one
// animation that is waited out is the hover re-deal, because its whole subject IS the
// width it ends at.

// Demo figures come from the REGISTRATION domain: in memory, never written. Assigning
// `AppSettings.demoMode` instead PERSISTS it, and for a bare binary that lands in a
// defaults domain named after the process — "render" — where it outlives the run and
// silently seeds the next one (found sitting there 2026-09-14). A renderer must not
// leave state behind; two runs of it have to produce the same picture.
UserDefaults.standard.register(defaults: ["demoMode": true])

Demo.pin(elapsed: 70)
let rows = Demo.rows()

/// Host widths, minus 2 × Theme.pad, are what the strip actually gets. 384 is the
/// popover's and the window's shared minimum; 468 is the user's own main window.
let narrowHost: CGFloat = 384
let realHost: CGFloat = 468

func exhausted(_ u: UsageSnapshot) -> UsageSnapshot {
    var u = u; u.sessionPct = 100; u.weekPct = 100; return u
}
func remembered(_ u: UsageSnapshot) -> UsageSnapshot { var u = u; u.live = false; return u }
func inFlight(_ u: UsageSnapshot) -> UsageSnapshot { var u = u; u.fetching = true; return u }
/// Codex hands out windows weeks long; the demo's own figures never go past a few days,
/// so the seven-character countdown that used to overflow the slot ("26d/09h") has to be
/// asked for on purpose or no sheet would ever show it.
func farOff(_ u: UsageSnapshot) -> UsageSnapshot {
    var u = u
    let now = Date().timeIntervalSince1970
    u.sessionResetsAt = now + 26 * 86_400 + 9 * 3600
    u.weekResetsAt = now + 12 * 86_400
    return u
}

/// One rendered strip.
struct Shot {
    var label: String
    var hostWidth: CGFloat = realHost
    var compact = true
    var hover: QuotaTrio.Slot?
    var claude = Demo.usage()
    var codex = Demo.codexUsage()
    /// false = SystemMonitor has never sampled — the machine card's own "no reading"
    /// state, which CPU is always in for one poll (it is a rate, so the first sample
    /// only sets a baseline). Reached by turning demo mode off for that one update,
    /// since demo substitutes for the real reading.
    var machineReads = true
}

let shots: [Shot] = [
    Shot(label: "popover \(Int(narrowHost))pt", hostWidth: narrowHost),
    Shot(label: "popover \(Int(realHost))pt"),
    Shot(label: "popover \(Int(realHost))pt · hover Claude", hover: .claude),
    Shot(label: "window \(Int(realHost))pt", compact: false),
    // The four account states T302 asks for, at the width the user actually runs.
    Shot(label: "quota exhausted (100%)",
         claude: exhausted(Demo.usage()), codex: exhausted(Demo.codexUsage())),
    Shot(label: "remembered, not measured (after a switch)",
         claude: remembered(Demo.usage()), codex: remembered(Demo.codexUsage())),
    Shot(label: "fetching (request in flight)",
         claude: inFlight(Demo.usage()), codex: Demo.codexUsage()),
    Shot(label: "signed in, no reading yet",
         claude: UsageSnapshot(), codex: UsageSnapshot()),
    Shot(label: "countdown weeks out (Codex)",
         claude: Demo.usage(), codex: farOff(Demo.codexUsage())),
    Shot(label: "machine: no reading yet (first poll)", machineReads: false),
]

/// Slot overflows found while rendering, reported together at the end where they
/// cannot scroll past. Declared before `render` because top-level code runs in order.
var overflows: [String] = []

func render(_ shot: Shot, look: NSAppearance) -> NSBitmapImageRep? {
    let labelH: CGFloat = 20
    let pad = Theme.pad
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: shot.hostWidth, height: 200),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = look
    let host = NSView(frame: win.contentRect(forFrameRect: win.frame))
    win.contentView = host
    host.wantsLayer = true
    let header = HeaderStatsView(compact: shot.compact)
    host.addSubview(header)
    NSLayoutConstraint.activate([
        header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
        header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad),
        header.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
    ])
    // Written and then REMOVED rather than left at false: removing restores the
    // registered value, so nothing of this shot survives into the next one or onto
    // disk. (register() alone can't be overridden — a real value has to shadow it.)
    if !shot.machineReads { UserDefaults.standard.set(false, forKey: "demoMode") }
    header.update(rows: rows, usage: shot.claude, codexUsage: shot.codex,
                  claudeAccount: Demo.account(.claude), codexAccount: Demo.account(.codex),
                  claudeRemembered: true, codexRemembered: true)
    if !shot.machineReads { UserDefaults.standard.removeObject(forKey: "demoMode") }

    host.layoutSubtreeIfNeeded()
    let h = header.fittingSize.height + 12 + 12
    win.setContentSize(NSSize(width: shot.hostWidth, height: h + labelH))
    host.frame = NSRect(x: 0, y: 0, width: shot.hostWidth, height: h + labelH)
    settle(host)
    look.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = Theme.baseFill.cgColor }

    // Hover the way the app gets it: a synthetic mouseMoved over the column, through
    // the strip's own tracking (QuotaTrio.mouseMoved), so what renders is what it does.
    if let hover = shot.hover, let trio = findTrio(header) {
        let cards = trio.subviews.compactMap { $0 as? MetricCard }
        let idx: Int = { switch hover { case .machine: return 0; case .claude: return 1; case .codex: return 2 } }()
        if idx < cards.count {
            let c = cards[idx]
            let p = c.convert(NSPoint(x: c.bounds.midX, y: c.bounds.midY), to: nil)
            if let ev = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [],
                                           timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 0, pressure: 0) {
                trio.mouseMoved(with: ev)
            }
        }
        // ★ Let the 3:1 re-deal FINISH. QuotaTrio animates the column widths over
        // QuotaTrio.duration (200ms) through the animator proxy, so capturing straight
        // after the event gives frame 0 — three equal columns, identical to the resting
        // shot. That is not a blind spot, it is a picture that says hover does nothing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        settle(host)
    }
    var clipped: [String] = []
    clippedLabels(header, into: &clipped)
    for c in clipped { overflows.append("  ✘ \(shot.label): \(c)") }

    let caption = NSTextField(labelWithString: shot.label)
    caption.font = .systemFont(ofSize: 11, weight: .semibold)
    caption.textColor = .secondaryLabelColor
    caption.frame = NSRect(x: pad, y: h + 2, width: shot.hostWidth, height: 16)
    host.addSubview(caption)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// QuotaTrio deals its column widths from inside layout(), which schedules another
/// pass; the app's run loop delivers that one, offscreen nothing does. Without this the
/// three columns stay 0×0 and print on top of each other at x=0 — a picture that looks
/// like a broken app and is only a half-laid-out preview (2026-09-11).
func settle(_ host: NSView) {
    for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        if let t = findTrio(host) { t.needsLayout = true; t.layoutSubtreeIfNeeded() }
        host.layoutSubtreeIfNeeded()
    }
}

func findTrio(_ v: NSView) -> QuotaTrio? {
    if let t = v as? QuotaTrio { return t }
    for s in v.subviews { if let t = findTrio(s) { return t } }
    return nil
}

/// Every label in the strip sits in a slot of a width someone chose, and a string that
/// outgrows its slot does NOT simply get cut: the fields resist compression, so the
/// slot's own width constraint is what Auto Layout breaks, and the label then eats the
/// one elastic thing beside it — its row's bar, which ends short of the column the
/// other three share. That damage is subtle in a picture and obvious in a number, so
/// the sheet is not the only output: this walks what was actually laid out and names
/// anything wider than the box it was given.
///
/// Generic on purpose — it compares intrinsic width against laid-out width for every
/// NSTextField in the header, so a slot nobody thought to add a case for is still
/// covered. Both overflows this caught on the day it was written ("100%" at 32 in a 25
/// slot, "26d/09h" at 41.5 in a 36) were found by measuring, not by looking.
func clippedLabels(_ v: NSView, into out: inout [String]) {
    if let f = v as? NSTextField, !f.stringValue.isEmpty, f.frame.width > 0 {
        let want = f.intrinsicContentSize.width
        if want > f.frame.width + 0.5 {
            out.append(String(format: "\"%@\" wants %.1fpt, slot is %.1f",
                              f.stringValue, want, f.frame.width))
        }
    }
    for s in v.subviews { clippedLabels(s, into: &out) }
}

func sheet(_ reps: [NSBitmapImageRep]) -> Data? {
    let gap = 4
    let w = reps.map(\.pixelsWide).max() ?? 0
    let h = reps.reduce(0) { $0 + $1.pixelsHigh } + gap * (reps.count - 1)
    guard w > 0, h > 0,
          let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
    let cg = ctx.cgContext
    cg.setFillColor(NSColor.systemPink.cgColor)   // gutter: clearly not part of any theme
    cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
    var y = h
    for r in reps {
        y -= r.pixelsHigh
        if let img = r.cgImage { cg.draw(img, in: CGRect(x: 0, y: y, width: r.pixelsWide, height: r.pixelsHigh)) }
        y -= gap
    }
    ctx.flushGraphics()
    return out.representation(using: .png, properties: [:])
}

NSApplication.shared.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for spec in ThemeRegistry.all {
    Theme.apply(spec.id)
    for (lookName, lookID) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        guard let look = NSAppearance(named: lookID) else { continue }
        // App-wide, the way the app's own light/dark override does it: forcing only the
        // window resolves some colours in the system's appearance instead (see
        // tools/row-preview/main.swift for the clay pill that exposed this).
        NSApp.appearance = look
        let reps = shots.compactMap { render($0, look: look) }
        let path = "\(outDir)/\(spec.id)-\(lookName).png"
        try? sheet(reps)?.write(to: URL(fileURLWithPath: path))
        print("\(spec.id) \(lookName): \(reps.count) shots → \(path)")
    }
}

// The part that does not need eyes. A slot overflow is the one failure here that is
// cheaper to read than to see, so it gets said in words and it fails the run.
print("")
if overflows.isEmpty {
    print("✅ every label fits its slot")
} else {
    print("❌ \(overflows.count) label(s) wider than the slot they were given:")
    // De-duplicated: the same string overflows on every theme and appearance, and four
    // copies of one fault reads as four faults.
    for line in Array(Set(overflows)).sorted() { print(line) }
    print("   A label that does not fit takes the width out of its own row's bar —")
    print("   see docs/row-display.md 「两个槽都放不下自己最长的那个值」.")
    exit(1)
}
