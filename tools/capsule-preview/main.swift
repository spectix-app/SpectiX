import Cocoa

// Offscreen renderer for the menu-bar pill (MenuCapsule.swift).
//
// This machine can't screencapture and can't drive the UI, and the pill lives in the
// menu bar where even a working screenshot tool would need a human to look. Every bug
// this change could introduce — a blank pill, a dot parked in the wrong slot, figures
// running off the bed, a colour that vanishes on a light menu bar — is invisible to
// both the compiler and tools/menubar-leak-probe.sh. So: render it to PNG.
//
// What you CAN'T see here: the breathing itself. The pulsing dot is a CALayer running
// a repeating animation, and a still frame captures its MODEL state — i.e. the top of
// the inhale, full size and full opacity. That the loop is actually attached is what
// the "working" case is for: if the dot is missing from that PNG, the layer never got
// positioned; if it is there, the animation is on it (they are set in the same call).

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/spectix-capsule"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// The real button is wider than the capsule — AppKit pads a status item, and the view
// centres its drawing in that. Mirror it so the PNG shows the same geometry the menu
// bar does.
let buttonPad: CGFloat = 12

let cases: [(String, [MenuSeg])] = [
    ("1-no-sessions", [MenuSeg(count: 0, status: "idle", drawNum: false, pulse: false)]),
    ("2-working", [MenuSeg(count: 3, status: "working", drawNum: true, pulse: true)]),
    ("3-needs-working", [
        MenuSeg(count: 1, status: "needs", drawNum: true, pulse: false),
        MenuSeg(count: 2, status: "working", drawNum: true, pulse: true),
    ]),
    ("4-all-buckets", [
        MenuSeg(count: 1, status: "needs", drawNum: true, pulse: false),
        MenuSeg(count: 12, status: "working", drawNum: true, pulse: true),
        MenuSeg(count: 2, status: "paused", drawNum: true, pulse: false),
        MenuSeg(count: 3, status: "await", drawNum: true, pulse: false),
        MenuSeg(count: 7, status: "done", drawNum: true, pulse: false),
    ]),
    ("5-idle-only", [MenuSeg(count: 9, status: "idle", drawNum: true, pulse: false)]),
]

/// One sheet per appearance: every case stacked, on a bed the colour of a menu bar.
func sheet(dark: Bool) -> NSImage {
    let scale: CGFloat = 2
    let rowH: CGFloat = 26
    let widths: [CGFloat] = cases.map { _, segs in
        let probe = MenuCapsuleView()
        return probe.width(for: segs) + buttonPad
    }
    let sheetW = (widths.max() ?? 80) + 24
    let sheetH = rowH * CGFloat(cases.count) + 12

    let img = NSImage(size: NSSize(width: sheetW, height: sheetH))
    img.addRepresentation({
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sheetW * scale), pixelsHigh: Int(sheetH * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: sheetW, height: sheetH)
        return rep
    }())

    img.lockFocus()
    // Menu bars are translucent over a wallpaper; a flat mid grey is enough to show
    // whether the glass bed and the accents survive on each side.
    (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
    NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

    for (i, (_, segs)) in cases.enumerated() {
        let view = MenuCapsuleView()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = view.width(for: segs) + buttonPad
        view.frame = NSRect(x: 0, y: 0, width: w, height: 18)
        _ = view.apply(segs)
        view.needsDisplay = true
        view.displayIfNeeded()

        let y = sheetH - rowH * CGFloat(i + 1) - 2
        guard let ctx = NSGraphicsContext.current?.cgContext, let layer = view.layer else { continue }
        ctx.saveGState()
        ctx.translateBy(x: 12, y: y + (rowH - 18) / 2)
        layer.render(in: ctx)
        ctx.restoreGState()
    }
    img.unlockFocus()
    return img
}

for dark in [false, true] {
    let img = sheet(dark: dark)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("❌ could not encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(out)/capsule-\(dark ? "dark" : "light").png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
