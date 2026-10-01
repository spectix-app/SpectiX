import Cocoa

// `Status` lives in main.swift; Theme.swift only hangs an extension off it (which is
// where claudeOrange comes from), so an empty enum links fine.
enum Status {}

// DemoData.swift drags in the app; the strip never reads it.
enum Demo {
    static var enabled = false
    static var eventsPath = ""
    static var impactPath = ""
    static func restart() {}
    static func ensureLogs() {}
}

// The count pill's chip pane lives in Components.swift (which drags in the app); a
// flat rounded stand-in keeps the chip's size honest here — the real chrome is the
// theme's business.
final class ChipShellView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.chip
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.gray.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

// `letShadowsEscape()` is an NSView extension in Components.swift (which drags in the
// app). Same two lines here so the preview links — keep them in step with the original.
extension NSView {
    func letShadowsEscape() {
        wantsLayer = true
        layer?.masksToBounds = false
        if #available(macOS 14.0, *) { clipsToBounds = false }
    }
}
