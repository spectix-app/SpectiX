import Cocoa

// MARK: - Stats pane ("Insights")
//
// A frosted-glass panel that reports, from the hook's append-only event log, how
// you've been using Claude Code. Top: the Insights title and a time-range switch
// (今日/本周/本月/全部) that scopes everything below. Then four titled blocks
// (SectionBlock, design/insights-sections-3-proposals.html 方案 13): 效能 and 成绩 are the
// ImpactPanel; 帮了你什么 holds the first item below; 消耗 holds the rest.
//   帮了你什么   — a 3-card row off impact.jsonl: auto jumps / nudges / waiting saved.
//                 The 效能 panel above it is folded by default and leads with a score;
//                 these are the plain counts that say what the app actually did.
//   概览        — a 2×2 card grid: sessions / completions / active time / cost,
//                 each with a "vs 上一期" delta line
//   本周配额消耗 — one segmented bar splitting the week's quota across its days
//   每日 Token   — a 26-week contribution grid with weekday + date axes
//   分布        — percentage bars ranked by token usage, flippable day / project /
//                 model / task
//
// Everything below 概览 is measured in TOKENS, not event counts: ten trivial turns
// shouldn't outweigh the one that burned a megatoken.
//
// Semantic colors are shared with the rest of the app: sessions use the blue
// "working" accent and completions the green "done" accent, so the numbers read
// the same as the row dots. Active time (teal) and cost (pink) are deliberately
// non-status tones that say "measurement, not session state".
final class StatsPane: NSView {

    private let store = StatsStore()
    // 效能 — its own append-only log (impact.jsonl). It scopes to the SAME range switch
    // as everything below it: the panel and the 用量 report answer different questions
    // (「这个 App 帮了我多少」 vs 「我用掉了多少」), but a window whose top card says 本周
    // while its switch says 今日 is just two answers to different questions stacked on
    // top of each other. See Impact.swift / ImpactView.swift, T255.
    private let impact = ImpactStore()
    private let impactPanel = ImpactPanel()
    private enum Mode: Int { case day, project, model, task }
    private var mode: Mode = .day
    private var range: TimeRange = .today
    // 按任务模式分页：每建一次 taskRow 都是一张多字段 GlassCard，全量渲染会卡；
    // 每页只渲染 taskPageSize 行，末行是「‹ 上一页 · N/M · 下一页 ›」导航。切模式/范围时归 0。
    private static let taskPageSize = 10
    private var taskPage = 0
    private var usage: UsageSnapshot?   // subscription quota snapshot, for the week-quota bar

    // Non-status accents: teal = active time, pink = estimated money.
    private static let time = NSColor(srgbRed: 0.20, green: 0.72, blue: 0.75, alpha: 1)
    private static let cost = NSColor(srgbRed: 0.95, green: 0.42, blue: 0.62, alpha: 1)

    // Violet = automatic jumps. A non-status tone on purpose: an auto-jump is the app
    // acting, not a session state. (The 效能 panel's own 托管 neon is a fixed sRGB magenta
    // that only reads on its dark bed — on a GlassCard in light mode it would vanish.)
    private static let auto = NSColor(srgbRed: 0.68, green: 0.51, blue: 0.98, alpha: 1)

    // Ranked-bar palette for the distribution rows, cycled by rank.
    private static let palette: [NSColor] = [
        Status.accent("working"), Status.accent("done"),
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.25, alpha: 1),   // orange
        auto,
        time, cost,
    ]

    // 「SpectiX 帮了你什么」 — the three plainest facts in impact.jsonl, always on screen
    // whether or not the 效能 panel above is expanded. That panel answers 「这一段怎么样」
    // with a score; these answer 「它到底替我做了多少」 with counts you can grep for.
    private let helpJumpV = StatsPane.bigNumber()
    private let helpNotifyV = StatsPane.bigNumber()
    private let helpSavedV = StatsPane.bigNumber()
    private let helpJumpSub = StatsPane.subCaption()
    private let helpNotifySub = StatsPane.subCaption()
    private let helpSavedSub = StatsPane.subCaption()

    // Overview cards — value + delta/sub line rebuilt on every range change.
    private let runsV = StatsPane.bigNumber()
    private let doneV = StatsPane.bigNumber()
    private let timeV = StatsPane.bigNumber()
    private let costV = StatsPane.bigNumber()
    private let runsSub = StatsPane.subCaption()
    private let doneSub = StatsPane.subCaption()
    private let timeSub = StatsPane.subCaption()
    private let costSub = StatsPane.subCaption()

    private let heatmap = HeatmapView()

    // The page's last two blocks (方案 13); the 效能 panel above draws the first two.
    private let helpBlock = SectionBlock(accent: StatsPane.auto)
    private let costBlock = SectionBlock(accent: Metric.accent(.tokens))

    // 本周配额消耗 — one horizontal bar split into per-day segments (+ a remainder
    // segment), driven by usage.json's week_pct and the current reset window.
    private let quotaTitle = StatsPane.sectionLabel(L("本周配额消耗", "This week's quota"))
    private let quotaRange = StatsPane.subCaption()   // "7/01 – 7/07 · 3 天后重置"
    private let quotaUsed = QuotaCaption()            // "已用 55%  [剩 45%]" — remainder as a violet pill
    private let quotaBar = SegmentBarView()

    // Says what the breakdown below is measured in — the ranked modes rank by tokens,
    // the task mode is a chronological list.
    private let distCap = StatsPane.subCaption()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L("还没有记录。跑几个会话后再回来看。", "No data yet. Run a few sessions and check back."))
    private let rangeSeg = NSSegmentedControl(labels: TimeRange.allCases.map { $0.label },
                                              trackingMode: .selectOne, target: nil, action: nil)
    // Hairline under the pinned range control, separating it from the scrolling report.
    private let rangeDivider = NSView()
    private let modeSeg = NSSegmentedControl(labels: [L("按天", "By day"), L("按项目", "By project"), L("按模型", "By model"), L("按任务", "By task")],
                                             trackingMode: .selectOne, target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rangeDivider.layer?.backgroundColor = Theme.hairline.cg(in: self)
    }

    // Reload the log and repaint everything. Called right before showWindow.
    // `usage` carries the latest subscription quota snapshot for the week-quota bar.
    // `force` bypasses the hover hold below — a tab switch must render even if the
    // pointer happens to be resting over the pane.
    func refresh(usage: UsageSnapshot? = nil, force: Bool = false) {
        self.usage = usage
        // A repaint reassigns every chart's data and rebuilds the whole breakdown list,
        // and each of those drops the hover state it owns — so the bubble under the
        // cursor blinked out every poll (2.5s) until the mouse moved again. While the
        // pointer is over the pane the user is reading it: hold the repaint until they
        // leave, and the next poll catches up on its own.
        if !force, pointerInside { return }
        store.reload()
        impact.reload()
        applyRange()
    }

    // Pointer over this pane. Asked of the window instead of tracked with an
    // NSTrackingArea so there is no flag to go stale when the pane is hidden, the
    // window closes, or the charts are rebuilt under a still mouse.
    private var pointerInside: Bool {
        guard let w = window, w.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: Build

    private func buildUI() {
        // The whole report is taller than the main window, so it lives inside one
        // scroll view; a flipped document keeps content pinned to the top.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Time range — scopes every number below it. Pinned to the pane top (outside
        // the scroll view) so it stays visible while the report scrolls under it.
        rangeSeg.selectedSegment = range.rawValue
        rangeSeg.target = self
        rangeSeg.action = #selector(rangeChanged)
        rangeSeg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rangeSeg)

        rangeDivider.wantsLayer = true
        rangeDivider.layer?.backgroundColor = Theme.hairline.cg(in: self)
        rangeDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rangeDivider)

        // 本周效能 — above 概览, because it answers "did this app do anything for me"
        // and everything below answers "what did Claude cost me".
        impactPanel.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(impactPanel)

        // 帮了你什么 — 3 cards straight off impact.jsonl, under the 效能 panel because
        // that panel ships folded: its bar shows a score and one figure, and the three
        // numbers a user actually judges the app by were only reachable by expanding it.
        helpBlock.set(title: L("帮了你什么", "What it did for you"))
        helpBlock.set(purpose: L("它替你做了哪几件事", "What SpectiX did on your behalf"))
        helpBlock.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(helpBlock)
        let helpRow = NSStackView(views: [
            card(helpJumpV,   sub: helpJumpSub,   caption: L("自动跳转", "Auto jumps"),     color: Self.auto),
            card(helpNotifyV, sub: helpNotifySub, caption: L("提醒你", "Nudges"),           color: Status.accent("needs")),
            card(helpSavedV,  sub: helpSavedSub,  caption: L("省下的等待", "Waiting saved"), color: Self.time),
        ])
        helpRow.orientation = .horizontal
        helpRow.distribution = .fillEqually
        helpRow.spacing = Theme.gap
        helpRow.translatesAutoresizingMaskIntoConstraints = false
        helpBlock.content.addSubview(helpRow)

        // 消耗 — everything from 概览 down answers 「Claude 花了我多少」.
        costBlock.set(title: L("消耗", "Spend"))
        costBlock.set(purpose: L("Claude 用了多少 token 和额度", "Tokens and quota Claude used"))
        costBlock.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(costBlock)
        let cc = costBlock.content

        // 概览 — 2×2 card grid.
        let ovLabel = Self.sectionLabel(L("概览", "Overview"))
        cc.addSubview(ovLabel)

        let row1 = NSStackView(views: [
            card(runsV, sub: runsSub, caption: L("总会话", "Total sessions"), color: Status.accent("working")),
            card(doneV, sub: doneSub, caption: L("已完成", "Completed"), color: Status.accent("done")),
        ])
        let row2 = NSStackView(views: [
            card(timeV, sub: timeSub, caption: L("活跃时间", "Active time"),     color: Self.time),
            card(costV, sub: costSub, caption: L("费用（估算）", "Cost (est.)"), color: Self.cost),
        ])
        for row in [row1, row2] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = Theme.gap
        }
        let cards = NSStackView(views: [row1, row2])
        cards.orientation = .vertical
        cards.distribution = .fillEqually
        cards.spacing = Theme.gap
        cards.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(cards)

        // 本周配额消耗 — segmented bar between 概览 and the heatmap.
        cc.addSubview(quotaTitle)
        quotaUsed.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(quotaUsed)
        cc.addSubview(quotaRange)
        quotaBar.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(quotaBar)

        // 会话活动热力图.
        let heatTitle = Self.sectionLabel(L("每日 Token 用量", "Daily token usage"))
        cc.addSubview(heatTitle)
        let heatCap = NSTextField(labelWithString: L("过去 26 周", "Last 26 weeks"))
        heatCap.font = Theme.font(10.5, .regular)
        heatCap.textColor = .tertiaryLabelColor
        heatCap.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(heatCap)
        heatmap.accent = Status.accent("done")
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(heatmap)

        // 分布.
        let distLabel = Self.sectionLabel(L("分布", "Distribution"))
        cc.addSubview(distLabel)
        cc.addSubview(distCap)
        modeSeg.selectedSegment = 0
        modeSeg.target = self
        modeSeg.action = #selector(modeChanged)
        modeSeg.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(modeSeg)

        // Breakdown rows flow directly in the document (no nested scroll).
        listStack.orientation = .vertical
        listStack.spacing = 6
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(listStack)

        emptyLabel.font = Theme.font(12.5, .regular)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        cc.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            // Pinned range control at the pane top, then a hairline, then the scroll.
            rangeSeg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.pad),
            rangeSeg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.pad),
            rangeSeg.topAnchor.constraint(equalTo: topAnchor, constant: Theme.pad),

            rangeDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            rangeDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            rangeDivider.topAnchor.constraint(equalTo: rangeSeg.bottomAnchor, constant: 12),
            rangeDivider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: rangeDivider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Document tracks the clip's width (see pinDocumentWidth, called below);
            // its height follows the content chain (impactPanel.top → costBlock.bottom),
            // so the report scrolls.

            impactPanel.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Theme.pad),
            impactPanel.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Theme.pad),
            impactPanel.topAnchor.constraint(equalTo: doc.topAnchor, constant: Theme.pad),

            helpBlock.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Theme.pad),
            helpBlock.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Theme.pad),
            helpBlock.topAnchor.constraint(equalTo: impactPanel.bottomAnchor, constant: 12),
            helpRow.leadingAnchor.constraint(equalTo: helpBlock.content.leadingAnchor),
            helpRow.trailingAnchor.constraint(equalTo: helpBlock.content.trailingAnchor),
            helpRow.topAnchor.constraint(equalTo: helpBlock.content.topAnchor),
            helpRow.bottomAnchor.constraint(equalTo: helpBlock.content.bottomAnchor),
            // 79 = one row of the 2×2 grid below (158 split in two), so the four card
            // heights on this page match instead of nearly matching.
            helpRow.heightAnchor.constraint(equalToConstant: 79),

            costBlock.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Theme.pad),
            costBlock.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Theme.pad),
            costBlock.topAnchor.constraint(equalTo: helpBlock.bottomAnchor, constant: 12),
            costBlock.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Theme.pad),

            ovLabel.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            ovLabel.topAnchor.constraint(equalTo: cc.topAnchor),

            cards.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            cards.topAnchor.constraint(equalTo: ovLabel.bottomAnchor, constant: 8),
            cards.heightAnchor.constraint(equalToConstant: 158),
            row1.widthAnchor.constraint(equalTo: cards.widthAnchor),
            row2.widthAnchor.constraint(equalTo: cards.widthAnchor),

            quotaTitle.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            quotaTitle.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 16),
            quotaUsed.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            quotaUsed.centerYAnchor.constraint(equalTo: quotaRange.centerYAnchor),
            quotaUsed.leadingAnchor.constraint(greaterThanOrEqualTo: quotaRange.trailingAnchor, constant: 8),
            quotaRange.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            quotaRange.trailingAnchor.constraint(lessThanOrEqualTo: quotaUsed.leadingAnchor, constant: -8),
            quotaRange.topAnchor.constraint(equalTo: quotaTitle.bottomAnchor, constant: 3),
            quotaBar.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            quotaBar.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            quotaBar.topAnchor.constraint(equalTo: quotaRange.bottomAnchor, constant: 8),
            quotaBar.heightAnchor.constraint(equalToConstant: 52),

            heatTitle.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            heatTitle.topAnchor.constraint(equalTo: quotaBar.bottomAnchor, constant: 16),
            heatCap.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            heatCap.firstBaselineAnchor.constraint(equalTo: heatTitle.firstBaselineAnchor),
            heatmap.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            heatmap.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            heatmap.topAnchor.constraint(equalTo: heatTitle.bottomAnchor, constant: 8),
            heatmap.heightAnchor.constraint(equalToConstant: 130),

            distLabel.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            distLabel.topAnchor.constraint(equalTo: heatmap.bottomAnchor, constant: 16),
            distCap.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            distCap.leadingAnchor.constraint(greaterThanOrEqualTo: distLabel.trailingAnchor, constant: 8),
            distCap.firstBaselineAnchor.constraint(equalTo: distLabel.firstBaselineAnchor),
            modeSeg.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            modeSeg.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            modeSeg.topAnchor.constraint(equalTo: distLabel.bottomAnchor, constant: 8),

            listStack.leadingAnchor.constraint(equalTo: cc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: cc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: modeSeg.bottomAnchor, constant: 10),
            listStack.bottomAnchor.constraint(equalTo: cc.bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: listStack.topAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listStack.leadingAnchor, constant: 2),
        ])
        pinDocumentWidth(doc, filling: scroll)
    }

    // MARK: Actions

    @objc private func rangeChanged() {
        range = TimeRange(rawValue: rangeSeg.selectedSegment) ?? .today
        taskPage = 0
        applyRange()
    }
    @objc private func modeChanged() {
        mode = Mode(rawValue: modeSeg.selectedSegment) ?? .day
        taskPage = 0
        rebuildList()
    }

    // Repaint every range-scoped number, plus heatmap / distribution.
    private func applyRange() {
        // 连续 is "did you run anything at all today", which lives in the usage log — so
        // the impact rollup borrows it rather than parsing the same file a second time.
        let work = Demo.enabled ? Demo.dailyWorkSec() : BreakReminder.shared.dailyWorkSec()
        let imp = impact.impact(range: range, usage: store.events, work: work)
        // The rate series comes from the USAGE log, not the impact log: tokens and the
        // heartbeat that reveals a live terminal are both written by the hook, so one
        // pass over one file answers both curves.
        impactPanel.update(imp, trend: impact.trend(range: range),
                           rate: store.rateSeries(range))
        updateHelpCards(imp)

        let t = store.totals(range)
        let prev = store.previousTotals(range)
        runsV.stringValue = "\(t.runs)"
        runsSub.attributedStringValue = deltaString(t.runs, prev?.runs)
        doneV.stringValue = "\(t.done)"
        doneSub.attributedStringValue = deltaString(t.done, prev?.done)
        timeV.stringValue = t.pairedTasks > 0 ? Self.fmtDur(t.durSec) : "—"
        timeSub.stringValue = t.pairedTasks > 0 ? L("平均 \(Self.fmtDur(t.durSec / t.pairedTasks))/会话", "\(Self.fmtDur(t.durSec / t.pairedTasks)) avg/session") : L("无计时", "No timing")
        costV.stringValue = t.costUSD > 0 ? Self.fmtUSD(t.costUSD) : "—"
        costSub.stringValue = Self.tokenSummary(t)
        let tok = imp.metric(.tokens).value
        let spend = [tok > 0 ? Tok.fmt(tok) : nil, t.costUSD > 0 ? Self.fmtUSD(t.costUSD) : nil]
        costBlock.set(summary: spend.compactMap { $0 }.joined(separator: " · "), tail: "")

        heatmap.days = store.heatmap(days: 26 * 7)
        updateQuotaBar()
        rebuildList()
    }

    // 「SpectiX 帮了你什么」. Each figure is a count of lines in impact.jsonl, so anyone
    // who doubts it can go count them — that is the whole reason the log stores
    // observations and never a score (Impact.swift's one hard rule).
    private func updateHelpCards(_ w: PeriodImpact) {
        let a = w.auto
        let jumps = a.chain + a.idle
        helpJumpV.stringValue = "\(jumps)"
        let acts = jumps + w.control.notifies
        helpBlock.set(summary: acts > 0 ? "\(acts)" : "", tail: L("次", acts == 1 ? "action" : "actions"))
        helpJumpSub.stringValue = jumps > 0
            ? L("答完接着跳 \(a.chain) · 闲时 \(a.idle)", "\(a.chain) chained · \(a.idle) idle")
            : L("还没自动跳过", "None yet")

        let n = w.control.notifies
        helpNotifyV.stringValue = "\(n)"
        // 在场次数, not the raw count: a banner that fired while you were away is not a
        // nudge anyone received. Same denominator 掌控 scores against.
        helpNotifySub.stringValue = n > 0
            ? L("\(w.control.scored) 次你就在电脑前", "\(w.control.scored) while you were here")
            : L("这段没提醒过你", "None this period")

        // 省时 has no number until enough unassisted arrivals exist to measure against —
        // showing a weak one here would undercut every other figure on the page, so the
        // card says what it is still waiting for instead.
        if w.saved.trustworthy {
            helpSavedV.stringValue = ImpactFormat.hm(w.metric(.saved).value)
            helpSavedSub.stringValue = L("自己找一次要 \(Self.fmtDur(w.saved.baselineSec))",
                                         "\(Self.fmtDur(w.saved.baselineSec)) to find one yourself")
        } else {
            let need = ImpactRule.baselineMinSamples - w.saved.baselineSamples
            helpSavedV.stringValue = "—"
            helpSavedSub.stringValue = L("还差 \(need) 次自己找的记录", "Needs \(need) more self-found")
        }
    }

    // Fill the week-quota bar from usage.json's authoritative week_pct + reset time,
    // splitting the used share across the period's days by their token share. Absent
    // a subscription snapshot the bar shows an unavailable placeholder.
    private func updateQuotaBar() {
        guard let u = usage, let pct = u.weekPct, let reset = u.weekResetsAt, reset > 0 else {
            quotaBar.setUnavailable()
            quotaRange.stringValue = L("暂无订阅配额数据", "No subscription quota data")
            quotaUsed.set(used: nil)
            return
        }
        quotaBar.set(days: store.weekQuotaDays(resetsAt: reset), weekPct: pct)
        let start = Date(timeIntervalSince1970: reset - 7 * 86_400)
        let end = Date(timeIntervalSince1970: reset)
        quotaRange.stringValue = "\(Self.mdf.string(from: start)) – \(Self.mdf.string(from: end)) · \(Self.resetCountdown(reset))"
        quotaUsed.set(used: pct)
    }

    // "3 天后重置" / "5 小时后重置" / "45 分钟后重置" / "即将重置".
    private static func resetCountdown(_ reset: Double) -> String {
        let left = reset - Date().timeIntervalSince1970
        if left <= 0 { return L("即将重置", "resetting soon") }
        let days = Int(left / 86_400)
        if days >= 1 { return L("\(days) 天后重置", "resets in \(days)d") }
        let hours = Int(left / 3_600)
        if hours >= 1 { return L("\(hours) 小时后重置", "resets in \(hours)h") }
        let mins = max(1, Int(left / 60))
        return L("\(mins) 分钟后重置", "resets in \(mins)m")
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 按天保持日期序（时间序比排名更有意义），其余按用量降序 — 所以这里只说
        // 数字是什么，不暗示排序方式。
        distCap.stringValue = mode == .task ? L("按时间倒序", "Newest first")
                                            : L("数值 = Token 用量", "Values are token usage")
        switch mode {
        case .task:
            let rows = store.sessions(range)
            emptyLabel.isHidden = !rows.isEmpty
            let size = Self.taskPageSize
            let pages = max(1, (rows.count + size - 1) / size)
            taskPage = min(taskPage, pages - 1)   // clamp after data shrinks
            let start = taskPage * size
            for r in rows[start..<min(start + size, rows.count)] { addRow(taskRow(r)) }
            if pages > 1 {
                addRow(PagerRow(page: taskPage, pages: pages) { [weak self] delta in
                    guard let self else { return }
                    self.taskPage = max(0, min(pages - 1, self.taskPage + delta))
                    self.rebuildList()
                })
            }
        default:
            let buckets = mode == .day ? store.byDay(range)
                        : mode == .project ? store.byProject(range)
                        : store.byModel(range)
            emptyLabel.isHidden = !buckets.isEmpty
            // Ranked bars measure tokens, not turn counts — a share of the range's
            // total consumption, so the percentages read as "where my quota went".
            let vals = buckets.map { $0.tokTotal }
            let total = max(vals.reduce(0, +), 1)
            for (i, b) in buckets.enumerated() {
                let name = mode == .day ? String(b.key.suffix(5)) : b.key
                addRow(RankRowView(name: name, valueText: Tok.fmt(vals[i]),
                                   pct: Double(vals[i]) / Double(total),
                                   color: Self.palette[i % Self.palette.count]))
            }
        }
    }

    // Add a breakdown row spanning the full list width (which tracks the pane's
    // live inner width, so rows reflow when the host window resizes).
    private func addRow(_ row: NSView) {
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    // MARK: Card + row builders

    private static func bigNumber() -> NSTextField {
        let f = NSTextField(labelWithString: "0")
        f.font = Theme.rounded(22, .bold)
        f.lineBreakMode = .byClipping
        f.maximumNumberOfLines = 1
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
    private static func subCaption() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = Theme.font(10, .regular)
        f.textColor = .tertiaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        // Below the document's width pin, so a long caption truncates instead of
        // widening the whole page past the window.
        f.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
    private static func sectionLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = Theme.font(12, .semibold)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // One overview card: caption top-left, big colored value, delta/sub line.
    private func card(_ value: NSTextField, sub: NSTextField, caption: String, color: NSColor) -> NSView {
        let card = GlassCard(radius: Theme.card, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        let cap = NSTextField(labelWithString: caption)
        cap.font = Theme.font(11, .medium)
        cap.textColor = .secondaryLabelColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cap)
        value.textColor = color
        card.addSubview(value)
        card.addSubview(sub)

        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            cap.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            value.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            value.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
            value.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
            sub.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 2),
        ])
        return card
    }

    // "+12 vs 上周" — green up / red down / gray flat; "累计" when there is no
    // previous window to compare against (the 全部 range).
    private func deltaString(_ cur: Int, _ prev: Int?) -> NSAttributedString {
        guard let prev, let cap = range.deltaCaption else {
            return NSAttributedString(string: L("累计", "Total"), attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(10, .regular)])
        }
        let d = cur - prev
        let sign = d > 0 ? "+\(d)" : d < 0 ? "\(d)" : "±0"
        let color: NSColor = d > 0 ? Status.accent("done")
                           : d < 0 ? Status.accent("needs") : .secondaryLabelColor
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: sign, attributes: [
            .foregroundColor: color, .font: Theme.rounded(10.5, .bold)]))
        out.append(NSAttributedString(string: " \(cap)", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(10, .regular)]))
        return out
    }

    // One task: prompt title left, "⏱ dur · ~$cost" right; tokens + model beneath.
    private func taskRow(_ s: TaskRun) -> NSView {
        let card = GlassCard(radius: Theme.chip, glows: false)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Full text (title + every metric) for the hover tooltip, so a truncated
        // row still exposes all fields.
        let durStr = s.durSec > 0 ? Self.fmtDur(s.durSec) : "—"
        let costStr = s.costUSD > 0 ? Self.fmtUSD(s.costUSD) : "—"
        let freshIn = s.tokIn + s.tokCacheW
        let model = Pricing.displayName(s.model)
        var full = "\(s.title)\n⏱ \(durStr)  ·  \(costStr)\n↓\(Self.fmtTok(s.tokOut)) ↑\(Self.fmtTok(freshIn)) ⟳\(Self.fmtTok(s.tokCacheR))"
        if model != L("未知", "Unknown") { full += "  ·  \(model)" }

        let key = NSTextField(labelWithString: s.title)
        key.font = Theme.rounded(13, .semibold)
        key.textColor = .labelColor
        key.lineBreakMode = .byTruncatingTail
        key.maximumNumberOfLines = 1
        // Long prompt titles yield to the fixed metrics column and truncate with a
        // trailing "…" instead of forcing the pane wider; hover shows the full text.
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.toolTip = full
        key.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(key)

        // Fixed-width metrics column: time + cost, right-aligned so the numbers
        // stay put and the title's truncation point doesn't jitter per row.
        let right = NSTextField(labelWithString: "")
        let rs = NSMutableAttributedString()
        let muted = NSColor.secondaryLabelColor
        rs.append(NSAttributedString(string: "⏱ \(durStr)",
            attributes: [.foregroundColor: muted, .font: Theme.rounded(12, .semibold)]))
        rs.append(NSAttributedString(string: "   " + costStr,
            attributes: [.foregroundColor: s.costUSD > 0 ? Self.cost : muted, .font: Theme.rounded(12, .bold)]))
        right.attributedStringValue = rs
        right.alignment = .right
        right.lineBreakMode = .byTruncatingTail
        right.toolTip = full
        right.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(right)

        let usage = NSTextField(labelWithString: "")
        usage.attributedStringValue = taskUsageString(s)
        usage.lineBreakMode = .byTruncatingTail
        usage.toolTip = full
        usage.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(usage)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 58),
            key.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            key.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            key.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -10),
            right.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            right.widthAnchor.constraint(equalToConstant: 150),
            right.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            usage.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.inset),
            usage.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            usage.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 5),
        ])
        return card
    }

    // Second line for a task: tokens + the model tag.
    private func taskUsageString(_ s: TaskRun) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let muted = NSColor.secondaryLabelColor, faint = NSColor.tertiaryLabelColor
        let numFont = Theme.rounded(11.5, .semibold), capFont = Theme.font(10.5, .regular)
        func num(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: muted, .font: numFont])) }
        func cap(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: faint, .font: capFont])) }
        let freshIn = s.tokIn + s.tokCacheW
        num("↓" + Self.fmtTok(s.tokOut)); cap(L(" 输出  ·  ", " Output  ·  "))
        num("↑" + Self.fmtTok(freshIn)); cap(L(" 输入  ·  ", " Input  ·  "))
        num("⟳" + Self.fmtTok(s.tokCacheR)); cap(L(" 缓存", " Cache"))
        let m = Pricing.displayName(s.model)
        if m != L("未知", "Unknown") { cap("   ·   "); num(m) }
        return out
    }

    // MARK: Formatters

    private static func fmtTok(_ n: Int) -> String { Tok.fmt(n) }
    private static func fmtDur(_ sec: Int) -> String {
        switch sec {
        case 3600...: return String(format: "%.1fh", Double(sec) / 3600)
        case 60...:   return "\(sec / 60)m"
        default:      return "\(sec)s"
        }
    }
    // Estimated USD. Tiny-but-nonzero collapses to "~<$0.01" so it never reads as free.
    private static func fmtUSD(_ c: Double) -> String {
        if c <= 0 { return "$0" }
        if c < 0.01 { return "~<$0.01" }
        return "~$" + String(format: "%.2f", c)
    }
    // Cost card sub-caption: compact token totals under the dollar figure.
    private static func tokenSummary(_ b: StatBucket) -> String {
        let freshIn = b.tokIn + b.tokCacheW
        if b.tokOut == 0 && freshIn == 0 && b.tokCacheR == 0 { return L("估算，非账单", "Estimate, not billed") }
        return "↓\(fmtTok(b.tokOut)) ↑\(fmtTok(freshIn)) ⟳\(fmtTok(b.tokCacheR))"
    }

    static let mdf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

// MARK: - Mini charts

// A compact single-line readout bubble drawn in-view on hover (NSToolTip's dwell
// tooltips don't fire in this window). Used by the distribution rows.
private enum HoverBubble {
    static let padX: CGFloat = 7, padY: CGFloat = 4
    static func size(text: String) -> NSSize {
        let ts = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ts.width + padX * 2, height: ts.height + padY * 2)
    }
    static let attrs: [NSAttributedString.Key: Any] = [
        .font: Theme.font(10, .medium), .foregroundColor: NSColor.labelColor]

    // Draw a bubble centered at `centerX`, its top edge at `topY`, clamped within
    // the host view's width so it never spills off the sides.
    static func draw(text: String, centerX: CGFloat, topY: CGFloat, in view: NSView) {
        let sz = size(text: text)
        var x = centerX - sz.width / 2
        x = min(max(x, 0), max(0, view.bounds.width - sz.width))
        let rect = NSRect(x: x, y: topY - sz.height, width: sz.width, height: sz.height)
        let back = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill(); back.fill()
        NSColor(cgColor: Theme.hairline.cg(in: view))?.setStroke(); back.stroke()
        (text as NSString).draw(at: NSPoint(x: rect.minX + padX, y: rect.minY + padY), withAttributes: attrs)
    }
}

// A GitHub-style contribution grid: one column per week (Mon at top), each day a
// rounded square whose opacity scales with that day's token usage. Weekday labels
// (一/三/五/日) run down the left gutter, M/d date labels along the bottom.
// Hovering a cell rings it and shows an instant in-view "M/d · N tokens" bubble —
// hand-rolled via NSTrackingArea because NSToolTip's dwell tooltips never fire
// in this window. Cell size adapts to the view so the grid fills the full width.
private final class HeatmapView: NSView {
    var days: [(date: Date, tok: Int)] = [] { didSet { hoverIndex = nil; needsDisplay = true } }
    var accent: NSColor = Status.accent("done")
    private let gap: CGFloat = 3, gutter: CGFloat = 20, labelH: CGFloat = 14
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }   // row 0 = top = Monday

    private static let mdf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // Compact token count for the hover bubble.
    private static func fmtTok(_ n: Int) -> String { Tok.fmt(n) }

    // Days before the first cell's weekday, so week columns line up.
    private var leadingBlanks: Int {
        guard let first = days.first?.date else { return 0 }
        let wd = Calendar.current.component(.weekday, from: first)   // 1=Sun..7=Sat
        return (wd + 5) % 7   // Mon=0 .. Sun=6
    }

    // Square cell size fitting both the 7 rows and the week columns across the width.
    private var cellSize: CGFloat {
        let weeks = Int(ceil(Double(days.count + leadingBlanks) / 7.0))
        guard weeks > 0 else { return 0 }
        let byH = (bounds.height - labelH - gap * 6) / 7
        let byW = (bounds.width - gutter - gap * CGFloat(weeks - 1)) / CGFloat(weeks)
        return max(min(byH, byW), 1)
    }

    private func cellRect(_ i: Int, cell: CGFloat) -> NSRect {
        let slot = i + leadingBlanks
        return NSRect(x: gutter + CGFloat(slot / 7) * (cell + gap),
                      y: CGFloat(slot % 7) * (cell + gap),
                      width: cell, height: cell)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverIndex = dayIndex(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    // Inverse of cellRect: the day index under a view-local point. Forgiving by
    // half a gap so the cursor doesn't flicker the bubble off between cells.
    private func dayIndex(at p: NSPoint) -> Int? {
        let cell = cellSize
        guard cell > 0, p.x >= gutter, p.y >= 0 else { return nil }
        let col = Int((p.x - gutter) / (cell + gap))
        let row = Int(p.y / (cell + gap))
        guard row < 7 else { return nil }
        let i = col * 7 + row - leadingBlanks
        guard days.indices.contains(i),
              cellRect(i, cell: cell).insetBy(dx: -gap / 2, dy: -gap / 2).contains(p)
        else { return nil }
        return i
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let weeks = Int(ceil(Double(days.count + leadingBlanks) / 7.0))
        let cell = cellSize
        let maxV = Double(max(days.map { $0.tok }.max() ?? 1, 1))
        let empty = Theme.cardFill.cg(in: self)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(9, .regular), .foregroundColor: NSColor.tertiaryLabelColor]

        // Weekday gutter: label alternating rows, GitHub-style.
        for (row, s) in [(0, L("一", "M")), (2, L("三", "W")), (4, L("五", "F")), (6, L("日", "S"))] {
            (s as NSString).draw(
                at: NSPoint(x: 0, y: CGFloat(row) * (cell + gap) + (cell - 11) / 2),
                withAttributes: attrs)
        }

        for (i, d) in days.enumerated() {
            let path = NSBezierPath(roundedRect: cellRect(i, cell: cell), xRadius: 2.5, yRadius: 2.5)
            if d.tok == 0 {
                NSColor(cgColor: empty)?.setFill() ?? NSColor.gray.withAlphaComponent(0.1).setFill()
            } else {
                let a = 0.28 + 0.72 * min(1.0, Double(d.tok) / maxV)
                accent.withAlphaComponent(CGFloat(a)).setFill()
            }
            path.fill()
        }

        // Date axis: the first day of every 4th week column.
        let labelY = 7 * (cell + gap)
        for w in stride(from: 0, to: weeks, by: 4) {
            let i = max(0, w * 7 - leadingBlanks)
            guard i < days.count else { break }
            let s = Self.mdf.string(from: days[i].date) as NSString
            s.draw(at: NSPoint(x: gutter + CGFloat(w) * (cell + gap), y: labelY),
                   withAttributes: attrs)
        }

        // Hover: ring the cell and float a "M/d · N tokens" bubble beside it.
        if let i = hoverIndex, days.indices.contains(i) {
            let r = cellRect(i, cell: cell)
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 3.5, yRadius: 3.5)
            ring.lineWidth = 1.5
            ring.stroke()

            let d = days[i]
            let usage = d.tok > 0 ? L("\(Self.fmtTok(d.tok)) tokens", "\(Self.fmtTok(d.tok)) tokens") : L("无用量", "No usage")
            let text = "\(Self.mdf.string(from: d.date)) · \(usage)"
            let tAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(10, .medium), .foregroundColor: NSColor.labelColor]
            let ts = (text as NSString).size(withAttributes: tAttrs)
            let padX: CGFloat = 7, padY: CGFloat = 4
            var bubble = NSRect(x: r.midX - ts.width / 2 - padX,
                                y: r.minY - ts.height - padY * 2 - 5,
                                width: ts.width + padX * 2, height: ts.height + padY * 2)
            if bubble.minY < 0 { bubble.origin.y = r.maxY + 5 }   // top rows: flip below
            bubble.origin.x = min(max(bubble.origin.x, 0), bounds.width - bubble.width)
            // Opaque-ish backdrop so the readout stays legible over lit cells.
            let back = NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
            back.fill()
            NSColor(cgColor: Theme.hairline.cg(in: self))?.setStroke()
            back.stroke()
            (text as NSString).draw(at: NSPoint(x: bubble.minX + padX, y: bubble.minY + padY),
                                    withAttributes: tAttrs)
        }
    }
}

// One horizontal bar for the week's quota, split into per-day segments plus a
// trailing remainder. Each day's width = its share of the used quota (its token
// share × week_pct); the leftover track is what's still unused. Colors run cool→warm
// across the week so the segments read as time flowing left to right. Hovering a
// segment rings nothing but floats a "周三 7/03 · 12% · 1.4M" bubble below the bar —
// hand-rolled, since NSToolTip's dwell tooltips don't fire in this window.
private final class SegmentBarView: NSView {
    private struct Seg { let date: Date; let tok: Int; let pct: Double; let color: NSColor }
    private var segs: [Seg] = []
    private var unavailable = false
    private var weekPct: Int = 0
    private let barH: CGFloat = 24, gap: CGFloat = 1.5, radius: CGFloat = 7
    private let topGap: CGFloat = 6     // headroom so a lifted segment doesn't clip the top

    static let violet = NSColor(srgbRed: 0.68, green: 0.51, blue: 0.98, alpha: 1)   // matches StatsPane.palette[3]

    // Hover lifts the pointed segment; animIndex is the segment currently being
    // animated (kept through the collapse so the exit is animated too).
    private var animIndex: Int?
    private var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            if hoverIndex != nil { animIndex = hoverIndex }
            startHoverTimer(); needsDisplay = true
        }
    }
    private var hoverProg: CGFloat = 0     // 0…1 spring-driven lift progress
    private var hoverVel: CGFloat = 0
    private var animTimer: Timer?

    // Breathing highlight that sweeps across the unused remainder.
    private let sweepHost = CALayer()
    private let sweep = CAGradientLayer()

    override init(frame: NSRect) { super.init(frame: frame); setupLayers() }
    required init?(coder: NSCoder) { super.init(coder: coder); setupLayers() }

    private func setupLayers() {
        wantsLayer = true
        sweepHost.masksToBounds = true
        sweepHost.cornerRadius = radius
        sweepHost.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        let v = Self.violet
        sweep.colors = [v.withAlphaComponent(0).cgColor, v.withAlphaComponent(0.55).cgColor, v.withAlphaComponent(0).cgColor]
        sweep.locations = [-0.3, -0.15, 0.0]
        sweepHost.addSublayer(sweep)
        layer?.addSublayer(sweepHost)
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.3, -0.15, 0.0]
        a.toValue = [1.0, 1.15, 1.3]
        a.duration = 2.6
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(a, forKey: "sweep")
    }

    // Split the authoritative week_pct across the period's days by token share. When the
    // per-day token breakdown is missing (token capture skipped this week — the
    // CLAUDE_CODE_CHILD_SESSION pitfall), segs stays empty and draw() falls back to a flat
    // used block so the bar length still honors week_pct instead of reading as 0% used.
    func set(days: [(date: Date, tok: Int)], weekPct: Int) {
        unavailable = false
        self.weekPct = weekPct
        let tot = days.reduce(0) { $0 + $1.tok }
        let n = days.count
        segs = tot > 0 ? days.enumerated().map { i, d in
            Seg(date: d.date, tok: d.tok,
                pct: Double(d.tok) / Double(tot) * Double(weekPct),
                color: Self.warm(i, n))
        } : []
        hoverIndex = nil; animIndex = nil; hoverProg = 0
        sweepHost.isHidden = false
        needsLayout = true; needsDisplay = true
    }

    func setUnavailable() { unavailable = true; segs = []; hoverIndex = nil; sweepHost.isHidden = true; needsDisplay = true }

    // Cool blue → warm pink across the week.
    private static func warm(_ i: Int, _ n: Int) -> NSColor {
        let t = n <= 1 ? 0 : Double(i) / Double(n - 1)
        return NSColor(srgbRed: 0.29 + (0.95 - 0.29) * t,
                       green: 0.62 + (0.42 - 0.62) * t,
                       blue:  1.00 + (0.62 - 1.00) * t, alpha: 1)
    }

    private var barY: CGFloat { bounds.height - barH - topGap }   // bar near the top; bubble drops below

    // Keep the breathing sweep pinned to the unused remainder.
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let usedFrac = CGFloat(min(weekPct, 100)) / 100
        let rx = bounds.width * usedFrac
        let rw = max(0, bounds.width - rx)
        sweepHost.frame = CGRect(x: rx, y: barY, width: rw, height: barH)
        sweep.frame = sweepHost.bounds
        CATransaction.commit()
    }

    // Per-segment (x, width) along the full bar width; pct sums to ≤100, the rest is track.
    private func segFrames() -> [(x: CGFloat, w: CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        var x: CGFloat = 0
        for s in segs {
            let w = bounds.width * CGFloat(s.pct / 100)
            out.append((x, w)); x += w
        }
        return out
    }

    // Under-damped spring toward the hover target so the lift overshoots and settles.
    private func startHoverTimer() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            let target: CGFloat = self.hoverIndex == nil ? 0 : 1
            let k: CGFloat = 240, c: CGFloat = 20, dt: CGFloat = 1.0 / 60
            let force = -k * (self.hoverProg - target) - c * self.hoverVel
            self.hoverVel += force * dt
            self.hoverProg += self.hoverVel * dt
            if abs(self.hoverProg - target) < 0.001 && abs(self.hoverVel) < 0.001 {
                self.hoverProg = target; self.hoverVel = 0
                if target == 0 { self.animIndex = nil }
                tm.invalidate(); self.animTimer = nil
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y >= barY && p.y <= barY + barH else { hoverIndex = nil; return }
        let frames = segFrames()
        hoverIndex = frames.firstIndex { p.x >= $0.x && p.x < $0.x + $0.w && $0.w > 0 }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: barY, width: bounds.width, height: barH)

        if unavailable {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); rect.fill()
            let s = L("暂无配额数据", "No quota data") as NSString
            let a: [NSAttributedString.Key: Any] = [.font: Theme.font(10.5, .regular),
                                                     .foregroundColor: NSColor.tertiaryLabelColor]
            let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: barY + (barH - sz.height) / 2), withAttributes: a)
            return
        }

        // Body: violet-tinted remainder base + per-day used segments (hover seg drawn after, unclipped).
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        Self.violet.withAlphaComponent(0.12).setFill()
        rect.fill()
        if segs.isEmpty && weekPct > 0 {
            // No per-day breakdown available — draw a single flat used block so the bar
            // length matches the authoritative week_pct.
            Self.violet.setFill()
            NSRect(x: 0, y: barY, width: bounds.width * CGFloat(min(weekPct, 100)) / 100, height: barH).fill()
        } else {
            for (i, f) in segFrames().enumerated() where f.w > 0 {
                if i == animIndex { continue }
                segs[i].color.setFill()
                NSRect(x: f.x, y: barY, width: max(0, f.w - gap), height: barH).fill()
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        // Lifted segment + spring bubble.
        if let i = animIndex, segs.indices.contains(i), segFrames()[i].w > 0 {
            let f = segFrames()[i]
            drawHoverSeg(frame: f, seg: segs[i])
            drawBubble(centerX: f.x + (f.w - gap) / 2, seg: segs[i])
        }
    }

    // The hovered day, lifted and brightened with a soft drop shadow.
    private func drawHoverSeg(frame f: (x: CGFloat, w: CGFloat), seg: Seg) {
        let p = hoverProg
        let lift = p * 3, grow = p * 2
        let r = NSRect(x: f.x, y: barY - grow + lift, width: max(0, f.w - gap), height: barH + grow * 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = seg.color.withAlphaComponent(0.5 * p)
        sh.shadowBlurRadius = 8 * p
        sh.shadowOffset = NSSize(width: 0, height: -2 * p)
        sh.set()
        (seg.color.highlight(withLevel: 0.18) ?? seg.color).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // A "周三 7/03 · 12% · 1.4M" readout that springs up from below the bar.
    private func drawBubble(centerX: CGFloat, seg: Seg) {
        let pct = Int(seg.pct.rounded())
        let text = "\(Self.weekday(seg.date)) \(StatsPane.mdf.string(from: seg.date)) · \(pct)% · \(Self.fmtTok(seg.tok))"
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(10, .medium),
                                                     .foregroundColor: NSColor.labelColor]
        let ts = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 7, padY: CGFloat = 3
        let bw = ts.width + padX * 2, bh = ts.height + padY * 2
        let p = max(0, min(1, hoverProg))
        var bx = centerX - bw / 2
        bx = min(max(bx, 0), bounds.width - bw)
        let by = (barY - bh - 4) - (1 - hoverProg) * 6     // slides up into place as it settles
        let b = NSRect(x: bx, y: by, width: bw, height: bh)
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        ctx?.cgContext.setAlpha(p)
        let back = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
        back.fill()
        NSColor(cgColor: Theme.hairline.cg(in: self))?.setStroke()
        back.stroke()
        (text as NSString).draw(at: NSPoint(x: b.minX + padX, y: b.minY + padY), withAttributes: attrs)
        ctx?.restoreGraphicsState()
    }

    private static func weekday(_ d: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: d)   // 1=Sun..7=Sat
        return L(["周日", "周一", "周二", "周三", "周四", "周五", "周六"][wd - 1],
                 ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][wd - 1])
    }
    private static func fmtTok(_ n: Int) -> String { Tok.fmt(n) }
}

// The quota caption above the bar: "已用 55%" in muted text, remainder as a
// filled violet pill so "剩 45%" reads as the headline figure, not a footnote.
private final class QuotaCaption: NSView {
    private var usedPct: Int?
    func set(used: Int?) { usedPct = used; invalidateIntrinsicContentSize(); needsDisplay = true }

    private let pillH: CGFloat = 18, pillPadX: CGFloat = 8, gap: CGFloat = 7

    private var usedStr: NSAttributedString? {
        guard let p = usedPct else { return nil }
        return NSAttributedString(string: L("已用 \(p)%", "Used \(p)%"),
            attributes: [.font: Theme.font(10.5, .regular), .foregroundColor: NSColor.secondaryLabelColor])
    }
    private var pillStr: NSAttributedString? {
        guard let p = usedPct else { return nil }
        return NSAttributedString(string: L("剩 \(max(0, 100 - p))%", "\(max(0, 100 - p))% left"),
            attributes: [.font: Theme.rounded(10.5, .bold), .foregroundColor: SegmentBarView.violet])
    }

    override var intrinsicContentSize: NSSize {
        guard let u = usedStr, let pl = pillStr else { return NSSize(width: 0, height: pillH) }
        return NSSize(width: u.size().width + gap + pl.size().width + pillPadX * 2, height: pillH)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let u = usedStr, let pl = pillStr else { return }
        let midY = bounds.midY
        let us = u.size()
        u.draw(at: NSPoint(x: 0, y: midY - us.height / 2))
        let ps = pl.size()
        let pill = NSRect(x: us.width + gap, y: midY - pillH / 2, width: ps.width + pillPadX * 2, height: pillH)
        let path = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
        SegmentBarView.violet.withAlphaComponent(0.14).setFill(); path.fill()
        path.lineWidth = 1; SegmentBarView.violet.withAlphaComponent(0.30).setStroke(); path.stroke()
        pl.draw(at: NSPoint(x: pill.minX + pillPadX, y: midY - ps.height / 2))
    }
}

// A rounded percentage bar: a faint full-width track with a colored fill.
private final class RankBarView: NSView {
    var pct: Double = 0
    var color: NSColor = Status.accent("working")

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 6
        let y = (bounds.height - h) / 2
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: h),
                     xRadius: 3, yRadius: 3).fill()
        if pct > 0 {
            let w = max(h, bounds.width * CGFloat(min(pct, 1)))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: h),
                         xRadius: 3, yRadius: 3).fill()
        }
    }
}

// One distribution row: color dot, name, percentage bar, "45 (45%)". Hovering
// highlights the row and floats a "name · 45 (45%)" bubble, so a middle-truncated
// name still exposes its full text and the row echoes the hour-bar hover language.
private final class RankRowView: NSView {
    private let detail: String
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private let overlay = BubbleOverlay()

    init(name: String, valueText: String, pct: Double, color: NSColor) {
        detail = "\(name) · \(valueText) tokens (\(Int((pct * 100).rounded()))%)"
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let nameL = NSTextField(labelWithString: name)
        nameL.font = Theme.rounded(12, .semibold)
        nameL.textColor = .labelColor
        nameL.lineBreakMode = .byTruncatingMiddle
        nameL.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameL)

        let bar = RankBarView()
        bar.pct = pct
        bar.color = color
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        let val = NSTextField(labelWithString: "")
        let vs = NSMutableAttributedString()
        vs.append(NSAttributedString(string: valueText, attributes: [
            .foregroundColor: NSColor.labelColor, .font: Theme.rounded(12, .bold)]))
        vs.append(NSAttributedString(string: " (\(Int((pct * 100).rounded()))%)", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.font(10.5, .regular)]))
        val.attributedStringValue = vs
        val.setContentHuggingPriority(.required, for: .horizontal)
        val.setContentCompressionResistancePriority(.required, for: .horizontal)
        val.translatesAutoresizingMaskIntoConstraints = false
        addSubview(val)

        // Topmost, click-through overlay that renders the hover bubble above the labels.
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            nameL.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            nameL.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -10),
            nameL.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 160),
            bar.trailingAnchor.constraint(equalTo: val.leadingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            val.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            val.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        overlay.text = detail
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; overlay.hoverX = nil }
    private func track(_ event: NSEvent) {
        hovering = true
        overlay.hoverX = convert(event.locationInWindow, from: nil).x
    }

    // Faint rounded wash behind the labels to mark the active row.
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

// Left/right pager under a paged task list. The by-task breakdown builds one
// multi-field GlassCard per session, so rendering a long history at once stalls;
// this shows one page at a time with "‹ 上一页 · N/M · 下一页 ›" navigation.
// `onStep` receives −1 (prev) or +1 (next); ends are disabled and dimmed.
private final class PagerRow: NSView {
    private let onStep: (Int) -> Void
    private let prev: PagerArrow
    private let next: PagerArrow

    init(page: Int, pages: Int, onStep: @escaping (Int) -> Void) {
        self.onStep = onStep
        prev = PagerArrow(glyph: "‹", enabled: page > 0)
        next = PagerArrow(glyph: "›", enabled: page < pages - 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let counter = NSTextField(labelWithString: "\(page + 1) / \(pages)")
        counter.font = Theme.rounded(12, .semibold)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        counter.translatesAutoresizingMaskIntoConstraints = false

        prev.onClick = { [weak self] in self?.onStep(-1) }
        next.onClick = { [weak self] in self?.onStep(1) }
        for v in [prev, counter, next] { addSubview(v) }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            counter.centerXAnchor.constraint(equalTo: centerXAnchor),
            counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            prev.trailingAnchor.constraint(equalTo: counter.leadingAnchor, constant: -6),
            prev.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.leadingAnchor.constraint(equalTo: counter.trailingAnchor, constant: 6),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// One square pager button: a chevron glyph in a rounded chip. Disabled ends dim
// and stop responding to clicks/hover.
private final class PagerArrow: NSView {
    var onClick: (() -> Void)?
    private let enabled: Bool
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(glyph: String, enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = glyph
        label.font = Theme.rounded(15, .bold)
        label.textColor = enabled ? Status.accent("working") : .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        guard enabled else { return }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if enabled { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: Theme.chip, yRadius: Theme.chip)
        (hovering ? Status.accent("working").withAlphaComponent(0.14)
                  : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        path.fill()
    }
}

// Transparent, click-through layer that floats the hover bubble on top of a row's
// labels (a row's own draw() renders behind its subviews, so the bubble lives here).
private final class BubbleOverlay: NSView {
    var text = ""
    var hoverX: CGFloat? { didSet { if hoverX != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let x = hoverX else { return }
        let sz = HoverBubble.size(text: text)
        HoverBubble.draw(text: text, centerX: x, topY: (bounds.height + sz.height) / 2, in: self)
    }
}

// A top-left origin container so the breakdown list grows downward inside the
// scroll view (AppKit's default bottom-left origin would stack rows upward).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
