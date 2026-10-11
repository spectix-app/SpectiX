// Pins ContextWindow.isOneMillion: which model ids read as a 1M window.
// Exits 1 on any failed case.
import Foundation

let cases: [(String, Bool)] = [
    // Native 1M — no suffix ever appears on these.
    ("claude-fable-5", true),
    ("claude-fable-5-1", true),
    ("claude-mythos-5", true),
    ("claude-opus-5-5", true),
    // Models this build has never heard of must not fall back to 200k.
    ("claude-sonnet-5-5", true),
    ("claude-opus-6", true),
    ("claude-newfamily-7-2", true),
    // 1M-beta tier.
    ("claude-opus-5[1m]", true),
    ("claude-opus-4-8[1m]", true),
    // 200k.
    ("claude-opus-5", false),
    ("claude-sonnet-5", false),
    ("claude-opus-4-8", false),
    ("claude-haiku-4-5-20251001", false),
    ("claude-haiku-5-5", false),
    ("claude-3-5-sonnet-20241022", false),
    ("<synthetic>", false),
    ("gpt-5.6-sol", false),
    ("", false),
]

var failed = 0
for (id, want) in cases {
    let got = ContextWindow.isOneMillion(id)
    if got != want {
        print("FAIL \(id): got \(got), want \(want)")
        failed += 1
    }
}
print(failed == 0 ? "context-window-check: \(cases.count) cases OK" : "context-window-check: \(failed) failed")
exit(failed == 0 ? 0 : 1)
