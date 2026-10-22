import Cocoa

// MARK: - Quick actions
//
// One-click actions the user binds to a shell script, a Claude skill, or a plain
// prompt for Claude, opened from the wrench at the right end of both bottom bars
// (design/quick-actions.html, scheme 2: drawer of tiles). Stored as a plain JSON
// array in ~/.claude/spectix/actions.json so Claude itself can add entries; the
// file is re-read every time the drawer opens. See docs/quick-actions.md.

struct QuickAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case script, skill, prompt }

    var id: String?
    var emoji: String?
    var name: String
    var kind: Kind
    var body: String
    var cwd: String?
    var inTerminal: Bool?
    var confirm: Bool?

    var key: String { id ?? name }
    var icon: String { (emoji?.isEmpty == false) ? emoji! : "⚡️" }
}

// MARK: - Store

final class QuickActionStore {
    static let shared = QuickActionStore()
    static let didChange = Notification.Name("QuickActionStore.didChange")
    static var path: String { NSHomeDirectory() + "/.claude/spectix/actions.json" }

    private(set) var actions: [QuickAction] = []
    private(set) var loadError: String?
    private var mtime: Date?

    // No post from init: an observer reading `shared` inside its own handler would
    // re-enter the lazy static initializer and trap.
    private init() { load() }

    // Cheap stat; only decodes when the file changed since the last read.
    func reloadIfChanged() {
        if load() { post() }
    }

    /// Returns whether anything was (re)read.
    @discardableResult
    private func load() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.path)
        let m = attrs?[.modificationDate] as? Date
        guard m != mtime else { return false }
        mtime = m
        guard let data = FileManager.default.contents(atPath: Self.path) else {
            actions = []; loadError = nil; return true
        }
        do {
            actions = try JSONDecoder().decode([QuickAction].self, from: data)
            loadError = nil
        } catch {
            loadError = L("actions.json 读不懂：\(error.localizedDescription)",
                          "Can't read actions.json: \(error.localizedDescription)")
        }
        return true
    }

    func upsert(_ action: QuickAction, replacing oldKey: String? = nil) {
        var list = actions
        if let i = list.firstIndex(where: { $0.key == (oldKey ?? action.key) }) { list[i] = action }
        else { list.append(action) }
        save(list)
    }

    func remove(_ key: String) { save(actions.filter { $0.key != key }) }

    private func save(_ list: [QuickAction]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(list) else { return }
        let url = URL(fileURLWithPath: Self.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        actions = list
        loadError = nil
        mtime = (try? FileManager.default.attributesOfItem(atPath: Self.path))?[.modificationDate] as? Date
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: nil) }
}

// MARK: - Runner

final class QuickActionRunner {
    static let shared = QuickActionRunner()
    static let didChange = Notification.Name("QuickActionRunner.didChange")

    struct Result {
        let action: QuickAction
        let exitCode: Int32
        let output: String
        let duration: TimeInterval
        let finished: Date
        var ok: Bool { exitCode == 0 }
    }

    enum Badge { case none, running, ok, failed }

    private(set) var running: [String: pid_t] = [:]
    private(set) var results: [String: Result] = [:]
    /// What the wrench's corner dot shows; ok/failed stick until the drawer is opened.
    private(set) var badge: Badge = .none
    private var failedSinceAck = false
    private var stopped: Set<String> = []

    private static var logDir: String { NSHomeDirectory() + "/.claude/spectix/actions" }

    func isRunning(_ key: String) -> Bool { running[key] != nil }

    func acknowledge() {
        guard running.isEmpty, badge != .none else { return }
        badge = .none
        failedSinceAck = false
        post()
    }

    func run(_ action: QuickAction) {
        guard !isRunning(action.key) else { return }
        if action.confirm == true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("运行「\(action.name)」？", "Run “\(action.name)”?")
            alert.informativeText = action.body
            alert.addButton(withTitle: L("运行", "Run"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if action.inTerminal == true { runInTerminal(action) } else { runInBackground(action) }
    }

    func stop(_ key: String) {
        guard let pid = running[key] else { return }
        stopped.insert(key)
        kill(-pid, SIGTERM)   // whole process group: zsh + claude + its children
    }

    // MARK: Command building

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func directory(_ a: QuickAction) -> String {
        let raw = a.cwd?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? NSHomeDirectory() : (raw as NSString).expandingTildeInPath
    }

    private static func command(_ a: QuickAction, interactive: Bool) -> String {
        switch a.kind {
        case .script:
            return a.body
        case .skill, .prompt:
            var prompt = a.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.kind == .skill, !prompt.hasPrefix("/") { prompt = "/" + prompt }
            return interactive
                ? "claude \(quote(prompt))"
                // No one is there to click "allow" in the background.
                : "claude -p \(quote(prompt)) --permission-mode acceptEdits"
        }
    }

    // GUI apps don't inherit the shell PATH; a login zsh plus the usual homes of `claude`.
    private static func script(_ a: QuickAction, interactive: Bool) -> String {
        """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd \(quote(directory(a))) || exit 1
        \(command(a, interactive: interactive))
        """
    }

    private static func logPath(_ a: QuickAction) -> String {
        let safe = a.key.map { "/:\\".contains($0) ? "_" : $0 }
        return "\(logDir)/\(String(safe)).log"
    }

    // MARK: Background

    private func runInBackground(_ a: QuickAction) {
        try? FileManager.default.createDirectory(atPath: Self.logDir, withIntermediateDirectories: true)
        let log = Self.logPath(a)
        guard let pid = Self.spawn(["/bin/zsh", "-lc", Self.script(a, interactive: false)], output: log) else {
            finish(a, exitCode: -1, started: Date(),
                   output: L("启动失败：/bin/zsh 起不来", "Failed to start /bin/zsh"))
            return
        }
        running[a.key] = pid
        badge = .running
        post()
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            // WIFEXITED / WEXITSTATUS by hand: the macros don't import into Swift.
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
            let out = Self.tail(of: log)
            DispatchQueue.main.async { self.finish(a, exitCode: code, started: started, output: out) }
        }
    }

    private func finish(_ a: QuickAction, exitCode: Int32, started: Date, output: String) {
        running[a.key] = nil
        let r = Result(action: a, exitCode: exitCode, output: output,
                       duration: Date().timeIntervalSince(started), finished: Date())
        results[a.key] = r
        let wasStopped = stopped.remove(a.key) != nil
        if !r.ok && !wasStopped { failedSinceAck = true }
        if running.isEmpty { badge = failedSinceAck ? .failed : .ok }
        post()
        let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
        ToastManager.shared.show(
            title: a.name,
            subtitle: wasStopped ? L("已停止", "Stopped")
                : r.ok ? (lastLine.isEmpty ? L("跑完了", "Done") : lastLine)
                : L("跑挂了（退出码 \(exitCode)）· 点这里看输出", "Failed (exit \(exitCode)) · click for output"),
            icon: .custom(a.icon), status: r.ok || wasStopped ? "done" : "needs",
            path: "!action-\(a.key)") { QuickActionResultWindow.show(a.key) }
    }

    // Last 64 KB is plenty to read and keeps a chatty script from bloating memory.
    private static func tail(of path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 65_536 ? size - 65_536 : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // posix_spawn with TCC responsibility disclaimed (see docs/permissions.md: a child
    // that pokes protected folders must not bill the prompts to SpectiX), in its own
    // process group so stop() can take the whole tree down, stdout+stderr → `output`.
    private static func spawn(_ argv: [String], output: String) -> pid_t? {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)

        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], &fa, &attr, &cargv, environ) == 0 else { return nil }
        return pid
    }

    // MARK: Terminal

    // A .command file opened with Terminal: no Apple Events, so no Automation prompt.
    private func runInTerminal(_ a: QuickAction) {
        try? FileManager.default.createDirectory(atPath: Self.logDir, withIntermediateDirectories: true)
        let path = Self.logPath(a).replacingOccurrences(of: ".log", with: ".command")
        let body = "#!/bin/zsh -l\nclear\n" + Self.script(a, interactive: true) + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(path, 0o755)
        if let pid = Self.spawn(["/usr/bin/open", "-a", "Terminal", path], output: "/dev/null") {
            DispatchQueue.global(qos: .utility).async { waitpid(pid, nil, 0) }
        }
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: nil) }
}

// MARK: - Wrench button

// The bottom-bar entry: an icon-only TabItemButton plus a corner dot that breathes
// blue while anything runs and settles green / red until the drawer is next opened.
final class QuickActionsButton: NSView {
    var onClick: (() -> Void)?
    var isOpen = false { didSet { button.isOn = isOpen } }

    private let button = TabItemButton(symbol: "wrench.and.screwdriver", label: "", index: -1)
    private let dot = CALayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        button.toolTip = L("快捷动作", "Quick actions")
        button.target = self
        button.action = #selector(clicked)
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 30),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        dot.frame = CGRect(x: 26, y: 20, width: 7, height: 7)
        dot.cornerRadius = 3.5
        layer?.addSublayer(dot)
        setContentHuggingPriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: QuickActionRunner.didChange, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    @objc private func refresh() {
        dot.removeAllAnimations()
        switch QuickActionRunner.shared.badge {
        case .none:
            dot.isHidden = true
        case .running:
            dot.isHidden = false
            dot.backgroundColor = Status.accent("working").cgColor
            // Model value parked at the dim end; phase anchored to Motion.epoch.
            dot.opacity = 0.45
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.45; a.toValue = 1
            a.duration = 0.7; a.autoreverses = true; a.repeatCount = .infinity
            a.beginTime = Motion.epoch
            dot.add(a, forKey: "breath")
        case .ok, .failed:
            dot.isHidden = false
            dot.opacity = 1
            dot.backgroundColor = Status.accent(QuickActionRunner.shared.badge == .ok ? "done" : "needs").cgColor
        }
    }
}

// MARK: - Drawer

// Floating card above the bottom bar: three columns of tiles, the last one "+".
// Click a tile = run; right-click = edit / last output / stop / delete.
final class QuickActionsDrawer: NSView {
    var onLayoutChange: (() -> Void)?

    private let base = OpaquePane(radius: 14)
    private let glass = Theme.surfacePane(material: .hudWindow, radius: 14)
    private let title = NSTextField(labelWithString: L("快捷动作", "Quick actions"))
    private let editLink = NSButton(title: L("打开文件", "Open file"), target: nil, action: nil)
    private let grid = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    static let columns = 3

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        for v in [base, glass] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        glass.wantsLayer = true
        glass.layer?.borderWidth = 1

        title.font = Theme.rounded(11.5, .bold)
        editLink.isBordered = false
        editLink.font = Theme.rounded(10.5, .medium)
        editLink.contentTintColor = .tertiaryLabelColor
        editLink.target = self
        editLink.action = #selector(openFile)
        editLink.toolTip = QuickActionStore.path

        note.font = Theme.font(10.5, .regular)
        note.textColor = .systemOrange
        note.isHidden = true

        grid.orientation = .vertical
        grid.spacing = 7
        grid.alignment = .leading

        let head = NSStackView(views: [title, NSView(), editLink])
        head.orientation = .horizontal
        let stack = NSStackView(views: [head, note, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)

        NSLayoutConstraint.activate([
            base.topAnchor.constraint(equalTo: topAnchor), base.bottomAnchor.constraint(equalTo: bottomAnchor),
            base.leadingAnchor.constraint(equalTo: leadingAnchor), base.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: QuickActionStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTiles),
                                               name: QuickActionRunner.didChange, object: nil)
        rebuild()
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called on open: pick up edits Claude (or the user) made to actions.json.
    func prepareForShow() {
        QuickActionStore.shared.reloadIfChanged()
        QuickActionRunner.shared.acknowledge()
    }

    @objc private func rebuild() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let store = QuickActionStore.shared
        note.stringValue = store.loadError ?? ""
        note.isHidden = store.loadError == nil
        var tiles: [NSView] = store.actions.map { QuickActionTile(action: $0) }
        tiles.append(QuickActionTile(action: nil))
        for start in stride(from: 0, to: tiles.count, by: Self.columns) {
            var rowViews = Array(tiles[start..<min(start + Self.columns, tiles.count)])
            while rowViews.count < Self.columns { rowViews.append(NSView()) }   // keep column widths
            let row = NSStackView(views: rowViews)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 7
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        onLayoutChange?()
    }

    @objc private func refreshTiles() {
        for case let row as NSStackView in grid.arrangedSubviews {
            for case let tile as QuickActionTile in row.arrangedSubviews { tile.refresh() }
        }
    }

    @objc private func openFile() {
        let path = QuickActionStore.path
        if !FileManager.default.fileExists(atPath: path) {
            try? "[]\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func resolveColors() {
        glass.layer?.borderColor = Theme.hairline.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// One tile: emoji over name, kind tag in the corner. `action == nil` is the "+" tile.
final class QuickActionTile: NSView {
    private let action: QuickAction?
    private let icon = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let kindTag = NSTextField(labelWithString: "")
    private var hovering = false

    init(action: QuickAction?) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        icon.stringValue = action?.icon ?? "＋"
        icon.font = .systemFont(ofSize: action == nil ? 17 : 20)
        icon.alignment = .center
        name.stringValue = action?.name ?? L("添加", "Add")
        name.font = Theme.rounded(10.5, .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 2
        name.cell?.wraps = true
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = action.map { "\($0.name)\n\($0.body)" }

        kindTag.font = Theme.rounded(8, .heavy)
        kindTag.isHidden = action == nil
        switch action?.kind {
        case .skill:  kindTag.stringValue = "SKILL"
        case .script: kindTag.stringValue = L("脚本", "SCRIPT")
        case .prompt: kindTag.stringValue = L("一句话", "PROMPT")
        case nil: break
        }

        let col = NSStackView(views: [icon, name])
        col.orientation = .vertical
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        kindTag.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kindTag)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            col.centerXAnchor.constraint(equalTo: centerXAnchor),
            col.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            col.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            col.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            kindTag.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            kindTag.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var busy: Bool { action.map { QuickActionRunner.shared.isRunning($0.key) } ?? false }

    func refresh() {
        let blue = Status.accent("working")
        if busy {
            layer?.backgroundColor = blue.withAlphaComponent(0.12).cgColor
            layer?.borderColor = blue.withAlphaComponent(0.55).cgColor
        } else {
            layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
            layer?.borderColor = Theme.hairline.cg(in: self)
        }
        name.textColor = action == nil ? .tertiaryLabelColor : .labelColor
        icon.textColor = action == nil ? .tertiaryLabelColor : .labelColor
        icon.alphaValue = busy ? 0.5 : 1
        switch action?.kind {
        case .skill:  kindTag.textColor = NSColor(srgbRed: 0.91, green: 0.54, blue: 0.36, alpha: 1)
        case .prompt: kindTag.textColor = Theme.agentAccent
        default:      kindTag.textColor = .tertiaryLabelColor
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent)  { hovering = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    // Claim the press so the matching mouseUp comes back to this view.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        guard let action else { QuickActionEditor.open(nil); return }
        QuickActionRunner.shared.run(action)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let action else { return nil }
        let m = NSMenu()
        let runner = QuickActionRunner.shared
        if runner.isRunning(action.key) {
            m.addItem(item(L("停止", "Stop")) { runner.stop(action.key) })
        } else {
            m.addItem(item(L("运行", "Run")) { runner.run(action) })
        }
        let last = item(L("看上次输出", "Last output")) { QuickActionResultWindow.show(action.key) }
        last.isEnabled = runner.results[action.key] != nil
        m.addItem(last)
        m.addItem(.separator())
        m.addItem(item(L("编辑…", "Edit…")) { QuickActionEditor.open(action) })
        m.addItem(item(L("删除", "Delete")) { QuickActionStore.shared.remove(action.key) })
        m.autoenablesItems = false
        return m
    }

    private func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, handler: handler)
        i.isEnabled = true
        return i
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - Editor window

final class QuickActionEditor: NSObject, NSWindowDelegate {
    private static var current: QuickActionEditor?

    static func open(_ action: QuickAction?) {
        current?.window.close()
        let e = QuickActionEditor(action)
        current = e
        NSApp.activate(ignoringOtherApps: true)
        e.window.center()
        e.window.makeKeyAndOrderFront(nil)
    }

    private let original: QuickAction?
    private let window: NSWindow
    private let emoji = NSTextField()
    private let name = NSTextField()
    private let kind = NSSegmentedControl(labels: [L("脚本", "Script"), "Skill", L("一句话", "Prompt")],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let kindNote = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let body = NSTextView()
    private let cwd = NSTextField()
    private let cwdRow = NSStackView()
    private let whereSeg = NSSegmentedControl(labels: [L("后台跑，跑完通知我", "Background, notify me"),
                                                       L("开个终端窗口跑", "In a Terminal window")],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let whereNote = NSTextField(wrappingLabelWithString: "")
    private let confirm = NSButton(checkboxWithTitle: L("运行前先问我一句", "Ask before running"), target: nil, action: nil)

    private init(_ action: QuickAction?) {
        original = action
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = action == nil ? L("添加快捷动作", "Add quick action") : L("编辑快捷动作", "Edit quick action")
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        fill(action)
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.font(12, .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        return l
    }

    private func build() {
        emoji.placeholderString = "⚡️"
        emoji.alignment = .center
        emoji.widthAnchor.constraint(equalToConstant: 40).isActive = true
        name.placeholderString = L("比如：清理 G915 配对", "e.g. Unpair G915")
        let nameRow = NSStackView(views: [emoji, name])

        kind.target = self
        kind.action = #selector(kindChanged)
        for n in [kindNote, whereNote] {
            n.font = Theme.font(10.5, .regular)
            n.textColor = .tertiaryLabelColor
            n.preferredMaxLayoutWidth = 340
        }
        let kindCol = NSStackView(views: [kind, kindNote])
        kindCol.orientation = .vertical
        kindCol.alignment = .leading

        body.isRichText = false
        body.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.textContainerInset = NSSize(width: 4, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        body.autoresizingMask = [.width]
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true

        cwd.placeholderString = "~"
        let pick = NSButton(title: L("选择…", "Choose…"), target: self, action: #selector(pickFolder))
        pick.bezelStyle = .rounded
        cwdRow.setViews([cwd, pick], in: .leading)

        whereSeg.target = self
        whereSeg.action = #selector(whereChanged)
        let whereCol = NSStackView(views: [whereSeg, whereNote])
        whereCol.orientation = .vertical
        whereCol.alignment = .leading

        let grid = NSGridView(views: [
            [label(L("名字", "Name")), nameRow],
            [label(L("类型", "Type")), kindCol],
            [bodyLabel, scroll],
            [label(L("目录", "Folder")), cwdRow],
            [label(L("怎么跑", "Run")), whereCol],
            [NSGridCell.emptyContentView, confirm],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).width = 56
        grid.rowAlignment = .firstBaseline
        bodyLabel.font = Theme.font(12, .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .right
        grid.row(at: 2).yPlacement = .top

        let delete = NSButton(title: L("删除", "Delete"), target: self, action: #selector(deleteAction))
        delete.isHidden = original == nil
        let test = NSButton(title: L("▶ 试跑一次", "▶ Test run"), target: self, action: #selector(testRun))
        let cancel = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("保存", "Save"), target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        for b in [delete, test, cancel, save] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [delete, test, NSView(), cancel, save])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        window.contentView = root
    }

    private func fill(_ a: QuickAction?) {
        emoji.stringValue = a?.emoji ?? ""
        name.stringValue = a?.name ?? ""
        kind.selectedSegment = QuickAction.Kind.allCases.firstIndex(of: a?.kind ?? .script) ?? 0
        body.string = a?.body ?? ""
        cwd.stringValue = a?.cwd ?? ""
        whereSeg.selectedSegment = a?.inTerminal == true ? 1 : 0
        confirm.state = a?.confirm == true ? .on : .off
        kindChanged()
        whereChanged()
    }

    private var selectedKind: QuickAction.Kind { QuickAction.Kind.allCases[max(kind.selectedSegment, 0)] }

    @objc private func kindChanged() {
        switch selectedKind {
        case .script:
            bodyLabel.stringValue = L("命令", "Command")
            kindNote.stringValue = L("用 zsh 跑，和你在终端里敲一样。不经过 Claude，不花 token。",
                                     "Runs in zsh, same as typing it in Terminal. No Claude, no tokens.")
        case .skill:
            bodyLabel.stringValue = "Skill"
            kindNote.stringValue = L("填一个 skill，比如 /morning。等于在下面的目录里跑 claude -p \"/morning\"。",
                                     "One skill, e.g. /morning. Same as running claude -p \"/morning\" in the folder below.")
        case .prompt:
            bodyLabel.stringValue = L("告诉 Claude", "Tell Claude")
            kindNote.stringValue = L("写一句话就行，不用先做成 skill。等于 claude -p \"…\"。",
                                     "Just a sentence, no skill needed. Same as claude -p \"…\".")
        }
    }

    @objc private func whereChanged() {
        whereNote.stringValue = whereSeg.selectedSegment == 1
            ? L("在 Terminal 里开新窗口跑：过程看得见，Claude 要你确认时也能直接回答。",
                "Opens a new Terminal window: you see it run and can answer Claude's prompts.")
            : L("看不到过程，跑完弹通知。Claude 会自动接受改文件，没人在场点「允许」。",
                "Runs unseen and notifies when done. Claude auto-accepts edits since no one is there to click Allow.")
    }

    @objc private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            self?.cwd.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func draft() -> QuickAction? {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let b = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !b.isEmpty else {
            NSSound.beep()
            window.makeFirstResponder(n.isEmpty ? name : body)
            return nil
        }
        let e = emoji.stringValue.trimmingCharacters(in: .whitespaces)
        let c = cwd.stringValue.trimmingCharacters(in: .whitespaces)
        return QuickAction(id: original?.id ?? UUID().uuidString.prefix(8).lowercased(),
                           emoji: e.isEmpty ? nil : e, name: n, kind: selectedKind, body: b,
                           cwd: c.isEmpty ? nil : c,
                           inTerminal: whereSeg.selectedSegment == 1 ? true : nil,
                           confirm: confirm.state == .on ? true : nil)
    }

    @objc private func saveAction() {
        guard let a = draft() else { return }
        QuickActionStore.shared.upsert(a, replacing: original?.key)
        window.close()
    }

    @objc private func testRun() {
        guard let a = draft() else { return }
        QuickActionRunner.shared.run(a)
    }

    @objc private func deleteAction() {
        if let k = original?.key { QuickActionStore.shared.remove(k) }
        window.close()
    }

    @objc private func cancel() { window.close() }
}

// MARK: - Result window

final class QuickActionResultWindow: NSObject {
    private static var window: NSWindow?
    private static var shownKey: String?

    static func show(_ key: String) {
        guard let r = QuickActionRunner.shared.results[key] else { return }
        shownKey = key
        let w = window ?? make()
        window = w
        w.title = "\(r.action.icon) \(r.action.name)"
        let text = (w.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTextView)
        let head = r.ok ? L("✓ 跑完了", "✓ Done") : L("✗ 跑挂了（退出码 \(r.exitCode)）", "✗ Failed (exit \(r.exitCode))")
        let secs = Int(r.duration.rounded())
        text?.string = "\(head) · \(secs / 60 > 0 ? "\(secs / 60)m " : "")\(secs % 60)s\n\n"
            + (r.output.isEmpty ? L("（没有输出）", "(no output)") : r.output)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.center()
        let text = NSTextView()
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: L("复制", "Copy"), target: self, action: #selector(copyOutput))
        let again = NSButton(title: L("再跑一次", "Run again"), target: self, action: #selector(runAgain))
        let bar = NSStackView(views: [copy, NSView(), again])
        bar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        w.contentView = root
        return w
    }

    @objc private static func copyOutput() {
        guard let k = shownKey, let r = QuickActionRunner.shared.results[k] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.output, forType: .string)
    }

    @objc private static func runAgain() {
        guard let k = shownKey, let r = QuickActionRunner.shared.results[k] else { return }
        window?.close()
        QuickActionRunner.shared.run(r.action)
    }
}
