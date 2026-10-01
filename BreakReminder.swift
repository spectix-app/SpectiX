import Cocoa

// MARK: - BreakReminder (番茄倒计时 · 连续工作计时 + 休息)
//
// The "don't sit here too long" tool. Four phases, one clock:
//
//   idle ──(AI activity / 开始倒计时)──▶ working ──(clock hits 0)──▶ overtime
//     ▲                                     │                           │
//     │                                     └──────(现在休息)───────────┘
//     └──────────(rest clock hits 0 / 结束休息)──── resting ◀───────────┘
//
// · working: counts DOWN from the work length (Settings › 休息提醒) — the same
//   stretch clock as before, read as "time left" instead of "time spent".
// · overtime: the clock keeps running past 0 into the negatives; the panel and chip
//   go red and breathe until you take the break. Not a separate timer — same deadline.
// · resting: counts down the rest length; the cat stretches.
// · idle: rest is over (or you walked away). Nothing runs until the AI shows new
//   activity (a session enters 运行) or you press 开始倒计时 — the user asked for the
//   restart to be deliberate, not "you touched the mouse".
//
// Walking away is still a break even if you never pressed the button: the presence
// rules from v1 stay (no input for 5 min with nothing running, or 20 min with a turn
// running, or the Mac slept) and drop the clock to idle. This is not about Claude's
// work time (SessionClock in Stats.swift); it is about the human.
final class BreakReminder {
    static let shared = BreakReminder()

    enum Phase { case idle, working, overtime, resting }
    enum Event { case overtime(Int), restEnded }

    /// No input for this long, with nothing running, is a break.
    private let gap: TimeInterval = 5 * 60
    /// With a session running, this much absence still is — whatever Claude is doing.
    private let waitGap: TimeInterval = 20 * 60
    /// "+10 分" — once per round (the research note: an unlimited snooze is how a
    /// reminder stops meaning anything).
    static let extensionSec = 10 * 60

    private(set) var phase: Phase = .idle
    private var workStart: Date?
    private var extraSec: Int = 0
    private(set) var extended = false
    /// Kept through the 休息好了？ that follows a rest, so that screen can say how long
    /// you have been away — cleared only when the next round starts.
    private var restStart: Date?
    /// The rest was inferred (you walked away / the lid closed), not pressed. AI activity
    /// ends an inferred rest the way it used to end the old idle state; a rest you chose
    /// runs its full length.
    private var restAuto = false
    private var restEnd: Date? {
        restStart.map { $0.addingTimeInterval(TimeInterval(AppSettings.breakRestMinutes * 60)) }
    }
    private var lastPoll = Date.distantPast
    private var lastPresent = Date.distantPast
    /// Reminder multiples fired this round (the banner repeats each work-length).
    private var reminded = 0
    /// True after the first stretch of the day started: the lenient "a session is
    /// already running when the app comes up" auto-start only applies before it.
    private var everStarted = false

    /// A banner the clock earned while a session was mid-turn. Held rather than fired:
    /// "该休息了" landing in the middle of a run is a reminder you can't act on — the
    /// moment to stand up is when the run ends. Released on the first quiet poll, or
    /// after `holdCap` if the machine simply never goes quiet (an autorun night would
    /// otherwise swallow the reminder for good).
    private var heldBanner: (sec: Int, since: Date)?
    private let holdCap: TimeInterval = 10 * 60

    /// The clock just crossed 0 (or +10 分 ran out again): the header pops the panel
    /// open once for it. Cleared by whoever shows it; `dismissed` stops a re-pop
    /// after the user closed the panel by hand this round.
    var autoShowPending = false
    var dismissed = false

    private let todayKeyKey = "breakTodayKey"
    private let todaySecKey = "breakTodaySec"
    private var todayKey: String
    private var todaySec: Int

    /// Posted once a second while a clock runs, so the chip and the strip tick by the
    /// second instead of by the 2.5s refresh. `.common` so dragging a window doesn't
    /// freeze the figure.
    static let tick = Notification.Name("BreakReminder.tick")
    private var ticker: Timer?

    private init() {
        todayKey = UserDefaults.standard.string(forKey: todayKeyKey) ?? ""
        todaySec = UserDefaults.standard.integer(forKey: todaySecKey)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.phase != .idle || self.restedSec != nil else { return }
            NotificationCenter.default.post(name: Self.tick, object: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: readings

    private var deadline: Date? {
        workStart.map { $0.addingTimeInterval(TimeInterval(AppSettings.breakReminderMinutes * 60 + extraSec)) }
    }

    /// Seconds left on whichever clock is running — negative in overtime, nil in idle.
    func remainingSec(now: Date = Date()) -> Int? {
        switch phase {
        case .working, .overtime:
            guard let d = deadline else { return nil }
            return Int((d.timeIntervalSince(now)).rounded(.up))
        case .resting:
            guard let r = restEnd else { return nil }
            return max(0, Int(r.timeIntervalSince(now).rounded(.up)))
        case .idle:
            return nil
        }
    }

    /// Seconds of the current work stretch (0 unless working / overtime).
    func streakSec(now: Date = Date()) -> Int {
        guard phase == .working || phase == .overtime, let s = workStart else { return 0 }
        return max(0, Int(now.timeIntervalSince(s)))
    }

    /// Seconds SINCE this phase began — the count-up reading. Work counts from the
    /// round's start, rest from when you pressed 现在休息.
    func elapsedSec(now: Date = Date()) -> Int {
        switch phase {
        case .working, .overtime: return streakSec(now: now)
        case .resting: return restStart.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
        case .idle: return 0
        }
    }

    /// The figure the strip and the chip both display, honouring 正计时 / 倒计时.
    /// nil only in idle, where there is no clock to show.
    func displaySec(now: Date = Date()) -> Int? {
        guard phase != .idle else { return nil }
        return AppSettings.breakCountUp ? elapsedSec(now: now) : remainingSec(now: now)
    }

    /// How long since the rest began, shown on 休息好了？ — nil if no rest preceded it, or
    /// past two hours (a lid closed overnight is not a "rest of 720 minutes").
    var restedSec: Int? {
        guard phase == .idle, let s = restStart else { return nil }
        let sec = max(0, Int(Date().timeIntervalSince(s)))
        return sec < 2 * 3600 ? sec : nil
    }

    /// Everything worked today: closed stretches + the live one.
    var todayTotalSec: Int { todaySec + streakSec() }

    // MARK: transitions (user / AI)

    /// The AI showed new activity — a session entered 运行, or you clicked into one.
    /// Starts the clock from idle; a running clock just notes you're here.
    func noteActivity(now: Date = Date()) {
        lastPresent = now
        let open = phase == .idle || (phase == .resting && restAuto)
        if open, AppSettings.breakReminderEnabled { startWork(now: now) }
    }

    func startWork(now: Date = Date()) {
        if phase == .working || phase == .overtime { closeStretch(at: now) }
        phase = .working
        workStart = now
        extraSec = 0
        extended = false
        reminded = 0
        autoShowPending = false
        dismissed = false
        heldBanner = nil
        restStart = nil
        restAuto = false
        lastPresent = now
        everStarted = true
    }

    func startRest(now: Date = Date(), auto: Bool = false) {
        closeStretch(at: now)
        phase = .resting
        restStart = now
        restAuto = auto
        heldBanner = nil
        autoShowPending = false
    }

    /// A new work length picked from the strip's clock. The running round re-derives
    /// its deadline from the setting, so only the phase needs a nudge: lengthening past
    /// "now" puts an overtime round back to counting down (and re-arms the 0 pop).
    func setWorkMinutes(_ m: Int, now: Date = Date()) {
        AppSettings.breakReminderMinutes = m
        guard phase == .overtime, let left = remainingSec(now: now), left > 0 else { return }
        phase = .working
        reminded = 0
        dismissed = false
        autoShowPending = false
    }

    /// A new rest length while resting — the end moves with it; a length already
    /// behind "now" ends the rest on the next poll.
    func setRestMinutes(_ m: Int) {
        AppSettings.breakRestMinutes = m
    }

    /// "+10 分". Once per round; from overtime it puts the clock back above 0 and
    /// re-arms the auto-pop for when it runs out again.
    @discardableResult
    func extend(now: Date = Date()) -> Bool {
        guard phase == .working || phase == .overtime, !extended else { return false }
        extended = true
        extraSec = Self.extensionSec
        if phase == .overtime, let d = deadline, d > now { phase = .working }
        dismissed = false
        autoShowPending = false
        return true
    }

    /// Preview only (tools/break-preview): shove the deadline into the past.
    func rewind(by sec: Int) { workStart = workStart?.addingTimeInterval(-TimeInterval(sec)) }

    // MARK: the poll

    /// One poll (every refresh). `idle` = seconds since the last mouse/keyboard event,
    /// `running` = any session mid-turn (also the presence rule's "you're watching it
    /// work"), `busy` = anything that means this is a bad moment to be told to stand up:
    /// a run in flight OR a prompt waiting on you. Returns an event to announce.
    func poll(idle: TimeInterval, running: Bool, busy: Bool = false, now: Date = Date()) -> Event? {
        rollDay(now)
        // Polls stop while the Mac sleeps, and the keystroke that wakes it resets the
        // idle reading — a closed lid would otherwise read as "never left".
        let slept = now.timeIntervalSince(lastPoll) > gap && lastPoll != .distantPast
        lastPoll = now
        let present = idle < gap || (running && idle < waitGap)

        switch phase {
        case .working, .overtime:
            // ★ Walking away (or closing the lid) STARTS a rest, dated from the last
            // input; it does not skip to 休息好了？. Going straight to idle put 休息好了？
            // on screen five minutes into an over-time round you had not rested in at
            // all (2026-09-30). The rest then ends on the usual length, or — since it
            // was inferred — on the next AI activity.
            if slept { startRest(now: lastPresent, auto: true); return nil }
            guard present else { startRest(now: now.addingTimeInterval(-idle), auto: true); return nil }
            lastPresent = now
            guard let left = remainingSec(now: now) else { return nil }
            if left <= 0 {
                if phase == .working { phase = .overtime }
                // The banner fires at 0 and again each work-length after it.
                let period = max(60, AppSettings.breakReminderMinutes * 60)
                let multiple = 1 + (-left) / period
                if AppSettings.breakReminderEnabled, multiple > reminded {
                    reminded = multiple
                    if busy {
                        heldBanner = (streakSec(now: now), now)   // wait for the run to end
                    } else {
                        if !dismissed { autoShowPending = true }
                        return .overtime(streakSec(now: now))
                    }
                }
            }
            // A held banner rides until the machine goes quiet — that IS the moment to
            // stand up — or until the cap says it has waited long enough.
            if let held = heldBanner, !busy || now.timeIntervalSince(held.since) >= holdCap {
                heldBanner = nil
                if !dismissed { autoShowPending = true }
                return .overtime(streakSec(now: now))
            }
            return nil
        case .resting:
            if let r = restEnd, now >= r { phase = .idle; return .restEnded }
            return nil
        case .idle:
            // Lenient first start: the app came up with a turn already running — you
            // are clearly at work. Later restarts wait for NEW activity (noteActivity).
            if running, !everStarted, AppSettings.breakReminderEnabled { startWork(now: now) }
            return nil
        }
    }

    private func closeStretch(at: Date) {
        if let s = workStart { todaySec += max(0, Int(at.timeIntervalSince(s))) }
        workStart = nil
        extraSec = 0
        extended = false
        reminded = 0
        persist()
    }

    private func rollDay(_ now: Date) {
        let key = Self.dayKey(now)
        guard key != todayKey else { return }
        todayKey = key
        todaySec = 0
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(todayKey, forKey: todayKeyKey)
        UserDefaults.standard.set(todaySec, forKey: todaySecKey)
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// "1h05m" / "48m" — for totals.
    static func fmt(_ sec: Int) -> String {
        let m = sec / 60
        return m >= 60 ? String(format: "%dh%02dm", m / 60, m % 60) : "\(m)m"
    }

    /// "48:12" / "−03:12" / "1:05:12" — for the running clock. Uses U+2212 so the
    /// sign is as wide as a digit and the figure doesn't jitter at the crossing.
    static func clock(_ sec: Int) -> String {
        let a = abs(sec)
        let body = a >= 3600 ? String(format: "%d:%02d:%02d", a / 3600, a / 60 % 60, a % 60)
                             : String(format: "%02d:%02d", a / 60, a % 60)
        return sec < 0 ? "−" + body : body
    }
}

// MARK: - Shared palette for the chip and the panel

enum BreakLook {
    static var tomato: NSColor { Status.claudeOrange }
    static let tomatoDeep = NSColor(red: 0.72, green: 0.18, blue: 0.10, alpha: 1)
    static let leaf = NSColor(red: 0.25, green: 0.64, blue: 0.30, alpha: 1)
    /// The over-time chip figure. tomatoDeep alone is too dark to read on a dark shell.
    static let overInk = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.45, blue: 0.38, alpha: 1) : tomatoDeep
    }

    /// ★ The pale surfaces (work / rest / rested) are FIXED light colours in both
    /// appearances, so their text must be fixed dark too. `.labelColor` flips to white
    /// in dark mode and the caption vanishes into the green — which is exactly what
    /// happened before 2026-09-14. Only the red over-time surface uses white ink.
    static let inkOnLight = NSColor(white: 0.08, alpha: 1)
    static let subOnLight = NSColor(white: 0.42, alpha: 1)

    /// Slow glow — 1.6s per breath is well under the WCAG 2.3.1 three-flashes-a-second line.
    static func breathe(_ layer: CALayer, key: String, from: CGFloat, to: CGFloat, path: String) {
        let a = CABasicAnimation(keyPath: path)
        a.fromValue = from; a.toValue = to
        a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // The model value is what an offscreen snapshot (tools/break-preview) draws.
        layer.setValue(to, forKeyPath: path)
        layer.add(a, forKey: key)
    }
}

// MARK: - BreakChip
//
// The identity-row chip ("🍅 48:12") beside the count pill in both hosts. Clicking
// it toggles the panel under the metric grid. Hidden entirely while the feature is
// off; in idle it still shows the tomato so the panel stays reachable.
final class BreakChip: NSView {
    var onClick: (() -> Void)?
    /// The same chip pane the count pill beside it is built on (ChipShellView), so
    /// the two read as one size and one substance whatever the theme does to chips.
    private let shell = ChipShellView()
    private let tint = CALayer()
    private let label = NSTextField(labelWithString: "")
    private lazy var collapsed = widthAnchor.constraint(equalToConstant: 0)
    private var glowing = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(shell)
        tint.cornerRadius = Theme.chip
        tint.cornerCurve = .continuous
        layer?.addSublayer(tint)
        // Metrics copied from CountPill: 22 high, 8 in, 11pt bold rounded.
        label.font = Theme.rounded(11, .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        trailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            trailing,
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(tick),
                                               name: BreakReminder.tick, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func tick() { if window != nil { refresh() } }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = bounds
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// Re-read the clock. Called on every poll by the host that shows it.
    func refresh() {
        let show = AppSettings.breakReminderEnabled
        isHidden = !show
        collapsed.isActive = !show
        guard show else { return }
        let r = BreakReminder.shared
        let now = Date()
        let text: String
        let fill: NSColor, ink: NSColor
        var glow = false
        switch r.phase {
        case .idle:
            text = "🍅 --:--"
            fill = BreakLook.leaf.withAlphaComponent(0.14); ink = BreakLook.leaf
        case .working:
            text = "🍅 " + BreakReminder.clock(r.displaySec(now: now) ?? 0)
            fill = BreakLook.tomato.withAlphaComponent(0.14); ink = BreakLook.tomatoDeep
        case .overtime:
            text = "🍅 " + BreakReminder.clock(r.displaySec(now: now) ?? 0)
            // Red on a pale tomato wash, not white on solid red: in the title bar the
            // white figure read as unreadable (user report, 2026-09-30). Red ink reads
            // whatever the theme's chip shell under the tint looks like.
            fill = BreakLook.tomato.withAlphaComponent(0.22); ink = BreakLook.overInk; glow = true
        case .resting:
            text = "🐈 " + BreakReminder.clock(r.displaySec(now: now) ?? 0)
            fill = BreakLook.leaf.withAlphaComponent(0.16); ink = BreakLook.leaf
        }
        if label.stringValue != text { label.stringValue = text }
        label.textColor = ink
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.backgroundColor = fill.cg(in: self)
        CATransaction.commit()
        if glow != glowing {
            glowing = glow
            if glow {
                tint.shadowColor = BreakLook.tomato.cgColor
                tint.shadowOffset = .zero
                tint.shadowRadius = 8
                BreakLook.breathe(tint, key: "glow", from: 0.15, to: 0.95, path: "shadowOpacity")
            } else {
                tint.removeAnimation(forKey: "glow")
                tint.shadowOpacity = 0
            }
        }
        toolTip = L("今天共 \(BreakReminder.fmt(r.todayTotalSec)) · 点击展开",
                    "\(BreakReminder.fmt(r.todayTotalSec)) today · click to open")
    }
}

// MARK: - BreakPanel
//
// The strip under the metric grid: [tomato / cat] [big clock + one line] [buttons] ✕.
// Collapsed (zero height) by default; opens on a chip click or when the clock
// crosses 0 (once per round — closing it by hand keeps it closed). Lives inside
// HeaderStatsView so both hosts get it and the list below simply moves down.
final class BreakPanel: NSView {
    /// Height changed (expand / collapse) — the popover re-sizes, the window re-fits.
    var onLayoutChange: (() -> Void)?
    /// A button was pressed — the host refreshes its chip in the same pass.
    var onAction: (() -> Void)?

    private(set) var expanded = false
    private let content = NSView()
    private let surface = CAGradientLayer()
    private let tile = NSView()
    private let emoji = NSTextField(labelWithString: "🍅")
    private let photo = NSImageView()
    /// Clock + caption ride in one box so the PAIR centres on the strip. Centring them
    /// separately around the middle line put the big figure visibly high — a 24pt
    /// figure and a 10.5pt caption don't balance around a shared edge.
    private let textBlock = NSView()
    private let clock = ClockLabel(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private let primary = PillButton()
    private let secondary = PillButton()
    private let close = BreakCloseButton()
    /// 倒计时 ⇄ 正计时. Rides the corner beside the ✕ rather than the button row: the
    /// row is already two buttons wide in the work states and a third would squeeze
    /// the caption into an ellipsis.
    private let flip = BreakIconButton()
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    private lazy var secondaryWidth = secondary.widthAnchor.constraint(equalToConstant: 0)
    private var look: Look?
    private enum Look { case work, over, rest, done }
    private var photoName: String?

    static let openHeight: CGFloat = 70   // 8 gap + 62 strip

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // ★ NOT clipped. The glow is a shadow on `surface`, and a clipping parent cuts a
        // shadow into a hard-edged RECTANGLE (docs/design-system.md 「阴影预算」) — which
        // is exactly what a green box around the rounded strip looked like. Collapsing
        // needs no clip: `setExpanded` hides the view outright. Use the shared helper,
        // not a bare masksToBounds: since macOS 14 the VIEW clips on its own too, so
        // clearing only the layer's flag leaves the square edges in place.
        letShadowsEscape()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        surface.cornerRadius = Theme.card
        surface.cornerCurve = .continuous
        surface.startPoint = CGPoint(x: 0, y: 0.5); surface.endPoint = CGPoint(x: 1, y: 0.5)
        surface.borderWidth = 1
        content.layer?.addSublayer(surface)
        addSubview(content)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        tile.layer?.cornerCurve = .continuous
        tile.layer?.masksToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tile)
        emoji.font = NSFont.systemFont(ofSize: 26)
        emoji.alignment = .center
        emoji.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(emoji)
        photo.imageScaling = .scaleProportionallyUpOrDown
        photo.wantsLayer = true
        photo.layer?.contentsGravity = .resizeAspectFill
        photo.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(photo)

        clock.font = Theme.roundedMono(24, .bold)
        clock.translatesAutoresizingMaskIntoConstraints = false
        clock.setContentCompressionResistancePriority(.required, for: .horizontal)
        textBlock.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(textBlock)
        clock.onClick = { [weak self] in self?.showLengthMenu() }
        clock.toolTip = L("点击调整时长", "Click to change the length")
        textBlock.addSubview(clock)
        line.font = Theme.font(10.5, .medium)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.translatesAutoresizingMaskIntoConstraints = false
        textBlock.addSubview(line)

        primary.onPress = { [weak self] in self?.press(primary: true) }
        secondary.onPress = { [weak self] in self?.press(primary: false) }
        content.addSubview(primary)
        content.addSubview(secondary)

        close.onClose = { [weak self] in
            BreakReminder.shared.dismissed = true
            self?.setExpanded(false)
        }
        close.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(close)
        flip.onPress = { [weak self] in
            AppSettings.breakCountUp.toggle()
            self?.refresh()
            self?.onAction?()
        }
        flip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(flip)

        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.heightAnchor.constraint(equalToConstant: Self.openHeight - 8),

            tile.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tile.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 44),
            tile.heightAnchor.constraint(equalToConstant: 44),
            emoji.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            photo.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            photo.topAnchor.constraint(equalTo: tile.topAnchor),
            photo.bottomAnchor.constraint(equalTo: tile.bottomAnchor),

            textBlock.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            textBlock.trailingAnchor.constraint(equalTo: secondary.leadingAnchor, constant: -8),
            textBlock.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            clock.topAnchor.constraint(equalTo: textBlock.topAnchor),
            clock.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            clock.trailingAnchor.constraint(lessThanOrEqualTo: textBlock.trailingAnchor),
            line.topAnchor.constraint(equalTo: clock.bottomAnchor, constant: 1),
            line.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: textBlock.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: textBlock.bottomAnchor),

            primary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            primary.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -6),
            secondary.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            // Inside the strip's corner, not hanging off it: the panel clips to its
            // bounds (and the popover to its own), so an overhanging ✕ shows up halved.
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -5),
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: 5),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),

            flip.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -5),
            flip.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            flip.widthAnchor.constraint(equalToConstant: 16),
            flip.heightAnchor.constraint(equalToConstant: 16),
        ])
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(tick),
                                               name: BreakReminder.tick, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func tick() { if expanded, window != nil { refresh() } }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.frame = content.bounds
        // The halo traces the strip's own rounded rect. Derived from the layer's alpha
        // instead, it re-softens into a square whenever anything upstream clips.
        surface.shadowPath = CGPath(roundedRect: content.bounds, cornerWidth: Theme.card,
                                    cornerHeight: Theme.card, transform: nil)
        CATransaction.commit()
    }

    /// Opened by hand while the countdown runs — stays until the next chip click / ✕.
    private var peeking = false

    func toggle() {
        peeking = !expanded && BreakReminder.shared.phase == .working
        setExpanded(!expanded)
    }

    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        isHidden = !on
        height.constant = on ? Self.openHeight : 0
        if !on { peeking = false }
        if on { BreakReminder.shared.autoShowPending = false; refresh() }
        onLayoutChange?()
    }

    /// The clock's menu: work lengths, or rest lengths while resting, current ticked.
    private func showLengthMenu() {
        let r = BreakReminder.shared
        let resting = r.phase == .resting
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: resting ? L("休息时长", "Rest length") : L("番茄时长", "Work length"),
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let choices = resting ? AppSettings.breakRestChoices : AppSettings.breakReminderChoices
        let current = resting ? AppSettings.breakRestMinutes : AppSettings.breakReminderMinutes
        for m in choices {
            let item = NSMenuItem(title: L("\(m) 分钟", "\(m) min"), action: #selector(pickLength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m
            item.state = m == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: clock.bounds.height + 4), in: clock)
    }

    @objc private func pickLength(_ item: NSMenuItem) {
        let r = BreakReminder.shared
        if r.phase == .resting { r.setRestMinutes(item.tag) } else { r.setWorkMinutes(item.tag) }
        refresh()
        onAction?()
    }

    /// The primary button keeps its spot while its meaning flips (现在休息 → 结束休息 → 现在休息,
    /// 开始倒计时 → 现在休息), so a double-click or an impatient second click ran both:
    /// the rest ended the instant it began and the strip jumped to 休息好了？(2026-09-18).
    private var lastPress = Date.distantPast
    private let pressGuard: TimeInterval = 1.5

    private func press(primary isPrimary: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastPress) >= pressGuard else { return }
        lastPress = now
        let r = BreakReminder.shared
        switch (r.phase, isPrimary) {
        case (.working, true), (.overtime, true): r.startRest()
        case (.working, false), (.overtime, false): r.extend()
        // Ending a rest early means you're back: go straight to the countdown
        // rather than parking on 休息好了？ for a second click (2026-09-24).
        case (.resting, true), (.idle, true): r.startWork()
        default: break
        }
        refresh()
        onAction?()
    }

    /// Re-read the clock; also pops open when the clock just crossed 0 this round and
    /// folds away when a countdown starts — the strip is for the alarm and the rest,
    /// not for watching the number go down (the chip does that).
    func refresh() {
        let r = BreakReminder.shared
        if r.autoShowPending, !r.dismissed, !expanded { setExpanded(true); return }
        if r.phase == .working, expanded, !peeking { setExpanded(false); return }
        guard expanded || look == nil else { return }
        let now = Date()
        let total = BreakReminder.fmt(r.todayTotalSec)
        let newLook: Look
        switch r.phase {
        case .working:
            newLook = .work
            clock.stringValue = BreakReminder.clock(r.displaySec(now: now) ?? 0)
            line.stringValue = AppSettings.breakCountUp
                ? L("已经工作 · 今天 \(total)", "At it for · \(total) today")
                : L("离休息还有 · 今天 \(total)", "Until break · \(total) today")
            primary.set(L("现在休息", "Rest now"))
            secondary.set(r.extended ? L("已延过", "Extended") : L("+10 分", "+10 min"), enabled: !r.extended)
        case .overtime:
            newLook = .over
            clock.stringValue = BreakReminder.clock(r.displaySec(now: now) ?? 0)
            line.stringValue = AppSettings.breakCountUp
                ? L("已经超时 · 该起来了", "Over time · get up")
                : L("超了 · 已连续 \(BreakReminder.fmt(r.streakSec(now: now)))",
                    "Over · \(BreakReminder.fmt(r.streakSec(now: now))) at it")
            primary.set(L("现在休息", "Rest now"))
            secondary.set(r.extended ? L("已延过", "Extended") : L("+10 分", "+10 min"), enabled: !r.extended)
        case .resting:
            newLook = .rest
            clock.stringValue = BreakReminder.clock(r.displaySec(now: now) ?? 0)
            line.stringValue = L("休息中 · 看看远处", "Resting · look far away")
            primary.set(L("结束休息", "End break"))
            secondary.set("", enabled: false)
        case .idle:
            newLook = .done
            clock.stringValue = L("休息好了？", "Rested?")
            if let rested = r.restedSec {
                line.stringValue = L("已休息 \(rested / 60) 分钟 · 用 AI 也会自动开始",
                                     "Rested \(rested / 60) min · AI use restarts it")
            } else {
                line.stringValue = L("今天共 \(total) · 用 AI 也会自动开始", "\(total) today · AI use restarts it")
            }
            primary.set(L("开始倒计时", "Start"))
            secondary.set("", enabled: false)
        }
        let up = AppSettings.breakCountUp
        flip.set(symbol: up ? "stopwatch" : "timer")
        flip.toolTip = up ? L("正计时 · 点击改回倒计时", "Counting up · click for countdown")
                          : L("倒计时 · 点击改成正计时", "Counting down · click to count up")
        secondary.isHidden = secondary.title.isEmpty
        secondaryWidth.isActive = secondary.title.isEmpty
        if newLook != look { apply(newLook) }
    }

    /// ★ The colour rule, and it is the whole scheme: **the surface is the state you
    /// are IN, the primary button is the state it takes you TO.** Working is red and its
    /// button (现在休息) is green; resting is green and its button (回去工作) is red.
    /// "休息好了？" still belongs to the rest family, so it stays green with a red start
    /// button. Never paint a button the same colour as the surface it sits on — that is
    /// what made it read as decoration rather than a way out.
    private func apply(_ l: Look) {
        look = l
        let white = NSColor.white
        switch l {
        case .work:
            gradient([NSColor(red: 1, green: 0.95, blue: 0.93, alpha: 1), NSColor(red: 1, green: 0.91, blue: 0.89, alpha: 1)],
                     border: BreakLook.tomato.withAlphaComponent(0.2))
            clock.textColor = BreakLook.inkOnLight; line.textColor = BreakLook.subOnLight
            primary.style(fill: BreakLook.leaf, ink: white)
            secondary.style(fill: BreakLook.tomato.withAlphaComponent(0.14), ink: BreakLook.tomatoDeep)
            flip.tint(BreakLook.subOnLight)
            showPhoto(nil)
            glow(nil)
        case .over:
            gradient([BreakLook.tomatoDeep, BreakLook.tomato], border: .clear)
            clock.textColor = white; line.textColor = white.withAlphaComponent(0.85)
            primary.style(fill: BreakLook.leaf, ink: white)
            secondary.style(fill: white.withAlphaComponent(0.22), ink: white)
            flip.tint(white)
            showPhoto(nil)
            glow(BreakLook.tomato)
        case .rest:
            gradient([NSColor(red: 0.93, green: 0.97, blue: 0.93, alpha: 1), NSColor(red: 0.89, green: 0.95, blue: 0.89, alpha: 1)],
                     border: BreakLook.leaf.withAlphaComponent(0.25))
            clock.textColor = BreakLook.inkOnLight; line.textColor = BreakLook.subOnLight
            primary.style(fill: BreakLook.tomatoDeep, ink: white)
            flip.tint(BreakLook.subOnLight)
            showPhoto("cat-stretch")
            glow(BreakLook.leaf)
        case .done:
            gradient([NSColor(red: 0.93, green: 0.97, blue: 0.93, alpha: 1), NSColor(red: 0.89, green: 0.95, blue: 0.89, alpha: 1)],
                     border: BreakLook.leaf.withAlphaComponent(0.25))
            clock.textColor = BreakLook.inkOnLight; line.textColor = BreakLook.subOnLight
            primary.style(fill: BreakLook.tomatoDeep, ink: white)
            flip.tint(BreakLook.subOnLight)
            showPhoto("cat-glasses")
            glow(nil)
        }
    }

    private func gradient(_ colors: [NSColor], border: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.colors = colors.map { $0.cg(in: self) }
        surface.borderColor = border.cg(in: self)
        CATransaction.commit()
    }

    /// The tile shows the tomato, or a bundled photo (tools/cat-*.jpg → Resources)
    /// with a slow breathing scale — the "animation" a still photo can afford.
    private func showPhoto(_ name: String?) {
        guard name != photoName else { return }
        photoName = name
        photo.layer?.removeAnimation(forKey: "breathe")
        if let name, let url = Bundle.main.resourceURL?.appendingPathComponent("\(name).jpg"),
           let img = NSImage(contentsOf: url) {
            photo.image = img
            photo.isHidden = false
            emoji.isHidden = true
            tile.layer?.backgroundColor = nil
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1.0; a.toValue = 1.06
            a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            photo.layer?.add(a, forKey: "breathe")
        } else {
            photo.image = nil
            photo.isHidden = true
            emoji.isHidden = false
            tile.layer?.backgroundColor = NSColor.white.withAlphaComponent(look == .over ? 0.18 : 0.7).cgColor
        }
    }

    /// The breathing halo behind the strip: tomato while you're over time, leaf green
    /// while you're resting (a calm one — half the opacity of the alarm), nil = none.
    private func glow(_ color: NSColor?) {
        guard let color else {
            surface.removeAnimation(forKey: "glow")
            surface.shadowOpacity = 0
            return
        }
        let calm = color === BreakLook.leaf
        surface.shadowColor = color.cgColor
        surface.shadowOffset = .zero
        // Inside the project's shadow budget (|offset| + 2×blur ≤ 18, design-system.md):
        // the strip sits 18pt from the window edge and 8pt from its neighbours, and a
        // blur that outgrows that budget is what gets sliced into straight edges.
        surface.shadowRadius = calm ? 8 : 9
        BreakLook.breathe(surface, key: "glow", from: calm ? 0.12 : 0.2,
                          to: calm ? 0.55 : 0.95, path: "shadowOpacity")
    }
}

/// A small pill button: filled capsule + label, press = closure. Kept to the panel
/// so it doesn't grow into a third button family beside the tab bar's.
final class PillButton: NSView {
    var onPress: (() -> Void)?
    private(set) var title = ""
    private let bg = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var enabled = true

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        bg.cornerRadius = 7
        bg.cornerCurve = .continuous
        layer?.addSublayer(bg)
        label.font = Theme.rounded(10.5, .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        CATransaction.commit()
    }

    func set(_ title: String, enabled: Bool = true) {
        self.title = title
        self.enabled = enabled
        label.stringValue = title
        alphaValue = enabled ? 1 : 0.45
    }

    func style(fill: NSColor, ink: NSColor) {
        label.textColor = ink
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.backgroundColor = fill.cg(in: self)
        CATransaction.commit()
    }

    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
}

/// The strip's ✕: a small dark disc with a bold xmark, always visible.
final class BreakCloseButton: NSView {
    var onClose: (() -> Void)?
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.55).cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        let iv = NSImageView(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(cfg) ?? NSImage())
        iv.contentTintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClose?() }
}

/// The strip's big clock: a label that answers a click (the length menu) and shows
/// the pointing hand so it reads as something to press.
final class ClockLabel: NSTextField {
    var onClick: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A 16pt symbol button for the strip's corner — the 倒计时 ⇄ 正计时 flip. Borderless
/// on purpose: the corner already carries the ✕, and two filled discs up there would
/// read as a toolbar the strip does not have.
final class BreakIconButton: NSView {
    var onPress: (() -> Void)?
    private let icon = NSImageView()
    private var symbol = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(symbol name: String) {
        guard name != symbol else { return }
        symbol = name
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    func tint(_ color: NSColor) { icon.contentTintColor = color }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onPress?() }
}
