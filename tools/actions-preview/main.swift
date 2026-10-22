import Cocoa

// Renders the quick-actions drawer + the wrench offscreen to PNG, every theme × dark/light
// at the popover's two widths. Same reason as the other previews: this machine cannot
// screenshot the real window. Reads the real ~/.claude/spectix/actions.json; the second
// column hovers the first tile and the third marks it running (via the runner's own state).

let widths: [CGFloat] = [384, 468]

func render(width: CGFloat, look: NSAppearance, hoverFirst: Bool) -> NSBitmapImageRep? {
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 400),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = look
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    host.wantsLayer = true
    win.contentView = host

    let bar = BottomTabBar()
    let drawer = QuickActionsDrawer()
    host.addSubview(bar)
    host.addSubview(drawer)
    NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        drawer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
        drawer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        drawer.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4),
    ])
    drawer.prepareForShow()
    bar.toolButton.isOpen = true
    for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
    let h = drawer.fittingSize.height + 60
    win.setContentSize(NSSize(width: width, height: h))
    host.frame = NSRect(x: 0, y: 0, width: width, height: h)
    for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
    look.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = Theme.baseFill.cgColor }

    if hoverFirst, let tile = firstTile(drawer),
       let ev = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                       eventNumber: 0, trackingNumber: 0, userData: nil) {
        tile.mouseEntered(with: ev)
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

func firstTile(_ v: NSView) -> QuickActionTile? {
    if let t = v as? QuickActionTile { return t }
    for s in v.subviews { if let t = firstTile(s) { return t } }
    return nil
}

func row(_ reps: [NSBitmapImageRep]) -> Data? {
    let gap = 6
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
        if let img = r.cgImage { cg.draw(img, in: CGRect(x: x, y: h - r.pixelsHigh, width: r.pixelsWide, height: r.pixelsHigh)) }
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
        NSApp.appearance = look
        var reps: [NSBitmapImageRep] = []
        for w in widths {
            for hover in [false, true] {
                if let r = render(width: w, look: look, hoverFirst: hover) { reps.append(r) }
            }
        }
        let path = "\(outDir)/\(spec.id)-\(lookName).png"
        try? row(reps)?.write(to: URL(fileURLWithPath: path))
        print("\(spec.id) \(lookName): \(reps.count) shots → \(path)")
    }
}
print("actions loaded: \(QuickActionStore.shared.actions.count)\(QuickActionStore.shared.loadError.map { " · " + $0 } ?? "")")
