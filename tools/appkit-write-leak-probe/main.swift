// Which AppKit property writes leak on THIS macOS? Run it, read the table.
//
//   swiftc -O tools/appkit-write-leak-probe/main.swift -o /tmp/probe -framework Cocoa && /tmp/probe
//
// Why it exists (2026-09-15): the menu-bar pill was redrawn 10× a second and the app
// grew about a gigabyte a day. The leak is inside AppKit — some property writes
// register a KVO dependency pair that is never released — so no amount of reading our
// own code finds it, and reasoning about which writes are "cheap" is how the WRONG
// suspect gets fixed (it happened here: the path doing 27 alpha writes a second turned
// out to leak nothing). This measures instead: N identical writes, live malloc blocks
// before and after. A net-positive per-write number IS the leak.
//
// Measured on macOS 26.6.2 (25G83), 20000 writes each:
//   status button .image            +5.02   ← what the pill used to do at 10 Hz
//   status button .alphaValue       +0.00   ← so it is not "all status button writes"
//   NSPanel  .alphaValue            +0.00
//   NSButton .alphaValue            +0.00
//   NSPanel  .ignoresMouseEvents    +0.00
//   NSView   .needsDisplay          +0.00
//   NSPanel  .order(.above:)       +18.08   ← the expensive one nobody suspects
//   NSPanel  .contentView = new    +15.04
//
// Add a row whenever you are about to put an AppKit write on a timer. Two minutes here
// beats a week of "the machine feels slow".

import Cocoa

// Which AppKit property writes actually leak on this OS? Counts LIVE malloc blocks
// before and after N identical writes, so a net-positive number means the objects the
// write created are never released.
func liveBlocks() -> Int {
    var s = malloc_statistics_t()
    malloc_zone_statistics(nil, &s)
    return Int(s.blocks_in_use)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let N = 20000
func measure(_ name: String, _ body: () -> Void) {
    for _ in 0..<50 { body() }                 // warm up, settle one-time allocations
    let before = liveBlocks()
    for _ in 0..<N { body() }
    let after = liveBlocks()
    let per = Double(after - before) / Double(N)
    let pad = String(repeating: " ", count: max(0, 40 - name.count))
    print("\(name)\(pad)\(String(format: "%+8.2f", per)) blocks/write")
}

// The control: the write we already know leaks.
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let img = NSImage(size: NSSize(width: 40, height: 18))
if let b = item.button {
    measure("status button .image", { b.image = img })
    measure("status button .alphaValue", { b.alphaValue = 1 })
} else {
    print("status button: unavailable")
}

// The suspects from FocusRing: an overlay NSPanel and its ✕ button.
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
let plain = NSButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
measure("NSPanel .alphaValue", { panel.alphaValue = 1 })
measure("NSButton .alphaValue", { plain.alphaValue = 1 })
measure("NSPanel .ignoresMouseEvents", { panel.ignoresMouseEvents = false })
measure("NSPanel .order(.above:)", { panel.order(.above, relativeTo: 0) })
measure("NSView .needsDisplay", { plain.needsDisplay = true })
measure("NSPanel .contentView = new", {
    panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
})
