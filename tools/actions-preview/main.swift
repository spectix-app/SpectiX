import Cocoa

// Renders the quick-actions drawer + the wrench offscreen to PNG, every theme × dark/light
// at the popover's two widths. Same reason as the other previews: this machine cannot
// screenshot the real window. Reads the real ~/.claude/spectix/actions.json; the second
// column hovers the first tile. detail-*.png shows the detail page never-run / running
// (live output) / failed, driven by real runs of throwaway scripts; editor-*.png is the
// add / edit page inside the drawer (new script · a skill · the list searched · a sub-skill).

let widths: [CGFloat] = [384, 468]

func render(width: CGFloat, look: NSAppearance, hoverFirst: Bool, detail: QuickAction? = nil,
            form: QuickAction?? = nil, search: String? = nil) -> NSBitmapImageRep? {
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
    if let detail { drawer.showDetail(detail) }
    if let form {
        drawer.showForm(form)
        // The skill list loads off the main thread.
        let table = firstView(drawer, NSTableView.self)
        for _ in 0..<600 where form?.kind == .skill && (table?.numberOfRows ?? 0) == 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let search, let field = firstView(drawer, NSSearchField.self) {
            field.stringValue = search
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
    }
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

func firstTile(_ v: NSView) -> QuickActionTile? { firstView(v, QuickActionTile.self) }

func firstView<T: NSView>(_ v: NSView, _ type: T.Type) -> T? {
    if let t = v as? T { return t }
    for s in v.subviews { if let t = firstView(s, type) { return t } }
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

let fresh = QuickAction(id: "preview-fresh", emoji: "🎹", name: "清理 G915 配对", kind: .script,
                        body: "blueutil --unpair \"$(blueutil --paired | grep -i g915 | grep -oE '([0-9a-f]{2}-){5}[0-9a-f]{2}')\"",
                        confirm: true)
let live = QuickAction(id: "preview-live", emoji: "☀️", name: "Morning brief", kind: .skill, body: "/morning",
                       cwd: "~/Projects")
let failed = QuickAction(id: "preview-failed", emoji: "🧪", name: "Run tests", kind: .prompt,
                         body: "Run the test suite and fix anything that fails")
let runner = QuickActionRunner.shared
// Stand-ins so nothing real runs: same runner, throwaway bodies, real states.
runner.run(QuickAction(id: failed.id, name: failed.name, kind: .script,
                       body: "echo 'collecting 142 tests'; echo 'FAILED test_session.py::test_resume' >&2; exit 1"))
runner.run(QuickAction(id: live.id, name: live.name, kind: .script,
                       body: "echo 'Reading yesterday’s commits…'; echo '3 PRs merged, 2 reviews waiting'; sleep 30"))
for _ in 0..<30 where runner.results[failed.key] == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
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
        let details = [fresh, live, failed].compactMap { render(width: 384, look: look, hoverFirst: false, detail: $0) }
        try? row(details)?.write(to: URL(fileURLWithPath: "\(outDir)/detail-\(spec.id)-\(lookName).png"))
        if spec.id == ThemeRegistry.all.first?.id {
            let skill = QuickAction(id: "preview-skill", emoji: "☀️", name: "Morning", kind: .skill, body: "/morning today")
            // A skill filed inside an entry skill (~/.claude/skills/notes/daily-report).
            let sub = QuickAction(id: "preview-sub", emoji: "📰", name: "早报", kind: .skill, body: "/notes daily-report today")
            let forms = [render(width: 384, look: look, hoverFirst: false, form: .some(nil)),
                         render(width: 384, look: look, hoverFirst: false, form: skill),
                         render(width: 384, look: look, hoverFirst: false, form: skill, search: "task"),
                         render(width: 384, look: look, hoverFirst: false, form: sub, search: "daily")].compactMap { $0 }
            try? row(forms)?.write(to: URL(fileURLWithPath: "\(outDir)/editor-\(lookName).png"))
        }
    }
}
runner.stop(live.key)
print("actions loaded: \(QuickActionStore.shared.actions.count)\(QuickActionStore.shared.loadError.map { " · " + $0 } ?? "")")
