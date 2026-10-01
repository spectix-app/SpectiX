import Foundation

// MARK: - Inline localization
//
// Same approach as the main app's L10n.swift: the installer is a single binary
// built by `swiftc -O installer/src/*.swift` with no .lproj bundle, so every
// user-facing string is written inline in both languages via `L("中文", "English")`.
//
// It does NOT reuse the app's L10n.swift, because that resolves through
// AppSettings.effectiveLang — which would drag UserDefaults, the theme registry
// and the settings-change notifications into a window that lives for ten seconds.
// The language rule below is a copy of the `.system` branch of that property:
// a Chinese system runs Chinese, everything else runs English.
//
// The installer has no language switch of its own on purpose — it appears before
// the user has any SpectiX preferences to read.
enum ILang {
    static let isZH: Bool = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}

func L(_ zh: String, _ en: String) -> String { ILang.isZH ? zh : en }
