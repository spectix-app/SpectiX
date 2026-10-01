import Cocoa

// MARK: - Theme registry
//
// The single list of themes the app ships.
//
// ── ADDING A THEME ────────────────────────────────────────────────────────────
// Exactly two edits, nothing else in the app changes:
//   1. Add `ThemeFoo.swift` at the top level (build.sh compiles `*.swift` from the
//      project root only — a subdirectory would silently not be built), exposing
//      `static let spec: ThemeSpec`.
//   2. Add `ThemeFoo.spec` to `all` below.
// Consumers keep saying `Theme.cardFill` / `Status.accent(_:)` and pick the new
// values up for free, because those accessors read through `Theme.current`.
//
// If a theme needs a look no existing `ThemeMaterial` / `SurfaceStyle` /
// `PillStyle` case can express, add a case there and handle it at the few sites
// that switch on it. That is the only situation that touches consumer code.

enum ThemeRegistry {

    /// Display order in Settings → 主题.
    static let all: [ThemeSpec] = [
        ThemeDefault.spec,
        ThemeClay.spec,
    ]

    /// What an unknown id resolves to. Must always be a member of `all`.
    static var fallback: ThemeSpec { ThemeDefault.spec }

    /// Look up a persisted id. Unknown ids (a theme removed in a later build, a
    /// hand-edited preference, a downgrade) resolve to the default rather than
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
