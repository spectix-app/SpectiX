import Foundation

// MARK: - Paid feature gate
//
// Every feature that will one day need a license is asked about HERE rather than
// checked inline, so "is this paid?" lives in one place. During the free beta
// `enabled(_:)` answers true for everything: the app behaves exactly as it always
// has and no call site can tell the difference. When licensing ships, the body of
// `enabled(_:)` is the only thing that changes and every feature follows at once.
//
// The call sites are the AppSettings getters, NOT the views. Gating a setting at its
// getter makes it read as its free-tier fallback everywhere at once — the list, the
// popover, the rings and the settings panel all agree without one extra branch. The
// setters stay open on purpose: a lapsed license must not erase what the user chose,
// so their preference is kept on disk and simply stops being honored while locked.
enum ProFeature: String, CaseIterable {
    /// Jumping to the next waiting session on its own — after you answer one, or
    /// once you've gone idle with something still pending.
    case autoJump

    /// Every ring and label this app draws: always-on terminal rings, the manual-click
    /// flash, per-status ring styles, the jump caption, the notification banner's
    /// animated icon — and the jump LANDING ring itself.
    ///
    /// That landing ring was free until T213, on the reasoning that showing where a
    /// jump put you is part of jumping rather than a flourish. It is paid now because
    /// the free tier no longer jumps anywhere precise (see `preciseJump`): there is no
    /// landing left to mark.
    case highlights

    /// Landing in the exact terminal pane a session runs in. Without it a click still
    /// brings the editor forward — it just leaves you wherever you already were in that
    /// window instead of inside that specific split.
    case preciseJump

    /// The usage columns — ⏱ working time, ◆ tokens, the context gauge, model chip.
    case metrics

    /// Themes beyond the built-in default.
    case themes

    /// Per-project emoji / image icons.
    case customIcons
}

/// Where this install stands with respect to a paid license.
///
/// Three states, no per-tier variants: their shape isn't knowable until the licensing
/// scheme is actually chosen, and guessing now would be dead weight.
///
/// Only `unlocked` is live today. Both of the others are SEAMS waiting on T214: until
/// an offline license file exists there is nothing to verify, and nothing left to fail
/// to verify either.
enum LicenseState {
    /// Free and complete. Every build is this.
    case unlocked
    /// A verified license is present. Nothing produces this yet (T214).
    case licensed
    /// Asked for a license and didn't get one. Nothing produces this yet (T214).
    case unlicensed
}

// MARK: - Dev-build gate
//
// Orthogonal to the paid gate above: `Pro` answers "has this user paid for it?",
// `Build` answers "does this binary have it at all?". A dev-only feature is one
// that works but isn't ready to be shipped to anyone — it stays in the tree,
// stays buildable, and stays out of every release package.
//
// The distinction that matters: this is a COMPILE-TIME fact, not a preference.
// `./build.sh` passes -D DEV_BUILD; package.sh's release path (UNIVERSAL=1) does
// not, so in a shipped binary the settings row is never built and the setting
// reads false no matter what is on disk — no `defaults write` can bring it back.
enum Build {
    #if DEV_BUILD
    static let isDev = true
    #else
    static let isDev = false
    #endif
}

enum Pro {
    /// One level now: a license, or not.
    ///
    /// **Any license check must stay offline.** Zero-network is not a preference here —
    /// it is enforced three ways: the README ("Privacy: no network") and the site's
    /// /privacy page make it a public commitment; build.sh fails the build if a networking API appears in the
    /// sources OR if a network library ends up linked; and it is the core answer to
    /// "why does this need Accessibility permission?" (`launch/07` §144). Consequences,
    /// all accepted: a license can't be revoked once issued, activation is a file the
    /// user imports rather than a server round-trip. Ed25519 via CryptoKit clears both
    /// build gates — measured, not assumed (`pipeline/05` §1).
    private static var licenseState: LicenseState {
        hasLicense ? .licensed : .unlocked
    }

    /// The seam T214 fills in — an imported, offline-verified license file. Kept as a
    /// named property rather than inlined above so there is one findable place to put
    /// it, and so turning the paid tier on stays a change to this one property:
    /// `enabled(_:)` below and every call site in AppSettings stay as they are.
    private static var hasLicense: Bool { false }

    /// Everything is on until T214 gives `.unlicensed` a way to happen. The parameter
    /// stays in the signature because every call site already asks about a specific
    /// feature, and the day a tier line is drawn it gets read here rather than at a
    /// hundred call sites.
    static func enabled(_ feature: ProFeature) -> Bool {
        switch licenseState {
        case .unlocked, .licensed: return true
        case .unlicensed:          return false
        }
    }

    /// Whether the settings panel marks a feature as paid.
    ///
    /// Off, on the user's call (2026-08-04, reaffirmed 2026-08-10): nothing is
    /// charged for yet, so a PRO badge on a row that works is just noise. The badge
    /// component, the rows that name a `ProFeature`, and `applyProLock` all stay
    /// wired — flipping this back to `true` is the whole of turning them back on.
    static let showsBadge = false
}
