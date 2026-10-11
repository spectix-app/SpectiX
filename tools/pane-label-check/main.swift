import Foundation

var failures = 0
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got == want { print("ok    \(what)") } else {
        print("FAIL  \(what): got \(got), want \(want)")
        failures += 1
    }
}

let names: [String: Int] = ["Claude Code": 1, "jx 0270": 2, "jx 0270 fix": 3, "zsh": 4]
func paneKey(_ desc: String) -> String? {
    PaneLabel.pane(desc).flatMap { PaneLabel.key(for: $0.label, in: names) }
}

// The two wordings VSCode has shipped.
expect(paneKey("终端 3，✳ Claude Code 运行命令"), "Claude Code", "zh tail")
expect(PaneLabel.pane("终端 3，✳ Claude Code 运行命令")?.index, 3, "zh index")
expect(paneKey("Terminal 5, jx 0270 fix run command"), "jx 0270 fix", "old en tail")
expect(paneKey("Terminal 5, jx 0270 Run the command: Toggle Screen Reader Accessibility Mode"),
       "jx 0270", "2026-08 en tail")
// Wordings it has not shipped (yet): the name must still come out.
expect(paneKey("Terminal 7, zsh Press Alt+F1 for accessibility help"), "zsh", "novel en tail")
expect(PaneLabel.pane("Terminal 7, zsh Press Alt+F1 for accessibility help")?.index, 7, "novel index")
expect(paneKey("ターミナル 2、✳ Claude Code ナントカ"), nil, "no recognised anchor comma")
expect(paneKey("终端 4，⠂ jx 0270 fix 按 Alt+F1 获取帮助"), "jx 0270 fix", "novel zh tail, longest name")
expect(paneKey("Terminal 1, zsh"), "zsh", "no tail at all")
// Never a guess.
expect(paneKey("Terminal 2, zshrc edit run command"), nil, "word boundary")
expect(paneKey("Terminal 2, other run command"), nil, "unknown name")
expect(paneKey("Terminal 2, "), nil, "empty label")
// Tab-strip rows.
expect(PaneLabel.tabRow("Terminal 5 ◐ jx 0270").flatMap { PaneLabel.key(for: $0.label, in: names) },
       "jx 0270", "tab row")
expect(PaneLabel.tabRow("终端5 ✳ Claude Code")?.index, 5, "tab row zh index")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all pane-label cases pass")
