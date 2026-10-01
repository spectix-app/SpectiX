import Cocoa

// MARK: - 技能 tab (main window tab 4)
//
// Every Claude Code / Codex skill and agent on this Mac as a usage leaderboard
// (design/skills-agents-tab.html, scheme 2): each row carries a bar sized to its
// share of the busiest visible item. The segment, tool chips and sort button sit
// OUTSIDE the scroll view so they stay put while the list scrolls. Data comes from
// SkillCatalog (see docs/skills-catalog.md); the first load reads ~1 GB of
// transcripts (~6 s) on a background queue, later ones only the appended bytes.

enum SkillSort: Int, CaseIterable {
    case uses, recent, name

    var label: String {
        switch self {
        case .uses:   return L("按次数", "By uses")
        case .recent: return L("按最近", "By recent")
        case .name:   return L("按名称", "By name")
        }
    }
}

final class SkillsPane: NSView {

    private var items: [CatalogItem] = []
    private var kind: CatalogKind = .skill
    private var tool: CatalogTool?            // nil = both
    private var sort: SkillSort = .uses
    private var expanded: Set<String> = []
    private var loading = false

    private var skillsSeg: TabItemButton!
    private var agentsSeg: TabItemButton!
    private var chips: [(CatalogTool?, ChipButton)] = []
    private let sortButton = ChipButton(title: "")
    private let summary = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildUI() {
        skillsSeg = TabItemButton(symbol: "wand.and.stars", label: "Skills", index: 0)
        agentsSeg = TabItemButton(symbol: "person.2", label: "Agents", index: 1)
        for b in [skillsSeg!, agentsSeg!] {
            b.target = self
            b.action = #selector(kindClicked(_:))
        }
        let seg = NSStackView(views: [skillsSeg, agentsSeg])
        seg.orientation = .horizontal
        seg.distribution = .fillEqually
        seg.spacing = 4
        seg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(seg)

        let chipRow = NSStackView()
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        for (t, title) in [(nil, L("全部", "All")), (CatalogTool.claude, "Claude"), (.codex, "Codex")] as [(CatalogTool?, String)] {
            let c = ChipButton(title: title)
            c.target = self
            c.action = #selector(toolClicked(_:))
            chips.append((t, c))
            chipRow.addArrangedSubview(c)
        }
        addSubview(chipRow)

        sortButton.symbol = "arrow.up.arrow.down"
        sortButton.outlined = false
        sortButton.target = self
        sortButton.action = #selector(sortClicked)
        sortButton.toolTip = L("排序方式", "Sort order")
        addSubview(sortButton)

        summary.font = Theme.font(11)
        summary.textColor = .tertiaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summary)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 5
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = SkillsFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        emptyLabel.font = Theme.font(12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            seg.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            seg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad),
            seg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.pad),

            chipRow.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 8),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad),

            sortButton.centerYAnchor.constraint(equalTo: chipRow.centerYAnchor),
            sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.pad + 4),

            summary.centerYAnchor.constraint(equalTo: chipRow.centerYAnchor),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: chipRow.trailingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -6),

            scroll.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad - 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Theme.pad - 6)),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 6),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -6),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        // Not pinDocumentWidth: that lets over-wide content scroll sideways, and here the
        // only over-wide content is prose that should wrap — with it, one long
        // description widened every row past the pane at 384pt (skills-preview, 2026-09-24).
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        syncControls()
    }

    // MARK: Data

    /// Tab switched in: refresh from disk (incremental after the first time).
    func paneDidAppear() {
        if Demo.enabled { show(Demo.catalog()); return }
        guard !loading else { return }
        loading = true
        if items.isEmpty { rebuild() }   // shows the "reading transcripts" state
        let roots = ProjectHistory.all().map { $0.path }
        SkillCatalog.load(projectRoots: roots) { [weak self] loaded in
            guard let self else { return }
            self.loading = false
            self.show(loaded)
        }
    }

    /// Render a given catalog (also the preview tool's entry point).
    func show(_ catalog: [CatalogItem]) {
        items = catalog
        rebuild()
    }

    func configure(kind: CatalogKind, tool: CatalogTool?, sort: SkillSort, expanded: Set<String>) {
        self.kind = kind; self.tool = tool; self.sort = sort; self.expanded = expanded
        syncControls()
        rebuild()
    }

    private func visible() -> [CatalogItem] {
        let l = items.filter { $0.kind == kind && (tool == nil || $0.tool == tool) }
        switch sort {
        case .uses:
            return l.sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recent:
            return l.sorted {
                let a = $0.lastUsed ?? .distantPast, b = $1.lastUsed ?? .distantPast
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .name:
            return l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // Rebuilt only on load or a user action (filter / sort / expand) — never on a
    // timer: every inserted control registers AppKit bookkeeping that is never freed
    // (docs/design-system.md, T318).
    private func rebuild() {
        let top = scroll.contentView.bounds.origin
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = visible()
        let maxUses = max(1, list.map(\.uses).max() ?? 0)
        let totalUses = list.reduce(0) { $0 + $1.uses }
        summary.stringValue = items.isEmpty ? "" : L("\(list.count) 个 · 共 \(totalUses) 次",
                                                     "\(list.count) · \(totalUses) uses")

        if items.isEmpty {
            emptyLabel.stringValue = loading
                ? L("正在读取对话记录…第一次要几秒钟", "Reading transcripts… the first time takes a few seconds")
                : L("没有找到 skill 或 agent", "No skills or agents found")
        } else {
            emptyLabel.stringValue = L("这一类下没有内容", "Nothing in this filter")
        }
        emptyLabel.isHidden = !list.isEmpty

        for (i, item) in list.enumerated() {
            let row = SkillRowView(item: item,
                                   rank: sort == .uses && item.uses > 0 ? i + 1 : nil,
                                   fraction: CGFloat(item.uses) / CGFloat(maxUses),
                                   expanded: expanded.contains(item.id))
            row.onToggle = { [weak self] id in
                guard let self else { return }
                if self.expanded.contains(id) { self.expanded.remove(id) } else { self.expanded.insert(id) }
                self.rebuild()
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: top)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Controls

    private func syncControls() {
        skillsSeg.isOn = kind == .skill
        agentsSeg.isOn = kind == .agent
        for (t, c) in chips { c.isOn = t == tool }
        sortButton.text = sort.label
    }

    @objc private func kindClicked(_ sender: TabItemButton) {
        let k: CatalogKind = sender.index == 0 ? .skill : .agent
        guard k != kind else { return }
        kind = k
        syncControls()
        scroll.contentView.scroll(to: .zero)
        rebuild()
    }

    @objc private func toolClicked(_ sender: ChipButton) {
        guard let entry = chips.first(where: { $0.1 === sender }), entry.0 != tool else { return }
        tool = entry.0
        syncControls()
        rebuild()
    }

    @objc private func sortClicked() {
        let menu = NSMenu()
        for s in SkillSort.allCases {
            let it = NSMenuItem(title: s.label, action: #selector(sortPicked(_:)), keyEquivalent: "")
            it.target = self
            it.tag = s.rawValue
            it.state = s == sort ? .on : .off
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sortButton.bounds.height + 4), in: sortButton)
    }

    @objc private func sortPicked(_ sender: NSMenuItem) {
        guard let s = SkillSort(rawValue: sender.tag), s != sort else { return }
        sort = s
        syncControls()
        rebuild()
    }
}

// MARK: - Row

private final class SkillRowView: NSView {

    var onToggle: ((String) -> Void)?

    private let item: CatalogItem
    private let fraction: CGFloat
    private let bar = CALayer()
    private let header = NSView()
    private var hovering = false

    init(item: CatalogItem, rank: Int?, fraction: CGFloat, expanded: Bool) {
        self.item = item
        self.fraction = fraction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
        translatesAutoresizingMaskIntoConstraints = false

        let rankLabel = NSTextField(labelWithString: rank.map(String.init) ?? "")
        rankLabel.font = Theme.roundedMono(10.5, .bold)
        rankLabel.textColor = .tertiaryLabelColor
        rankLabel.alignment = .right

        let name = NSTextField(labelWithString: item.name)
        name.font = Theme.font(13, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let count = NSTextField(labelWithString: "\(item.uses)")
        count.font = Theme.roundedMono(12, .bold)
        count.textColor = .labelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)

        let chev = NSImageView(image: NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                              accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
        chev.contentTintColor = .tertiaryLabelColor

        let line = NSStackView(views: [rankLabel, name, TagView.tool(item.tool)])
        line.orientation = .horizontal
        line.spacing = 7
        line.alignment = .centerY
        if let o = Self.originText(item.origin) { line.addArrangedSubview(TagView(o, tint: nil)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        line.addArrangedSubview(spacer)
        line.addArrangedSubview(count)
        line.addArrangedSubview(chev)
        line.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(line)

        let column = NSStackView(views: [header])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 20),
            chev.widthAnchor.constraint(equalToConstant: 10),

            header.heightAnchor.constraint(equalToConstant: 32),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if expanded {
            let d = SkillDetailView(item: item)
            column.addArrangedSubview(d)
            d.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        if item.uses == 0 { alphaValue = 0.5 }

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    static func originText(_ o: CatalogOrigin) -> String? {
        switch o {
        case .user:           return nil
        case .plugin(let p):  return L("插件 · \(p)", "Plugin · \(p)")
        case .project(let p): return L("项目 · \(p)", "Project · \(p)")
        case .system:         return L("系统", "System")
        case .builtin:        return L("内置", "Built-in")
        case .missing:        return L("已删除", "Removed")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    // Only the header strip toggles; clicks in the detail block belong to its buttons
    // and to text selection.
    override func mouseUp(with event: NSEvent) {
        let p = header.convert(event.locationInWindow, from: nil)
        if header.bounds.contains(p) { onToggle?(item.id) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyColors() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        // The fill alone all but vanishes on the light bed; the hairline keeps a zero-use
        // row reading as a row.
        layer?.borderWidth = 1
        layer?.borderColor = (hovering ? Theme.hairlineHover : Theme.hairline).cg(in: self)
        bar.backgroundColor = Status.accent("working").withAlphaComponent(0.16).cgColor
    }
}

// MARK: - Expanded detail

private final class SkillDetailView: NSView {

    private let item: CatalogItem

    init(item: CatalogItem) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let desc = NSTextField(wrappingLabelWithString: item.description.isEmpty
                               ? L("（没有简介）", "(No description)") : item.description)
        desc.font = Theme.font(12)
        desc.textColor = .secondaryLabelColor
        desc.isSelectable = true
        // A wrapping label still asks for its one-line width; at the default resistance a
        // long description widened the row past the pane at 384pt instead of wrapping.
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [(String, String)] = [
            (L("使用", "Used"), Self.usesText(item)),
            (L("来源", "Source"), Self.sourceText(item)),
        ]
        if let m = item.model { rows.append((L("模型", "Model"), m)) }
        rows.append((L("位置", "Location"),
                     item.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("（没有文件）", "(no file)")))

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        for (k, v) in rows {
            let kl = NSTextField(labelWithString: k)
            kl.font = Theme.font(11)
            kl.textColor = .tertiaryLabelColor
            let vl = NSTextField(wrappingLabelWithString: v)
            vl.font = Theme.font(11)
            vl.textColor = .secondaryLabelColor
            vl.isSelectable = true
            vl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [kl, vl])
        }
        grid.column(at: 0).width = 44
        grid.column(at: 0).xPlacement = .leading

        let stack = NSStackView(views: [desc, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if item.path != nil {
            let reveal = ChipButton(title: L("在 Finder 中显示", "Show in Finder"))
            reveal.target = self; reveal.action = #selector(revealClicked)
            let open = ChipButton(title: L("打开文件", "Open file"))
            open.target = self; open.action = #selector(openClicked)
            let copy = ChipButton(title: L("复制名字", "Copy name"))
            copy.target = self; copy.action = #selector(copyClicked)
            let acts = NSStackView(views: [reveal, open, copy])
            acts.orientation = .horizontal
            acts.spacing = 6
            stack.addArrangedSubview(acts)
        }
        addSubview(stack)

        NSLayoutConstraint.activate([
            desc.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 31),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func usesText(_ item: CatalogItem) -> String {
        guard item.uses > 0 else { return L("从没用过", "Never used") }
        let n = L("\(item.uses) 次", item.uses == 1 ? "1 time" : "\(item.uses) times")
        guard let d = item.lastUsed else { return n }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return L("\(n) · 最近 \(df.string(from: d))", "\(n) · last \(df.string(from: d))")
    }

    private static func sourceText(_ item: CatalogItem) -> String {
        let t = item.tool == .claude ? "Claude Code" : "Codex"
        let o = SkillRowView.originText(item.origin) ?? L("个人", "Personal")
        return "\(t) · \(o)"
    }

    @objc private func revealClicked() {
        guard let p = item.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
    @objc private func openClicked() {
        guard let p = item.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    @objc private func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
    }
}

// MARK: - Small pieces

// A small label in a padded capsule. `tint` fills it (the CLAUDE / CODEX tag);
// without one it gets a hairline border (origin tags).
private final class TagView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let tint: NSColor?

    init(_ text: String, tint: NSColor?) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = tint == nil ? 7 : 4
        label.stringValue = text
        label.font = tint == nil ? Theme.font(10) : Theme.rounded(8.5, .heavy)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let pad: CGFloat = tint == nil ? 6 : 4
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        if tint != nil {
            setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Copper matches the desktop Claude badge; Codex takes a periwinkle kept off the
    // status palette.
    static func tool(_ t: CatalogTool) -> TagView {
        t == .claude
            ? TagView("CLAUDE", tint: NSColor(srgbRed: 0.878, green: 0.541, blue: 0.369, alpha: 1))
            : TagView("CODEX", tint: NSColor(srgbRed: 0.490, green: 0.557, blue: 1.0, alpha: 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        if let tint {
            label.textColor = tint
            layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        } else {
            label.textColor = .tertiaryLabelColor
            layer?.borderWidth = 1
            layer?.borderColor = Theme.hairline.cg(in: self)
        }
    }
}

// Pill-shaped text button: filter chips, the sort button (borderless, with a
// symbol) and the detail row's actions.
final class ChipButton: NSButton {
    var isOn = false { didSet { applyStyle() } }
    var outlined = true { didSet { applyStyle() } }
    var symbol: String? {
        didSet {
            image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) }
            imagePosition = image == nil ? .noImage : .imageLeading
            applyStyle()
        }
    }
    var text: String { didSet { applyStyle() } }
    private var hovering = false

    init(title: String) {
        text = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 20, height: 22)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyStyle() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        let blue = Status.accent("working")
        let fg: NSColor = isOn ? .labelColor : (hovering ? .labelColor : .secondaryLabelColor)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.font(11, .semibold), .foregroundColor: fg])
        contentTintColor = fg
        layer?.borderWidth = outlined ? 1 : 0
        layer?.borderColor = (isOn ? blue : Theme.hairline).cg(in: self)
        if isOn {
            layer?.backgroundColor = blue.withAlphaComponent(0.12).cgColor
        } else if outlined || hovering {
            layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class SkillsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
