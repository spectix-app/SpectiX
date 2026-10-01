import AppKit

// The companion extension's own account of itself: one terminals-<hostPid>.json per
// running extension host (= per editor window), rewritten every ~2s, listing the shell
// pids of that window's terminals. It is the only evidence that the extension is
// RUNNING somewhere, as opposed to sitting on disk (T226/T229 — the two diverge on
// every fresh install until the window is reloaded, and on every uninstall until the
// editor quits). FocusRing keeps its own richer reader (name→pid tables bound to
// windows); this one answers just "which hosts are alive and whom do they serve".
enum CompanionExtension {
    struct Manifest {
        let file: String
        let hostPid: pid_t
        let modified: Date
        let shellPids: [pid_t]
    }

    static let stateDir = "\(NSHomeDirectory())/.claude/spectix"

    /// How stale a window file may be and still count. The extension rewrites every ~2s;
    /// a minute leaves room for a wedged host or a machine coming back from sleep while
    /// still rejecting anything left by a process that died.
    private static let windowFileMaxAge: TimeInterval = 60

    /// Every manifest on disk, dead hosts included — the report wants to show those.
    static func manifests() -> [Manifest] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir)
        else { return [] }
        return files.compactMap { f -> Manifest? in
            guard f.hasPrefix("terminals-"), f.hasSuffix(".json"),
                  let host = pid_t(f.dropFirst("terminals-".count).dropLast(".json".count))
            else { return nil }
            let path = "\(stateDir)/\(f)"
            guard let data = FileManager.default.contents(atPath: path),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return nil }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let pids = arr.compactMap { e -> pid_t? in
                ((e["pid"] as? Int) ?? (e["pid"] as? NSNumber)?.intValue).map(pid_t.init)
            }
            return Manifest(file: f, hostPid: host, modified: mtime ?? .distantPast, shellPids: pids)
        }
    }

    /// Manifests whose host process still exists. A host that crashed (no deactivate)
    /// leaves its file behind; ESRCH is the one answer that says it is gone for sure.
    static func liveManifests() -> [Manifest] {
        manifests().filter { hostAlive($0.hostPid) }
    }

    struct WindowFolders {
        let hostPid: pid_t
        let folders: [String]
    }

    /// What each LIVE extension host says its own window has open. A window TITLE carries
    /// only the folder NAME, so two git worktrees of one repo look identical from outside
    /// and every name→path lookup has to guess between them; this is the window answering
    /// for itself instead (extension ≥ 0.0.8).
    ///
    /// ★ A SEPARATE file from terminals-<pid>.json on purpose. Four readers parse that one
    /// as a bare array (FocusRing ×2, StatusPip, manifests above), so folding an object
    /// into it would break the rings, the pips and this report at once — and would break
    /// them on any machine where an old window still runs the previous extension version.
    ///
    /// ★ Believed only while its host keeps rewriting it (every ~2s), NOT merely while
    /// some process holds that pid. A host that crashed without deactivate leaves its
    /// file behind and nothing ever cleans it up (this disk still has terminals files
    /// from August), so a pid-liveness test alone brings that file back to life the day
    /// its number is handed to another child of the same editor. The damage then is
    /// worse than the phantom group this file exists to prevent: a bogus report can make
    /// an editor's window count match, and a trusted editor skips the title fallback
    /// entirely — its real windows get no header at all.
    static func liveWindowFolders() -> [WindowFolders] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir)
        else { return [] }
        return files.compactMap { f -> WindowFolders? in
            guard f.hasPrefix("window-"), f.hasSuffix(".json"),
                  let host = pid_t(f.dropFirst("window-".count).dropLast(".json".count)),
                  hostAlive(host),
                  let mtime = (try? FileManager.default.attributesOfItem(
                      atPath: "\(stateDir)/\(f)"))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(mtime) < windowFileMaxAge,
                  let data = FileManager.default.contents(atPath: "\(stateDir)/\(f)"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Absolute paths only: a multi-root window can hold a virtual (untitled:,
            // vscode-remote:) root that names nothing on this disk.
            let folders = (obj["folders"] as? [String])?.filter { $0.hasPrefix("/") } ?? []
            return WindowFolders(hostPid: host, folders: folders)
        }
    }

    static func hostAlive(_ pid: pid_t) -> Bool {
        !(kill(pid, 0) != 0 && errno == ESRCH)
    }
}

// The "export diagnostics" file: everything a remote reader needs to tell apart the
// failures that all look like "the ring doesn't show" — permission dead, extension not
// on disk, on disk but not loaded, loaded but the pane never confirmed — plus the
// self-trimming logs those judgements are made from. One plain-text file so it can be
// pasted or attached without an archiver, chosen through a save panel so writing it
// needs no folder permission of its own.
//
// What it deliberately does NOT contain: any per-session state file (titles carry
// prompts), the account book, or hook script contents. The logs keep project names
// on purpose — see jumpDiag for why redacting them would defeat the file.
enum DiagnosticsReport {
    static func export(from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SpectiX-diagnostics-\(Self.stamp.string(from: Date())).txt"
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            let text = build()
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("没能写入诊断文件", "Couldn't write the diagnostics file")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    static func build() -> String {
        let home = NSHomeDirectory()
        var out: [String] = []
        func section(_ title: String) { out.append(""); out.append("== \(title) =="); }
        func line(_ s: String) { out.append(s.replacingOccurrences(of: home, with: "~")) }

        let os = ProcessInfo.processInfo.operatingSystemVersionString
        line("SpectiX \(AboutCard.version)\(Build.isDev ? " (dev)" : "") · \(os) · \(Self.wall.string(from: Date()))")

        section("Accessibility")
        line("AXIsProcessTrusted=\(AXIsProcessTrusted()) degraded=\(AppController.axDegraded)")

        section("Companion extension")
        for editor in EditorApp.allCases {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: editor.rawValue).isEmpty
            let names = (try? FileManager.default.contentsOfDirectory(atPath: editor.extDir)) ?? []
            let onDisk = names.filter { $0.hasPrefix("spectix.focus") || $0.hasPrefix("taskbeacon.focus") }
            let indexed = extensionsIndexLists(editor)
            line("\(editor.appSupportName): running=\(running) onDisk=\(onDisk.isEmpty ? "none" : onDisk.joined(separator: ","))"
                 + " indexed=\(indexed.map(String.init) ?? "no extensions.json")")
        }
        let manifests = CompanionExtension.manifests()
        if manifests.isEmpty { line("hosts: none (no terminals-*.json — no window has loaded the extension)") }
        for m in manifests.sorted(by: { $0.hostPid < $1.hostPid }) {
            let age = Int(Date().timeIntervalSince(m.modified))
            line("host \(m.hostPid): alive=\(CompanionExtension.hostAlive(m.hostPid)) age=\(age)s terminals=\(m.shellPids.map(String.init).joined(separator: ","))")
        }
        for f in ["active-terminal", "active-window", "focus-request"] {
            let path = "\(CompanionExtension.stateDir)/\(f)"
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let value = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(absent)"
            line("\(f): \(value)\(mtime.map { " @ \(Self.wall.string(from: $0))" } ?? "")")
        }

        section("Hooks")
        let settings = (try? String(contentsOfFile: "\(home)/.claude/settings.json", encoding: .utf8)) ?? ""
        line("~/.claude/settings.json mentions spectix ×\(settings.components(separatedBy: "spectix").count - 1)")
        for h in ["spectix-status.sh", "spectix-usage.py"] {
            line("~/.claude/hooks/\(h): \(FileManager.default.fileExists(atPath: "\(home)/.claude/hooks/\(h)") ? "present" : "missing")")
        }

        for log in ["jump-diag.log", "ring-diag.log", "pip-diag.log", "ax-probe.log", "desktop-probe.log", "popover-debug.log"] {
            section(log)
            let path = "\(CompanionExtension.stateDir)/\(log)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                line("(absent)"); continue
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > Self.tailLines { line("… \(lines.count - Self.tailLines) earlier lines omitted") }
            for l in lines.suffix(Self.tailLines) { line(String(l)) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Whether the editor's extensions.json — the index it actually loads from — names
    /// our extension. nil when there is no index to read. On disk without this entry is
    /// the T226 root cause: the folder is there and the editor will never look at it.
    private static func extensionsIndexLists(_ editor: EditorApp) -> Bool? {
        let path = "\(editor.extDir)/extensions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr.contains {
            (($0["identifier"] as? [String: Any])?["id"] as? String)?.lowercased() == "spectix.focus"
        }
    }

    private static let tailLines = 400
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f
    }()
    private static let wall: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
}
