import Foundation

/// ★ T283: Codex defers SessionStart until the FIRST prompt (measured on 0.151.0:
/// `codex exec` logs SessionStart right before UserPromptSubmit; a cold TUI fires no
/// hook at all), so a fresh codex inherits whatever the tty's previous session left in
/// state-<tty>. The hook can't fix this — it never runs. A state written before this
/// process existed can't be its own, so it reads as 闲置. Claude fires SessionStart at
/// launch and rewrites the file itself, so it is left alone.
/// Pinned by tools/inherited-state-check.sh.
enum InheritedState {
    static func status(_ raw: String, isCodex: Bool, stateMTime: Double,
                       processStart: Double?) -> String {
        guard isCodex, let started = processStart, stateMTime < started else { return raw }
        return "idle"
    }
}
