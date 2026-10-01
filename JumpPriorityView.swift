import Cocoa

// MARK: - Jump-priority setting card
//
// Settings › 高亮 › 「跳转优先级」. Two settings in one card, one gesture each:
// DRAG to reorder the status buckets every jump path walks (AppSettings.jumpPriority),
// TAP a chip's 自动/Auto pill to include or exclude that bucket from the two AUTOMATIC
// paths (AppSettings.jumpAutoStatuses — idle auto-jump + answered-chain). The manual
// hotkey always walks all three, by design: excluding a bucket from an action you press
// yourself is pointless, excluding it from one that fires on its own is the whole point.
// Order lives in exactly one place (jumpPriority) so statusDisplayOrder keeps a single
// source; the pills only carry membership. Both gestures auto-save on settle; 恢复默认
// resets order and membership together.

// One draggable status chip: dot + label + auto pill, on a rounded glass pill. Sizes
// itself to its content; the track positions it by frame.
private final class PriorityChip: NSView {
    let key: String
    private let autoPill = NSView()
    private let autoLabel = NSTextField(labelWithString: L("自动", "Auto"))
    private(set) var isAuto = false

    init(key: String, title: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let dot = StatusDot(diameter: 11)
        dot.apply(key)                       // keyless → steady animation, no entrance pop
        dot.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = Theme.rounded(13, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        // The pill is deliberately NOT status-colored: the dot already says which status
        // this is, so tinting it too would say the same thing twice and leave the
        // on/off state unreadable. Accent = a boolean, which is what it encodes.
        autoPill.wantsLayer = true
        autoPill.layer?.cornerRadius = 7
        autoPill.layer?.cornerCurve = .continuous
        autoPill.translatesAutoresizingMaskIntoConstraints = false
        autoLabel.font = Theme.font(9.5, .bold)
        autoLabel.translatesAutoresizingMaskIntoConstraints = false
        autoPill.addSubview(autoLabel)
        autoPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        autoPill.setContentHuggingPriority(.required, for: .horizontal)

        // Centered content group so equal-width chips don't left-align their labels.
        let stack = NSStackView(views: [dot, name, autoPill])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.setCustomSpacing(8, after: dot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            dot.widthAnchor.constraint(equalToConstant: 11),
            dot.heightAnchor.constraint(equalToConstant: 11),
            autoPill.heightAnchor.constraint(equalToConstant: 20),
            autoLabel.centerYAnchor.constraint(equalTo: autoPill.centerYAnchor),
            autoLabel.leadingAnchor.constraint(equalTo: autoPill.leadingAnchor, constant: 8),
            autoLabel.trailingAnchor.constraint(equalTo: autoPill.trailingAnchor, constant: -8),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
        applyColors()
        applyAutoColors(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setAuto(_ on: Bool, animated: Bool) {
        guard on != isAuto else { return }
        isAuto = on
        applyAutoColors(animated: animated)
    }

    // The pill's hit box in the CHIP's coordinate space, padded out to a comfortable
    // ~42×32 target. The chip is an unscaled direct child of the track, so the track
    // only has to offset this by the chip's origin.
    var autoHitBox: NSRect {
        layoutSubtreeIfNeeded()
        // `autoPill.frame` is in the STACK's space, not the chip's — convert, or the box
        // lands wherever the stack's centering offset happens to put it.
        return autoPill.convert(autoPill.bounds, to: self).insetBy(dx: -6, dy: -5)
    }

    // Shake the pill in place — the refusal feedback when this is the last 自动 left.
    func rejectAuto() {
        let a = CAKeyframeAnimation(keyPath: "position.x")
        let x = autoPill.layer?.position.x ?? 0
        a.values = [x, x - 3, x + 3, x - 2, x]
        a.duration = 0.12
        autoPill.layer?.add(a, forKey: "reject")
    }

    private func applyAutoColors(animated: Bool) {
        let apply = {
            self.autoPill.layer?.backgroundColor = self.isAuto
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            self.autoPill.layer?.borderWidth = self.isAuto ? 0 : 1
            self.autoPill.layer?.borderColor = Theme.hairline.cgColor
            self.autoLabel.textColor = self.isAuto ? .controlAccentColor : .tertiaryLabelColor
        }
        guard animated else { apply(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.allowsImplicitAnimation = true
            apply()
        }
    }

    // Re-read glass colors (they're appearance-dynamic).
    func applyColors() {
        layer?.backgroundColor = Theme.cardFill.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func updateLayer() { applyColors(); applyAutoColors(animated: false) }
    // Let the track own all mouse handling — never swallow the drag here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

// The draggable track: a recessed strip holding the chips + arrows. Owns the
// pointer-drag reorder; publishes the live order via `draft` and pings `onChange`
// when a drag settles.
private final class JumpPriorityTrack: NSView {
    private(set) var draft: [String]
    private(set) var draftAuto: [String] = []
    var onChange: (() -> Void)?
    var onAutoChange: (() -> Void)?
    // Raised when a tap tried to clear the last 自动 pill — the card turns it into the
    // "keep at least one" hint rather than silently doing nothing.
    var onAutoRefused: (() -> Void)?

    // The main window is movable-by-background; without this a drag on the track
    // would drag the whole window instead of the chip.
    override var mouseDownCanMoveWindow: Bool { false }

    private var chipByKey: [String: PriorityChip] = [:]
    private var chips: [PriorityChip] = []
    private var arrows: [NSTextField] = []
    private let leftPad: CGFloat = 12
    private let interItem: CGFloat = 24        // gap between chips, holds one arrow
    private let chipH: CGFloat = 32
    private var dragging: PriorityChip?
    private var grabDX: CGFloat = 0
    // Press bookkeeping — a press is not yet a drag. Committing to the drag on mouseDown
    // made every plain tap flash the lift shadow, and with a tappable pill inside the
    // chip the two gestures have to be told apart by movement, not by the down event.
    private var pressChip: PriorityChip?
    private var pressOrigin: NSPoint = .zero
    private var pressedAuto = false
    private let dragSlop: CGFloat = 3

    init(order: [String], auto: [String]) {
        self.draft = order
        self.draftAuto = auto
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        for key in AppSettings.jumpStatuses {
            let chip = PriorityChip(key: key, title: Self.label(key))
            chip.frame.size = NSSize(width: chip.fittingSize.width, height: chipH)
            chip.setAuto(auto.contains(key), animated: false)
            addSubview(chip)
            chips.append(chip)
            chipByKey[key] = chip
        }
        for _ in 1..<AppSettings.jumpStatuses.count {
            let a = NSTextField(labelWithString: "→")
            a.font = Theme.font(15, .regular)
            a.textColor = .tertiaryLabelColor
            a.frame.size = a.fittingSize
            addSubview(a)
            arrows.append(a)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func label(_ key: String) -> String {
        switch key {
        case "needs":  return L("确认", "Wait")
        case "paused": return L("暂停", "Held")
        case "done":   return L("完成", "Done")
        default:       return key
        }
    }

    func setOrder(_ order: [String]) {
        draft = order
        relayout(animated: true)
    }

    func setAuto(_ auto: [String]) {
        draftAuto = auto
        for chip in chips { chip.setAuto(auto.contains(chip.key), animated: true) }
    }

    var autoContainsDone: Bool { draftAuto.contains("done") }

    override func layout() {
        super.layout()
        if dragging == nil { relayout(animated: false) }
    }

    // Lay chips out edge-to-edge in `draft` order: all equal width, together filling
    // the track (minus padding + the arrow gaps). Drop each arrow in the gap before
    // its chip. The chip under the cursor keeps its dragged x (width still refreshed).
    private func relayout(animated: Bool) {
        let n = draft.count
        guard n > 0, bounds.width > 0 else { return }
        let avail = bounds.width - 2 * leftPad - CGFloat(n - 1) * interItem
        let chipW = max(40, avail / CGFloat(n))
        let cy = (bounds.height - chipH) / 2
        var x = leftPad
        for (i, key) in draft.enumerated() {
            guard let chip = chipByKey[key] else { continue }
            if i > 0 {
                let arrow = arrows[i - 1]
                arrow.frame.origin = NSPoint(x: x + (interItem - arrow.frame.width) / 2,
                                             y: (bounds.height - arrow.frame.height) / 2)
                x += interItem
            }
            if chip === dragging {
                chip.frame.size = NSSize(width: chipW, height: chipH)   // keep dragged x, refresh size
            } else {
                let target = NSRect(x: x, y: cy, width: chipW, height: chipH)
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.16
                        ctx.allowsImplicitAnimation = true
                        chip.animator().frame = target
                    }
                } else {
                    chip.frame = target
                }
            }
            x += chipW
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let chip = chips.first(where: { $0.frame.contains(p) }) else { return }
        // Record the press only — the drag isn't committed until the pointer actually
        // moves (see mouseDragged), so a tap on the pill never lifts the chip.
        pressChip = chip
        pressOrigin = p
        grabDX = p.x - chip.frame.minX
        pressedAuto = chip.autoHitBox.offsetBy(dx: chip.frame.minX, dy: chip.frame.minY).contains(p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if dragging == nil {
            guard let pressed = pressChip,
                  abs(p.x - pressOrigin.x) > dragSlop || abs(p.y - pressOrigin.y) > dragSlop
            else { return }
            dragging = pressed
            addSubview(pressed)                // raise above siblings + arrows
            pressed.layer?.shadowColor = NSColor.black.cgColor
            pressed.layer?.shadowOpacity = 0.45
            pressed.layer?.shadowRadius = 10
            pressed.layer?.shadowOffset = NSSize(width: 0, height: -3)
        }
        guard let chip = dragging else { return }
        let desiredX = p.x - grabDX
        let nx = max(leftPad, min(desiredX, bounds.width - leftPad - chip.frame.width))
        chip.frame.origin.x = nx
        // Re-derive order from visual centers: siblings sit at their slots, the
        // dragged chip at the cursor. Use the dragged chip's *unclamped* center —
        // at either edge its clamped midX exactly ties the edge sibling's slot
        // center, and a strict-< sort could never overtake it (the "can't drop
        // into first/last slot" bug). The unclamped center clears the tie.
        let dragMid = desiredX + chip.frame.width / 2
        let mid: (String) -> CGFloat = { $0 == chip.key ? dragMid : self.chipByKey[$0]!.frame.midX }
        let sorted = draft.sorted { mid($0) < mid($1) }
        if sorted != draft {
            draft = sorted
            relayout(animated: true)           // shift the displaced siblings, leave the dragged one
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressChip = nil; pressedAuto = false }
        guard let chip = dragging else {
            if pressedAuto, let chip = pressChip { toggleAuto(chip) }
            return
        }
        dragging = nil
        chip.layer?.shadowOpacity = 0
        relayout(animated: true)               // snap the dropped chip into its slot
        onChange?()
    }

    // Refuse to clear the LAST auto bucket. An empty set would silently disable both
    // auto paths while their own switches still read "on" — a dead end whose cause
    // lives in a different card. Turning auto-jump off already has two obvious
    // switches right below, so the pill points there instead of becoming a third way.
    private func toggleAuto(_ chip: PriorityChip) {
        if chip.isAuto && draftAuto.count <= 1 {
            chip.rejectAuto()
            onAutoRefused?()
            return
        }
        if chip.isAuto { draftAuto.removeAll { $0 == chip.key } } else { draftAuto.append(chip.key) }
        chip.setAuto(!chip.isAuto, animated: true)
        onAutoChange?()
    }
}

// The settings card: title + a 恢复默认 button level with it (top-right), the
// draggable track, and a drag hint. No edit/confirm step — drag directly and each
// settle auto-saves to AppSettings.jumpPriority. Retains its own control target
// (it's held by the view tree), so it needs no external handler bookkeeping.
final class JumpPriorityCard: NSView {
    private let track: JumpPriorityTrack
    private let resetBtn = NSButton()
    private let legend = NSTextField(labelWithString: "")
    private var hintResetWork: DispatchWorkItem?

    init() {
        track = JumpPriorityTrack(order: AppSettings.jumpPriority, auto: AppSettings.jumpAutoStatuses)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        // Auto-save: a settled drag commits the new order, a tap commits membership;
        // both jump paths read them live.
        track.onChange = { [weak self] in
            guard let self else { return }
            AppSettings.jumpPriority = self.track.draft
        }
        track.onAutoChange = { [weak self] in
            guard let self else { return }
            AppSettings.jumpAutoStatuses = self.track.draftAuto
            self.updateLegend()
        }
        track.onAutoRefused = { [weak self] in self?.flashLegend(Self.legendFloor) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // Glass background (GlassCard is final — embed rather than subclass).
        let bg = GlassCard(radius: Theme.card, glows: false)
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let name = NSTextField(labelWithString: L("跳转优先级", "Jump Priority"))
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        // 恢复默认 — top-right, level with the title.
        resetBtn.isBordered = false
        resetBtn.attributedTitle = NSAttributedString(
            string: L("恢复默认", "Reset"),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: Theme.font(12.5, .semibold)])
        resetBtn.setContentHuggingPriority(.required, for: .horizontal)
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.target = self
        resetBtn.action = #selector(resetTapped)
        addSubview(resetBtn)

        let desc = NSTextField(labelWithString:
            L("越靠左越先跳；点「自动」决定它是否参与自动跳转",
              "Leftmost goes first; tap Auto to include it in auto-jumps"))
        desc.font = Theme.font(11.5, .regular)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desc)

        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)

        legend.font = Theme.font(11, .regular)
        legend.textColor = .tertiaryLabelColor
        legend.alignment = .center
        legend.lineBreakMode = .byTruncatingTail
        legend.translatesAutoresizingMaskIntoConstraints = false
        addSubview(legend)
        updateLegend()

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            resetBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            resetBtn.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.inset),

            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            track.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 12),
            track.heightAnchor.constraint(equalToConstant: 56),

            legend.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            legend.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 9),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),   // card self-sizes to content
        ])
    }

    @objc private func resetTapped() {
        track.setOrder(AppSettings.jumpStatuses)          // back to the factory order
        track.setAuto(AppSettings.jumpAutoDefault)        // …and the factory auto set
        AppSettings.jumpPriority = track.draft             // auto-save the reset too
        AppSettings.jumpAutoStatuses = track.draftAuto
        updateLegend()
    }

    // The hint line under the track carries three messages in one field: how to drive
    // the card, the cost of having turned 完成 on, and the refusal when you try to clear
    // the last 自动.
    private static var legendDefault: String {
        L("拖放排序 · 点药丸开关自动", "Drag to reorder · tap the pill to toggle Auto")
    }
    private static var legendDone: String {
        L("完成也会触发自动跳转 —— 别的会话跑完时可能把你带走",
          "Done now triggers auto-jumps — another session finishing can pull you away")
    }
    private static var legendFloor: String {
        L("至少保留一个；要完全关掉自动跳转用下面两个开关",
          "Keep at least one; use the two switches below to turn auto-jump off")
    }

    private func updateLegend() {
        hintResetWork?.cancel()
        legend.stringValue = track.autoContainsDone ? Self.legendDone : Self.legendDefault
    }

    private func flashLegend(_ text: String) {
        hintResetWork?.cancel()
        legend.stringValue = text
        let work = DispatchWorkItem { [weak self] in self?.updateLegend() }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
