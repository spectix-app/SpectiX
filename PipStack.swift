import CoreGraphics

// Which pane dots of ONE host window are hidden by the tab-stack rule (StatusPip's
// stackedBehind, step ①). Pure geometry, kept out of StatusPip.swift so
// tools/pip-stack-check can pin it without AppKit or AX.
enum PipStack {
    // `panes`: pane rects (AX global) of the pips riding one window; `showing`: the
    // session that window's tab strip marks selected. Returns the pids to hide.
    //
    // Two ways a non-selected pane proves it is not on screen:
    //   • it COINCIDES with another pane of the window — a tab stack, every member
    //     measured at the same rect;
    //   • it OVERLAPS the selected pane's rect without coinciding (T328). Live panes
    //     tile and never overlap, so this is a memo gone stale: an in-window relayout
    //     (panel divider drag, sidebar resize) moved the shown pane, which got
    //     re-measured, while the hidden terminals' memos still vouch for the old rect
    //     because the host window's bounds never changed. Inset by `slop` so split
    //     panes sharing an edge never read as overlapping.
    static func hiddenInWindow(panes: [pid_t: CGRect], showing: pid_t?, slop: CGFloat) -> Set<pid_t> {
        guard let showing = showing else { return [] }
        let shown = panes[showing]?.insetBy(dx: slop, dy: slop)
        var hidden: Set<pid_t> = []
        for (pid, rect) in panes where pid != showing {
            let coincides = panes.contains { other in
                other.key != pid
                    && abs(other.value.minX - rect.minX) < slop
                    && abs(other.value.minY - rect.minY) < slop
            }
            let overlapsShown = shown.map { !$0.isNull && $0.intersects(rect) } ?? false
            if coincides || overlapsShown { hidden.insert(pid) }
        }
        return hidden
    }
}
