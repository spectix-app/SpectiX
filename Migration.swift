import Foundation

// MARK: - Carrying a pre-rename install over (T180)
//
// T172 renamed the app: bundle id com.<vendor>.taskbeacon → com.<vendor>.spectix,
// state directory ~/.claude/taskbeacon → ~/.claude/spectix, hook script
// taskbeacon-status.sh → spectix-status.sh. To macOS those are two unrelated apps,
// so on an upgrading machine nothing follows the rename on its own: every
// preference snaps back to its default, the work-time log and the recent-projects
// list stop at the rename, and the old hook keeps firing into a directory nobody
// reads.
//
// The installer already retires the old *install* (old bundle, old scripts, old
// settings.json wiring — InstallerCore.retireLegacyInstall). What it cannot carry
// is the *data*: its one-shot `moveItem` only fires when the new state directory
// does not exist yet, and by then it always does — the hook mkdir's it on the
// first event and projects.json seeds itself on first launch. Doing it here
// instead covers every install path (installer, hand-copied bundle, dev build)
// and can merge the two sides rather than choosing one wholesale.
//
// Runs once per machine, before the first preference is read. Every step swallows
// its failures: a migration that cannot finish must never keep the app from
// launching, and none of it is load-bearing for a fresh install.
enum Migration {

    /// Set in the NEW domain, so it is absent on exactly the machines that still
    /// need the pass — and a machine that has run it once never pays for it again.
    private static let flagKey = "legacyMigrationDone"

    /// Every bundle id this app has shipped under, newest first — the first domain to
    /// supply a key wins. Two renames are represented here. T206 moved the id onto the
    /// product's domain (`com.<vendor>.spectix` → `app.spectix.SpectiX`) so that a
    /// world-readable string stops carrying personal information; T172 before it was the
    /// product rename (`com.<vendor>.taskbeacon`). `com.taskbeacon.app` and a bare
    /// `TaskBeacon` (a build that shipped without an explicit id, so CFBundleName became
    /// one) are older still and can both be on a long-lived machine.
    ///
    /// This list is the only reason a rename costs the user nothing on the settings side.
    /// It does NOT carry the Accessibility grant — TCC has no equivalent, which is why
    /// build.sh calls the id frozen from here on.
    ///
    /// The dev build carries the release ids as well, and that is not a rename: build.sh
    /// gives it its own bundle id so its Accessibility grant stops colliding with the
    /// release install's over TCC's single per-id record. A separate id is a separate
    /// preference domain too, so without this the developer's own machine loses every
    /// setting the moment the split lands. Seeding from the release domain is one-shot
    /// like the rest — the two diverge from first launch on, which is the point.
    ///
    /// The ids shipped between T172 and T206 (`com.<vendor>.spectix`, its `.dev` twin,
    /// `com.<vendor>.taskbeacon`) are found on disk by shape rather than spelled here:
    /// the vendor segment was the author's personal name and this file is public.
    private static var legacyDomains: [String] {
        let vendor = vendorDomains()
        let pick = { (suffix: String) in vendor.filter { $0.hasSuffix(suffix) } }
        #if DEV_BUILD
        let current = ["app.spectix.SpectiX"] + pick(".spectix.dev")
        #else
        let current: [String] = []
        #endif
        return current + pick(".spectix") + pick(".taskbeacon") + ["com.taskbeacon.app", "TaskBeacon"]
    }

    /// `com.<vendor>.spectix[.dev]` and `com.<vendor>.taskbeacon` domains that have a
    /// plist on this machine. Only the NAME comes from the file listing — the values are
    /// still read through cfprefsd by `domainKeys`, for the reason given there.
    private static func vendorDomains() -> [String] {
        let dir = NSHomeDirectory() + "/Library/Preferences"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { name -> String? in
            guard name.range(of: #"^com\.[A-Za-z0-9-]+\.(spectix(\.dev)?|taskbeacon)\.plist$"#,
                             options: .regularExpression) != nil else { return nil }
            return String(name.dropLast(".plist".count))
        }.sorted()
    }

    /// The same escape hatch as InstallPaths.resolve, and for the same reason: it lets
    /// this pass be exercised against a throwaway tree instead of the developer's own
    /// ~/.claude, which holds a large hand-tuned hook config a test run must not touch.
    /// Unset for every real user, always.
    private static var claudeDir: String {
        let root = ProcessInfo.processInfo.environment["SPECTIX_MIGRATE_ROOT"] ?? ""
        return "\(root.isEmpty ? NSHomeDirectory() : root)/.claude"
    }

    private static var legacyDir:  String { "\(claudeDir)/taskbeacon" }
    private static var currentDir: String { "\(claudeDir)/spectix" }
    private static var settingsFile: String { "\(claudeDir)/settings.json" }

    /// Call first thing in applicationDidFinishLaunching — ahead of any AppSettings
    /// getter, or the app renders one frame from defaults it is about to replace.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }
        defaults.set(true, forKey: flagKey)

        migrateDefaults()
        migrateStateDir()
        rewireLegacyHook()
    }

    // MARK: Preferences

    /// Every key an older bundle id wrote, into the current one. A key the current
    /// domain already holds is never overwritten: that value was written since the
    /// rename and is the user's more recent intent.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        // The "already set?" test reads the current domain the same way, on purpose.
        // `object(forKey:)` answers from the whole search list — the registration
        // domain and NSGlobalDomain included — so an inherited hit would read as
        // "user already chose this" and skip a key nobody ever set.
        var taken = Set(domainKeys(kCFPreferencesCurrentApplication).keys)
        for domain in legacyDomains {
            for (key, value) in domainKeys(domain as CFString)
            where !taken.contains(key) && isMigratable(key) {
                defaults.set(value, forKey: key)
                taken.insert(key)
            }
        }
    }

    /// One preference domain's own keys — nothing inherited.
    ///
    /// Not `UserDefaults(suiteName:)`: a suite object still carries the full search
    /// list, so `dictionaryRepresentation()` hands back NSGlobalDomain and
    /// registration keys alongside the real ones (measured on this machine: 138 keys
    /// returned for a domain holding 54) with no way to tell which came from where.
    /// CFPreferences at this level returns exactly the domain's plist, and still goes
    /// through cfprefsd — reading the file by hand would bypass the daemon that owns
    /// it and can be stale. An absent domain reads back empty, not nil.
    private static func domainKeys(_ domain: CFString) -> [String: Any] {
        CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private static func isMigratable(_ key: String) -> Bool {
        // The login item is registered per bundle id, so the renamed app has to be
        // allowed to seed its own. Carrying this flag over as `true` means
        // seedLaunchAtLogin() no-ops and the user's 开机启动 silently stops working.
        if key == "launchAtLoginSeeded" { return false }
        // Written by the frameworks, not by us: color/open panel state, toolbar
        // configs, window-frame autosave, per-app language overrides. They are the
        // old app's stale UI state — the old domain here really does hold seven of
        // them. No key of ours starts with any of these.
        for prefix in ["NS", "Apple", "com.apple.", "AK", "PK", "WebKit", "_"]
        where key.hasPrefix(prefix) { return false }
        return true
    }

    // MARK: State directory

    /// Only what the new directory cannot regenerate. Everything else in there is
    /// derived and self-refreshing inside one 2.5s poll (per-tty state/title/step,
    /// the context snapshots, the usage cache, the request handshake files, the
    /// debug logs), and copying a stale copy of it would resurrect rows for
    /// sessions that ended weeks ago.
    private static func migrateStateDir() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDir) else { return }
        try? fm.createDirectory(atPath: currentDir, withIntermediateDirectories: true)

        // The two alert-sound choices and the volume: bare-name files the hook
        // reads (see AppSettings.readSound). Kept only when the new name has no
        // value of its own.
        for name in ["sound-done", "sound-needs", "sound-volume"] {
            let dst = "\(currentDir)/\(name)"
            guard !fm.fileExists(atPath: dst) else { continue }
            try? fm.copyItem(atPath: "\(legacyDir)/\(name)", toPath: dst)
        }

        mergeEventLog()
        mergeProjects()
        mergeIcons()
    }

    /// The work-time log is append-only and BOTH names can hold real events: a
    /// machine that ran the old hook and the new one in the same week has a
    /// genuine overlap plus a stretch only the old one saw. So union the lines
    /// instead of picking a file — deduping on the whole raw line, since every
    /// field including the timestamp is in it, and re-sorting by `ts` because
    /// Stats walks the log expecting it to move forward in time.
    ///
    /// The dedupe is not only about the overlap between the two files: each file
    /// already holds duplicate lines of its own (measured on the dev machine:
    /// 493 of 4780 lines, from the stretch when both hooks were wired at once). Stats
    /// does not dedupe as it reads, so those were being counted twice — tokens, cost
    /// and event counts all included. Merging therefore makes existing totals go DOWN,
    /// which is a correction, not a loss: an identical line is the same event, down to
    /// its token tallies.
    private static func mergeEventLog() {
        let fm = FileManager.default
        let name = "events.jsonl"
        guard let oldData = fm.contents(atPath: "\(legacyDir)/\(name)") else { return }
        let dst = "\(currentDir)/\(name)"
        // Byte level throughout, never String(contentsOfFile:). The hook truncates
        // long prompt titles, so one clipped multi-byte character anywhere in the
        // file makes a UTF-8 read of the WHOLE file fail — and a failed read of the
        // destination here would mean overwriting it with the old file alone.
        let newData = fm.fileExists(atPath: dst) ? fm.contents(atPath: dst) : Data()
        guard let newData else { return }   // exists but unreadable → leave it alone

        let newline = UInt8(0x0A)
        var seen = Set<Data>()
        // (timestamp, arrival order, line) — the order field keeps same-second events
        // in the sequence they were logged, which sort(by:) alone does not promise.
        var rows: [(ts: Double, seq: Int, line: Data)] = []
        for chunk in [oldData, newData] {
            for line in chunk.split(separator: newline) where !line.isEmpty {
                let data = Data(line)
                guard seen.insert(data).inserted else { continue }
                rows.append((timestamp(of: data), rows.count, data))
            }
        }
        var out = Data()
        for row in rows.sorted(by: { $0.ts == $1.ts ? $0.seq < $1.seq : $0.ts < $1.ts }) {
            out.append(row.line)
            out.append(newline)
        }
        try? out.write(to: URL(fileURLWithPath: dst), options: .atomic)
    }

    private static func timestamp(of line: Data) -> Double {
        // Second candidate: the same line with invalid bytes replaced by U+FFFD. A
        // title clipped mid-character is not JSON the parser will touch, and falling
        // through to 0 would sort that line to the very top of the log — which is the
        // one ordering Stats' work clock is entitled to assume can't happen. The
        // replacement lands inside the title string, so the number stays readable, and
        // it is only ever used for sorting: the line written out is the original bytes.
        for candidate in [line, Data(String(decoding: line, as: UTF8.self).utf8)] {
            if let o = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
               let t = (o["ts"] as? NSNumber)?.doubleValue { return t }
        }
        return 0
    }

    /// projects.json always exists under the new name by now — first launch seeds it
    /// from ~/.claude.json — but a seeded entry carries lastSeen 0 and no pin, which
    /// is strictly less than what the old file remembers. Union by path, keeping the
    /// later sighting and a pin from either side.
    private static func mergeProjects() {
        let name = "projects.json"
        guard let oldRows = projectRows(at: "\(legacyDir)/\(name)") else { return }
        let dst = "\(currentDir)/\(name)"
        var merged: [String: (lastSeen: Double, pinned: Bool)] = [:]
        for row in oldRows + (projectRows(at: dst) ?? []) {
            let prev = merged[row.path]
            merged[row.path] = (max(prev?.lastSeen ?? 0, row.lastSeen),
                                (prev?.pinned ?? false) || row.pinned)
        }
        let out = merged.map { path, v -> [String: Any] in
            var o: [String: Any] = ["path": path, "lastSeen": v.lastSeen]
            if v.pinned { o["pinned"] = true }
            return o
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: dst), options: .atomic)
    }

    private static func projectRows(at path: String)
        -> [(path: String, lastSeen: Double, pinned: Bool)]? {
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr.compactMap {
            guard let p = $0["path"] as? String,
                  let t = ($0["lastSeen"] as? NSNumber)?.doubleValue else { return nil }
            return (p, t, $0["pinned"] as? Bool ?? false)
        }
    }

    /// The per-project icon PNGs. File names are unique per import and the
    /// `customIconImages` dictionary that points at them just came over in
    /// migrateDefaults — so these two have to move together or the surviving half
    /// references nothing.
    private static func mergeIcons() {
        let fm = FileManager.default
        let src = "\(legacyDir)/icons"
        guard let names = try? fm.contentsOfDirectory(atPath: src) else { return }
        let dst = "\(currentDir)/icons"
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        for name in names where !fm.fileExists(atPath: "\(dst)/\(name)") {
            try? fm.copyItem(atPath: "\(src)/\(name)", toPath: "\(dst)/\(name)")
        }
    }

    // MARK: Hook wiring

    /// Point our own settings.json entries at the renamed scripts.
    ///
    /// This is narrower than it looks, and deliberately so: it rewrites the script
    /// NAME inside commands that already name our hook, and touches nothing else.
    /// AppController.bootstrapHooks cannot do this — it may never edit a user's
    /// entries, so all it can do is decline to append a second one, which leaves a
    /// machine wired before the rename running the OLD script forever: it writes
    /// ~/.claude/taskbeacon/state-<tty>, which this build does not read, so every
    /// row goes 闲置 while the hook fires perfectly. The installer fixes this too
    /// (InstallerCore.wireSettings), but a hand-copied bundle never runs it.
    private static func rewireLegacyHook() {
        let url = URL(fileURLWithPath: settingsFile)
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }

        var changed = false
        for (event, raw) in hooks {
            guard let blocks = raw as? [[String: Any]] else { continue }
            var seen = Set<String>()
            var rebuilt: [[String: Any]] = []
            for block in blocks {
                var block = block
                // Both writers of our wiring (bootstrapHooks here, wireSettings in
                // the installer) append a matcher-less block of their own, so a
                // machine wired on both sides of the rename holds the duplicate
                // across two blocks — which is why dedupe spans them. A block WITH
                // a matcher is the user's own composition and is left whole, even
                // if it names the same script.
                let dedupable = block["matcher"] == nil
                var kept: [[String: Any]] = []
                for entry in (block["hooks"] as? [[String: Any]] ?? []) {
                    var entry = entry
                    guard let cmd = entry["command"] as? String else { kept.append(entry); continue }
                    let renamed = cmd
                        .replacingOccurrences(of: "taskbeacon-status", with: "spectix-status")
                        .replacingOccurrences(of: "taskbeacon-usage", with: "spectix-usage")
                    if dedupable, renamed.contains("spectix-status") || renamed.contains("spectix-usage") {
                        guard seen.insert(renamed).inserted else { changed = true; continue }
                    }
                    if renamed != cmd {
                        entry["command"] = renamed
                        changed = true
                    }
                    kept.append(entry)
                }
                guard !kept.isEmpty else { continue }
                block["hooks"] = kept
                rebuilt.append(block)
            }
            hooks[event] = rebuilt
        }
        guard changed else { return }
        root["hooks"] = hooks
        if let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
        }
    }
}
