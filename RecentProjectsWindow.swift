import Cocoa

// MARK: - Recent projects pane ("最近项目")
//
// A list of every project ProjectHistory has recorded — pinned ones first, then
// most recently seen. Each row shows the folder's real Finder icon, its name,
// the ~-abbreviated path, and either a green "已打开" badge (a live session has
// this cwd right now) or the last-seen relative time. Click a row to open: the
// AppController either jumps to the live VSCode window or hands the folder to
// VSCode. Hovering reveals 📌 (pin/unpin) and ✕ (drop from history); the +
// button adds a folder by hand via NSOpenPanel.
//
// Lives as tab 2 of the main window (scheme 6). Frost/base come from the host
// window's glass; the pane itself is transparent.
final class RecentProjectsPane: NSView {

    /// Row clicked → open/focus this project path.
    var onOpen: ((String) -> Void)?

    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L("还没有记录。点右上角 + 手动添加，或跑几个会话后再回来看。", "No history yet. Tap + at the top-right to add manually, or run a few sessions and check back."))
    private let countLabel = NSTextField(labelWithString: "")
    private var openCwds: Set<String> = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        // A custom project icon picked here (or on a session header) lands on the
        // matching row right away. Icons only — a full rebuild would drop hover state.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: AppSettings.didChange, object: nil)
    }

    @objc private func settingsChanged() {
        guard window?.isVisible == true, !isHidden else { return }
        for case let row as ProjectRowView in listStack.arrangedSubviews { row.refreshIcon() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildUI() {
        // Header row: project count on the left, a + to add a folder by hand.
        let addButton = GlassButton(symbol: "plus", action: #selector(addClicked), target: self)
        addButton.toolTip = L("手动添加项目", "Add project manually")
        addSubview(addButton)

        countLabel.font = Theme.font(11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped document view keeps a short list pinned to the TOP of the scroll
        // area (a bare NSStackView documentView sinks to the bottom when the
        // content is shorter than the clip view).
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        emptyLabel.font = Theme.font(12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.pad + 4),
            addButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad),
            countLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad - 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Theme.pad - 6)),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // Document tracks the clip's width (see pinDocumentWidth, called below);
            // its height follows the stack, so rows span full width and the scroller
            // appears only when needed.
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        pinDocumentWidth(doc, filling: scroll)
    }

    // MARK: Data

    /// Rebuild the list from ProjectHistory. Called right before showWindow and
    /// after a delete — NOT on the 2.5s scan (a rebuild would break hover state).
    func refresh(openCwds: Set<String>) {
        self.openCwds = openCwds
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = ProjectHistory.all()
        let names = ListModel.folderNames(entries.map { $0.path })
        emptyLabel.isHidden = !entries.isEmpty
        countLabel.stringValue = entries.isEmpty ? "" : L("\(entries.count) 个项目", "\(entries.count) projects")
        for e in entries {
            let row = ProjectRowView(entry: e,
                                     displayName: names[e.path] ?? (e.path as NSString).lastPathComponent,
                                     isOpen: openCwds.contains(e.path))
            row.onOpen = { [weak self] path in self?.onOpen?(path) }
            row.onPin = { [weak self] path, pinned in
                ProjectHistory.setPinned(path, pinned)
                self?.refresh(openCwds: self?.openCwds ?? [])   // re-sort: pinned float up
            }
            row.onDelete = { [weak self] path in
                ProjectHistory.remove(path)
                self?.refresh(openCwds: self?.openCwds ?? [])
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    // Folder picker for projects SpectiX never saw (no Claude session yet).
    @objc private func addClicked() {
        guard let window = window else { return }   // the host main window
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("添加", "Add")
        panel.message = L("选择要加入最近项目的文件夹", "Choose a folder to add to Recent")
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self = self else { return }
            for url in panel.urls { ProjectHistory.add(url.path) }
            self.refresh(openCwds: self.openCwds)
        }
    }

    /// Live-update just the 已打开 badges as sessions come and go, keeping rows
    /// (and any in-progress hover) intact.
    func updateOpenState(_ openCwds: Set<String>) {
        guard window?.isVisible == true, openCwds != self.openCwds else { return }
        self.openCwds = openCwds
        for case let row as ProjectRowView in listStack.arrangedSubviews {
            row.setOpen(openCwds.contains(row.path))
        }
    }
}

// MARK: - One project row

private final class ProjectRowView: NSView {

    let path: String
    var onOpen: ((String) -> Void)?
    var onPin: ((String, Bool) -> Void)?    // (path, new pinned value)
    var onDelete: ((String) -> Void)?

    private var hovering = false
    private var isOpen = false
    private let pinned: Bool
    // Icon slot: the folder's Finder icon by default, the user's custom emoji/image
    // badge once they pick one (same slot, only one visible at a time).
    private let folderIcon: NSImageView
    private let iconSlot = NSView()
    private let badge = LogoBadge()
    private let iconMenu = ProjectIconMenu()   // menu items hold their target weakly
    private let timeLabel = NSTextField(labelWithString: "")
    private let openBadge = NSView()
    private let pinIndicator = NSImageView()
    private var pinButton: GlassButton!
    private var deleteButton: GlassButton!

    init(entry: ProjectHistory.Entry, displayName: String, isOpen: Bool) {
        self.path = entry.path
        self.pinned = entry.pinned
        self.folderIcon = NSImageView(image: NSWorkspace.shared.icon(forFile: entry.path))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.chip
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true

        // Icon slot: a fixed-size box the folder icon and the custom badge both center
        // in, so swapping between them (they differ by 2pt) never shifts the name/path
        // columns beside it.
        let icon = iconSlot
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        // Real Finder icon of the folder — same trick as the header source icons.
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(folderIcon)
        badge.showsGripCursor = false   // nothing to drag here
        icon.addSubview(badge)

        let name = NSTextField(labelWithString: displayName)
        name.font = Theme.font(13, .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        let pathLabel = NSTextField(labelWithString: (entry.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.font = Theme.font(11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        // Both of these carry text whose length the user picks, not us — a deeply
        // nested project path runs far wider than the pane. At the default resistance
        // they'd win their ">= gap" against the badge/buttons and push the row wider,
        // which the scroll view then has to absorb. Truncating (tail for the name,
        // middle for the path, so both ends of a path stay readable) is the better
        // trade at any width.
        for f in [name, pathLabel] {
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // Right side: 已打开 badge (green dot + label) or the last-seen time.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Status.accent("done").cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        let openText = NSTextField(labelWithString: L("已打开", "Open"))
        openText.font = Theme.font(11, .medium)
        openText.textColor = Status.accent("done")
        openText.translatesAutoresizingMaskIntoConstraints = false
        openBadge.translatesAutoresizingMaskIntoConstraints = false
        openBadge.addSubview(dot)
        openBadge.addSubview(openText)

        timeLabel.stringValue = Self.relTime(entry.lastSeen)
        timeLabel.font = Theme.font(11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)
        addSubview(openBadge)

        // Always-visible pin corner mark for a pinned row (yields to the hover buttons).
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        pinIndicator.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        pinIndicator.contentTintColor = .secondaryLabelColor
        pinIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinIndicator)

        pinButton = GlassButton(symbol: pinned ? "pin.slash" : "pin", action: #selector(pinClicked), target: self)
        pinButton.toolTip = pinned ? L("取消置顶", "Unpin") : L("置顶", "Pin")
        pinButton.isHidden = true
        addSubview(pinButton)

        deleteButton = GlassButton(symbol: "xmark", action: #selector(deleteClicked), target: self)
        deleteButton.toolTip = L("从历史中移除", "Remove from history")
        deleteButton.isHidden = true
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            folderIcon.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            folderIcon.trailingAnchor.constraint(equalTo: icon.trailingAnchor),
            folderIcon.topAnchor.constraint(equalTo: icon.topAnchor),
            folderIcon.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            badge.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            name.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),

            pathLabel.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),

            openBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            openBadge.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: openBadge.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: openBadge.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            openText.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            openText.trailingAnchor.constraint(equalTo: openBadge.trailingAnchor),
            openText.topAnchor.constraint(equalTo: openBadge.topAnchor),
            openText.bottomAnchor.constraint(equalTo: openBadge.bottomAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            pinButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            pinIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pinIndicator.centerYAnchor.constraint(equalTo: name.centerYAnchor),
        ])

        setOpen(isOpen)
        refreshIcon()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOpen(_ open: Bool) {
        isOpen = open
        applyVisibility()
    }

    /// Show the icon the user picked for this folder (the same badge its session-list
    /// header wears), falling back to the Finder icon when there is none.
    func refreshIcon() {
        let custom = AppSettings.customIcon(cwd: path)
        if let c = custom { badge.configure(LogoBadge.mode(for: c)) }
        badge.isHidden = custom == nil
        folderIcon.isHidden = custom != nil
    }

    // Right-click anywhere on the row opens the icon menu. A folder header limits it
    // to the badge because the rest of the header has its own menu (hide/pin); here
    // the icon is the only thing to configure, so the whole row is the target.
    override func menu(for event: NSEvent) -> NSMenu? {
        iconMenu.menu(cwd: path, anchor: iconSlot)
    }

    // MARK: Interaction

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent)  { setHover(false) }

    // On hover the 📌+✕ take the right edge and the badge/time/pin mark yield
    // to them, so nothing overlaps in the row's fixed height.
    private func applyVisibility() {
        deleteButton.isHidden = !hovering
        pinButton.isHidden = !hovering
        pinIndicator.isHidden = hovering || !pinned
        openBadge.isHidden = hovering || !isOpen
        timeLabel.isHidden = hovering || isOpen || timeLabel.stringValue.isEmpty
    }

    private func setHover(_ on: Bool) {
        hovering = on
        applyVisibility()
        layer?.backgroundColor = on ? Theme.cardFillHover.cg(in: self) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hovering { layer?.backgroundColor = Theme.cardFillHover.cg(in: self) }
    }

    override func mouseUp(with event: NSEvent) {
        // Clicks on the delete button are swallowed by the button itself; a mouseUp
        // reaching the row means "open this project".
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?(path)
        }
    }

    @objc private func pinClicked()    { onPin?(path, !pinned) }
    @objc private func deleteClicked() { onDelete?(path) }

    // "刚刚 / N 分钟前 / N 小时前 / N 天前 / yyyy/M/d"; seeded entries (0) show nothing.
    private static func relTime(_ t: Double) -> String {
        guard t > 0 else { return "" }
        let s = Date().timeIntervalSince1970 - t
        switch s {
        case ..<60:      return L("刚刚", "just now")
        case ..<3600:    return L("\(Int(s / 60)) 分钟前", "\(Int(s / 60))m ago")
        case ..<86400:   return L("\(Int(s / 3600)) 小时前", "\(Int(s / 3600))h ago")
        case ..<2592000: return L("\(Int(s / 86400)) 天前", "\(Int(s / 86400))d ago")
        default:
            let df = DateFormatter()
            df.dateFormat = "yyyy/M/d"
            return df.string(from: Date(timeIntervalSince1970: t))
        }
    }
}

// A flipped container so scroll content hangs from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
