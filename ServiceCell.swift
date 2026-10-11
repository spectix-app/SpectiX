import Cocoa

// MARK: - ServiceCell (T336)
//
// One server a session left listening, drawn as the last slices of its PROJECT's card —
// under that project's own title, never pooled with other projects' servers (user,
// 2026-10-06; this replaced a single tray below the whole list). A server is not a
// session state, so it doesn't hold its session row on 等待; this row is where it shows.
//
//   ⏻ :9685  静态网页 · 开了 6 天 · 可能忘关了              [打开] [停止]
//
// Same enclosure recipe as AgentCell (a GroupCard slice continuing the project card),
// so collapse / group hover lift / fade-out all come from the list for free.
final class ServiceCell: NSTableCellView, Hoverable {
    static let rowHeight: CGFloat = 34

    // A hue outside the status palette, for the same reason as the shell tag: a server
    // is not a state, and a status tone would claim to be one. Amber = probably forgotten.
    static var accent: NSColor { dyn(dark: 0x9FA8DA, light: 0x5361B5) }
    static var staleAccent: NSColor { dyn(dark: 0xE0A84A, light: 0xA8670C) }

    private let card = GroupCard(radius: Theme.group)
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var buttons: [ServiceButton] = []
    private var service: ServiceInfo?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        letShadowsEscape()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        icon.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)

        let open = ServiceButton(title: L("打开", "Open"), danger: false) { [weak self] in
            if let s = self?.service { ServiceProbe.open(s) }
        }
        let stop = ServiceButton(title: L("停止", "Stop"), danger: true) { [weak self] in
            // The row leaves on the next poll, once the process is really gone.
            if let s = self?.service { ServiceProbe.stop(s) }
        }
        buttons = [open, stop]
        for b in buttons {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            card.addSubview(b)
        }

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cardCellInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.cardCellInset),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Icon in the status-dot column (cell x 44, as AgentCell's thread); text on the
            // rows' title vertical (55), so a server lines up under the sessions above it.
            icon.centerXAnchor.constraint(equalTo: card.leadingAnchor, constant: 38),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 55),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -8),
            stop.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            stop.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: stop.leadingAnchor, constant: -4),
            open.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Unlike ChildCell this does NOT override hitTest to claim every click: the two
    // buttons must get theirs.

    func setHovered(_ lift: HoverLift, groupFrame: NSRect?, groupRole: SliceRole?, animated: Bool) {
        card.setHover(lift,
                      groupFrame: groupFrame.map { card.convert($0, from: self) },
                      groupRole: groupRole,
                      animated: animated)
    }

    func setSelected(_ on: Bool, animated: Bool) { card.setSelected(on, animated: animated) }

    // `isLastRow` rounds the project card's bottom — servers are always its last rows.
    func configure(_ s: ServiceInfo, isLastRow: Bool) {
        service = s
        card.configure(role: isLastRow ? .bottom : .middle, isHeaderBand: false, topDivider: true)
        card.setAccent("idle")
        let tint = s.stale ? Self.staleAccent : Self.accent

        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let img = NSImage(systemSymbolName: "powerplug", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: nil)
        icon.image = img?.withSymbolConfiguration(cfg)
        icon.contentTintColor = tint

        let up = Self.uptime(Date().timeIntervalSince1970 - s.start)
        let t = NSMutableAttributedString(string: ":\(s.port)", attributes: [
            .font: Theme.roundedMono(11.5, .semibold), .foregroundColor: tint])
        t.append(NSAttributedString(string: "  \(s.kind) · " + L("开了 \(up)", "up \(up)"), attributes: [
            .font: Theme.font(11, .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        if s.stale {
            t.append(NSAttributedString(string: " · " + L("可能忘关了", "maybe forgotten"), attributes: [
                .font: Theme.font(11, .semibold), .foregroundColor: Self.staleAccent]))
        }
        // An attributed string carries its own line breaking and would wrap onto a second
        // line at popover width — the row is one line tall.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        t.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: t.length))
        label.attributedStringValue = t
        buttons[0].toolTip = "http://localhost:\(s.port)/"
        buttons[1].toolTip = L("结束这个服务（端口 \(s.port)）", "Stop this server (port \(s.port))")
        card.setHover(.none, animated: false)
    }

    // fmtDur tops out at hours ("144.0h"); a server forgotten for days should say days.
    static func uptime(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        return s >= 86_400 ? L("\(s / 86_400) 天", "\(s / 86_400)d") : UsageMetricsView.fmtDur(s)
    }

    private static func dyn(dark: UInt32, light: UInt32) -> NSColor {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light)
        }
    }
}

// Small outlined text button. Hover tints it — blue for 打开, red for 停止 — so the
// destructive one announces itself before the click, not after.
final class ServiceButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bg = CALayer()
    private let danger: Bool
    private let action: () -> Void
    private var hovered = false { didSet { restyle() } }

    init(title: String, danger: Bool, action: @escaping () -> Void) {
        self.danger = danger
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerRadius = 6
        bg.cornerCurve = .continuous
        bg.borderWidth = 1
        layer?.addSublayer(bg)
        label.stringValue = title
        label.font = Theme.font(10.5, .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // The popover is rarely key when you reach for a server — act on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func restyle() {
        let hot = danger ? Status.accent("needs") : Status.accent("working")
        label.textColor = hovered ? hot : .secondaryLabelColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.borderColor = (hovered ? hot : NSColor.tertiaryLabelColor).cg(in: self)
        bg.backgroundColor = hovered ? hot.withAlphaComponent(0.10).cg(in: self) : NSColor.clear.cgColor
        CATransaction.commit()
    }
}
