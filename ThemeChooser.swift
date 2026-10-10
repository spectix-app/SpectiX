import Cocoa

// MARK: - Theme chooser (Settings → 主题)
//
// One card per shipped theme, each PREVIEWING ITSELF, plus a line naming which
// status palette is in use — an independent axis, not a competing one.
//
// The one rule everything here follows: paint from the `ThemeSpec` that was
// passed in, never from `Theme.current`. A chooser that read the live theme would
// draw every card in the active theme's colors — precisely what it must not do.
// That is why `ThemeSwatch` re-derives tint/pill treatment off its own spec
// instead of calling `Status.tint(_:)`.

/// A miniature of one theme: its canvas, one raised surface bounded the way that
/// theme bounds surfaces (hairline stroke vs. light), three status dots and one
/// status pill in that theme's pill style.
final class ThemeSwatch: NSView {

    /// The swatch is roughly half the size of a real row, so the theme's radii and
    /// shadow geometry are halved with it — full-size values on a 32pt face read as
    /// a different theme, not a smaller one.
    private static let scale: CGFloat = 0.5

    private static let dotStatuses = ["needs", "working", "done"]

    private let spec: ThemeSpec

    // A CALayer carries exactly ONE shadow, and a raised clay surface has two lobes,
    // so the upper-left counter-glow gets its own layer underneath the surface.
    private let glow = CALayer()
    private let surface = CALayer()
    private let rim = CALayer()          // 1pt top edge light — dark clay leans on it
    private var dots: [CALayer] = []
    private let pill = CALayer()
    private let pillBar = CALayer()      // stands in for the pill's label

    init(spec: ThemeSpec) {
        self.spec = spec
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        // Also crops the surface's drop shadow to the canvas, so a generous clay
        // shadow can't bleed onto the settings card behind the swatch.
        layer?.masksToBounds = true

        layer?.addSublayer(glow)
        layer?.addSublayer(surface)
        // The surface does NOT mask its sublayers: masking would clip away its own
        // drop shadow. Everything inside is inset far enough to stay off the corners.
        surface.addSublayer(rim)
        for _ in Self.dotStatuses {
            let d = CALayer()
            surface.addSublayer(d)
            dots.append(d)
        }
        pill.addSublayer(pillBar)
        surface.addSublayer(pill)

        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // a resize must not animate the mini
        defer { CATransaction.commit() }

        // Inset far enough that the scaled clay shadow (offset 3 + radius 3.5) still
        // lands inside the canvas rather than being cropped off at the bottom.
        let s = bounds.insetBy(dx: 7, dy: 7)
        guard s.width > 0, s.height > 0 else { return }
        surface.frame = s
        glow.frame = s

        let r = min(spec.metrics.card * Self.scale, s.height / 2)
        surface.cornerRadius = r
        surface.cornerCurve = .continuous
        glow.cornerRadius = r
        // Pre-rendered shadow path (the task's performance rule): never let
        // CoreAnimation derive a shadow from layer alpha, here or anywhere else.
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: s.size),
                          cornerWidth: r, cornerHeight: r, transform: nil)
        surface.shadowPath = path
        glow.shadowPath = path

        // Sublayer frames are in the surface's own coordinates (origin at 0,0), which
        // is unflipped — +y points up, so the rim sits at the TOP.
        rim.frame = CGRect(x: r, y: s.height - 1, width: max(0, s.width - 2 * r), height: 1)

        let dotD: CGFloat = 8
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: 9 + CGFloat(i) * 13, y: (s.height - dotD) / 2,
                             width: dotD, height: dotD)
            d.cornerRadius = dotD / 2
        }

        let pw: CGFloat = 30, ph: CGFloat = 14
        pill.frame = CGRect(x: s.width - 9 - pw, y: (s.height - ph) / 2, width: pw, height: ph)
        pill.cornerRadius = ph / 2
        pillBar.frame = CGRect(x: 8, y: (ph - 3) / 2, width: 14, height: 3)
        pillBar.cornerRadius = 1.5
    }

    private func resolveColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = spec.palette.baseFill.cg(in: self)
        surface.backgroundColor = spec.palette.cardFill.cg(in: self)

        switch spec.surface {
        case .hairline:
            surface.borderWidth = 1
            surface.borderColor = spec.palette.hairline.cg(in: self)
            surface.shadowOpacity = 0
            glow.shadowOpacity = 0
            rim.isHidden = true
        case .softShadow(let light, let darkSpec):
            let lighting = dark ? darkSpec : light
            surface.borderWidth = 0
            surface.applyShadowLobe(lighting.drop, scale: Self.scale)
            if let counter = lighting.counterGlow { glow.applyShadowLobe(counter, scale: Self.scale) }
            else { glow.shadowOpacity = 0 }
            rim.isHidden = lighting.rimHighlight == nil
            rim.backgroundColor = lighting.rimHighlight?.cgColor
        }

        for (i, d) in dots.enumerated() {
            d.backgroundColor = spec.status.accent(Self.dotStatuses[i]).cg(in: self)
        }

        // The pill previews `pillStyle`: a solid deepened block carrying white text,
        // or a pale bed carrying the deepened status color AS text.
        switch spec.pillStyle {
        case .solidWhiteText:
            pill.backgroundColor = spec.status.fill("done").cg(in: self)
            pillBar.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        case .tintedDeepText(let bed):
            pill.backgroundColor = spec.status.accent("done")
                .themeBlended(bed, into: spec.palette.cardFill).cg(in: self)
            pillBar.backgroundColor = spec.status.fill("done").cg(in: self)
        }
    }

    /// `Status.tint(_:)` for a theme that is not the current one — same rule, read
    /// off the passed-in spec. The active palette deliberately does NOT apply: a
    /// swatch answers "what does this theme look like", and the palette is a separate
    /// choice the line below the grid reports on.
    private func tint(_ s: String) -> NSColor {
        let a = spec.status.accent(s)
        switch spec.tintStyle {
        case .alpha(let x): return a.withAlphaComponent(x)
        case .mix(let x):   return a.themeBlended(x, into: spec.palette.cardFill)
        }
    }

}

// MARK: - One theme's card

/// Name + one-line blurb + a live swatch. Selection styling matches the 状态颜色
/// preset cards (scheme 8): accent-tinted bed, 1.5pt accent border, ✓ 使用中.
private final class ThemeChoiceCard: NSView {

    static let height: CGFloat = 100

    var onClick: (() -> Void)?

    private let check = NSTextField(labelWithString: "✓ " + L("使用中", "In use"))
    private var selected = false

    init(spec: ThemeSpec) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L(spec.nameZH, spec.nameEN))
        name.font = Theme.rounded(12, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        check.font = Theme.font(10, .medium)
        check.textColor = .controlAccentColor
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        let blurb = NSTextField(labelWithString: L(spec.blurbZH, spec.blurbEN))
        blurb.font = Theme.font(11, .regular)
        blurb.textColor = .secondaryLabelColor
        blurb.lineBreakMode = .byTruncatingTail
        blurb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurb)

        let swatch = ThemeSwatch(spec: spec)
        addSubview(swatch)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            check.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            check.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            blurb.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            blurb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            blurb.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),

            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            swatch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            swatch.heightAnchor.constraint(equalToConstant: 44),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        repaint()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    func set(selected on: Bool) {
        selected = on
        repaint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    private func repaint() {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : Theme.cardFill.cg(in: self)
        layer?.borderWidth = selected ? 1.5 : 1
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            : Theme.hairline.cg(in: self)
        check.isHidden = !selected
    }
}

// MARK: - The 主题 card

/// The whole 主题 section body: a grid of theme cards over a line naming the status
/// palette currently in use, with a shortcut to where it is chosen.
///
/// Self-contained on purpose — the settings pane just drops it into the column.
/// It watches `AppSettings.didChange` so editing a color in the 状态颜色 card below
/// updates the line immediately.
final class ThemeChooserCard: NSView {

    /// Fires with the id of the theme the user picked. The pane owns the switch
    /// itself because switching rebuilds every window (including this view), so it
    /// has to record where to land first.
    var onPick: ((String) -> Void)?

    /// Which palette the 状态颜色 card is currently set to. Injected rather than
    /// derived here: that card owns the preset list, and two places deciding
    /// independently what counts as "霓虹" is how the two labels drift apart.
    var currentPaletteName: (() -> String)?

    /// The user tapped 更改 — take them to the 状态颜色 card.
    var onEditColors: (() -> Void)?

    private let card = GlassCard(radius: Theme.card, glows: false)
    private var choices: [ThemeChoiceCard] = []
    private var choiceIDs: [String] = []
    private let line = NSView()
    private let lineLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    private static let lineHeight: CGFloat = 40

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        observer = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPaletteLine() }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func buildUI() {
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let title = NSTextField(labelWithString: L("外观主题", "Appearance theme"))
        title.font = Theme.rounded(14, .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let sub = NSTextField(labelWithString: L(
            "整套底色、圆角、材质与状态色；切换后窗口会重建一次",
            "A whole palette — surfaces, radii, material, status colors; switching rebuilds the windows once"))
        sub.font = Theme.font(11.5, .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])

        // ── theme cards, two per row (the grid grows downward as themes are added,
        //    which is the whole point of the registry) ──
        let gap: CGFloat = 8
        var rowBottom: NSLayoutYAxisAnchor = sub.bottomAnchor
        var rowGap: CGFloat = 10
        var rowLeader: ThemeChoiceCard?

        // Re-read the theme folder so a file dropped in since launch shows up.
        ThemeRegistry.reload()
        for (i, spec) in ThemeRegistry.all.enumerated() {
            let choice = ThemeChoiceCard(spec: spec)
            choiceIDs.append(spec.id)
            choice.onClick = { [weak self] in self?.onPick?(spec.id) }
            card.addSubview(choice)
            choices.append(choice)

            choice.heightAnchor.constraint(equalToConstant: ThemeChoiceCard.height).isActive = true
            if i % 2 == 0 {
                NSLayoutConstraint.activate([
                    choice.topAnchor.constraint(equalTo: rowBottom, constant: rowGap),
                    choice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
                    choice.trailingAnchor.constraint(equalTo: card.centerXAnchor, constant: -gap / 2),
                ])
                rowLeader = choice
                // A trailing odd card is its own row's bottom until a partner arrives.
                rowBottom = choice.bottomAnchor
                rowGap = gap
            } else {
                NSLayoutConstraint.activate([
                    choice.topAnchor.constraint(equalTo: rowLeader!.topAnchor),
                    choice.leadingAnchor.constraint(equalTo: card.centerXAnchor, constant: gap / 2),
                    choice.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
                ])
            }
        }

        // ── status-color line ────────────────────────────────────────────────────
        // The palette is an axis of its own: a theme picks the MATERIAL (shadows,
        // edges, pill shape), the palette picks the COLORS, and every combination is
        // legitimate. So this line simply states which palette is in use and offers
        // the way to it.
        //
        // It replaced an amber warning ("your custom colors override this theme's")
        // with a 用本主题配色 button. Nothing was actually in conflict — the two are
        // orthogonal — but framing it as one, in the app's "needs attention" color,
        // read as "you are holding it wrong" and pushed people back onto the theme's
        // own colors (T113).
        line.wantsLayer = true
        line.layer?.cornerRadius = 9
        line.layer?.cornerCurve = .continuous
        line.layer?.borderWidth = 1
        line.layer?.masksToBounds = true
        line.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(line)

        lineLabel.font = Theme.font(11, .regular)
        lineLabel.textColor = .secondaryLabelColor
        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(lineLabel)

        let edit = NSButton(title: L("更改", "Change"),
                            target: self, action: #selector(editColorsClicked))
        edit.isBordered = false
        edit.font = Theme.rounded(11, .semibold)
        edit.contentTintColor = .controlAccentColor
        edit.setContentCompressionResistancePriority(.required, for: .horizontal)
        edit.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(edit)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: rowBottom, constant: 10),
            line.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            line.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            line.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            line.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            lineLabel.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 11),
            lineLabel.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            edit.leadingAnchor.constraint(greaterThanOrEqualTo: lineLabel.trailingAnchor, constant: 8),
            edit.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -9),
            edit.centerYAnchor.constraint(equalTo: line.centerYAnchor),
        ])

        repaintSelection()
        refreshPaletteLine()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveLineColors()
    }

    /// Light exactly the card whose theme is stored.
    private func repaintSelection() {
        let current = AppSettings.themeID
        // Our own ids, not `ThemeRegistry.all[i]`: the registry can be reloaded
        // (a pick re-reads the folder) while this view is still alive.
        for (c, id) in zip(choices, choiceIDs) {
            c.set(selected: id == current)
        }
    }

    /// Restate which palette is in use. Always shown, unlike the warning it replaced:
    /// the point is that this axis EXISTS and is yours to set, which a line that only
    /// appears once you have already found it cannot make.
    func refreshPaletteLine() {
        let name = currentPaletteName?() ?? L("跟随主题", "Follow theme")
        lineLabel.stringValue = L("状态颜色：", "Status colors: ") + name
        resolveLineColors()
    }

    private func resolveLineColors() {
        // Neutral, not the amber "needs attention" register — this states a setting,
        // it does not report a problem.
        line.layer?.backgroundColor = Theme.barTrack.cg(in: self)
        line.layer?.borderColor = Theme.hairline.cg(in: self)
    }

    @objc private func editColorsClicked() { onEditColors?() }
}
