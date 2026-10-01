import Cocoa

// MARK: - Palette
//
// A deliberately small transcription of the app's default theme
// (`ThemeDefault.swift` — status accents at lines 102-118). The installer does NOT
// import Theme: that would drag in ThemeSpec, ThemeRegistry and AppSettings, i.e.
// the whole multi-theme runtime, for a one-shot window that never switches themes.
// These few values are copied instead, and only these.
enum IColor {
    private static func dyn(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let base      = dyn(dark: rgb(0.12, 0.12, 0.13), light: .white)
    static let card      = dyn(dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 1, alpha: 0.50))
    static let cardHi    = dyn(dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 0, alpha: 0.04))
    static let text      = dyn(dark: NSColor(white: 1, alpha: 0.94), light: NSColor(white: 0, alpha: 0.88))
    static let text2     = dyn(dark: NSColor(white: 1, alpha: 0.62), light: NSColor(white: 0, alpha: 0.56))
    static let text3     = dyn(dark: NSColor(white: 1, alpha: 0.40), light: NSColor(white: 0, alpha: 0.36))
    static let hairline  = dyn(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.07))
    static let track     = dyn(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.08))

    static let working   = rgb(0.27, 0.62, 1.00)     // sky blue
    static let done      = rgb(0.26, 0.82, 0.49)     // mint green
    static let doneFill  = rgb(0.12, 0.55, 0.31)
    static let needs     = rgb(1.00, 0.32, 0.34)     // coral red
    static let idle      = rgb(0.62, 0.66, 0.72)     // cool gray
    static let iris      = rgb(0.486, 0.549, 1.00)   // the agent dimension's hue
    /// Not from the app's theme — the one hue nothing else in this window uses, kept
    /// exclusively for "you still have to do something" (see ReloadHintView).
    static let amber     = rgb(1.00, 0.69, 0.18)
}

enum IFont {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

// MARK: - Glow
//
// The soft halo behind the app icon — the one flourish this layout allows itself.
// The artwork is a dark rounded tile, so on a dark window it needs something to
// sit in or it reads as a hole.
final class GlowView: NSView {
    private let glow = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        recolor()
        layer?.addSublayer(glow)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        glow.colors = [IColor.iris.withAlphaComponent(0.30).cgColor,
                       IColor.iris.withAlphaComponent(0).cgColor]
        glow.locations = [0, 1]
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { recolor() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // decorative only
}

// MARK: - Pill button

final class PillButton: NSButton {
    private var fill: NSColor = IColor.working
    private var hovering = false

    init(title: String, action: Selector?, target: AnyObject?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerCurve = .continuous
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 52          // the generous horizontal padding a pill needs
        s.height = 40
        return s
    }
    override var title: String { didSet { restyle(); invalidateIntrinsicContentSize() } }
    override var isEnabled: Bool { didSet { restyle() } }

    func setFill(_ c: NSColor) { fill = c; restyle() }

    private func restyle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: IFont.rounded(13, .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.75),
        ])
        let base = isEnabled ? fill : fill.withAlphaComponent(0.45)
        layer?.backgroundColor = (hovering && isEnabled
            ? base.blended(withFraction: 0.12, of: .white) ?? base
            : base).cgColor
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true;  restyle() }
    override func mouseExited(with event: NSEvent)  { hovering = false; restyle() }
    override func viewDidChangeEffectiveAppearance() { restyle() }

    // The focus ring follows the pill. Without these AppKit has no idea the button
    // is anything but its bounds — a self-drawn (borderless + layer-backed) control
    // gets a rectangular ring boxing in the rounded shape.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds,
                     xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

// MARK: - Thin progress bar

final class ProgressBar: NSView {
    private let fill = CALayer()
    private var value: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1.5
        fill.cornerRadius = 1.5
        layer?.addSublayer(fill)
        recolor()
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 3).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        layer?.backgroundColor = IColor.track.cgColor
        fill.backgroundColor = IColor.working.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { recolor() }

    func set(_ v: CGFloat, animated: Bool = true) {
        value = max(0, min(1, v))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        set(value, animated: false)
    }
}

// MARK: - Key cap

/// One key of a shortcut, drawn as a physical cap. Three of these beat writing
/// "⌘⇧P" inline: at 11pt the glyphs alone read as punctuation, and this is the one
/// line in the window the user is expected to act on rather than just read.
final class KeyCap: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ key: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.stringValue = key
        label.font = IFont.rounded(10.5, .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        recolor()

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
            // Square-ish for ⌘ and ⇧, wider only if a key needs it.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        layer?.backgroundColor = IColor.cardHi.cgColor
        layer?.borderColor = IColor.hairline.cgColor
        label.textColor = IColor.text
    }
    override func viewDidChangeEffectiveAppearance() { recolor() }
}

// MARK: - Reload hint

/// The one thing the finish screen has to make the user actually do. Installing the
/// extension is not enough on its own: the editor reads its extension index when the
/// extension host starts, so a window that was already open keeps running without it,
/// and jumps land with no highlight ring (T226). Nothing else on this screen is amber,
/// which is the whole point — it has to survive a glance that is already reading
/// "All set".
///
/// Hidden entirely when no editor was found: telling someone to reload a window they
/// don't have is worse than saying nothing.
final class ReloadHintView: NSView {
    private let glyph = NSImageView()
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")
    private let caps = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        if let img = NSImage(systemSymbolName: "arrow.clockwise",
                             accessibilityDescription: nil) {
            glyph.image = img.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false

        for l in [line1, line2] {
            l.font = IFont.rounded(11.5)
            l.lineBreakMode = .byWordWrapping
            l.translatesAutoresizingMaskIntoConstraints = false
        }
        // A wrapping label has no intrinsic height until it knows its width, and the
        // trailing constraint alone doesn't tell it — without these the bar collapses
        // to one clipped line. Widths are what the 440pt window leaves after the
        // margins, the glyph, and (for line 2) the key caps.
        line1.maximumNumberOfLines = 2
        line1.preferredMaxLayoutWidth = 440 - 26 * 2 - 12 - 15 - 9 - 12
        // One line only: it sits beside the caps and is centred on them, so a second
        // line would grow past the bottom edge the caps anchor.
        line2.maximumNumberOfLines = 1
        line2.preferredMaxLayoutWidth = 440 - 26 * 2 - 12 - 15 - 9 - 12 - 67

        caps.orientation = .horizontal
        caps.spacing = 3
        caps.translatesAutoresizingMaskIntoConstraints = false
        for k in ["⌘", "⇧", "P"] { caps.addArrangedSubview(KeyCap(k)) }

        for v: NSView in [glyph, line1, caps, line2] { addSubview(v) }
        recolor()

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            glyph.widthAnchor.constraint(equalToConstant: 15),
            glyph.heightAnchor.constraint(equalToConstant: 15),

            line1.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),
            line1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line1.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            caps.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            caps.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 6),

            line2.leadingAnchor.constraint(equalTo: caps.trailingAnchor, constant: 7),
            line2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line2.centerYAnchor.constraint(equalTo: caps.centerYAnchor),

            bottomAnchor.constraint(equalTo: caps.bottomAnchor, constant: 10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// - Parameter editors: display names of the editors the extension landed in.
    func configure(editors: [String]) {
        let names = editors.joined(separator: ILang.isZH ? "、" : ", ")
        let head = L("还差一步 · ", "One step left · ")
        let rest = L("\(names) 需要重载窗口，跳转高亮才会出现",
                     "reload \(names) to get jump highlights")
        let s = NSMutableAttributedString(
            string: head,
            attributes: [.font: IFont.rounded(11.5, .bold), .foregroundColor: IColor.amber])
        s.append(NSAttributedString(
            string: rest,
            attributes: [.font: IFont.rounded(11.5), .foregroundColor: IColor.text]))
        line1.attributedStringValue = s
        line2.stringValue = L("选 Reload Window，或重启编辑器",
                              "→ Reload Window, or restart it")
        line2.textColor = IColor.text2
    }

    private func recolor() {
        layer?.backgroundColor = IColor.amber.withAlphaComponent(0.13).cgColor
        layer?.borderColor = IColor.amber.withAlphaComponent(0.34).cgColor
        glyph.contentTintColor = IColor.amber
    }
    override func viewDidChangeEffectiveAppearance() { recolor() }
}

// MARK: - Capability card
//
// One of the three tiles. Its glyph box carries the whole state story: the tinted
// symbol while idle, a spinner while running, a tick when done, a dash when
// legitimately skipped (no editor installed is NOT a failure and must not read
// like one), a cross when it actually broke.
final class CapabilityCard: NSView {
    enum State { case idle, running, ok, skipped, failed }

    private let box = NSView()
    private let symbolView = NSImageView()
    private let shape = CAShapeLayer()      // tick / dash / cross
    private let spinner = CAShapeLayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let symbolName: String
    private let tint: NSColor

    init(symbol: String, tint: NSColor, name: String, status: String) {
        self.symbolName = symbol
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            symbolView.image = img.withSymbolConfiguration(
                .init(pointSize: 13, weight: .semibold))
        }

        for l in [shape, spinner] {
            l.fillColor = nil
            l.lineWidth = 1.9
            l.lineCap = .round
            l.lineJoin = .round
            l.isHidden = true
            box.layer?.addSublayer(l)
        }
        spinner.lineWidth = 1.7
        spinner.strokeColor = NSColor.white.cgColor

        nameLabel.font = IFont.rounded(11, .semibold)
        nameLabel.textColor = IColor.text
        nameLabel.stringValue = name
        nameLabel.alignment = .center

        statusLabel.font = IFont.rounded(10)
        statusLabel.textColor = IColor.text3
        statusLabel.stringValue = status
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        // One line, always: the verdicts are two words in either language, and a
        // second line would change the card's height mid-install.
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        box.addSubview(symbolView)
        let stack = NSStackView(views: [box, nameLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 26),
            box.heightAnchor.constraint(equalToConstant: 26),
            symbolView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 15),
            symbolView.heightAnchor.constraint(equalToConstant: 15),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        apply(.idle)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    override func layout() {
        super.layout()
        let b = box.bounds
        shape.frame = b
        spinner.frame = b
        spinner.path = CGPath(ellipseIn: b.insetBy(dx: 8, dy: 8), transform: nil)
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.7
    }

    private func tickPath() -> CGPath {
        let b = box.bounds
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.width * 0.30, y: b.height * 0.52))
        p.addLine(to: CGPoint(x: b.width * 0.44, y: b.height * 0.36))
        p.addLine(to: CGPoint(x: b.width * 0.72, y: b.height * 0.66))
        return p
    }
    private func dashPath() -> CGPath {
        let b = box.bounds
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.width * 0.32, y: b.midY))
        p.addLine(to: CGPoint(x: b.width * 0.68, y: b.midY))
        return p
    }
    private func crossPath() -> CGPath {
        let b = box.bounds
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.width * 0.34, y: b.height * 0.34))
        p.addLine(to: CGPoint(x: b.width * 0.66, y: b.height * 0.66))
        p.move(to: CGPoint(x: b.width * 0.66, y: b.height * 0.34))
        p.addLine(to: CGPoint(x: b.width * 0.34, y: b.height * 0.66))
        return p
    }

    func apply(_ state: State) {
        layoutSubtreeIfNeeded()
        shape.isHidden = true
        spinner.isHidden = true
        spinner.removeAnimation(forKey: "spin")
        symbolView.isHidden = false
        alphaValue = 1

        layer?.backgroundColor = IColor.card.cgColor

        switch state {
        case .idle:
            layer?.borderColor = IColor.hairline.cgColor
            box.layer?.backgroundColor = IColor.cardHi.cgColor
            box.layer?.borderColor = IColor.hairline.cgColor
            symbolView.contentTintColor = tint
        case .running:
            layer?.borderColor = IColor.working.withAlphaComponent(0.55).cgColor
            box.layer?.backgroundColor = IColor.working.cgColor
            box.layer?.borderColor = NSColor.clear.cgColor
            symbolView.isHidden = true
            spinner.isHidden = false
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 0.75
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        case .ok:
            layer?.borderColor = IColor.done.withAlphaComponent(0.45).cgColor
            box.layer?.backgroundColor = IColor.done.withAlphaComponent(0.16).cgColor
            box.layer?.borderColor = NSColor.clear.cgColor
            symbolView.isHidden = true
            shape.isHidden = false
            shape.strokeColor = IColor.done.cgColor
            shape.path = tickPath()
        case .skipped:
            layer?.borderColor = IColor.hairline.cgColor
            box.layer?.backgroundColor = IColor.idle.withAlphaComponent(0.18).cgColor
            box.layer?.borderColor = NSColor.clear.cgColor
            symbolView.isHidden = true
            shape.isHidden = false
            shape.strokeColor = IColor.idle.cgColor
            shape.path = dashPath()
        case .failed:
            layer?.borderColor = IColor.needs.withAlphaComponent(0.55).cgColor
            box.layer?.backgroundColor = IColor.needs.withAlphaComponent(0.18).cgColor
            box.layer?.borderColor = NSColor.clear.cgColor
            symbolView.isHidden = true
            shape.isHidden = false
            shape.strokeColor = IColor.needs.cgColor
            shape.path = crossPath()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        nameLabel.textColor = IColor.text
        statusLabel.textColor = IColor.text3
    }
}

// MARK: - Window

final class InstallerWindowController: NSObject {

    private let core = InstallerCore()
    private let window: NSWindow
    private let headline = NSTextField(labelWithString: "")
    private let subhead = NSTextField(labelWithString: "")
    private let cards: [InstallStep: CapabilityCard]
    private let primary: PillButton
    private let progress = ProgressBar()
    private let uninstallButton = NSButton()
    private let reloadHint = ReloadHintView()
    /// Collapses the hint out of the layout when there is nothing to reload. Both are
    /// switched together — zeroing only the height would leave its top gap behind.
    private var hintHeight: NSLayoutConstraint!
    private var hintGap: NSLayoutConstraint!
    private var launchAfterInstall = false

    override init() {
        let appCard = CapabilityCard(
            symbol: "macwindow", tint: IColor.working,
            name: "App", status: L("应用程序", "Applications"))
        let hookCard = CapabilityCard(
            symbol: "link", tint: IColor.done,
            name: "hook", status: L("自动接线", "Auto-wired"))
        let extCard = CapabilityCard(
            symbol: "chevron.left.forwardslash.chevron.right", tint: IColor.iris,
            name: L("扩展", "Extension"), status: L("精准跳转", "Precise jump"))
        cards = [.app: appCard, .hooks: hookCard, .extensions: extCard]
        primary = PillButton(title: "", action: nil, target: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 432),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = L("安装 SpectiX", "Install SpectiX")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = IColor.base
        window.center()

        primary.target = self
        primary.action = #selector(primaryTapped)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        headline.font = IFont.rounded(21, .bold)
        headline.textColor = IColor.text
        headline.alignment = .center

        subhead.font = IFont.rounded(12.5)
        subhead.textColor = IColor.text2
        subhead.alignment = .center
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 2

        let row = NSStackView(views: [appCard, hookCard, extCard])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        // Button and progress bar share one fixed-height slot so swapping between
        // them never shifts the layout above.
        let actionSlot = NSView()
        actionSlot.translatesAutoresizingMaskIntoConstraints = false
        actionSlot.addSubview(primary)
        actionSlot.addSubview(progress)
        progress.isHidden = true

        uninstallButton.isBordered = false
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstallTapped)
        uninstallButton.attributedTitle = NSAttributedString(
            string: L("卸载 SpectiX", "Uninstall SpectiX"),
            attributes: [.font: IFont.rounded(11.5, .medium),
                         .foregroundColor: IColor.text3,
                         .underlineStyle: NSUnderlineStyle.single.rawValue])
        uninstallButton.isHidden = true

        let glow = GlowView()
        glow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        // Drive the window from constraints, not from the contentRect above. With
        // the default autoresizing behaviour AppKit was free to shrink the window
        // to the subviews' minimum fitting width — and since the labels carry low
        // compression resistance, that minimum is a ~70pt sliver. Pinning the
        // content width (and closing the vertical chain to the bottom edge) makes
        // the layout the single source of the window's size.
        content.translatesAutoresizingMaskIntoConstraints = false
        // Opt every child out of autoresizing in one place. Doing it per-view is
        // how the first version collapsed: three of them (both labels and the
        // uninstall button, all created by AppKit initialisers that default to
        // true) kept their autoresizing constraints, which outranked the layout
        // below and flattened the whole vertical chain.
        for sub: NSView in [glow, icon, headline, subhead, row, reloadHint,
                            actionSlot, uninstallButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(sub)
        }
        reloadHint.isHidden = true

        // Collapsed until an install actually puts the extension somewhere; finish()
        // reopens both. Height 0 with the view hidden takes it out of the picture
        // without dropping it from the chain that gives the content its height.
        hintGap = reloadHint.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 0)
        hintHeight = reloadHint.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            hintGap, hintHeight,

            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),

            glow.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            glow.centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: -6),
            glow.widthAnchor.constraint(equalToConstant: 260),
            glow.heightAnchor.constraint(equalToConstant: 260),

            headline.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 15),
            headline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            headline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            subhead.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
            subhead.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            subhead.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            // Two lines' worth, fixed: the subhead carries the longest strings in
            // the window (and English runs longer than Chinese), so letting it size
            // itself would make the window jump between states and languages.
            subhead.heightAnchor.constraint(equalToConstant: 34),

            row.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: 20),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            // 94, not 84: the card's stack needs 26(glyph) + 6 + 16(name) + 6 +
            // 14(status) = 68pt plus 23pt of insets. At 84 the labels got
            // compressed and their descenders were clipped.
            row.heightAnchor.constraint(equalToConstant: 94),

            reloadHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            reloadHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),

            actionSlot.topAnchor.constraint(equalTo: reloadHint.bottomAnchor, constant: 20),
            actionSlot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            actionSlot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            actionSlot.heightAnchor.constraint(equalToConstant: 40),

            primary.centerXAnchor.constraint(equalTo: actionSlot.centerXAnchor),
            primary.centerYAnchor.constraint(equalTo: actionSlot.centerYAnchor),
            progress.centerYAnchor.constraint(equalTo: actionSlot.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: actionSlot.leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: actionSlot.trailingAnchor, constant: -14),

            uninstallButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            uninstallButton.topAnchor.constraint(equalTo: actionSlot.bottomAnchor, constant: 9),
            // Without this NSButton keeps its stock bezel padding and stands 62pt
            // tall for a single line of 11.5pt text.
            uninstallButton.heightAnchor.constraint(equalToConstant: 18),
            // Closes the vertical chain so the content has an unambiguous height.
            // It stays in the layout while hidden (isHidden doesn't drop
            // constraints), so the window doesn't resize between states.
            uninstallButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
        window.contentView = content

        renderIdle()
        // Size the window to the layout rather than trusting the contentRect above
        // — the two disagreed by 48pt, which showed up as dead space under the
        // uninstall link. renderIdle() runs first so the real strings are in place.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Resolved geometry, for the layout smoke test. A collapsed window is not
    /// something a filesystem assertion can catch — this makes the one number that
    /// matters (the content width) checkable without a screenshot.
    func layoutReport() -> String {
        guard let content = window.contentView else { return "no content view" }
        content.layoutSubtreeIfNeeded()
        let fit = content.fittingSize
        var lines = ["fitting \(Int(fit.width))×\(Int(fit.height))",
                     "frame \(Int(content.frame.width))×\(Int(content.frame.height))"]
        func note(_ label: String, _ v: NSView) {
            let f = v.frame
            lines.append("\(label) y=\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
        }
        for sub in content.subviews {
            let name: String
            switch sub {
            case is GlowView:      name = "glow"
            case primary:          name = "button"
            case headline:         name = "headline"
            case subhead:          name = "subhead"
            case uninstallButton:  name = "uninstall"
            case is NSStackView:   name = "cards"
            case is NSImageView:   name = "icon"
            default:               name = "slot"
            }
            note(name, sub)
        }
        return lines.joined(separator: "\n  ")
    }

    // MARK: States

    private func renderIdle() {
        let sandboxNote = L("⚠︎ 测试模式：只会写入沙箱目录",
                            "⚠︎ Test mode: writes to a sandbox directory only")
        if core.isAlreadyInstalled {
            headline.stringValue = "SpectiX"
            subhead.stringValue = core.paths.isSandboxed ? sandboxNote
                : L("已安装 · 版本 1.0", "Installed · version 1.0")
            primary.title = L("重新安装", "Reinstall")
            uninstallButton.isHidden = false
            cards[.app]?.setStatus(L("已就位", "In place"))
            cards[.hooks]?.setStatus(L("已接线", "Wired"))
            cards[.extensions]?.setStatus(L("已安装", "Installed"))
        } else {
            headline.stringValue = "SpectiX"
            subhead.stringValue = core.paths.isSandboxed ? sandboxNote
                : L("菜单栏上的 Claude Code 会话雷达",
                    "A radar for your Claude Code sessions, in the menu bar")
            primary.title = L("开始安装", "Install")
            uninstallButton.isHidden = true
        }
        InstallStep.allCases.forEach { cards[$0]?.apply(.idle) }
        primary.setFill(IColor.working)
        primary.isEnabled = true
        primary.isHidden = false
        progress.isHidden = true
        launchAfterInstall = false
    }

    @objc private func primaryTapped() {
        if launchAfterInstall { launchApp(); return }
        runInstall()
    }

    private func runInstall() {
        headline.stringValue = L("正在安装", "Installing")
        subhead.stringValue = L("大约需要几秒钟", "This takes a few seconds")
        uninstallButton.isHidden = true
        primary.isHidden = true
        progress.isHidden = false
        progress.set(0.04)
        hideReloadHint()    // a reinstall re-decides this from scratch
        InstallStep.allCases.forEach { cards[$0]?.apply(.idle) }

        // Filesystem work off the main thread so the spinner keeps turning; every
        // UI touch hops back.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let all = InstallStep.allCases
            let results = self.core.install { step in
                DispatchQueue.main.async {
                    self.cards[step]?.apply(.running)
                    self.cards[step]?.setStatus(L("进行中", "Working"))
                    if let i = all.firstIndex(of: step) {
                        self.progress.set(CGFloat(i) / CGFloat(all.count))
                    }
                }
            }
            DispatchQueue.main.async { self.finish(results) }
        }
    }

    private func finish(_ results: [StepResult]) {
        progress.set(1)
        for r in results {
            cards[r.step]?.apply(r.ok ? (r.skipped ? .skipped : .ok) : .failed)
            cards[r.step]?.setStatus(shortStatus(for: r))
        }
        // Only when the extension is really sitting in an editor. A skipped step (no
        // editor on this machine) and a failed one both mean there is nothing for the
        // user to reload, and the prompt would send them looking for a window that
        // isn't there.
        let ext = results.first { $0.step == .extensions }
        if let ext, ext.ok, !ext.skipped, !ext.editors.isEmpty {
            reloadHint.configure(editors: ext.editors)
            showReloadHint()
        }

        let failed = results.filter { !$0.ok }
        if failed.isEmpty {
            headline.stringValue = L("装好了", "All set")
            // Codex will not run a hook it has not been told to trust, and it never
            // says that it declined — the hook just never fires. So a Codex user who
            // is only told "All set" reads a working install as a broken one. This is
            // the one line on this screen everyone looks at, which is why the sentence
            // goes here rather than into a note beside the card.
            let hooks = results.first { $0.step == .hooks }
            switch hooks?.codex ?? .absent {
            case .wired:
                subhead.stringValue = L(
                    "重开会话即可看到状态。Codex 里还要跑一次 /hooks 批准，否则 hook 不会执行。",
                    "Restart your session to see it light up. In Codex, run /hooks once to approve — until then it stays inert.")
            case .failed:
                // Claude Code is wired, so the install is not a failure — but saying
                // nothing would leave the user believing Codex works too.
                subhead.stringValue = hooks?.codexNote ?? ""
            case .absent:
                subhead.stringValue = L("重开一个 Claude Code 会话即可看到状态",
                                        "Restart a Claude Code session to see it light up")
            }
            primary.title = L("启动 SpectiX", "Launch SpectiX")
            primary.setFill(IColor.doneFill)
            launchAfterInstall = true
        } else {
            headline.stringValue = L("安装未完成", "Install incomplete")
            subhead.stringValue = failed.first?.detail ?? L("有步骤失败了", "A step failed")
            primary.title = L("重试", "Try again")
            primary.setFill(IColor.working)
            launchAfterInstall = false
        }
        primary.isEnabled = true
        primary.isHidden = false
        progress.isHidden = true
    }

    /// Opens the amber hint and grows the window downwards. Growing matters: AppKit
    /// frames are bottom-left anchored, so resizing alone would push the title bar up
    /// the screen and the whole window would appear to jump at the exact moment the
    /// user is reading the result. Keeping the top edge fixed makes it read as the
    /// panel unfolding.
    private func showReloadHint() {
        guard let content = window.contentView else { return }
        reloadHint.isHidden = false
        hintGap.constant = 14
        hintHeight.isActive = false     // from here its own contents set the height

        resize(content, keepingTopEdge: window.frame.maxY)
    }

    /// Puts the window back to the height it has when there is nothing to reload.
    private func hideReloadHint() {
        guard let content = window.contentView, !reloadHint.isHidden else { return }
        reloadHint.isHidden = true
        hintGap.constant = 0
        hintHeight.isActive = true
        resize(content, keepingTopEdge: window.frame.maxY)
    }

    private func resize(_ content: NSView, keepingTopEdge top: CGFloat) {
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        var f = window.frame
        f.origin.y -= f.maxY - top
        window.setFrame(f, display: true, animate: false)
    }

    /// The cards are narrow, so they get a two-word verdict; the full sentence
    /// (paths, backup filenames) goes to the subhead when something needs saying.
    private func shortStatus(for r: StepResult) -> String {
        if !r.ok { return L("失败", "Failed") }
        if r.skipped { return L("已跳过", "Skipped") }
        switch r.step {
        case .app:        return L("应用程序", "Applications")
        case .hooks:
            switch r.codex {
            case .wired:  return L("Claude + Codex", "Claude + Codex")
            case .failed: return L("仅 Claude", "Claude only")
            case .absent: return L("7 个事件", "7 events")
            }
        case .extensions: return L("已装入", "Installed")
        }
    }

    private func launchApp() {
        let url = core.paths.installedApp
        if #available(macOS 11.0, *) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            NSWorkspace.shared.launchApplication(url.path)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    @objc private func uninstallTapped() {
        let alert = NSAlert()
        alert.messageText = L("卸载 SpectiX？", "Uninstall SpectiX?")
        alert.informativeText = L(
            "将移除 App、状态 hook、settings.json 与 Codex hooks.json 里的接线，以及编辑器扩展。你自己的其它 hook 不受影响。",
            "Removes the app, the status hook, its wiring in settings.json and in Codex's hooks.json, and the editor extension. Your own hooks are left untouched.")
        alert.addButton(withTitle: L("卸载", "Uninstall"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removed = core.uninstall()
        headline.stringValue = L("已卸载", "Uninstalled")
        subhead.stringValue = removed.isEmpty
            ? L("没找到已安装的内容", "Nothing was installed")
            : L("已移除：", "Removed: ") + removed.joined(separator: ILang.isZH ? "、" : ", ")
        InstallStep.allCases.forEach {
            cards[$0]?.apply(.idle)
            cards[$0]?.setStatus(L("已移除", "Removed"))
        }
        primary.title = L("重新安装", "Reinstall")
        primary.setFill(IColor.working)
        primary.isEnabled = true
        primary.isHidden = false
        progress.isHidden = true
        uninstallButton.isHidden = true
        hideReloadHint()    // nothing left to reload into
        launchAfterInstall = false
    }
}

// MARK: - Entry

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    private var controller: InstallerWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        controller = InstallerWindowController()
        controller?.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
