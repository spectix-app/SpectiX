import Foundation

// Whether a model id runs with a 1M context window (vs the 200k default).
//
// ~/.claude.json's lastModelUsage keys and transcript ids carry no window field, so it
// has to be read off the id. Two shapes mean 1M:
//   - a "[1m]" suffix — the Sonnet/Opus 1M-BETA tier (only .claude.json keys carry it)
//   - a natively-1M model, whose id carries no suffix at all
//
// ★ The native case is decided by listing what is 200k, not what is 1M. The 200k set
// is closed history — Haiku, every pre-5 generation, and the bare Opus 5 / Sonnet 5 ids
// (that generation reached 1M only through the beta tier, seen here as
// "claude-opus-5[1m]") — while every model released since is native 1M. The old
// allow-list ("fable-5", "mythos-5", "opus-5-5") had to be patched for each launch and
// read every unlisted new model as 200k, inflating its % ~5x until someone noticed.
enum ContextWindow {
    static func isOneMillion(_ modelId: String) -> Bool {
        var s = modelId.lowercased()
        if s.contains("[1m]") { return true }
        guard s.hasPrefix("claude-") else { return false }   // "<synthetic>", Codex ids
        s = String(s.dropFirst("claude-".count))
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first(where: { Int($0) == nil }) else { return false }
        let version = parts.compactMap { Int($0) }
        guard let major = version.first else { return false }
        let minor = version.count > 1 ? version[1] : 0
        if family == "haiku" || major < 5 { return false }
        if major == 5, minor == 0, family == "opus" || family == "sonnet" { return false }
        return true
    }
}
