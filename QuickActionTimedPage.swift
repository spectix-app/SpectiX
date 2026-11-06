import Cocoa

// MARK: - Scheduled page
//
// The drawer's second page (design/quick-actions-schedule.html, scheme 2): one list of
// everything that runs on its own — quick actions with a schedule, and the user's launchd
// jobs. Clicking an action opens its normal detail page; clicking a job opens a page here.

private struct TimedItem {
    enum Source {
        case action(QuickAction)
        case job(LaunchJob)
        case more(count: Int, open: Bool)
    }

    let key: String
    let source: Source
    let emoji: String?
    let symbol: String?
    let keepAliveDot: Bool
    let title: String
    let sub: NSAttributedString
    let whenTop: String
    let whenBelow: String
    let off: Bool
}

final class QuickActionTimedPage: NSView {
    var onOpenAction: ((QuickAction) -> Void)?
    var onLayoutChange: (() -> Void)?

    private let box = NSView()
    private let list = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString:
        L("还没有会自己跑的东西。在某个按钮的编辑页里设「什么时候跑」，它就会出现在这里。",
          "Nothing runs on its own yet. Set \"When\" in a button's edit page and it shows up here."))
    private let detail = TimedJobDetail()
    private var rows: [TimedRow] = []
    private var rowKeys: [String] = []
    private var showOthers = false
    private var openLabel: String?
    private var lastCount = -1

    var count: Int {
        let actions = QuickActionStore.shared.actions.filter { $0.schedule?.isValid == true }.count
        return actions + LaunchAgents.shared.jobs.count
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: box.topAnchor),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        empty.font = Theme.font(11, .regular)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        detail.onBack = { [weak self] in self?.closeJob() }
        detail.isHidden = true

        let root = NSStackView(views: [box, empty, detail])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.widthAnchor.constraint(equalTo: root.widthAnchor),
            empty.widthAnchor.constraint(equalTo: root.widthAnchor),
            detail.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(dataChanged), name: QuickActionStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(dataChanged), name: QuickActionRunner.didChange, object: nil)
        nc.addObserver(self, selector: #selector(ticked), name: QuickActionRunner.didTick, object: nil)
        nc.addObserver(self, selector: #selector(launchChanged), name: LaunchAgents.didChange, object: nil)
        resolveColors()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func prepareForShow() {
        openLabel = nil
        LaunchAgents.shared.refresh()
        rebuild()
        applyVisibility()
    }

    // MARK: Observers

    @objc private func dataChanged() { rebuild() }

    @objc private func ticked() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, openLabel == nil else { return }
        rebuild()
    }

    @objc private func launchChanged() {
        rebuild()
        guard let label = openLabel else { return }
        if let job = LaunchAgents.shared.jobs.first(where: { $0.label == label }) {
            detail.update(job)
        } else {
            closeJob()
        }
    }

    // MARK: Job page

    private func open(_ job: LaunchJob) {
        openLabel = job.label
        detail.show(job)
        applyVisibility()
    }

    private func closeJob() {
        openLabel = nil
        rebuild()
        applyVisibility()
    }

    private func applyVisibility() {
        let inJob = openLabel != nil
        detail.isHidden = !inJob
        box.isHidden = inJob || rowKeys.isEmpty
        empty.isHidden = inJob || !rowKeys.isEmpty
        onLayoutChange?()
    }

    // MARK: List

    private func rebuild() {
        let items = makeItems()
        let keys = items.map(\.key)
        if keys == rowKeys {
            for (row, item) in zip(rows, items) { row.apply(item) }
        } else {
            for r in rows { list.removeView(r); r.removeFromSuperview() }
            rows = items.enumerated().map { i, item in
                let row = TimedRow(item, first: i == 0)
                row.onClick = { [weak self] in self?.clicked($0) }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                return row
            }
            rowKeys = keys
            if openLabel == nil { applyVisibility() }
        }
        if count != lastCount {
            lastCount = count
            onLayoutChange?()
        }
    }

    private func clicked(_ item: TimedItem) {
        switch item.source {
        case .action(let a): onOpenAction?(a)
        case .job(let j): open(j)
        case .more:
            showOthers.toggle()
            rebuild()
        }
    }

    private struct Entry {
        let item: TimedItem
        let group: Int
        let next: Date?
    }

    private func makeItems() -> [TimedItem] {
        let runner = QuickActionRunner.shared
        let agents = LaunchAgents.shared
        var entries: [Entry] = []

        for a in QuickActionStore.shared.actions {
            guard let s = a.schedule, s.isValid else { continue }
            let next = QuickActionScheduler.shared.nextRun(a)
            var bits: [(String, NSColor?)] = [(s.summary, nil)]
            if let t = runner.elapsed(a.key) {
                bits.append((L("在跑 \(QuickActionTile.clock(t))", "Running \(QuickActionTile.clock(t))"), Status.accent("working")))
            } else if let r = runner.results[a.key], !r.stopped {
                bits.append(Self.result(ok: r.ok, code: r.exitCode, at: r.finished))
                if QuickActionScheduler.shared.lastFired(a.key)?.catchUp == true {
                    bits.append((L("醒来补跑", "made up after wake"), nil))
                }
            }
            let (top, below) = Self.when(next)
            entries.append(Entry(item: TimedItem(
                key: "a:" + a.key, source: .action(a), emoji: a.icon ?? "⚡️", symbol: nil, keepAliveDot: false,
                title: a.name, sub: Self.sub(bits), whenTop: top, whenBelow: below, off: false),
                group: 1, next: next))
        }

        let own = agents.jobs.filter(\.own)
        let others = agents.jobs.filter { !$0.own }
        for j in own { entries.append(jobEntry(j)) }
        entries.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            switch ($0.next, $1.next) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }
        }
        var items = entries.map(\.item)

        if !others.isEmpty {
            let title = L("其他 \(others.count) 个（别的软件装的）", "\(others.count) more from other apps")
            items.append(TimedItem(
                key: "more", source: .more(count: others.count, open: showOthers), emoji: nil,
                symbol: "ellipsis.circle", keepAliveDot: false, title: title, sub: NSAttributedString(),
                whenTop: showOthers ? "⌃" : "⌄", whenBelow: "", off: false))
            if showOthers {
                items += others.map(jobEntry).sorted { $0.item.title < $1.item.title }.map(\.item)
            }
        }
        return items
    }

    private func jobEntry(_ job: LaunchJob) -> Entry {
        let agents = LaunchAgents.shared
        let st = agents.status[job.label]
        let running = st?.pid != nil
        var bits: [(String, NSColor?)] = []
        switch job.timing {
        case .schedule(let s, _): bits.append((s.summary, nil))
        case .custom: bits.append((L("自定义日程", "Custom schedule"), nil))
        case .keepAlive: break
        case .atLogin: bits.append((L("登录时跑", "At login"), nil))
        case .onDemand: bits.append((L("手动", "Manual"), nil))
        }
        if !job.enabled {
            bits.append((L("已停用", "Disabled"), nil))
        } else if running {
            // launchctl reports the PREVIOUS exit code while a job runs, so never show it here.
            let text = job.timing == .keepAlive ? L("一直在跑", "Always running") : L("在跑", "Running")
            bits.append((text, Status.accent("working")))
        } else if job.timing == .keepAlive {
            bits.append((L("没在跑", "Not running"), nil))
        } else if let code = st?.lastExit, code != 0 {
            bits.append(Self.result(ok: false, code: code, at: nil))
        } else if let last = agents.lastRun(job) {
            bits.append(Self.result(ok: true, code: 0, at: last))
        }
        let next = agents.nextRun(job)
        let keep = job.enabled && job.timing == .keepAlive
        let (top, below) = !job.enabled ? ("—", "") : keep ? (L("常驻", "Always"), "") : Self.when(next)
        let group = !job.enabled ? 2 : keep ? 0 : 1
        return Entry(item: TimedItem(
            key: "j:" + job.label, source: .job(job), emoji: nil, symbol: "gearshape", keepAliveDot: keep && running,
            title: job.name, sub: Self.sub(bits), whenTop: top, whenBelow: below, off: !job.enabled),
            group: group, next: next)
    }

    private static func result(ok: Bool, code: Int32, at date: Date?) -> (String, NSColor?) {
        let ago = date.map { QuickActionDetail.ago($0) }
        if ok { return ("✓ " + (ago ?? ""), Status.accent("done")) }
        return (L("✗ 上次失败 · 退出码 \(code)", "✗ Last run failed · exit \(code)"), Status.accent("needs"))
    }

    private static func sub(_ bits: [(String, NSColor?)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, bit) in bits.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])) }
            out.append(NSAttributedString(string: bit.0, attributes: [.foregroundColor: bit.1 ?? NSColor.secondaryLabelColor]))
        }
        out.addAttribute(.font, value: Theme.font(10, .regular), range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Right-edge pair: today "09:15" over "3 分钟后"; later "明天" over "06:00".
    private static func when(_ date: Date?) -> (String, String) {
        guard let date else { return ("—", "") }
        let short = QuickActionSchedule.shortWhen(date)
        if Calendar.current.isDateInToday(date) {
            let mins = max(1, Int(date.timeIntervalSinceNow / 60))
            let until = mins < 60 ? L("\(mins) 分钟后", "in \(mins) min") : L("\(mins / 60) 小时后", "in \(mins / 60) h")
            return (short, until)
        }
        let parts = short.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (short, "")
    }

    private func resolveColors() {
        box.layer?.backgroundColor = Theme.cardFill.cg(in: self)
        box.layer?.borderColor = Theme.hairline.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - Row

private final class SourceTag: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isAction = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.rounded(8.5, .heavy)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(isAction: Bool) {
        self.isAction = isAction
        label.stringValue = isAction ? L("按钮", "Button") : "SYS"
        resolveColors()
    }

    private func resolveColors() {
        label.textColor = isAction ? Theme.agentAccent : .secondaryLabelColor
        layer?.backgroundColor = (isAction ? Theme.agentAccent.withAlphaComponent(0.14) : Theme.cardFill).cg(in: self)
        layer?.borderColor = (isAction ? Theme.agentAccent.withAlphaComponent(0.35) : Theme.hairline).cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

private final class TimedRow: NSView {
    var onClick: ((TimedItem) -> Void)?

    private var item: TimedItem
    private var hovering = false
    private let iconBox = NSView()
    private let emoji = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let sourceTag = SourceTag()
    private let sub = NSTextField(labelWithString: "")
    private let whenTop = NSTextField(labelWithString: "")
    private let whenBelow = NSTextField(labelWithString: "")
    private let separator = NSView()

    init(_ item: TimedItem, first: Bool) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 7
        iconBox.layer?.cornerCurve = .continuous
        iconBox.layer?.borderWidth = 1
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        emoji.font = .systemFont(ofSize: 12)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = Status.accent("done").cgColor
        for v in [emoji, symbol, dot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            iconBox.addSubview(v)
            v.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor).isActive = true
            v.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 24),
            iconBox.heightAnchor.constraint(equalToConstant: 24),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        title.font = Theme.rounded(11.8, .bold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [title, sourceTag])
        titleRow.spacing = 6
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let mn = NSStackView(views: [titleRow, sub])
        mn.orientation = .vertical
        mn.alignment = .leading
        mn.spacing = 2
        mn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mn.setHuggingPriority(.init(1), for: .horizontal)   // the when column stays at the right edge

        whenTop.font = .monospacedDigitSystemFont(ofSize: 11, weight: .heavy)
        whenBelow.font = Theme.font(9, .semibold)
        whenBelow.textColor = .tertiaryLabelColor
        let when = NSStackView(views: [whenTop, whenBelow])
        when.orientation = .vertical
        when.alignment = .trailing
        when.spacing = 0
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        when.setContentHuggingPriority(.required, for: .horizontal)

        let h = NSStackView(views: [iconBox, mn, when])
        h.spacing = 9
        h.alignment = .centerY
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)

        separator.wantsLayer = true
        separator.isHidden = first
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        apply(item)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ item: TimedItem) {
        self.item = item
        emoji.stringValue = item.emoji ?? ""
        emoji.isHidden = item.emoji == nil
        symbol.image = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.isHidden = item.emoji != nil || item.keepAliveDot
        dot.isHidden = !item.keepAliveDot
        title.stringValue = item.title
        switch item.source {
        case .action: sourceTag.isHidden = false; sourceTag.set(isAction: true)
        case .job: sourceTag.isHidden = false; sourceTag.set(isAction: false)
        case .more: sourceTag.isHidden = true
        }
        sub.attributedStringValue = item.sub
        sub.isHidden = item.sub.length == 0
        whenTop.stringValue = item.whenTop
        whenBelow.stringValue = item.whenBelow
        whenBelow.isHidden = item.whenBelow.isEmpty
        alphaValue = item.off ? 0.5 : 1
        resolveColors()
    }

    private func resolveColors() {
        layer?.backgroundColor = hovering ? Theme.cardFillHover.cg(in: self) : NSColor.clear.cgColor
        iconBox.layer?.backgroundColor = Theme.cardFill.cg(in: self)
        iconBox.layer?.borderColor = Theme.hairline.cg(in: self)
        separator.layer?.backgroundColor = Theme.hairline.cg(in: self)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; resolveColors() }
    override func mouseExited(with event: NSEvent) { hovering = false; resolveColors() }
    override func mouseDown(with event: NSEvent) { onClick?(item) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }
}

// MARK: - Launchd job page

private final class TimedJobDetail: NSView {
    var onBack: (() -> Void)?

    private var job: LaunchJob?
    private let back = NSButton(title: L("‹ 定时", "‹ Scheduled"), target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let sourceTag = SourceTag()
    private let path = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let status = NSTextField(labelWithString: "")
    private let editor = QuickActionScheduleEditor(manualTitle: L("不定时", "Not timed"))
    private let fixed = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let runButton = QuickActionPillButton(primary: true)
    private let toggleButton = QuickActionPillButton(primary: false)
    private let logButton = QuickActionPillButton(primary: false)
    private let finderButton = QuickActionPillButton(primary: false)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        back.isBordered = false
        back.font = Theme.rounded(10.5, .semibold)
        back.contentTintColor = .secondaryLabelColor
        back.target = self
        back.action = #selector(backClicked)
        let top = NSStackView(views: [back, NSView()])

        name.font = Theme.rounded(13.5, .bold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceTag.set(isAction: false)
        let titleRow = NSStackView(views: [name, sourceTag])
        titleRow.spacing = 7
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        status.font = Theme.rounded(11, .semibold)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [dot, status])
        statusRow.spacing = 6

        let section = NSTextField(labelWithString: L("什么时候跑", "When"))
        section.font = Theme.rounded(9.5, .heavy)
        section.textColor = .tertiaryLabelColor
        fixed.font = Theme.font(11, .regular)
        fixed.textColor = .secondaryLabelColor
        error.font = Theme.font(10.5, .regular)
        error.textColor = .systemOrange
        error.stringValue = L("没改成：文件写不了或格式不认识。", "Couldn't change it: the file isn't writable or its format isn't understood.")
        error.isHidden = true

        editor.onChange = { [weak self] s in self?.scheduleChanged(s) }

        runButton.set(title: L("跑一次", "Run once"), symbol: "play.fill")
        logButton.set(title: L("看日志", "Log"), symbol: "doc.text")
        finderButton.set(title: L("在 Finder 显示", "Show in Finder"), symbol: "folder")
        for (b, sel) in [(runButton, #selector(runClicked)), (toggleButton, #selector(toggleClicked)),
                         (logButton, #selector(logClicked)), (finderButton, #selector(finderClicked))] {
            b.target = self
            b.action = sel
        }
        let row1 = NSStackView(views: [runButton, toggleButton, NSView()])
        let row2 = NSStackView(views: [logButton, finderButton, NSView()])
        row1.spacing = 8
        row2.spacing = 8

        let stack = NSStackView(views: [top, titleRow, path, statusRow, section, editor, fixed, error, row1, row2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(3, after: titleRow)
        stack.setCustomSpacing(10, after: path)
        stack.setCustomSpacing(12, after: statusRow)
        stack.setCustomSpacing(12, after: error)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for v in [top, path, editor, fixed, error, row1, row2] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Opening a job: also reset the editor to what the file says.
    func show(_ job: LaunchJob) {
        error.isHidden = true
        fill(job, resetEditor: true)
    }

    /// Same job after a refresh (its path changes on enable / disable).
    func update(_ job: LaunchJob) { fill(job, resetEditor: job.schedule != editor.schedule) }

    private func fill(_ job: LaunchJob, resetEditor: Bool) {
        self.job = job
        name.stringValue = job.name
        path.stringValue = (job.path as NSString).abbreviatingWithTildeInPath

        let agents = LaunchAgents.shared
        let st = agents.status[job.label]
        let color: NSColor
        if !job.enabled {
            color = .tertiaryLabelColor
            status.stringValue = L("已停用", "Disabled")
        } else if let pid = st?.pid {
            color = Status.accent("working")
            status.stringValue = L("在跑 (pid \(pid))", "Running (pid \(pid))")
        } else if st == nil {
            color = .tertiaryLabelColor
            status.stringValue = L("没加载", "Not loaded")
        } else if let code = st?.lastExit, code != 0 {
            color = Status.accent("needs")
            status.stringValue = L("上次失败 · 退出码 \(code)", "Last run failed · exit \(code)")
        } else if let last = agents.lastRun(job) {
            color = Status.accent("done")
            status.stringValue = L("上次成功 · \(QuickActionDetail.ago(last))", "Last run OK · \(QuickActionDetail.ago(last))")
        } else {
            color = .tertiaryLabelColor
            status.stringValue = L("已加载 · 还没跑过", "Loaded · not run yet")
        }
        dot.layer?.backgroundColor = color.cgColor
        status.textColor = st?.pid != nil && job.enabled ? color : .labelColor

        editor.isHidden = !job.editable
        fixed.isHidden = job.editable
        if job.editable {
            if resetEditor {
                editor.schedule = job.schedule
                editor.footnote = Self.footnote(job.schedule)
            }
        } else if job.timing == .keepAlive {
            fixed.stringValue = L("一直在跑", "Always running")
        } else {
            fixed.stringValue = L("自定义日程 · 打开文件改", "Custom schedule · edit the file to change it")
        }

        toggleButton.set(title: job.enabled ? L("停用", "Disable") : L("启用", "Enable"),
                         symbol: job.enabled ? "pause.fill" : "play.circle")
        runButton.isEnabled = job.enabled
        runButton.alphaValue = job.enabled ? 1 : 0.4
        logButton.isHidden = job.logPath == nil
    }

    private static func footnote(_ s: QuickActionSchedule?) -> String {
        var text = L("改的是系统任务的 plist，立刻生效。", "Changes the system job's plist; takes effect immediately.")
        if s?.every != nil {
            text += L(" 间隔任务从上次跑完起算，不按整点。", " An interval counts from the last run, not on the clock.")
        }
        return text
    }

    private func scheduleChanged(_ s: QuickActionSchedule?) {
        guard let job else { return }
        error.isHidden = LaunchAgents.shared.setSchedule(job, s)
        editor.footnote = Self.footnote(s)
    }

    @objc private func backClicked() { onBack?() }
    @objc private func runClicked() { if let job { LaunchAgents.shared.runNow(job) } }
    @objc private func toggleClicked() { if let job { LaunchAgents.shared.setEnabled(job, !job.enabled) } }
    @objc private func finderClicked() { if let job { LaunchAgents.shared.revealInFinder(job) } }
    @objc private func logClicked() {
        if let log = job?.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
    }
}
