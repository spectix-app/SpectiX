import Foundation

// Build: swiftc -O SkillCatalog.swift SkillUsage.swift tools/skill-usage-probe/main.swift -o /tmp/skillprobe
// Usage: skillprobe [--cold] [--dump]   (--dump prints every item as TSV)

let args = CommandLine.arguments
let projectsDir = NSHomeDirectory() + "/Projects"
let fm = FileManager.default
let roots = ((try? fm.contentsOfDirectory(atPath: projectsDir)) ?? []).sorted().map { projectsDir + "/" + $0 }
    .filter { fm.fileExists(atPath: $0 + "/.claude") || fm.fileExists(atPath: $0 + "/.agents") }

func runLoad() -> ([CatalogItem], Double) {
    let start = Date()
    var result: [CatalogItem]?
    SkillCatalog.load(projectRoots: roots) { result = $0 }
    while result == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    return (result!, Date().timeIntervalSince(start))
}

func originLabel(_ o: CatalogOrigin) -> String {
    switch o {
    case .user: return "user"
    case .plugin(let p): return "plugin(\(p))"
    case .project(let p): return "project(\(p))"
    case .system: return "system"
    case .builtin: return "builtin"
    case .missing: return "missing"
    }
}

let iso = ISO8601DateFormatter()
func day(_ d: Date?) -> String { d.map { String(iso.string(from: $0).prefix(10)) } ?? "-" }

if args.contains("--cold") { try? fm.removeItem(at: SkillUsage.cacheURL) }
let (items, first) = runLoad()
let (_, second) = runLoad()

print("project roots: \(roots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
print(String(format: "first scan (%@): %.2fs   warm rescan: %.2fs", args.contains("--cold") ? "cold" : "as-is", first, second))

var groups: [String: Int] = [:]
for it in items { groups["\(it.tool.rawValue)\t\(it.kind.rawValue)\t\(originLabel(it.origin))", default: 0] += 1 }
print("\n== items per tool/kind/origin (total \(items.count))")
for (k, n) in groups.sorted(by: { $0.key < $1.key }) { print("\(n)\t\(k)") }

let ids = items.map(\.id)
let dup = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys
print("\nduplicate ids: \(dup.isEmpty ? "none" : dup.sorted().joined(separator: ", "))")

for tool in [CatalogTool.claude, .codex] {
    for kind in [CatalogKind.skill, .agent] {
        let sel = items.filter { $0.tool == tool && $0.kind == kind && $0.uses > 0 }
        print("\n== top 20 \(tool.rawValue) \(kind.rawValue) (used: \(sel.count), total uses: \(sel.reduce(0) { $0 + $1.uses }))")
        for it in sel.prefix(20) { print("\(it.uses)\t\(it.name)\t\(day(it.lastUsed))\t\(originLabel(it.origin))") }
    }
}

print("\n== builtin / missing")
for it in items where it.origin == .builtin || it.origin == .missing {
    print("\(it.tool.rawValue).\(it.kind.rawValue)\t\(it.name)\t\(it.uses)\t\(originLabel(it.origin))")
}

if args.contains("--dump") {
    print("\n== dump")
    for it in items {
        print([it.id, originLabel(it.origin), String(it.uses), day(it.lastUsed), it.model ?? "", it.path ?? "", it.description].joined(separator: "\t"))
    }
}
