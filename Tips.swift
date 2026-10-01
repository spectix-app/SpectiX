import Cocoa

// MARK: - Contextual feature tips
//
// Teaches the handful of affordances that have no visual hint (click a row to jump,
// drag a header to reorder, right-click a header, tap the 🤖 badge) — each exactly
// once, and only at the moment it first becomes relevant. Two halves:
//
//   TipCenter — decides WHICH tip, WHEN, and remembers what's been seen
//   TipBar    — renders it as an inline bar between the list and the HiddenBar
//
// The two are deliberately decoupled: swapping the renderer (say, to a toast) means
// replacing TipBar alone, none of the trigger logic below.
//
// The bar lives OUTSIDE the table on purpose. The list rebuilds itself every second
// (the ⏱ seconds tick is part of its render key), which strips and re-adds any layer
// animation on a cell — see docs/design-system.md "循环动效的两条铁律". Nothing here
// loops, but sitting outside the table also means the bar's show/hide animation is
// never interrupted mid-flight by an unrelated reload.

struct TipSpec {
    let id: String
    let symbol: String
    let text: String
}

// Ordered by priority: the first one whose condition holds is the one shown, the rest
// wait for a later evaluation. Jump leads because it's the whole point of the app and
// has zero visual affordance — a user who never discovers it treats this as a dashboard.
enum Tips {
    static func all() -> [TipSpec] {
        [
            TipSpec(id: "jump", symbol: "arrow.up.forward.app",
                    text: L("点任一行即可跳到那个终端", "Click a row to jump to that terminal")),
            TipSpec(id: "reorder", symbol: "arrow.up.arrow.down",
                    text: L("拖动项目标题可调整顺序", "Drag a project header to reorder")),
            TipSpec(id: "headerMenu", symbol: "contextualmenu.and.cursorarrow",
                    text: L("右键项目标题可置顶或隐藏", "Right-click a header to pin or hide")),
            TipSpec(id: "agents", symbol: "chevron.down.circle",
                    text: L("点 🤖 徽章可展开后台 agent", "Tap the 🤖 badge to see background agents")),
        ]
    }

    // Every id that has a `tipSeen-*` flag. Adding a tip above means adding it here too,
    // otherwise "turn tips back on" won't clear it.
    static var ids: [String] { all().map(\.id) }
}

// What the host knows and the trigger conditions need. Assembled per reload so the
// center itself never reaches into the model or the settings for state.
struct TipContext {
    let sessionCount: Int
    let groupCount: Int        // project headers on screen (live projects + header-only ones)
    let hasCustomOrder: Bool   // the user has dragged something at least once, ever
    let hasAgents: Bool
}

final class TipCenter {

    // All the pacing in one place — see docs/row-display.md's sibling note in
    // task/AutoRunLog for why these values. Turning the volume down = editing these
    // four numbers, nothing else.
    private enum Timing {
        static let perLaunchLimit = 2              // inline tips per app launch
        static let gap: TimeInterval = 90          // attention-time between two tips
        static let warmup: TimeInterval = 3        // settle after the list first has content
        static let display: TimeInterval = 12      // how long one tip stays up
    }

    private let bar: TipBar
    // Host gate: true only while the user can actually see the sessions list (window
    // shown, key, on the sessions tab, no undo prompt fighting for the same strip).
    // Everything below counts ATTENTION time, not wall time, so a tip can't burn its
    // 12 seconds while the window sits behind Xcode.
    var isActive: (() -> Bool)?

    private var shownThisLaunch = 0
    private var attention: TimeInterval = 0      // accumulated seconds the gate was open
    private var attentionAtLastTip: TimeInterval? = nil
    private var lastTick: Date?
    private var current: TipSpec?
    private var remaining: TimeInterval = 0
    private var countdown: Timer?

    init(bar: TipBar) {
        self.bar = bar
        bar.onDismiss = { [weak self] in
            guard let self, let tip = self.current else { return }
            AppSettings.markTipSeen(tip.id)
            self.hide()
        }
    }

    // Called once per list reload (~2.5s). Cheap: usually one bool check.
    func evaluate(_ ctx: TipContext) {
        let active = isActive?() ?? false

        // Accumulate attention time. The clamp bridges the gap across a period where the
        // window was hidden or the app was asleep — otherwise one 4-hour background stretch
        // would satisfy every cooldown at once the moment the window comes back.
        let now = Date()
        if active, let last = lastTick { attention += min(now.timeIntervalSince(last), 5) }
        lastTick = now

        guard AppSettings.featureTipsEnabled else {
            if current != nil { hide() }
            return
        }
        guard current == nil, active else { return }
        guard shownThisLaunch < Timing.perLaunchLimit else { return }
        guard attention >= Timing.warmup else { return }
        if let t = attentionAtLastTip, attention - t < Timing.gap { return }

        guard let tip = Tips.all().first(where: { fires($0.id, ctx) }) else { return }
        show(tip)
    }

    // A tip fires when it hasn't been seen AND the thing it teaches is on screen right
    // now. `reorder` additionally checks the user hasn't already figured it out: a saved
    // custom order is proof, and it survives reinstalls — so an existing user upgrading
    // never gets taught a feature they've been using for months.
    private func fires(_ id: String, _ ctx: TipContext) -> Bool {
        guard !AppSettings.tipSeen(id) else { return false }
        switch id {
        case "jump":       return ctx.sessionCount >= 1
        case "reorder":    return AppSettings.sortMode == .custom && ctx.groupCount >= 2 && !ctx.hasCustomOrder
        case "headerMenu": return AppSettings.sortMode == .custom && ctx.groupCount >= 3
        case "agents":     return ctx.hasAgents
        default:           return false
        }
    }

    private func show(_ tip: TipSpec) {
        current = tip
        shownThisLaunch += 1
        attentionAtLastTip = attention
        remaining = Timing.display
        bar.show(tip)
        // 0.5s ticks, but only spending the budget while the gate is open — ⌘Tab away
        // mid-tip and it's still there when you come back.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isActive?() ?? false else { return }
            self.remaining -= 0.5
            if self.remaining <= 0 {
                AppSettings.markTipSeen(tip.id)
                self.hide()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countdown = t
    }

    // The user did the thing the tip teaches. Mark it learned whether or not the tip was
    // ever shown — someone who clicks a row in the first ten seconds should never be told
    // that rows are clickable — and take the bar down if it's the one on screen.
    func markLearned(_ id: String) {
        guard !AppSettings.tipSeen(id) else { return }
        AppSettings.markTipSeen(id)
        if current?.id == id { hide() }
    }

    private func hide() {
        countdown?.invalidate(); countdown = nil
        current = nil
        bar.dismiss()
    }
}

// MARK: - The bar
//
// Same chrome as HiddenBar (30pt, card fill + hairline, 8pt radius, 11.5pt label, blue
// text button) so the two read as one family when they're stacked. One deliberate
// difference: this bar's ICON is blue where HiddenBar's is grey — grey states a fact,
// blue points at something you can do.
final class TipBar: NSView {
    var onDismiss: (() -> Void)?
    // The host re-fits the window after the height animation settles (adjustWindowHeight
    // reads a live frame, so it must not run mid-animation).
    var onHeightChange: (() -> Void)?

    // The visible pill is 30pt like HiddenBar; the extra 4 is the gap to the bar below,
    // carried INSIDE this view's height. That way the collapsed state is a true zero —
    // the list sits exactly where it did before this bar existed, no stray 4pt seam.
    private static let pillHeight: CGFloat = 30
    static let barHeight: CGFloat = 34

    private let pill = CALayer()
    private let content = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var heightC: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        pill.cornerRadius = 8
        pill.cornerCurve = .continuous
        pill.borderWidth = 1
        layer?.addSublayer(pill)

        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true   // so the fade is a layer opacity animation, not a redraw per frame
        content.alphaValue = 0
        addSubview(content)

        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)

        label.font = Theme.font(11.5, .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        button.isBordered = false
        button.target = self
        button.action = #selector(dismissTapped)
        button.attributedTitle = NSAttributedString(
            string: L("知道了", "Got it"),
            attributes: [.foregroundColor: Status.accent("working"),
                         .font: Theme.font(11.5, .semibold)])
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)

        heightC = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightC,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.heightAnchor.constraint(equalToConstant: Self.pillHeight),

            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        isHidden = true
        applyChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        pill.frame = content.frame   // top 30pt; the 4pt below is the gap to HiddenBar
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }
    private func applyChrome() {
        pill.backgroundColor = Theme.cardFill.cg(in: self)
        pill.borderColor = Theme.hairline.cg(in: self)
        icon.contentTintColor = Status.accent("working")
    }

    func show(_ tip: TipSpec) {
        applyChrome()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.image = (NSImage(systemSymbolName: tip.symbol, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil))?
            .withSymbolConfiguration(cfg)
        label.stringValue = tip.text
        isHidden = false

        // Grow from the bottom edge, then fade the text in just behind it. No extra
        // slide: the bar is already moving, a second offset reads as two things.
        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            heightC.animator().constant = Self.barHeight
        }, completionHandler: { [weak self] in self?.onHeightChange?() })
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            content.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        // Fade the text first so it's never squashed by the closing height.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            content.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.heightC.animator().constant = 0
            }, completionHandler: {
                self.isHidden = true
                self.onHeightChange?()
            })
        })
    }

    @objc private func dismissTapped() { onDismiss?() }

    override func resetCursorRects() { addCursorRect(button.frame, cursor: .pointingHand) }
}
