import Cocoa

// MARK: - Design system
//
// The shared vocabulary — spacing on an 8pt-ish grid, a few radii, fonts, and
// surface/status helpers — so the window, rows, chips and toasts all read as one
// material.
//
// Everything appearance-dependent resolves through `Theme.current`, a `ThemeSpec`
// picked at launch from `AppSettings.themeID` and swapped by `Theme.apply(_:)`.
// The accessors below deliberately keep their old names and shapes: a call site
// still writes `Theme.cardFill` or `Theme.card`, which is why making the app
// multi-theme required no changes at the ~390 places that read them. See
// `ThemeSpec.swift` for what a theme may vary and `ThemeRegistry.swift` for how
// to add one.
//
// Note the two tiers:
//   • `static let` — global constants a theme may NOT touch (spacing, row
//     heights). These encode information density tuned over many rounds; a reskin
//     must not be able to overturn it.
//   • `static var` — themed values, read through `current`.

enum Theme {

    // MARK: Current theme

    /// The active theme. Seeded from the persisted id; unknown ids fall back to
    /// the default rather than crashing or leaving the app unstyled.
    static private(set) var current: ThemeSpec = ThemeRegistry.spec(for: AppSettings.themeID)

    /// Swap the active theme. Callers must follow this with a wholesale UI rebuild
    /// — colors and radii are baked into layers when views are built, so already
    /// constructed views keep the old look until they are recreated. That rebuild
    /// is driven by `AppSettings.themeDidChange`; go through `AppSettings.themeID`
    /// rather than calling this directly.
    static func apply(_ id: String) {
        current = ThemeRegistry.spec(for: id)
    }

    // MARK: Spacing — NOT themeable (see header)

    static let pad: CGFloat   = 18    // window edge inset
    static let gap: CGFloat   = 10    // between sibling elements
    static let inset: CGFloat = 14    // inside a card

    /// Narrowest either surface may get — the main window's `minSize.width` and the
    /// floor of the popover's drag range are the same number on purpose, so the
    /// dropdown never ends up narrower than the panel showing the same content.
    /// (It doubles as the popover's factory width: the dropdown ships as narrow as
    /// it is allowed to be and grows by drag.)
    ///
    /// 384 fits the header's 2×2 metric grid with room to spare: each gauge row
    /// spends 112pt on fixed columns (card padding + icon + percentage + footnote),
    /// so two cards plus their gap and the window padding take 267pt and each micro
    /// bar still gets ~58pt.
    ///
    /// ⚠️ Raising this is not a free "give the grid more room" knob — it is a floor
    /// people are already parked on. It was briefly pushed to 440 to widen the
    /// bars; every window saved at the old minimum got shoved out to 440 and could
    /// no longer be dragged back, which reads as "the window won't resize any more".
    /// If a row looks cramped, fix that row's constraints (the real cause the one
    /// time this came up was a bar that wasn't pinned to its neighbours, so it sat
    /// at its 48pt preferred width and left a gap) — don't move this number.
    static let minPanelWidth: CGFloat = 384

    /// How far a list card sits inside its own table cell — and therefore how much
    /// room its shadow has (改这块前必读).
    ///
    /// A scroll view's clip rect crops EVERYTHING at its own edge, whatever the
    /// cells allow, and a cropped soft shadow doesn't fade — it stops, in a straight
    /// line. So the window's 18pt side margin is spent INSIDE the cell rather than
    /// outside the list: the list view insets itself by `pad - cardCellInset` (= 0)
    /// and each cell insets its card by this. The card lands on exactly the same
    /// 18pt margin as before, but its shadow now has 18pt of clip rect to fade
    /// across instead of 6pt. Clay's lobes are sized to that budget; see ThemeClay.
    static let cardCellInset: CGFloat = 18

    // MARK: Row metrics — NOT themeable (see header)

    static let rowHeight: CGFloat = 64
    static let agentRowHeight: CGFloat = 46   // expanded agent sublist node

    // MARK: Radii

    static var card: CGFloat  { current.metrics.card }
    static var group: CGFloat { current.metrics.group }   // project container (grouped list)
    static var chip: CGFloat  { current.metrics.chip }
    static let pill: CGFloat = 999    // capsule — a constant, not a theme choice
    static var windowRadius: CGFloat  { current.metrics.windowRadius }
    static var popoverRadius: CGFloat { current.metrics.popoverRadius }

    // MARK: Agent dimension
    //
    // Colors the 🤖 badge and the expanded agent sublist (axis, nodes, chips,
    // running pill). Deliberately NOT a session status color — it marks the
    // orthogonal "background agents" dimension — so it lives outside
    // `Status.accent` and the user's status-color overrides.

    static var agentAccent: NSColor { current.palette.agentAccent }
    static var agentDeep: NSColor   { current.palette.agentDeep }

    /// The 职位 tag's family tints. A subagent type reads as one of three families
    /// and the tag is colored by it, so a glance down the sublist counts "how many
    /// workers / how many managers" without reading a single word: worker-* keeps
    /// the iris, manager-* takes teal, and anything else (Explore, general-purpose,
    /// custom types) stays neutral gray so the colored ones actually mean something.
    static var agentManagerAccent: NSColor { current.palette.agentManagerAccent }
    static var agentNeutralAccent: NSColor { current.palette.agentNeutralAccent }

    /// The 命令标记 (`bash` / `shell`) tag. Orthogonal to session status like the agent
    /// iris, so it stays out of `Status.accent` and out of the user's status overrides.
    static var shellTagAccent: NSColor { current.palette.shellTagAccent }

    /// The expanded agent sublist's resting fill (方案 16). A slice paints it
    /// INSTEAD OF `cardFill` — one layer, one backgroundColor — so the segment
    /// reads as a distinct band of the same card. See docs/row-display.md.
    static var agentSegmentFill: NSColor { current.palette.agentSegmentFill }
    /// The iris hairline that opens that segment; nodes inside it keep `divider`.
    static var agentSeam: NSColor        { current.palette.agentSeam }

    // MARK: Paid tier
    //
    // Colors the PRO badge in Settings. Like the agent iris this marks an orthogonal
    // dimension rather than a session status, so it lives outside `Status.accent` and
    // the user's status-color overrides. The locked badge's solid bed is derived with
    // `deepenedForWhiteText()` rather than stored as a second tone.
    static var proAccent: NSColor { current.palette.proAccent }

    // MARK: Fonts
    //
    // Sizes are NOT themeable — they set density. Weights are (`current.weights`),
    // for the couple of places a theme legitimately wants a heavier title.

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
    // Rounded, but with monospaced (tabular) digits so a metric never nudges its
    // neighbours as the count changes — "12m"→"13m" or "6.1k"→"6.2k" keep every
    // glyph in place. Paired with fixed tab-stop columns in the usage line so the
    // ⏱ time / ◆ token figures line up vertically across rows regardless of width.
    static func roundedMono(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = rounded(size, weight)
        let d = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// Weight for a project name in a group header.
    static var groupTitleWeight: NSFont.Weight { current.weights.groupTitle }
    /// Weight for a section caption in the settings pane.
    static var sectionTitleWeight: NSFont.Weight { current.weights.sectionTitle }

    // MARK: Surfaces

    static var cardFill: NSColor      { current.palette.cardFill }
    static var cardFillHover: NSColor { current.palette.cardFillHover }
    /// Opaque fill for a single row floated out as its own card (方案 C hover). A
    /// translucent fill would let the rounded corners see through to the darker
    /// baseFill behind, dirtying the four corners ("四角漏底"); an opaque tile keeps
    /// the card solid and clean-cornered.
    static var cardFloat: NSColor     { current.palette.cardFloat }
    static var hairline: NSColor      { current.palette.hairline }
    static var hairlineHover: NSColor { current.palette.hairlineHover }
    /// Internal hairline inside a project container — the line under the header
    /// band and between consecutive sessions. A touch stronger than the outer
    /// hairline so the rows read as separated within the single enclosure.
    static var divider: NSColor       { current.palette.divider }
    /// Empty track of a micro progress bar (the header quota bars).
    static var barTrack: NSColor      { current.palette.barTrack }

    /// Opaque pane behind the main window's surface treatment.
    static var baseFill: NSColor      { current.palette.baseFill }

    /// How this theme bounds a surface — a hairline stroke, or light alone.
    static var surfaceStyle: SurfaceStyle { current.surface }
    /// Whether surfaces need a blur layer at all.
    static var material: ThemeMaterial    { current.material }

    /// The lighting recipe for a surface in `view`'s appearance, or nil when this
    /// theme bounds surfaces with a stroke instead of with light. Every clay
    /// surface goes through here rather than reading `current.surface` itself, so
    /// there is one place that resolves light-vs-dark (they are separate recipes,
    /// not the same numbers twice — see `SurfaceStyle.softShadow`).
    static func shadow(in view: NSView) -> ShadowSpec? {
        guard case .softShadow(let light, let dark) = current.surface else { return nil }
        return view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? dark : light
    }

    /// The group header's status wash over the fill (top alpha, bottom alpha).
    /// Every header paints one — idle/seen wear the neutral cool gray. `hovered`
    /// deepens the wash while the header (or its group) is lifted.
    static func bandAlphas(dark: Bool, hovered: Bool = false) -> (top: CGFloat, bottom: CGFloat) {
        current.band.alphas(dark: dark, hovered: hovered)
    }

    /// The window/popover-sized pane every other view is hosted in.
    ///
    /// A `.frostedGlass` theme returns a rounded frost pane (within-window blending,
    /// so it frosts the app's own opaque base — pair it with an OpaquePane behind —
    /// never the desktop). A `.clay` theme has nothing to frost: its canvas is the
    /// opaque base itself and depth comes from the cards' shadows, so it returns a
    /// plain transparent container and the app renders with ONE FEWER blur pass.
    ///
    /// Returns `NSView` for that reason: call sites only host subviews in it.
    static func surfacePane(material: NSVisualEffectView.Material, radius: CGFloat) -> NSView {
        guard current.material == .frostedGlass else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = radius
            v.layer?.cornerCurve = .continuous
            return v
        }
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous   // Apple's smooth "squircle" corner
        v.layer?.masksToBounds = true
        // Plain layer.cornerRadius + masksToBounds does NOT reliably clip an
        // NSVisualEffectView's material: the square corners of the blur leak out
        // as light/white triangles at a rounded host's corners (the "四角有白边"
        // bug). A rounded maskImage clips the material itself, cleanly.
        if radius > 0 { v.maskImage = roundedMask(radius: radius) }
        return v
    }

    /// A stretchable rounded-rect mask image for clipping NSVisualEffectView
    /// material. Center-stretch (capInsets) keeps corners crisp at any size.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Opaque backing pane
//
// Solid baseFill pane placed behind every within-window frost so no desktop
// bleeds through — the whole app renders opaque. Rounded to the host corner so
// its square edge doesn't poke past the glass. Re-resolves its fill on
// appearance flips — a static color would stick to whichever mode was active
// at creation (the old "window glowing in dark mode" bug).
final class OpaquePane: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func resolveColors() {
        layer?.backgroundColor = Theme.baseFill.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - Appearance-correct CGColor resolution
//
// CALayer.backgroundColor/borderColor take a CGColor, which is a *static*
// snapshot — assigning a dynamic NSColor's `.cgColor` captures whatever
// appearance happened to be current. To make glass layers track light/dark we
// resolve the dynamic color under the host view's effectiveAppearance, and the
// views re-resolve in viewDidChangeEffectiveAppearance.
extension NSColor {
    func cg(in view: NSView) -> CGColor {
        var resolved = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }

    // "#RRGGBB" from the sRGB components — how a custom ring color is persisted.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // Parse a "#RRGGBB" (or bare "RRGGBB") string back into an opaque sRGB color;
    // nil for anything malformed so the caller falls back to the default accent.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // Relative luminance per WCAG 2.1 (linearized sRGB), 0 (black) … 1 (white).
    var wcagLuminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent)
             + 0.0722 * lin(c.blueComponent)
    }

    // Darken toward black (uniform sRGB scale, hue preserved) until white text on
    // this color clears WCAG 4.5:1 — i.e. luminance ≤ 1.05/4.5 − 0.05 ≈ 0.183. Lets
    // a user's bright status color back a white-text filled pill without hand-tuning
    // a second "deep" shade, and doubles as the guard behind a theme's own fills
    // (see `Status.fill`) — a color that already passes comes back untouched.
    // Resolved per appearance, since the input may be light/dark dynamic: taking the
    // sRGB components up front would snapshot one tone and drop the other.
    func deepenedForWhiteText() -> NSColor {
        NSColor(name: nil) { appearance in
            var out = self
            appearance.performAsCurrentDrawingAppearance {
                guard let c = self.usingColorSpace(.sRGB) else { return }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                var k: CGFloat = 1, guardN = 0
                out = c
                while out.wcagLuminance > 0.183, guardN < 40 {
                    k -= 0.03; guardN += 1
                    out = NSColor(srgbRed: r * k, green: g * k, blue: b * k, alpha: 1)
                }
            }
            return out
        }
    }

    // The mirror of `deepenedForWhiteText` for the other pill vocabulary: a color
    // pushed AWAY from the bed it will be written on until the pair clears 4.5:1.
    //
    // Why a second helper rather than one more call to the first: under
    // `.tintedDeepText` the status color is the LABEL, not the fill, and the bed it
    // sits on follows the theme's surface — pale in light, dark in dark. So the
    // readable direction FLIPS with the appearance, and darkening (which is all
    // `deepenedForWhiteText` can do) is exactly wrong in dark mode: it lands a near
    // black label on a near black bed. Which way to move is therefore decided per
    // appearance, from the bed's own luminance.
    //
    // Only needed for colors with no hand-tuned deep tone — a user override, or one
    // theme's palette worn by another theme (see `Status.fill`). A theme's own fills
    // were authored against their own bed and come through untouched.
    func contrastedForTintedBed(_ bed: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = self
            appearance.performAsCurrentDrawingAppearance {
                guard let c = self.usingColorSpace(.sRGB),
                      let b = bed.usingColorSpace(.sRGB) else { return }
                let bedL = b.wcagLuminance
                func ratio(_ x: NSColor) -> CGFloat {
                    let l = x.wcagLuminance
                    return (max(l, bedL) + 0.05) / (min(l, bedL) + 0.05)
                }
                // Black-on-bed beats white-on-bed above this luminance — the same
                // 4.5:1 crossover `deepenedForWhiteText` is built around.
                let darken = bedL > 0.183
                let r = c.redComponent, g = c.greenComponent, bl = c.blueComponent
                var t: CGFloat = 0, guardN = 0
                out = c
                while ratio(out) < 4.5, guardN < 40 {
                    t += 0.03; guardN += 1
                    out = darken
                        ? NSColor(srgbRed: r * (1 - t), green: g * (1 - t), blue: bl * (1 - t), alpha: 1)
                        : NSColor(srgbRed: r + (1 - r) * t, green: g + (1 - g) * t,
                                  blue: bl + (1 - bl) * t, alpha: 1)
                }
            }
            return out
        }
    }

    /// The receiver moved by the same step that carries `from` to `to`.
    ///
    /// For "give this color the lift a card gets on hover" — which is NOT a fixed
    /// blend: on a light canvas the float is a hair brighter than the fill, on a dark
    /// one it is a visibly lighter tone, and a color that is already brighter than
    /// the fill (an agent segment, say) must move by that same step rather than
    /// toward the float's absolute value, which would drag it back DOWN.
    /// Resolved per appearance, since every input may be light/dark dynamic.
    func themeShifted(like from: NSColor, to: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = self
            appearance.performAsCurrentDrawingAppearance {
                guard let s = self.usingColorSpace(.sRGB),
                      let f = from.usingColorSpace(.sRGB),
                      let t = to.usingColorSpace(.sRGB) else { return }
                func step(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> CGFloat {
                    min(1, max(0, a + (c - b)))
                }
                out = NSColor(srgbRed: step(s.redComponent, f.redComponent, t.redComponent),
                              green: step(s.greenComponent, f.greenComponent, t.greenComponent),
                              blue: step(s.blueComponent, f.blueComponent, t.blueComponent),
                              alpha: 1)
            }
            return out
        }
    }

    /// The receiver composited over an opaque `base` (source-over), resolved per
    /// appearance: what a translucent fill actually looks like sitting on that bed.
    /// Alpha 1 out, so the result can stand in wherever an opaque fill is required.
    func themeOver(_ base: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = self
            appearance.performAsCurrentDrawingAppearance {
                guard let a = self.usingColorSpace(.sRGB),
                      let b = base.usingColorSpace(.sRGB) else { return }
                let t = a.alphaComponent
                out = NSColor(srgbRed: a.redComponent   * t + b.redComponent   * (1 - t),
                              green:   a.greenComponent * t + b.greenComponent * (1 - t),
                              blue:    a.blueComponent  * t + b.blueComponent  * (1 - t),
                              alpha: 1)
            }
            return out
        }
    }

    /// Blend `fraction` of the receiver into `other`, resolving BOTH under each
    /// appearance so a dynamic (light/dark) color survives the mix. `NSColor`'s own
    /// `blended(withFraction:of:)` needs concrete components, which an
    /// `NSColor(name:)` dynamic color does not have until it is resolved — mixing
    /// those directly returns nil.
    func themeBlended(_ fraction: CGFloat, into other: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = self
            appearance.performAsCurrentDrawingAppearance {
                guard let a = self.usingColorSpace(.sRGB),
                      let b = other.usingColorSpace(.sRGB) else { return }
                out = NSColor(srgbRed: a.redComponent   * fraction + b.redComponent   * (1 - fraction),
                              green:   a.greenComponent * fraction + b.greenComponent * (1 - fraction),
                              blue:    a.blueComponent  * fraction + b.blueComponent  * (1 - fraction),
                              alpha: 1)
            }
            return out
        }
    }
}

// MARK: - Status palette (semantic, shared with the menu bar)

extension Status {
    /// The single source of every session-status color. A user override (Settings →
    /// 状态颜色) wins over the theme, so switching themes never silently discards a
    /// color the user picked — and changing either recolors the list, header, dots,
    /// menu bar, focus ring and caption at once (they all read accent/tint/fill).
    static func accent(_ s: String) -> NSColor {
        if let custom = AppSettings.userColor(for: s) { return custom }
        // "rest" (the break-reminder banner/chip) is not a session status: no theme
        // slot, no user override — it wears the token tally's terracotta.
        if s == "rest" { return claudeOrange }
        return defaultAccent(s)
    }

    /// The CURRENT THEME's accent, ignoring any user override — Settings needs it
    /// to tell which palette (if any) the user's colors match, and to reset. Now
    /// that themes ship their own defaults, "⟲ 默认" means "back to THIS theme's
    /// color", which is exactly the behaviour you want.
    static func defaultAccent(_ s: String) -> NSColor {
        Theme.current.status.accent(s)
    }

    /// Tinted capsule background for status pills/chips. How the tint is derived is
    /// a theme decision: alpha reads correctly over glass (the blurred backdrop is
    /// meant to carry through), but on an opaque surface it lets that surface's own
    /// shadow bleed into the capsule, so such themes mix opaquely instead.
    static func tint(_ s: String) -> NSColor {
        let a = accent(s)
        switch Theme.current.tintStyle {
        case .alpha(let x): return a.withAlphaComponent(x)
        case .mix(let x):   return a.themeBlended(x, into: Theme.cardFill)
        }
    }

    /// The bed a `.tintedDeepText` pill lays its label on. Shared by the pill that
    /// paints it and by `fill`'s text derivation — contrasting the label against a
    /// bed computed slightly differently from the one actually drawn is how a
    /// "verified 4.5:1" quietly stops being true.
    static func pillBed(_ s: String, mix: CGFloat) -> NSColor {
        accent(s).themeBlended(mix, into: Theme.cardFill)
    }

    /// Collapse a status onto the palette bucket its header count belongs to, so the
    /// count pills always sum to the session total. The client-only overlays fold
    /// back to their semantic bucket: "checking" (amber, you're looking) is still a
    /// pending "needs"; "seen" (acked) and any unexpected value read as "idle".
    static func bucket(_ s: String) -> String {
        switch s {
        case "needs", "working", "paused", "await", "done": return s
        case "checking": return "needs"
        default:         return "idle"   // idle, seen, or anything unknown
        }
    }

    /// Claude's brand terracotta — token tallies. Deepens on light backgrounds and
    /// brightens on dark so it stays legible over the surface without any outline
    /// (a stroke on small numerals always reads as cheap).
    static var claudeOrange: NSColor { Theme.current.palette.claudeOrange }

    /// Emerald / bright mint for elapsed-time tallies — same light/dark legibility
    /// trick, kept distinct from the semantic "done" dot green.
    static var usageGreen: NSColor { Theme.current.palette.usageGreen }

    /// Model-family SEMANTIC tints for the usage line's third metric — Opus 紫 /
    /// Sonnet 青 / Haiku 琥珀.
    ///
    /// The color carries the family, so it must only ever be shown for a family we
    /// actually recognise — see `modelTint`. None of these are session-status hues
    /// (the model is an attribute, never a state), so they don't belong in the
    /// `Status.accent` override system.
    static var modelOpus: NSColor   { Theme.current.palette.modelOpus }
    static var modelSonnet: NSColor { Theme.current.palette.modelSonnet }
    static var modelHaiku: NSColor  { Theme.current.palette.modelHaiku }

    /// Tint for a humanised model label ("Opus 5" / "Sonnet 5" / "Haiku 4.5") — keyed on
    /// the FAMILY (the label's first word, which is how `modelLabel` builds it). An
    /// unrecognised family falls back to the neutral secondary label color rather than
    /// borrowing one of the three: these hues are a claim about which family this is, and
    /// painting an unknown model violet would assert something false.
    static func modelTint(_ label: String) -> NSColor {
        let s = label.lowercased()
        if s.hasPrefix("opus")   { return modelOpus }
        if s.hasPrefix("sonnet") { return modelSonnet }
        if s.hasPrefix("haiku")  { return modelHaiku }
        return .secondaryLabelColor
    }

    /// Quota-fullness tint: green under half, Claude-orange approaching the cap,
    /// red at/over 80% — a glanceable "how close am I" without reading the digits.
    /// Shared by the header's percentage figures and the micro progress bars.
    static func usageTint(_ pct: Int) -> NSColor {
        switch pct {
        case ..<50: return usageGreen
        case ..<80: return claudeOrange
        default:    return accent("needs")
        }
    }

    /// Solid, deepened status color for FILLED chips that carry white text. On a
    /// translucent surface a low-alpha tint lets the backdrop bleed through behind
    /// the label; an opaque fill gives the text a clean backdrop. A theme's tones are
    /// hand-tuned to clear 4.5:1 against white (ThemeDefault lists the measured
    /// ratios), green included — a bright mint would fail white-on-green, so the pill
    /// green is pushed darker than the row dot.
    static func fill(_ s: String) -> NSColor {
        // A user override (or one theme's palette worn by another — the presets in
        // Settings include every theme's own colors) ships no hand-tuned deep tone, so
        // this one is DERIVED. Which direction to derive is the CURRENT theme's call,
        // not the color's: the same hex has to be dark enough to carry white text under
        // `.solidWhiteText`, and — in dark mode — light enough to BE the text under
        // `.tintedDeepText`. Deriving one way for both is what made a bright preset
        // unreadable on clay: a deepened label on an already dark bed.
        if let custom = AppSettings.userColor(for: s) ?? (s == "rest" ? claudeOrange : nil) {
            switch Theme.current.pillStyle {
            case .solidWhiteText:
                return custom.deepenedForWhiteText()
            case .tintedDeepText(let bed):
                return custom.contrastedForTintedBed(pillBed(s, mix: bed))
            }
        }
        let base = Theme.current.status.fill(s)
        // A theme's own fills go through the same deepening — a no-op on the tuned
        // values, but it means a mistuned one degrades into a slightly darker pill
        // instead of an unreadable white label. Only under `.solidWhiteText`: a
        // tinted-bed theme paints this tone AS the label on a pale bed, and in dark
        // mode that tone is bright by design — deepening it there erases the pill.
        guard case .solidWhiteText = Theme.current.pillStyle else { return base }
        return base.deepenedForWhiteText()
    }

    /// How a filled status pill carries its label under the current theme.
    static var pillStyle: PillStyle { Theme.current.pillStyle }
}

// MARK: - Metric palette (本周效能's five bars)
//
// The design's neon five, in ONE place (T227 D1). Deliberately outside `Status.accent`:
// a metric is a measurement, not a session state, so the user's status-color overrides
// must not repaint it — and a shared source is what stops a sixth metric from arriving
// with an ad-hoc hex picked somewhere inside the panel.
//
// Hues sit 50–82° apart, so five bars stacked together stay tellable at a glance. All
// five are light (L 59–74%), which is why the figure printed ON a bar is near-black:
// white measures 1.7–1.9:1 on the brightest two and simply cannot be read.
//
// ONE palette for both appearances, user-decided 2026-08-13 after seeing six candidates
// rendered side by side (设计稿第十七–十九轮). A dimmed light variant was tried first and
// rejected twice over: the bars went muddy, and dimming a bar breaks the near-black
// figure that the whole colour scheme is built on. What light mode actually lacked was
// an EDGE, not a softer colour — a pale bar on a pale bed has no boundary to read. So
// light mode keeps these exact values and gains an outline instead (see NeonBar.draw).
//
// 工作 / 消耗 joined later (2026-10-10) as rows six and seven. Their hues sit only ~35–55°
// from the nearest of the five, which is why each also has its own glyph.
extension Metric {
    static func accent(_ m: Metric) -> NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch m {
        case .saved:   rgb = (0.176, 1.000, 0.690)   // #2DFFB0
        case .focus:   rgb = (0.486, 0.624, 1.000)   // #7C9FFF
        case .streak:  rgb = (1.000, 0.616, 0.239)   // #FF9D3D
        case .auto:    rgb = (0.961, 0.427, 1.000)   // #F56DFF
        case .control: rgb = (0.706, 1.000, 0.239)   // #B4FF3D
        case .work:    rgb = (1.000, 0.361, 0.478)   // #FF5C7A — the 🍅 clock's red, neon
        case .tokens:  rgb = (0.239, 0.878, 1.000)   // #3DE0FF
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
