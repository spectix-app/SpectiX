import Foundation

var failures = 0
func expect(_ got: Set<pid_t>, _ want: Set<pid_t>, _ what: String) {
    if got == want { print("ok    \(what)") } else {
        print("FAIL  \(what): got \(got.sorted()), want \(want.sorted())")
        failures += 1
    }
}
func hidden(_ panes: [pid_t: CGRect], _ showing: pid_t?) -> Set<pid_t> {
    PipStack.hiddenInWindow(panes: panes, showing: showing, slop: 16)
}

// Bottom panel, terminal tabs: three sessions measured at the same rect, 101 shown.
let panel = CGRect(x: 300, y: 700, width: 900, height: 300)
expect(hidden([101: panel, 102: panel, 103: panel], 101), [102, 103], "tab stack hides the unselected")

// T328: divider dragged up 200pt. The shown pane was re-measured; the hidden tabs'
// memos still vouch for the old rect (host bounds unchanged). They no longer coincide
// with the shown pane but still overlap it — must stay hidden, not show as orphans.
let taller = CGRect(x: 300, y: 500, width: 900, height: 500)
expect(hidden([101: taller, 102: panel, 103: panel], 101), [102, 103], "stale memo after divider drag")

// Divider dragged down: the stale rects are now TALLER than the shown pane.
let shorter = CGRect(x: 300, y: 850, width: 900, height: 150)
expect(hidden([101: shorter, 102: panel], 101), [102], "stale memo after panel shrinks")

// Sidebar resized: everything shifts right by 120pt.
let shifted = panel.offsetBy(dx: 120, dy: 0)
expect(hidden([101: shifted, 102: panel], 101), [102], "stale memo after sidebar resize")

// Splits: two panes side by side sharing an edge, only one row selected. Both are on
// screen — neither may be hidden.
let left = CGRect(x: 300, y: 700, width: 450, height: 300)
let right = CGRect(x: 750, y: 700, width: 450, height: 300)
expect(hidden([101: left, 102: right], 101), [], "split panes both visible")
expect(hidden([101: left, 102: right, 103: left], 101), [103], "tab stacked behind the shown split half")

// No selected row known: no opinion.
expect(hidden([101: panel, 102: panel], nil), [], "no selection, no opinion")
// Selected session owns no pane dot (unresolvable name): coincidence still decides.
expect(hidden([102: panel, 103: panel], 101), [102, 103], "selected has no dot")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all pip-stack cases pass")
