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
    var icon: String? { emoji?.isEmpty == false ? emoji : nil }
}

extension QuickAction.Kind {
    /// Tile corner tag.
    var tag: String {
        switch self {
        case .script: return "BASH"
        case .skill:  return "AI·SKILL"
        case .prompt: return "AI"
        }
    }

    /// Detail page pill: says plainly whether Claude is involved.
    var label: String {
        switch self {
        case .script: return L("Bash 脚本 · 不经过 AI", "Bash script · no AI")
        case .skill:  return L("AI · Claude 跑 skill", "AI · Claude runs a skill")
        case .prompt: return L("AI · Claude 照一句话做", "AI · Claude follows a prompt")
        }
    }

    var tint: NSColor {
        switch self {
        case .script: return .secondaryLabelColor
        case .skill:  return NSColor(srgbRed: 0.91, green: 0.54, blue: 0.36, alpha: 1)
        case .prompt: return Theme.agentAccent
        }
    }
}

// MARK: - Store

final class QuickActionStore {
    static let shared = QuickActionStore()
    static let didChange = Notification.Name("QuickActionStore.didChange")
    static var path: String {
        Demo.enabled ? Demo.actionsPath : NSHomeDirectory() + "/.claude/spectix/actions.json"
    }

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

    /// What "Copy for AI" puts on the clipboard: enough for any agent that can edit
    /// files to add an action, no skill or MCP server needed. The user types their
    /// request after the last line.
    static var aiPrompt: String {
        let example = #"{"id":"disk-space","emoji":"💾","name":"Disk","kind":"script","body":"df -h / | tail -1"}"#
        return L("""
        帮我在 SpectiX 里加一个快捷动作（菜单栏 App 右下角扳手里的按钮）。
        做法：编辑 \(path)。它是一个 JSON 数组，每个元素是一个按钮；文件不存在就新建为 []。保留已有的元素，只追加；写完确认还是合法 JSON。SpectiX 下次打开抽屉会自动读到，不用重启。
        字段：
        - id：短英文，唯一，比如 "disk-space"
        - emoji：一个表情
        - name：按钮上的字，越短越好
        - kind："script" = 用 zsh 跑一段 shell 命令，不经过 AI；"skill" = 让 Claude Code 跑一个 skill，body 写 "/名字"，要带话就跟在后面（"/morning today"）；"prompt" = 让 Claude 照一句话去做（等于 claude -p "…"）
        - body：命令 / skill 名 / 那句话
        - cwd：可选，在哪个文件夹跑；不写就在 SpectiX 自己的文件夹里跑（推荐）。处理某个项目时填项目路径。别填 ~：Claude 在主目录里启动会触发一串 macOS 权限弹窗
        - inTerminal：可选，true = 开终端窗口跑（需要我交互时用）；不写就是后台跑，跑完弹通知，通知里显示最后一行输出
        - confirm：可选，true = 运行前先弹窗确认；删除、重置这类改不回来的动作一定要加
        例子：\(example)
        script 里用到的命令行工具我没装的话，先告诉我怎么装。如果你改不了我电脑上的文件，就只回我这一个 JSON 对象，我粘贴进 SpectiX。
        我要的按钮：
        """, """
        Add a quick action to SpectiX for me (a button in the wrench drawer of the menu-bar app).
        How: edit \(path). It is a JSON array, one element per button; create it as [] if missing. Keep existing elements and only append; make sure it is still valid JSON. SpectiX picks it up the next time the drawer opens, no restart.
        Fields:
        - id: short, unique, e.g. "disk-space"
        - emoji: one emoji
        - name: button label, as short as possible
        - kind: "script" = a shell command run in zsh, no AI; "skill" = Claude Code runs a skill, body is "/name", optionally followed by text ("/morning today"); "prompt" = Claude follows one sentence (same as claude -p "…")
        - body: the command / skill name / the sentence
        - cwd: optional, folder to run in; leave it out to run in SpectiX's own folder (recommended). Use a project path to work on that project. Never ~: Claude starting in the home folder triggers a string of macOS permission prompts
        - inTerminal: optional, true = run in a Terminal window (when I need to interact); otherwise it runs in the background and notifies with the last output line
        - confirm: optional, true = ask before running; always set it for anything destructive
        Example: \(example)
        If the script needs a CLI tool I may not have, tell me how to install it first. If you can't edit files on my machine, reply with just that one JSON object and I'll paste it into SpectiX.
        The button I want:
        """) + " "
    }

    /// Pulls one action out of whatever an AI replied: tolerates prose around the
    /// JSON and a one-element array.
    static func parse(_ text: String) -> QuickAction? {
        let dec = JSONDecoder()
        for (open, close) in [("{", "}"), ("[", "]")] {
            guard let a = text.firstIndex(of: Character(open)),
                  let b = text.lastIndex(of: Character(close)), a < b else { continue }
            let data = Data(text[a...b].utf8)
            if let one = try? dec.decode(QuickAction.self, from: data) { return one }
            if let many = try? dec.decode([QuickAction].self, from: data), let first = many.first { return first }
        }
        return nil
    }
}

// MARK: - Runner

final class QuickActionRunner {
    static let shared = QuickActionRunner()
    static let didChange = Notification.Name("QuickActionRunner.didChange")
    /// Once a second while anything runs, so elapsed times and live output can tick.
    static let didTick = Notification.Name("QuickActionRunner.didTick")

    struct Result {
        let action: QuickAction
        let exitCode: Int32
        let output: String
        let duration: TimeInterval
        let finished: Date
        var stopped = false
        var ok: Bool { exitCode == 0 }
    }

    enum Badge { case none, running, ok, failed }

    private(set) var running: [String: pid_t] = [:]
    private(set) var startedAt: [String: Date] = [:]
    /// Terminal runs aren't tracked; this only remembers when one was opened.
    private(set) var openedInTerminal: [String: Date] = [:]
    private var ticker: Timer?
    private(set) var results: [String: Result] = [:]
    /// What the wrench's corner dot shows; ok/failed stick until the drawer is opened.
    private(set) var badge: Badge = .none
    private var failedSinceAck = false
    private var stopped: Set<String> = []

    private static var logDir: String { NSHomeDirectory() + "/.claude/spectix/actions" }

    func isRunning(_ key: String) -> Bool { running[key] != nil }

    func elapsed(_ key: String) -> TimeInterval? { startedAt[key].map { Date().timeIntervalSince($0) } }

    /// What the log holds so far, for watching a background run live.
    func liveOutput(_ a: QuickAction) -> String { Self.tail(of: Self.logPath(a)) }

    /// The command line as the user would type it (ignores demo mode's stand-in).
    static func commandPreview(_ a: QuickAction) -> String {
        realCommand(a, interactive: a.inTerminal == true)
    }

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

    /// Where an action runs when it names no folder: SpectiX's own, so whatever it
    /// writes stays there, and Claude never starts in ~ (it scans its folder on launch,
    /// and ~ holds Desktop / Documents / Downloads — one macOS prompt each).
    static var workspace: String { NSHomeDirectory() + "/.claude/spectix/actions/workspace" }

    static func isHome(_ path: String) -> Bool {
        let p = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: p).standardizedFileURL.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    }

    private static func directory(_ a: QuickAction) -> String {
        let raw = a.cwd?.trimmingCharacters(in: .whitespaces) ?? ""
        guard raw.isEmpty else { return (raw as NSString).expandingTildeInPath }
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private static func command(_ a: QuickAction, interactive: Bool) -> String {
        // Demo tiles only pretend: nothing real runs behind a fake button.
        if Demo.enabled { return "sleep 4; echo \(quote(Demo.actionOutput(a.key)))" }
        return realCommand(a, interactive: interactive)
    }

    private static func realCommand(_ a: QuickAction, interactive: Bool) -> String {
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
        let started = Date()
        running[a.key] = pid
        startedAt[a.key] = started
        badge = .running
        startTicker()
        post()
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
        startedAt[a.key] = nil
        if running.isEmpty { ticker?.invalidate(); ticker = nil }
        let wasStopped = stopped.remove(a.key) != nil
        let r = Result(action: a, exitCode: exitCode, output: output,
                       duration: Date().timeIntervalSince(started), finished: Date(), stopped: wasStopped)
        results[a.key] = r
        if !r.ok && !wasStopped { failedSinceAck = true }
        if running.isEmpty { badge = failedSinceAck ? .failed : .ok }
        post()
        let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
        ToastManager.shared.show(
            title: a.name,
            subtitle: wasStopped ? L("已停止", "Stopped")
                : r.ok ? (lastLine.isEmpty ? L("跑完了", "Done") : lastLine)
                : L("跑挂了（退出码 \(exitCode)）· 点这里看输出", "Failed (exit \(exitCode)) · click for output"),
            icon: .custom(a.icon ?? ""), status: r.ok || wasStopped ? "done" : "needs",
            path: "!action-\(a.key)") { QuickActionResultWindow.show(a.key) }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            NotificationCenter.default.post(name: Self.didTick, object: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
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
    static func spawn(_ argv: [String], output: String) -> pid_t? {
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
            openedInTerminal[a.key] = Date()
            post()
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
// Click a tile = its detail page; hover bar = run / details; right-click = the full menu.
final class QuickActionsDrawer: NSView {
    var onLayoutChange: (() -> Void)?

    private let base = OpaquePane(radius: 14)
    private let glass = Theme.surfacePane(material: .hudWindow, radius: 14)
    private let title = NSTextField(labelWithString: L("快捷动作", "Quick actions"))
    private let editLink = NSButton(title: L("打开文件", "Open file"), target: nil, action: nil)
    private let grid = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let head = NSStackView()
    private let detail = QuickActionDetail()
    private let form = QuickActionForm()
    private let aiRow = MCPConnectRow()
    private let formScroll = NSScrollView()
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

        head.setViews([title, NSView(), editLink], in: .leading)
        head.orientation = .horizontal
        detail.isHidden = true
        detail.onBack = { [weak self] in self?.showDetail(nil) }
        detail.onEdit = { [weak self] in self?.showForm($0) }
        form.onClose = { [weak self] in self?.showDetail($0) }
        formScroll.documentView = form
        formScroll.drawsBackground = false
        formScroll.hasVerticalScroller = true
        formScroll.autohidesScrollers = true
        formScroll.isHidden = true
        let stack = NSStackView(views: [head, aiRow, note, grid, detail, formScroll])
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
            aiRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            form.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            // As tall as the form, but the host's top limit wins and the form scrolls.
            formScroll.heightAnchor.constraint(lessThanOrEqualTo: form.heightAnchor),
        ])
        let fitForm = formScroll.heightAnchor.constraint(equalTo: form.heightAnchor)
        fitForm.priority = .defaultLow
        fitForm.isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: QuickActionStore.didChange, object: nil)
        for n in [QuickActionRunner.didChange, QuickActionRunner.didTick] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshTiles), name: n, object: nil)
        }
        rebuild()
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called on open: pick up edits Claude (or the user) made to actions.json.
    func prepareForShow() {
        QuickActionStore.shared.reloadIfChanged()
        QuickActionRunner.shared.acknowledge()
        aiRow.start()
        if formScroll.isHidden { showDetail(nil) }   // a half-filled form survives the popover closing
        refreshTiles()   // "✓ 3m ago" only ticks while something runs
    }

    /// nil = back to the tile grid.
    func showDetail(_ action: QuickAction?) {
        detail.action = action
        show(detail: action != nil, form: false)
    }

    /// nil = add a new action.
    func showForm(_ action: QuickAction?) {
        form.load(action)
        show(detail: false, form: true)
        formScroll.contentView.scroll(to: .zero)
        window?.makeFirstResponder(form.name)
    }

    private func show(detail showsDetail: Bool, form showsForm: Bool) {
        detail.isHidden = !showsDetail
        formScroll.isHidden = !showsForm
        grid.isHidden = showsDetail || showsForm
        head.isHidden = showsDetail || showsForm
        aiRow.isHidden = showsDetail || showsForm
        onLayoutChange?()
    }

    @objc private func rebuild() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let store = QuickActionStore.shared
        note.stringValue = store.loadError ?? ""
        note.isHidden = store.loadError == nil
        var tiles: [NSView] = store.actions.map { a in
            let t = QuickActionTile(action: a)
            t.onOpen = { [weak self] in self?.showDetail($0) }
            t.onEdit = { [weak self] in self?.showForm($0) }
            return t
        }
        let add = QuickActionTile(action: nil)
        add.onEdit = { [weak self] in self?.showForm($0) }
        tiles.append(add)
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
        // Follow an edit made while its page is open; a deleted action drops back to the grid.
        if !detail.isHidden, let open = detail.action {
            showDetail(store.actions.first { $0.key == open.key })
            return
        }
        onLayoutChange?()
    }

    @objc private func refreshTiles() {
        for case let row as NSStackView in grid.arrangedSubviews {
            for case let tile as QuickActionTile in row.arrangedSubviews { tile.refresh() }
        }
        if !detail.isHidden { detail.refresh() }
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

// The drawer's page for one action: what it is (Bash or AI), what exactly runs,
// whether it is running right now, its output (live while running), run / stop.
final class QuickActionDetail: NSView {
    var onBack: (() -> Void)?
    var onEdit: ((QuickAction) -> Void)?
    var action: QuickAction? { didSet { fill() } }

    private let back = NSButton(title: L("‹ 快捷动作", "‹ Quick actions"), target: nil, action: nil)
    private let edit = NSButton(title: L("编辑", "Edit"), target: nil, action: nil)
    private let icon = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let kindPill = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let status = NSTextField(labelWithString: "")
    private let commandLabel = QuickActionDetail.section(L("跑什么", "Runs"))
    private let command = QuickActionDetail.codeField()
    private let commandBox = NSView()
    private let meta = NSTextField(wrappingLabelWithString: "")
    private let outputLabel = QuickActionDetail.section(L("输出", "Output"))
    private let output = QuickActionDetail.codeField()
    private let outputBox = NSView()
    private let runButton = QuickActionPillButton(primary: true)
    private let fullButton = QuickActionPillButton(primary: false)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for b in [back, edit] {
            b.isBordered = false
            b.font = Theme.rounded(10.5, .semibold)
            b.contentTintColor = .secondaryLabelColor
            b.target = self
        }
        back.action = #selector(backClicked)
        edit.action = #selector(editClicked)
        let top = NSStackView(views: [back, NSView(), edit])

        icon.font = .systemFont(ofSize: 24)
        name.font = Theme.rounded(13.5, .bold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindPill.font = Theme.rounded(10, .bold)
        let titles = NSStackView(views: [name, kindPill])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let ident = NSStackView(views: [icon, titles])
        ident.spacing = 9

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        status.font = Theme.rounded(11, .semibold)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [dot, status])
        statusRow.spacing = 6

        meta.font = Theme.font(10.5, .regular)
        meta.textColor = .tertiaryLabelColor

        runButton.target = self
        runButton.action = #selector(runClicked)
        fullButton.target = self
        fullButton.action = #selector(fullClicked)
        fullButton.set(title: L("完整输出", "Full output"), symbol: "doc.plaintext")
        let buttons = NSStackView(views: [runButton, fullButton, NSView()])
        buttons.spacing = 8

        for (box, field) in [(commandBox, command), (outputBox, output)] {
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.cornerCurve = .continuous
            box.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
                field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
                field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            ])
        }

        let stack = NSStackView(views: [top, ident, statusRow, commandLabel, commandBox, meta,
                                        outputLabel, outputBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(8, after: ident)
        stack.setCustomSpacing(10, after: statusRow)
        stack.setCustomSpacing(10, after: meta)
        stack.setCustomSpacing(10, after: outputBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for v in [top, commandBox, meta, outputBox, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func section(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.rounded(9.5, .heavy)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private static func codeField() -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        f.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        f.isSelectable = true
        f.maximumNumberOfLines = 8
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    private func fill() {
        guard let a = action else { return }
        icon.stringValue = a.icon ?? ""
        icon.isHidden = a.icon == nil
        name.stringValue = a.name
        kindPill.stringValue = a.kind.label
        kindPill.textColor = a.kind.tint
        command.stringValue = QuickActionRunner.commandPreview(a)
        var bits = [(a.cwd?.isEmpty == false) ? L("在 \(a.cwd!) 里", "in \(a.cwd!)")
                                              : L("在 SpectiX 自己的文件夹里", "in SpectiX's own folder"),
                    a.inTerminal == true ? L("开终端窗口跑", "opens a Terminal window")
                                         : L("后台跑，跑完通知你", "runs in background, notifies when done")]
        if a.confirm == true { bits.append(L("运行前先问你", "asks first")) }
        meta.stringValue = bits.joined(separator: " · ")
        refresh()
    }

    func refresh() {
        guard let a = action else { return }
        let runner = QuickActionRunner.shared
        let busy = runner.isRunning(a.key)
        let last = runner.results[a.key]
        let color: NSColor
        if let t = runner.elapsed(a.key) {
            color = Status.accent("working")
            status.stringValue = L("运行中 · \(QuickActionTile.clock(t))", "Running · \(QuickActionTile.clock(t))")
        } else if let opened = runner.openedInTerminal[a.key], a.inTerminal == true {
            color = .tertiaryLabelColor
            status.stringValue = L("\(Self.ago(opened))在终端窗口打开 · 过程看那个窗口",
                                   "Opened in Terminal \(Self.ago(opened)) · watch it there")
        } else if let r = last, r.stopped {
            color = .tertiaryLabelColor
            status.stringValue = L("上次被你停止 · \(Self.ago(r.finished))", "Stopped by you · \(Self.ago(r.finished))")
        } else if let r = last {
            color = Status.accent(r.ok ? "done" : "needs")
            let took = Int(r.duration.rounded())
            status.stringValue = r.ok
                ? L("上次成功 · \(Self.ago(r.finished)) · 用时 \(took) 秒", "Last run OK · \(Self.ago(r.finished)) · took \(took)s")
                : L("上次失败 · 退出码 \(r.exitCode) · \(Self.ago(r.finished))", "Last run failed · exit \(r.exitCode) · \(Self.ago(r.finished))")
        } else {
            color = .tertiaryLabelColor
            status.stringValue = L("还没跑过", "Never run")
        }
        dot.layer?.backgroundColor = color.cgColor
        status.textColor = busy ? color : .labelColor

        let text = busy ? runner.liveOutput(a) : (last?.output ?? "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(8)
        output.stringValue = text.isEmpty ? L("（还没有输出）", "(no output yet)") : lines.joined(separator: "\n")
        output.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
        outputLabel.stringValue = busy ? L("输出 · 实时", "Output · live") : L("输出", "Output")
        let showOutput = busy || last != nil
        outputLabel.isHidden = !showOutput
        outputBox.isHidden = !showOutput

        runButton.set(title: busy ? L("停止", "Stop") : L("运行", "Run"),
                      symbol: busy ? "stop.fill" : "play.fill")
        fullButton.isHidden = busy || last == nil
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return L("刚刚", "just now") }
        if s < 3600 { return L("\(s / 60) 分钟前", "\(s / 60)m ago") }
        if s < 86_400 { return L("\(s / 3600) 小时前", "\(s / 3600)h ago") }
        return L("\(s / 86_400) 天前", "\(s / 86_400)d ago")
    }

    @objc private func backClicked() { onBack?() }
    @objc private func editClicked() { if let a = action { onEdit?(a) } }
    @objc private func fullClicked() { if let a = action { QuickActionResultWindow.show(a.key) } }
    @objc private func runClicked() {
        guard let a = action else { return }
        let runner = QuickActionRunner.shared
        if runner.isRunning(a.key) { runner.stop(a.key) } else { runner.run(a) }
    }

    private func resolveColors() {
        for box in [commandBox, outputBox] { box.layer?.backgroundColor = Theme.cardFill.cg(in: self) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// Capsule button for the detail page; primary = filled with the running blue.
final class QuickActionPillButton: NSButton {
    private let primary: Bool
    private var hovering = false

    init(primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = primary ? 0 : 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, symbol: String) {
        let fg: NSColor = primary ? .white : .labelColor
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: Theme.rounded(11, .bold), .foregroundColor: fg])
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .bold))
        contentTintColor = fg
        resolveColors()
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 24, height: 26)
    }

    private func resolveColors() {
        if primary {
            layer?.backgroundColor = Status.accent("working").withAlphaComponent(hovering ? 1 : 0.88).cgColor
        } else {
            layer?.backgroundColor = (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
            layer?.borderColor = Theme.hairline.cg(in: self)
        }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; resolveColors() }
    override func mouseExited(with event: NSEvent)  { hovering = false; resolveColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resolveColors() }
}

// One tile (design/quick-actions.html round 2, layout B): click = detail page.
// State lives in exactly two places so nothing collides: the top-right tag (kind →
// clock → result) and a 3pt strip along the bottom edge. Hover slides a two-button
// bar over the name: ▶ Run (■ Stop while running) | Details. `action == nil` is "+".
final class QuickActionTile: NSView {
    var onOpen: ((QuickAction) -> Void)?
    /// nil = the "+" tile: add a new one.
    var onEdit: ((QuickAction?) -> Void)?

    private let action: QuickAction?
    private let icon = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let cornerTag = NSTextField(labelWithString: "")
    private let strip = CAGradientLayer()
    private let hoverBar = NSView()
    private let runButton = NSButton()
    private let detailButton = NSButton()
    private let barDivider = NSView()
    private var hovering = false
    static let height: CGFloat = 64
    private static let barHeight: CGFloat = 24

    init(action: QuickAction?) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        icon.stringValue = action == nil ? "＋" : action?.icon ?? ""
        icon.isHidden = action != nil && action?.icon == nil
        icon.font = .systemFont(ofSize: action == nil ? 17 : 20)
        icon.alignment = .center
        name.stringValue = action?.name ?? L("添加", "Add")
        name.font = Theme.rounded(10.5, .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = action.map { "\($0.name)\n\($0.body)" }
        cornerTag.font = Theme.roundedMono(8, .heavy)
        cornerTag.alignment = .right
        cornerTag.isHidden = action == nil

        let col = NSStackView(views: [icon, name])
        col.orientation = .vertical
        col.spacing = 5
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        cornerTag.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cornerTag)

        for (b, act) in [(runButton, #selector(runClicked)), (detailButton, #selector(detailClicked))] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.target = self
            b.action = act
            b.translatesAutoresizingMaskIntoConstraints = false
            hoverBar.addSubview(b)
        }
        detailButton.attributedTitle = NSAttributedString(string: L("详情", "Details"), attributes: [
            .font: Theme.rounded(10, .bold), .foregroundColor: NSColor.secondaryLabelColor])
        barDivider.wantsLayer = true
        barDivider.translatesAutoresizingMaskIntoConstraints = false
        hoverBar.addSubview(barDivider)
        hoverBar.wantsLayer = true
        hoverBar.isHidden = true
        hoverBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBar)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            col.centerXAnchor.constraint(equalTo: centerXAnchor),
            col.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            col.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            col.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            cornerTag.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            cornerTag.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            cornerTag.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            hoverBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            hoverBar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            runButton.leadingAnchor.constraint(equalTo: hoverBar.leadingAnchor),
            runButton.topAnchor.constraint(equalTo: hoverBar.topAnchor),
            runButton.bottomAnchor.constraint(equalTo: hoverBar.bottomAnchor),
            barDivider.leadingAnchor.constraint(equalTo: runButton.trailingAnchor),
            barDivider.widthAnchor.constraint(equalToConstant: 1),
            barDivider.topAnchor.constraint(equalTo: hoverBar.topAnchor, constant: 5),
            barDivider.bottomAnchor.constraint(equalTo: hoverBar.bottomAnchor, constant: -5),
            detailButton.leadingAnchor.constraint(equalTo: barDivider.trailingAnchor),
            detailButton.trailingAnchor.constraint(equalTo: hoverBar.trailingAnchor),
            detailButton.topAnchor.constraint(equalTo: hoverBar.topAnchor),
            detailButton.bottomAnchor.constraint(equalTo: hoverBar.bottomAnchor),
            runButton.widthAnchor.constraint(equalTo: detailButton.widthAnchor),
        ])

        strip.startPoint = CGPoint(x: 0, y: 0.5)
        strip.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(strip)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 3)
        CATransaction.commit()
    }

    private var busy: Bool { action.map { QuickActionRunner.shared.isRunning($0.key) } ?? false }

    func refresh() {
        let blue = Status.accent("working")
        let runner = QuickActionRunner.shared
        let last = action.flatMap { runner.results[$0.key] }
        let failed = !busy && last.map { !$0.ok && !$0.stopped } == true

        layer?.backgroundColor = busy ? blue.withAlphaComponent(0.10).cgColor
            : (hovering ? Theme.cardFillHover : Theme.cardFill).cg(in: self)
        layer?.borderColor = busy ? blue.withAlphaComponent(0.55).cgColor
            : failed ? Status.accent("needs").withAlphaComponent(0.6).cgColor
            : Theme.hairline.cg(in: self)
        name.textColor = action == nil ? .tertiaryLabelColor : .labelColor
        icon.textColor = action == nil ? .tertiaryLabelColor : .labelColor
        guard let action else { return }

        // Top-right tag: kind at rest, clock while running, last result after.
        if let t = runner.elapsed(action.key) {
            cornerTag.stringValue = Self.clock(t)
            cornerTag.textColor = blue
        } else if let r = last {
            cornerTag.stringValue = r.stopped ? L("已停止", "STOPPED")
                : r.ok ? "✓ " + QuickActionDetail.ago(r.finished) : L("✗ 失败", "✗ FAILED")
            cornerTag.textColor = r.stopped ? .tertiaryLabelColor : Status.accent(r.ok ? "done" : "needs")
        } else {
            cornerTag.stringValue = action.kind.tag
            cornerTag.textColor = action.kind.tint
        }

        // Bottom strip: flowing blue while running, then the result's color.
        strip.removeAllAnimations()
        if busy {
            let c = blue.cgColor, clear = blue.withAlphaComponent(0).cgColor
            strip.colors = [clear, c, clear]
            strip.isHidden = false
            // Model value parked off the left edge; phase anchored to Motion.epoch.
            strip.locations = [-0.5, -0.25, 0]
            let a = CABasicAnimation(keyPath: "locations")
            a.fromValue = [-0.5, -0.25, 0]
            a.toValue = [1, 1.25, 1.5]
            a.duration = 1.1
            a.repeatCount = .infinity
            a.beginTime = Motion.epoch
            strip.add(a, forKey: "flow")
        } else if let r = last {
            let c = (r.stopped ? NSColor.tertiaryLabelColor : Status.accent(r.ok ? "done" : "needs")).cgColor
            strip.colors = [c, c]
            strip.locations = [0, 1]
            strip.isHidden = false
        } else {
            strip.isHidden = true
        }

        // Hover bar sits over the name; it stays put while running so Stop is one move away.
        let showBar = hovering
        hoverBar.isHidden = !showBar
        name.alphaValue = showBar ? 0 : 1
        hoverBar.layer?.backgroundColor = Theme.cardFill.cg(in: self)
        barDivider.layer?.backgroundColor = Theme.hairline.cg(in: self)
        let symbol = busy ? "stop.fill" : "play.fill"
        let title = busy ? L(" 停止", " Stop") : L(" 运行", " Run")
        runButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold))
        runButton.imagePosition = .imageLeading
        runButton.imageHugsTitle = true
        runButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.rounded(10, .bold), .foregroundColor: blue])
        runButton.contentTintColor = blue
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func runClicked() {
        guard let action else { return }
        let runner = QuickActionRunner.shared
        if runner.isRunning(action.key) { runner.stop(action.key) } else { runner.run(action) }
    }

    @objc private func detailClicked() {
        if let action { onOpen?(action) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent)  { hovering = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    // Claim the press so the matching mouseUp comes back to this view.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        guard let action else { onEdit?(nil); return }
        onOpen?(action)
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
        m.addItem(item(L("编辑…", "Edit…")) { [weak self] in self?.onEdit?(action) })
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

// MARK: - Add / edit page

private struct SkillRow {
    let name: String
    let item: CatalogItem?   // nil = the skill actions.json names but isn't installed
    var parent: String? = nil
    var key: String { parent.map { $0 + "/" + name } ?? name }
}

// The drawer's add / edit page: same fields the old editor window had, laid out in
// one column so it fits the drawer's width.
final class QuickActionForm: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Saved → the saved action; cancelled → the action it was editing (nil = was adding);
    /// deleted → nil.
    var onClose: ((QuickAction?) -> Void)?

    override var isFlipped: Bool { true }   // top-aligned inside the drawer's scroll view

    private var original: QuickAction?
    private let back = NSButton(title: L("‹ 快捷动作", "‹ Quick actions"), target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "")
    private let emoji = NSButton()
    private var pickedEmoji: String?
    let name = NSTextField()
    private let kind = NSSegmentedControl(labels: [L("脚本", "Script"), "Skill", L("一句话", "Prompt")],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let kindNote = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = QuickActionForm.section("")
    private let body = NSTextView()
    private let bodyScroll = NSScrollView()
    private let cwd = NSTextField()
    private let cwdNote = NSTextField(wrappingLabelWithString: "")
    private let whereSeg = NSSegmentedControl(labels: [L("后台跑，跑完通知我", "Background, notify me"),
                                                       L("开个终端窗口跑", "In a Terminal window")],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let whereNote = NSTextField(wrappingLabelWithString: "")
    private let confirm = NSButton(checkboxWithTitle: L("运行前先问我一句", "Ask before running"), target: nil, action: nil)
    private let aiNote = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = NSButton(title: L("删除", "Delete"), target: nil, action: nil)
    private var pastedID: String?

    private let skillSearch = NSSearchField()
    private let skillTable = NSTableView()
    private let skillScroll = NSScrollView()
    private let skillArgs = NSTextField()
    private let skillNote = NSTextField(wrappingLabelWithString: "")
    private var skills: [CatalogItem] = []
    /// Skills filed inside an entry skill (notes/daily-report), keyed by the entry's name.
    /// Claude only lists the entry, so they run as "/notes daily-report".
    private var subSkills: [String: [CatalogItem]] = [:]
    private var skillsLoaded = false
    private var shownSkills: [SkillRow] = []
    private var selectedSkill: String?
    private var selectedSub: String?
    /// The skill typed into an older actions.json that isn't installed (kept selectable).
    private var unknownSkill: String?
    /// Last folder filled in for a project skill, so picking another one may replace it.
    private var autoCwd: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        loadSkills()
    }
    required init?(coder: NSCoder) { fatalError() }

    func load(_ action: QuickAction?) {
        original = action
        pastedID = nil
        heading.stringValue = action == nil ? L("添加快捷动作", "Add quick action") : L("编辑快捷动作", "Edit quick action")
        deleteButton.isHidden = action == nil
        aiNote.isHidden = true
        skillSearch.stringValue = ""
        fill(action)
    }

    private static func section(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.rounded(9.5, .heavy)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private static func column(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func build() {
        for b in [back] {
            b.isBordered = false
            b.font = Theme.rounded(10.5, .semibold)
            b.contentTintColor = .secondaryLabelColor
            b.target = self
        }
        back.action = #selector(cancel)
        heading.font = Theme.rounded(11.5, .bold)
        let top = NSStackView(views: [back, NSView(), heading])

        emoji.bezelStyle = .rounded
        emoji.target = self
        emoji.action = #selector(pickEmoji)
        emoji.setContentHuggingPriority(.required, for: .horizontal)
        emoji.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        name.placeholderString = L("比如：清理 G915 配对", "e.g. Unpair G915")
        let nameRow = NSStackView(views: [emoji, name])

        kind.target = self
        kind.action = #selector(kindChanged)
        for n in [kindNote, whereNote, skillNote, cwdNote] {
            n.font = Theme.font(10.5, .regular)
            n.textColor = .tertiaryLabelColor
            n.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        body.isRichText = false
        body.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.textContainerInset = NSSize(width: 4, height: 6)
        body.autoresizingMask = [.width]
        bodyScroll.documentView = body
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true

        skillSearch.placeholderString = L("搜索 skill", "Search skills")
        skillSearch.delegate = self
        let col = NSTableColumn(identifier: .init("skill"))
        skillTable.addTableColumn(col)
        skillTable.headerView = nil
        skillTable.rowHeight = 36
        skillTable.intercellSpacing = NSSize(width: 0, height: 2)
        skillTable.style = .plain
        skillTable.backgroundColor = .clear
        skillTable.dataSource = self
        skillTable.delegate = self
        skillTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        col.resizingMask = .autoresizingMask
        skillScroll.documentView = skillTable
        skillScroll.hasVerticalScroller = true
        skillScroll.borderType = .bezelBorder
        skillScroll.drawsBackground = false
        skillScroll.heightAnchor.constraint(equalToConstant: 5 * 38).isActive = true
        skillArgs.placeholderString = L("跟在后面的话（可选）：today · 存到 ~/Notes · work",
                                        "Text after it (optional): today · save to ~/Notes · work")

        cwd.placeholderString = L("不填 = SpectiX 自己的文件夹", "Empty = SpectiX's own folder")
        cwd.delegate = self
        cwd.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pick = NSButton(title: L("选择…", "Choose…"), target: self, action: #selector(pickFolder))
        let open = NSButton(title: L("打开", "Open"), target: self, action: #selector(openFolder))
        for b in [pick, open] { b.bezelStyle = .rounded; b.setContentHuggingPriority(.required, for: .horizontal) }
        let cwdRow = NSStackView(views: [cwd, pick, open])

        whereSeg.target = self
        whereSeg.action = #selector(whereChanged)

        deleteButton.target = self
        deleteButton.action = #selector(deleteAction)
        let test = NSButton(title: L("▶ 试跑一次", "▶ Test run"), target: self, action: #selector(testRun))
        let cancel = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(cancel))
        let save = NSButton(title: L("保存", "Save"), target: self, action: #selector(saveAction))
        save.bezelColor = .controlAccentColor
        for b in [deleteButton, test, cancel, save] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [deleteButton, test, NSView(), cancel, save])

        let stack = Self.column([
            top, aiBox(),
            Self.column([Self.section(L("名字", "Name")), nameRow]),
            Self.column([Self.section(L("类型", "Type")), kind, kindNote]),
            Self.column([bodyLabel, bodyScroll, skillSearch, skillScroll, skillArgs, skillNote]),
            Self.column([Self.section(L("在哪跑", "Folder")), cwdRow, cwdNote]),
            Self.column([Self.section(L("怎么跑", "Run")), whereSeg, whereNote]),
            confirm, buttons,
        ], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Every row and every field inside a section spans the full width.
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            guard let section = v as? NSStackView, section.orientation == .vertical else { continue }
            for inner in section.arrangedSubviews where !(inner is NSSegmentedControl) {
                inner.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            }
        }
    }

    // "Let AI build it": copy a ready prompt for any file-editing agent, or paste
    // back the JSON a chat-only AI replied with.
    private func aiBox() -> NSView {
        let title = NSTextField(labelWithString: L("让 AI 帮你建", "Let AI build it"))
        title.font = Theme.font(12, .semibold)
        let how = NSTextField(wrappingLabelWithString: L(
            "最省事：回抽屉首页点「连接 AI」那一行，连上以后直接在 AI 里说要什么按钮。没法连的 AI：点「复制给 AI」贴给它，在最后写上你要的按钮；只能聊天的 AI 会回一段 JSON，复制后点「粘贴 JSON」。",
            "Easiest: connect your AI from the “Connect AI” row on the drawer's first page, then just ask it for a button. Otherwise click Copy for AI, paste it and add what you want at the end; a chat-only AI replies with JSON: copy that and click Paste JSON."))
        how.font = Theme.font(10.5, .regular)
        how.textColor = .secondaryLabelColor
        how.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        aiNote.font = Theme.font(10.5, .medium)
        aiNote.textColor = .secondaryLabelColor
        aiNote.isHidden = true
        let copy = NSButton(title: L("复制给 AI", "Copy for AI"), target: self, action: #selector(copyPrompt))
        let paste = NSButton(title: L("粘贴 JSON", "Paste JSON"), target: self, action: #selector(pasteJSON))
        for b in [copy, paste] { b.bezelStyle = .rounded }
        let row = NSStackView(views: [copy, paste, aiNote])
        let col = Self.column([title, how, row], spacing: 6)
        col.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        how.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -24).isActive = true

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        col.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: box.topAnchor),
            col.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(QuickActionStore.aiPrompt, forType: .string)
        aiNote.stringValue = L("已复制 ✓", "Copied ✓")
        aiNote.isHidden = false
    }

    @objc private func pasteJSON() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let a = QuickActionStore.parse(text) else {
            NSSound.beep()
            aiNote.stringValue = L("剪贴板里没有能用的 JSON", "No usable JSON on the clipboard")
            aiNote.isHidden = false
            return
        }
        pastedID = a.id
        fill(a)
        aiNote.stringValue = L("已填好，检查后点保存", "Filled in: check it, then Save")
        aiNote.isHidden = false
    }

    // MARK: Skill picker

    private func loadSkills() {
        if Demo.enabled { setSkills(Demo.catalog()); return }
        rebuildSkillList()   // "loading…" until the catalog arrives
        SkillCatalog.load(projectRoots: ProjectHistory.all().map { $0.path }) { [weak self] in self?.setSkills($0) }
    }

    private func setSkills(_ all: [CatalogItem]) {
        skills = all.filter { $0.tool == .claude && $0.kind == .skill }
        subSkills = [:]
        for s in skills {
            let subs = Self.subSkills(of: s)
            if !subs.isEmpty { subSkills[s.name] = subs }
        }
        skillsLoaded = true
        rebuildSkillList()
    }

    /// <entry>/<sub>/SKILL.md next to the entry's own SKILL.md, one level down.
    private static func subSkills(of entry: CatalogItem) -> [CatalogItem] {
        guard let path = entry.path else { return [] }
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().compactMap { sub in
            let p = dir + "/" + sub + "/SKILL.md"
            guard fm.fileExists(atPath: p) else { return nil }
            let front = SkillCatalog.frontmatter(p)
            let n = front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? sub
            return CatalogItem(tool: .claude, kind: .skill, name: n, description: front["description"] ?? "",
                               path: p, origin: entry.origin, model: nil, uses: 0, lastUsed: nil)
        }
    }

    private var selectedKey: String? { selectedSkill.map { p in selectedSub.map { p + "/" + $0 } ?? p } }

    private func selectedItem() -> CatalogItem? {
        guard let p = selectedSkill else { return nil }
        guard let sub = selectedSub else { return skills.first { $0.name == p } }
        return subSkills[p]?.first { $0.name == sub }
    }

    /// "/notes daily-report today" loads as notes → daily-report with "today" left over.
    private func claimSubFromArgs() {
        guard selectedSub == nil, let p = selectedSkill, let subs = subSkills[p] else { return }
        let words = skillArgs.stringValue.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = words.first, subs.contains(where: { $0.name == first }) else { return }
        selectedSub = first
        skillArgs.stringValue = words.count > 1 ? words[1] : ""
    }

    private static func skillName(_ body: String) -> String {
        var n = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasPrefix("/") { n.removeFirst() }
        return String(n.prefix { !$0.isWhitespace })
    }

    private static func skillArgs(_ body: String) -> String {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = b.firstIndex(where: \.isWhitespace) else { return "" }
        return b[gap...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func origin(_ o: CatalogOrigin) -> String {
        switch o {
        case .plugin(let p):  return L("插件 · \(p)", "Plugin · \(p)")
        case .project(let p): return L("项目 · \(p)", "Project · \(p)")
        case .builtin:        return L("内置", "Built-in")
        case .system:         return L("系统", "System")
        case .user:           return L("全局", "Global")
        }
    }

    /// Folder a project skill lives under (…/<root>/.claude/skills/<name>/SKILL.md).
    private static func projectRoot(_ item: CatalogItem) -> String? {
        guard case .project = item.origin, let path = item.path,
              let r = path.range(of: "/.claude/skills/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).abbreviatingWithTildeInPath
    }

    private func rebuildSkillList() {
        if skillsLoaded { claimSubFromArgs() }
        let installed = Set(skills.map(\.name))
        let current = selectedSkill ?? ""
        unknownSkill = (!current.isEmpty && !installed.contains(current) && skillsLoaded) ? current : nil
        let q = skillSearch.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [SkillRow] = unknownSkill.map { [SkillRow(name: $0, item: nil)] } ?? []
        for s in skills {
            rows.append(SkillRow(name: s.name, item: s))
            rows += (subSkills[s.name] ?? []).map { SkillRow(name: $0.name, item: $0, parent: s.name) }
        }
        if !q.isEmpty {
            rows = rows.filter { $0.name.lowercased().contains(q) || ($0.item?.description.lowercased().contains(q) ?? false) }
        }
        shownSkills = rows
        skillTable.reloadData()
        if let i = rows.firstIndex(where: { $0.key == selectedKey }) {
            skillTable.selectRowIndexes([i], byExtendingSelection: false)
            skillTable.scrollRowToVisible(i)
        } else {
            skillTable.deselectAll(nil)
        }
        updateSkillNote()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownSkills.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("skillCell")
        let label = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = NSTextField(wrappingLabelWithString: "")
            f.identifier = id
            f.maximumNumberOfLines = 2
            f.lineBreakMode = .byTruncatingTail
            f.cell?.truncatesLastVisibleLine = true
            return f
        }()
        let r = shownSkills[row]
        let item = r.item
        let title = NSMutableAttributedString(string: r.parent == nil ? r.name : "   " + r.name,
                                              attributes: [.font: Theme.font(12, .semibold), .foregroundColor: NSColor.labelColor])
        var meta = "   "
        if let p = r.parent {
            meta += L("在 \(p) 里", "in \(p)")
        } else if let item {
            meta += Self.origin(item.origin)
            if item.uses > 0 { meta += L(" · 用过 \(item.uses) 次", " · used \(item.uses)×") }
        } else {
            meta += L("没找到这个 skill", "not installed")
        }
        title.append(NSAttributedString(string: meta, attributes: [
            .font: Theme.font(10.5, .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        if let d = item?.description, !d.isEmpty {
            title.append(NSAttributedString(string: "\n" + d, attributes: [
                .font: Theme.font(10.5, .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        label.attributedStringValue = title
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = skillTable.selectedRow
        guard row >= 0, row < shownSkills.count, shownSkills[row].key != selectedKey else { return }
        skillChanged(shownSkills[row])
    }

    private func skillChanged(_ r: SkillRow) {
        selectedSkill = r.parent ?? r.name
        selectedSub = r.parent == nil ? nil : r.name
        if let item = r.item {
            let c = cwd.stringValue.trimmingCharacters(in: .whitespaces)
            if let root = Self.projectRoot(item), c.isEmpty || c == autoCwd {
                cwd.stringValue = root
                autoCwd = root
                updateCwdNote()
            } else if Self.projectRoot(item) == nil, c == autoCwd {
                cwd.stringValue = ""
                autoCwd = nil
                updateCwdNote()
            }
            if name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { name.stringValue = item.name }
        }
        updateSkillNote()
    }

    private func updateSkillNote() {
        if !skillsLoaded {
            skillNote.stringValue = L("正在读取已装的 skill…", "Reading installed skills…")
        } else if shownSkills.isEmpty {
            skillNote.stringValue = L("没有名字或说明里带「\(skillSearch.stringValue)」的 skill。",
                                      "No skill matches “\(skillSearch.stringValue)”.")
        } else if let n = selectedSkill, n == unknownSkill {
            skillNote.stringValue = L("这台电脑上没装这个 skill，跑的时候 Claude 会找不到它。",
                                      "This skill isn't installed here; Claude won't find it.")
        } else if let n = selectedSkill, let item = selectedItem() {
            var t = selectedSub.map { L("已选 \($0)（在 \(n) 里，存成 /\(n) \($0)）", "Selected: \($0) (inside \(n), saved as /\(n) \($0))") }
                ?? L("已选 \(n)", "Selected: \(n)")
            if let root = Self.projectRoot(item) {
                t += L("。项目 skill，只在 \(root) 里找得到，所以下面的目录填成了它。",
                       ". Project skill: only found inside \(root), so the folder below is set to it.")
            }
            skillNote.stringValue = t
        } else {
            skillNote.stringValue = L("列表来自「技能」tab，按用过的次数排。", "From the Skills tab, most used first.")
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === cwd { updateCwdNote() }
        if (obj.object as? NSTextField) === skillSearch { rebuildSkillList() }
    }

    // ↑/↓ in the search box walk the list; ⏎ picks the highlighted row.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === skillSearch, !shownSkills.isEmpty else { return false }
        let row = skillTable.selectedRow
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(row < 0 ? 0 : min(row + 1, shownSkills.count - 1))
        case #selector(NSResponder.moveUp(_:)):   select(max(row - 1, 0))
        case #selector(NSResponder.insertNewline(_:)): select(row < 0 ? 0 : row)
        default: return false
        }
        return true
    }

    private func select(_ row: Int) {
        skillTable.selectRowIndexes([row], byExtendingSelection: false)
        skillTable.scrollRowToVisible(row)
    }

    private func updateCwdNote() {
        let c = cwd.stringValue.trimmingCharacters(in: .whitespaces)
        cwdNote.textColor = .tertiaryLabelColor
        if c.isEmpty {
            cwdNote.stringValue = L("在 SpectiX 自己的文件夹里跑，脚本和 Claude 生成的文件都留在这里（\((QuickActionRunner.workspace as NSString).abbreviatingWithTildeInPath)）。要处理某个项目，就选那个项目的文件夹。",
                                    "Runs in SpectiX's own folder; anything the script or Claude writes stays there (\((QuickActionRunner.workspace as NSString).abbreviatingWithTildeInPath)). To work on a project, choose its folder.")
        } else if QuickActionRunner.isHome(c) {
            cwdNote.textColor = .systemOrange
            cwdNote.stringValue = L("不建议用主目录：Claude 一启动会扫一遍这个文件夹，里面有桌面、文稿、下载，macOS 会一个个弹权限。",
                                    "Avoid your home folder: Claude scans its folder on launch, and home holds Desktop, Documents and Downloads, so macOS asks for each one.")
        } else {
            cwdNote.stringValue = L("命令从这个文件夹开始跑；Skill 会读这里的 CLAUDE.md 和项目 skill。",
                                    "The command starts in this folder; a skill reads its CLAUDE.md and project skills.")
        }
    }

    @objc private func openFolder() {
        let c = cwd.stringValue.trimmingCharacters(in: .whitespaces)
        let path = c.isEmpty ? QuickActionRunner.workspace : (c as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func fill(_ a: QuickAction?) {
        setEmoji(a?.icon)
        name.stringValue = a?.name ?? ""
        kind.selectedSegment = QuickAction.Kind.allCases.firstIndex(of: a?.kind ?? .script) ?? 0
        let isSkill = a?.kind == .skill
        body.string = isSkill ? "" : a?.body ?? ""
        selectedSkill = isSkill ? Self.skillName(a?.body ?? "") : nil
        selectedSub = nil
        if selectedSkill?.isEmpty == true { selectedSkill = nil }
        skillArgs.stringValue = isSkill ? Self.skillArgs(a?.body ?? "") : ""
        cwd.stringValue = a?.cwd ?? ""
        whereSeg.selectedSegment = a?.inTerminal == true ? 1 : 0
        confirm.state = a?.confirm == true ? .on : .off
        autoCwd = nil
        updateCwdNote()
        kindChanged()
        whereChanged()
        rebuildSkillList()
    }

    private var selectedKind: QuickAction.Kind { QuickAction.Kind.allCases[max(kind.selectedSegment, 0)] }

    @objc private func kindChanged() {
        let isSkill = selectedKind == .skill
        bodyScroll.isHidden = isSkill
        for v in [skillSearch, skillScroll, skillArgs, skillNote] as [NSView] { v.isHidden = !isSkill }
        switch selectedKind {
        case .script:
            bodyLabel.stringValue = L("命令", "Command")
            kindNote.stringValue = L("用 zsh 跑，和你在终端里敲一样。不经过 Claude，不花 token。",
                                     "Runs in zsh, same as typing it in Terminal. No Claude, no tokens.")
        case .skill:
            bodyLabel.stringValue = "Skill"
            kindNote.stringValue = L("从你装好的 skill 里选一个，下面那格写跟在后面的话。等于在下面的目录里跑 claude -p \"/名字 那句话\"。",
                                     "Pick one of your installed skills; the box below is what follows it. Same as claude -p \"/name text\" in the folder below.")
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

    private func setEmoji(_ e: String?) {
        pickedEmoji = e
        emoji.title = e ?? L("图标", "Icon")
        emoji.font = e == nil ? Theme.font(11, .regular) : .systemFont(ofSize: 15)
    }

    @objc private func pickEmoji() {
        guard let w = window else { return }
        let rect = w.convertToScreen(emoji.convert(emoji.bounds, to: nil))
        EmojiIconPicker.present(anchorScreenRect: rect,
                                onPick: { [weak self] in self?.setEmoji($0) },
                                onUpload: nil,
                                onRemove: { [weak self] in self?.setEmoji(nil) },
                                removeTitle: L("不要图标", "No icon"))
    }

    @objc private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            self?.cwd.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self?.updateCwdNote()
        }
    }

    private func draft() -> QuickAction? {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let args = skillArgs.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = selectedKind == .skill ? selectedSkill.map { "/" + $0 + (selectedSub.map { " " + $0 } ?? "") + (args.isEmpty ? "" : " " + args) } ?? ""
                                       : body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !b.isEmpty else {
            NSSound.beep()
            if n.isEmpty { window?.makeFirstResponder(name) }
            else if selectedKind == .skill { window?.makeFirstResponder(skillSearch) }
            else { window?.makeFirstResponder(body) }
            return nil
        }
        let e = pickedEmoji ?? ""
        let c = cwd.stringValue.trimmingCharacters(in: .whitespaces)
        var id = original?.id ?? pastedID ?? String(UUID().uuidString.prefix(8).lowercased())
        // A pasted id that is already taken would silently replace that button.
        if original == nil, QuickActionStore.shared.actions.contains(where: { $0.key == id }) {
            id += "-" + UUID().uuidString.prefix(4).lowercased()
        }
        return QuickAction(id: id,
                           emoji: e.isEmpty ? nil : e, name: n, kind: selectedKind, body: b,
                           cwd: c.isEmpty ? nil : c,
                           inTerminal: whereSeg.selectedSegment == 1 ? true : nil,
                           confirm: confirm.state == .on ? true : nil)
    }

    @objc private func saveAction() {
        guard let a = draft() else { return }
        QuickActionStore.shared.upsert(a, replacing: original?.key)
        onClose?(a)
    }

    @objc private func testRun() {
        guard let a = draft() else { return }
        QuickActionRunner.shared.run(a)
    }

    @objc private func deleteAction() {
        if let k = original?.key { QuickActionStore.shared.remove(k) }
        onClose?(nil)
    }

    @objc private func cancel() { onClose?(original) }
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
        w.title = [r.action.icon, r.action.name].compactMap { $0 }.joined(separator: " ")
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
