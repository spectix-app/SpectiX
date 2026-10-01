import Cocoa

// MARK: - Install locations
//
// Every path the installer writes to resolves through `InstallPaths`. That
// indirection exists for exactly one reason: it lets the whole install/uninstall
// flow be exercised against a throwaway directory instead of the developer's own
// ~/.claude — which on this machine holds a large hand-tuned hook config that a
// stray test run must never touch.
//
// Set SPECTIX_INSTALL_ROOT=<dir> and both the home and Applications targets
// are re-rooted under it. Unset (every real user, always) → the true locations.
struct InstallPaths {
    let applications: URL
    let home: URL

    var claudeDir: URL { home.appendingPathComponent(".claude") }
    var hooksDir:  URL { claudeDir.appendingPathComponent("hooks") }
    var settings:  URL { claudeDir.appendingPathComponent("settings.json") }
    var stateDir:  URL { claudeDir.appendingPathComponent("spectix") }
    var installedApp: URL { applications.appendingPathComponent("SpectiX.app") }

    /// OpenAI Codex CLI. Its hook system is the same contract as Claude Code's — same
    /// event names, same JSON shape, and the very same spectix-status.sh runs under it
    /// unmodified — but it reads its own file and never looks at ~/.claude.
    ///
    /// Nothing here is created speculatively: `codexDir` existing is the only signal
    /// that Codex is installed, so a machine without it must come out of the install
    /// with no ~/.codex at all rather than an empty one that looks configured.
    var codexDir:    URL { home.appendingPathComponent(".codex") }
    var codexHooks:  URL { codexDir.appendingPathComponent("hooks") }
    var codexConfig: URL { codexDir.appendingPathComponent("hooks.json") }

    /// Everything the app was called before T172. A machine that installed the old
    /// build has all of this on disk under names nothing else here looks at any more,
    /// so it has to be named once and retired explicitly — left alone it does not sit
    /// inert, it keeps running: the old hook writes state the new app never reads, and
    /// two menu bar icons appear.
    var legacyStateDir: URL { claudeDir.appendingPathComponent("taskbeacon") }
    var legacyApp: URL { applications.appendingPathComponent("TaskBeacon.app") }

    /// True when re-rooted for testing — the UI surfaces this so a sandboxed run
    /// can never be mistaken for a real install.
    let isSandboxed: Bool

    static func resolve() -> InstallPaths {
        let fm = FileManager.default
        if let root = ProcessInfo.processInfo.environment["SPECTIX_INSTALL_ROOT"], !root.isEmpty {
            let base = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            let apps = base.appendingPathComponent("Applications")
            let home = base.appendingPathComponent("home")
            try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
            try? fm.createDirectory(at: home, withIntermediateDirectories: true)
            return InstallPaths(applications: apps, home: home, isSandboxed: true)
        }

        // /Applications is drwxrwxr-x root:admin — an admin account (the common
        // case) can write it without authorization. A standard account can't, so
        // fall back to ~/Applications rather than failing the install outright.
        let system = URL(fileURLWithPath: "/Applications")
        let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let target: URL
        if fm.isWritableFile(atPath: system.path) {
            target = system
        } else {
            try? fm.createDirectory(at: userApps, withIntermediateDirectories: true)
            target = userApps
        }
        return InstallPaths(applications: target,
                            home: fm.homeDirectoryForCurrentUser,
                            isSandboxed: false)
    }
}

// MARK: - Step reporting

enum InstallStep: CaseIterable {
    case app, hooks, extensions

    var title: String {
        switch self {
        case .app:        return "SpectiX App"
        case .hooks:      return L("状态 hook", "Status hook")
        case .extensions: return L("编辑器扩展", "Editor extension")
        }
    }
}

/// What the Codex half of the hook step managed to do.
///
/// Carried apart from `ok` because the two failure modes are not the same thing:
/// no Codex on this machine is the ordinary case and must not read as a problem,
/// and a Codex that is present but could not be wired must not paint an install
/// as failed when Claude Code came out of it correctly wired.
enum CodexOutcome { case absent, wired, failed }

struct StepResult {
    let step: InstallStep
    let ok: Bool
    /// One short line shown next to the step — where it landed, or why it didn't.
    let detail: String

    /// Only ever set by `.hooks`. The finish screen reads it to decide whether the
    /// user still has to approve the hook inside Codex — see `codexNote`.
    var codex: CodexOutcome = .absent

    /// The Codex half's own sentence, kept separate from `detail` so the UI can put
    /// it in front of the user on a *successful* install too. Nothing else in this
    /// window needs that: every other note is either implied by the tick or is a
    /// failure. This one is an action the user has to take by hand.
    var codexNote: String = ""

    /// A step that legitimately did nothing (no editor installed) — reported as a
    /// success so the run isn't painted as failed, but worth saying out loud.
    var skipped: Bool = false

    /// Editors the extension actually landed in, by display name. The finish screen
    /// names them in its "reload the window" prompt, so it must be the real list and
    /// not a guess — telling a Cursor-only user to open VS Code is worse than silence.
    /// Empty for every step but `.extensions`.
    var editors: [String] = []
}

// MARK: - Core

/// All filesystem work, with no AppKit UI coupling: the window drives this and
/// renders whatever `StepResult`s come back. Every method is idempotent —
/// re-running a finished install is a supported, ordinary action.
final class InstallerCore {

    let paths: InstallPaths
    private let fm = FileManager.default

    /// The app bundled inside this installer's Resources/. Everything payload-ish
    /// is read from here, including the hook scripts — those live inside
    /// SpectiX.app's own Resources (build.sh puts them there for the app's
    /// self-bootstrap path), so the installer reads that one copy instead of
    /// shipping a second one that could drift out of sync.
    private var payloadApp: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let app = res.appendingPathComponent("SpectiX.app")
        return fm.fileExists(atPath: app.path) ? app : nil
    }

    private var payloadHooks: URL? {
        payloadApp?.appendingPathComponent("Contents/Resources/hooks")
    }

    private var payloadExtension: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("vscode-extension")
        return fm.fileExists(atPath: dir.path) ? dir : nil
    }

    init(paths: InstallPaths = .resolve()) {
        self.paths = paths
    }

    /// True when a previous install is already on disk — the window opens in
    /// "reinstall / uninstall" mode instead of first-run mode.
    var isAlreadyInstalled: Bool {
        fm.fileExists(atPath: paths.installedApp.path)
    }

    // MARK: Install

    func install(progress: (InstallStep) -> Void) -> [StepResult] {
        var results: [StepResult] = []
        progress(.app);        results.append(installApp())
        progress(.hooks);      results.append(installHooks())
        progress(.extensions); results.append(installExtensions())
        return results
    }

    // MARK: 1. The app itself

    private func installApp() -> StepResult {
        guard let src = payloadApp else {
            return StepResult(step: .app, ok: false,
                              detail: L("安装包损坏：找不到内嵌的 SpectiX.app",
                                        "Broken package: bundled SpectiX.app is missing"))
        }
        let dst = paths.installedApp

        // A running copy holds its bundle open; replacing it underneath leaves the
        // old process alive with a deleted binary. Quit it first and wait briefly
        // for the process to actually go away.
        //
        // Not under a re-rooted run: the target there is a throwaway path no process
        // has open, so there is nothing to quit — and the running copy it WOULD find
        // is the developer's own, which the sandbox exists to leave alone.
        if !paths.isSandboxed { quitRunningApp() }
        retireLegacyInstall()
        resetAccessibilityIfSignatureChanged(against: src)

        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } catch {
            return StepResult(step: .app, ok: false,
                              detail: L("拷贝失败：", "Copy failed: ") + error.localizedDescription)
        }

        // The installer arrived from the internet, so everything inside it carries
        // com.apple.quarantine — including the copy we just made. The app is
        // notarized and stapled so it would launch anyway, but stripping the flag
        // keeps the installed copy indistinguishable from a hand-installed one.
        stripQuarantine(at: dst)

        return StepResult(step: .app, ok: true,
                          detail: L("已安装到 ", "Installed to ") + dst.path)
    }

    /// Every bundle id this app has shipped under. Each rename made the previous build a
    /// *different app* to macOS, so a pre-rename copy keeps running through an install of
    /// the new one and the user ends up with two menu bar icons fighting over the same
    /// sessions. T206 moved the id onto the product's domain, T172 renamed the product.
    /// The pre-T206 ids (`com.<vendor>.spectix`, `com.<vendor>.taskbeacon`) are matched
    /// by shape rather than spelled: the vendor segment was a personal name and this
    /// file is public.
    private static func isOurApp(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == "app.spectix.SpectiX"
            || id.range(of: #"^com\.[A-Za-z0-9-]+\.(spectix|taskbeacon)$"#,
                        options: .regularExpression) != nil
    }

    private func quitRunningApp() {
        let ours = { NSWorkspace.shared.runningApplications.filter { Self.isOurApp($0.bundleIdentifier) } }
        let running = ours()
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }

        // Give them a moment to exit; force-terminate whatever is still up.
        let stillUp = { ours().filter { !$0.isTerminated } }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !stillUp().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        stillUp().forEach { $0.forceTerminate() }
    }

    /// Remove what the pre-rename build left behind, once, on the first install of the
    /// renamed one. Everything here is keyed to a name nothing else in this file reads
    /// any more, so skipping it does not leave a harmless leftover — it leaves a second
    /// working app: its hook keeps writing ~/.claude/taskbeacon/state-<tty>, its bundle
    /// keeps launching at login, and its Accessibility row keeps pointing at an id the
    /// user can no longer see a reason for.
    ///
    /// The hook wiring and the editor extension are NOT handled here: they are retired
    /// by the same passes that install their replacements (wireSettings drops any
    /// command naming either script; installExtensions clears both id prefixes), so
    /// they cannot fall out of step with what is being written in their place.
    private func retireLegacyInstall() {
        // Either Applications directory can hold the old copy (see InstallPaths.resolve);
        // a sandboxed run sees only its own re-rooted one.
        let legacyApps = (paths.isSandboxed ? [paths.legacyApp] : [
            URL(fileURLWithPath: "/Applications/TaskBeacon.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/TaskBeacon.app"),
        ]).filter { fm.fileExists(atPath: $0.path) }

        // tccutil addresses the id through LaunchServices, so it has to run while a
        // copy of the old bundle is still on disk — before the removal, never after.
        // A re-rooted test run must never touch the real TCC database.
        if !paths.isSandboxed {
            legacyApps.compactMap { Bundle(url: $0)?.bundleIdentifier }
                .forEach { resetAccessibility(for: $0) }
        }
        legacyApps.forEach { try? fm.removeItem(at: $0) }

        for name in ["taskbeacon-status.sh", "taskbeacon-usage.py"] {
            let url = paths.hooksDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        // Carry the state directory over rather than dropping it: most of what is in
        // there is derived and self-refreshing (per-tty status, the usage cache), but
        // three things are not — the work-time event log, the recent-projects list and
        // the per-row custom icons — and they are the same user's, under a new name.
        // Only when the new location doesn't exist yet, so a second install can never
        // overwrite state the renamed app has already written. That case is the common
        // one, not the exception — the hook mkdir's the new directory on its first
        // event — so this is only the fast path: whatever it declines to move, the app
        // itself merges file by file on next launch (Migration.migrateStateDir, T180).
        if fm.fileExists(atPath: paths.legacyStateDir.path),
           !fm.fileExists(atPath: paths.stateDir.path) {
            try? fm.moveItem(at: paths.legacyStateDir, to: paths.stateDir)
        }
    }

    private func stripQuarantine(at root: URL) {
        var targets = [root]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            targets.append(contentsOf: walker.compactMap { $0 as? URL })
        }
        for url in targets {
            _ = url.withUnsafeFileSystemRepresentation { path in
                path.map { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
            }
        }
    }

    // MARK: Accessibility grant continuity
    //
    // macOS keys an Accessibility grant to neither a name nor a path: it stores
    // (service, bundle id, csreq), where csreq is a snapshot of the app's code
    // signing *designated requirement* taken the moment the user approved it.
    // Every later launch is checked against that snapshot, and a mismatch makes
    // the grant silently inert — while its row in System Settings stays ticked,
    // because that list reports only whether a record exists, never whether it
    // still validates. That is the "I toggled it back on and nothing happened, I
    // had to delete the entry and re-add it" report, and no code can repair it in
    // place: TCC.db is SIP-protected, readable at most, never rewritable.
    //
    // Our Developer ID requirement binds only the bundle id and the team — not
    // the binary's hash, not the certificate's serial — so an ordinary update
    // carries the grant over untouched and must NOT be reset. Clearing it on
    // every install would force the user to re-tick the box on every single
    // update, which is worse than the bug. Only a real requirement change (an
    // older ad-hoc or self-signed build being replaced by a signed one) voids the
    // record, and only then do we clear it, so the user gets a clean prompt
    // instead of a tick that lies.

    /// The `designated => …` line of a bundle's signature; nil when the bundle is
    /// unsigned or unreadable.
    private func designatedRequirement(of bundle: URL) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", bundle.path]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        // Read before waiting: a full pipe buffer with nobody draining it would
        // deadlock the other way round.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("designated =>") }
                   .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Drop every Accessibility record for a bundle id. Addresses the id through
    /// LaunchServices, so a copy of that app must still be on disk — call this
    /// *before* removing the old bundle, never after.
    private func resetAccessibility(for bundleID: String = "app.spectix.SpectiX") {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
    }

    /// Clear the stale grant when — and only when — the copy being replaced
    /// carries a different designated requirement than the one going in.
    private func resetAccessibilityIfSignatureChanged(against incoming: URL) {
        // A re-rooted test run must never touch the real TCC database.
        guard !paths.isSandboxed else { return }

        // Either Applications directory can hold a previous copy (see
        // InstallPaths.resolve), and the stale grant belongs to whichever one the
        // user last approved — so a mismatch in either is reason enough.
        let previous = [
            URL(fileURLWithPath: "/Applications/SpectiX.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/SpectiX.app"),
        ].filter { fm.fileExists(atPath: $0.path) }
        guard !previous.isEmpty else { return }   // first install: nothing to clear

        let incomingDR = designatedRequirement(of: incoming)
        guard previous.contains(where: { designatedRequirement(of: $0) != incomingDR }) else { return }
        // Every id, not just the current one. T206 renamed the id while leaving the .app
        // at the same path, so the copy being replaced here can be holding its grant
        // under the OLD id — clearing only the new one would leave that record behind,
        // and a record whose bundle no longer exists is exactly the one that draws an
        // unclickable row in System Settings. The old id is read off that copy (see
        // isOurApp for why it is not spelled); tccutil on an id with no record is a no-op.
        let onDisk = previous.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { Self.isOurApp($0) }
        Set(["app.spectix.SpectiX"] + onDisk).forEach { resetAccessibility(for: $0) }
    }

    // MARK: 2. Hook scripts + settings.json wiring

    private func installHooks() -> StepResult {
        guard let src = payloadHooks, fm.fileExists(atPath: src.path) else {
            return StepResult(step: .hooks, ok: false,
                              detail: L("安装包损坏：找不到 hook 脚本",
                                        "Broken package: hook scripts are missing"))
        }

        do {
            try fm.createDirectory(at: paths.hooksDir, withIntermediateDirectories: true)
            for name in ["spectix-status.sh", "spectix-usage.py"] {
                let from = src.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = paths.hooksDir.appendingPathComponent(name)
                // Overwrite: unlike the app's own passive bootstrap (which
                // preserves a user's edited copy), running the installer is an
                // explicit "give me this version" request.
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
        } catch {
            return StepResult(step: .hooks, ok: false,
                              detail: L("写入 ~/.claude/hooks 失败：",
                                        "Writing ~/.claude/hooks failed: ") + error.localizedDescription)
        }

        let wired = wireSettings()
        let codex = wireCodex(from: src)
        return StepResult(step: .hooks, ok: wired.ok,
                          detail: wired.note + L("；", "; ") + codex.note,
                          codex: codex.outcome, codexNote: codex.note)
    }

    /// The seven events the app watches, and the state each one writes. Must stay
    /// in lockstep with AppController.bootstrapHooks() in the main app.
    private static let wiring: [(event: String, arg: String)] = [
        ("UserPromptSubmit", "working"), ("PreToolUse", "working"),
        ("PostToolUse", "working"), ("Stop", "done"),
        ("Notification", "needs"), ("PermissionRequest", "needs"),
        ("SessionStart", "session-start"),
    ]

    /// The same table minus `Notification`, which does not exist in Codex. Claude Code
    /// needs it because its permission prompt is only reliably announced that way;
    /// Codex fires `PermissionRequest` (already in the table above) for the same
    /// moment, so nothing is lost by dropping it — and wiring an event the host never
    /// emits would just leave an entry in the user's config that can never fire.
    private static let codexWiring: [(event: String, arg: String)] =
        wiring.filter { $0.event != "Notification" }

    private func wireSettings() -> (ok: Bool, note: String) {
        let url = paths.settings
        let cmd = "~/.claude/hooks/spectix-status.sh"
        let loaded = loadConfig(at: url)
        var root = loaded.root
        let note = loaded.backedUp
            ?? L("已接线 ~/.claude/settings.json", "Wired into ~/.claude/settings.json")

        root["hooks"] = mergeWiring(root["hooks"] as? [String: Any] ?? [:],
                                    table: Self.wiring, command: cmd)

        do {
            try fm.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url)
            return (true, note)
        } catch {
            return (false, L("写入 settings.json 失败：",
                             "Writing settings.json failed: ") + error.localizedDescription)
        }
    }

    /// Reads a hook config. A file that exists but does not parse is copied aside
    /// first: the old shell installer swallowed that case and wrote a fresh `{}` over
    /// it, silently destroying every other setting the user had. Returns the sentence
    /// to report in place of the ordinary one whenever that happened.
    private func loadConfig(at url: URL) -> (root: [String: Any], backedUp: String?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([:], nil) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj, nil)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = url.lastPathComponent
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(name).bak-\(stamp)")
        try? fm.copyItem(at: url, to: backup)
        return ([:], L("原 \(name) 无法解析，已备份为 \(backup.lastPathComponent) 后重建",
                       "\(name) was unreadable — backed up as \(backup.lastPathComponent), rebuilt"))
    }

    /// Rewrites the `hooks` map so every event in `table` holds exactly one entry of
    /// ours, and everything that is not ours survives untouched — the user's own
    /// hooks, their matchers and their order all come back out unchanged.
    ///
    /// Ours is dropped and re-added rather than skipped when present. Plain "add if
    /// missing" would leave stale entries from an older layout behind, and it would
    /// make a second install append a duplicate.
    ///
    /// ★ The match covers the PRE-RENAME name too (T172), and that is the whole
    /// reason `isOurs` is a substring test rather than an equality check. On a machine
    /// wired before the rename, matching only "spectix" leaves the taskbeacon-status.sh
    /// entry in place and appends ours next to it: two hooks fire on every event, each
    /// writing a different state directory, and the row the app shows depends on which
    /// one won the race. Removing the old script from disk (retireLegacyInstall) does
    /// not help — the entry stays in the config and the host just reports it failing,
    /// on every event. Cleanup recognises BOTH names; only the new one is written back.
    private func mergeWiring(_ hooks: [String: Any],
                             table: [(event: String, arg: String)],
                             command: String) -> [String: Any] {
        var hooks = hooks
        for (event, arg) in table {
            var blocks = hooks[event] as? [[String: Any]] ?? []
            blocks = blocks.compactMap { block in
                var block = block
                let kept = (block["hooks"] as? [[String: Any]] ?? []).filter { !Self.isOurs($0) }
                if kept.isEmpty { return nil }
                block["hooks"] = kept
                return block
            }
            blocks.append(["hooks": [["type": "command", "command": "\(command) \(arg)"]]])
            hooks[event] = blocks
        }
        return hooks
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let cmd = (entry["command"] as? String) ?? ""
        return cmd.contains("spectix") || cmd.contains("taskbeacon")
    }

    // MARK: 2b. The same hook, wired into Codex CLI
    //
    // Codex's hook system is Claude Code's contract verbatim: same JSON shape, same
    // event names, and spectix-status.sh runs under it unmodified (it keys everything
    // off the tty, which is the same tty either way). Three things differ, and each
    // one is a decision below rather than an oversight:
    //
    //  1. Codex reads ~/.codex/hooks.json, and never ~/.claude/settings.json.
    //  2. There is no `Notification` event — see `codexWiring`.
    //  3. ★ Codex will not run a hook it has not been told to trust, and it does not
    //     say so when it declines: the hook simply never fires. Trust is recorded per
    //     script CONTENT (a hash, kept in ~/.codex/config.toml under [hooks.state]),
    //     approved by the user from the `/hooks` panel inside Codex, and invalidated
    //     by any edit to the file — including the next SpectiX update shipping a new
    //     version of this script. Nothing here can grant that trust: writing the hash
    //     ourselves would be forging an approval the user never gave. So the install
    //     is not finished when this function returns, and the UI has to say so out
    //     loud — a user who is not told will read the silence as a broken install.

    /// Installs the status script under ~/.codex and merges our entries into
    /// hooks.json, leaving every hook the user already had in place.
    ///
    /// - Parameter payload: the bundled `hooks` directory, same source the Claude side
    ///   copies from — so the two installed copies are written from one file in one
    ///   pass and cannot drift apart.
    private func wireCodex(from payload: URL) -> (outcome: CodexOutcome, note: String) {
        // The directory existing is the only evidence Codex is installed. Creating it
        // to "get ahead" would leave a ~/.codex on machines that have no Codex, which
        // is both a lie and something the uninstall would then have to reason about.
        guard fm.fileExists(atPath: paths.codexDir.path) else {
            return (.absent, L("未检测到 Codex，已跳过", "No Codex found — skipped"))
        }
        let script = payload.appendingPathComponent("spectix-status.sh")
        guard fm.fileExists(atPath: script.path) else {
            return (.failed, L("安装包损坏：找不到 hook 脚本，Codex 未接线",
                               "Broken package: hook script missing — Codex not wired"))
        }

        // A second copy of the script rather than pointing Codex at ~/.claude/hooks:
        // Codex support must not depend on Claude Code being installed (or staying
        // installed), and its trust record is keyed to the file it was approved from.
        // Both copies are written from the same payload in the same pass, so they are
        // byte-identical and cannot drift.
        let installed = paths.codexHooks.appendingPathComponent("spectix-status.sh")
        do {
            try fm.createDirectory(at: paths.codexHooks, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
            try fm.copyItem(at: script, to: installed)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        } catch {
            return (.failed, L("写入 ~/.codex/hooks 失败：",
                               "Writing ~/.codex/hooks failed: ") + error.localizedDescription)
        }

        // Absolute and quoted, unlike the Claude side's `~/…`: whether Codex expands a
        // leading tilde in a hook command is not something this was able to verify, and
        // a path that fails to expand fails silently for exactly the same reason an
        // untrusted hook does. The quotes carry a home directory with a space in it.
        let cmd = "'\(installed.path)'"
        let loaded = loadConfig(at: paths.codexConfig)
        var root = loaded.root
        root["hooks"] = mergeWiring(root["hooks"] as? [String: Any] ?? [:],
                                    table: Self.codexWiring, command: cmd)

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: paths.codexConfig)) != nil
        else {
            return (.failed, L("写入 ~/.codex/hooks.json 失败", "Writing ~/.codex/hooks.json failed"))
        }
        let wired = L("已接线 ~/.codex/hooks.json，还需在 Codex 里跑一次 /hooks 批准",
                      "Wired into ~/.codex/hooks.json — run /hooks in Codex to approve it")
        return (.wired, loaded.backedUp.map { $0 + L("；", "; ") + wired } ?? wired)
    }

    // MARK: 3. Editor companion extension

    /// VSCode, Cursor and Windsurf are all VSCode forks — one unmodified copy of
    /// the extension works in all three.
    private static let editors: [(dir: String, name: String)] = [
        (".vscode", "VS Code"), (".cursor", "Cursor"), (".windsurf", "Windsurf"),
    ]

    /// Current id first; the rest are ids this extension shipped under before and has
    /// to clean up after (see installExtensions).
    private static let extensionIDs = ["spectix.focus", "taskbeacon.focus"]

    private func installExtensions() -> StepResult {
        guard let src = payloadExtension else {
            return StepResult(step: .extensions, ok: false,
                              detail: L("安装包损坏：找不到扩展文件",
                                        "Broken package: extension files are missing"))
        }
        let version = extensionVersion(from: src) ?? "0.0.8"
        let id = "spectix.focus"
        var installed: [String] = []
        var failed: [String] = []

        for editor in Self.editors {
            let base = paths.home.appendingPathComponent(editor.dir)
            guard fm.fileExists(atPath: base.path) else { continue }
            let extRoot = base.appendingPathComponent("extensions")
            let dst = extRoot.appendingPathComponent("\(id)-\(version)")
            do {
                try fm.createDirectory(at: extRoot, withIntermediateDirectories: true)
                // Clear every previous version, else the editor may load an old one.
                // Including the pre-rename id (T172): changing the publisher made this
                // a NEW extension as far as the editor is concerned, so the old one is
                // never superseded — it stays loaded, still watching the state
                // directory this app stopped writing, and every jump it handles goes
                // nowhere. It has to be removed by name.
                for entry in (try? fm.contentsOfDirectory(atPath: extRoot.path)) ?? []
                where Self.extensionIDs.contains(where: { entry.hasPrefix("\($0)-") }) {
                    try? fm.removeItem(at: extRoot.appendingPathComponent(entry))
                }
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for file in ["package.json", "extension.js"] {
                    try fm.copyItem(at: src.appendingPathComponent(file),
                                    to: dst.appendingPathComponent(file))
                }
                guard reindexExtensions(in: extRoot, add: (id, version, dst)) else {
                    failed.append(editor.name)   // files on disk but invisible — say so
                    continue
                }
                installed.append(editor.name)
            } catch {
                failed.append(editor.name)    // one editor failing must not sink the others
            }
        }

        if installed.isEmpty && failed.isEmpty {
            return StepResult(step: .extensions, ok: true,
                              detail: L("没检测到 VS Code / Cursor / Windsurf，已跳过",
                                        "No VS Code / Cursor / Windsurf found — skipped"),
                              skipped: true)
        }
        let sep = ILang.isZH ? "、" : ", "
        if installed.isEmpty {
            let names = failed.joined(separator: sep)
            return StepResult(step: .extensions, ok: false,
                              detail: L("装入 \(names) 失败，跳转落点高亮不会出现",
                                        "Could not install into \(names) — jump highlights won't appear"))
        }
        var detail = L("已装入 \(installed.joined(separator: sep))，重载窗口后生效",
                       "Installed into \(installed.joined(separator: sep)) — reload the window")
        if !failed.isEmpty {
            detail += L("；\(failed.joined(separator: sep)) 失败",
                        "; failed for \(failed.joined(separator: sep))")
        }
        return StepResult(step: .extensions, ok: true, detail: detail, editors: installed)
    }

    /// `extensions.json` sitting next to the extension folders is the editor's ONLY
    /// index of what is installed — a folder that is not listed there does not exist
    /// as far as VSCode is concerned. T226: the installer copied the files and stopped,
    /// so the extension never loaded, nobody wrote `active-terminal`, and every jump's
    /// focus ring silently gave up while the jump itself still worked (it does not need
    /// the extension). Register on install, unregister on uninstall.
    ///
    /// Only the default profile's index is touched. Named profiles keep their own
    /// `extensions.json` under `Application Support`; installing into those is a
    /// separate problem and is deliberately not attempted here.
    ///
    /// Returns false when the index cannot be updated — the caller reports that editor
    /// as failed rather than claiming an install the editor will ignore.
    private func reindexExtensions(in extRoot: URL,
                                   add entry: (id: String, version: String, dir: URL)?) -> Bool {
        let url = extRoot.appendingPathComponent("extensions.json")
        var list: [[String: Any]] = []
        if let data = try? Data(contentsOf: url) {
            // A file we cannot parse must be left alone: overwriting it would wipe the
            // user's entire extension index, which is far worse than not installing.
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return false }
            list = parsed
        } else if entry == nil {
            return true    // uninstalling from an editor that has no index — nothing to do
        }

        // Drop every entry for our ids first, current and retired alike. Without this
        // a reinstall appends a second row for the same id, and a rename leaves the
        // retired id claiming to be installed at a folder that was just deleted.
        list.removeAll { row in
            guard let id = (row["identifier"] as? [String: Any])?["id"] as? String
            else { return false }
            return Self.extensionIDs.contains(id)
        }

        if let entry {
            // Mirrors the shape VSCode writes for an extension that did not come from
            // the marketplace: no uuid, no metadata. Verified accepted by
            // `code --list-extensions`.
            list.append([
                "identifier": ["id": entry.id],
                "version": entry.version,
                "location": ["$mid": 1, "path": entry.dir.path, "scheme": "file"],
                "relativeLocation": entry.dir.lastPathComponent,
            ])
        }

        guard let out = try? JSONSerialization.data(withJSONObject: list) else { return false }
        // Atomic: the editor may read this file at any moment, and a half-written
        // index reads as "no extensions installed".
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    private func extensionVersion(from dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["version"] as? String
    }

    // MARK: Uninstall

    /// Mirrors install: removes the app, the hook scripts, our settings.json
    /// wiring (leaving every other hook intact), the state directory, and the
    /// extension from all three editors.
    func uninstall() -> [String] {
        var removed: [String] = []
        if !paths.isSandboxed { quitRunningApp() }   // see installApp()

        // Clear the Accessibility record while a bundle is still on disk for
        // tccutil to address — once the app is gone the id no longer resolves and
        // the row would sit in System Settings forever, pointing at nothing.
        // Old ids too (T172): a machine that never ran the renamed installer still has a
        // grant under one, and uninstalling would strand exactly the orphan row this
        // ordering exists to prevent. They are read off the bundles about to be removed
        // (see isOurApp for why they are not spelled) — tccutil can only reach an id
        // whose bundle is on disk anyway.
        if !paths.isSandboxed {
            let onDisk = [paths.installedApp, paths.legacyApp]
                .compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { Self.isOurApp($0) }
            Set(["app.spectix.SpectiX"] + onDisk).forEach { resetAccessibility(for: $0) }
        }

        for app in [paths.installedApp, paths.legacyApp]
        where fm.fileExists(atPath: app.path) {
            try? fm.removeItem(at: app)
            if !removed.contains("App") { removed.append("App") }
        }

        for name in ["spectix-status.sh", "spectix-usage.py",
                     "taskbeacon-status.sh", "taskbeacon-usage.py"] {
            let url = paths.hooksDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        for dir in [paths.stateDir, paths.legacyStateDir]
        where fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        removed.append(L("hook 与状态文件", "hook & state files"))

        if unwireSettings() { removed.append(L("settings.json 接线", "settings.json wiring")) }

        // The script only; ~/.codex/hooks is the user's own directory and holds their
        // other hooks, so it is never removed even if ours was the last file in it.
        let codexScript = paths.codexHooks.appendingPathComponent("spectix-status.sh")
        var codexCleaned = fm.fileExists(atPath: codexScript.path)
        if codexCleaned { try? fm.removeItem(at: codexScript) }
        if unwireConfig(at: paths.codexConfig) { codexCleaned = true }
        if codexCleaned { removed.append(L("Codex 接线", "Codex wiring")) }

        var editorsCleaned = false
        for editor in Self.editors {
            let extRoot = paths.home.appendingPathComponent(editor.dir)
                .appendingPathComponent("extensions")
            for entry in (try? fm.contentsOfDirectory(atPath: extRoot.path)) ?? []
            where Self.extensionIDs.contains(where: { entry.hasPrefix("\($0)-") }) {
                try? fm.removeItem(at: extRoot.appendingPathComponent(entry))
                editorsCleaned = true
            }
            // Unconditionally, not only when a folder was deleted: the index can hold a
            // stale row pointing at a folder that is already gone, and the editor would
            // keep reporting the extension as installed.
            _ = reindexExtensions(in: extRoot, add: nil)
        }
        if editorsCleaned { removed.append(L("编辑器扩展", "editor extension")) }
        return removed
    }

    private func unwireSettings() -> Bool { unwireConfig(at: paths.settings) }

    /// Strips our entries out of a hook config — settings.json or Codex's hooks.json,
    /// which are the same shape — and writes it back only if something was actually
    /// removed. Every other hook, and every other key in the file, is preserved.
    /// Returns false when there was nothing of ours to take out.
    private func unwireConfig(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return false }

        var touched = false
        for event in hooks.keys {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = blocks.compactMap { block -> [String: Any]? in
                var block = block
                let all = block["hooks"] as? [[String: Any]] ?? []
                // Both names, same reason as mergeWiring: an uninstall that leaves the
                // pre-rename entry behind leaves the host running a hook script this
                // uninstall just deleted, failing on every event.
                let kept = all.filter { !Self.isOurs($0) }
                if kept.count != all.count { touched = true }
                if kept.isEmpty { return nil }
                block["hooks"] = kept
                return block
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        guard touched else { return false }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        try? out.write(to: url)
        return true
    }
}
