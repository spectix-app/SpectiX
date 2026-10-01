#if DEV_BUILD
import Cocoa
import ApplicationServices

// MARK: - Dev-only accessibility tree probe
//
// Why this exists: a standalone `swift tools/*.swift` script cannot read another app's
// accessibility tree — TCC grants that per binary and only this app holds the grant. So
// any question about "what does VSCode's terminal DOM actually look like" has to be
// answered from inside SpectiX. Reasoning about it from the outside is how the pane
// features got fixed twice on plausible-but-wrong theories.
//
// Usage:  touch ~/.claude/spectix/ax-probe            (marker consumed on the next tick)
//         cat   ~/.claude/spectix/ax-probe.log
//
// Read-only: copies attributes, never sets one. Compiled out of release builds.
enum AXProbe {
    private static let marker = "\(NSHomeDirectory())/.claude/spectix/ax-probe"
    private static let out    = "\(NSHomeDirectory())/.claude/spectix/ax-probe.log"
    private static let queue  = DispatchQueue(label: "spectix.axprobe")
    private static var running = false

    // Cheap when idle: one stat per call.
    static func pollMarker() {
        guard FileManager.default.fileExists(atPath: marker), !running else { return }
        try? FileManager.default.removeItem(atPath: marker)
        running = true
        queue.async {
            let text = dump()
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { running = false }
        }
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> Any? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
    private static func classList(_ el: AXUIElement) -> [String] {
        (attr(el, "AXDOMClassList") as? [String]) ?? []
    }
    private static func s(_ el: AXUIElement, _ n: String) -> String {
        (attr(el, n) as? String) ?? ""
    }
    private static func rect(_ r: CGRect?) -> String {
        guard let r = r else { return "—" }
        return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
    }

    // One line per node: everything that could conceivably distinguish a hidden pane
    // from a visible one, or a tab row from its neighbours.
    private static func line(_ el: AXUIElement, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        var bits = ["\(pad)\(s(el, kAXRoleAttribute))"]
        let cl = classList(el)
        if !cl.isEmpty { bits.append("cls=[\(cl.joined(separator: " "))]") }
        if let id = attr(el, "AXDOMIdentifier") as? String, !id.isEmpty { bits.append("id=\(id)") }
        bits.append("f=\(rect(frame(el)))")
        for a in ["AXHidden", "AXSelected", "AXEnabled", "AXFocused"] {
            if let v = attr(el, a) as? Bool, v { bits.append("\(a)=1") }
        }
        let d = s(el, kAXDescriptionAttribute), t = s(el, kAXTitleAttribute), v = s(el, kAXValueAttribute)
        if !d.isEmpty { bits.append("desc=\(d.prefix(90))") }
        if !t.isEmpty { bits.append("title=\(t.prefix(60))") }
        if !v.isEmpty { bits.append("val=\(v.prefix(40))") }
        return bits.joined(separator: " ")
    }

    private static func subtree(_ el: AXUIElement, depth: Int, cap: Int, into acc: inout [String]) {
        guard depth < 40, acc.count < cap else { return }
        acc.append(line(el, depth: depth))
        guard let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids { subtree(k, depth: depth + 1, cap: cap, into: &acc) }
    }

    private static func findTextareas(_ el: AXUIElement, depth: Int, into acc: inout [AXUIElement]) {
        guard depth < 50 else { return }
        if classList(el).contains(where: { $0.contains("xterm-helper-textarea") }) { acc.append(el) }
        guard let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids { findTextareas(k, depth: depth + 1, into: &acc) }
    }

    private static func dump() -> String {
        var lines: [String] = ["AXProbe \(Date())"]
        let editors = NSWorkspace.shared.runningApplications.filter {
            EditorApp(rawValue: $0.bundleIdentifier ?? "") != nil
        }
        for app in editors {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 8)
            lines.append("\n########## \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")
            guard let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for (i, w) in wins.enumerated() {
                lines.append("\n===== window \(i) title=\(s(w, kAXTitleAttribute)) f=\(rect(frame(w)))")
                var tas: [AXUIElement] = []
                findTextareas(w, depth: 0, into: &tas)
                lines.append("  xterm textareas: \(tas.count)")
                // Per textarea: the ancestor chain, which is where a hidden pane must
                // differ from the visible one if it differs anywhere.
                for (n, ta) in tas.enumerated() {
                    lines.append("\n  --- textarea #\(n) desc=\(s(ta, kAXDescriptionAttribute).prefix(120))")
                    var cur = ta
                    for up in 0..<10 {
                        guard let p = attr(cur, kAXParentAttribute) else { break }
                        cur = p as! AXUIElement
                        lines.append("    up\(up) \(line(cur, depth: 0))")
                    }
                }
                // The terminal part of the workbench, dumped whole: the tab list on the
                // left lives here as a sibling of the panes.
                if let ta = tas.first, let root = terminalPart(from: ta) {
                    lines.append("\n  ----- terminal part subtree")
                    var acc: [String] = []
                    subtree(root, depth: 1, cap: 600, into: &acc)
                    lines.append(contentsOf: acc)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // Walk up from a pane textarea to the workbench panel/part that contains both the
    // panes and the tab list.
    private static func terminalPart(from el: AXUIElement) -> AXUIElement? {
        var cur = el
        var best: AXUIElement?
        for _ in 0..<25 {
            guard let p = attr(cur, kAXParentAttribute) else { break }
            cur = p as! AXUIElement
            let id = s(cur, "AXDOMIdentifier")
            let cl = classList(cur)
            if id.contains("workbench.parts.panel") || id.contains("terminal")
                || cl.contains(where: { $0 == "terminal-outer-container" || $0 == "integrated-terminal" }) {
                best = cur
            }
        }
        return best
    }
}
#endif
