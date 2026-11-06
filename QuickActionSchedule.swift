import Cocoa

// MARK: - Schedules
//
// When a quick action runs on its own (design/quick-actions-schedule.html, scheme 2).
// Stored inside the action in actions.json, written so a person or an AI can type it:
//   {"every": 5}                      every 5 minutes, on the clock (:00 :05 :10 …)
//   {"at": "06:00"}                   every day at 06:00
//   {"at": "06:00", "days": [1,2,3]}  Mon/Tue/Wed at 06:00 (1 = Monday … 7 = Sunday)
// No schedule = manual only. Also describes launchd jobs whose timing fits these shapes.

struct QuickActionSchedule: Codable, Equatable, Hashable {
    var every: Int?
    var at: String?
    var days: [Int]?

    static let minEvery = 5

    static func everyMinutes(_ n: Int) -> Self { Self(every: max(minEvery, n)) }
    static func daily(_ hour: Int, _ minute: Int, days: [Int]? = nil) -> Self {
        Self(at: String(format: "%02d:%02d", hour, minute), days: days?.isEmpty == false ? days?.sorted() : nil)
    }

    /// (hour, minute) of `at`, nil when missing or malformed.
    var time: (hour: Int, minute: Int)? {
        guard let parts = at?.split(separator: ":"), parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }

    var isValid: Bool { every.map { $0 >= Self.minEvery } ?? (time != nil) }

    /// The first run strictly after `date`. Interval schedules line up with midnight,
    /// so "every 60" means on the hour.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        if let n = every, n >= Self.minEvery {
            let day = calendar.startOfDay(for: date)
            let minutes = Int(date.timeIntervalSince(day) / 60)
            let slot = (minutes / n + 1) * n
            if slot < 24 * 60 { return day.addingTimeInterval(TimeInterval(slot * 60)) }
            return calendar.date(byAdding: .day, value: 1, to: day)
        }
        guard let t = time else { return nil }
        let allowed = Set(days ?? Array(1...7))
        var day = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            if allowed.contains(Self.isoWeekday(day, calendar)),
               let run = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day), run > date {
                return run
            }
            guard let d = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = d
        }
        return nil
    }

    static func isoWeekday(_ date: Date, _ calendar: Calendar = .current) -> Int {
        let w = calendar.component(.weekday, from: date)   // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    /// "每 5 分钟" / "每小时" / "每天 06:00" / "工作日 06:00" / "周一、三 06:00"
    var summary: String {
        if let n = every {
            if n == 60 { return L("每小时", "Hourly") }
            if n % 60 == 0 { return L("每 \(n / 60) 小时", "Every \(n / 60) h") }
            return L("每 \(n) 分钟", "Every \(n) min")
        }
        let at = self.at ?? "?"
        guard let d = days, Set(d) != Set(1...7) else { return L("每天 \(at)", "Daily \(at)") }
        if Set(d) == Set(1...5) { return L("工作日 \(at)", "Weekdays \(at)") }
        if Set(d) == Set([6, 7]) { return L("周末 \(at)", "Weekends \(at)") }
        return d.sorted().map(Self.dayName).joined(separator: L("、", ", ")) + " " + at
    }

    static func dayName(_ iso: Int) -> String {
        let zh = ["一", "二", "三", "四", "五", "六", "日"]
        let en = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let i = max(1, min(7, iso)) - 1
        return L("周" + zh[i], en[i])
    }

    /// Short "when" for a list's right edge: "09:15" today, "明天 06:00", "周日 21:00".
    static func shortWhen(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let hm = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return hm }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("明天 ", "Tmrw ") + hm
        }
        return dayName(isoWeekday(date, calendar)) + " " + hm
    }
}

// MARK: - Scheduler

/// Fires scheduled quick actions while SpectiX is running. A missed slot (Mac asleep,
/// app quit) is made up once when it notices — ten missed runs still make one.
final class QuickActionScheduler {
    static let shared = QuickActionScheduler()

    struct Fired: Codable {
        var at: Date
        var catchUp: Bool
    }

    private struct Entry: Codable {
        var schedule: QuickActionSchedule
        /// Slots up to here are settled (run or deliberately skipped).
        var settled: Date
        var fired: Fired?
    }

    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private static var statePath: String { NSHomeDirectory() + "/.claude/spectix/actions/schedule-state.json" }
    /// Later than this past its slot counts as made up after the fact.
    private static let lateness: TimeInterval = 120

    private init() {
        if let data = FileManager.default.contents(atPath: Self.statePath),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        tick()
    }

    func nextRun(_ a: QuickAction) -> Date? {
        guard let s = a.schedule, s.isValid else { return nil }
        let from = entries[a.key].flatMap { $0.schedule == s ? $0.settled : nil } ?? Date()
        return s.next(after: max(from, Date().addingTimeInterval(-1)))
    }

    func lastFired(_ key: String) -> Fired? { entries[key]?.fired }

    private func tick() {
        guard !Demo.enabled else { return }
        QuickActionStore.shared.reloadIfChanged()
        let now = Date()
        var changed = false
        var live: Set<String> = []
        for a in QuickActionStore.shared.actions {
            guard let s = a.schedule, s.isValid else { continue }
            live.insert(a.key)
            // New or edited schedule: start counting from now, don't fire for the past.
            guard var e = entries[a.key], e.schedule == s else {
                entries[a.key] = Entry(schedule: s, settled: now, fired: entries[a.key]?.fired)
                changed = true
                continue
            }
            guard let due = s.next(after: e.settled), due <= now else { continue }
            e.settled = now
            if !QuickActionRunner.shared.isRunning(a.key) {
                e.fired = Fired(at: now, catchUp: now.timeIntervalSince(due) > Self.lateness)
                QuickActionRunner.shared.run(a, scheduled: true)
            }
            entries[a.key] = e
            changed = true
        }
        for key in entries.keys where !live.contains(key) {
            entries[key] = nil
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        let url = URL(fileURLWithPath: Self.statePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

// MARK: - Editor

/// "When does it run": manual / every N min / hourly / daily / some weekdays, plus a
/// time and the next-run line. Shared by the add/edit page and a launchd job's page.
final class QuickActionScheduleEditor: NSView {
    var onChange: ((QuickActionSchedule?) -> Void)?

    private enum Mode: Int { case manual, every, hourly, daily, weekly }

    private let modes: [Mode]
    private let seg: NSSegmentedControl
    private let every = NSPopUpButton()
    private let time = NSDatePicker()
    private var dayButtons: [NSButton] = []
    private let everyRow = NSStackView()
    private let timeRow = NSStackView()
    private let daysRow = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    /// 5/10/15/30, plus whatever odd interval a launchd job came with.
    private var everyChoices = [5, 10, 15, 30]

    /// `manualTitle`: what "no schedule" means here ("只手动" for a button,
    /// "不定时" for a launchd job that is only kicked by hand).
    init(manualTitle: String = L("只手动", "Manual")) {
        modes = [.manual, .every, .hourly, .daily, .weekly]
        seg = NSSegmentedControl(labels: [manualTitle, L("每 N 分钟", "Every N min"), L("每小时", "Hourly"),
                                          L("每天", "Daily"), L("每周几", "Weekdays")],
                                 trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        seg.target = self
        seg.action = #selector(changed)
        seg.selectedSegment = 0
        seg.segmentDistribution = .fillEqually
        seg.controlSize = .small
        seg.font = Theme.font(10.5, .medium)

        for n in everyChoices { every.addItem(withTitle: L("\(n) 分钟", "\(n) min")) }
        every.controlSize = .small
        every.target = self
        every.action = #selector(changed)
        everyRow.setViews([Self.label(L("每", "Every")), every], in: .leading)

        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = .hourMinute
        time.controlSize = .small
        time.target = self
        time.action = #selector(changed)
        time.dateValue = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date()) ?? Date()
        timeRow.setViews([Self.label(L("几点", "At")), time], in: .leading)

        var days: [NSView] = [Self.label(L("周几", "On"))]
        for d in 1...7 {
            let b = NSButton(title: String(QuickActionSchedule.dayName(d).suffix(L("一", "Mon").count)),
                             target: self, action: #selector(changed))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Theme.font(10.5, .medium)
            b.state = d <= 5 ? .on : .off
            dayButtons.append(b)
            days.append(b)
        }
        daysRow.setViews(days, in: .leading)
        daysRow.spacing = 3

        summary.font = Theme.font(10.5, .regular)
        summary.textColor = .secondaryLabelColor
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [seg, everyRow, timeRow, daysRow, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            seg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.font(11, .regular)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// nil = manual. Setting it doesn't call `onChange`.
    var schedule: QuickActionSchedule? {
        get {
            let cal = Calendar.current
            let h = cal.component(.hour, from: time.dateValue), m = cal.component(.minute, from: time.dateValue)
            switch modes[max(0, seg.selectedSegment)] {
            case .manual: return nil
            case .every: return .everyMinutes(everyChoices[max(0, every.indexOfSelectedItem)])
            case .hourly: return .everyMinutes(60)
            case .daily: return .daily(h, m)
            case .weekly:
                let days = dayButtons.indices.filter { dayButtons[$0].state == .on }.map { $0 + 1 }
                return .daily(h, m, days: days.isEmpty ? [QuickActionSchedule.isoWeekday(Date())] : days)
            }
        }
        set {
            let s = newValue
            var mode = Mode.manual
            if let n = s?.every {
                mode = n == 60 ? .hourly : .every
                if n != 60, !everyChoices.contains(n) {
                    everyChoices.append(n)
                    every.addItem(withTitle: L("\(n) 分钟", "\(n) min"))
                }
                every.selectItem(at: everyChoices.firstIndex(of: n) ?? 0)
            } else if let s, let t = s.time {
                time.dateValue = Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? time.dateValue
                if let d = s.days, Set(d) != Set(1...7) {
                    mode = .weekly
                    for (i, b) in dayButtons.enumerated() { b.state = d.contains(i + 1) ? .on : .off }
                } else {
                    mode = .daily
                }
            }
            seg.selectedSegment = modes.firstIndex(of: mode) ?? 0
            update()
        }
    }

    /// Extra line under the summary (e.g. "runs while SpectiX is open").
    var footnote: String? { didSet { update() } }

    @objc private func changed() {
        update()
        onChange?(schedule)
    }

    private func update() {
        let mode = modes[max(0, seg.selectedSegment)]
        everyRow.isHidden = mode != .every
        timeRow.isHidden = !(mode == .daily || mode == .weekly)
        daysRow.isHidden = mode != .weekly
        guard let s = schedule else {
            summary.stringValue = L("不会自己跑。", "Never runs on its own.")
            return
        }
        var text = s.summary
        if let next = s.next(after: Date()) {
            text += L(" · 下次：", " · next: ") + QuickActionSchedule.shortWhen(next)
        }
        if let f = footnote { text += "\n" + f }
        summary.stringValue = text
    }
}
