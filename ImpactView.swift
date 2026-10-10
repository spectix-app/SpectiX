import Cocoa

// MARK: - 效能 panel (改这个文件前先读 task/files/tasks/T227-impact-stats-neon.md
// 和 T255-impact-panel-follow-range.md — 这个面板跟随 Insights 顶部的时间范围)
//
// The design is CLICKABLE — open design/impact-stats-5-proposals.html and it lands on
// the 「★ 最终成品 · 霓虹」 tab. Reading it takes a minute and settles more questions
// than reading this file does.
//
// Sits above 概览 in the stats window. Collapsed it is one 62pt bar that already answers
// 「这一段怎么样」; expanded it opens a hero (score ring + trend curve) and the five metric
// bars. Every figure comes from ImpactStore — nothing is computed here, because the
// panel's whole claim is that the user can re-derive each number from impact.jsonl.
//
// The bars are neon, and neon is three things at once (D1). Miss any one and they turn
// grey, which is exactly what the first attempt shipped:
//   1. the gradient barely decays (100% → 85%) — the eye judges brightness off the whole
//      bar, so a tail fading into the dark bed reads as a grey bar
//   2. the light ESCAPES the bar — hence a bar view as tall as its whole row, since a
//      layer-backed view clips its own drawing and a clipped glow is not a glow
//   3. a 1pt inner highlight along the top edge — a real neon tube is round and catches
//      light up there; without it the bar is a colored rectangle, not a tube
// None of that is available on a light bed (a glow needs somewhere dark to spill into),
// so light mode keeps the same colours and gets an outline instead — see NeonBar.draw.
//
// `setExpanded` and `select` are internal rather than private on purpose: this machine
// can grant neither screen-recording nor accessibility permission, so the only way to
// LOOK at this panel — and the only way to see its boundary states at all — is the
// offscreen renderer described in the task file, which drives it through those two.

final class ImpactPanel: NSView {

    private let fold = FoldBar()
    private let body = NSView()
    // One surface, two halves. hero and rate used to be separate NeonSurfaces stacked
    // with a gap; they are the same subject read at two zoom levels, so they now share
    // a card and are parted by a hairline instead of by air.
    private let card = PanelCard()
    private let divider = NeonDivider()
    private let hero = HeroCard()
    private let rate = RateCard()
    private let barsTitle = NSTextField(labelWithString: "")
    private var bars: [(metric: Metric, row: MetricRow)] = []
    private let hint = NSTextField(labelWithString: L("点任意一行看它是什么意思",
                                                      "Tap any row to see what it means"))
    private let detail = DetailCard()

    private var expanded = false
    private var selected: Metric?
    private var foldBottom: NSLayoutConstraint!
    private var bodyBottom: NSLayoutConstraint!
    private var hintHeight: NSLayoutConstraint!
    private var detailHeight: NSLayoutConstraint!

    // Latest rollup, so an expand can paint the body without asking the store again.
    private var period: PeriodImpact?

    // D5's stagger measured from one clock, so the bars, their figures and the curve
    // keep their designed offsets however long an individual frame takes.
    private let clock = IntroClock(span: 1.2)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        setExpanded(false, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildUI() {
        fold.translatesAutoresizingMaskIntoConstraints = false
        fold.onClick = { [weak self] in self?.toggle() }
        addSubview(fold)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        card.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(card)

        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.onCollapse = { [weak self] in self?.toggle() }
        card.addSubview(hero)

        divider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider)

        rate.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rate)

        // 「本周 · 条长 = 占你的个人最佳」 — the bars mean nothing without their divisor
        // (the period noun tracks the range switch; see barsCaption)
        // stated, and the divisor is the point: it is YOUR record, not a target we set.
        // Filled in by update(), which knows whether there is a divisor at all yet.
        // It must yield before anything else does: it is one long unbroken line, and at
        // full compression resistance it becomes the panel's horizontal floor — in
        // English that floor is wider than a narrow stats window.
        barsTitle.lineBreakMode = .byTruncatingTail
        barsTitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        barsTitle.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(barsTitle)

        // Fixed order 省时 · 专注 · 连续 · 托管 · 掌控 (2.4) — it is Metric's declaration
        // order, so the list can never drift out of step with the palette.
        var prev: NSView?
        for m in Metric.allCases {
            let row = MetricRow(metric: m)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] in self?.select(m) }
            body.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                row.topAnchor.constraint(equalTo: prev?.bottomAnchor ?? barsTitle.bottomAnchor,
                                         constant: prev == nil ? 6 : 0),
            ])
            bars.append((m, row))
            prev = row
        }

        // 「点任意一行看它是什么意思」 — the detail sits far from the row that opens it
        // (D4), so without this nobody discovers the rows are clickable at all.
        hint.font = Theme.font(9.5, .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(hint)

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.alphaValue = 0
        detail.onHeightChange = { [weak self] _ in self?.syncSelection(animated: false) }
        body.addSubview(detail)

        hintHeight = hint.heightAnchor.constraint(equalToConstant: Self.hintH)
        detailHeight = detail.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            hint.topAnchor.constraint(equalTo: prev!.bottomAnchor, constant: 7),
            hintHeight,

            detail.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detail.topAnchor.constraint(equalTo: hint.bottomAnchor),
            detailHeight,
        ])
        prev = detail

        foldBottom = fold.bottomAnchor.constraint(equalTo: bottomAnchor)
        bodyBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            fold.topAnchor.constraint(equalTo: topAnchor),
            fold.leadingAnchor.constraint(equalTo: leadingAnchor),
            fold.trailingAnchor.constraint(equalTo: trailingAnchor),
            fold.heightAnchor.constraint(equalToConstant: 62),

            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.topAnchor.constraint(equalTo: body.topAnchor),
            card.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: body.trailingAnchor),

            hero.topAnchor.constraint(equalTo: card.topAnchor),
            hero.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            // Inset to match the content either side of it, so the fold line starts and
            // stops where the text does rather than cutting the card edge to edge.
            divider.topAnchor.constraint(equalTo: hero.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            rate.topAnchor.constraint(equalTo: divider.bottomAnchor),
            rate.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rate.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rate.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            barsTitle.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 2),
            barsTitle.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            barsTitle.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),

            prev!.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])

        // D5's timings, all measured from the moment the panel opens:
        //   0.06s  the ring draws itself (its own layer animation, started by the hero)
        //   0.10s  the bars grow from the left, 60ms apart
        //   0.20s  the curve draws in
        //   0.34s  each figure surfaces once its bar has passed under it
        clock.onTick = { [weak self] t in
            guard let self else { return }
            for (i, b) in self.bars.enumerated() {
                b.row.setIntro(grow: IntroClock.phase(t, delay: 0.10 + 0.06 * Double(i), dur: 0.62),
                               fade: IntroClock.phase(t, delay: 0.34 + 0.06 * Double(i), dur: 0.40))
            }
            self.hero.setIntro(curve: IntroClock.phase(t, delay: 0.20, dur: 1.0))
            self.rate.setIntro(curve: IntroClock.phase(t, delay: 0.28, dur: 1.0))
        }
    }

    // MARK: Data

    func update(_ w: PeriodImpact, trend pts: [TrendPoint], rate rp: [RatePoint]) {
        period = w
        detail.lastPeriod = w
        barsTitle.attributedStringValue = Self.barsCaption(w)
        fold.update(w, trend: pts)
        hero.update(w, trend: pts)
        rate.update(rp, range: w.range)
        for (m, row) in bars { row.update(w.metric(m), period: w) }
        if let s = selected {
            detail.show(s, period: w)
            syncSelection(animated: false)
        }
    }

    // MARK: Expand / collapse
    //
    // Either the bar OR the body — expanded, the bar disappears entirely rather than
    // sitting above the hero, because everything on it is repeated inside (D4).

    private func toggle() { setExpanded(!expanded) }

    func setExpanded(_ on: Bool, animated: Bool = true) {
        expanded = on
        if !on { selected = nil; syncSelection(animated: false) }

        // Neither half may be `isHidden` while it moves — a hidden view cannot fade. The
        // one that ends up invisible is hidden again on completion instead, otherwise its
        // transparent self keeps swallowing clicks meant for the other.
        fold.isHidden = false
        body.isHidden = false

        let apply = {
            self.foldBottom.isActive = !on
            self.bodyBottom.isActive = on
            self.fold.alphaValue = on ? 0 : 1
            self.body.alphaValue = on ? 1 : 0
        }
        let settle = {
            self.fold.isHidden = on
            self.body.isHidden = !on
        }

        guard animated else { apply(); settle(); on ? clock.settle() : clock.stop(); return }

        // 260–380ms (D5): below that the sections underneath read as jumping rather
        // than moving. The whole chain animates, not just us — the panel lives in the
        // stats page's document view and everything under it slides with it.
        animate(0.30) { apply() } done: { settle() }
        if on { hero.playRingIntro(); clock.run() } else { clock.stop() }
    }

    // MARK: Detail (3.1)
    //
    // The detail lands at the BOTTOM of the list, never inside the row. The one thing
    // this list is for is comparing five bar lengths side by side, and any interaction
    // that moves a bar destroys exactly that (D4).

    func select(_ m: Metric) {
        selected = (selected == m) ? nil : m       // the row is its own switch — no ✕ (D4)
        if let s = selected, let w = period { detail.show(s, period: w) }
        // Nothing to animate before the panel is on screen (and an animation group with
        // no runloop to pump it just leaves half-applied layout behind).
        syncSelection(animated: window != nil)
    }

    private func syncSelection(animated: Bool) {
        let open = selected != nil
        for (m, row) in bars { row.setSelected(m == selected) }
        let apply = {
            self.detailHeight.constant = open ? self.detail.wantedHeight : 0
            self.hintHeight.constant = open ? 0 : Self.hintH
            self.detail.alphaValue = open ? 1 : 0
            self.hint.alphaValue = open ? 0 : 1
        }
        animated ? animate(0.26) { apply() } done: {} : apply()
    }

    /// Constraint changes only animate when something asks the layout engine to run
    /// inside the animation group — hence the explicit `layoutSubtreeIfNeeded` on the
    /// ancestor, so the views BELOW this panel travel with it instead of teleporting.
    private func animate(_ duration: Double, _ apply: @escaping () -> Void,
                         done: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            apply()
            (superview ?? self).layoutSubtreeIfNeeded()
        }, completionHandler: done)
    }

    private static let hintH: CGFloat = 22

    /// Before four tracked periods there is no divisor, so the caption says what the
    /// numbers ARE instead of what the (absent) bars mean — and says it once, rather
    /// than repeating 「还需 N 周才有纪录」 down all five rows (D6 新用户).
    private static func barsCaption(_ w: PeriodImpact) -> NSAttributedString {
        let out = NSMutableAttributedString(string: w.range.impactNoun, attributes: [
            .font: Theme.font(12, .semibold), .foregroundColor: NSColor.labelColor])
        let tail: String
        if !w.comparable {
            tail = L("　全部区间没有上一期，只看总量",
                     "  all-time has no prior period — totals only")
        } else if w.bucketsTracked < ImpactRule.newUserBuckets {
            let need = ImpactRule.newUserBuckets - w.bucketsTracked
            tail = L("　还需 \(need) \(w.range.bucketNoun)才有纪录可比，先看数字",
                     "  \(need) more \(w.range.bucketNoun) before there is a record to compare against")
        } else {
            tail = L("　条长 = 占你的个人最佳", "  bar = share of your personal best")
        }
        out.append(NSAttributedString(string: tail,
            attributes: [.font: Theme.font(10.5, .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return out
    }
}

// MARK: - Intro clock (3.3 / D5)
//
// One timer for the whole panel. The bars, their figures and the curve all read the
// same elapsed time, so the 60ms stagger between them holds even when a frame is late —
// five independent animations would drift apart under load and arrive as a ragged wave.
private final class IntroClock {

    private var timer: Timer?
    private var start = CFAbsoluteTimeGetCurrent()
    private let span: Double
    var onTick: ((Double) -> Void)?

    init(span: Double) { self.span = span }

    func run() {
        stop()
        start = CFAbsoluteTimeGetCurrent()
        onTick?(0)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let e = CFAbsoluteTimeGetCurrent() - self.start
            self.onTick?(min(e, self.span))
            if e >= self.span { t.invalidate(); self.timer = nil }
        }
        timer = t
        // .common, not .default: the stats page is a scroll view, and a plain timer
        // freezes mid-animation the moment the user starts scrolling it.
        RunLoop.main.add(t, forMode: .common)
    }

    /// Jump straight to the finished state (a non-animated expand).
    func settle() { stop(); onTick?(span) }

    func stop() { timer?.invalidate(); timer = nil }

    /// One segment of the stagger: 0 before it starts, 1 once it is done, eased between.
    static func phase(_ t: Double, delay: Double, dur: Double) -> CGFloat {
        let x = max(0, min(1, (t - delay) / dur))
        return CGFloat(1 - pow(1 - x, 3))          // easeOutCubic ≈ the design's curve
    }
}

// MARK: - Collapsed bar (2.2)
//
// 62pt, and it has to answer 「这一段怎么样」 on its own — score, trend vs the period
// before it, records broken, the curve's shape, and the headline hour figure.

private final class FoldBar: NeonSurface {

    var onClick: (() -> Void)?

    private let ring = NeonRing(lineWidth: 3.6, glow: 4, numberSize: 13, caption: nil)
    private let title = NSTextField(labelWithString: "")
    private let band = TagPill()
    private let sub = NSTextField(labelWithString: "")
    private let spark = SparkLine()
    private let tailValue = NSTextField(labelWithString: "—")
    private let tailCaption = NSTextField(labelWithString: L("省下的等待", "Waiting saved"))
    private let tri = TriangleButton(pointsUp: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        title.font = Theme.rounded(11.5, .bold)
        title.textColor = NeonInk.primary
        sub.font = Theme.font(9.5, .regular)
        sub.textColor = NeonInk.secondary
        tailValue.font = Theme.roundedMono(13.5, .bold)
        tailValue.textColor = Metric.accent(.saved)
        tailCaption.font = Theme.font(8.5, .semibold)
        tailCaption.textColor = NeonInk.faint
        tailValue.alignment = .right
        tailCaption.alignment = .right
        // The sparkline and the hour figure keep their size; the wordy left half is what
        // yields when the window is narrow, rather than the layout breaking a constraint.
        for v in [title, sub] {
            v.lineBreakMode = .byTruncatingTail
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        tri.onClick = { [weak self] in self?.onClick?() }

        for v in [ring, title, band, sub, spark, tailValue, tailCaption, tri] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 38),
            ring.heightAnchor.constraint(equalToConstant: 38),

            title.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 12),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            band.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            band.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            spark.leadingAnchor.constraint(greaterThanOrEqualTo: band.trailingAnchor, constant: 12),
            spark.leadingAnchor.constraint(greaterThanOrEqualTo: sub.trailingAnchor, constant: 12),
            spark.trailingAnchor.constraint(equalTo: tailValue.leadingAnchor, constant: -12),
            spark.centerYAnchor.constraint(equalTo: centerYAnchor),
            spark.widthAnchor.constraint(equalToConstant: 76),
            spark.heightAnchor.constraint(equalToConstant: 22),

            tailValue.trailingAnchor.constraint(equalTo: tri.leadingAnchor, constant: -12),
            tailValue.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            tailCaption.trailingAnchor.constraint(equalTo: tailValue.trailingAnchor),
            tailCaption.topAnchor.constraint(equalTo: tailValue.bottomAnchor, constant: 4),

            tri.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            tri.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(_ w: PeriodImpact, trend pts: [TrendPoint]) {
        title.stringValue = w.range.impactTitle
        ring.set(score: w.score.value)
        band.set(text: ImpactFormat.band(w.score.value), color: Metric.accent(.saved))
        sub.attributedStringValue = ImpactFormat.foldSubline(w)
        // The spark shows whichever series the hero's curve settled on, so the two can
        // never be reporting different things about the same period.
        spark.points = ImpactFormat.scored(pts) ? pts.map { $0.score.map(Double.init) }
                                                : pts.map { Double($0.arrivals) }
        // With no baseline yet 省时 has no number, and a lone 「—」 under 「省下的等待」
        // reads as "nothing was saved". Fall back to the figure that IS measured —
        // the trips that found something waiting (the hero's own headline number).
        if w.saved.trustworthy {
            tailValue.stringValue = ImpactFormat.hm(w.metric(.saved).value)
            tailCaption.stringValue = L("省下的等待", "Waiting saved")
        } else {
            tailValue.stringValue = L("\(w.score.effectiveArrivals) 次",
                                      "\(w.score.effectiveArrivals)")
            tailCaption.stringValue = L("少扑空", "Trips that paid off")
        }
        tailValue.textColor = Metric.accent(.saved)
    }

    // The whole bar is the affordance, not just the triangle (D4).
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Hero (2.3)

// The single surface hero and rate are drawn on.
//
// It deliberately does NOT track the pointer. A surface that brightens under the cursor
// is promising a click, and this one stopped accepting clicks when collapsing moved to
// the ▲ alone (so the charts could be hovered for readings without folding the panel).
// It therefore sits permanently at NeonSurface's resting wash — which is exactly the
// brightness the hover state used to have.
private final class PanelCard: NeonSurface {}

private final class HeroCard: NSView {

    var onCollapse: (() -> Void)?

    private let ring = NeonRing(lineWidth: 8, glow: 6, numberSize: 26, caption: "")
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let chart = TrendChart()
    private let emptyChart = NSTextField(labelWithString: L(
        "这一段还没有足够的数据画出趋势", "Not enough data in this range to draw a trend"))
    private let legend = NSTextField(labelWithString: "")
    private let peakNote = NSTextField(labelWithString: "")
    private let tri = TriangleButton(pointsUp: true)
    private lazy var chartHeight = chart.heightAnchor.constraint(equalToConstant: 92)

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        headline.font = Theme.rounded(12, .bold)
        headline.textColor = NeonInk.primary
        detail.font = Theme.font(11, .regular)
        detail.textColor = NeonInk.secondary
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        // Three lines of English are still a wide minimum if the label refuses to
        // compress; let it give way and wrap instead of widening the whole panel.
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        legend.font = Theme.font(10.5, .regular)
        peakNote.font = Theme.roundedMono(10.5, .regular)
        peakNote.textColor = NeonInk.primary
        peakNote.alignment = .right
        emptyChart.font = Theme.font(10, .regular)
        emptyChart.textColor = NeonInk.faint
        emptyChart.alignment = .center

        tri.onClick = { [weak self] in self?.onCollapse?() }

        for v in [ring, headline, detail, chart, emptyChart, legend, peakNote, tri] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            tri.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tri.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            ring.widthAnchor.constraint(equalToConstant: 92),
            ring.heightAnchor.constraint(equalToConstant: 92),

            headline.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 14),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: tri.leadingAnchor, constant: -10),
            headline.topAnchor.constraint(equalTo: ring.topAnchor, constant: 14),
            detail.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),

            chart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chart.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 10),
            chartHeight,

            emptyChart.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            emptyChart.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            emptyChart.centerYAnchor.constraint(equalTo: chart.centerYAnchor),

            legend.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            legend.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 2),
            peakNote.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            peakNote.leadingAnchor.constraint(greaterThanOrEqualTo: legend.trailingAnchor, constant: 8),
            peakNote.firstBaselineAnchor.constraint(equalTo: legend.firstBaselineAnchor),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func update(_ w: PeriodImpact, trend pts: [TrendPoint]) {
        ring.set(caption: w.range.impactTitle)
        ring.set(score: w.score.value)
        headline.stringValue = ImpactFormat.heroHeadline(w)
        detail.attributedStringValue = ImpactFormat.heroDetail(w)

        let model = ImpactFormat.trendModel(pts, w.range)
        let drawable = !model.isEmpty
        chart.set(model)
        chart.isHidden = !drawable
        emptyChart.isHidden = drawable
        legend.isHidden = !drawable
        peakNote.isHidden = !drawable
        chartHeight.constant = drawable ? 92 : 24
        legend.attributedStringValue = ImpactFormat.legend(scored: ImpactFormat.scored(pts),
                                                           hasDashed: !model.dashed.isEmpty)
        peakNote.stringValue = ImpactFormat.trendNote(pts, w.range)
    }

    // Collapsing is the ▲ button's job ALONE. Click-anywhere used to be the gesture
    // (D4), and it was right while the card was inert — but the charts read out values
    // under the pointer now, so anywhere you would hover to read a number is somewhere
    // a stray click would have folded the panel away underneath you.
    // Hover styling belongs to the enclosing PanelCard: the two halves share one
    // surface, so lighting up only the half under the pointer would split it back in two.

    func setIntro(curve: CGFloat) { chart.drawProgress = curve }

    func playRingIntro() { ring.playIntro() }
}

// MARK: - 消耗速率 (the two fine-grained curves)
//
// Two charts stacked, not one overlaid. The units are different — tokens against a
// count of terminals — and one of them is tiny: a peak of four terminals normalised
// onto a megatoken axis is a flat line on the floor. Stacking keeps the x axis common,
// which is the whole reason to show them together: read straight down from an
// expensive five minutes to see how many terminals were open during it.
private final class RateCard: NSView {

    private let title = NSTextField(labelWithString: L("消耗速率", "Burn rate"))
    private let tokChart = TrendChart()
    private let tokLegend = NSTextField(labelWithString: "")
    private let tokNote = NSTextField(labelWithString: "")
    // The same fold line the panel draws between hero and this card. The two charts
    // are as separate from each other as this card is from the ring above it, so the
    // seam between them has to read at the same weight or the card looks lopsided.
    private let split = NeonDivider()
    private let concTitle = NSTextField(labelWithString: L("同时在跑的终端",
                                                          "Terminals at once"))
    private let concNote = NSTextField(labelWithString: "")
    private let concChart = TrendChart()
    // Reached only when the range is too short to hold two buckets — i.e. there is no
    // timeline, not merely nothing on it. Anything that HAPPENED, including nothing,
    // draws as a line.
    private let empty = NSTextField(labelWithString: L(
        "这个时间段还没有任何记录", "Nothing recorded in this range yet"))

    private lazy var tokHeight = tokChart.heightAnchor.constraint(equalToConstant: 96)
    // 46 was enough for a floor-and-ceiling axis; a labelled line per terminal needs
    // real height or the numbers collide. Still shorter than the burn-rate chart above,
    // which is the one carrying the detail.
    private lazy var concHeight = concChart.heightAnchor.constraint(equalToConstant: 84)

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        title.font = Theme.rounded(12, .bold)
        title.textColor = NeonInk.primary
        // The two halves of this card are the same shape: a bold white heading over a
        // chart, with the figures parked bottom-right. Anything less and the second
        // heading reads as a caption belonging to the chart above it.
        concTitle.font = Theme.rounded(12, .bold)
        concTitle.textColor = NeonInk.primary
        concNote.font = Theme.roundedMono(10.5, .regular)
        concNote.textColor = NeonInk.primary
        concNote.alignment = .right
        concNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tokLegend.font = Theme.font(10.5, .regular)
        tokNote.font = Theme.roundedMono(10.5, .regular)
        tokNote.textColor = NeonInk.primary
        tokNote.alignment = .right
        tokNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        empty.font = Theme.font(10, .regular)
        empty.textColor = NeonInk.faint
        empty.alignment = .center

        // Burning tokens is spending, so the curve wears 连续's orange; the unattended
        // share wears 托管's magenta, so it reads as the same thing the 托管 bar counts.
        tokChart.accents = (Metric.accent(.streak), Metric.accent(.auto))
        // Concurrency IS 掌控's raw series (its peak and P75 are computed from it), so
        // it wears that colour and nothing else.
        concChart.accents = (Metric.accent(.control), Metric.accent(.control))

        for v in [title, tokChart, tokLegend, tokNote,
                  split, concTitle, concNote, concChart, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            tokChart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tokChart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tokChart.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            tokHeight,

            empty.leadingAnchor.constraint(equalTo: tokChart.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: tokChart.trailingAnchor),
            empty.centerYAnchor.constraint(equalTo: tokChart.centerYAnchor),

            tokLegend.leadingAnchor.constraint(equalTo: tokChart.leadingAnchor),
            tokLegend.topAnchor.constraint(equalTo: tokChart.bottomAnchor, constant: 2),
            tokNote.trailingAnchor.constraint(equalTo: tokChart.trailingAnchor),
            tokNote.leadingAnchor.constraint(greaterThanOrEqualTo: tokLegend.trailingAnchor,
                                             constant: 8),
            tokNote.firstBaselineAnchor.constraint(equalTo: tokLegend.firstBaselineAnchor),

            split.topAnchor.constraint(equalTo: tokLegend.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            split.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            split.heightAnchor.constraint(equalToConstant: 1),

            concTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            concTitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            concTitle.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 12),

            concChart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            concChart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            concChart.topAnchor.constraint(equalTo: concTitle.bottomAnchor, constant: 8),
            concHeight,

            concNote.trailingAnchor.constraint(equalTo: concChart.trailingAnchor),
            concNote.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            concNote.topAnchor.constraint(equalTo: concChart.bottomAnchor, constant: 2),
            concNote.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func update(_ pts: [RatePoint], range: TimeRange) {
        // ONE gate for both halves, and it asks only whether there is a timeline to draw
        // on — not whether anything happened along it. Zero IS the answer to "how fast
        // were tokens burned"; treating it as absence is how this card came to claim
        // nothing had happened in the top half while the bottom half drew a live line
        // through the very same minutes. The halves also have to agree: they share one
        // x axis, so either both are drawn or neither is.
        let tokModel = ImpactFormat.rateModel(pts)
        let drawable = pts.count > 1

        tokChart.set(tokModel)
        tokChart.isHidden = !drawable
        empty.isHidden = drawable
        tokLegend.isHidden = !drawable
        tokNote.isHidden = !drawable
        tokHeight.constant = drawable ? 96 : 24

        tokLegend.attributedStringValue =
            ImpactFormat.rateLegend(hasAuto: pts.contains { $0.autoTok > 0 })
        tokNote.stringValue = ImpactFormat.rateNote(pts, range)

        concChart.set(ImpactFormat.concurrencyModel(pts))
        concChart.isHidden = !drawable
        concTitle.isHidden = !drawable
        concNote.isHidden = !drawable
        split.isHidden = !drawable
        concHeight.constant = drawable ? 84 : 0
        concNote.stringValue = ImpactFormat.concurrencyNote(pts)
    }

    func setIntro(curve: CGFloat) {
        tokChart.drawProgress = curve
        concChart.drawProgress = curve
    }

}

// The hairline between the two halves of the card. Same colour as the surface's own
// border, at the same weight, so it reads as the card folding rather than as a rule
// somebody drew across it.
private final class NeonDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        resolvedSRGB(Metric.accent(.saved)).withAlphaComponent(0.22).setFill()
        bounds.fill()
    }
}

// MARK: - One metric bar (2.4 / 2.5)

private final class MetricRow: NSView {

    // 36, not the design's 42: expanded, this panel sits above 概览 and everything else
    // on the stats page, and at 42 the five rows plus the hero filled a short window
    // edge to edge — you could not see there was a page under it.
    static let height: CGFloat = 36

    var onClick: (() -> Void)?

    private let metric: Metric
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let bar: NeonBar
    private let note = NSTextField(labelWithString: "")
    private let chev = NSTextField(labelWithString: "⌄")

    private var hovering = false { didSet { if hovering != oldValue { refreshChrome() } } }
    private var selected = false { didSet { if selected != oldValue { refreshChrome() } } }

    init(metric: Metric) {
        self.metric = metric
        bar = NeonBar(metric: metric)
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let accent = Metric.accent(metric)

        icon.image = ImpactFormat.symbol(metric)
        icon.contentTintColor = accent
        icon.imageScaling = .scaleProportionallyUpOrDown
        // The icon glows in its bar's own color; the text next to it does not. Glowing
        // type on top of five glowing bars is where the panel turns to mush (D1).
        icon.wantsLayer = true
        icon.shadowed(color: accent, radius: 4, opacity: 0.9)

        name.stringValue = ImpactFormat.name(metric)
        name.font = Theme.font(11, .semibold)
        name.textColor = .labelColor
        name.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)

        note.alignment = .right
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byTruncatingTail

        // Appears on hover only, and goes away again once the row is open — by then the
        // detail card below is the affordance and a stale chevron just adds noise.
        chev.font = Theme.font(9, .regular)
        chev.textColor = .tertiaryLabelColor
        chev.alignment = .center
        chev.alphaValue = 0

        for v in [icon, name, bar, note, chev] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            chev.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            chev.centerYAnchor.constraint(equalTo: centerYAnchor),
            chev.widthAnchor.constraint(equalToConstant: 11),

            // 8, not 2: the selected row's colour rule lives in the first few points.
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            // A fixed column, so the five bars start on the same x — their lengths being
            // comparable is the only thing this list is for. 88, because at 74 the widest
            // English name had 37pt to live in and 「Control」 needs 45: it came out as
            // 「Contro」, and a truncated name costs more than 14pt of bar does.
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: note.leadingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),

            note.trailingAnchor.constraint(equalTo: chev.leadingAnchor, constant: -3),
            note.widthAnchor.constraint(equalToConstant: 84),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: Selection / hover (3.1)

    func setSelected(_ on: Bool) { selected = on }

    func setIntro(grow: CGFloat, fade: CGFloat) { bar.setIntro(grow: grow, fade: fade) }

    private func refreshChrome() {
        chev.animator().alphaValue = (hovering && !selected) ? 0.75 : 0
        bar.emphasised = hovering || selected
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // The selected row keeps a lit rule down its left edge, in its own colour. Of D4's
    // three anchors tying the far-away card back to the row that opened it, this is the
    // one doing most of the work — the eye finds the colour before it reads anything.
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering {
            NSColor.labelColor.withAlphaComponent(selected ? 0.06 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2),
                         xRadius: 9, yRadius: 9).fill()
        }
        guard selected else { return }
        // Inside bounds, not hanging off the left edge: this view is layer-backed and a
        // layer clips its own drawing — the glow would be sheared away (D1 point 2).
        let accent = resolvedSRGB(Metric.accent(metric))
        let rule = NSRect(x: 1, y: 8, width: 2.5, height: bounds.height - 16)
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.85)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        accent.setFill()
        NSBezierPath(roundedRect: rule, xRadius: 1.25, yRadius: 1.25).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // The icon's glow is a CGColor, which snapshots whichever appearance was current when
    // it was set — so it has to be taken again on a light/dark flip or it keeps painting
    // the old palette's tone.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let accent = Metric.accent(metric)
        icon.contentTintColor = accent
        icon.shadowed(color: accent, radius: 4, opacity: 0.9)
    }

    func update(_ v: MetricValue, period: PeriodImpact) {
        // Before there is a record to divide by, every metric IS its own record and every
        // bar would sit at 100% — five full bars saying nothing (D6 新用户前 4 周). So the
        // bar is withheld and only the figure is shown until a real divisor exists.
        // Before there is a past week to divide by, every metric IS its own best, so all
        // five bars sit at 100%. That was read as 「条没了」 when the bars were withheld
        // instead — a row with no bar looks broken, and 「还没有可比的纪录」 is a caption's
        // job, not a reason to delete the shape people came to look at. The right-hand
        // note says 「首次记录」 so a full bar is never mistaken for an achievement.
        bar.set(ratio: CGFloat(v.ratio),
                value: ImpactFormat.value(metric, period),
                record: period.comparable
                        && period.bucketsTracked >= ImpactRule.newUserBuckets && v.isRecord)
        note.attributedStringValue = ImpactFormat.note(v, period: period)
    }
}

// MARK: - Detail card (3.1 / 3.2)
//
// Three fixed sections, in the same order for all five metrics (3.2): what it MEANS,
// three facts from this week, and one line of 「怎么算的」. That last line is the point
// of the whole panel — a number nobody can re-derive is worth less than no number — but
// it is also the least interesting thing on screen, so it goes last and small.
//
// The card's height is the SAME for every metric (D4's third anchor): it is measured
// across all five, not just the one on screen, so switching rows swaps the contents
// without the page under it twitching each time.
private final class DetailCard: NSView {

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let big = NSTextField(labelWithString: "")
    private let meaning = NSTextField(labelWithString: "")
    private let facts = [FactRow(), FactRow(), FactRow()]
    private let how = NSTextField(labelWithString: "")
    private let ruleTop = Hairline()
    private let ruleBottom = Hairline()

    private(set) var wantedHeight: CGFloat = 150
    private var metric: Metric?

    // One place for the vertical rhythm, because `height(for:)` has to add up exactly
    // the same numbers the constraints below lay out — two copies would drift and the
    // card would clip its last line.
    private static let padTop: CGFloat = 12, headerH: CGFloat = 17
    private static let gapMeaning: CGFloat = 9, gapRule: CGFloat = 9, gapFacts: CGFloat = 6
    private static let factH: CGFloat = 17, gapAfterFacts: CGFloat = 8
    private static let gapHow: CGFloat = 7, padBottom: CGFloat = 12
    private static let sidePad: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        name.font = Theme.font(12, .bold)
        name.textColor = .labelColor
        big.font = Theme.roundedMono(13, .bold)
        big.textColor = .secondaryLabelColor
        big.alignment = .right
        icon.imageScaling = .scaleProportionallyUpOrDown

        // Wrapping, and barred from setting a width floor. This card sits in a scroll view
        // whose document tracks the clip's width, so a label that refuses to compress
        // pushes the window itself wider — and at 750 it beats the priority holding the
        // window at its size. In English 「how」 wants 570pt on one line, which dragged a
        // 545pt window out to ~600 the moment a row was opened, and it stayed there
        // afterwards: the text is still in the hierarchy at zero height. Same fix as the
        // hero's detail line and SettingsWindow's relaxLabelWidths.
        for (v, lines) in [(meaning, 3), (how, 3)] {
            v.lineBreakMode = .byWordWrapping
            v.maximumNumberOfLines = lines
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for v in ([icon, name, big, meaning, how, ruleTop, ruleBottom] as [NSView]) + facts {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        let P = Self.sidePad
        var c: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Self.padTop),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            big.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),
            big.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            big.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            meaning.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
            meaning.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),
            meaning.topAnchor.constraint(equalTo: topAnchor,
                                         constant: Self.padTop + Self.headerH + Self.gapMeaning),

            ruleTop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
            ruleTop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),
            ruleTop.topAnchor.constraint(equalTo: meaning.bottomAnchor, constant: Self.gapRule),

            ruleBottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
            ruleBottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),

            how.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
            how.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),
            how.topAnchor.constraint(equalTo: ruleBottom.bottomAnchor, constant: Self.gapHow),
        ]
        var prev: NSView = ruleTop
        for (i, f) in facts.enumerated() {
            c += [
                f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P),
                f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P),
                f.heightAnchor.constraint(equalToConstant: Self.factH),
                f.topAnchor.constraint(equalTo: prev.bottomAnchor,
                                       constant: i == 0 ? Self.gapFacts : 0),
            ]
            prev = f
        }
        c.append(ruleBottom.topAnchor.constraint(equalTo: prev.bottomAnchor,
                                                 constant: Self.gapAfterFacts))
        NSLayoutConstraint.activate(c)
    }

    func show(_ m: Metric, period w: PeriodImpact) {
        metric = m
        let accent = Metric.accent(m)
        icon.image = ImpactFormat.symbol(m)
        icon.contentTintColor = accent
        name.stringValue = ImpactFormat.name(m)
        big.attributedStringValue = ImpactFormat.detailHeadline(m, w)
        meaning.attributedStringValue = ImpactFormat.detailMeaning(m, w)
        how.attributedStringValue = ImpactFormat.detailHow(m, w)
        let rows = ImpactFormat.detailFacts(m, w)
        for (i, f) in facts.enumerated() {
            f.set(rows.indices.contains(i) ? rows[i] : (label: "", value: ""))
        }
        wantedHeight = Self.height(for: w, width: bounds.width)
        needsDisplay = true
    }

    /// The tallest the card gets for ANY metric at this width — see the class comment.
    private static func height(for w: PeriodImpact, width: CGFloat) -> CGFloat {
        let textW = max(120, width - sidePad * 2)
        func lines(_ s: NSAttributedString) -> CGFloat {
            ceil(s.boundingRect(with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let fixed = padTop + headerH + gapMeaning + gapRule + 1 + gapFacts
                  + factH * 3 + gapAfterFacts + 1 + gapHow + padBottom
        let tallest = Metric.allCases.map {
            lines(ImpactFormat.detailMeaning($0, w)) + lines(ImpactFormat.detailHow($0, w))
        }.max() ?? 0
        return max(150, fixed + tallest)
    }

    override func layout() {
        super.layout()
        // A window resize rewraps the text, so the shared height has to be taken again —
        // otherwise the card keeps the height of whatever width it was opened at.
        guard let m = metric, let w = lastPeriod else { return }
        let h = Self.height(for: w, width: bounds.width)
        guard abs(h - wantedHeight) > 0.5 else { return }
        wantedHeight = h
        // Handed to the next runloop turn on purpose: the callback re-activates the
        // panel's constraints, and doing that from inside a layout pass makes the engine
        // drop work already queued for this pass — the section caption above simply
        // stopped being laid out.
        DispatchQueue.main.async { [weak self] in self?.onHeightChange?(m) }
    }

    var lastPeriod: PeriodImpact?
    var onHeightChange: ((Metric) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.30).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.09).setStroke()
        path.stroke()
    }
}

/// 「本周专注段数 …… 23 段」 — label left, figure right, tabular so the column of
/// figures lines up however the labels differ in width.
private final class FactRow: NSView {

    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.font(10, .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.font = Theme.roundedMono(10, .bold)
        value.textColor = .labelColor
        value.alignment = .right
        for v in [label, value] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ row: (label: String, value: String)) {
        label.stringValue = row.label
        value.stringValue = row.value
    }
}

private final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
    }
}

// A bar as tall as its whole row, with the 24pt track drawn centred inside it. The extra
// height is not padding — it is the only room the glow has. This view is layer-backed
// (everything in this window is, once an NSVisualEffectView is in the hierarchy), and a
// layer clips its own drawing, so a glow drawn in a 24pt view would be sheared off flat
// at the bar's edge. A sheared glow does not read as light (D1 point 2).
private final class NeonBar: NSView {

    private let metric: Metric
    private var ratio: CGFloat = 0
    private var value = NSAttributedString()
    private var record = false

    private var grow: CGFloat = 1      // 0…1, the expand animation (D5)
    private var fade: CGFloat = 1      // 0…1, the figure surfacing after its bar

    var emphasised = false { didSet { if emphasised != oldValue { needsDisplay = true } } }

    private let barH: CGFloat = 24, radius: CGFloat = 7
    // Below this the figure cannot live inside the bar — it would be clipped by its own
    // fill. The most-missed state, because every mock-up was drawn at 67%+ (D6).
    private let insideMin: CGFloat = 0.32

    init(metric: Metric) {
        self.metric = metric
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(ratio: CGFloat, value: NSAttributedString, record: Bool) {
        self.ratio = max(0, min(1, ratio))
        self.value = value
        self.record = record
        needsDisplay = true
    }

    func setIntro(grow: CGFloat, fade: CGFloat) {
        self.grow = grow
        self.fade = fade
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - barH) / 2
        let accent = resolvedSRGB(Metric.accent(metric))
        // Whether the figure sits inside is decided by the FINAL length, not the
        // animated one — otherwise it would start outside and hop in mid-grow.
        let inside = ratio >= insideMin
        let w = bounds.width * ratio * grow

        // Same five colours either way (Theme.swift). What differs is how a bar is made
        // to READ: on a dark bed by glowing, on a light one by being outlined. A glow
        // needs somewhere dark to spill into, so on white it is simply not available —
        // and a pale bar on a pale bed with no edge is the thing users could not see.
        let light = (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua) == .aqua
        let strong = record || emphasised

        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: barH),
                     xRadius: radius, yRadius: radius)
            .fill(with: NSColor.labelColor.withAlphaComponent(0.05))
        // The empty part gets an edge too, or a short bar floats with nothing to
        // measure it against — 「占你的个人最佳」 needs the 100% mark to be visible.
        if light {
            let track = NSBezierPath(roundedRect: NSRect(x: 0.5, y: y + 0.5,
                                                         width: bounds.width - 1,
                                                         height: barH - 1),
                                     xRadius: radius, yRadius: radius)
            track.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()
        }

        if w > 1 {
            let fill = NSRect(x: 0, y: y, width: max(w, barH), height: barH)
            let path = NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius)

            if !light {
                // Bloom first, as a flat fill under the gradient: a shadow is cast by the
                // shape, and the gradient laid on top hides the solid it came from.
                NSGraphicsContext.current?.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = accent.withAlphaComponent(strong ? 0.70 : 0.42)
                glow.shadowBlurRadius = strong ? 16 : 10
                glow.shadowOffset = .zero
                glow.set()
                accent.setFill()
                path.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }

            // 100% → 85%. The first version decayed 93% → 44% and every bar looked grey:
            // the eye rates a bar by its whole length, and a tail sunk into the dark bed
            // drags the verdict down with it.
            NSGradient(starting: accent, ending: accent.withAlphaComponent(0.85))?
                .draw(in: path, angle: 0)

            if light {
                // The outline also does the job the stronger glow does in dark mode:
                // marking a record. 「哪条破纪录看谁更亮」 has no light-mode equivalent,
                // so on white it becomes 「看谁的边更重」.
                let edge = NSBezierPath(roundedRect: fill.insetBy(dx: 0.75, dy: 0.75),
                                        xRadius: radius - 0.75, yRadius: radius - 0.75)
                edge.lineWidth = strong ? 2.5 : 1.5
                NSColor.labelColor.withAlphaComponent(0.82).setStroke()
                edge.stroke()
            } else {
                // The tube's top reflection. Without it this is a colored rectangle.
                NSGraphicsContext.current?.saveGraphicsState()
                path.addClip()
                NSColor.white.withAlphaComponent(strong ? 0.34 : 0.28).setFill()
                NSRect(x: fill.minX, y: fill.maxY - 1.5, width: fill.width, height: 1.5).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }

        guard fade > 0.001 else { return }
        // Inside the bar the figure is near-black — white on these tones measures under
        // 2:1. Outside it (a short bar, or no bar at all) it goes back to the label color.
        let size = value.size()
        let ty = y + (barH - size.height) / 2 - 6 * (1 - fade)   // rises into place (D5)
        let text: NSAttributedString
        if inside {
            text = value
        } else {
            let shifted = NSMutableAttributedString(attributedString: value)
            shifted.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: 0, length: shifted.length))
            text = shifted
        }
        let x = inside ? 10 : min(w + 8, bounds.width - size.width)
        text.draw(at: NSPoint(x: x, y: ty), alpha: fade)
    }
}

// MARK: - Score ring

private final class NeonRing: NSView {

    private let lineW: CGFloat
    private let glowR: CGFloat
    private var progress: CGFloat = 0

    private let track = CAShapeLayer()
    private let bloom = CAShapeLayer()
    private let grad = CAGradientLayer()
    private let arc = CAShapeLayer()          // gradient's mask only — never in the tree
    private let number = NSTextField(labelWithString: "—")
    private let caption: NSTextField?

    init(lineWidth: CGFloat, glow: CGFloat, numberSize: CGFloat, caption: String?) {
        lineW = lineWidth
        glowR = glow
        self.caption = caption.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        wantsLayer = true

        for l in [track, bloom] { l.fillColor = nil; layer?.addSublayer(l) }
        arc.fillColor = nil
        arc.lineCap = .round
        bloom.lineCap = .round
        grad.mask = arc
        layer?.addSublayer(grad)

        number.font = Theme.roundedMono(numberSize, .bold)
        number.alignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        addSubview(number)

        var constraints = [
            number.centerXAnchor.constraint(equalTo: centerXAnchor),
            number.centerYAnchor.constraint(equalTo: centerYAnchor,
                                            constant: caption == nil ? 0 : -6),
        ]
        if let cap = self.caption {
            cap.font = Theme.font(9, .medium)
            cap.textColor = NeonInk.faint
            cap.alignment = .center
            cap.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cap)
            constraints += [
                cap.centerXAnchor.constraint(equalTo: centerXAnchor),
                cap.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 1),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The caption follows the selected range, so the ring is never labelled 「本周」
    /// over a number that is today's.
    func set(caption text: String) { caption?.stringValue = text }

    /// nil = below the sample floor. The ring then shows its empty track and the figure
    /// reads 「—」: a made-up score on three days of data would poison every other number
    /// on the panel (D6).
    func set(score: Int?) {
        progress = CGFloat(score ?? 0) / 100
        number.stringValue = score.map(String.init) ?? "—"
        number.textColor = score == nil ? NeonInk.faint : NeonInk.primary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = (min(bounds.width, bounds.height) - lineW) / 2
        let path = CGMutablePath()
        // Starts at 12 o'clock and fills clockwise, so a partial ring reads like a dial.
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(0, r),
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, bloom, arc] {
            l.frame = bounds
            l.path = path
            l.lineWidth = lineW
        }
        grad.frame = bounds
        bloom.strokeEnd = progress
        arc.strokeEnd = progress
        resolveColors()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// The dial sweeps up to the score (D5: 0.06s in, over 0.85s). Both strokes are
    /// CAShapeLayers, so this is the one part of the intro the layer tree can run on
    /// its own — no need to bother the panel's clock with it.
    func playIntro() {
        layoutSubtreeIfNeeded()
        for l in [bloom, arc] {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 0
            a.toValue = progress
            a.duration = 0.85
            a.beginTime = CACurrentMediaTime() + 0.06
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            l.add(a, forKey: "intro")
        }
    }

    private func resolveColors() {
        let a = Metric.accent(.saved), b = Metric.accent(.focus)
        track.strokeColor = NSColor.labelColor.withAlphaComponent(0.09).cg(in: self)
        bloom.strokeColor = a.cg(in: self)
        bloom.shadowColor = a.cg(in: self)
        bloom.shadowRadius = glowR
        bloom.shadowOpacity = 0.55
        bloom.shadowOffset = .zero
        arc.strokeColor = NSColor.black.cgColor      // a mask reads alpha, not hue
        grad.colors = [a.cg(in: self), b.cg(in: self)]
        grad.startPoint = CGPoint(x: 0, y: 1)        // 135°, matching the design
        grad.endPoint = CGPoint(x: 1, y: 0)
    }
}

// MARK: - Sparkline (collapsed bar)

private final class SparkLine: NSView {
    /// One entry per bucket, oldest first; nil is a bucket with no score, drawn as a
    /// break in the line rather than bridged over.
    var points: [Double?] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let vals = points
        guard vals.compactMap({ $0 }).count > 1 else { return }
        let accent = resolvedSRGB(Metric.accent(.saved))
        let lo = vals.compactMap { $0 }.min() ?? 0
        let hi = vals.compactMap { $0 }.max() ?? 1
        let span = max(hi - lo, 1)
        let inset: CGFloat = 3
        let w = bounds.width - inset * 2, h = bounds.height - inset * 2

        func point(_ i: Int, _ v: Double) -> NSPoint {
            NSPoint(x: inset + w * CGFloat(i) / CGFloat(max(vals.count - 1, 1)),
                    y: inset + h * CGFloat((v - lo) / span))
        }

        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        glow.set()

        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var pen = false
        for (i, v) in vals.enumerated() {
            guard let v else { pen = false; continue }
            let p = point(i, v)
            pen ? path.line(to: p) : path.move(to: p)
            pen = true
        }
        accent.withAlphaComponent(0.7).setStroke()
        path.stroke()

        // The last known bucket gets a dot — "you are here".
        if let last = vals.lastIndex(where: { $0 != nil }), let v = vals[last] {
            let p = point(last, v)
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - Trend curve (hero)

// What the chart draws, already reduced to 0…1. Keeping the normalisation OUT of the
// view is what lets the same frame plot a year of 效能分 or twenty-four hours of arrivals
// without a second copy of the axis, grid and wipe-in code.
struct TrendModel {
    let solid: [Double?]                    // nil breaks the line rather than bridging it
    let dashed: [Double]                    // empty = no second series
    let yLabels: [(frac: Double, text: String)]
    let xTicks: [(index: Int, text: String, align: NSTextAlignment)]

    /// One readout per point, shown beside the crosshair while the pointer is over that
    /// column. The axis can only afford six labels and the y axis only two or three, so
    /// without this a curve is a shape you cannot interrogate — you can see that a spike
    /// happened but not when, or how big. Empty array = this chart takes no hover.
    var hover: [String] = []

    var count: Int { solid.count }
    var isEmpty: Bool { solid.compactMap { $0 }.count < 2 }
}

private final class TrendChart: NSView {

    private var model = TrendModel(solid: [], dashed: [], yLabels: [], xTicks: [])

    /// Line colours. nil keeps the hero chart's original 省时/连续 pairing; the rate
    /// charts below override them so their series read as their own metric instead of
    /// borrowing two unrelated ones.
    var accents: (primary: NSColor, secondary: NSColor)?

    /// 0…1 — how much of the plot has been drawn (D5: the lines wipe in over 1s). Only
    /// the two lines are masked; the grid and the axis are the frame they arrive into
    /// and would look broken half-drawn.
    var drawProgress: CGFloat = 1 { didSet { needsDisplay = true } }

    func set(_ m: TrendModel) {
        model = m
        if let h = hoverIndex, h >= m.count { hoverIndex = nil }   // series shrank under us
        needsDisplay = true
    }

    /// Width reserved left of the plot for y-axis labels. 26 fits the hero curve's
    /// "100"/"50"/"0"; a token axis reaches "124.1M" and needs roughly half again.
    var gutter: CGFloat = 26
    private let axisH: CGFloat = 18, top: CGFloat = 8

    // MARK: Crosshair

    private var hoverIndex: Int?

    private var plotRect: NSRect {
        NSRect(x: gutter, y: axisH,
               width: max(0, bounds.width - gutter - 6),
               height: max(0, bounds.height - axisH - top))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        guard model.count > 1, !model.hover.isEmpty, plot.width > 0,
              p.x >= plot.minX - 8, p.x <= plot.maxX + 8 else {
            if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
            return
        }
        // Snap to the nearest column rather than the one to the left: the pointer sits
        // between samples most of the time, and rounding down makes the readout lag the
        // crosshair by up to a whole bucket.
        let frac = (p.x - plot.minX) / plot.width
        let i = min(model.count - 1, max(0, Int((frac * CGFloat(model.count - 1)).rounded())))
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard model.count > 1 else { return }
        let primary = resolvedSRGB(accents?.primary ?? Metric.accent(.saved))
        let secondary = resolvedSRGB(accents?.secondary ?? Metric.accent(.streak))
        let plot = NSRect(x: gutter, y: axisH,
                          width: max(0, bounds.width - gutter - 6),
                          height: max(0, bounds.height - axisH - top))
        guard plot.width > 0, plot.height > 0 else { return }

        // Grid + y axis. Both series are already 0…1; the dashed one rides the same frame
        // as a SHAPE, which is why it is labelled separately rather than sharing a unit.
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.roundedMono(8, .bold),
            .foregroundColor: primary.withAlphaComponent(0.6)]
        for (frac, text) in model.yLabels {
            let y = plot.minY + plot.height * CGFloat(frac)
            NeonInk.rule.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
            let s = text as NSString
            let sz = s.size(withAttributes: labelAttrs)
            s.draw(at: NSPoint(x: plot.minX - 6 - sz.width, y: y - sz.height / 2),
                   withAttributes: labelAttrs)
        }

        func x(_ i: Int) -> CGFloat {
            plot.minX + plot.width * CGFloat(i) / CGFloat(model.count - 1)
        }
        func y(_ v: Double) -> CGFloat { plot.minY + plot.height * CGFloat(max(0, min(1, v))) }

        // The two lines wipe in from the left; the axis labels below are NOT part of
        // that (they belong to the frame), so this clip is lifted again before them.
        NSGraphicsContext.current?.saveGraphicsState()
        if drawProgress < 1 {
            NSBezierPath(rect: NSRect(x: 0, y: 0,
                                      width: plot.minX + plot.width * drawProgress + 4,
                                      height: bounds.height)).addClip()
        }

        // The secondary series rides the same frame as a shape, which is why it is dashed
        // and separately labelled rather than sharing the axis's unit.
        if !model.dashed.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (i, v) in model.dashed.enumerated() {
                let pt = NSPoint(x: x(i), y: y(v))
                i == 0 ? path.move(to: pt) : path.line(to: pt)
            }
            path.setLineDash([3, 3], count: 2, phase: 0)
            secondary.withAlphaComponent(0.55).setStroke()
            path.stroke()
        }

        // The primary series — the one the axis belongs to. A nil breaks the line.
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = primary.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var pen = false
        for (i, v) in model.solid.enumerated() {
            guard let v else { pen = false; continue }
            let pt = NSPoint(x: x(i), y: y(v))
            pen ? path.line(to: pt) : path.move(to: pt)
            pen = true
        }
        primary.setStroke()
        path.stroke()
        if let last = model.solid.lastIndex(where: { $0 != nil }), let v = model.solid[last] {
            primary.setFill()
            let p = NSPoint(x: x(last), y: y(v))
            NSBezierPath(ovalIn: NSRect(x: p.x - 3.4, y: p.y - 3.4, width: 6.8, height: 6.8)).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGraphicsContext.current?.restoreGraphicsState()   // lift the wipe clip

        // Only the ends and the middle are labelled — eight dates in a row would be noise.
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10, .medium), .foregroundColor: NeonInk.secondary]
        for (i, text, align) in model.xTicks {
            let s = text as NSString
            let sz = s.size(withAttributes: axisAttrs)
            var px = x(i)
            switch align {
            case .center: px -= sz.width / 2
            case .right:  px -= sz.width
            default: break
            }
            s.draw(at: NSPoint(x: px, y: 2), withAttributes: axisAttrs)
        }

        // The crosshair goes on last and outside the wipe clip: it is the pointer's
        // position, not part of the drawing the chart animates into place.
        guard let hi = hoverIndex, hi < model.hover.count, !model.hover[hi].isEmpty else { return }
        let cx = x(hi)

        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: cx, y: plot.minY))
        rule.line(to: NSPoint(x: cx, y: plot.maxY))
        rule.lineWidth = 1
        rule.setLineDash([2, 3], count: 2, phase: 0)
        NeonInk.primary.withAlphaComponent(0.5).setStroke()
        rule.stroke()

        // Ring the sampled point so it is obvious WHICH value the readout belongs to —
        // on a dense series the crosshair alone lands between two visible wiggles.
        if hi < model.solid.count, let v = model.solid[hi] {
            primary.setFill()
            let pt = NSPoint(x: cx, y: y(v))
            NSBezierPath(ovalIn: NSRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)).fill()
        }

        // Same bubble the stats tab uses, so a readout looks like a readout everywhere.
        let bubbleAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10, .medium), .foregroundColor: NeonInk.primary]
        let text = model.hover[hi] as NSString
        let ts = text.size(withAttributes: bubbleAttrs)
        let padX: CGFloat = 7, padY: CGFloat = 4
        let w = ts.width + padX * 2, h = ts.height + padY * 2
        let bx = min(max(cx - w / 2, 0), max(0, bounds.width - w))
        let box = NSRect(x: bx, y: plot.maxY - h, width: w, height: h)
        let back = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NeonInk.bed(in: self).withAlphaComponent(0.96).setFill()
        back.fill()
        primary.withAlphaComponent(0.45).setStroke()
        back.lineWidth = 1
        back.stroke()
        text.draw(at: NSPoint(x: box.minX + padX, y: box.minY + padY), withAttributes: bubbleAttrs)
    }
}

// MARK: - Shared chrome

// The two containers share one material: a faint 省时绿→专注蓝 wash inside a green
// hairline. Painted in draw() rather than baked into layers so a light/dark flip
// re-resolves it for free.
private class NeonSurface: NSView {

    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var radius: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        let a = resolvedSRGB(Metric.accent(.saved))
        let b = resolvedSRGB(Metric.accent(.focus))
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)

        // The card always lays its own bed, in both appearances — dark in both, so the
        // accents always have something to glow against. See the note on NeonInk for why
        // this also decides the text colour on top.
        NeonInk.bed(in: self).setFill()
        path.fill()

        // The resting wash IS what the hover state used to be — the old resting value was
        // too faint to separate the card from the window at a glance. Hover now lifts
        // from there, for the surfaces where hovering still means anything.
        NSGradient(starting: a.withAlphaComponent(hovering ? 0.21 : 0.15),
                   ending: b.withAlphaComponent(hovering ? 0.10 : 0.07))?
            .draw(in: path, angle: -45)
        path.lineWidth = 1
        a.withAlphaComponent(hovering ? 0.44 : 0.34).setStroke()
        path.stroke()
    }
}

// The 24×24 disclosure control: ▼ on the collapsed bar, ▲ in the hero's top-right
// corner. Filled with the ring's own gradient so the two read as one control moving.
private final class TriangleButton: NSView {

    var onClick: (() -> Void)?
    private let pointsUp: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(pointsUp: Bool) {
        self.pointsUp = pointsUp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let a = resolvedSRGB(Metric.accent(.saved))
        let b = resolvedSRGB(Metric.accent(.focus))
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 7, yRadius: 7)
        a.withAlphaComponent(hovering ? 0.16 : 0.07).setFill()
        chip.fill()
        chip.lineWidth = 1
        a.withAlphaComponent(hovering ? 0.45 : 0.22).setStroke()
        chip.stroke()

        let w: CGFloat = 10, h: CGFloat = 7
        let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
        let tri = NSBezierPath()
        if pointsUp {
            tri.move(to: NSPoint(x: ox, y: oy))
            tri.line(to: NSPoint(x: ox + w, y: oy))
            tri.line(to: NSPoint(x: ox + w / 2, y: oy + h))
        } else {
            tri.move(to: NSPoint(x: ox, y: oy + h))
            tri.line(to: NSPoint(x: ox + w, y: oy + h))
            tri.line(to: NSPoint(x: ox + w / 2, y: oy))
        }
        tri.close()

        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = a.withAlphaComponent(hovering ? 0.9 : 0.55)
        glow.shadowBlurRadius = hovering ? 8 : 4
        glow.shadowOffset = .zero
        glow.set()
        a.setFill()
        tri.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(starting: a, ending: b)?.draw(in: tri, angle: -45)
    }
}

// A tiny tinted capsule for the 「良好」 verdict beside the title.
private final class TagPill: NSView {

    private var text = ""
    private var color = NSColor.labelColor
    private let padX: CGFloat = 6, height: CGFloat = 15

    func set(text: String, color: NSColor) {
        self.text = text
        self.color = color
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: Theme.rounded(9.5, .bold), .foregroundColor: color]
    }

    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return NSSize(width: 0, height: height) }
        return NSSize(width: (text as NSString).size(withAttributes: attrs).width + padX * 2,
                      height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let c = resolvedSRGB(color)
        let path = NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2)
        c.withAlphaComponent(0.16).setFill()
        path.fill()
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: padX, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Period vocabulary
//
// Every headline on this panel names the period it is talking about. One table, so
// 「今日」 can never end up over a card whose numbers are the month's.
extension TimeRange {

    /// The panel's own title, over the ring and on the collapsed bar.
    var impactTitle: String {
        switch self {
        case .today: return L("今日效能", "Today")
        case .week:  return L("本周效能", "This week")
        case .month: return L("本月效能", "This month")
        case .all:   return L("全部效能", "All time")
        }
    }

    /// The noun a sentence opens with: 「本周替你省下 …」.
    var impactNoun: String {
        switch self {
        case .today: return L("今日", "Today")
        case .week:  return L("本周", "This week")
        case .month: return L("本月", "This month")
        case .all:   return L("累计", "All time")
        }
    }

    /// 「较上周」. Empty under 全部 — a single bucket has no predecessor.
    var vsPrevious: String {
        switch self {
        case .today: return L(" 较昨日", " vs yesterday")
        case .week:  return L(" 较上周", " vs last week")
        case .month: return L(" 较上月", " vs last month")
        case .all:   return ""
        }
    }

    var noPrevious: String {
        switch self {
        case .today: return L("还没有昨日可比", "no prior day yet")
        case .week:  return L("还没有上周可比", "no prior week yet")
        case .month: return L("还没有上月可比", "no prior month yet")
        case .all:   return L("全部区间没有可比的上一期", "all-time has no prior period")
        }
    }

    /// The unit of 「还需 N 周才有纪录可比」.
    var bucketNoun: String {
        switch self {
        case .today: return L("天", "days")
        case .week:  return L("周", "weeks")
        case .month: return L("月", "months")
        case .all:   return L("期", "periods")
        }
    }

    /// The curve's granularity, for 「本周按天 · 共 N 次到达」.
    var stepNoun: String {
        switch self {
        case .today:        return L("按小时", "by hour")
        case .week, .month: return L("按天", "by day")
        case .all:          return L("按月", "by month")
        }
    }

    /// The fine series has its own grain, so it needs its own word — `stepNoun` above
    /// describes the hero curve and would mislabel this one by a factor of twelve.
    /// DERIVED from `rateBucket` rather than written out beside it: a hand-written
    /// table would go on claiming "每 5 分钟" after someone widened the bucket, and
    /// nothing would fail — the chart would just quietly lie about its own axis.
    var rateNoun: String {
        let s = rateBucket
        guard s % 3600 == 0 else { return L("每 \(s / 60) 分钟", "per \(s / 60) min") }
        let h = s / 3600
        return h == 24 ? L("每天", "per day") : L("每 \(h) 小时", "per \(h) h")
    }
}

// MARK: - Formatting
//
// Every string the panel shows, in one place — the wording is part of the design (it was
// argued over for 19 rounds) and scattering it through the views is how it drifts.

enum ImpactFormat {

    static func name(_ m: Metric) -> String {
        switch m {
        case .saved:   return L("省时", "Saved")
        case .focus:   return L("专注", "Focus")
        case .streak:  return L("连续", "Streak")
        case .auto:    return L("托管", "Auto")
        case .control: return L("掌控", "Control")
        case .work:    return L("工作", "Work")
        case .tokens:  return L("消耗", "Tokens")
        }
    }

    // SF Symbols standing in for the design's hand-drawn glyphs — same shapes (clock /
    // concentric circles / flame / bolt / parallel bars), and they track the system's
    // weight and optical sizing for free.
    static func symbol(_ m: Metric) -> NSImage? {
        let names: [String]
        switch m {
        case .saved:   names = ["clock"]
        case .focus:   names = ["circle.circle", "scope", "circle"]
        case .streak:  names = ["flame.fill"]
        case .auto:    names = ["bolt.fill"]
        case .control: names = ["chart.bar.fill"]
        case .work:    names = ["laptopcomputer"]
        case .tokens:  names = ["circle.hexagongrid.fill", "circle.grid.3x3.fill"]
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: name(m)) {
                return img.withSymbolConfiguration(config)
            }
        }
        return nil
    }

    /// A metric's headline figure, split into number and unit — the unit is set smaller
    /// and faded, so the number is what the eye lands on.
    static func value(_ m: Metric, _ w: PeriodImpact) -> NSAttributedString {
        let v = w.metric(m).value
        let numFont = Theme.roundedMono(11.5, .heavy)
        let unitFont = Theme.roundedMono(9.5, .heavy)
        let ink = NSColor.black.withAlphaComponent(0.8)
        let out = NSMutableAttributedString()
        func num(_ s: String) {
            out.append(NSAttributedString(string: s, attributes: [
                .font: numFont, .foregroundColor: ink]))
        }
        func unit(_ s: String) {
            out.append(NSAttributedString(string: " " + s, attributes: [
                .font: unitFont, .foregroundColor: ink.withAlphaComponent(0.62)]))
        }
        switch m {
        case .saved:
            // Without a baseline there is no saved-time figure — and 「0m」 states
            // something false ("this app saved you nothing") where the truth is that
            // there is nothing to measure it against yet (D3).
            guard w.saved.trustworthy else {
                out.append(NSAttributedString(string: L("暂无基线", "no baseline yet"),
                    attributes: [.font: unitFont, .foregroundColor: ink.withAlphaComponent(0.62)]))
                return out
            }
            num(hm(v))
        case .focus:
            num(hm(v))
        case .streak:
            num("\(v)"); unit(L("天", "d"))
        case .auto:
            num("\(v)"); unit(L("次", "jumps"))
        case .control:
            num("\(v)")
            unit(L("线 · \(w.control.stranded) 漏", "live · \(w.control.stranded) missed"))
        case .work:
            num(hm(v))
        case .tokens:
            num(Tok.fmt(v))
        }
        return out
    }

    /// The right-hand note: what this period is measured against. A record says so on
    /// its own line and names the mark it beat — the bar being full is the claim, this is
    /// the evidence.
    static func note(_ v: MetricValue, period: PeriodImpact) -> NSAttributedString {
        let small = Theme.roundedMono(9.5, .regular)
        let bold = Theme.roundedMono(9.5, .bold)
        let out = NSMutableAttributedString()
        guard period.comparable else {
            // 全部 is one bucket. 「最佳」 would be this same number quoted back, which
            // reads as a comparison the panel never actually made.
            out.append(NSAttributedString(string: L("累计总量", "all-time total"),
                attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
            return out
        }
        if period.bucketsTracked < ImpactRule.newUserBuckets {
            // The bar is full because this IS the first one; say so, or a full bar reads
            // as an achievement. The 「还需 N 周」 part is true of all five at once and is
            // said once in the section caption instead of five times down the column.
            out.append(NSAttributedString(string: L("首次记录", "first on record"),
                attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
            return out
        } else if v.isRecord {
            out.append(NSAttributedString(string: L("破纪录\n", "Record\n"), attributes: [
                .font: bold, .foregroundColor: Metric.accent(v.metric)]))
            out.append(NSAttributedString(string: L("上一个 \(unitText(v.metric, v.priorBest, period))",
                                                    "was \(unitText(v.metric, v.priorBest, period))"),
                attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            out.append(NSAttributedString(string: L("最佳 \(unitText(v.metric, v.best, period))",
                                                    "best \(unitText(v.metric, v.best, period))"),
                attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }

    private static func unitText(_ m: Metric, _ v: Int, _ w: PeriodImpact) -> String {
        switch m {
        case .saved, .focus: return hm(v)
        case .streak:        return L("\(v) 天", "\(v)d")
        case .auto:          return L("\(v) 次", "\(v)")
        case .control:       return L("\(v) 线", "\(v)")
        case .work:          return hm(v)
        case .tokens:        return Tok.fmt(v)
        }
    }

    // MARK: Detail card content (3.2)
    //
    // Same three sections for every metric, always in this order: what it means, three
    // facts from this week, one line of 「怎么算的」. The last line answers only the ONE
    // question that metric provokes — the 3s debounce, the 5-minute cap, the log mapping
    // and the 40/30/30 weights are deliberately NOT here. Everything a user might ever
    // want lives in the settings page's long form; this card has to stay readable.

    static func detailHeadline(_ m: Metric, _ w: PeriodImpact) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: value(m, w))
        // Two fixes over the bar's own figure: it is near-black there so it can sit ON
        // the neon (invisible on the card in dark mode), and an attributed string carries
        // its own paragraph style, which would override the field's right alignment.
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        out.addAttributes([.foregroundColor: NSColor.labelColor, .paragraphStyle: para],
                          range: NSRange(location: 0, length: out.length))
        return out
    }

    static func detailMeaning(_ m: Metric, _ w: PeriodImpact) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11, .semibold), .foregroundColor: NSColor.labelColor]
        let hi: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11, .semibold), .foregroundColor: Metric.accent(m)]
        let out = NSMutableAttributedString()
        func t(_ zh: String, _ en: String) { out.append(NSAttributedString(string: L(zh, en), attributes: base)) }
        func b(_ zh: String, _ en: String) { out.append(NSAttributedString(string: L(zh, en), attributes: hi)) }

        switch m {
        case .saved:
            t("提醒和跳转让你", "Time you did not spend waiting because a banner or a jump ")
            b("少等的时间", "got there first")
            t("，按跳转类型分别计算。", " — counted separately for each kind of jump.")
        case .focus:
            t("你停在一个终端连续工作、", "The longest stretch you stayed in one terminal ")
            b("没被任何会话拽走", "without another session pulling you away")
            t("的最长一段。", ".")
        case .streak:
            t("连续用 SpectiX 的天数，", "Days in a row you have used SpectiX — ")
            b("断一天就归零", "one missed day resets it")
            t("。", ".")
        case .auto:
            t("自动跳转直接把你送到，", "Times an automatic jump delivered you, ")
            b("你完全没动手", "with nothing to do on your part")
            t("的次数。", ".")
        case .control:
            let missed = w.control.stranded
            t("同时活跃的会话最多几个，", "How many sessions ran at once, and ")
            if missed == 0 {
                b("且一个都没被晾超过 10 分钟", "not one of them was left waiting over 10 minutes")
                t("。", ".")
            } else {
                b("其中 \(missed) 个被晾了超过 10 分钟",
                  "\(missed) of them sat unanswered for over 10 minutes")
                t("。", ".")
            }
        case .work:
            t("你自己", "How long ")
            b("坐在电脑前干活", "you yourself were at it")
            t("的时间 —— 量的是人，不是 Claude。", " — the person, not Claude.")
        case .tokens:
            t("所有会话", "Tokens every session ")
            b("一共消耗的 token", "burned between them")
            t("，包括缓存读写。", ", cache reads and writes included.")
        }
        return out
    }

    static func detailFacts(_ m: Metric, _ w: PeriodImpact) -> [(label: String, value: String)] {
        switch m {
        case .saved:
            // Always the same three lines, in the same order, even at zero — which of
            // the three paths you never use is itself worth seeing.
            let trusted = w.saved.trustworthy
            func row(_ kinds: [ImpactKind], _ zh: String, _ en: String) -> (String, String) {
                let hits = w.saved.rows.filter { kinds.contains($0.kind) }
                let n = hits.reduce(0) { $0 + $1.count }
                let sec = hits.reduce(0) { $0 + $1.savedSec }
                return (L("\(zh) · \(n) 次", "\(en) · \(n)"),
                        trusted ? (n > 0 ? hm(sec) : "—") : "—")
            }
            return [row([.jumpManual], "点通知横幅", "Banner clicks"),
                    row([.jumpHotkey], "快捷键跳转", "Hotkey jumps"),
                    row([.jumpAutoChain, .jumpAutoIdle], "自动跳转", "Automatic jumps")]
        case .focus:
            let f = w.focus
            return [(L("\(w.range.impactNoun)专注段数", "Stretches this period"),
                     L("\(f.segments) 段", "\(f.segments)")),
                    (L("平均每段", "Average stretch"), f.avgSec > 0 ? hm(f.avgSec) : "—"),
                    (L("最长一段", "Longest stretch"),
                     f.longestSec > 0 ? "\(hm(f.longestSec)) · \(dayHalf(f.longestAt))" : "—")]
        case .streak:
            let s = w.streak, v = w.metric(.streak)
            return [(L("本轮起点", "Run started"), s.startTs > 0 ? monthDay(s.startTs) : "—"),
                    (L("上一个纪录", "Previous record"),
                     v.priorBest > 0 ? L("\(v.priorBest) 天", "\(v.priorBest)d") : L("还没有", "none yet")),
                    (L("今天状态", "Today"), s.todayCounted ? L("已达成", "counted")
                                                            : L("还没跑过会话", "no session yet"))]
        case .auto:
            let a = w.auto
            return [(L("答完自动连跳", "Answered-chain jumps"),
                     a.chain > 0 ? L("\(a.chain) 次 · 最长 \(a.longestChain) 连",
                                     "\(a.chain) · longest run \(a.longestChain)")
                                 : L("0 次", "0")),
                    (L("闲置自动跳", "Idle auto-jumps"), L("\(a.idle) 次", "\(a.idle)")),
                    (L("「先处理手头的红」拦下", "Held back by the parked latch"),
                     L("\(a.blocked) 次", "\(a.blocked)"))]
        case .control:
            let c = w.control
            return [(L("峰值出现在", "Peak was"),
                     c.peak > 0 ? L("\(dayTime(c.peakAt)) · \(c.peak) 线",
                                    "\(dayTime(c.peakAt)) · \(c.peak) live") : "—"),
                    (L("常态（P75）", "Everyday level (P75)"), L("\(c.p75) 线", "\(c.p75)")),
                    (L("被晾超 10 分钟", "Left over 10 minutes"),
                     L("\(c.stranded) 个 / \(c.scored) 个计分", "\(c.stranded) of \(c.scored) scored"))]
        case .work, .tokens:
            let v = w.metric(m)
            let f: (Int) -> String = m == .work ? { hm($0) } : { Tok.fmt($0) }
            return [(L("\(w.range.impactNoun)", "This period"), f(v.value)),
                    (L("上一期", "Previous period"), w.comparable ? f(v.previous) : "—"),
                    (L("最佳一期", "Best period"), w.comparable && v.best > 0 ? f(v.best) : "—")]
        }
    }

    static func detailHow(_ m: Metric, _ w: PeriodImpact) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: Theme.font(9.5, .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let hi: [NSAttributedString.Key: Any] = [
            .font: Theme.font(9.5, .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let out = NSMutableAttributedString()
        func t(_ zh: String, _ en: String) { out.append(NSAttributedString(string: L(zh, en), attributes: base)) }
        func b(_ zh: String, _ en: String) { out.append(NSAttributedString(string: L(zh, en), attributes: hi)) }

        switch m {
        case .saved:
            guard w.saved.trustworthy else {
                let need = max(0, ImpactRule.baselineMinSamples - w.saved.baselineSamples)
                t("基线只能来自", "The baseline can only come from arrivals you made ")
                b("你自己找到的到达", "without help")
                t("，\(w.range.impactNoun)还差 \(need) 次 —— 所以先不给省时数字。",
                  " — \(need) short this period, so no saved-time figure yet.")
                return out
            }
            t("基线是", "The baseline is the median ")
            b("你自己猜着切过去", "delay when you found a session yourself")
            t("的延迟中位 \(w.saved.baselineSec) 秒（\(w.range.impactNoun) \(w.saved.baselineSamples) 次）—— 不是行业数据。",
              ": \(w.saved.baselineSec)s over \(w.saved.baselineSamples) arrivals this period — not an industry figure.")
        case .focus:
            t("一段 = 你待在同一个终端不动、期间", "A stretch = you stayed in one terminal and ")
            b("有键鼠活动", "actually typed or clicked")
            t("的连续区间；切走即结束。", "; it ends the moment focus moves.")
        case .streak:
            t("当天有任意一个会话跑起来就算，", "Any session running that day counts — ")
            b("不需要你做什么额外的事", "there is nothing extra to do")
            t("。", ".")
        case .auto:
            t("被拦下的不算跳转 —— 那是", "A held-back jump is not counted — that is the app ")
            b("保护你不被从手头的确认上拽走", "refusing to drag you off the prompt in front of you")
            t("。", ".")
        case .control:
            t("只在你", "A miss only counts while you were ")
            b("在电脑前", "at the machine")
            t("时计遗漏 —— 你去吃饭时会话就绪，不算你的。",
              " — a session going quiet while you are at lunch is not yours to miss.")
        case .work:
            t("就是番茄计时走过的时间：", "The time the 🍅 clock ran: ")
            b("离开 5 分钟就停表", "it stops once you are away 5 minutes")
            t("（有会话在跑时 20 分钟），App 关着的时间不算。",
              " (20 with a session running), and time with the app closed does not count.")
        case .tokens:
            t("每轮结束时从会话记录里读出来的，", "Read from each turn's transcript when it ends — ")
            b("和下面用量里的 token 是同一个数", "the same figure as the token usage below")
            t("。", ".")
        }
        return out
    }

    // MARK: Dates
    //
    // 「周三 15:20」 rather than a timestamp: the user is being invited to remember the
    // moment and check it, and nobody remembers epoch seconds.

    private static func cal() -> Calendar { Calendar.current }

    private static func hourLabel(_ ts: Int) -> String {
        let h = cal().component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return L("\(h) 时", "\(h):00")
    }

    private static func dayOfMonth(_ ts: Int) -> String {
        let d = cal().component(.day, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return L("\(d) 日", "\(d)")
    }

    private static let monthEn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func monthLabel(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        return L("\(cal().component(.month, from: d)) 月", monthEn.string(from: d))
    }

    private static func weekday(_ ts: Int) -> String {
        let wd = cal().component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let zh = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let i = max(0, min(6, wd - 1))
        return L(zh[i], en[i])
    }

    static func dayTime(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let c = cal().dateComponents([.hour, .minute], from: d)
        return String(format: "%@ %02d:%02d", weekday(ts), c.hour ?? 0, c.minute ?? 0)
    }

    static func dayHalf(_ ts: Int) -> String {
        let h = cal().component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let part = h < 12 ? L("上午", " morning") : h < 18 ? L("下午", " afternoon")
                                                           : L("晚上", " evening")
        return weekday(ts) + part
    }

    static func monthDay(_ ts: Int) -> String {
        let c = cal().dateComponents([.month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return L("\(c.month ?? 0) 月 \(c.day ?? 0) 日", "\(c.month ?? 0)/\(c.day ?? 0)")
    }

    /// Score bands. The score is a 0–100 composite and a bare number invites the wrong
    /// question ("why not 100?"); the word says whether this period was fine.
    static func band(_ score: Int?) -> String {
        guard let s = score else { return L("攒数据中", "Collecting") }
        switch s {
        case 90...: return L("出色", "Excellent")
        case 75...: return L("良好", "Good")
        case 60...: return L("尚可", "Fair")
        default:    return L("待提升", "Low")
        }
    }

    /// 「↑ 6 较上周 · 2 项破纪录」. A worse period says so, in the warning color and with
    /// no softening — a panel that only ever reports good news is one nobody believes (D6).
    ///
    /// The comparison is against the PREVIOUS PERIOD, which the rollup carries — reading
    /// it off the curve's second-to-last point would compare 本周 against yesterday, since
    /// the curve is drawn at the range's own granularity.
    static func foldSubline(_ w: PeriodImpact) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let faint: [NSAttributedString.Key: Any] = [
            .font: Theme.font(9.5, .regular), .foregroundColor: NSColor.secondaryLabelColor]

        if let now = w.score.value, let prev = w.previousScore {
            let d = now - prev
            let color: NSColor = d > 0 ? Metric.accent(.saved)
                               : d < 0 ? Status.accent("needs") : .secondaryLabelColor
            out.append(NSAttributedString(string: d > 0 ? "↑ \(d)" : d < 0 ? "↓ \(-d)" : "±0",
                attributes: [.font: Theme.roundedMono(9.5, .bold), .foregroundColor: color]))
            out.append(NSAttributedString(string: w.range.vsPrevious, attributes: faint))
        } else {
            out.append(NSAttributedString(string: w.range.noPrevious, attributes: faint))
        }

        if w.records > 0 {
            out.append(NSAttributedString(string: " · ", attributes: faint))
            out.append(NSAttributedString(string: L("\(w.records) 项", "\(w.records)"), attributes: [
                .font: Theme.roundedMono(9.5, .bold), .foregroundColor: Metric.accent(.saved)]))
            out.append(NSAttributedString(string: L("破纪录", " records"), attributes: faint))
        }
        return out
    }

    static func heroHeadline(_ w: PeriodImpact) -> String {
        let b = band(w.score.value)
        guard w.records > 0 else { return b }
        return L("\(b) · \(w.records) 项破纪录", "\(b) · \(w.records) records broken")
    }

    /// The one sentence the panel exists for. Below the sample floor it says what it is
    /// still waiting for instead of guessing (D6).
    static func heroDetail(_ w: PeriodImpact) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11, .regular), .foregroundColor: NeonInk.secondary]
        let strong: [NSAttributedString.Key: Any] = [
            .font: Theme.roundedMono(11.5, .bold), .foregroundColor: Metric.accent(.saved)]
        let out = NSMutableAttributedString()

        guard w.score.enoughData else {
            let need = max(0, ImpactRule.scoreMinArrivals - w.score.arrivals)
            out.append(NSAttributedString(
                string: L("攒数据中 · 还需 \(need) 次到达才给出效能分。",
                          "Collecting · \(need) more arrivals before a score."), attributes: body))
            return out
        }
        // 省时 is the one figure with a multiplier in it, and its multiplier is measured
        // against arrivals you made WITHOUT help. Too few of those and the number is
        // withheld — saying "saved you 0m" would read as "this app did nothing", when the
        // truth is "we don't have a baseline to weigh it against yet" (D3).
        guard w.saved.trustworthy else {
            let need = max(0, ImpactRule.baselineMinSamples - w.saved.baselineSamples)
            out.append(NSAttributedString(string: L("\(w.range.impactNoun)少扑空 ", ""), attributes: body))
            out.append(NSAttributedString(string: "\(w.score.effectiveArrivals)", attributes: strong))
            out.append(NSAttributedString(
                string: L(" 次。省时还差 \(need) 次「你自己找到的」到达才有基线。",
                          " trips weren't wasted. Saved-time needs \(need) more unassisted arrivals for a baseline."),
                attributes: body))
            return out
        }
        out.append(NSAttributedString(string: L("\(w.range.impactNoun)替你省下 ", "Saved you "), attributes: body))
        out.append(NSAttributedString(string: hm(w.metric(.saved).value), attributes: strong))
        out.append(NSAttributedString(string: L(" 等待、少扑空 ", " of waiting, and "), attributes: body))
        out.append(NSAttributedString(string: "\(w.score.effectiveArrivals)", attributes: strong))
        out.append(NSAttributedString(string: L(" 次。", " trips that weren't wasted."), attributes: body))
        return out
    }

    // MARK: Trend models
    //
    // Both curves are normalised here rather than in the view, so one drawing routine
    // serves both and the axis can never disagree with the line it is labelling.

    /// Which of the two series the curve draws. 效能分 is the real subject, but it needs
    /// the sample floor cleared in at least TWO buckets before there is a line to join
    /// up — an hour of arrivals never clears it, a month usually does. The decision is
    /// taken once for the whole curve rather than per point: a line that changed units
    /// halfway along would be lying about its own axis.
    /// Whether the SCORED curve is the one worth drawing — not merely whether scores
    /// exist. A score needs a sample floor under it and an hour rarely clears that
    /// floor: on a real day only 3 of 22 hourly buckets scored, and three points with
    /// nineteen breaks between them draw as a single dot with no line at all. Counts
    /// have no floor, so where scores are this sparse the count curve is the one
    /// carrying the information. Requiring a majority is what keeps 今日 on counts and
    /// 本周/本月 — where every bucket scores — on the score.
    static func scored(_ pts: [TrendPoint]) -> Bool {
        let n = pts.compactMap { $0.score }.count
        return n >= 2 && n * 2 >= pts.count
    }

    /// The curve for one range, at that range's own granularity (hours / days / months —
    /// the same split the usage histogram below uses). Scores when there are scores,
    /// plain arrival and jump counts otherwise; counts have no sample floor under them,
    /// which is why they can be drawn at any granularity.
    static func trendModel(_ pts: [TrendPoint], _ range: TimeRange) -> TrendModel {
        guard pts.count > 1 else {
            return TrendModel(solid: [], dashed: [], yLabels: [], xTicks: [])
        }
        let ticks = xTicks(pts, range)
        guard scored(pts) else {
            // Plain counts, so the y axis is labelled with the actual peak instead of a
            // 0–100 score that would be meaningless on three arrivals.
            let top = Double(max(pts.map { max($0.arrivals, $0.jumps) }.max() ?? 0, 1))
            return TrendModel(
                solid: pts.map { Double($0.arrivals) / top },
                dashed: pts.contains { $0.jumps > 0 } ? pts.map { Double($0.jumps) / top } : [],
                yLabels: [(1.0, "\(Int(top))"), (0.5, "\(Int(top / 2))"), (0.0, "0")],
                xTicks: ticks,
                hover: pts.map { p in
                    L("\(trendStamp(p.start, range)) · 到达 \(p.arrivals) · 跳转 \(p.jumps)",
                      "\(trendStamp(p.start, range)) · \(p.arrivals) arrivals · \(p.jumps) jumps")
                })
        }
        let savedMax = Double(pts.map { $0.savedSec }.max() ?? 0)
        return TrendModel(
            solid: pts.map { $0.score.map { Double($0) / 100 } },
            dashed: savedMax > 0 ? pts.map { Double($0.savedSec) / savedMax } : [],
            yLabels: [(1.0, "100"), (0.5, "50"), (0.0, "0")],
            xTicks: ticks,
            hover: pts.map { p in
                let head = trendStamp(p.start, range)
                // A bucket under the sample floor has no score, and saying "0 分" for it
                // would report a bad day where there was simply not enough to judge.
                guard let sc = p.score else {
                    return L("\(head) · 样本不足", "\(head) · not enough to score")
                }
                guard p.savedSec > 0 else { return L("\(head) · \(sc) 分", "\(head) · \(sc)") }
                return L("\(head) · \(sc) 分 · 省 \(p.savedSec / 60) 分钟",
                         "\(head) · \(sc) · saved \(p.savedSec / 60)m")
            })
    }

    /// Timestamp for the hero curve's crosshair, at that range's own grain.
    private static func trendStamp(_ ts: Int, _ range: TimeRange) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        switch range {
        case .today: fmt.dateFormat = "HH:mm"
        case .week, .month: fmt.dateFormat = "M/d"
        case .all: fmt.dateFormat = L("yyyy年M月", "MMM yyyy")
        }
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Evenly spaced labels at whatever stride keeps the count at or under `maxTicks` —
    /// a full week gets all seven weekdays, a month of days gets every fifth. Fixed at
    /// three (ends + middle) it read as an axis with nothing on it; thirty dates in a row
    /// would be the opposite problem, and every label here is 2–4 characters wide, so
    /// seven of them clear each other at any width this panel is ever given.
    private static let maxTicks = 7

    private static func xTicks(_ pts: [TrendPoint],
                               _ range: TimeRange) -> [(Int, String, NSTextAlignment)] {
        let n = pts.count
        guard n >= 2 else { return [] }
        func label(_ i: Int) -> String {
            let ts = pts[i].start
            switch range {
            case .today: return hourLabel(ts)
            case .week:  return weekday(ts)
            case .month: return dayOfMonth(ts)
            case .all:   return monthLabel(ts)
            }
        }
        let now: String
        switch range {
        case .today:        now = L("现在", "Now")
        case .week, .month: now = L("今天", "Today")
        case .all:          now = L("本月", "Now")
        }
        let stride = max(1, Int(ceil(Double(n - 1) / Double(maxTicks))))
        var ticks: [(Int, String, NSTextAlignment)] = []
        var i = 0
        while i < n - 1 {
            // Anything inside one stride of the end would crowd 「现在」, which owns that
            // slot outright — it is the only label people look for by name.
            if n - 1 - i >= stride { ticks.append((i, label(i), i == 0 ? .left : .center)) }
            i += stride
        }
        ticks.append((n - 1, now, .right))
        return ticks
    }

    /// The burn-rate curve. Unlike `trendModel` above, the dashed series here is a
    /// SUBSET of the solid one (the unattended share of the same tokens), not an
    /// independent shape — so the two genuinely share the axis and its labels.
    static func rateModel(_ pts: [RatePoint]) -> TrendModel {
        guard pts.count > 1 else {
            return TrendModel(solid: [], dashed: [], yLabels: [], xTicks: [])
        }
        // A flat-zero range still gets an axis, but only one label on it: scaling to a
        // placeholder peak of 1 would print "1 / 0 / 0" and invent a ceiling nobody hit.
        let peak = pts.map { $0.tok }.max() ?? 0
        let top = max(peak, 1)
        return TrendModel(
            solid: pts.map { $0.tok / top },
            dashed: pts.contains { $0.autoTok > 0 } ? pts.map { $0.autoTok / top } : [],
            yLabels: peak > 0
                ? [(1.0, axisTok(Int(top))), (0.5, axisTok(Int(top / 2))), (0.0, "0")]
                : [(0.0, "0")],
            xTicks: rateTicks(pts),
            hover: pts.map { p in
                let stamp = rateStamp(p.start, span: span(pts))
                guard p.autoTok > 0 else { return "\(stamp) · \(Tok.fmt(Int(p.tok)))" }
                return L("\(stamp) · \(Tok.fmt(Int(p.tok)))（托管 \(Tok.fmt(Int(p.autoTok))))",
                         "\(stamp) · \(Tok.fmt(Int(p.tok))) (\(Tok.fmt(Int(p.autoTok))) unattended)")
            })
    }

    /// Concurrent terminals. The axis is labelled with the observed peak rather than a
    /// rounded scale: at a peak of four, a "5" gridline implies a terminal that never
    /// existed. Whole numbers only, for the same reason.
    static func concurrencyModel(_ pts: [RatePoint]) -> TrendModel {
        guard pts.count > 1 else {
            return TrendModel(solid: [], dashed: [], yLabels: [], xTicks: [])
        }
        let peak = pts.map { $0.sessions }.max() ?? 0
        // A gridline per terminal, not just floor and ceiling. Unlike tokens — a
        // continuous quantity where three ticks are plenty — this axis counts things,
        // and every step on it is a whole terminal somebody could point at. Labelling
        // only "0" and "4" leaves the reader measuring the line against nothing.
        // The step opens up (1 → 2 → 5 → …) once six lines would no longer fit, and the
        // ceiling rounds up to a multiple of it so the top line is always labelled.
        var step = 1
        for s in [1, 2, 5, 10, 20, 50] where (peak / s) + 1 <= 6 { step = s; break }
        let topInt = max(step, ((peak + step - 1) / step) * step)
        let top = Double(topInt)
        return TrendModel(
            solid: pts.map { Double($0.sessions) / top },
            dashed: [],
            yLabels: peak > 0
                ? stride(from: 0, through: topInt, by: step).map {
                      (Double($0) / top, "\($0)")
                  }
                : [(0.0, "0")],
            xTicks: rateTicks(pts),
            hover: pts.map { p in
                let stamp = rateStamp(p.start, span: span(pts))
                return L("\(stamp) · \(p.sessions) 个终端",
                         "\(stamp) · \(p.sessions) terminal\(p.sessions == 1 ? "" : "s")")
            })
    }

    /// Token labels for a y AXIS, which is tighter than anywhere else they appear: the
    /// gutter is shared with the hero curve above (so the three plots start at the same
    /// x and read as one stack), and "124.1M" does not fit in it while "124M" does.
    /// The crosshair readout keeps the decimal — an axis needs to be short, a readout
    /// needs to be exact.
    private static func axisTok(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return "\(n / 1_000_000)M"
        case 1_000...:     return "\(n / 1_000)k"
        default:           return "\(n)"
        }
    }

    private static func span(_ pts: [RatePoint]) -> Int {
        guard let f = pts.first, let l = pts.last else { return 0 }
        return l.start - f.start
    }

    /// A single bucket's timestamp for the crosshair readout. Carries more than the axis
    /// tick does — the axis can only fit six labels, and the whole point of the readout
    /// is to name the column the axis had to skip.
    private static func rateStamp(_ ts: Int, span: Int) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateFormat = span <= 86400 ? "HH:mm" : (span <= 86400 * 40 ? "M/d HH:mm" : "M/d")
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Clock labels for the fine axis. 今日 is minutes apart so it reads as a time of
    /// day; every wider range is labelled by date. Six is the most that clear each
    /// other at the widths this panel is given.
    private static func rateTicks(_ pts: [RatePoint])
        -> [(index: Int, text: String, align: NSTextAlignment)] {
        guard pts.count > 1 else { return [] }
        let span = (pts.last!.start - pts.first!.start)
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateFormat = span <= 86400 ? "HH:mm" : L("M/d", "M/d")
        func label(_ i: Int) -> String {
            fmt.string(from: Date(timeIntervalSince1970: TimeInterval(pts[i].start)))
        }
        let n = pts.count
        let stride = max(1, n / 6)
        var out: [(index: Int, text: String, align: NSTextAlignment)] = []
        var i = 0
        // Six evenly spaced ticks over four days lands two of them on the same date, and
        // "8/31 8/31 9/1 9/1" reads as a broken axis. Drop a label that repeats the one
        // before it and let the spacing go uneven — an axis may be sparse, not wrong.
        while i < n - 1 {
            if n - 1 - i >= stride {
                let t = label(i)
                if t != out.last?.text { out.append((i, t, i == 0 ? .left : .center)) }
            }
            i += stride
        }
        let tail = label(n - 1)
        if tail == out.last?.text { out.removeLast() }   // the end tick owns the date
        out.append((n - 1, tail, .right))
        return out
    }

    /// "共 1.2M tokens · 其中托管 480k" — the right-hand note over the burn-rate curve.
    /// It names the TOTAL, because the axis only ever shows a per-bucket peak and the
    /// question anyone asks first is what the whole range cost.
    static func rateNote(_ pts: [RatePoint], _ range: TimeRange) -> String {
        guard pts.count > 1 else { return "" }
        let total = pts.reduce(0.0) { $0 + $1.tok }
        let auto = pts.reduce(0.0) { $0 + $1.autoTok }
        let head = L("\(range.rateNoun) · 共 \(Tok.fmt(Int(total)))",
                     "\(range.rateNoun) · \(Tok.fmt(Int(total))) total")
        guard auto > 0 else { return head }
        return head + L(" · 托管 \(Tok.fmt(Int(auto)))", " · \(Tok.fmt(Int(auto))) unattended")
    }

    /// The figures under the concurrency chart. A peak with no context reads as a
    /// boast, so the everyday level rides next to it — and the median is taken over
    /// the buckets that had ANY terminal working, or a night of sleep would drag the
    /// typical figure to zero and call a busy day quiet.
    static func concurrencyNote(_ pts: [RatePoint]) -> String {
        let peak = pts.map { $0.sessions }.max() ?? 0
        guard peak > 0 else { return L("这段时间没有终端在跑", "no terminals running") }
        let busy = pts.filter { $0.sessions > 0 }.map { $0.sessions }.sorted()
        let median = busy.isEmpty ? 0 : busy[busy.count / 2]
        return L("最多 \(peak) 个 · 常态 \(median) 个",
                 "peak \(peak) · typically \(median)")
    }

    static func rateLegend(hasAuto: Bool) -> NSAttributedString {
        let faint: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10.5, .regular), .foregroundColor: NeonInk.secondary]
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "━", attributes: [
            .font: Theme.font(10.5, .regular), .foregroundColor: Metric.accent(.streak)]))
        out.append(NSAttributedString(string: L(" 全部　", " all  "), attributes: faint))
        guard hasAuto else { return out }
        out.append(NSAttributedString(string: "┄", attributes: [
            .font: Theme.font(10.5, .regular), .foregroundColor: Metric.accent(.auto)]))
        out.append(NSAttributedString(string: L(" 其中无人值守", " of which unattended"),
                                      attributes: faint))
        return out
    }

    /// `hasDashed` is passed separately because the second series drops out on its own
    /// whenever its source is all zeros — announcing a dashed line that was never
    /// stroked is the chart telling the reader something untrue about itself.
    static func legend(scored: Bool, hasDashed: Bool) -> NSAttributedString {
        let faint: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10.5, .regular), .foregroundColor: NeonInk.secondary]
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "━", attributes: [
            .font: Theme.font(10.5, .regular), .foregroundColor: Metric.accent(.saved)]))
        out.append(NSAttributedString(string: scored ? L(" 效能分　", " impact  ")
                                                     : L(" 到达　", " arrivals  "), attributes: faint))
        guard hasDashed else { return out }
        out.append(NSAttributedString(string: "┄", attributes: [
            .font: Theme.font(10.5, .regular), .foregroundColor: Metric.accent(.streak)]))
        out.append(NSAttributedString(string: scored ? L(" 省时趋势", " saved-time trend")
                                                     : L(" 跳转", " jumps"),
                                      attributes: faint))
        return out
    }

    /// The curve's right-hand note — says WHAT is being drawn, so nobody mistakes
    /// twenty-four hours for twenty-four weeks, and what the high-water mark was.
    static func trendNote(_ pts: [TrendPoint], _ range: TimeRange) -> String {
        guard pts.count > 1 else { return "" }
        guard scored(pts) else {
            let total = pts.reduce(0) { $0 + $1.arrivals }
            return L("\(range.impactNoun)\(range.stepNoun) · 共 \(total) 次到达",
                     "\(range.stepNoun) · \(total) arrivals")
        }
        let all = pts.compactMap { $0.score }
        guard let best = all.max(), let now = pts.last(where: { $0.score != nil })?.score
        else { return "" }
        let head = now >= best ? L("\(range.impactNoun)最高", "best yet")
                               : L("最高 \(best)", "best \(best)")
        // Only the OLDEST bucket may fill the 「起点」 slot. Reaching for the first bucket
        // that happens to have a score means a fresh log labels THIS period's own number
        // as the start of history — a fabricated comparison, which is the one thing this
        // panel must never print.
        guard let first = pts.first, let oldest = first.score else { return head }
        return L("\(head) · 起点 \(oldest)", "\(head) · from \(oldest)")
    }

    /// "1h04m" / "56m" / "0m" — never "1.1h": the panel claims these figures are yours to
    /// check, and a rounded decimal hour cannot be checked against a list of jumps.
    static func hm(_ sec: Int) -> String {
        guard sec >= 3600 else { return "\(sec / 60)m" }
        return String(format: "%dh%02dm", sec / 3600, (sec % 3600) / 60)
    }
}

// MARK: - Small helpers

// A dynamic (light/dark) color has no components until it is resolved, and
// `withAlphaComponent` on one throws them away. Inside draw() the view's appearance is
// current, so this is where the concrete tone must be taken.
private func resolvedSRGB(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

// MARK: - Neon surfaces are dark in BOTH appearances (改这段前先读)
//
// The five accent colours are neon: they are defined by how much brighter they are than
// what is behind them. On a light appearance there is nothing behind them — the 掌控
// yellow-green and 省时 mint wash out to near-invisible on white, which is what a user
// reported after the burn-rate charts landed. A glow needs somewhere dark to spill into.
//
// So the card lays its own bed rather than borrowing the window's. That makes the card
// dark under a light appearance too, which in turn means nothing drawn ON it can follow
// the system label colour — that flips to black on light and vanishes into the bed. Text
// on a neon surface uses NeonInk instead, which is pale in both appearances because the
// surface under it is dark in both.
//
// (NeonBar, the five metric rows, solves the same problem the opposite way: it sits on
// the WINDOW, not on a card, so it cannot darken its own background and instead swaps
// its glow for an outline on light. Two different beds, two different recipes.)
enum NeonInk {
    /// The bed every neon surface paints under itself on a LIGHT appearance. Dark enough
    /// that the accents still glow against it, light enough to read as a surface rather
    /// than a hole.
    static let bed = NSColor(srgbRed: 0.478, green: 0.514, blue: 0.569, alpha: 1)
    /// On a dark appearance the light bed sat far brighter than the window and read as a
    /// washed-out grey slab (2026-10-10 user report). Ink, a hair above the window and
    /// faintly blue, picked from four renders (design/impact-dark-bed.html). The ink
    /// alphas below stay as they are: pale text only gains contrast on a darker bed.
    static let darkBed = NSColor(srgbRed: 0.105, green: 0.118, blue: 0.149, alpha: 1)

    static func bed(in view: NSView) -> NSColor {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkBed : bed
    }

    // The alphas below are tuned TO that bed and have to move with it: a paler bed eats
    // low-alpha white, so every step was lifted when the bed was. This is close to the
    // ceiling — a bed much lighter than this stops being a dark surface at all, and the
    // whole recipe would have to invert (dark ink on a light card) rather than be nudged.
    private static let base = NSColor(srgbRed: 0.965, green: 0.976, blue: 0.988, alpha: 1)
    static var primary: NSColor { base }
    static var secondary: NSColor { base.withAlphaComponent(0.78) }
    static var faint: NSColor { base.withAlphaComponent(0.54) }
    /// Hairlines and gridlines drawn over the bed.
    static var rule: NSColor { base.withAlphaComponent(0.17) }
}

private extension NSView {
    /// Layer glow around a symbol image, in the symbol's own color.
    func shadowed(color: NSColor, radius: CGFloat, opacity: Float) {
        wantsLayer = true
        layer?.shadowColor = color.cg(in: self)
        layer?.shadowRadius = radius
        layer?.shadowOpacity = opacity
        layer?.shadowOffset = .zero
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

private extension NSAttributedString {
    /// Fading attributed text without rebuilding every colour attribute — the figures
    /// carry two different inks (number and unit) and re-tinting both on every frame of
    /// the intro would be 60 allocations a second for nothing.
    func draw(at p: NSPoint, alpha: CGFloat) {
        guard alpha < 0.999 else { return draw(at: p) }
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        draw(at: p)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
