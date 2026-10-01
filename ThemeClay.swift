import Cocoa

// MARK: - Clay theme (soft opaque clay)
//
// Transcribed from `design/clay-theme.html`, 中饱和 (`data-sat="vivid"`) — the档
// the user selected. The 粉彩 (`soft`) variant is deliberately NOT shipped: it was
// the design's other option, not a second theme.
//
// Vocabulary: warm cream canvas, opaque raised surfaces shaped by light instead of
// strokes, low-saturation-but-still-separable status hues, generous radii.
//
// ── Why the two appearances are NOT one recipe ────────────────────────────────
// Light clay is textbook neumorphism: a white upper-left counter-glow pushes the
// surface out of the canvas. Dark clay cannot do that — over a dark base the white
// glow can only be given ~5% before everything looks fogged. So dark drops the
// counter-glow entirely and builds depth the way native dark UI does: the raised
// surface is simply LIGHTER than its canvas, with a 1pt rim light along the top
// edge and a deeper shadow below. (Q2, user-decided 2026-08-01.)
//
// Every value below carries its source hex from the design file so a later tweak
// can be traced back rather than re-guessed.

enum ThemeClay {

    // The agent dimension's iris. `vivid` happens to use the same hue in both
    // appearances (#8E95E2) — named once so the badge, axis, segment and seam are
    // provably one hue.
    private static let iris = themeRGB(0.557, 0.584, 0.886)   // #8E95E2

    static let spec = ThemeSpec(
        id: "clay",
        nameZH: "陶土",
        nameEN: "Clay",
        blurbZH: "软塑陶土 · 暖奶油底 + 双光源软阴影",
        blurbEN: "Soft clay · warm cream, twin-light shadows",

        material: .clay,

        // CSS box-shadow → CALayer mapping, applied to every lobe below:
        //   • offset y is NEGATED — CSS +y points down, an unflipped CALayer's +y
        //     points up, so CSS `6px 6px` becomes `(6, -6)`.
        //   • blur is HALVED — CSS blur-radius ≈ 2× CALayer `shadowRadius`.
        // `blur` here is therefore already in `shadowRadius` units; Phase 3 must
        // assign it straight across, not re-convert.
        //
        // ── Every lobe must fit `Theme.cardCellInset` (18pt) ─────────────────────
        // That is the whole budget a list card's shadow has before the scroll view's
        // clip rect cuts it — and a cut soft shadow doesn't fade, it ends in a hard
        // straight line. Reach = |offset| + 2×blur, so 18pt is the ceiling for both
        // lobes here. Anything you add later gets measured the same way.
        surface: .softShadow(
            light: ShadowSpec(
                // .clay: 6px 6px 14px rgba(163,155,140,.34) — blur pulled 7→6 so the
                // reach lands exactly on the 18pt budget.
                drop: ShadowLobe(offset: CGSize(width: 6, height: -6), blur: 6,
                                 color: themeRGB(0.639, 0.608, 0.549), opacity: 0.34),
                // .clay: -5px -5px 12px rgba(255,255,255,.90), tightened.
                //
                // The two lobes are NOT free to be the same size here. A card's drop
                // may overshoot downward as far as it likes — the row below paints
                // after it, so the overshoot lands behind that card. The counter-glow
                // travels the other way, over rows already painted, and all it has to
                // work with is the 8pt gap between groups; at the design's reach (5 +
                // 2×6 = 17pt) it hazes the bottom of the card above. Tightened to
                // ~12pt so only the faint tail crosses.
                counterGlow: ShadowLobe(offset: CGSize(width: -4, height: 4), blur: 4,
                                        color: .white, opacity: 0.90),
                // .clay: inset 0 1px 1px rgba(255,255,255, .90 × .7)
                rimHighlight: NSColor.white.withAlphaComponent(0.63)
            ),
            dark: ShadowSpec(
                // Deeper and pure black — a warm-gray shadow reads as haze on a dark base.
                drop: ShadowLobe(offset: CGSize(width: 6, height: -6), blur: 6,
                                 color: .black, opacity: 0.50),
                counterGlow: nil,                                     // see header (Q2)
                rimHighlight: NSColor.white.withAlphaComponent(0.08)   // Q2's edge light
            )
        ),

        // A solid deepened block is the heaviest thing on a calm warm row; clay
        // carries the label as colored TEXT on a pale bed instead. 34% is the
        // design's `.pill` mix — firmer than `tintStyle` because this bed has to
        // hold text, where a chip's tint only has to register as a color.
        pillStyle: .tintedDeepText(bed: 0.34),
        // Opaque mix, NOT alpha: over an opaque panel an alpha tint lets the
        // surface's own shadow show through the capsule and dirties it.
        tintStyle: .mix(0.24),

        palette: ThemePalette(
            baseFill:      themePick(dark: themeRGB(0.129, 0.122, 0.114),   // #211F1D
                                     light: themeRGB(0.937, 0.925, 0.902)), // #EFECE6

            // Opaque throughout — clay has no blur for a translucent fill to sit on.
            cardFill:      themePick(dark: themeRGB(0.169, 0.161, 0.149),   // #2B2926 --surface
                                     light: themeRGB(0.969, 0.961, 0.945)), // #F7F5F1
            // Hover lifts by BRIGHTENING to the highlight end of the surface
            // gradient; Phase 3 additionally deepens the shadow (`.clay-hi`).
            cardFillHover: themePick(dark: themeRGB(0.204, 0.192, 0.176),   // #34312D --surface-hi
                                     light: themeRGB(0.992, 0.988, 0.980)), // #FDFCFA
            // Already opaque, so unlike the glass theme this needs no separate
            // "don't let the corners see through" tone — it is the same lifted face.
            cardFloat:     themePick(dark: themeRGB(0.204, 0.192, 0.176),
                                     light: themeRGB(0.992, 0.988, 0.980)),

            // Clay bounds surfaces with light, not strokes. These stay defined
            // because a few places (inputs, the settings pane) still want a real
            // edge, but they are quiet by design.
            hairline:      themePick(dark: themeRGB(0.231, 0.216, 0.200),   // #3B3733 --border
                                     light: themeRGB(0.878, 0.859, 0.820)), // #E0DBD1
            hairlineHover: themePick(dark: themeRGB(0.290, 0.271, 0.247),
                                     light: themeRGB(0.831, 0.808, 0.761)),
            // The design's `--border` — literally what `.group .grow + .grow::before`
            // (the line between two rows) is painted with. It is the ONLY line inside a
            // clay enclosure, since the outer edge is bounded by light, so it carries
            // the whole "one slab, sliced" read and must not be quieter than the
            // hairline. (An earlier transcription had it weaker, on a note claiming
            // that matched the default theme; the default theme's divider is in fact
            // the STRONGER of the two — see Theme.divider.)
            divider:       themePick(dark: themeRGB(0.231, 0.216, 0.200),   // #3B3733
                                     light: themeRGB(0.878, 0.859, 0.820)), // #E0DBD1
            // The design's `--canvas-deep`, the same tone its `.well` (inset) class
            // uses — a progress track IS a well, so Phase 3's inset treatment lands
            // on exactly the color the design intended.
            barTrack:      themePick(dark: themeRGB(0.102, 0.098, 0.090),   // #1A1917
                                     light: themeRGB(0.902, 0.886, 0.855)), // #E6E2DA

            agentAccent:         iris,                                       // #8E95E2 both
            agentDeep:           themePick(dark: themeRGB(0.706, 0.729, 0.961),   // #B4BAF5
                                           light: themeRGB(0.290, 0.322, 0.690)), // #4A52B0
            agentManagerAccent:  themePick(dark: themeRGB(0.498, 0.847, 0.910),   // #7FD8E8
                                           light: themeRGB(0.122, 0.498, 0.549)), // #1F7F8C
            // The design's `--ink-3`, its own muted text tone — a neutral that
            // belongs to this palette rather than a borrowed cool gray.
            agentNeutralAccent:  themePick(dark: themeRGB(0.478, 0.451, 0.420),   // #7A736B
                                           light: themeRGB(0.604, 0.576, 0.541)), // #9A938A
            // 命令标记 blue, pulled toward slate so it sits in a warm clay palette
            // instead of looking pasted in from the default theme.
            shellTagAccent:      themePick(dark: themeRGB(0.541, 0.686, 0.902),   // #8AAFE6
                                           light: themeRGB(0.180, 0.376, 0.612)), // #2E609C

            // ⚠️ DERIVED, not transcribed — the design file has no agent-sublist mock.
            // Built to the rule in docs/row-display.md: land as bright as `cardFill`
            // while reading clearly iris.
            //
            // Light was measured against a real sublist and corrected: mixing iris
            // INTO the cream surface can only darken it (iris is darker than cream in
            // every channel), and at ~20% the band came out 8% darker than the rows
            // above it — reading as a dimmed strip rather than as another layer of the
            // same card. It is therefore authored directly instead: the same lightness
            // as `cardFill`, carried on a violet cast (B above R above G) rather than
            // on darkness.
            agentSegmentFill: themePick(dark: themeRGB(0.239, 0.235, 0.282),   // ≈ surface + 18% iris
                                        light: themeRGB(0.937, 0.929, 0.980)),
            // Likewise derived: strong enough to announce the segment, since on an
            // opaque warm face a divider-weight line in this hue would vanish.
            agentSeam: themePick(dark: themeRGB(0.384, 0.416, 0.722),
                                 light: themeRGB(0.651, 0.671, 0.871)),

            // ⚠️ DERIVED — the clay design file has no paid-tier mock. Pushed brighter
            // in dark and deeper in light than the default theme's amber: this canvas is
            // warm and opaque, so a mid amber would sit too close to the surface itself.
            proAccent: themePick(dark: themeRGB(0.929, 0.733, 0.361),     // #EDBB5C
                                 light: themeRGB(0.659, 0.439, 0.102)),   // #A8701A

            // `.usage .k` → `--claude-deep`: the metric is TEXT here, so it takes
            // the deep tone in light and the bright one in dark.
            claudeOrange: themePick(dark: themeRGB(0.961, 0.682, 0.502),    // #F5AE80
                                    light: themeRGB(0.639, 0.302, 0.133)),  // #A34D22
            // `.usage .t` → `--primary-deep`, the design's mint.
            usageGreen:   themePick(dark: themeRGB(0.651, 0.871, 0.765),    // #A6DEC3
                                    light: themeRGB(0.306, 0.620, 0.478)),  // #4E9E7A
            modelOpus:    themePick(dark: themeRGB(0.702, 0.616, 0.973),    // #B39DF8
                                    light: themeRGB(0.478, 0.388, 0.769)),  // #7A63C4
            modelSonnet:  themePick(dark: themeRGB(0.353, 0.820, 0.784),    // #5AD1C8
                                    light: themeRGB(0.180, 0.549, 0.525)),  // #2E8C86
            modelHaiku:   themePick(dark: themeRGB(0.941, 0.722, 0.400),    // #F0B866
                                    light: themeRGB(0.659, 0.463, 0.086))   // #A87616
        ),

        // Softer, rounder than the glass theme — clay's whole read is "pressed out
        // of a soft slab", which tight corners fight.
        metrics: ThemeMetrics(
            card: 18,          // --r-card  (default 13)
            group: 20,         // --r-group (default 14)
            chip: 12,          // --r-chip  (default 9)
            windowRadius: 22,  // --r-window (default 10)
            // The design has no popover mock; it matches the window, exactly as the
            // default theme keeps the two equal.
            popoverRadius: 22
        ),

        status: ThemeStatusPalette(
            // 中饱和: pulled back from the glass theme's glow, but deliberately NOT
            // all the way to the design's 粉彩 option — that lost red-vs-amber
            // separability at arm's length, which a status color cannot afford.
            needs:    themePick(dark: themeRGB(0.941, 0.451, 0.416),   // #F0736A / #E8756E
                                light: themeRGB(0.910, 0.459, 0.431)),
            working:  themePick(dark: themeRGB(0.420, 0.659, 0.910),   // #6BA8E8 / #74A8E0
                                light: themeRGB(0.455, 0.659, 0.878)),
            checking: themePick(dark: themeRGB(0.941, 0.722, 0.290),   // #F0B84A / #E9B85A
                                light: themeRGB(0.914, 0.722, 0.353)),
            paused:   themePick(dark: themeRGB(0.753, 0.467, 0.878),   // #C077E0 / #B87FD6
                                light: themeRGB(0.722, 0.498, 0.839)),
            await:    themePick(dark: themeRGB(0.310, 0.780, 0.706),   // #4FC7B4 / #58C2B0
                                light: themeRGB(0.345, 0.761, 0.690)),
            done:     themePick(dark: themeRGB(0.333, 0.816, 0.588),   // #55D096 / #6FCFA0
                                light: themeRGB(0.435, 0.812, 0.627)),
            idle:     themePick(dark: themeRGB(0.573, 0.549, 0.518),   // #928C84 / #ADA79D
                                light: themeRGB(0.678, 0.655, 0.616)),

            // The design's `-deep` tones. NOTE the inversion versus the glass theme:
            // these are DARK in light mode and LIGHT in dark mode, because under
            // `.tintedDeepText` they are the pill's TEXT color over a pale tinted
            // bed — not a fill carrying white text. Phase 3 (3.3) is what makes that
            // switch real; until then filled pills will look wrong, as documented in
            // the task's Session 2 中间态 note.
            needsFill:    themePick(dark: themeRGB(1.000, 0.600, 0.565),   // #FF9990 / #A8332B
                                    light: themeRGB(0.659, 0.200, 0.169)),
            workingFill:  themePick(dark: themeRGB(0.592, 0.776, 0.961),   // #97C6F5 / #1F5C99
                                    light: themeRGB(0.122, 0.361, 0.600)),
            checkingFill: themePick(dark: themeRGB(1.000, 0.831, 0.471),   // #FFD478 / #8A5C05
                                    light: themeRGB(0.541, 0.361, 0.020)),
            pausedFill:   themePick(dark: themeRGB(0.863, 0.647, 0.941),   // #DCA5F0 / #6B3585
                                    light: themeRGB(0.420, 0.208, 0.522)),
            awaitFill:    themePick(dark: themeRGB(0.561, 0.878, 0.816),   // #8FE0D0 / #0F6E62
                                    light: themeRGB(0.059, 0.431, 0.384)),
            doneFill:     themePick(dark: themeRGB(0.498, 0.902, 0.706),   // #7FE6B4 / #24785A
                                    light: themeRGB(0.141, 0.471, 0.353)),
            idleFill:     themePick(dark: themeRGB(0.722, 0.698, 0.667),   // #B8B2AA / #5E584F
                                    light: themeRGB(0.369, 0.345, 0.310))
        ),

        // Q3 (user-decided): clay pushes titles one step heavier. Only weight moves —
        // sizes stay global, so density is unchanged. Takes effect once step 3.8
        // wires these accessors up; today nothing reads them.
        weights: ThemeWeights(
            groupTitle: .heavy,
            sectionTitle: .bold
        ),

        // Lighter washes than the glass theme's. There the wash sits on a
        // translucent tile over a blur, which eats saturation; on an opaque warm
        // face the same alphas would read as a slab of flat color and overpower the
        // row content.
        band: ThemeBandWash(
            lightTop: 0.22, lightBottom: 0.12,
            lightHoverTop: 0.30, lightHoverBottom: 0.18,
            darkTop: 0.20, darkBottom: 0.20,
            darkHoverTop: 0.28, darkHoverBottom: 0.28
        )
    )
}
