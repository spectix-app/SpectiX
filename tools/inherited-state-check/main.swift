import Foundation

var failures = 0
func expect(_ got: String, _ want: String, _ what: String) {
    if got == want { print("ok    \(what)") } else {
        print("FAIL  \(what): got \(got), want \(want)")
        failures += 1
    }
}

let start = 1_000.0
// A fresh codex on a tty whose previous session left any state behind.
for prev in ["done", "working", "needs", "paused"] {
    expect(InheritedState.status(prev, isCodex: true, stateMTime: start - 180, processStart: start),
           "idle", "codex cold start ignores inherited \(prev)")
}
// Written by this codex's own hooks: trusted as-is.
expect(InheritedState.status("working", isCodex: true, stateMTime: start + 5, processStart: start),
       "working", "codex own state kept")
// Process gone / start unknown: never a guess.
expect(InheritedState.status("done", isCodex: true, stateMTime: start - 180, processStart: nil),
       "done", "unknown process start leaves state alone")
// Claude rewrites state on its own SessionStart; this rule must not touch it.
expect(InheritedState.status("done", isCodex: false, stateMTime: start - 180, processStart: start),
       "done", "claude row untouched")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
