import Cocoa

// MARK: - Settings live preview (design/settings-live-preview.html 方案 3)
//
// A single card pinned at the top of Settings' 显示 section showing a REAL session
// list — three fixed mock sessions rendered by the very same `ChildCell` the main
// window uses. Every display toggle below it acts on this card, so it always shows
// all settings COMBINED (the reason 方案 3 won over the per-row thumbnails: four
// switches make 24 combinations, and only a shared panel can show one of them).
//
// After a setting changes, the element that setting controls flashes a blue ring —
// that's what pays for the eye travel between a switch and the card up top. The
// mapping lives in ChildCell.previewFlashTarget(for:); the notification carries
// which setting moved as AppSettings.DisplayKey.

// The three mock sessions: one per status that carries usage (运行中 / 需确认 / 完成).
// Fixed data, never live — the point is a stable stage the settings act on. Numbers
// are self-consistent the way a real row is: the ◆ figure IS the context occupancy
// the % is computed from (see UsageMetricsView.usageText / SessionRow.ctxPct).
enum PreviewSessions {
    static var all: [SessionRow] {
        [
            row(tty: "preview-working", status: "working",
                folder: "SpectiX",
                title: L("给设置项加所见即所得预览", "Add live preview to settings"),
                seq: 1, workSec: 12 * 60, ctxTokens: 124_000, model: "Opus 5",
                // A Bash step on purpose: 当前步骤 is the setting people come here to turn
                // off, and this is the shape they recognise it by.
                step: "Bash · git push"),
            row(tty: "preview-needs", status: "needs",
                folder: "deal-alarm",
                title: L("抓取脚本改成增量模式", "Make the crawler incremental"),
                seq: 2, workSec: 4 * 60, ctxTokens: 36_000, model: "Sonnet 5"),
            // One live background shell: the 等待 row (T312) — hollow dot and the
            // "N 个 shell 运行中" subtitle, so the fifth status is in the preview.
            row(tty: "preview-await", status: "await",
                folder: "landing",
                title: L("landing page 文案改版", "Rewrite the landing copy"),
                seq: 3, workSec: 3 * 60, ctxTokens: 18_000, model: "Haiku 4.5",
                bgShells: 1),
        ]
    }

    // shellPid -1 marks these as unreachable: nothing in the preview jumps or focuses,
    // and no real session can collide with the "preview-*" ttys these are keyed by.
    private static func row(tty: String, status: String, folder: String, title: String,
                            seq: Int, workSec: Int, ctxTokens: Int, model: String,
                            step: String = "", bgShells: Int = 0) -> SessionRow {
        var r = SessionRow(title: folder, folder: folder, cwd: "/Users/you/Projects/\(folder)",
                           shellPid: -1, tty: tty, status: status, taskTitle: title, seq: seq,
                           workSec: workSec, tokens: ctxTokens, tokensExact: true,
                           ctxTokens: ctxTokens, ctxLimit: 200_000, model: model, step: step)
        r.bgShells = bgShells
        return r
    }
}

// The expanding blue ring that says "this is the element you just changed". Drawn on
// its own overlay above the rows rather than on the target's layer: the target may be
// clipped by its row (the rows box masks to a rounded rect), and a ring that grows
// OUTWARD would be cut off. Click-through, so the card stays inert.
final class PreviewFlashOverlay: NSView {
    private let ring = CAShapeLayer()

    // The CSS keyframe this mirrors: box-shadow spread 0 → 7px, alpha .9 → 0, .55s
    // ease-out. A centered stroke growing 0 → 14 covers the same 7pt outward reach.
    private let duration: CFTimeInterval = 0.55
    private let spread: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        ring.fillColor = nil
        ring.opacity = 0
        ring.lineWidth = 0
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Never intercept clicks — the settings rows below stay fully operable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(around target: NSView, radius: CGFloat) {
        guard target.window != nil else { return }
        let box = convert(target.bounds, from: target)
        guard box.width > 1, box.height > 1 else { return }

        // Corners follow the element: a capsule-ish chip rounds to its own height, a
        // whole row keeps the group radius passed in.
        let r = min(radius, box.height / 2)
        ring.removeAllAnimations()
        // Re-read the accent on every flash, not once at init: the ring is the same
        // blue as a 运行中 session, and both the theme and Settings › 状态颜色 can
        // change it while this card is on screen.
        ring.strokeColor = Status.accent("working").cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        // The path sits half a stroke outside the element so the growing stroke reads
        // as spreading outward only, matching the mock's box-shadow spread.
        ring.path = CGPath(roundedRect: box.insetBy(dx: -spread / 2, dy: -spread / 2),
                           cornerWidth: r + spread / 2, cornerHeight: r + spread / 2,
                           transform: nil)
        CATransaction.commit()

        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = 0
        width.toValue = spread
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [width, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "flash")
    }
}

// The card itself: header line + three real rows, rebuilt from AppSettings on every
// change. Observation is driven by the host pane (start/stop on tab switch), mirroring
// how the focus-ring preview is parked while Settings isn't on screen.
final class LivePreviewCard: NSView {
    static let rowHeight: CGFloat = 54
    // header band + three rows + the card's own bottom padding.
    static let height: CGFloat = 34 + rowHeight * 3 + 8

    private let card = GlassCard(radius: Theme.card, glows: false)
    private let rowsBox = NSView()
    private let overlay = PreviewFlashOverlay()
    private var cells: [ChildCell] = []
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let head = NSTextField(labelWithString: L("预览 · 你的列表会长这样",
                                                  "Preview · how your list will look"))
        head.font = Theme.rounded(11.5, .semibold)
        head.textColor = .secondaryLabelColor
        head.lineBreakMode = .byTruncatingTail
        head.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(head)

        let live = NSTextField(labelWithString: L("改下面任意一项，这里实时变",
                                                  "Change anything below — this updates live"))
        live.font = Theme.font(10.5, .regular)
        live.textColor = .tertiaryLabelColor
        live.lineBreakMode = .byTruncatingTail
        live.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(live)

        // These two share one line, kept apart by a required ">= 8" gap. That gap is
        // the right rule — they must never overlap — but at the default 750 resistance
        // it makes their combined intrinsic width a hard floor for the card, and from
        // there for the whole window (in English the pair runs ~480pt). Let the text
        // truncate instead: the gap still holds, and neither label can widen the window.
        for f in [head, live] {
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // No clipping here — the first row rounds and closes its own top edge via
        // configure(roundTop:), the way a header would cap it in the real list.
        rowsBox.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsBox)

        var prev: NSView?
        for _ in 0..<3 {
            let cell = ChildCell(id: NSUserInterfaceItemIdentifier("preview-child"))
            // A mock row always shows the step column, however narrow the settings window
            // gets — otherwise the 当前步骤 toggle would have nothing to preview here.
            cell.enforcesStepFloor = false
            cell.translatesAutoresizingMaskIntoConstraints = false
            rowsBox.addSubview(cell)
            // The trailing edge is deliberately breakable (and see the paired squeeze on
            // rowsBox below — one is useless without the other). A ChildCell is built
            // from fixed columns (the reserved usage block, the pill, the rail) adding
            // up to ~400pt of unshrinkable width. In the real list that never matters:
            // cells live in an NSTableView, whose width no cell can push on. Here the
            // rows sit in plain Auto Layout, so a required trailing pin hands that 400pt
            // straight up the chain (rowsBox → card → column → 设置 → window) and jams
            // the window's minimum width at 409pt — past its own 384pt minSize, with no
            // way to drag it back. Breakable, the pin still sets the width in every
            // normal layout and simply yields on a narrow window, where the preview row
            // overhangs its card by the few points that don't fit.
            let snugTrailing = cell.trailingAnchor.constraint(equalTo: rowsBox.trailingAnchor)
            snugTrailing.priority = .defaultLow
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: rowsBox.leadingAnchor),
                snugTrailing,
                cell.heightAnchor.constraint(equalToConstant: Self.rowHeight),
                cell.topAnchor.constraint(equalTo: prev?.bottomAnchor ?? rowsBox.topAnchor),
            ])
            cells.append(cell)
            prev = cell
        }

        // Above the rows and spanning the whole card, so an outward ring around the
        // top or bottom row isn't clipped by the rows box.
        card.addSubview(overlay)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),

            live.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            live.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            live.leadingAnchor.constraint(greaterThanOrEqualTo: head.trailingAnchor, constant: 8),

            rowsBox.topAnchor.constraint(equalTo: card.topAnchor, constant: 34),
            rowsBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            rowsBox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            rowsBox.heightAnchor.constraint(equalToConstant: Self.rowHeight * 3),
            // The other half of the breakable trailing pin above. Lowering that pin is
            // not enough on its own: the window's minimum size comes from a fitting-size
            // pass, and an optional constraint with nothing opposing it is simply
            // granted — the rows would still set the floor. This states the opposing
            // wish outright ("be as narrow as you can"), pitched one step above the pin
            // so it wins that pass, and far below the required leading/trailing pins
            // that give rowsBox its real width in normal layout.
            squeeze(rowsBox),

            overlay.topAnchor.constraint(equalTo: card.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        render(changed: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // ── Lifecycle: only live while the Settings tab is on screen ──

    func startObserving() {
        render(changed: nil)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] note in
                self?.render(changed: note.object as? AppSettings.DisplayKey)
            }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { stopObserving() }

    // ── Render ──

    // Sessions in the order the real list would show them: 按状态分组 sorts by the same
    // status order the list uses (which the user can reorder in 跳转优先级, so the
    // preview follows that too); 按项目分组 keeps them in session order.
    private func ordered() -> [SessionRow] {
        let rows = PreviewSessions.all
        guard AppSettings.sortMode == .status else { return rows }
        let order = AppSettings.statusDisplayOrder
        return rows.sorted {
            (order.firstIndex(of: Status.bucket($0.status)) ?? order.count)
                < (order.firstIndex(of: Status.bucket($1.status)) ?? order.count)
        }
    }

    private func render(changed: AppSettings.DisplayKey?) {
        let rows = ordered()
        for (i, cell) in cells.enumerated() where i < rows.count {
            cell.configure(rows[i], isFirst: i == 0, isLast: i == rows.count - 1, roundTop: true)
        }
        guard let changed else { return }
        // Layout has to settle before the ring can be placed — a chip that just
        // appeared (or moved columns) still carries its old frame at this point.
        layoutSubtreeIfNeeded()
        flash(changed)
    }

    // Flash what the changed setting controls: the first row that actually paints an
    // element for it (a chip that's switched off — or collapsed to zero width on this
    // particular row — can't be pointed at), else the whole list. The list-wide fallback
    // is also the right answer by design for sorting and status colors, which reorder or
    // recolor every row rather than living in one element.
    private func flash(_ key: AppSettings.DisplayKey) {
        let element = cells
            .compactMap { $0.previewFlashTarget(for: key) }
            .first { $0.bounds.width > 1 && $0.bounds.height > 1 }
        // A chip rounds to a capsule; the whole list keeps the group radius.
        overlay.flash(around: element ?? rowsBox, radius: element == nil ? Theme.group : 6)
    }
}
