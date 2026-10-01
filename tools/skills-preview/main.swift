import Cocoa

// Renders the 技能 tab offscreen to PNG. This machine can't screenshot the real window
// (see tools/panel-preview/main.swift), and everything that goes wrong in a list like
// this — a long name shoving the count off the edge, a bar drawn at the wrong length,
// a tag unreadable in light mode — compiles, runs and passes every test.
//
// Each sheet is four columns of the REAL SkillsPane plus the real 5-tab BottomTabBar
// under each: real catalog (skills by uses, top row expanded) · real agents · real
// Codex skills by name · the demo catalog by recent. Compare against
// design/skills-agents-tab.html 方案 2.
//
// Same blind spots as row-preview: no NSVisualEffectView blur (the bed is Theme.baseFill)
// and no hover (the pane has no tracking-driven state worth faking).

let previewWidths: [CGFloat] = [384, 476]
let paneH: CGFloat = 620

var real: [CatalogItem] = []
var done = false
SkillCatalog.load(projectRoots: ProjectHistory.all().map { $0.path }) { real = $0; done = true }
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let demo = Demo.catalog()
print("real catalog: \(real.count) items · demo: \(demo.count)")

struct Shot { let label: String; let items: [CatalogItem]; let kind: CatalogKind; let tool: CatalogTool?; let sort: SkillSort; let expandTop: Bool }
let shots = [
    Shot(label: "skills · all · uses · top expanded", items: real, kind: .skill, tool: nil, sort: .uses, expandTop: true),
    Shot(label: "agents · all · uses", items: real, kind: .agent, tool: nil, sort: .uses, expandTop: false),
    Shot(label: "skills · codex · name", items: real, kind: .skill, tool: .codex, sort: .name, expandTop: false),
    Shot(label: "demo · skills · recent · expanded", items: demo, kind: .skill, tool: nil, sort: .recent, expandTop: true),
]

func render(_ shot: Shot, look: NSAppearance, width: CGFloat) -> NSBitmapImageRep? {
    let labelH: CGFloat = 24, barH: CGFloat = 44
    let totalH = paneH + barH + labelH
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: totalH),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = look
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalH))
    win.contentView = host
    host.wantsLayer = true
    look.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = Theme.baseFill.cgColor }

    let pane = SkillsPane()
    pane.translatesAutoresizingMaskIntoConstraints = true
    pane.frame = NSRect(x: 0, y: barH, width: width, height: paneH)
    host.addSubview(pane)
    pane.show(shot.items)
    let filtered = shot.items.filter { $0.kind == shot.kind && (shot.tool == nil || $0.tool == shot.tool) }
    let top: CatalogItem?
    switch shot.sort {
    case .recent: top = filtered.max { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    case .uses:   top = filtered.max { $0.uses < $1.uses }
    case .name:   top = nil
    }
    pane.configure(kind: shot.kind, tool: shot.tool, sort: shot.sort,
                   expanded: shot.expandTop ? Set([top?.id].compactMap { $0 }) : [])

    let bar = BottomTabBar()
    bar.translatesAutoresizingMaskIntoConstraints = true
    bar.frame = NSRect(x: 0, y: 0, width: width, height: barH)
    host.addSubview(bar)
    bar.select(MainTab.skills.rawValue)

    let caption = NSTextField(labelWithString: "\(shot.label) · \(Int(width))pt")
    caption.font = .systemFont(ofSize: 11, weight: .semibold)
    caption.textColor = .secondaryLabelColor
    caption.frame = NSRect(x: 12, y: totalH - labelH + 4, width: width, height: 16)
    host.addSubview(caption)

    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); host.display() }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

func sheet(_ reps: [NSBitmapImageRep]) -> Data? {
    let gap = 4
    let w = reps.reduce(0) { $0 + $1.pixelsWide } + gap * (reps.count - 1)
    let h = reps.map(\.pixelsHigh).max() ?? 0
    guard w > 0, h > 0,
          let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
    let cg = ctx.cgContext
    cg.setFillColor(NSColor.systemPink.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
    var x = 0
    for r in reps {
        if let img = r.cgImage {
            cg.draw(img, in: CGRect(x: x, y: h - r.pixelsHigh, width: r.pixelsWide, height: r.pixelsHigh))
        }
        x += r.pixelsWide + gap
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
        NSApp.appearance = look   // app-wide, as the app's own override does (see row-preview)
        for w in previewWidths {
            let reps = shots.compactMap { render($0, look: look, width: w) }
            let path = "\(outDir)/\(spec.id)-\(lookName)-\(Int(w)).png"
            try? sheet(reps)?.write(to: URL(fileURLWithPath: path))
            print("    \(path)")
        }
    }
}
