import Foundation

enum CatalogTool: String { case claude, codex }
enum CatalogKind: String { case skill, agent }

enum CatalogOrigin: Equatable {
    case user
    case plugin(String)
    case project(String)
    case system
    case builtin
    case missing
}

struct CatalogItem {
    let tool: CatalogTool
    let kind: CatalogKind
    let name: String
    let description: String
    let path: String?
    let origin: CatalogOrigin
    let model: String?
    var uses: Int
    var lastUsed: Date?

    var key: String { "\(tool.rawValue).\(kind.rawValue).\(name)" }
    var id: String {
        if case .project(let p) = origin { return key + "@" + p }
        return key
    }
}

enum SkillCatalog {
    static let builtinClaudeSkills = [
        "update-config", "claude-in-chrome", "run", "claude-api", "simplify", "code-review", "loop",
        "schedule", "init", "security-review", "fewer-permission-prompts", "keybindings-help",
    ]
    static let builtinClaudeAgents = ["general-purpose", "Explore", "Plan", "claude-code-guide", "statusline-setup", "fork"]

    // Serial so two overlapping loads can't race on the usage cache file.
    private static let queue = DispatchQueue(label: "SpectiX.SkillCatalog", qos: .utility)

    /// Full rebuild: definitions + incremental usage scan. Sorted by uses desc, then name. completion on main.
    static func load(projectRoots: [String], completion: @escaping ([CatalogItem]) -> Void) {
        queue.async {
            let items = build(projectRoots: projectRoots)
            DispatchQueue.main.async { completion(items) }
        }
    }

    private static func build(projectRoots: [String]) -> [CatalogItem] {
        var items = definitions(projectRoots: projectRoots)
        let usage = SkillUsage.scan()

        var claudeSkillNames = Set(builtinClaudeSkills)
        for it in items where it.tool == .claude && it.kind == .skill { claudeSkillNames.insert(it.name) }
        var totals: [String: UsageStat] = [:]
        for (k, s) in usage {
            if k.hasPrefix("claude.typed.") {
                let name = String(k.dropFirst("claude.typed.".count))
                // Typed /usage, /clear, /model… are CLI commands, not skills; filtered here rather than
                // at scan time so a skill installed later picks up its past typed uses without a rescan.
                if claudeSkillNames.contains(name) { totals["claude.skill." + name, default: UsageStat()].merge(s) }
            } else {
                totals[k, default: UsageStat()].merge(s)
            }
        }

        // A used name maps to one item: user/plugin/system before project copies, then by dir name,
        // since Codex usage is inferred from a SKILL.md path and some frontmatter names differ from the dir.
        func rank(_ o: CatalogOrigin) -> Int {
            switch o { case .user: 0; case .plugin: 1; case .system: 2; case .project: 3; default: 4 }
        }
        var byKey: [String: Int] = [:]
        var byDir: [String: Int] = [:]
        for i in items.indices.sorted(by: { rank(items[$0].origin) < rank(items[$1].origin) }) {
            let it = items[i]
            if byKey[it.key] == nil { byKey[it.key] = i }
            if it.kind == .skill, let p = it.path {
                let dir = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let k = "\(it.tool.rawValue).skill.\(dir)"
                if byDir[k] == nil { byDir[k] = i }
            }
        }

        let builtins: Set<String> = Set(builtinClaudeSkills.map { "claude.skill." + $0 } + builtinClaudeAgents.map { "claude.agent." + $0 })
        for (k, s) in totals where s.n > 0 {
            let date = s.t > 0 ? Date(timeIntervalSince1970: s.t) : nil
            if let i = byKey[k] ?? byDir[k] {
                items[i].uses += s.n
                if let d = date, d > (items[i].lastUsed ?? .distantPast) { items[i].lastUsed = d }
                continue
            }
            let parts = k.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.count == 3, let tool = CatalogTool(rawValue: parts[0]), let kind = CatalogKind(rawValue: parts[1]) else { continue }
            items.append(CatalogItem(tool: tool, kind: kind, name: parts[2], description: "", path: nil,
                                     origin: builtins.contains(k) ? .builtin : .missing, model: nil,
                                     uses: s.n, lastUsed: date))
        }

        return items.sorted {
            $0.uses != $1.uses ? $0.uses > $1.uses : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Definitions

    private static func definitions(projectRoots: [String]) -> [CatalogItem] {
        let home = NSHomeDirectory()
        var out: [CatalogItem] = []
        var seen = Set<String>()
        func add(_ it: CatalogItem) { if seen.insert(it.id).inserted { out.append(it) } }

        for (path, fm) in skillFiles(in: home + "/.claude/skills") { add(skill(.claude, path, fm, .user)) }
        claudePlugins(home: home, add: add)
        for f in files(in: home + "/.claude/agents", ext: "md") {
            let fm = frontmatter(f)
            guard let name = fm["name"], !name.isEmpty else { continue }
            add(CatalogItem(tool: .claude, kind: .agent, name: name, description: fm["description"] ?? "",
                            path: f, origin: .user, model: fm["model"], uses: 0, lastUsed: nil))
        }

        for (path, fm) in skillFiles(in: home + "/.agents/skills") { add(skill(.codex, path, fm, .user)) }
        for (path, fm) in skillFiles(in: home + "/.codex/skills/.system") { add(skill(.codex, path, fm, .system)) }
        for f in files(in: home + "/.codex/agents", ext: "toml") {
            let kv = tomlTopLevel(f)
            guard let name = kv["name"], !name.isEmpty else { continue }
            add(CatalogItem(tool: .codex, kind: .agent, name: name, description: collapse(kv["description"] ?? ""),
                            path: f, origin: .user, model: kv["model"], uses: 0, lastUsed: nil))
        }

        // Home is often a "project" too (a session started in ~), and ~/.agents/skills is
        // exactly the Codex user-skill folder — without this every Codex skill shows twice.
        let homeStd = (home as NSString).standardizingPath
        for root in Set(projectRoots.map { ($0 as NSString).standardizingPath }).sorted() where root != homeStd {
            let proj = (root as NSString).lastPathComponent
            for (path, fm) in skillFiles(in: root + "/.claude/skills") { add(skill(.claude, path, fm, .project(proj))) }
            for (path, fm) in skillFiles(in: root + "/.agents/skills") { add(skill(.codex, path, fm, .project(proj))) }
        }
        return out
    }

    private static func skill(_ tool: CatalogTool, _ path: String, _ fm: [String: String],
                              _ origin: CatalogOrigin, prefix: String? = nil) -> CatalogItem {
        let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let base = fm["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dir
        return CatalogItem(tool: tool, kind: .skill, name: prefix.map { "\($0):\(base)" } ?? base,
                           description: fm["description"] ?? "", path: path, origin: origin,
                           model: nil, uses: 0, lastUsed: nil)
    }

    private static func claudePlugins(home: String, add: (CatalogItem) -> Void) {
        let base = home + "/.claude/plugins"
        guard let installed = readJSON(base + "/installed_plugins.json")?["plugins"] as? [String: Any],
              let enabled = readJSON(home + "/.claude/settings.json")?["enabledPlugins"] as? [String: Any] else { return }
        for key in installed.keys.sorted() where enabled[key] as? Bool == true {
            guard let install = (installed[key] as? [[String: Any]])?.first?["installPath"] as? String else { continue }
            let at = key.split(separator: "@", maxSplits: 1).map(String.init)
            guard at.count == 2 else { continue }
            let (plugin, market) = (at[0], at[1])
            let prefix = readJSON(install + "/.claude-plugin/plugin.json")?["name"] as? String ?? plugin

            // Monorepo marketplaces install the whole repo for every plugin, so globbing skills/ would
            // list each skill once per plugin; the marketplace manifest says which ones this plugin owns.
            let declared = ((readJSON(base + "/marketplaces/\(market)/.claude-plugin/marketplace.json")?["plugins"] as? [[String: Any]])?
                .first { $0["name"] as? String == plugin }?["skills"]) as? [String]
            let skillPaths: [String]
            if let declared {
                skillPaths = declared.map { install + "/" + ($0.hasPrefix("./") ? String($0.dropFirst(2)) : $0) + "/SKILL.md" }
                    .filter { FileManager.default.fileExists(atPath: $0) }
            } else {
                skillPaths = skillFiles(in: install + "/skills").map(\.0)
            }
            for p in skillPaths { add(skill(.claude, p, frontmatter(p), .plugin(plugin), prefix: prefix)) }

            for f in files(in: install + "/agents", ext: "md") {
                let fm = frontmatter(f)
                let name = fm["name"].flatMap { $0.isEmpty ? nil : $0 } ?? ((f as NSString).lastPathComponent as NSString).deletingPathExtension
                add(CatalogItem(tool: .claude, kind: .agent, name: "\(prefix):\(name)", description: fm["description"] ?? "",
                                path: f, origin: .plugin(plugin), model: fm["model"], uses: 0, lastUsed: nil))
            }
        }
    }

    // MARK: - File helpers

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func files(in dir: String, ext: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            .filter { ($0 as NSString).pathExtension == ext }.map { dir + "/" + $0 }
    }

    private static func skillFiles(in dir: String) -> [(String, [String: String])] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().compactMap { entry in
            let p = dir + "/" + entry + "/SKILL.md"
            return FileManager.default.fileExists(atPath: p) ? (p, frontmatter(p)) : nil
        }
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Top-level scalar keys of a YAML frontmatter block. Indented lines after a key are its
    /// continuation, which covers `>` / `|` blocks and plain multi-line scalars alike.
    static func frontmatter(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var key: String?
        var parts: [String] = []
        func flush() {
            guard let k = key else { return }
            var v = collapse(parts.joined(separator: " "))
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(where: { v.hasPrefix($0 + " ") || v == $0 }) {
                v = collapse(String(v.drop(while: { !$0.isWhitespace })))
            } else if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
                v = String(v.dropFirst().dropLast())
                v = q == "'" ? v.replacingOccurrences(of: "''", with: "'")
                             : v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            out[k] = v
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let c = line.first, c == " " || c == "\t" || line.isEmpty {
                if key != nil { parts.append(line) }
                continue
            }
            flush()
            key = nil
            parts = []
            guard let colon = line.firstIndex(of: ":") else { continue }
            key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            parts = [String(line[line.index(after: colon)...])]
        }
        flush()
        return out
    }

    /// Top-level `key = "value"` pairs; skips over multi-line `"""`/`'''` strings so their
    /// contents (agent instructions often contain `name = ...` lines) are never read as keys.
    static func tomlTopLevel(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        var inMulti: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let delim = inMulti {
                if line.contains(delim) { inMulti = nil }
                continue
            }
            if line.hasPrefix("[") { break }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let delim = ["\"\"\"", "'''"].first(where: { v.hasPrefix($0) }) {
                if !v.dropFirst(3).contains(delim) { inMulti = delim }
                continue
            }
            if v.hasPrefix("\""), let end = closingQuote(v) {
                out[k] = String(v[v.index(after: v.startIndex)..<end])
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else if v.hasPrefix("'"), let end = v.dropFirst().firstIndex(of: "'") {
                out[k] = String(v[v.index(after: v.startIndex)..<end])
            }
        }
        return out
    }

    private static func closingQuote(_ v: String) -> String.Index? {
        var i = v.index(after: v.startIndex)
        while i < v.endIndex {
            if v[i] == "\\" { i = v.index(after: i); if i < v.endIndex { i = v.index(after: i) }; continue }
            if v[i] == "\"" { return i }
            i = v.index(after: i)
        }
        return nil
    }
}
