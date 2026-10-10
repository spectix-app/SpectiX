import Cocoa

// MARK: - Theme spec
//
// A theme is DATA, not a subclass. Everything that makes one theme look
// different from another lives in a `ThemeSpec` value; `Theme.current` points at
// one of them and every `Theme.*` / `Status.*` accessor reads through it. That is
// what keeps the ~390 `Theme.…` call sites across the app untouched when a theme
// switches — they still say `Theme.cardFill`, it just resolves differently now.
//
// Adding a theme = one new file under `Themes/` returning a `ThemeSpec`, plus one
// line in `ThemeRegistry.builtIns` — or, without rebuilding, a JSON file that
// overrides a built-in's colors (ThemeFile.swift). No consumer changes. The handful of things that are
// genuinely *behavioural* rather than numeric (does this material need a blur
// layer? is a surface bounded by a line or by light?) are expressed as small enums
// below, so a new theme normally picks an existing case and just fills in values.
//
// ── What deliberately does NOT live here ──────────────────────────────────────
// A theme may change how the app LOOKS, never how much FITS. Spacing
// (`Theme.pad/gap/inset`), row heights and the usage column's fixed tab stops stay
// global constants in `Theme` — they encode information density that was tuned over
// many rounds (see docs/row-display.md), and a reskin must not be able to overturn
// it. Same reasoning keeps the Stats chart palette and the LogoBadge editor-brand
// gradients out: those are category/brand colors, not theme colors
// (docs/design-system.md, "不纳入统一").

// MARK: Behaviour switches

/// How a theme paints its base surfaces. Only add a case for a genuinely new
/// material — most new themes reuse one of these and differ only in numbers.
enum ThemeMaterial {
    /// An `NSVisualEffectView` frosting an opaque base pane behind it (the
    /// original look). Surfaces read as translucent glass over a milky panel.
    case frostedGlass
    /// Opaque warm surfaces shaped by soft shadows, no blur layer at all —
    /// one less render pass than `.frostedGlass`.
    case clay
}

/// A single soft shadow lobe. Two of these (a drop and an optional upper-left
/// counter-glow) are what make a clay surface read as extruded.
struct ShadowLobe {
    let offset: CGSize
    let blur: CGFloat
    let color: NSColor
    let opacity: Float

    // How far this lobe actually spills past the surface's top / bottom edge. The
    // two differ — an offset lobe reaches far one way and barely at all the other
    // (a 6pt-down drop with 7pt blur travels 13pt down but only 1pt up) — and a
    // sliced enclosure insets each seam by exactly that, so a slice never sheds
    // light onto its neighbour's face yet still lights the group's outer edges.
    // Layer space: +y is UP, so a "down" offset is negative.
    var spillUp: CGFloat   { blur + offset.height }
    var spillDown: CGFloat { blur - offset.height }

    /// How clay says "lifted" (glass uses a brighter fill + a ring): the same lobe,
    /// DEEPER.
    ///
    /// The design's `.clay-hi` grows the geometry too (6→9px offset, 14→20px blur).
    /// We deliberately don't: a list card's shadow already spends its entire budget
    /// (`Theme.cardCellInset`) inside the scroll view's clip rect, and anything that
    /// reaches past it is cut off in a straight line rather than fading — which is
    /// far uglier than a lift that reads purely through density.
    func raised(opacityBoost: Float = 0) -> ShadowLobe {
        ShadowLobe(offset: offset, blur: blur, color: color,
                   opacity: min(1, opacity + opacityBoost))
    }

    /// The same lobe at another scale — for a smaller element wearing the same
    /// material (see `ShadowSpec.small`).
    func scaled(_ f: CGFloat, opacityScale: Float = 1) -> ShadowLobe {
        ShadowLobe(offset: CGSize(width: offset.width * f, height: offset.height * f),
                   blur: blur * f, color: color, opacity: opacity * opacityScale)
    }
}

/// The full lighting recipe for one surface, in one appearance.
struct ShadowSpec {
    /// The lower-right lobe that seats the surface on its canvas.
    let drop: ShadowLobe
    /// The upper-left counter-glow that makes the surface read as extruded rather
    /// than merely floating. Light mode only — nil in dark, see `softShadow`.
    let counterGlow: ShadowLobe?
    /// A 1pt highlight along the TOP edge. Dark-mode clay leans on this (plus a
    /// lighter surface fill) in place of the counter-glow it cannot afford.
    let rimHighlight: NSColor?

    init(drop: ShadowLobe, counterGlow: ShadowLobe? = nil, rimHighlight: NSColor? = nil) {
        self.drop = drop
        self.counterGlow = counterGlow
        self.rimHighlight = rimHighlight
    }

    /// The whole recipe one step up — a hovered card, a floated row. Only the drop
    /// deepens; brightening the counter-glow too would just fog the surface instead
    /// of raising it. The boost carries the whole lift on its own (see
    /// `ShadowLobe.raised`), so it is larger than the design's +.06.
    var raised: ShadowSpec {
        ShadowSpec(drop: drop.raised(opacityBoost: 0.14),
                   counterGlow: counterGlow,
                   rimHighlight: rimHighlight)
    }

    /// The same material at chip scale (the design's `.clay-sm`): a count pill is
    /// raised out of the card the same way the card is raised out of the canvas, but
    /// a 22pt chip wearing full-size lobes reads as bloated rather than as the same
    /// substance. Geometry shrinks to ~0.42 and the drop lightens — both straight
    /// from the design file (6px/14 → 2.5px/6, alpha ×.75).
    var small: ShadowSpec {
        ShadowSpec(drop: drop.scaled(0.42, opacityScale: 0.75),
                   counterGlow: counterGlow?.scaled(0.42),
                   rimHighlight: rimHighlight)
    }
}

/// What gives a surface its edge.
enum SurfaceStyle {
    /// A hairline stroke draws the boundary (the frosted-glass vocabulary).
    case hairline

    /// Light draws the boundary — no stroke at all.
    ///
    /// Light and dark carry SEPARATE specs on purpose, and not merely as different
    /// numbers of the same recipe: neumorphism's upper-left white counter-glow needs
    /// a bright ground to push against. Over a dark base it can only be given ~5%
    /// before the surface just looks fogged, so dark mode drops the counter-glow
    /// entirely and builds depth the way native dark UI does — a raised surface is
    /// simply *lighter* than its canvas, with a faint rim light along the top edge
    /// and a soft shadow below. Trying to run one recipe in both appearances is what
    /// makes most "dark neumorphism" look flat.
    case softShadow(light: ShadowSpec, dark: ShadowSpec)
}

/// How a filled status pill carries its label.
enum PillStyle {
    /// Opaque deepened status color + white text (pre-tuned to clear WCAG 4.5:1).
    case solidWhiteText
    /// Light tinted bed + the deepened status color as TEXT. Reads softer; on a
    /// warm opaque canvas a solid dark block is the heaviest thing on the row and
    /// breaks the material's calm.
    ///
    /// `bed` is how much accent is mixed into the surface for that bed. It is the
    /// PILL's own strength, deliberately not `tintStyle` — the pill has to carry
    /// text and needs a firmer bed than the chips and captions that tint serves.
    case tintedDeepText(bed: CGFloat)
}

/// How a status tint (the pale capsule bed) is derived from its accent.
enum TintStyle {
    /// `accent.withAlphaComponent(x)` — correct over glass, where the blurred
    /// backdrop is meant to carry through.
    case alpha(CGFloat)
    /// Blend `x` of the accent into the theme's surface color, opaquely. Required
    /// on clay: an alpha tint over an opaque panel lets the surface's own shadow
    /// show through the capsule and dirties it.
    case mix(CGFloat)
}

// MARK: Value groups

struct ThemePalette {
    var baseFill: NSColor
    var cardFill: NSColor
    var cardFillHover: NSColor
    var cardFloat: NSColor
    var hairline: NSColor
    var hairlineHover: NSColor
    var divider: NSColor
    var barTrack: NSColor

    // The agent dimension — orthogonal to session status, so it is NOT part of
    // `ThemeStatusPalette` and never participates in the user's status-color
    // overrides (docs/design-system.md).
    var agentAccent: NSColor
    var agentDeep: NSColor
    var agentManagerAccent: NSColor
    var agentNeutralAccent: NSColor
    /// The 命令标记 (`bash` / `shell`) tag beside the title. Its own hue rather than a
    /// status color: the tag rides the same edge as the status pill and appears on
    /// working AND done rows, so borrowing `Status.accent` would either duplicate the
    /// pill or contradict it (docs/row-display.md 「命令标记」).
    var shellTagAccent: NSColor
    /// Resting fill of an expanded agent sublist — REPLACES `cardFill` on those
    /// slices (a layer has one backgroundColor), so it must land as bright as
    /// `cardFill` while reading clearly iris (docs/row-display.md, 方案 16).
    var agentSegmentFill: NSColor
    /// The one iris hairline that opens the segment; nodes inside keep `divider`.
    var agentSeam: NSColor

    /// The paid-tier dimension. Like the agent iris this is orthogonal to session
    /// status, so it stays out of `ThemeStatusPalette` and never participates in the
    /// user's status-color overrides. Amber because nothing else in the palette
    /// claims it and "premium" reads gold. Only ONE tone is stored — the locked
    /// badge's solid bed derives from it via `deepenedForWhiteText()`.
    var proAccent: NSColor

    // Usage-line metric hues. Attributes of a session, never states.
    var claudeOrange: NSColor
    var usageGreen: NSColor
    var modelOpus: NSColor
    var modelSonnet: NSColor
    var modelHaiku: NSColor
}

/// Corner radii only. Spacing and row heights are intentionally absent — see the
/// "looks vs fits" note at the top of this file.
struct ThemeMetrics {
    var card: CGFloat
    var group: CGFloat
    var chip: CGFloat
    var windowRadius: CGFloat
    var popoverRadius: CGFloat
}

/// The seven session-status defaults a theme ships. A user override still wins over
/// every one of these — `Status.accent` consults `AppSettings.userColor` first, so
/// switching themes never silently discards a color the user picked.
struct ThemeStatusPalette {
    // `await` is backticked because a bare `return await` parses as the await
    // operator and fails to compile; the argument label needs no escape.
    var needs, working, checking, paused, `await`, done, idle: NSColor
    var needsFill, workingFill, checkingFill, pausedFill, awaitFill, doneFill, idleFill: NSColor

    func accent(_ s: String) -> NSColor {
        switch s {
        case "needs":    return needs
        case "working":  return working
        case "checking": return checking
        case "paused":   return paused
        case "await":    return `await`
        case "done":     return done
        default:         return idle
        }
    }

    func fill(_ s: String) -> NSColor {
        switch s {
        case "needs":    return needsFill
        case "working":  return workingFill
        case "checking": return checkingFill
        case "paused":   return pausedFill
        case "await":    return awaitFill
        case "done":     return doneFill
        default:         return idleFill
        }
    }
}

/// Font weights a theme may push. Sizes are NOT themeable — they set density.
struct ThemeWeights {
    /// Project name in a group header.
    let groupTitle: NSFont.Weight
    /// Section captions in the settings pane.
    let sectionTitle: NSFont.Weight
}

/// The group header's status wash, as (top, bottom) alpha pairs. Two treatments
/// because a gradient washes out over a dark fill while a flat tint stays legible.
struct ThemeBandWash {
    let lightTop, lightBottom: CGFloat
    let lightHoverTop, lightHoverBottom: CGFloat
    let darkTop, darkBottom: CGFloat
    let darkHoverTop, darkHoverBottom: CGFloat

    func alphas(dark: Bool, hovered: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if hovered { return dark ? (darkHoverTop, darkHoverBottom) : (lightHoverTop, lightHoverBottom) }
        return dark ? (darkTop, darkBottom) : (lightTop, lightBottom)
    }
}

// MARK: The spec

struct ThemeSpec {
    /// Persisted in UserDefaults — never rename an existing id, or users silently
    /// fall back to the default theme on upgrade.
    let id: String
    let nameZH: String
    let nameEN: String
    let blurbZH: String
    let blurbEN: String

    let material: ThemeMaterial
    let surface: SurfaceStyle
    let pillStyle: PillStyle
    let tintStyle: TintStyle

    let palette: ThemePalette
    let metrics: ThemeMetrics
    let status: ThemeStatusPalette
    let weights: ThemeWeights
    let band: ThemeBandWash
}

// MARK: - Dynamic color helpers
//
// Theme files build their palettes with these. An appearance-adaptive NSColor
// re-evaluates its body per appearance, so a `.cgColor` resolved under a view's
// effectiveAppearance (see `NSColor.cg(in:)`) picks the right variant — which is
// how one palette serves both light and dark.

/// One color at two alphas, chosen by appearance.
func themeDyn(dark: NSColor, dAlpha: CGFloat, light: NSColor, lAlpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? dark.withAlphaComponent(dAlpha)
            : light.withAlphaComponent(lAlpha)
    }
}

/// Two distinct colors, chosen by appearance.
func themePick(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// Shorthand for the opaque sRGB literals the palettes are written in.
func themeRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

// MARK: - Painting a lobe

extension CALayer {
    /// Wear one shadow lobe. A layer carries exactly ONE shadow, so a two-lobe clay
    /// surface needs a second layer beneath it for the counter-glow.
    ///
    /// `scale` shrinks the whole recipe with a miniature (the settings swatch):
    /// full-size geometry on a half-size face reads as a different theme, not a
    /// smaller one. Lobe colors are static (white / black / a warm gray), so
    /// `.cgColor` needs no appearance resolution.
    ///
    /// Callers MUST also set `shadowPath` — see the task's performance rule; a
    /// shadow derived from layer alpha is recomputed on every frame of a list that
    /// reloads once a second.
    func applyShadowLobe(_ lobe: ShadowLobe, scale: CGFloat = 1) {
        shadowColor = lobe.color.cgColor
        shadowOffset = CGSize(width: lobe.offset.width * scale,
                              height: lobe.offset.height * scale)
        shadowRadius = lobe.blur * scale
        shadowOpacity = lobe.opacity
    }
}
