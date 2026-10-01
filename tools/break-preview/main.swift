import Cocoa

// Renders the break-timer chip + strip (BreakReminder.swift) in every phase, light and
// dark, to PNG — the only way to LOOK at it on a machine that can't screenshot.
// Photos come from tools/ directly (no bundle here), so the Resources lookup is
// pointed there before anything draws.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/spectix-break"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
AppSettings.breakReminderEnabled = true

let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
let r = BreakReminder.shared
// phase name → how to put the clock there (each step continues from the previous one)
let states: [(String, () -> Void)] = [
    ("1-work", { AppSettings.breakCountUp = false; r.startWork(); r.rewind(by: 11 * 60) }),
    ("1b-work-up", { AppSettings.breakCountUp = true }),
    ("1c-work-down", { AppSettings.breakCountUp = false }),
    ("2-over", { r.rewind(by: AppSettings.breakReminderMinutes * 60 + 192); _ = r.poll(idle: 0, running: true) }),
    ("3-rest", { r.startRest() }),
    // Rested 15 min against a 10-min rest: the real poll ends it and 休息好了？ shows the total.
    ("4-done", { r.startRest(now: Date().addingTimeInterval(-15 * 60)); _ = r.poll(idle: 0, running: false) }),
]

for (lookName, lookID) in looks {
    for (name, enter) in states {
        enter()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 8 + 22 + BreakPanel.openHeight + 8))
        host.appearance = NSAppearance(named: lookID)
        host.wantsLayer = true
        // A mid-grey bed on purpose, NOT windowBackgroundColor: a glow that leaks past
        // the strip — or gets clipped into a rectangle by something upstream — is
        // invisible against a near-white page, which is how a square green halo shipped
        // on 2026-09-11. Grey shows both the halo's shape and its reach.
        host.layer?.backgroundColor = NSColor(white: lookName == "dark" ? 0.18 : 0.72,
                                              alpha: 1).cgColor
        let chip = BreakChip()
        let panel = BreakPanel()
        host.addSubview(chip)
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            chip.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        chip.refresh()
        if !panel.expanded { panel.toggle() }   // a hand-opened peek: the work phase folds itself otherwise
        panel.refresh()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        let path = "\(outDir)/\(lookName)-\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("\(path)  chip=\(Int(chip.frame.width))w  expanded=\(panel.expanded)")
    }
}
