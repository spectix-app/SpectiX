import Cocoa

// MARK: - Default theme (frosted glass)
//
// The look SpectiX shipped with, lifted verbatim out of `Theme`'s old
// compile-time constants into a `ThemeSpec`. Every value below is a straight
// transcription — if any number here differs from what `Theme.swift` held before
// the multi-theme refactor, that is a BUG, not a tweak. The whole point of this
// theme is that turning `Theme` into a runtime-switchable indirection changed
// nothing on screen. The one deliberate exception is the status ACCENT row, which
// was re-picked as the factory status palette (see its comment down there).
//
// Its vocabulary: translucent white tiles over a within-window frost, bounded by a
// hairline, with saturated status accents that glow over glass.

enum ThemeDefault {

    // The agent dimension's iris, named once so the badge, the axis, the sublist
    // fill and its seam are provably the same hue rather than four near-misses.
    private static let iris     = themeRGB(0.486, 0.549, 1.00)
    private static let irisDeep = themeRGB(0.353, 0.420, 0.961)

    static let spec = ThemeSpec(
        id: "default",
        nameZH: "默认",
        nameEN: "Default",
        blurbZH: "磨砂玻璃 · 半透明面 + 细描边",
        blurbEN: "Frosted glass · translucent tiles, hairline edges",

        material: .frostedGlass,
        surface: .hairline,
        pillStyle: .solidWhiteText,
        // Status.tint was `accent × 0.18` — the blurred backdrop is meant to carry
        // through a glass capsule, so alpha is the right operator here.
        tintStyle: .alpha(0.18),

        palette: ThemePalette(
            // Opaque pane behind the within-window frost. White in light; a deep
            // neutral in dark so the HUD material frosts into a dark panel instead
            // of glowing white.
            baseFill: themePick(dark: themeRGB(0.12, 0.12, 0.13), light: .white),

            // Glass tints — appearance-adaptive so the same vocabulary reads as
            // real frosted glass in BOTH appearances. Dark brightens (white over a
            // dark blur); light lays a translucent white tile on the light blur.
            cardFill:      themeDyn(dark: .white, dAlpha: 0.06, light: .white, lAlpha: 0.50),
            cardFillHover: themeDyn(dark: .white, dAlpha: 0.13, light: .white, lAlpha: 0.72),
            // OPAQUE fill for a single row floated out as its own card. A
            // translucent fill would let the rounded corners see through to the
            // darker baseFill behind, dirtying the four corners.
            cardFloat:     themePick(dark: themeRGB(0.23, 0.23, 0.245), light: themeRGB(1, 1, 1)),

            hairline:      themeDyn(dark: .white, dAlpha: 0.12, light: .black, lAlpha: 0.07),
            hairlineHover: themeDyn(dark: .white, dAlpha: 0.22, light: .black, lAlpha: 0.13),
            // Internal hairline inside a project container — a touch stronger than
            // the outer one so rows read as separated within the single enclosure.
            divider:       themeDyn(dark: .white, dAlpha: 0.08, light: .black, lAlpha: 0.06),
            barTrack:      themeDyn(dark: .white, dAlpha: 0.08, light: .black, lAlpha: 0.08),

            // Agent-dimension iris. Deliberately NOT a session status color.
            agentAccent:         iris,
            agentDeep:           irisDeep,
            agentManagerAccent:  themeRGB(0.310, 0.753, 0.847),
            // A real cool gray, NOT `.secondaryLabelColor`: that semantic color is
            // already partly transparent and washes out once alpha is applied twice.
            agentNeutralAccent:  themeRGB(0.580, 0.620, 0.700),
            // 命令标记 blue. Split per mode because the tag paints its own text in this
            // tone over a 0.22 wash of it: one blue cannot be both bright enough on the
            // dark bed and dark enough to stay readable on the light frost.
            shellTagAccent:      themePick(dark:  themeRGB(0.361, 0.663, 1.000),   // #5CA9FF
                                           light: themeRGB(0.078, 0.427, 0.784)),  // #146DC8
            // Agent segment: as bright as `cardFill` (0.06 / 0.50) but iris. Dark
            // takes the accent straight — it is bright enough to lift the tile at a
            // hair more alpha. Light cannot: iris at 0.5 over a light frost reads as
            // a saturated purple block, so it is pre-mixed toward white and carried
            // at a slightly higher alpha to land at the same lightness.
            agentSegmentFill: themeDyn(dark: iris, dAlpha: 0.10,
                                       light: themeRGB(0.88, 0.90, 1.00), lAlpha: 0.62),
            // Stronger than `divider` (0.08 / 0.06) on purpose — it is the one line
            // that announces the segment, and a hairline at divider alpha in a hue
            // this pale would simply not be seen.
            agentSeam: themeDyn(dark: iris, dAlpha: 0.45, light: irisDeep, lAlpha: 0.38),

            // Paid tier. Bright amber in dark; a deepened one in light, where the badge
            // sits on a white frosted tile and a mid amber would wash out.
            proAccent: themePick(dark: themeRGB(0.878, 0.651, 0.235),     // #E0A63C
                                 light: themeRGB(0.722, 0.498, 0.118)),   // #B87F1E

            // Claude's brand terracotta — token tallies. Deepens on light and
            // brightens on dark so it stays legible over glass without an outline.
            claudeOrange: themePick(dark: themeRGB(0.96, 0.58, 0.41), light: themeRGB(0.83, 0.40, 0.25)),
            // Emerald / bright mint for elapsed time — kept distinct from the
            // semantic "done" dot green.
            usageGreen:   themePick(dark: themeRGB(0.34, 0.85, 0.56), light: themeRGB(0.10, 0.60, 0.40)),
            // Model-family hues (#b39df8 / #5ad1c8 / #f0b866 in dark; same hues
            // deepened for light).
            modelOpus:    themePick(dark: themeRGB(0.70, 0.62, 0.97), light: themeRGB(0.45, 0.35, 0.80)),
            modelSonnet:  themePick(dark: themeRGB(0.35, 0.82, 0.78), light: themeRGB(0.05, 0.50, 0.47)),
            modelHaiku:   themePick(dark: themeRGB(0.94, 0.72, 0.40), light: themeRGB(0.68, 0.45, 0.10))
        ),

        metrics: ThemeMetrics(
            card: 13,
            group: 14,
            chip: 9,
            // macOS titled-window corner; popover matches.
            windowRadius: 10,
            popoverRadius: 10
        ),

        status: ThemeStatusPalette(
            // The factory status palette: fully saturated hues that glow over glass
            // and stay distinguishable at dot size. A user override
            // ("ringColor-<status>") still wins over every one of these.
            needs:    themeRGB(1.000, 0.176, 0.333),   // #FF2D55 rose red
            working:  themeRGB(0.000, 0.690, 1.000),   // #00B0FF sky blue
            checking: themeRGB(1.000, 0.831, 0.000),   // #FFD400 amber — "查看中" (client-only)
            paused:   themeRGB(0.878, 0.251, 0.984),   // #E040FB fuchsia — "暂停" (interrupt)
            await:    themeRGB(0.000, 0.749, 0.647),   // #00BFA5 teal — "等待" (background shell running)
            done:     themeRGB(0.000, 0.902, 0.463),   // #00E676 mint green
            idle:     themeRGB(0.471, 0.565, 0.612),   // #78909C cool gray

            // Solid, deepened shades for FILLED chips carrying white text. Every one
            // is hand-tuned to clear WCAG 4.5:1 against white (measured ratios below),
            // green included — a bright mint would fail white-on-green, so the pill
            // green is pushed darker than the row dot. Changing any of these means
            // re-measuring: white text on a 4.2:1 fill is the failure this guards.
            needsFill:    themeRGB(0.86, 0.20, 0.21),   // #DB3336 — 4.62:1
            workingFill:  themeRGB(0.05, 0.42, 0.95),   // #0D6BF2 — 4.76:1
            checkingFill: themeRGB(0.65, 0.39, 0.02),   // #A66305 — 4.75:1
            pausedFill:   themeRGB(0.64, 0.26, 0.74),   // #A342BD — 5.15:1
            awaitFill:    themeRGB(0.000, 0.502, 0.455),   // #008074 — 4.84:1 (#00897B measured 4.32:1, darkened)
            doneFill:     themeRGB(0.11, 0.52, 0.29),   // #1C854A — 4.69:1
            idleFill:     themeRGB(0.42, 0.46, 0.52)    // #6B7585 — 4.65:1
        ),

        weights: ThemeWeights(
            groupTitle: .bold,
            sectionTitle: .semibold
        ),

        // LIGHT = a bold saturated top→bottom gradient, DARK = a flat even tint
        // (top == bottom): a gradient washes out over the dark fill, a flat fill
        // stays legible. `hovered` deepens the wash while the header is lifted.
        band: ThemeBandWash(
            lightTop: 0.40, lightBottom: 0.24,
            lightHoverTop: 0.50, lightHoverBottom: 0.32,
            darkTop: 0.40, darkBottom: 0.40,
            darkHoverTop: 0.52, darkHoverBottom: 0.52
        )
    )
}
