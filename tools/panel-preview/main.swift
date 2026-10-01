import Cocoa

// Renders the 效能 panel offscreen to PNG, one file per time range.
//
// Why this exists (改这个面板前先跑一次): this machine can neither screen-record nor
// drive the UI — `screencapture` fails with "could not create image from display" and
// osascript keystrokes return 1002 — and the stats window only opens from the menu bar.
// So "just open it and look" is not available, and a panel bug that is only visible
// (a legend naming a line that was never stroked, an axis label pushed off the card, a
// curve that renders as one lone dot) ships unnoticed: nothing throws, no test fails.
// Two such bugs shipped exactly that way before this harness was made permanent.
//
// What it CAN show: layout, colours, wording, line shapes, axis ticks, empty states.
// What it CANNOT: the NSVisualEffectView blur underneath (so the background reads as a
// raw gradient rather than the dark material you see in the app) and CALayer animations
// mid-flight — `cacheDisplay` draws model values, not the presentation layer.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let store = StatsStore(); store.reload()
let impact = ImpactStore(); impact.reload()

// Both appearances, every time. The neon palette behaves completely differently on a
// light bed than a dark one — the accents wash out and the text flips to black — and
// rendering only whichever one this Mac happens to be set to is how a light-mode
// regression shipped unseen.
let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

for (lookName, lookID) in looks {
for range in TimeRange.allCases {
    let period = impact.impact(range: range, usage: store.events)
    let trend = impact.trend(range: range)
    let rate = store.rateSeries(range)

    let panel = ImpactPanel()
    panel.translatesAutoresizingMaskIntoConstraints = false
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 1200))
    host.appearance = NSAppearance(named: lookID)
    // Paint the window's own bed. Without it everything OUTSIDE the neon card (the five
    // metric rows, which follow the system label colour) renders black-on-black under a
    // light appearance and looks broken when it is not.
    host.wantsLayer = true
    NSAppearance(named: lookID)?.performAsCurrentDrawingAppearance {
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    host.addSubview(panel)
    NSLayoutConstraint.activate([
        panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        panel.topAnchor.constraint(equalTo: host.topAnchor)])
    panel.setExpanded(true, animated: false)
    panel.update(period, trend: trend, rate: rate)
    host.layoutSubtreeIfNeeded()

    let h = ceil(panel.fittingSize.height)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: h)
    host.layoutSubtreeIfNeeded()

    let scoredBuckets = trend.compactMap { $0.score }.count
    print(String(format: "%-5@ %-6@ height=%4.0f  trend=%d buckets (%d scored)  rate=%d points",
                 lookName as NSString, range.label as NSString, h,
                 trend.count, scoredBuckets, rate.count))

    func shoot(_ suffix: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let path = "\(outDir)/\(lookName)-\(range.rawValue)-\(range.label)\(suffix).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("       \(path)")
    }
    shoot("")

    // Hover state. A view outside a window converts coordinates against nothing, so the
    // panel goes into a real (offscreen) window first; then a synthetic mouseMoved is
    // handed straight to each chart, bypassing the tracking area (which only fires for
    // a window the user is actually pointing at).
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                       backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()

    func charts(_ v: NSView) -> [NSView] {
        (String(describing: type(of: v)).contains("TrendChart") ? [v] : [])
            + v.subviews.flatMap(charts)
    }
    let found = charts(host)
    for c in found {
        // Two thirds along, so the readout has to clamp on the right — the case most
        // likely to draw the bubble off the card.
        let inView = NSPoint(x: c.bounds.width * 0.66, y: c.bounds.midY)
        let inWin = c.convert(inView, to: nil)
        if let ev = NSEvent.mouseEvent(with: .mouseMoved, location: inWin, modifierFlags: [],
                                       timestamp: 0, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            c.mouseMoved(with: ev)
        }
    }
    print("       (\(found.count) charts crosshaired)")
    host.layoutSubtreeIfNeeded()
    shoot("-hover")
}
}
