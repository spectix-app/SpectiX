import Cocoa

// MARK: - Theme registry
//
// The built-in themes plus any theme files the user dropped into
// ~/.claude/spectix/themes/ (ThemeFile.swift, docs/themes.md).
//
// ── ADDING A BUILT-IN THEME ───────────────────────────────────────────────────
// Exactly two edits, nothing else in the app changes:
//   1. Add `ThemeFoo.swift` at the top level (build.sh compiles `*.swift` from the
//      project root only — a subdirectory would silently not be built), exposing
//      `static let spec: ThemeSpec`.
//   2. Add `ThemeFoo.spec` to `builtIns` below.
// Consumers keep saying `Theme.cardFill` / `Status.accent(_:)` and pick the new
// values up for free, because those accessors read through `Theme.current`.
//
// If a theme needs a look no existing `ThemeMaterial` / `SurfaceStyle` /
// `PillStyle` case can express, add a case there and handle it at the few sites
// that switch on it. That is the only situation that touches consumer code.

enum ThemeRegistry {

    /// Display order in Settings → 主题. The first one is also what a theme file
    /// inherits from when it names no `base`.
    static let builtIns: [ThemeSpec] = [
        ThemeDefault.spec,
        ThemeClay.spec,
    ]

    /// Built-ins first, then file themes by filename. Loaded on first use (so the
    /// theme the app launches into can be a file theme) and again by `reload()`.
    static private(set) var all: [ThemeSpec] = builtIns + loadFiles()

    /// Re-read the theme folder. Called whenever the theme chooser is built and when
    /// a file theme is picked, so a new or edited file shows up without a restart.
    static func reload() {
        all = builtIns + loadFiles()
    }

    /// Picking a file theme that is already active still re-applies it — that is how
    /// an author sees an edit to the file they are working on.
    static func isFileTheme(_ id: String) -> Bool {
        !builtIns.contains { $0.id == id } && isKnown(id)
    }

    private static func loadFiles() -> [ThemeSpec] {
        let result = ThemeFile.loadAll(builtIns: builtIns)
        for f in result.failures {
            NSLog("SpectiX theme file %@ skipped: %@", f.file, f.reason)
        }
        return result.themes
    }

    /// What an unknown id resolves to. Must always be a member of `builtIns`.
    static var fallback: ThemeSpec { ThemeDefault.spec }

    /// Look up a persisted id. Unknown ids (a theme removed in a later build, a
    /// deleted theme file, a hand-edited preference, a downgrade) resolve to the default rather than
    /// crashing or leaving the app unstyled.
    static func spec(for id: String) -> ThemeSpec {
        all.first { $0.id == id } ?? fallback
    }

    /// Whether an id names a theme we actually ship — Settings uses this to tell a
    /// stale stored id from a live selection.
    static func isKnown(_ id: String) -> Bool {
        all.contains { $0.id == id }
    }
}
