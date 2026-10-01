import Foundation

// MARK: - Project history
//
// Persistent record of every project directory a Claude session has ever been
// observed in (plus any the user added by hand), so a project closed in VSCode
// can be reopened with one click from the "最近项目" window. The scan loop
// already knows each live session's cwd — this just remembers them across
// restarts.
//
// Storage: ~/.claude/spectix/projects.json —
//   [{"path": ..., "lastSeen": epoch, "pinned": bool}].
// lastSeen == 0 marks a seeded entry (imported, never actually observed by us),
// so the UI can skip showing a bogus timestamp for it. "pinned" is omitted when
// false (older files without the key load fine).
//
// Main-thread only (called from refresh()'s main-queue completion and the UI).
enum ProjectHistory {

    struct Entry {
        let path: String
        let lastSeen: Double
        let pinned: Bool
    }

    private static let file = "\(NSHomeDirectory())/.claude/spectix/projects.json"
    private static var cache: [String: (lastSeen: Double, pinned: Bool)] = [:]
    private static var loaded = false

    /// All known projects: pinned first, then most recently seen (seeded entries
    /// sink to the bottom, alphabetical among themselves).
    static func all() -> [Entry] {
        // Demo mode substitutes a fabricated list, and every mutator below refuses to
        // run — otherwise pinning or deleting a fake project during a recording would
        // rewrite the user's real projects.json.
        if Demo.enabled { return Demo.projects() }
        load()
        return cache.map { Entry(path: $0.key, lastSeen: $0.value.lastSeen, pinned: $0.value.pinned) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.path < $1.path
            }
    }

    /// Merge the cwds of the sessions alive right now. Non-paths (the desktop
    /// row's sentinel) are skipped. lastSeen advances at most once per minute
    /// per project so the 2.5s scan doesn't rewrite the file constantly.
    static func record(_ cwds: [String]) {
        guard !Demo.enabled else { return }
        load()
        let now = Date().timeIntervalSince1970
        var changed = false
        for cwd in Set(cwds) where cwd.hasPrefix("/") {
            if let e = cache[cwd], now - e.lastSeen < 60 { continue }
            cache[cwd] = (now, cache[cwd]?.pinned ?? false)
            changed = true
        }
        if changed { save() }
    }

    /// User picked a folder by hand — add it (or bump it) so it surfaces on top.
    static func add(_ path: String) {
        guard !Demo.enabled else { return }
        load()
        cache[path] = (Date().timeIntervalSince1970, cache[path]?.pinned ?? false)
        save()
    }

    static func setPinned(_ path: String, _ pinned: Bool) {
        guard !Demo.enabled else { return }
        load()
        guard let e = cache[path], e.pinned != pinned else { return }
        cache[path] = (e.lastSeen, pinned)
        save()
    }

    static func remove(_ path: String) {
        guard !Demo.enabled else { return }
        load()
        guard cache.removeValue(forKey: path) != nil else { return }
        save()
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = FileManager.default.contents(atPath: file),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for o in arr {
                guard let p = o["path"] as? String,
                      let t = (o["lastSeen"] as? NSNumber)?.doubleValue else { continue }
                cache[p] = (t, o["pinned"] as? Bool ?? false)
            }
        }
        if cache.isEmpty { seed() }
    }

    // First run: import the project dirs Claude Code itself remembers (the
    // "projects" keys of ~/.claude.json), so the list is useful immediately
    // instead of filling up one session at a time. Dirs that no longer exist
    // are skipped; imported entries carry lastSeen 0 ("never observed").
    private static func seed() {
        guard let data = FileManager.default.contents(atPath: "\(NSHomeDirectory())/.claude.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return }
        var isDir: ObjCBool = false
        for cwd in projects.keys where cwd.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
                cache[cwd] = (0, false)
            }
        }
        if !cache.isEmpty { save() }
    }

    private static func save() {
        let arr = cache.map { k, v -> [String: Any] in
            var o: [String: Any] = ["path": k, "lastSeen": v.lastSeen]
            if v.pinned { o["pinned"] = true }
            return o
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
