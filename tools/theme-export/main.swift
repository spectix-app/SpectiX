// Writes every built-in theme out in theme-file form (ThemeFile.export) — the
// full-key reference docs/themes/*.json is generated from. Re-run after changing
// a built-in theme so the reference cannot drift from the code:
//
//   ./tools/theme-export.sh
//
// Also round-trips each export through ThemeFile.parse, so a key the exporter
// writes but the parser refuses fails here instead of in a user's folder.
import Cocoa

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let builtIns = [ThemeDefault.spec, ThemeClay.spec]

for spec in builtIns {
    let json = ThemeFile.export(spec)
    let data = try JSONSerialization.data(
        withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    _ = try ThemeFile.parse(data, file: "\(spec.id).json", builtIns: builtIns)
    let url = outDir.appendingPathComponent("\(spec.id).json")
    try (data + Data("\n".utf8)).write(to: url)
    print("wrote \(url.path)")
}
