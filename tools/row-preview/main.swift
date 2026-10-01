import Cocoa

// Renders the session list's row states offscreen to PNG — one sheet per theme ×
// appearance, the states side by side so a selected row can be judged against its
// resting neighbours.
//
// Why this exists: row styling is only ever judged by eye. A selection fill a shade off
// the mock, a halo that floods the row, a hover outline that vanishes in light mode —
// none of it throws or fails a test, and this machine can't screenshot the real window
// (see tools/panel-preview/main.swift). These are the REAL cells (HeaderCell / ChildCell
// / GroupCard) fed demo-mode sessions and driven through the table's own pin and hover
// entry points, so what renders here is what the app draws.
//
// Compare against design/selected-row-glow-5-proposals.html (方案 2, the selection
// halo) and design/row-hover-5-versions.html (方案 C, the hovered row).
//
// Same blind spots as panel-preview: no NSVisualEffectView blur (the bed is painted flat
// with Theme.baseFill) and model values only, never mid-animation frames.

enum Shot: CaseIterable {
    case rest, selected, hover, hoverGroup, selectedAndHover, selectedInHoveredGroup

    var label: String {
        switch self {
        case .rest:             return "rest"
        case .selected:         return "selected (pin)"
        case .hover:            return "hover row"
        case .hoverGroup:       return "hover header (group)"
        case .selectedAndHover: return "selected + hover below"
        case .selectedInHoveredGroup: return "selected + own group hovered"
        }
    }
}

// The rows the shots point at, picked once from the first render by cell type so every
// shot of every sheet lights the same rows.
struct Targets { var header = -1, first = -1, second = -1 }

// ★ TWO widths, both REAL (改这块前必读): 384 = the menu-bar popover's floor
// (AppSettings.popoverWidthRange.lowerBound, the shipped default), 468 = a typical
// main window. A single 420pt sheet sat between them and so rendered neither: the
// right-hand attribute band's floors (shellSlotW 52 / stepMinW 60) drop the tag at
// 420 AND at 384 but keep it at 468, so the one sheet showed a row that no window
// ever draws. That is how the 「等待」 row shipped explaining nothing at every width
// and the preview still looked right (2026-09-12).
let previewWidths: [CGFloat] = [384, 468]

// Captured ONCE: Demo.rows() animates off the wall clock, and a beat boundary crossed
// between two shots would give the columns of one sheet different statuses.
// Pinned so the pico-engine row (phase 12, cycle 140) sits in its 等待 beat: the fifth
// status has to be on every sheet, and a wall-clock render would show it 1 time in 7.
Demo.pin(elapsed: 70)
let previewRows = Demo.rows()

func findTable(_ v: NSView) -> ReorderTableView? {
    if let t = v as? ReorderTableView { return t }
    for s in v.subviews { if let t = findTable(s) { return t } }
    return nil
}

func pickTargets(_ table: ReorderTableView) -> Targets {
    let cells = (0..<table.numberOfRows).map { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
    var t = Targets()
    // First expanded group with at least one child: its header drives the group lift,
    // its first two children the pin and the neighbouring hover.
    for (r, c) in cells.enumerated() where c is HeaderCell {
        guard r + 1 < cells.count, cells[r + 1] is ChildCell else { continue }
        t.header = r
        t.first = r + 1
        break
    }
    let children = cells.indices.filter { cells[$0] is ChildCell }
    if t.first < 0 { t.first = children.first ?? -1 }
    t.second = children.first { $0 > t.first } ?? children.first { $0 != t.first } ?? -1
    return t
}

func render(_ shot: Shot, look: NSAppearance, previewWidth: CGFloat,
            targets: inout Targets?) -> NSBitmapImageRep? {
    let labelH: CGFloat = 24
    // Far offscreen: reload() re-syncs hover to the REAL pointer, and a window parked at
    // the screen origin could catch it and light a row nobody asked for.
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: previewWidth, height: 900),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = look
    let host = NSView(frame: win.contentRect(forFrameRect: win.frame))
    win.contentView = host
    host.wantsLayer = true

    let list = SessionListView(model: ListModel())
    host.addSubview(list)
    list.reload(previewRows)
    // + the scroll view's 18pt bottom inset, so the last card's shadow isn't cut off
    // and the below-the-fold glow never fires.
    let listH = ceil(list.contentHeight) + 18
    win.setContentSize(NSSize(width: previewWidth, height: listH + labelH))
    host.frame = NSRect(x: 0, y: 0, width: previewWidth, height: listH + labelH)
    list.frame = NSRect(x: 0, y: 0, width: previewWidth, height: listH)
    host.layoutSubtreeIfNeeded()
    look.performAsCurrentDrawingAppearance {
        host.layer?.backgroundColor = Theme.baseFill.cgColor
    }

    let caption = NSTextField(labelWithString: "\(shot.label) · \(Int(previewWidth))pt")
    caption.font = .systemFont(ofSize: 11, weight: .semibold)
    caption.textColor = .secondaryLabelColor
    caption.frame = NSRect(x: Theme.cardCellInset, y: listH + 4, width: previewWidth, height: 16)
    host.addSubview(caption)

    guard let table = findTable(list) else { print("  no ReorderTableView found"); return nil }
    if targets == nil { targets = pickTargets(table) }
    let t = targets!

    func pointAt(_ row: Int) {
        guard row >= 0 else { return }
        let r = table.rect(ofRow: row)
        let p = table.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        if let ev = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [],
                                       timestamp: 0, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            table.mouseMoved(with: ev)
        }
    }
    switch shot {
    case .rest:             break
    case .selected:         table.setPinnedRow(t.first)
    case .hover:            pointAt(t.second)
    case .hoverGroup:       pointAt(t.header)
    case .selectedAndHover: table.setPinnedRow(t.first); pointAt(t.second)
    // The one combination the other five miss: the SELECTED row is itself inside the
    // lifted group, so its halo wears the group scale while the halo's mask does not.
    case .selectedInHoveredGroup: table.setPinnedRow(t.first); pointAt(t.header)
    }
    host.layoutSubtreeIfNeeded()

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
    cg.setFillColor(NSColor.systemPink.cgColor)   // gutter: clearly not part of any theme
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
print("demo rows: \(previewRows.count) — " + previewRows.map { "\($0.folder)/\($0.status)" }.joined(separator: " "))

for spec in ThemeRegistry.all {
    Theme.apply(spec.id)
    for (lookName, lookID) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        guard let look = NSAppearance(named: lookID) else { continue }
        // App-wide, the way the app's own light/dark override does it (AppSettings sets
        // NSApp.appearance). Forcing only the window left clay's light pills with a bed
        // resolved in the system's dark look — a preview artifact, not what ships.
        NSApp.appearance = look
        for w in previewWidths {
            var targets: Targets?
            let reps = Shot.allCases.compactMap {
                render($0, look: look, previewWidth: w, targets: &targets)
            }
            let path = "\(outDir)/\(spec.id)-\(lookName)-\(Int(w)).png"
            try? sheet(reps)?.write(to: URL(fileURLWithPath: path))
            let t = targets ?? Targets()
            print("\(spec.id) \(lookName) \(Int(w))pt: header=\(t.header) pinned=\(t.first) hovered=\(t.second)")
            print("    \(path)")
        }
    }
}
