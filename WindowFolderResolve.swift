import Foundation

// MARK: - Which project a window title means, when the name alone is ambiguous
//
// A VSCode window title carries the FOLDER NAME, never the path, so resolving it back
// to a real cwd is a lookup against known name→path pairs. Two git worktrees of one
// repo (.../nextad/apps/deal-alarm and .../nextad-wt-deal-alarm/apps/deal-alarm) give
// byte-identical titles, and picking by ranking alone once produced a PHANTOM group:
// the open worktree window resolved to the pinned main-repo path, which has no session,
// so the very window that already had a real group was counted again as an empty one.
//
// This lives outside AppController — and takes everything it needs as arguments — so
// tools/empty-group-check.sh can compile it on its own and assert the six cases below
// without launching the app. The phantom group is invisible to every other record
// (both candidates are legitimate paths and the title looks fine), so a test that can
// run in a second is the only thing that catches a regression here.
//
// ★ With ONE candidate the answer is byte-for-byte the pre-T317 behaviour. Every new
// rule is gated on an ambiguity that could not previously be resolved at all, so this
// cannot turn a correct resolution into a wrong one.
enum WindowFolderResolve {

    // Is `path` inside `dir` (or dir itself)? Component-boundary aware, so /a/web-dash
    // never counts as living under /a/web.
    static func isUnder(_ path: String?, _ dir: String) -> Bool {
        guard let path else { return false }
        return path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// The project this window belongs to, or nil when it must not produce a group.
    ///
    /// - candidates: every known path whose folder name the title could mean, in
    ///   preference order (pinned first, then most-recently-seen, then editor-reported).
    ///   Duplicates are collapsed keeping the first occurrence: one path reaches this
    ///   list from both ProjectHistory and EditorWorkspaces, and a repeat would make an
    ///   unambiguous name look ambiguous.
    /// - doc: the file the window currently shows (its AXDocument), if any.
    /// - activeCwds: projects that already have a live session, hence a real group.
    /// - editorFolders: folders the editor itself reports having open. A HINT only —
    ///   measured 2026-09-15, storage.json listed 8 folders against 6 open windows, so
    ///   membership orders candidates but absence never rejects one.
    /// - taken: projects an earlier window in this pass already claimed.
    static func resolve(candidates: [String],
                        doc: String?,
                        activeCwds: Set<String>,
                        editorFolders: Set<String>,
                        taken: Set<String>) -> String? {
        var seen = Set<String>()
        let cands = candidates.filter { seen.insert($0).inserted }
        guard let first = cands.first else { return nil }

        // Unambiguous: the old path, unchanged. A name with one candidate that is
        // already spoken for simply yields no group, exactly as before.
        guard cands.count > 1 else {
            return (activeCwds.contains(first) || taken.contains(first)) ? nil : first
        }

        // The document is the one window attribute that carries a path, so when it lands
        // under a candidate it settles the question outright — including the case where
        // that candidate turns out to have sessions (this window is that group, and the
        // right answer is to add nothing).
        if let byDoc = cands.first(where: { isUnder(doc, $0) }) {
            return (activeCwds.contains(byDoc) || taken.contains(byDoc)) ? nil : byDoc
        }

        // No document — a webview or welcome-page window, which is exactly how the
        // phantom came back after T267. With one of the candidates already running
        // sessions, this window is overwhelmingly that project's second window rather
        // than a sibling checkout nobody opened. Guessing costs a phantom group;
        // declining costs at most one missing grey header, and this whole feature fails
        // toward fewer rows (same call as the three gates in docs/desktop-app.md).
        if cands.contains(where: { activeCwds.contains($0) }) { return nil }

        // Two same-named windows both open and both sessionless: the first took one path,
        // so this one is the other. Filtering rather than rejecting is what lets the
        // second window resolve at all.
        let free = cands.filter { !taken.contains($0) }
        guard let fallback = free.first else { return nil }
        return free.first(where: { editorFolders.contains($0) }) ?? fallback
    }
}
