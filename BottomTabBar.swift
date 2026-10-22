import Cocoa

// MARK: - Bottom tab bar (scheme 6)
//
// The main window's flat, in-flow bottom navigation — five equal icon+label
// tabs over a hairline top border (design/main-window-merge-alternatives.html
// `.m4toolbar`). In-flow means the content pane ends where the bar begins:
// nothing is overlaid, so the list never needs a contentInset. The selected
// tab tints blue. Each tab owns ⌘1–⌘5 as its keyEquivalent, active whenever
// the window is key.

final class BottomTabBar: NSView {

    var onSelect: ((Int) -> Void)?
    /// Quick-actions wrench at the far right (QuickActions.swift); the owner wires its drawer.
    let toolButton = QuickActionsButton()

    private let border = NSView()
    private var buttons: [TabItemButton] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        border.wantsLayer = true
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        // 2 / 8 rather than 6 / 10: five labels at the 384pt window floor clipped
        // "Sessions" by a few points (tools/skills-preview.sh, 2026-09-24).
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (i, tab) in MainTab.allCases.enumerated() {
            let b = TabItemButton(symbol: tab.symbol, label: tab.label, index: i)
            b.keyEquivalent = "\(i + 1)"
            b.keyEquivalentModifierMask = .command
            b.target = self
            b.action = #selector(tabClicked(_:))
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        buttons[0].isOn = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        addSubview(toolButton)

        NSLayoutConstraint.activate([
            toolButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: toolButton.leadingAnchor, constant: -4),
            divider.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            divider.widthAnchor.constraint(equalToConstant: 1),

            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tabClicked(_ sender: TabItemButton) {
        select(sender.index)
        onSelect?(sender.index)
    }

    func select(_ index: Int) {
        for (i, b) in buttons.enumerated() { b.isOn = i == index }
    }

    private func resolveColors() {
        border.layer?.backgroundColor = Theme.divider.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// One tab: 14pt symbol + 11.5pt label side by side, rounded-8 slice that
// brightens on hover and tints blue when selected. An NSButton so the ⌘number
// keyEquivalent routes through AppKit for free; subviews are inert (hitTest
// returns self) so every click lands on the button.
//
// Reused by the popover footer (variant A) as a flat deep-link button: there it
// never turns `isOn`, carries no keyEquivalent, and the permission-fix entry
// sets `warn` (amber) with an empty label (icon-only).
final class TabItemButton: NSButton {

    let index: Int
    var isOn = false { didSet { applyStyle() } }
    /// Amber icon/label for the permission-fix entry (never selected).
    var warn = false { didSet { applyStyle() } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let pair = NSStackView()
    /// Width the button needs to show icon + label without clipping.
    private(set) var labelledWidth: CGFloat = 0

    /// Icon-only when false (the label moves to the tooltip).
    var showsLabel = true {
        didSet {
            guard showsLabel != oldValue else { return }
            label.isHidden = !showsLabel || label.stringValue.isEmpty
            toolTip = showsLabel ? nil : label.stringValue
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: pair.fittingSize.width + 8, height: 30)
    }
    private let baseImage: NSImage?
    private var hovering = false

    init(symbol: String, label text: String, index: Int) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(cfg)
        self.index = index
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = Theme.rounded(11.5, .semibold)
        label.isHidden = text.isEmpty   // icon-only (permission-fix entry)

        // Icon + label centered as one unit.
        pair.setViews([icon, label], in: .leading)
        pair.orientation = .horizontal
        pair.spacing = 5
        pair.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pair)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            pair.centerXAnchor.constraint(equalTo: centerXAnchor),
            pair.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
        applyStyle()
        labelledWidth = intrinsicContentSize.width   // after applyStyle sets the icon image
    }
    required init?(coder: NSCoder) { fatalError() }

    // Subviews never swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyStyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        let blue = Status.accent("working")
        let fg: NSColor
        if warn {
            fg = .systemOrange
        } else if isOn {
            fg = blue
        } else {
            fg = hovering ? .labelColor : .secondaryLabelColor
        }
        if isOn {
            layer?.backgroundColor = blue.withAlphaComponent(0.14).cgColor
        } else if hovering {
            layer?.backgroundColor = Theme.cardFill.cg(in: self)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        label.textColor = fg
        icon.image = baseImage
        icon.contentTintColor = fg
    }
}
