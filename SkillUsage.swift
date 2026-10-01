import Foundation

struct UsageStat: Codable {
    var n: Int = 0
    var t: Double = 0

    mutating func add(_ ts: Double) { n += 1; t = max(t, ts) }
    mutating func merge(_ o: UsageStat) { n += o.n; t = max(t, o.t) }
}

private struct PendingUse: Codable {
    let key: String
    let t: Double
}

private struct FileEntry: Codable {
    var size: Int64
    var mtime: Double
    var offset: Int64
    var uses: [String: UsageStat] = [:]
    // Agent launches whose tool_result hasn't been read yet; they only become real uses once we know
    // the launch wasn't rejected, but they still count in totals meanwhile (a killed session never gets one).
    var pending: [String: PendingUse] = [:]
}

private struct UsageCache: Codable {
    var version: Int
    var files: [String: FileEntry]
}

/// Keys: `claude.skill.X`, `claude.typed.X` (raw typed `/X`, unfiltered), `claude.agent.X`,
/// `codex.skill.X`, `codex.agent.X`.
enum SkillUsage {
    static let cacheVersion = 1
    static var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/SpectiX/skill-usage.json")
    }

    private static let chunkSize = 4 << 20

    /// Blocking; call off the main thread.
    static func scan() -> [String: UsageStat] {
        let old = loadCache()
        let jobs = listClaude().map { ($0, false) } + listCodex().map { ($0, true) }
        var results = [FileEntry?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let (path, codex) = jobs[i]
            guard let (size, mtime) = statFile(path) else { return }
            let prev = old[path]
            let entry: FileEntry
            if let p = prev, p.size == size, p.mtime == mtime {
                entry = p
            } else if codex {
                entry = scanCodex(path: path, size: size, mtime: mtime)
            } else {
                entry = scanClaude(path: path, prev: prev, size: size, mtime: mtime)
            }
            lock.lock(); results[i] = entry; lock.unlock()
        }
        var files: [String: FileEntry] = [:]
        var totals: [String: UsageStat] = [:]
        for (i, e) in results.enumerated() {
            guard let e else { continue }
            files[jobs[i].0] = e
            for (k, s) in e.uses { totals[k, default: UsageStat()].merge(s) }
            for p in e.pending.values { totals[p.key, default: UsageStat()].add(p.t) }
        }
        saveCache(UsageCache(version: cacheVersion, files: files))
        return totals
    }

    // MARK: - Cache

    private static func loadCache() -> [String: FileEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(UsageCache.self, from: data),
              c.version == cacheVersion else { return [:] }
        return c.files
    }

    private static func saveCache(_ c: UsageCache) {
        let url = cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - File discovery

    private static func subdirs(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
    }

    private static func listClaude() -> [String] {
        var out: [String] = []
        for proj in subdirs(NSHomeDirectory() + "/.claude/projects") {
            for entry in subdirs(proj) {
                if entry.hasSuffix(".jsonl") { out.append(entry); continue }
                for f in subdirs(entry + "/subagents") where f.hasSuffix(".jsonl") { out.append(f) }
            }
        }
        return out
    }

    private static func listCodex() -> [String] {
        let root = NSHomeDirectory() + "/.codex/sessions"
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { out.append(root + "/" + rel) }
        }
        return out
    }

    private static func statFile(_ path: String) -> (Int64, Double)? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (Int64(st.st_size), m)
    }

    // MARK: - Claude transcripts

    private static let claudeNeedles: [[UInt8]] = [
        "\"name\":\"Skill\"", "\"name\":\"Agent\"", "\"name\":\"Task\"", "<command-name>",
    ].map { Array($0.utf8) }

    private static let typedRegex = try! NSRegularExpression(pattern: "<command-name>/([^<\\s]+)</command-name>")

    private static func scanClaude(path: String, prev: FileEntry?, size: Int64, mtime: Double) -> FileEntry {
        var e = prev ?? FileEntry(size: 0, mtime: 0, offset: 0)
        if size < e.offset { e = FileEntry(size: 0, mtime: 0, offset: 0) }
        e.size = size
        e.mtime = mtime
        guard size > e.offset, let fh = FileHandle(forReadingAtPath: path) else { return e }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(e.offset)) } catch { return e }
        var buf = Data()
        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buf.append(chunk)
            let used = buf.withUnsafeBytes { raw -> Int in
                let p = raw.bindMemory(to: UInt8.self)
                guard let base = p.baseAddress, let end = lastNewline(base, p.count) else { return 0 }
                processClaude(base, end + 1, &e)
                return end + 1
            }
            if used > 0 {
                e.offset += Int64(used)
                buf = used == buf.count ? Data() : Data(buf[used...])
            }
        }
        return e
    }

    private static func lastNewline(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int? {
        var i = n - 1
        while i >= 0 { if p[i] == 0x0A { return i }; i -= 1 }
        return nil
    }

    private static func lineBounds(_ p: UnsafePointer<UInt8>, _ n: Int, _ hit: Int) -> (Int, Int) {
        var s = hit
        while s > 0 && p[s - 1] != 0x0A { s -= 1 }
        let e = memchr(p + hit, 0x0A, n - hit).map { UnsafeRawPointer($0) - UnsafeRawPointer(p) } ?? n
        return (s, e)
    }

    /// Byte offsets of every line containing `needle`, searching from `from`.
    private static func linesContaining(_ needle: [UInt8], _ p: UnsafePointer<UInt8>, _ n: Int, from: Int = 0) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var at = from
        while at < n, let hit = needle.withUnsafeBytes({ memmem(p + at, n - at, $0.baseAddress, $0.count) }) {
            let (s, e) = lineBounds(p, n, UnsafeRawPointer(hit) - UnsafeRawPointer(p))
            out.append((s, e))
            at = e + 1
        }
        return out
    }

    private static func json(_ p: UnsafePointer<UInt8>, _ r: (Int, Int)) -> [String: Any]? {
        let d = Data(bytes: p + r.0, count: r.1 - r.0)
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func processClaude(_ p: UnsafePointer<UInt8>, _ n: Int, _ e: inout FileEntry) {
        var lines: [Int: Int] = [:]
        for needle in claudeNeedles { for (s, end) in linesContaining(needle, p, n) { lines[s] = end } }
        // Where to start looking for each pending id's tool_result; ids carried over search from 0.
        var searchFrom: [String: Int] = e.pending.mapValues { _ in 0 }
        for s in lines.keys.sorted() {
            let end = lines[s]!
            guard let obj = json(p, (s, end)), let msg = obj["message"] as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(parseISO) ?? 0
            switch obj["type"] as? String {
            case "assistant":
                for case let c as [String: Any] in (msg["content"] as? [Any]) ?? [] where c["type"] as? String == "tool_use" {
                    let input = c["input"] as? [String: Any] ?? [:]
                    switch c["name"] as? String {
                    case "Skill":
                        if let sk = input["skill"] as? String, !sk.isEmpty { e.uses["claude.skill." + sk, default: UsageStat()].add(ts) }
                    case "Agent", "Task":
                        let t = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general-purpose"
                        let key = "claude.agent." + t
                        if let id = c["id"] as? String {
                            e.pending[id] = PendingUse(key: key, t: ts)
                            searchFrom[id] = end
                        } else {
                            e.uses[key, default: UsageStat()].add(ts)
                        }
                    default: break
                    }
                }
            case "user":
                var texts: [String] = []
                if let s = msg["content"] as? String { texts.append(s) }
                for case let c as [String: Any] in (msg["content"] as? [Any]) ?? [] where c["type"] as? String == "text" {
                    if let t = c["text"] as? String { texts.append(t) }
                }
                for t in texts where t.contains("<command-name>") {
                    let ns = t as NSString
                    for m in typedRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                        e.uses["claude.typed." + ns.substring(with: m.range(at: 1)), default: UsageStat()].add(ts)
                    }
                }
            default: break
            }
        }
        for (id, from) in searchFrom {
            guard let pend = e.pending[id] else { continue }
            // The literal is stable regardless of object key order, and only tool_result blocks carry it.
            let needle = Array("\"tool_use_id\":\"\(id)\"".utf8)
            for r in linesContaining(needle, p, n, from: from) {
                guard let obj = json(p, r), let msg = obj["message"] as? [String: Any],
                      let result = ((msg["content"] as? [Any]) ?? []).lazy.compactMap({ $0 as? [String: Any] })
                        .first(where: { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == id })
                else { continue }
                e.pending[id] = nil
                if result["is_error"] as? Bool != true { e.uses[pend.key, default: UsageStat()].add(pend.t) }
                break
            }
        }
    }

    // MARK: - Codex sessions

    private static let codexNeedles = ["spawn_agent", "SKILL.md", "<skill>", "task_started"].map { Array($0.utf8) }
    private static let skillReadRegex = try! NSRegularExpression(
        pattern: #"(?:sed\s+-n\s+['"]?1,\d+p['"]?|\bcat)\s+(?:[^\s'"\\]*/)?([^/\s'"\\]+)/SKILL\.md"#)

    private static func scanCodex(path: String, size: Int64, mtime: Double) -> FileEntry {
        var e = FileEntry(size: size, mtime: mtime, offset: size)
        guard let data = FileManager.default.contents(atPath: path) else { return e }
        let fallbackTs = fileNameTime(path)
        var turnSkills = Set<String>()
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard let base = p.baseAddress else { return }
            let n = p.count
            var lines: [Int: Int] = [:]
            for needle in codexNeedles { for (s, end) in linesContaining(needle, base, n) { lines[s] = end } }
            for s in lines.keys.sorted() {
                guard let obj = json(base, (s, lines[s]!)) else { continue }
                let pl = obj["payload"] as? [String: Any] ?? obj
                let ts = (obj["timestamp"] as? String).flatMap(parseISO) ?? fallbackTs
                let type = pl["type"] as? String
                let name = pl["name"] as? String
                func skillUse(_ x: String) {
                    if turnSkills.insert(x).inserted { e.uses["codex.skill." + x, default: UsageStat()].add(ts) }
                }
                func scanCommand(_ cmd: String) {
                    let ns = cmd as NSString
                    for m in skillReadRegex.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
                        skillUse(ns.substring(with: m.range(at: 1)))
                    }
                }
                if type == "task_started" {
                    turnSkills.removeAll()
                } else if type == "function_call", name == "spawn_agent" {
                    let args = (pl["arguments"] as? String)?.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let t = (args?["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
                    e.uses["codex.agent." + t, default: UsageStat()].add(ts)
                } else if type == "custom_tool_call", name == "exec", let input = pl["input"] as? String {
                    scanCommand(input)
                } else if type == "function_call", name == "shell" || name == "exec_command", let args = pl["arguments"] as? String {
                    scanCommand(args)
                } else if type == "message", pl["role"] as? String == "user" {
                    for case let c as [String: Any] in (pl["content"] as? [Any]) ?? [] {
                        guard let t = c["text"] as? String, t.hasPrefix("<skill>\n<name>"),
                              let close = t.range(of: "</name>") else { continue }
                        let x = t[t.index(t.startIndex, offsetBy: 14)..<close.lowerBound]
                        if !x.isEmpty { skillUse(String(x)) }
                    }
                }
            }
        }
        return e
    }

    /// `rollout-2025-08-31T22-19-32-<uuid>.jsonl`; the oldest format has no per-line timestamp.
    private static func fileNameTime(_ path: String) -> Double {
        let name = (path as NSString).lastPathComponent
        guard name.count >= 27 else { return 0 }
        let stamp = String(name.dropFirst(8).prefix(19))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.date(from: stamp)?.timeIntervalSince1970 ?? 0
    }

    // MARK: - Time

    /// `2026-08-27T05:16:50.093Z` → Unix seconds. Hand-rolled because it runs inside
    /// concurrentPerform and formatters are neither cheap nor meant to be shared across threads.
    static func parseISO(_ s: String) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<a + n {
                let c = Int(u[i]) - 48
                guard c >= 0 && c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return nil }
        var frac = 0.0, scale = 0.1, i = 20
        if u.count > 19 && u[19] == 46 {
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1
        let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + se) + frac
    }
}
