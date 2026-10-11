import Foundation

// VSCode's accessibility label for a terminal pane / tab row, and the match from it to
// the extension manifest's terminal names. Foundation-only so that
// tools/pane-label-check.sh can compile it on its own and pin the parse down.
enum PaneLabel {
    /// What VSCode's label says a pane IS. Both halves matter and the number is NOT
    /// decoration — see FocusRing's paneIdentityCache for why the name alone is not an
    /// identity.
    struct Identity: Equatable {
        /// The "终端 N" number = VSCode's terminal instanceId. Unique within its window
        /// and stable for that terminal's whole life. nil when the label carries no
        /// number (unknown locale / older VSCode).
        let index: Int?
        /// Everything after the number: the tab name, possibly followed by whatever
        /// sentence VSCode appends. Only ever read through key(for:in:).
        let label: String
    }

    // ★ Never parse the tail of a pane label (改这里前必读). The pane's AXDescription is
    // "终端 N，<title> 运行命令" / "Terminal N, <title> run command" — and VSCode rewrites
    // that tail without notice: by 2026-08 it read "<title> Run the command: Toggle
    // Screen Reader Accessibility Mode …", the old " run command" parser returned nil for
    // every pane, and rings, pips and pane-level jump all silently degraded to "only the
    // pane you just clicked is known" (deep sweep: 8 panes found, 0 named). So the label
    // is cut only at the number's comma, and where the title ends is decided by the
    // manifest names in key(for:in:) — the one thing that cannot drift with VSCode.
    static func pane(_ desc: String) -> Identity? {
        var head = desc
        var index: Int?
        if let comma = head.range(of: "，") ?? head.range(of: ", ") {
            let digits = head[head.startIndex..<comma.lowerBound]
                .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            index = Int(digits)
            head = String(head[comma.upperBound...])
        }
        let label = head.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : Identity(index: index, label: label)
    }

    // "Terminal 5 ◐ jx 0270 …" / "终端 5 ◐ …" — a tab-strip row's description. Same two
    // halves as a pane's, but no comma after the number, so it gets its own anchor.
    static func tabRow(_ desc: String) -> Identity? {
        let t = desc.trimmingCharacters(in: .whitespaces)
        for prefix in ["Terminal ", "终端 ", "终端"] {
            guard t.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            var rest = String(t.dropFirst(prefix.count))
            let digits = rest.prefix(while: { $0.isNumber })
            guard let index = Int(digits) else { continue }
            rest = String(rest.dropFirst(digits.count))
            if rest.hasPrefix("，") || rest.hasPrefix(",") { rest.removeFirst() }
            let label = rest.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : Identity(index: index, label: label)
        }
        return nil
    }

    // The manifest name a label carries: the whole label when it is one, else the
    // LONGEST name the label starts with, ending on a word boundary. Longest so
    // "jx 0270 fix" is not read as its sibling "jx 0270"; boundary so "zshrc" is not "zsh".
    static func key<V>(for label: String, in names: [String: V]) -> String? {
        let t = normalize(label)
        if names[t] != nil { return t }
        var best: String?
        for name in names.keys where !name.isEmpty && name.count > (best?.count ?? 0)
                                     && t.hasPrefix(name) {
            if t.dropFirst(name.count).first?.isWhitespace == true { best = name }
        }
        return best
    }

    // Canonical form for matching pane titles to manifest names: trim, then drop a
    // single leading status glyph (spinner ⠂…, ✳ etc. — any leading char that's
    // neither alphanumeric nor CJK).
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let first = t.unicodeScalars.first,
           !CharacterSet.alphanumerics.contains(first), !isCJK(first) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func isCJK(_ u: UnicodeScalar) -> Bool {
        switch u.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F,
             0xFF00...0xFFEF, 0x2E80...0x2EFF: return true
        default: return false
        }
    }
}
