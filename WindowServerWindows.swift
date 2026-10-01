import Foundation
import CoreGraphics

// Which of an app's WindowServer windows are REAL user windows — answerable without
// Accessibility, and therefore across every Space.
//
// WHY THIS EXISTS: kAXWindows only enumerates the CURRENT Space (see logDesktopProbe).
// So a Claude window that has never shared a Space with you — the app auto-started on
// another desktop after a reboot, or it is full-screen (its own Space by definition) —
// is invisible to the a11y probe forever, and its row never appears. CGWindowList spans
// every Space, but its public fields cannot tell a session window from Electron's
// scaffolding: for one visible Claude window the app publishes ~12 layer-0 windows (a
// native top-bar strip per display, never-shown 800x600 shells, a 500x500 helper), and
// alpha / sharingState / storeType / memoryUsage are IDENTICAL across all of them.
// kCGWindowName would separate them, but it is the one field Screen Recording gates,
// and requiring that permission for a menu bar app is not on the table.
//
// SLSCopySpacesForWindows answers it instead: WindowServer assigns a Space only to a
// window that actually belongs to a desktop. Measured on this machine with Claude
// sitting on another Space (2026-08-08):
//
//     Claude   12 layer-0 windows -> 1 with a Space  (the real one, on Space 3)
//     Notion   10 layer-0 windows -> 1 with a Space  (same Electron shape)
//     Finder    9 layer-0 windows -> 0 with a Space  (no Finder window was open)
//     Code     11 layer-0 windows -> 3 with a Space  (three real editor windows)
//
// SkyLight is already loaded in every AppKit process (AppKit links it), so the symbols
// come from dlsym on the global scope — nothing is dlopen'd and nothing is linked, which
// keeps `otool -L` output unchanged for anyone auditing the no-network guarantee.
//
// TAGS/ATTRIBUTES WERE TRIED AND REJECTED: the classifier yabai uses
// (SLSWindowIteratorGetAttributes & 0x2, plus tag bits) reads attributes=0x0 for EVERY
// window on this macOS build, real ones included, and the tag words of the real window
// and of a never-shown shell are bit-identical (0x300000100080401). It would have
// classified nothing. SLSCopyWindowProperty(kCGSWindowTitle) returns an empty string for
// every window here, so titles are gated too and cannot name the Design window.
enum WindowServerWindows {

    // Window numbers, among `candidates`, that WindowServer says are real user windows.
    // nil means "no answer" — the caller must then keep its previous behaviour rather
    // than treat the empty set as "there are no windows".
    //
    // Two independent signals must agree before a window counts, because inventing a row
    // is a worse bug than missing one (see desktopFallback):
    //   1. WindowServer gave it a Space.
    //   2. It is big enough to be a window a person uses. The top-bar strips are
    //      3440x30 / 1728x33 — they fail this on height alone, so even if the Space rule
    //      ever loosened they could not sprout rows.
    // And a sanity gate on the result: these are undocumented semantics, and the way
    // they break is by degrading into "everything matches". An app that suddenly has
    // more than `maxPlausible` real windows is a filter that stopped filtering, so the
    // whole answer is thrown away rather than published as a dozen phantom rows.
    static func realWindows(_ candidates: [(wid: CGWindowID, frame: CGRect)],
                            maxPlausible: Int = 8) -> Set<CGWindowID>? {
        guard !candidates.isEmpty, let sls = symbols else { return nil }
        var out = Set<CGWindowID>()
        for c in candidates where c.frame.width >= 200 && c.frame.height >= 120 {
            let spaces = sls.spacesForWindows(sls.connection(), spaceSelectorAll,
                                              [NSNumber(value: c.wid)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] ?? []
            if !spaces.isEmpty { out.insert(c.wid) }
        }
        return out.count > maxPlausible ? nil : out
    }

    // 0x7 = every kind of Space (user desktops, full-screen, tiled), the selector yabai
    // passes for the same question. A narrower one would drop full-screen windows, which
    // are precisely the ones a11y can never see.
    private static let spaceSelectorAll: Int32 = 0x7

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    // Resolved once. A missing symbol (a future macOS renames or drops it) closes this
    // path for good instead of crashing — the desktop rows then behave exactly as they
    // did before this file existed.
    private static let symbols: (connection: MainConnectionFn,
                                 spacesForWindows: SpacesForWindowsFn)? = {
        // RTLD_DEFAULT: search every image already loaded in the process.
        let anyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let conn = dlsym(anyLoadedImage, "SLSMainConnectionID"),
              let spaces = dlsym(anyLoadedImage, "SLSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(conn, to: MainConnectionFn.self),
                unsafeBitCast(spaces, to: SpacesForWindowsFn.self))
    }()
}
