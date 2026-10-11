import Cocoa

// Counts the NSKeyValueDependency objects AppKit leaks while the session list refreshes.
//
// Why this exists (T318): on macOS 26 every control that enters a window registers an
// NSKeyValueDependency that is never freed. NSTableView.reloadData detaches every
// visible cell and re-attaches it, and the list's render key changes every second while
// a session works (the ⏱ text), so the list alone leaked ~35 objects/s. Nothing else can
// see this: it compiles, it renders correctly, it just grows the heap for days.
//
// The REAL SessionListView, in an offscreen window, fed demo-mode rows one wall-clock
// second apart (so each reload has new visible content but the same row shapes — the
// steady state of a working session). `heap` counts the dependency objects before and
// after; more than LEAK_MAX_PER_RELOAD (default 1) per reload fails.

let reloads = 120
let maxPerReload = Double(ProcessInfo.processInfo.environment["LEAK_MAX_PER_RELOAD"] ?? "") ?? 1

func kvdCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
    p.arguments = ["\(getpid())"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    // heap lines: "  COUNT  BYTES  AVG  CLASS_NAME  TYPE  BINARY"
    return text.split(separator: "\n").reduce(0) { n, line in
        guard line.contains("NSKeyValueDependency") else { return n }
        return n + (Int(line.split(separator: " ").first ?? "") ?? 0)
    }
}

NSApplication.shared.setActivationPolicy(.accessory)

// Far offscreen, like row-preview: reload() re-syncs hover to the real pointer.
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 468, height: 900),
                   styleMask: [.borderless], backing: .buffered, defer: false)
let host = NSView(frame: win.contentRect(forFrameRect: win.frame))
win.contentView = host
let list = SessionListView(model: ListModel())
list.frame = host.bounds
host.addSubview(list)

func step(_ i: Int) {
    Demo.pin(elapsed: 70 + Double(i))
    list.reload(Demo.rows())
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
}

// Warm-up: first build of every cell, caches, lazy AppKit state.
for i in 0..<10 { step(i) }
let before = kvdCount()
for i in 10..<(10 + reloads) { step(i) }
let after = kvdCount()

let per = Double(after - before) / Double(reloads)
print("rows: \(Demo.rows().count)   reloads: \(reloads)")
print("NSKeyValueDependency*: \(before) → \(after)   (\(String(format: "%.2f", per))/reload)")
if per > maxPerReload {
    print("❌ the list leaks \(String(format: "%.2f", per)) dependency objects per reload (max \(maxPerReload)) — cells are being re-inserted into the window (T318)")
    exit(1)
}
print("✅ list reload leaks \(String(format: "%.2f", per))/reload (max \(maxPerReload))")
