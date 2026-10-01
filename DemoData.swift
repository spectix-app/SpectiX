import Cocoa

// MARK: - Demo mode (DEV-ONLY)
//
// A self-contained fake world: sessions, subscription quota, machine load and both
// append-only logs behind the 统计 tab. Switched on from Settings (dev builds only,
// see AppSettings.demoMode) so the whole UI can be recorded or screenshotted on a
// machine with nothing running — no waiting for a session to reach 需确认, no
// blurring out real project names.
//
// ★ Two rules this file exists to keep, and that any new demo surface must keep too:
//
// 1. **It never writes into the user's data.** The two fake logs are generated into
//    a scratch dir under NSTemporaryDirectory(); the read paths are redirected
//    (StatsStore.logPath / ImpactLog.readPath) while the write paths are not, so a
//    demo session can't append a single line to the real events.jsonl.
// 2. **It never touches the outside world.** The demo render path in AppController
//    deliberately skips ring drawing, toasts, auto-jump and ProjectHistory, and
//    focus() returns early — a fake row has no pane behind it, so pointing at one
//    would land the highlight on whatever unrelated window happens to be there.
//
// Everything animates off one clock (`elapsed`). Nothing is stored per row, so the
// world is reproducible: same second since switch-on → same frame.
enum Demo {

    static var enabled: Bool { AppSettings.demoMode }

    // MARK: Clock

    private static var t0 = Date().timeIntervalSince1970
    private static var elapsed: Double { Date().timeIntervalSince1970 - t0 }

    /// Park the demo clock at a chosen point in the cycle — tools/row-preview pins it
    /// so its one-shot render lands on the beats it wants to photograph.
    static func pin(elapsed e: Double) { t0 = Date().timeIntervalSince1970 - e }

    /// Rewind to the first beat and re-generate the logs under a fresh filename.
    /// Called when the toggle flips, so switching demo mode off and on again gives a
    /// clean run instead of resuming mid-cycle with stale figures.
    static func restart() {
        t0 = Date().timeIntervalSince1970
        logGeneration += 1
        logsWritten = false
        current = [:]
        books = defaultBooks
    }

    // MARK: - Sessions

    /// One fake session's whole life, as a loop. `beats` is the status cycle; `phase`
    /// slides this row's start point into the cycle so the four rows aren't in
    /// lockstep (all-green-then-all-blue reads as a screensaver, not as work).
    private struct Beat { let status: String; let secs: Double }
    private struct Sub { let type: String; let desc: String; let step: String }

    private struct Script {
        let cwd: String
        let tty: String
        let seq: Int
        let task: String
        let model: String
        let editor: EditorApp?
        let terminal: TerminalApp?
        let isChatPanel: Bool
        let isDesktop: Bool
        let desktopWid: CGWindowID
        let shellPid: pid_t
        let baseWorkSec: Int      // where this session's clock already stood at t0
        let baseTokens: Int
        let ctxLimit: Int
        let ctxGrow: Int          // context added over one full cycle, then /clear-style reset
        let tokensPerSec: Double  // spend rate while 运行中
        let phase: Double
        let beats: [Beat]
        let steps: [String]
        let agents: [Sub]

        var cycle: Double { beats.reduce(0) { $0 + $1.secs } }
        var workPerCycle: Double {
            beats.reduce(0) { $0 + ($1.status == "working" ? $1.secs : 0) }
        }
    }

    private static let scripts: [Script] = buildScripts()

    private static func buildScripts() -> [Script] {
        let home = NSHomeDirectory()
        var out: [Script] = []

        // Two sessions in one VSCode window — the case the whole grouping layout exists
        // for. Kept on different cycle lengths so the folder is rarely all-one-color.
        out.append(Script(cwd: "\(home)/Developer/aurora-web", tty: "ttys004", seq: 1,
                          task: "Wire the checkout flow to the new payments API",
                          model: "Opus 5", editor: .vscode, terminal: nil,
                          isChatPanel: false, isDesktop: false, desktopWid: 0, shellPid: 41207,
                          baseWorkSec: 2_640, baseTokens: 812_000, ctxLimit: 200_000, ctxGrow: 128_000,
                          tokensPerSec: 190, phase: 0,
                          beats: [Beat(status: "working", secs: 48), Beat(status: "done", secs: 22), Beat(status: "idle", secs: 14)],
                          steps: ["Edit · CheckoutSheet.tsx", "Bash · yarn test payments",
                                  "Read · api/payments/intent.ts", "Grep · createPaymentIntent",
                                  "Edit · usePaymentIntent.ts", "Bash · yarn typecheck"],
                          agents: []))

        out.append(Script(cwd: "\(home)/Developer/aurora-web", tty: "ttys006", seq: 2,
                          task: "Fix the flaky auth test on CI",
                          model: "Sonnet 5", editor: .vscode, terminal: nil,
                          isChatPanel: false, isDesktop: false, desktopWid: 0, shellPid: 41310,
                          baseWorkSec: 1_155, baseTokens: 341_000, ctxLimit: 200_000, ctxGrow: 74_000,
                          tokensPerSec: 120, phase: 37,
                          beats: [Beat(status: "working", secs: 34), Beat(status: "needs", secs: 30), Beat(status: "working", secs: 26), Beat(status: "done", secs: 18)],
                          steps: ["Bash · yarn vitest auth", "Read · tests/auth.spec.ts",
                                  "Edit · tests/auth.spec.ts", "Bash · git diff"],
                          agents: []))

        // Cursor, with background subagents — drives the 🤖 badge and its sublist.
        out.append(Script(cwd: "\(home)/Developer/pico-engine", tty: "ttys011", seq: 1,
                          task: "Port the particle system to Metal",
                          model: "Opus 5", editor: .cursor, terminal: nil,
                          isChatPanel: false, isDesktop: false, desktopWid: 0, shellPid: 39822,
                          baseWorkSec: 5_980, baseTokens: 1_940_000, ctxLimit: 1_000_000, ctxGrow: 410_000,
                          tokensPerSec: 260, phase: 12,
                          beats: [Beat(status: "working", secs: 76), Beat(status: "await", secs: 20),
                                  Beat(status: "done", secs: 24), Beat(status: "idle", secs: 20)],
                          steps: ["Edit · ParticleKernel.metal", "Bash · swift build -c release",
                                  "Read · Renderer/EmitterPool.swift", "Agent ×2",
                                  "Edit · Renderer/EmitterPool.swift"],
                          agents: [Sub(type: "Explore", desc: "Map every call site of EmitterPool",
                                  step: "Grep · EmitterPool"),
                                   Sub(type: "general-purpose", desc: "Benchmark the CPU fallback path",
                                  step: "Bash · swift test --filter Bench")]))

        // Terminal.app, on Haiku — the native-emulator badge plus a third model.
        out.append(Script(cwd: "\(home)/Developer/notes-api", tty: "ttys015", seq: 1,
                          task: "Migrate the user table to UUID keys",
                          model: "Haiku 4.5", editor: nil, terminal: .terminal,
                          isChatPanel: false, isDesktop: false, desktopWid: 0, shellPid: 38104,
                          baseWorkSec: 780, baseTokens: 96_000, ctxLimit: 200_000, ctxGrow: 51_000,
                          tokensPerSec: 70, phase: 61,
                          beats: [Beat(status: "idle", secs: 26), Beat(status: "working", secs: 40), Beat(status: "done", secs: 30)],
                          steps: ["Bash · psql -f migrate.sql", "Read · db/schema.sql",
                                  "Edit · db/migrations/0007_uuid.sql"],
                          agents: []))

        // A chat panel inside VSCode: no tty, no shell — the hook keys it by pid.
        out.append(Script(cwd: "\(home)/Developer/spectix-site", tty: "pid48210", seq: 1,
                          task: "Rewrite the pricing page copy",
                          model: "Sonnet 5", editor: .vscode, terminal: nil,
                          isChatPanel: true, isDesktop: false, desktopWid: 0, shellPid: 48210,
                          baseWorkSec: 410, baseTokens: 58_000, ctxLimit: 200_000, ctxGrow: 33_000,
                          tokensPerSec: 95, phase: 88,
                          beats: [Beat(status: "working", secs: 30), Beat(status: "done", secs: 34), Beat(status: "idle", secs: 44)],
                          steps: ["Edit · web/pricing.html", "Read · web/index.html"],
                          agents: []))

        // The Claude desktop app row — discovered by AX, not by a hook, and the only
        // row whose identity is a window number.
        out.append(Script(cwd: "Claude App", tty: "", seq: 1,
                          task: "Draft the launch announcement",
                          model: "Opus 5", editor: nil, terminal: nil,
                          isChatPanel: false, isDesktop: true, desktopWid: 7311, shellPid: 0,
                          baseWorkSec: 0, baseTokens: 0, ctxLimit: 0, ctxGrow: 0,
                          tokensPerSec: 0, phase: 23,
                          beats: [Beat(status: "working", secs: 42), Beat(status: "done", secs: 26), Beat(status: "idle", secs: 32)],
                          steps: [], agents: []))
        return out
    }

    /// The current frame of the fake world, in the same shape `fetchRows()` returns.
    static func rows() -> [SessionRow] {
        let now = Date().timeIntervalSince1970
        let e = elapsed
        return scripts.map { s in
            let cycle = s.cycle
            let p = (e + s.phase).truncatingRemainder(dividingBy: cycle)
            let cycles = ((e + s.phase) / cycle).rounded(.down)

            // Walk the beats to find which one `p` lands in, and how much 运行中 time
            // this cycle has banked so far.
            var status = s.beats[0].status
            var acc = 0.0
            var workThisCycle = 0.0
            for b in s.beats {
                if p < acc + b.secs {
                    status = b.status
                    if b.status == "working" { workThisCycle += p - acc }
                    break
                }
                if b.status == "working" { workThisCycle += b.secs }
                acc += b.secs
            }

            let folder = (s.cwd as NSString).lastPathComponent
            var r = SessionRow(title: folder, folder: folder, cwd: s.cwd,
                               shellPid: s.shellPid, tty: s.tty, status: status,
                               taskTitle: s.task, seq: s.seq)

            // The clock counts only 运行中 seconds and keeps running across cycles —
            // one long-lived session working through several turns, which is what a
            // real row shows.
            let workSec = Double(s.baseWorkSec) + cycles * s.workPerCycle + workThisCycle
            r.workSec = Int(workSec)
            r.tokens = s.baseTokens + Int((workSec - Double(s.baseWorkSec)) * s.tokensPerSec)
            r.tokensExact = true
            r.model = s.model
            // Context fills over the cycle and resets with it — a turn boundary reads
            // like the /clear it stands in for.
            if s.ctxLimit > 0 {
                r.ctxLimit = s.ctxLimit
                r.ctxTokens = Int(Double(s.ctxGrow) * (p / cycle)) + s.ctxGrow / 6
            }
            if status == "await" {
                // The beat stands in for one backgrounded command that started with it.
                r.bgShells = 1
                r.bgShellsSince = now - (p - acc)
            }
            if status == "working", !s.steps.isEmpty {
                r.step = s.steps[Int(e / 4) % s.steps.count]
                if !s.agents.isEmpty {
                    r.bgAgents = s.agents.count
                    r.agents = s.agents.enumerated().map { i, a in
                        var ag = AgentInfo(id: "demo-\(s.tty)-\(i)", type: a.type,
                                           desc: a.desc, start: now - 40 - Double(i) * 25)
                        ag.step = a.step
                        ag.ctxLimit = s.ctxLimit
                        ag.ctxTokens = 24_000 + i * 17_000
                        return ag
                    }
                }
            }
            r.isChatPanel = s.isChatPanel
            r.isDesktop = s.isDesktop
            r.desktopWid = s.desktopWid
            r.terminalApp = s.terminal
            r.editor = s.editor
            return r
        }
        // Same fixed ordering the real list uses: position never moves on a status change.
        .sorted { $0.cwd != $1.cwd ? $0.cwd < $1.cwd : $0.seq < $1.seq }
    }

    // MARK: - Recent projects
    //
    // The 最近项目 tab reads its own store (ProjectHistory), not the session rows, so
    // without this it would keep listing the user's REAL folders next to the fake
    // sessions — the one screen that leaks exactly what demo mode exists to hide.
    static func projects() -> [ProjectHistory.Entry] {
        let now = Date().timeIntervalSince1970
        let recent: [(String, Double, Bool)] = [
            ("aurora-web",    -60,        true),
            ("pico-engine",   -420,       true),
            ("notes-api",     -3_600,     false),
            ("spectix-site",  -5_400,     false),
            ("ledger-cli",    -86_400,    false),
            ("thumbnail-svc", -3 * 86_400, false),
            ("bloom-filter",  -9 * 86_400, false),
            // lastSeen 0 is the store's marker for "imported, never actually observed",
            // which the row renders without a timestamp — worth showing, since a real
            // list is mostly made of these.
            ("archive/old-crawler", 0,    false),
            ("archive/rss-reader",  0,    false),
        ]
        return recent.map { name, age, pinned in
            ProjectHistory.Entry(path: "\(NSHomeDirectory())/Developer/\(name)",
                                 lastSeen: age == 0 ? 0 : now + age,
                                 pinned: pinned)
        }
    }

    // MARK: - Subscription quota

    // The 5-hour window is replayed on a fast clock (`demoWindow`) so the bar visibly
    // fills during a two-minute recording. The countdown is DERIVED from the same
    // percentage rather than measured independently, so what the header shows stays
    // self-consistent — 42% used always reads as ~2h55m left of five hours.
    private static let demoWindow: Double = 600     // one fake session window, in real seconds
    private static let realWindow: Double = 5 * 3600
    private static var weekResetsAt: Double { t0 + 3 * 86400 + 4 * 3600 + 900 }

    static func usage() -> UsageSnapshot {
        let now = Date().timeIntervalSince1970
        // Start ~a third of the way in rather than at zero, so the first frame already
        // looks like a day in progress.
        let p = ((elapsed + demoWindow * 0.34).truncatingRemainder(dividingBy: demoWindow))
                / demoWindow
        var u = UsageSnapshot()
        u.sessionPct = Int((p * 100).rounded())
        u.sessionResetsAt = now + realWindow * (1 - p)
        // The weekly figures creep and then settle. Two reasons not to run them fast:
        // a week genuinely doesn't move inside a recording, and anything that climbs
        // on a demo clock eventually pegs at its ceiling — a header reading 99% 本周
        // looks like an account about to be cut off, not like a product working.
        u.weekPct = min(74, 63 + Int(elapsed / 180))
        u.weekModelPct = min(58, 44 + Int(elapsed / 240))
        // Anchored to the run's start, not to `now` — recomputing the reset instant
        // every poll would freeze the countdown at a constant "3d04h" forever.
        u.weekResetsAt = weekResetsAt
        u.weekModelLabel = "Opus"
        u.updatedAt = now
        return u
    }

    // MARK: - Accounts

    // Three Claude addresses and two Codex ones: enough for the account panel to be a
    // list rather than a single row, and for both header cards to carry a plan. The
    // signed-in row's figures are the header's own (usage() / codexUsage()), so the
    // panel and the card never disagree; the other rows carry an older reading, and
    // one of them is past its window so the "rolled over, full again" state is on
    // screen too.
    //
    // ★ A pick here moves `current` and nothing else — no credential is copied or
    // restored, no login is launched, and the real book is neither read nor written.
    // headerAgentInfo bails to these before AccountBook.note for the same reason: it
    // used to file the demo's fake percentages under the user's REAL address.
    private struct Person { let email: String; let name: String; let plan: String; let id: String }
    private static let defaultBooks: [AgentKind: [Person]] = [
        .claude: [Person(email: "mei.tanaka@aurora.dev", name: "Mei Tanaka", plan: "Max 20x", id: "demo-claude-1"),
                  Person(email: "dev@pico-engine.io", name: "Pico Engine", plan: "Max 5x", id: "demo-claude-2"),
                  Person(email: "jordan.reyes@gmail.com", name: "Jordan Reyes", plan: "Pro", id: "demo-claude-3")],
        .codex:  [Person(email: "mei.tanaka@aurora.dev", name: "Mei Tanaka", plan: "Pro", id: "demo-codex-1"),
                  Person(email: "ops@pico-engine.io", name: "Pico Ops", plan: "Plus", id: "demo-codex-2")],
    ]
    private static var books = defaultBooks
    private static var current: [AgentKind: String] = [:]

    private static func person(_ kind: AgentKind) -> Person? {
        let list = books[kind] ?? []
        if let email = current[kind], let p = list.first(where: { $0.email == email }) { return p }
        return list.first
    }

    /// What the header shows as the signed-in account.
    static func account(_ kind: AgentKind) -> AgentAccount? {
        guard let p = person(kind) else { return nil }
        return AgentAccount(email: p.email, displayName: p.name, plan: p.plan,
                            organization: nil, accountID: p.id)
    }

    /// The panel's rows, in the fixed order the real book keeps them.
    static func book(_ kind: AgentKind) -> [RememberedAccount] {
        let now = Date().timeIntervalSince1970
        let cur = person(kind)?.email
        let live = kind == .claude ? usage() : codexUsage()
        return (books[kind] ?? []).enumerated().map { i, p in
            var r = RememberedAccount(email: p.email, displayName: p.name, plan: p.plan,
                                      accountID: p.id, lastSeen: now, addedAt: t0 - Double(30 - i) * 86400,
                                      oauthAccountJSON: nil, usage: nil)
            if p.email == cur {
                r.usage = AccountUsage(sessionPct: live.sessionPct, weekPct: live.weekPct,
                                       sessionResetsAt: live.sessionResetsAt,
                                       weekResetsAt: live.weekResetsAt, readAt: now)
            } else {
                r.usage = staleUsage[p.id]
            }
            return r
        }
    }

    /// Readings for the rows that aren't signed in, anchored to the run's start so a
    /// countdown keeps counting instead of freezing at one figure. Second Claude
    /// address: still inside a heavy window. Third: window already over (renders as
    /// "full again"). Second Codex address: light use, hours left.
    private static var staleUsage: [String: AccountUsage] {[
        "demo-claude-2": AccountUsage(sessionPct: 81, weekPct: 66,
                                      sessionResetsAt: t0 + 1 * 3600 + 40 * 60,
                                      weekResetsAt: t0 + 2 * 86400 + 6 * 3600,
                                      readAt: t0 - 47 * 60),
        "demo-claude-3": AccountUsage(sessionPct: 94, weekPct: 31,
                                      sessionResetsAt: t0 - 20 * 60,
                                      weekResetsAt: t0 + 5 * 86400 + 2 * 3600,
                                      readAt: t0 - 3 * 3600 - 12 * 60),
        "demo-codex-2":  AccountUsage(sessionPct: 57, weekPct: 44,
                                      sessionResetsAt: t0 + 2 * 3600 + 10 * 60,
                                      weekResetsAt: t0 + 3 * 86400 + 20 * 3600,
                                      readAt: t0 - 1 * 3600 - 20 * 60),
    ]}

    /// The panel's click: the tick moves, nothing else happens.
    static func pick(_ kind: AgentKind, email: String) { current[kind] = email }

    /// The row's context menu: drop it from the fake list for the rest of this run.
    static func forget(_ kind: AgentKind, email: String) {
        books[kind] = (books[kind] ?? []).filter { $0.email != email }
    }

    /// Codex's card runs on its own phase so the two cards never move in lockstep,
    /// and its weekly figure sits lower — a second subscription that is used less.
    static func codexUsage() -> UsageSnapshot {
        let now = Date().timeIntervalSince1970
        let p = ((elapsed + demoWindow * 0.61).truncatingRemainder(dividingBy: demoWindow))
                / demoWindow
        var u = UsageSnapshot()
        u.sessionPct = Int((p * 100).rounded())
        u.sessionResetsAt = now + realWindow * (1 - p)
        u.weekPct = min(52, 38 + Int(elapsed / 300))
        u.weekResetsAt = weekResetsAt + 14 * 3600
        u.updatedAt = now
        return u
    }

    // MARK: - Machine load

    // Two out-of-phase sines plus a slow wobble: no repeat you can see inside a
    // recording, and no jitter frame-to-frame that would read as a broken gauge.
    static func systemLoad() -> SystemLoad {
        let e = elapsed
        let cpu = 46 + 26 * sin(e / 7.3) + 11 * sin(e / 2.7) + 6 * sin(e / 19.1)
        let mem = 61 + 5 * sin(e / 23.0) + 2 * sin(e / 6.1)
        let total = ProcessInfo.processInfo.physicalMemory
        let memPct = min(96, max(30, Int(mem.rounded())))
        return SystemLoad(cpuPct: min(99, max(3, Int(cpu.rounded()))),
                          cores: ProcessInfo.processInfo.activeProcessorCount,
                          memPct: memPct,
                          memUsedBytes: UInt64(Double(total) * Double(memPct) / 100),
                          memTotalBytes: total)
    }

    // MARK: - Fake logs behind the 统计 / 效能 tabs
    //
    // Rather than teach every chart a demo branch, we hand the two stores a different
    // FILE. Both aggregations then run exactly as they do in production — which is
    // also the point: a demo that renders through a second code path proves nothing
    // about the real one.

    private static var logGeneration = 0
    private static var logsWritten = false

    private static var dir: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("spectix-demo")
    }
    /// The filename carries the generation because JSONLCache parses INCREMENTALLY:
    /// it only re-reads from scratch when the path changes or the file shrank, so
    /// rewriting the same name after a restart would splice two timelines together.
    ///
    /// Both getters materialize the files if they aren't there yet. That is on purpose:
    /// they are read through `StatsStore.logPath` / `ImpactLog.readPath`, which the
    /// 统计 tab can reach before the first demo poll has run, and a chart that comes up
    /// blank for one frame because its file didn't exist yet is a bug nobody would think
    /// to look for here.
    static var eventsPath: String { ensureLogs(); return "\(dir)/events-\(logGeneration).jsonl" }
    static var impactPath: String { ensureLogs(); return "\(dir)/impact-\(logGeneration).jsonl" }

    /// Generate both logs once per demo run. Idempotent and main-thread only (the demo
    /// render path and the 统计 tab are the only callers), and cheap enough — a few
    /// thousand short lines — to do inline rather than hand to a queue whose completion
    /// nothing would be waiting on.
    static func ensureLogs() {
        guard !logsWritten else { return }
        logsWritten = true
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeEvents(to: "\(dir)/events-\(logGeneration).jsonl")
        writeImpact(to: "\(dir)/impact-\(logGeneration).jsonl")
    }

    // A seeded LCG, not arc4random: the same demo run must produce the same charts
    // every time, or two screenshots of "the same" week disagree.
    private struct RNG {
        private var s: UInt64
        init(_ seed: UInt64) { s = seed }
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() >> 33) % (range.upperBound - range.lowerBound + 1)
        }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
        mutating func chance(_ pct: Int) -> Bool { int(1...100) <= pct }
    }

    private static let demoProjects = ["aurora-web", "pico-engine", "notes-api",
                                       "spectix-site", "ledger-cli"]
    private static let demoTtys = ["ttys004", "ttys006", "ttys011", "ttys015", "ttys021"]
    private static let demoModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
    // Titles are keyed by project: a log where "Port the particle system to Metal"
    // lands on the notes API reads as generated the moment anyone looks at the 按任务
    // list, which is exactly the screen a demo is most likely to be showing.
    private static let demoTitles: [String: [String]] = [
        "aurora-web": ["Wire the checkout flow to the new payments API",
                       "Fix the flaky auth test on CI",
                       "Split the settings screen into sections",
                       "Add retries around the webhook consumer"],
        "pico-engine": ["Port the particle system to Metal",
                        "Trace the memory growth in the render loop",
                        "Batch the sprite draw calls",
                        "Cache the shader cache between launches"],
        "notes-api": ["Migrate the user table to UUID keys",
                      "Rate-limit the search endpoint",
                      "Backfill the missing created_at column",
                      "Move attachments off the app server"],
        "spectix-site": ["Rewrite the pricing page copy",
                         "Shrink the hero image payload",
                         "Add the changelog page",
                         "Fix the mobile nav overlap"],
        "ledger-cli": ["Document the release checklist",
                       "Parse the OFX export format",
                       "Round currency at the boundary, not per row",
                       "Add a --since flag to the report command"],
    ]

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 45 days of turns: run → a few ticks → sometimes a decision → done with token
    /// tallies. Weekends are quieter and the most recent days are busier, so the
    /// day chart has a shape and 「较上期」 has something to compare against.
    private static func writeEvents(to path: String) {
        var rng = RNG(0x5EC71A9B)
        var out = ""
        let now = Int(Date().timeIntervalSince1970)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for back in stride(from: 44, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let quiet = (weekday == 1 || weekday == 7)
            // A gentle ramp so recent weeks beat older ones — the 效能 panel's
            // 个人最佳 / 较上期 lines need a trend, not noise around a flat mean.
            let ramp = 1.0 + Double(44 - back) / 90.0
            guard let (open, close) = window(day, isToday: back == 0, now: now) else { continue }
            var turns = max(1, Int(Double(rng.int(quiet ? 2...9 : 14...30)) * ramp))
            // A turn needs room for its own heartbeats; packing more in than the day
            // has seconds would make one session's `run` land before the previous
            // one's `done` and read as an abandoned turn to the work clock.
            turns = min(turns, max(1, (close - open) / 450))
            let step = max(120, (close - open) / turns)
            let date = dayFmt.string(from: day)
            for i in 0..<turns {
                let clock = open + i * step + rng.int(0...(step / 3))
                let project = rng.pick(demoProjects)
                let titles = demoTitles[project] ?? ["Untitled task"]
                let tty = rng.pick(demoTtys)
                let model = rng.pick(demoModels)
                let runTs = clock
                out += line(["ts": runTs, "date": date, "event": "run", "project": project,
                             "title": rng.pick(titles), "tty": tty])
                // Heartbeats 60s apart, which is what the work clock actually counts.
                let ticks = rng.int(0...6)
                var t = runTs
                for _ in 0..<ticks {
                    t += 60
                    out += line(["ts": t, "date": date, "event": "tick",
                                 "project": project, "tty": tty])
                }
                if rng.chance(35) {
                    t += rng.int(5...50)
                    out += line(["ts": t, "date": date, "event": "decision",
                                 "project": project, "tty": tty])
                }
                t += rng.int(10...90)
                let cacheR = rng.int(40_000...420_000)
                out += line(["ts": t, "date": date, "event": "done", "project": project,
                             "tty": tty, "tok_in": rng.int(400...9_000),
                             "tok_out": rng.int(300...6_500),
                             "tok_cache_w": rng.int(2_000...48_000),
                             "tok_cache_r": cacheR,
                             "api_calls": rng.int(3...40), "model": model])
            }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The 效能 log: a banner fires, you get there (or don't), you stay a while.
    /// Proportions are chosen so every metric on that panel has something to show —
    /// enough self-found arrivals to pass `baselineMinSamples`, a few 被晾 misses so
    /// 遗漏 isn't a suspicious zero, and auto-jumps that land far faster than the
    /// manual ones, which is the whole claim the panel makes.
    private static func writeImpact(to path: String) {
        var rng = RNG(0xDEA1B0A7)
        var out = ""
        let now = Int(Date().timeIntervalSince1970)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for back in stride(from: 44, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let quiet = (weekday == 1 || weekday == 7)
            let ramp = 1.0 + Double(44 - back) / 90.0
            guard let (open, close) = window(day, isToday: back == 0, now: now) else { continue }
            let banners = max(1, Int(Double(rng.int(quiet ? 2...7 : 10...22)) * ramp))
            let step = max(60, (close - open) / banners)
            for i in 0..<banners {
                let clock = open + i * step + rng.int(0...(step / 3))
                let tty = rng.pick(demoTtys)
                let status = rng.chance(45) ? "needs" : "done"
                // 「你在不在电脑前」: mostly yes, so the miss count stays meaningful.
                let idle = rng.chance(78) ? rng.int(0...110) : rng.int(200...5_000)
                out += line(["ts": clock, "kind": "notify", "tty": tty,
                             "status": status, "idle": idle])
                let roll = rng.int(1...100)
                var arriveTs = clock
                if roll <= 34 {
                    arriveTs = clock + rng.int(1...4)
                    out += line(["ts": arriveTs, "kind": "jump_auto_chain", "tty": tty])
                } else if roll <= 48 {
                    arriveTs = clock + rng.int(2...9)
                    out += line(["ts": arriveTs, "kind": "jump_hotkey", "tty": tty])
                } else if roll <= 82 {
                    arriveTs = clock + rng.int(8...70)
                    out += line(["ts": arriveTs, "kind": "jump_manual", "tty": tty])
                } else if roll <= 92 {
                    // Found it yourself — these are the baseline the credits measure against.
                    arriveTs = clock + rng.int(90...520)
                } else {
                    // Never answered inside the window: a 被晾 miss.
                    arriveTs = 0
                }
                if arriveTs > 0 {
                    out += line(["ts": arriveTs + rng.int(1...3), "kind": "arrive", "tty": tty,
                                 "status": status, "dwell": rng.int(6...480),
                                 "active": rng.chance(72)])
                }
                if rng.chance(18) {
                    out += line(["ts": clock + rng.int(1...30), "kind": "parked_block", "tty": tty])
                }
                if rng.chance(30) {
                    out += line(["ts": clock + rng.int(1...20), "kind": "live",
                                 "n": rng.int(1...5)])
                }
            }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The slice of one day that gets activity: a 09:00–21:00 working day, never
    /// running past `now`. Today is the case that matters — a log written at 09:00
    /// that spreads turns across the whole day would put half its events in the
    /// FUTURE, and 今日 would claim work nobody has done yet. When that clipping
    /// leaves too little day, the window slides earlier instead of thinning out, so
    /// 今日 still has a shape; before ~06:00 there simply isn't one, and the demo
    /// shows a quiet morning rather than an invented one.
    private static func window(_ day: Date, isToday: Bool, now: Int) -> (Int, Int)? {
        let dayStart = Int(day.timeIntervalSince1970)
        var open = dayStart + 9 * 3600
        var close = dayStart + 21 * 3600
        if isToday { close = min(close, now - 120) }
        if close - open < 3 * 3600 { open = max(dayStart + 5 * 3600, close - 3 * 3600) }
        guard close - open >= 600 else { return nil }
        return (open, close)
    }

    /// One JSONL line. Values are Int / String / Bool only, so this hand-rolls the
    /// encoding rather than pulling JSONSerialization through a few thousand calls.
    private static func line(_ fields: [String: Any]) -> String {
        // Sorted keys keep the output byte-stable across runs — the seeded RNG is
        // pointless if dictionary order shuffles the file anyway.
        let body = fields.keys.sorted().compactMap { k -> String? in
            switch fields[k] {
            case let v as Bool:   return "\"\(k)\":\(v)"
            case let v as Int:    return "\"\(k)\":\(v)"
            case let v as String: return "\"\(k)\":\"\(v)\""
            default:              return nil
            }
        }.joined(separator: ",")
        return "{\(body)}\n"
    }
}

// MARK: - Skills tab

extension Demo {
    // A made-up catalog for the 技能 tab: generic names, no real paths from this Mac.
    static func catalog() -> [CatalogItem] {
        let now = Date()
        func item(_ tool: CatalogTool, _ kind: CatalogKind, _ name: String, _ uses: Int, _ daysAgo: Double?,
                  _ origin: CatalogOrigin = .user, desc: String, model: String? = nil) -> CatalogItem {
            let dir = tool == .claude ? "~/.claude" : (kind == .skill ? "~/.agents" : "~/.codex")
            let path: String?
            switch origin {
            case .builtin, .missing: path = nil
            default: path = kind == .skill ? "\(dir)/skills/\(name)/SKILL.md"
                                           : "\(dir)/agents/\(name).\(tool == .claude ? "md" : "toml")"
            }
            return CatalogItem(tool: tool, kind: kind, name: name, description: desc,
                               path: path.map { ($0 as NSString).expandingTildeInPath }, origin: origin, model: model,
                               uses: uses, lastUsed: daysAgo.map { now.addingTimeInterval(-$0 * 86400) })
        }
        return [
            item(.claude, .skill, "release-notes", 31, 0.1, desc: "Drafts release notes from the commits since the last tag."),
            item(.claude, .skill, "pr", 18, 0.4, desc: "Branch, commit, push and open a pull request in one step."),
            item(.claude, .skill, "handoff", 12, 1, desc: "Summarise the conversation into a task so a new session can pick it up."),
            item(.claude, .skill, "design-preview", 9, 2, desc: "Render design options as a local HTML page to compare side by side."),
            item(.claude, .skill, "claude-api", 4, 5, .builtin, desc: "Claude API and SDK reference."),
            item(.claude, .skill, "deploy-site", 3, 8, .project("website"), desc: "Build and upload the marketing site."),
            item(.claude, .skill, "bench:profile", 1, 20, .plugin("bench"), desc: "Profile a hot path and summarise the flame graph."),
            item(.claude, .skill, "changelog", 0, nil, desc: "Keep CHANGELOG.md in step with merged work."),
            item(.claude, .skill, "i18n-check", 0, nil, desc: "Find user-facing strings that miss a translation."),
            item(.claude, .agent, "general-purpose", 64, 0.05, .builtin, desc: "Built-in agent for research and multi-step tasks."),
            item(.claude, .agent, "researcher", 41, 0.3, desc: "Searches the web and returns a structured report.", model: "sonnet"),
            item(.claude, .agent, "reviewer", 37, 0.2, desc: "Reviews a change against its requirements.", model: "opus"),
            item(.claude, .agent, "coder", 22, 1, desc: "Implements a well-specified change.", model: "opus"),
            item(.claude, .agent, "Explore", 15, 3, .builtin, desc: "Built-in read-only search agent."),
            item(.claude, .agent, "tester", 0, nil, desc: "Writes and runs tests, reports failures."),
            item(.codex, .skill, "release-notes", 6, 2, desc: "Drafts release notes from the commits since the last tag."),
            item(.codex, .skill, "docs-lookup", 2, 9, .system, desc: "Looks up official documentation."),
            item(.codex, .skill, "migrate-db", 0, nil, desc: "Write and dry-run a schema migration."),
            item(.codex, .agent, "reviewer", 5, 1, desc: "Reviews a change against its requirements."),
            item(.codex, .agent, "coder", 2, 4, desc: "Implements a well-specified change."),
        ]
    }
}
