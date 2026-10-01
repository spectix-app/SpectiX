import Foundation

// MARK: - Lightweight inline localization
//
// SpectiX compiles as a single binary (swiftc -O *.swift) with no .lproj
// bundle, so there's no NSLocalizedString table to load. Instead every
// user-facing string is written inline in both languages via `L("中文", "English")`;
// L() returns the one for the current language at call time. The whole UI is
// rebuilt on a language change (AppController tears down and reopens the windows +
// popover), so call-time resolution is enough — no per-view observers needed.
//
// Rule of thumb: wrap only strings the *user* sees (labels, buttons, menu items,
// toasts). Leave comments, NSLog output, and internal identifiers alone.

enum Lang: String { case zh, en }

// The single global translation helper. zh is the source/default text.
func L(_ zh: String, _ en: String) -> String {
    AppSettings.effectiveLang == .zh ? zh : en
}
