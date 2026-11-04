import Cocoa

// MARK: - Quick actions over MCP
//
// `SpectiX --mcp` turns this same binary into a tiny MCP server on stdin/stdout, so an
// AI client the user connected (Claude Code, Codex, Cursor) can list / add / change /
// delete quick actions by calling tools instead of editing actions.json by hand. No
// socket: the client spawns us and talks over pipes. Each client session starts its
// own short-lived process, so "connected" in the drawer means "registered, and last
// seen at…" (mcp-seen.json). See docs/quick-actions.md.

enum QuickActionsMCP {
    static let flag = "--mcp"
    /// Never the demo file: an AI adding a button means a real one.
    static let actionsPath = NSHomeDirectory() + "/.claude/spectix/actions.json"
    /// {"<clientInfo.name>": "<ISO 8601 time of its last initialize>"}
    static let seenPath = NSHomeDirectory() + "/.claude/spectix/mcp-seen.json"

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reply(id: NSNull(), error: (-32700, "Parse error"))
                continue
            }
            // A message without an id is a notification: never answered.
            guard let id = msg["id"] else { continue }
            let params = msg["params"] as? [String: Any] ?? [:]
            switch msg["method"] as? String {
            case "initialize":
                if let client = (params["clientInfo"] as? [String: Any])?["name"] as? String { markSeen(client) }
                reply(id: id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "spectix", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                    "instructions": "Buttons in the SpectiX menu-bar app's quick-actions drawer (the wrench). Each runs a shell script, a Claude Code skill, or a prompt for Claude when the user clicks it.",
                ])
            case "ping":
                reply(id: id, result: [:])
            case "tools/list":
                reply(id: id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, failed) = call(name, args)
                reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": failed])
            default:
                reply(id: id, error: (-32601, "Method not found"))
            }
        }
        exit(0)
    }

    // MARK: Tools

    private static let fieldProps: [String: Any] = [
        "name": ["type": "string", "description": "Button label, as short as possible"],
        "kind": ["type": "string", "enum": ["script", "skill", "prompt"],
                 "description": "script = a zsh command, no AI; skill = Claude Code runs a skill; prompt = Claude follows one sentence (claude -p)"],
        "body": ["type": "string",
                 "description": "script: the command. skill: the skill name, optionally followed by text (\"morning today\"); a skill filed inside an entry skill is \"<entry> <sub>\" (\"notes daily-report\"). prompt: the sentence"],
        "emoji": ["type": "string", "description": "Optional: one emoji for the tile"],
        "cwd": ["type": "string",
                "description": "Optional folder to run in. Leave out to run in SpectiX's own folder (recommended); use a project path to work on that project. Never ~ (Claude starting in the home folder triggers macOS permission prompts)"],
        "inTerminal": ["type": "boolean", "description": "Optional: true = open a Terminal window (when the user must interact); default runs in the background and notifies"],
        "confirm": ["type": "boolean", "description": "Optional: true = ask the user before each run (use for anything destructive)"],
    ]

    private static var tools: [[String: Any]] {
        var withID = fieldProps
        withID["id"] = ["type": "string", "description": "The action's id, from list_quick_actions"]
        return [
            ["name": "list_quick_actions",
             "description": "List the user's SpectiX quick actions (the buttons in the wrench drawer) as JSON.",
             "inputSchema": ["type": "object", "properties": [String: Any]()]],
            ["name": "add_quick_action",
             "description": "Add a button to the SpectiX quick-actions drawer. It appears right away; nothing runs until the user clicks it.",
             "inputSchema": ["type": "object", "properties": fieldProps, "required": ["name", "kind", "body"]]],
            ["name": "update_quick_action",
             "description": "Change an existing quick action. Only the fields given are changed; pass an empty string to clear emoji or cwd.",
             "inputSchema": ["type": "object", "properties": withID, "required": ["id"]]],
            ["name": "delete_quick_action",
             "description": "Remove a quick action from the drawer.",
             "inputSchema": ["type": "object", "properties": ["id": withID["id"]!], "required": ["id"]]],
        ]
    }

    private static func call(_ tool: String, _ a: [String: Any]) -> (String, Bool) {
        let list: [QuickAction]
        do { list = try load() } catch { return ("Can't read \(actionsPath): \(error.localizedDescription)", true) }
        switch tool {
        case "list_quick_actions":
            return (json(list), false)

        case "add_quick_action":
            guard let name = nonEmpty(a["name"]), let body = nonEmpty(a["body"]),
                  let kind = (a["kind"] as? String).flatMap(QuickAction.Kind.init(rawValue:)) else {
                return ("name, kind (script | skill | prompt) and body are required.", true)
            }
            var id = slug(name)
            while list.contains(where: { $0.key == id }) { id += "-" + UUID().uuidString.prefix(4).lowercased() }
            var action = QuickAction(id: id, name: name, kind: kind, body: body)
            apply(a, to: &action)
            return save(list + [action], done: "Added “\(name)” (id \(id)). It is in the drawer now.")

        case "update_quick_action":
            guard let id = a["id"] as? String, let i = list.firstIndex(where: { $0.key == id }) else {
                return ("No quick action with id \(a["id"] ?? "") — call list_quick_actions for the ids.", true)
            }
            var action = list[i]
            if let n = nonEmpty(a["name"]) { action.name = n }
            if let b = nonEmpty(a["body"]) { action.body = b }
            if let k = a["kind"] as? String {
                guard let kind = QuickAction.Kind(rawValue: k) else { return ("kind must be script, skill or prompt.", true) }
                action.kind = kind
            }
            apply(a, to: &action)
            var next = list
            next[i] = action
            return save(next, done: "Updated “\(action.name)”.")

        case "delete_quick_action":
            guard let id = a["id"] as? String, let gone = list.first(where: { $0.key == id }) else {
                return ("No quick action with id \(a["id"] ?? "") — call list_quick_actions for the ids.", true)
            }
            return save(list.filter { $0.key != id }, done: "Deleted “\(gone.name)”.")

        default:
            return ("Unknown tool \(tool).", true)
        }
    }

    /// Optional fields; a skill body is stored the way the drawer writes it ("/name …").
    private static func apply(_ a: [String: Any], to action: inout QuickAction) {
        if let e = a["emoji"] as? String { action.emoji = e.isEmpty ? nil : e }
        if let c = a["cwd"] as? String { action.cwd = c.isEmpty ? nil : c }
        if let t = a["inTerminal"] as? Bool { action.inTerminal = t ? true : nil }
        if let c = a["confirm"] as? Bool { action.confirm = c ? true : nil }
        if action.kind == .skill, !action.body.hasPrefix("/") { action.body = "/" + action.body }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func slug(_ name: String) -> String {
        let ascii = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let s = String(ascii).split(separator: "-").joined(separator: "-")
        return s.isEmpty ? String(UUID().uuidString.prefix(8).lowercased()) : s
    }

    // MARK: Files

    private static func load() throws -> [QuickAction] {
        guard let data = FileManager.default.contents(atPath: actionsPath) else { return [] }
        return try JSONDecoder().decode([QuickAction].self, from: data)
    }

    private static func save(_ list: [QuickAction], done: String) -> (String, Bool) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: actionsPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(list).write(to: url, options: .atomic)
        } catch {
            return ("Can't write \(actionsPath): \(error.localizedDescription)", true)
        }
        return (done, false)
    }

    private static func json(_ list: [QuickAction]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? enc.encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func markSeen(_ client: String) {
        var seen = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: seenPath)))) as? [String: String] ?? [:]
        seen[client] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: seen, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: seenPath), options: .atomic)
        }
    }

    /// When each client last connected, keyed by the name it sent in initialize.
    static func lastSeen() -> [String: Date] {
        let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: seenPath)))) as? [String: String] ?? [:]
        let f = ISO8601DateFormatter()
        return raw.compactMapValues { f.date(from: $0) }
    }

    // MARK: JSON-RPC

    private static func reply(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func reply(id: Any, error: (Int, String)) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": error.0, "message": error.1]])
    }

    private static func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - Connecting AI clients
//
// What the drawer's "AI" row shows and does: for each client installed here, whether
// SpectiX is registered as its MCP server, when it last connected, and a one-click
// register / unregister. Claude Code goes through its own CLI (it rewrites
// ~/.claude.json all the time, so hand edits can be lost); Codex and Cursor are plain
// config files. Everything runs out of process or touches files: the app opens no socket.

enum MCPClient: String, CaseIterable {
    case claude, codex, cursor

    static let serverName = "spectix"

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }

    private static let home = NSHomeDirectory()
    private var configPath: String {
        switch self {
        case .claude: return Self.home + "/.claude.json"
        case .codex:  return Self.home + "/.codex/config.toml"
        case .cursor: return Self.home + "/.cursor/mcp.json"
        }
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        switch self {
        case .claude: return fm.fileExists(atPath: Self.home + "/.claude")
        case .codex:  return fm.fileExists(atPath: Self.home + "/.codex")
        case .cursor: return fm.fileExists(atPath: Self.home + "/.cursor") || fm.fileExists(atPath: "/Applications/Cursor.app")
        }
    }

    /// Reads the client's config; ~/.claude.json runs to hundreds of KB, so call it off the main thread.
    var isRegistered: Bool {
        switch self {
        case .claude, .cursor:
            guard let d = FileManager.default.contents(atPath: configPath),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
            return (o["mcpServers"] as? [String: Any])?[Self.serverName] != nil
        case .codex:
            let toml = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            return toml.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == Self.codexHeader }
        }
    }

    /// The name each client puts in `initialize` isn't documented; match it loosely.
    var lastSeen: Date? {
        QuickActionsMCP.lastSeen().filter { $0.key.lowercased().contains(rawValue) }.values.max()
    }

    private static var codexHeader: String { "[mcp_servers.\(serverName)]" }
    private static var serverPath: String { Bundle.main.executablePath ?? "" }

    /// Registers (or with `on: false` unregisters) this binary; `done` gets an error message or nil.
    func connect(_ on: Bool, done: @escaping (String?) -> Void) {
        let path = Self.serverPath
        DispatchQueue.global(qos: .userInitiated).async {
            let err: String?
            switch self {
            case .claude:
                let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                var cmd = "claude mcp remove --scope user \(Self.serverName) >/dev/null 2>&1"
                if on { cmd += "; claude mcp add --scope user \(Self.serverName) -- \(q(path)) \(QuickActionsMCP.flag)" }
                err = Self.shell(cmd)
            case .codex:
                err = self.editCodex(on ? path : nil)
            case .cursor:
                err = self.editCursor(on ? path : nil)
            }
            DispatchQueue.main.async { done(err) }
        }
    }

    // GUI apps don't inherit the shell PATH; same prefix the quick-action runner uses.
    private static func shell(_ cmd: String) -> String? {
        try? FileManager.default.createDirectory(atPath: QuickActionRunner.workspace, withIntermediateDirectories: true)
        let log = NSTemporaryDirectory() + "spectix-mcp-connect.log"
        let script = """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd \(QuickActionRunner.workspace.replacingOccurrences(of: " ", with: "\\ ")) || exit 1
        \(cmd)
        """
        guard let pid = QuickActionRunner.spawn(["/bin/zsh", "-lc", script], output: log) else {
            return L("/bin/zsh 起不来", "Couldn't start /bin/zsh")
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status != 0 else { return nil }
        let out = (try? String(contentsOfFile: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? L("命令失败", "Command failed") : String(out.suffix(300))
    }

    /// Drops our table (header up to the next header) and, when `path` is given, appends a fresh one.
    private func editCodex(_ path: String?) -> String? {
        let old = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var skipping = false
        for line in old.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { skipping = t == Self.codexHeader || t.hasPrefix("[mcp_servers.\(Self.serverName).") }
            if !skipping { kept.append(line) }
        }
        var text = kept.joined(separator: "\n")
        if let path {
            while text.hasSuffix("\n\n") { text.removeLast() }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            let esc = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            text += (text.isEmpty ? "" : "\n") + "\(Self.codexHeader)\ncommand = \"\(esc)\"\nargs = [\"\(QuickActionsMCP.flag)\"]\n"
        }
        return write(text.data(using: .utf8)!)
    }

    private func editCursor(_ path: String?) -> String? {
        var root: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: configPath) {
            guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                return L("\(configPath) 不是合法的 JSON，没敢动它", "\(configPath) isn't valid JSON; left it alone")
            }
            root = o
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = path.map { ["type": "stdio", "command": $0, "args": [QuickActionsMCP.flag]] }
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return L("写不出 JSON", "Couldn't encode JSON")
        }
        return write(data)
    }

    private func write(_ data: Data) -> String? {
        let url = URL(fileURLWithPath: configPath)
        let fm = FileManager.default
        // An atomic write makes a new file; keep the old one's mode (config.toml is 0600).
        let mode = (try? fm.attributesOfItem(atPath: configPath))?[.posixPermissions]
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: configPath) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Connect page

// One line per installed AI: "● Claude Code  connected · used 3m ago  [Disconnect]",
// plus an error line when connecting fails.
final class MCPConnectRow: NSView {
    /// Any client registered — drives the dot on the drawer's "连接 AI" button.
    var onConnectedChange: ((Bool) -> Void)?
    private let chips = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var registered: [MCPClient: Bool] = [:]
    private var busy: MCPClient?
    private var lastError: String?
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chips.orientation = .vertical
        chips.alignment = .leading
        chips.spacing = 4
        hint.font = Theme.font(10.5, .regular)
        hint.textColor = .tertiaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let col = NSStackView(views: [chips, hint])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.widthAnchor.constraint(equalTo: col.widthAnchor),
            chips.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Re-read registrations now, and every few seconds while the drawer shows
    /// (a "last used" that only updates on reopen would look stuck).
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            QuickActionStore.shared.reloadIfChanged()   // a button the AI just added appears without reopening
            self.refresh()
        }
    }

    override func viewDidHide() { super.viewDidHide(); timer?.invalidate(); timer = nil }

    private var clients: [MCPClient] { MCPClient.allCases.filter(\.isInstalled) }

    private func refresh() {
        let list = clients
        DispatchQueue.global(qos: .utility).async {
            let r = Dictionary(uniqueKeysWithValues: list.map { ($0, $0.isRegistered) })
            DispatchQueue.main.async { [weak self] in
                self?.registered = r
                self?.render()   // also ticks "used 3m ago"
            }
        }
    }

    // One line per installed client: name, state, and a connect / disconnect button.
    private func render() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = clients
        isHidden = list.isEmpty
        for c in list {
            let on = registered[c] == true
            let name = NSMutableAttributedString(string: on ? "● " : "○ ", attributes: [
                .font: Theme.rounded(10, .bold),
                .foregroundColor: on ? Status.accent("done") : NSColor.tertiaryLabelColor])
            name.append(NSAttributedString(string: c.title, attributes: [
                .font: Theme.rounded(11, .semibold), .foregroundColor: NSColor.labelColor]))
            let nameLabel = NSTextField(labelWithAttributedString: name)
            let state = NSTextField(labelWithString: stateText(c, on: on))
            state.font = Theme.font(10.5, .regular)
            state.textColor = .tertiaryLabelColor
            state.lineBreakMode = .byTruncatingTail
            state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let b = NSButton(title: "", target: self, action: #selector(toggle(_:)))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(
                string: busy == c ? "…" : on ? L("断开", "Disconnect") : L("连接", "Connect"),
                attributes: [.font: Theme.rounded(10.5, .semibold),
                             .foregroundColor: busy != nil ? NSColor.tertiaryLabelColor
                                 : on ? NSColor.systemRed : NSColor.controlAccentColor])
            b.tag = MCPClient.allCases.firstIndex(of: c) ?? 0
            b.toolTip = on ? L("从 \(c.title) 的设置里去掉 SpectiX，随时可以再连", "Remove SpectiX from \(c.title)'s settings; you can reconnect any time")
                           : L("把 SpectiX 登记到 \(c.title)", "Register SpectiX with \(c.title)")
            let line = NSStackView(views: [nameLabel, state, NSView(), b])
            line.spacing = 6
            chips.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: chips.widthAnchor).isActive = true
        }
        renderHint()
        onConnectedChange?(list.contains { registered[$0] == true })
    }

    private func stateText(_ c: MCPClient, on: Bool) -> String {
        guard on else { return L("未连接", "not connected") }
        guard let t = c.lastSeen else { return L("已连接 · 新开一个会话后生效", "connected · start a new session") }
        return L("已连接 · \(QuickActionDetail.ago(t))用过", "connected · used \(QuickActionDetail.ago(t))")
    }

    private func renderHint() {
        hint.isHidden = lastError == nil
        hint.textColor = .systemOrange
        hint.stringValue = lastError ?? ""
    }

    @objc private func toggle(_ sender: NSButton) {
        guard busy == nil else { return }
        let c = MCPClient.allCases[sender.tag]
        set(c, on: registered[c] != true)
    }

    private func set(_ c: MCPClient, on: Bool) {
        busy = c
        lastError = nil
        render()
        c.connect(on) { [weak self] err in
            guard let self else { return }
            self.busy = nil
            self.lastError = err.map { L("\(c.title) 没连上：\($0)", "Couldn't connect \(c.title): \($0)") }
            self.registered[c] = err == nil ? on : self.registered[c]
            self.render()
        }
    }
}

// The drawer page behind the "连接 AI" button: the three connect buttons, then what
// to say, how it works and what the AI cannot do.
final class MCPConnectPage: NSView {
    var onBack: (() -> Void)?
    let row = MCPConnectRow()
    private let back = NSButton(title: L("‹ 快捷动作", "‹ Quick actions"), target: nil, action: nil)
    private let heading = NSTextField(labelWithString: L("连接 AI", "Connect AI"))

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        back.isBordered = false
        back.font = Theme.rounded(10.5, .semibold)
        back.contentTintColor = .secondaryLabelColor
        back.target = self
        back.action = #selector(backClicked)
        heading.font = Theme.rounded(13.5, .bold)

        let sections: [(String, String)] = [
            (L("怎么用", "How to use it"),
             L("在上面你用的那家点「连接」，再新开一个会话，直接说要什么按钮。不想用了就点「断开」，SpectiX 会从它的设置里删掉自己，你的按钮不受影响。",
               "Click Connect next to the one you use, start a new session, then just say what button you want. Changed your mind? Disconnect removes SpectiX from its settings; your buttons stay.")),
            (L("可以这样说", "Things to say"),
             L("「SpectiX 都有哪些按钮」\n「加个按钮，每天早上跑 /morning」\n「把『看磁盘』改名叫『磁盘』」\n「删掉看磁盘那个」",
               "“What buttons does SpectiX have?”\n“Add a button that runs /morning”\n“Rename ‘Disk’ to ‘Storage’”\n“Delete the Disk button”")),
            (L("怎么做到的", "How it works"),
             L("连接会在那家 AI 的设置里登记 SpectiX。之后 AI 每开一个会话，就在后台临时启动一份 SpectiX，让它改你的按钮清单。两边在这台电脑上直接传话，不联网。「N 分钟前用过」是 AI 上次叫它的时间。",
               "Connecting registers SpectiX in that AI's settings. Each new session, the AI starts a copy of SpectiX in the background and asks it to change your buttons. They talk on this Mac, with no network. “Used N ago” is when the AI last called it.")),
            (L("它不会做的", "What it won't do"),
             L("替你按按钮。运行还是要你自己点，「运行前先问我一句」不会被绕过。",
               "Press a button for you. Running stays a click of yours, so “Ask before running” cannot be bypassed.")),
            (L("连不上的 AI", "AIs that can't connect"),
             L("点「＋」添加按钮，在「让 AI 帮你建」里点「复制给 AI」，把那段话贴给它。",
               "Click “＋”, then Copy for AI under “Let AI build it”, and paste that to the AI.")),
        ]
        var views: [NSView] = [NSStackView(views: [back, NSView()]), heading, row]
        var bodies: [NSView] = []
        for (title, text) in sections {
            let t = NSTextField(labelWithString: title)
            t.font = Theme.rounded(9.5, .heavy)
            t.textColor = .tertiaryLabelColor
            let b = NSTextField(wrappingLabelWithString: text)
            b.font = Theme.font(11, .regular)
            b.textColor = .secondaryLabelColor
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views += [t, b]
            bodies.append(b)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(6, after: views[0])
        stack.setCustomSpacing(8, after: heading)
        stack.setCustomSpacing(12, after: row)
        for b in bodies.dropLast() { stack.setCustomSpacing(10, after: b) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for v in [views[0], row] + bodies { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func backClicked() { onBack?() }
}
