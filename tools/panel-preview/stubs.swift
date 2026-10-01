import Cocoa

// Two shells the panel links against but does not need the real versions of.
//
// `Status` lives in main.swift (415KB — pulling it in would mean pulling in the whole
// app); Theme.swift only hangs an extension off it, so an empty enum links fine.
enum Status {}

// DemoData.swift drags in the app too. The preview always renders the REAL logs, which
// is the point of it, so the demo redirect is simply always off.
enum Demo {
    static var enabled = false
    static var eventsPath = ""
    static var impactPath = ""
    static func restart() {}
    static func ensureLogs() {}
}
