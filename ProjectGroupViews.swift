import Cocoa

// MARK: - Project groups (T387): title row, drag-merge feedback, side rail
//
// Look and motion follow design/project-groups.html round 2: "C 改 · 贴边线" for the
// group (cards keep their full width; a violet rail runs down the empty strip left of
// them) and "I2" for the merge (a ring fills around the target's icon while the drag
// dwells on it, then the icon glows and a hint says what letting go will do).

enum ProjectGroupStyle {
    static let accent = NSColor(srgbRed: 191 / 255, green: 90 / 255, blue: 242 / 255, alpha: 1)
    // How long a dragged header must rest on another before letting go merges them.
    static let dwell: TimeInterval = 0.5
    // The rail sits in the cell's leading inset, 8pt left of the cards' edge.
    static let railX: CGFloat = Theme.cardCellInset - 8
    static let railWidth: CGFloat = 3
    static let titleHeight: CGFloat = 30
    static let membersLineHeight: CGFloat = 20
}

// Where a drag-merge stands on one target row.
enum MergeState: Equatable {
    case none
    case counting(since: Date)
    case ready(joining: Bool)   // joining = the drop adds to an existing group
}

// Which stretch of a group's rail a row carries. Rows abut with no spacing, so the
// per-row segments read as one line from the title down to the last member's card.
enum GroupRail { case none, start, middle, end, only }

// MARK: Merge ring

// The I2 countdown: a rounded-rect ring around an icon that fills over the dwell, then
// glows once letting go will merge. Sized by its host to the icon plus a margin.
final class MergeRingView: NSView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private var state: MergeState = .none

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for l in [track, progress] {
            l.fillColor = NSColor.clear.cgColor
            l.lineWidth = 2.5
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        progress.strokeColor = ProjectGroupStyle.accent.cgColor
        progress.shadowColor = ProjectGroupStyle.accent.cgColor
        progress.shadowOffset = .zero
        progress.shadowRadius = 5
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Decoration: clicks and drags belong to the icon underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = bounds.insetBy(dx: 1.25, dy: 1.25)
        let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
        track.frame = bounds; progress.frame = bounds
        track.path = path; progress.path = path
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        track.strokeColor = Theme.hairlineHover.cg(in: self)
    }

    func apply(_ s: MergeState) {
        guard s != state else { return }
        state = s
        track.strokeColor = Theme.hairlineHover.cg(in: self)
        progress.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch s {
        case .none:
            isHidden = true
        case .counting(let since):
            isHidden = false
            progress.shadowOpacity = 0
            progress.strokeEnd = 1
            // Resume from the elapsed share so a reload mid-dwell doesn't restart the ring.
            let done = min(max(Date().timeIntervalSince(since) / ProjectGroupStyle.dwell, 0), 1)
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = done
            a.toValue = 1
            a.duration = max(ProjectGroupStyle.dwell * (1 - done), 0.01)
            progress.add(a, forKey: "fill")
        case .ready:
            isHidden = false
            progress.strokeEnd = 1
            progress.shadowOpacity = 1
        }
        CATransaction.commit()
    }
}

// The "松手 → …" chip shown once the dwell completes.
final class MergeHint: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ProjectGroupStyle.accent.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        label.font = Theme.rounded(11, .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ s: MergeState) {
        guard case .ready(let joining) = s else { isHidden = true; return }
        label.stringValue = joining ? L("松手 → 加进这个组", "Release to join group")
                                    : L("松手 → 合成一组", "Release to group")
        isHidden = false
    }
}

// MARK: Group title row

// The group's own row: a small violet stack icon (the drag grip), the group name, how
// many projects it holds, the summed status pill and the collapse disc. No card — the
// member projects below keep theirs; the rail in the row views ties them together.
// Collapsed, a second line lists the member names.
final class GroupTitleCell: NSTableCellView, HandleProviding, Hoverable {
    private let icon = NSView()
    private let glyph = NSImageView()
    private let ring = MergeRingView()
    private let hint = MergeHint()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let countPill = CountPill()
    private let disc = DiscButton()
    private let membersLabel = NSTextField(labelWithString: "")
    private var topGap: NSLayoutConstraint!

    var dragHandle: NSView { icon }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        icon.wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.layer?.cornerRadius = 5
        icon.layer?.cornerCurve = .continuous
        icon.layer?.borderWidth = 1
        icon.layer?.backgroundColor = ProjectGroupStyle.accent.withAlphaComponent(0.22).cgColor
        icon.layer?.borderColor = ProjectGroupStyle.accent.withAlphaComponent(0.5).cgColor
        glyph.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        glyph.contentTintColor = ProjectGroupStyle.accent
        glyph.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(glyph)
        addSubview(icon)
        addSubview(ring)

        nameLabel.font = Theme.rounded(12.5, .bold)
        nameLabel.textColor = ProjectGroupStyle.accent
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.font = Theme.rounded(10.5, .semibold)
        sizeLabel.textColor = .secondaryLabelColor
        membersLabel.font = Theme.font(11, .medium)
        membersLabel.textColor = .secondaryLabelColor
        membersLabel.lineBreakMode = .byTruncatingTail
        membersLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [nameLabel, sizeLabel, membersLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        addSubview(countPill)
        addSubview(disc)
        addSubview(hint)

        topGap = icon.topAnchor.constraint(equalTo: topAnchor, constant: 8 + 2)
        NSLayoutConstraint.activate([
            topGap,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cardCellInset + 1),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            glyph.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            ring.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -4),
            ring.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            ring.topAnchor.constraint(equalTo: icon.topAnchor, constant: -4),
            ring.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 7),
            sizeLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            sizeLabel.trailingAnchor.constraint(lessThanOrEqualTo: countPill.leadingAnchor, constant: -8),

            // Same right-hand columns as a project header (HeaderCell), so the pills and
            // discs of the group and its members line up.
            disc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Theme.cardCellInset + 10)),
            disc.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            countPill.trailingAnchor.constraint(equalTo: disc.leadingAnchor, constant: -9),
            countPill.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: countPill.trailingAnchor),
            hint.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            membersLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            membersLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            membersLabel.trailingAnchor.constraint(lessThanOrEqualTo: disc.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Every click on the row is the collapse toggle (the table routes it), so the cell
    // claims them all, like the project header.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    func configure(name: String, counts: [(String, Int)], collapsed: Bool, members: [String], isFirst: Bool) {
        topGap.constant = (isFirst ? 0 : 8) + 2
        nameLabel.stringValue = name
        sizeLabel.stringValue = L("\(members.count) 个项目", "\(members.count) projects")
        countPill.configure(counts: counts)
        countPill.isHidden = counts.isEmpty
        disc.configure(collapsed: collapsed)
        membersLabel.stringValue = members.joined(separator: " · ")
        membersLabel.isHidden = !collapsed
    }

    func setMergeState(_ s: MergeState) {
        ring.apply(s)
        hint.apply(s)
        countPill.alphaValue = hint.isHidden ? 1 : 0
    }

    // Not a card: the title neither lifts nor haloes.
    func setHovered(_ lift: HoverLift, groupFrame: NSRect?, groupRole: SliceRole?, animated: Bool) {}
    func setSelected(_ on: Bool, animated: Bool) {}

    static func height(collapsed: Bool, isFirst: Bool) -> CGFloat {
        ProjectGroupStyle.titleHeight + (collapsed ? ProjectGroupStyle.membersLineHeight : 0) - (isFirst ? 8 : 0)
    }
}

// MARK: Rail

extension TransparentRowView {
    // Paint this row's stretch of a group rail (or clear it). `topInset` is where the
    // rail starts on a .start/.only row — the title row's own top gap.
    func setGroupRail(_ rail: GroupRail, topInset: CGFloat) {
        let l = railLayer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard rail != .none else { l.isHidden = true; railState = (.none, 0); return }
        l.isHidden = false
        l.backgroundColor = ProjectGroupStyle.accent.withAlphaComponent(0.85).cgColor
        let starts = rail == .start || rail == .only
        let ends = rail == .end || rail == .only
        let top: CGFloat = starts ? topInset : 0
        let bottom: CGFloat = ends ? 2 : 0
        let h = max(0, bounds.height - top - bottom)
        // Table row views are flipped, and so is their backing layer's geometry:
        // y grows downward from the row's top edge.
        l.frame = CGRect(x: ProjectGroupStyle.railX, y: top, width: ProjectGroupStyle.railWidth, height: h)
        l.cornerRadius = (starts || ends) ? ProjectGroupStyle.railWidth / 2 : 0
        railState = (rail, topInset)
    }
}
