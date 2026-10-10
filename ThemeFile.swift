import Cocoa

// MARK: - Theme files
//
// A theme can also come from a JSON file dropped into ~/.claude/spectix/themes/
// (format and examples: docs/themes.md). A file never builds a theme from scratch:
// it names a built-in `base` and overrides colors and corner radii on top of it.
// Material, shadows, pill and tint style always come from the base — they are
// behaviour, not values (see the ThemeSpec.swift header), and spacing is not
// themeable at all, so no file can change how much fits on screen.
//
// An unknown key REJECTS the whole file instead of being skipped: a misspelt key
// that silently does nothing is the worst possible authoring experience.
//
// This file must not depend on Theme.swift or L(): tools/theme-export compiles it
// together with ThemeSpec + the built-in themes only.

enum ThemeFile {

    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/spectix/themes", isDirectory: true)

    struct Failure: Error {
        let file: String
        let reason: String
    }

    // MARK: Key tables — one list drives both parsing and tools/theme-export

    static let paletteKeys: [(String, WritableKeyPath<ThemePalette, NSColor>)] = [
        ("baseFill", \.baseFill), ("cardFill", \.cardFill), ("cardFillHover", \.cardFillHover),
        ("cardFloat", \.cardFloat), ("hairline", \.hairline), ("hairlineHover", \.hairlineHover),
        ("divider", \.divider), ("barTrack", \.barTrack),
        ("agentAccent", \.agentAccent), ("agentDeep", \.agentDeep),
        ("agentManagerAccent", \.agentManagerAccent), ("agentNeutralAccent", \.agentNeutralAccent),
        ("shellTagAccent", \.shellTagAccent), ("agentSegmentFill", \.agentSegmentFill),
        ("agentSeam", \.agentSeam), ("proAccent", \.proAccent),
        ("claudeOrange", \.claudeOrange), ("usageGreen", \.usageGreen),
        ("modelOpus", \.modelOpus), ("modelSonnet", \.modelSonnet), ("modelHaiku", \.modelHaiku),
    ]

    static let statusKeys: [(String, WritableKeyPath<ThemeStatusPalette, NSColor>)] = [
        ("needs", \.needs), ("working", \.working), ("checking", \.checking),
        ("paused", \.paused), ("await", \.`await`), ("done", \.done), ("idle", \.idle),
        ("needsFill", \.needsFill), ("workingFill", \.workingFill), ("checkingFill", \.checkingFill),
        ("pausedFill", \.pausedFill), ("awaitFill", \.awaitFill), ("doneFill", \.doneFill),
        ("idleFill", \.idleFill),
    ]

    static let metricKeys: [(String, WritableKeyPath<ThemeMetrics, CGFloat>)] = [
        ("card", \.card), ("group", \.group), ("chip", \.chip),
        ("windowRadius", \.windowRadius), ("popoverRadius", \.popoverRadius),
    ]

    private static let topKeys: Set<String> = [
        "id", "name", "nameZH", "description", "descriptionZH", "base",
        "palette", "status", "metrics",
    ]

    // MARK: Loading

    /// Every valid file theme (sorted by filename) and every file that was refused.
    static func loadAll(builtIns: [ThemeSpec]) -> (themes: [ThemeSpec], failures: [Failure]) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var themes: [ThemeSpec] = []
        var failures: [Failure] = []
        for url in urls.filter({ $0.pathExtension.lowercased() == "json" })
                       .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            do {
                let spec = try parse(try Data(contentsOf: url), file: name, builtIns: builtIns)
                if themes.contains(where: { $0.id == spec.id }) {
                    throw Failure(file: name, reason: "id \"\(spec.id)\" is already used by another file")
                }
                themes.append(spec)
            } catch let f as Failure {
                failures.append(f)
            } catch {
                failures.append(Failure(file: name, reason: error.localizedDescription))
            }
        }
        return (themes, failures)
    }

    static func parse(_ data: Data, file: String, builtIns: [ThemeSpec]) throws -> ThemeSpec {
        func fail(_ reason: String) -> Failure { Failure(file: file, reason: reason) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("the top level must be a JSON object")
        }
        if let bad = Set(json.keys).subtracting(topKeys).sorted().first {
            throw fail("unknown key \"\(bad)\"")
        }

        guard let id = json["id"] as? String,
              !id.isEmpty, id.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" })
        else { throw fail("\"id\" must be lowercase letters, digits and dashes") }
        if builtIns.contains(where: { $0.id == id }) {
            throw fail("id \"\(id)\" belongs to a built-in theme")
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            throw fail("\"name\" is required")
        }

        let baseID = json["base"] ?? builtIns[0].id
        guard let base = builtIns.first(where: { $0.id == baseID as? String }) else {
            throw fail("\"base\" must be one of: " + builtIns.map(\.id).joined(separator: ", "))
        }

        var palette = base.palette
        try overlay(json["palette"], section: "palette", keys: paletteKeys, onto: &palette, fail: fail) {
            color($0)
        }
        var status = base.status
        try overlay(json["status"], section: "status", keys: statusKeys, onto: &status, fail: fail) {
            color($0)
        }
        var metrics = base.metrics
        try overlay(json["metrics"], section: "metrics", keys: metricKeys, onto: &metrics, fail: fail) {
            // JSON true/false also arrive as NSNumber.
            guard let n = $0 as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  (0...40).contains(n.doubleValue) else { return nil }
            return CGFloat(n.doubleValue)
        }

        let description = json["description"] as? String ?? ""
        return ThemeSpec(
            id: id,
            nameZH: json["nameZH"] as? String ?? name,
            nameEN: name,
            blurbZH: json["descriptionZH"] as? String ?? description,
            blurbEN: description,
            material: base.material,
            surface: base.surface,
            pillStyle: base.pillStyle,
            tintStyle: base.tintStyle,
            palette: palette,
            metrics: metrics,
            status: status,
            weights: base.weights,
            band: base.band)
    }

    private static func overlay<Group, Value>(
        _ raw: Any?, section: String,
        keys: [(String, WritableKeyPath<Group, Value>)],
        onto group: inout Group,
        fail: (String) -> Failure,
        value: (Any) -> Value?
    ) throws {
        guard let raw else { return }
        guard let dict = raw as? [String: Any] else { throw fail("\"\(section)\" must be an object") }
        for (key, v) in dict {
            guard let path = keys.first(where: { $0.0 == key })?.1 else {
                throw fail("unknown key \"\(section).\(key)\"")
            }
            guard let parsed = value(v) else {
                throw fail("bad value for \"\(section).\(key)\"")
            }
            group[keyPath: path] = parsed
        }
    }

    // MARK: Colors

    /// "#RRGGBB", "#RRGGBBAA", or {"light": …, "dark": …} with either form inside.
    static func color(_ v: Any) -> NSColor? {
        if let s = v as? String { return hex(s) }
        guard let d = v as? [String: Any], Set(d.keys) == ["light", "dark"],
              let light = (d["light"] as? String).flatMap(hex),
              let dark = (d["dark"] as? String).flatMap(hex) else { return nil }
        return themePick(dark: dark, light: light)
    }

    private static func hex(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        // isHexDigit first: UInt64(_:radix:) would also accept a leading "+".
        guard h.count == 6 || h.count == 8, h.allSatisfy(\.isHexDigit),
              let v = UInt64(h, radix: 16) else { return nil }
        let rgba = h.count == 6 ? (v << 8) | 0xFF : v
        func c(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: c(24), green: c(16), blue: c(8), alpha: c(0))
    }

    // MARK: Export (tools/theme-export)

    /// A built-in theme written out in file form, every key spelled out — the
    /// reference an author copies from. Material and shadows are not exported:
    /// a file inherits them through `base`.
    static func export(_ spec: ThemeSpec) -> [String: Any] {
        func colors<G>(_ group: G, _ keys: [(String, WritableKeyPath<G, NSColor>)]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: keys.map { ($0.0, encode(group[keyPath: $0.1])) })
        }
        return [
            "id": spec.id + "-copy",
            "name": spec.nameEN + " (copy)",
            "nameZH": spec.nameZH + "（副本）",
            "description": spec.blurbEN,
            "descriptionZH": spec.blurbZH,
            "base": spec.id,
            "palette": colors(spec.palette, paletteKeys),
            "status": colors(spec.status, statusKeys),
            "metrics": Dictionary(uniqueKeysWithValues: metricKeys.map {
                ($0.0, Double(spec.metrics[keyPath: $0.1]))
            }),
        ]
    }

    private static func encode(_ color: NSColor) -> Any {
        func resolved(_ name: NSAppearance.Name) -> String {
            var out = ""
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                let parts = [c.redComponent, c.greenComponent, c.blueComponent]
                    .map { String(format: "%02X", Int(($0 * 255).rounded())) }
                out = "#" + parts.joined()
                if c.alphaComponent < 1 {
                    out += String(format: "%02X", Int((c.alphaComponent * 255).rounded()))
                }
            }
            return out
        }
        let light = resolved(.aqua), dark = resolved(.darkAqua)
        return light == dark ? light : ["light": light, "dark": dark]
    }
}
