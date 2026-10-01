import Foundation

// MARK: - Usage log model + aggregation
//
// The status hook appends one JSONL line per counted event to
// ~/.claude/spectix/events.jsonl. This file turns that raw log into everything
// the stats window shows — headline counts, wall-clock time, token tallies, an
// estimated dollar cost, plus streak / peak-hours / heatmap views — sliced by a
// time range (today / week / month / all) and grouped by day, project, model, or
// individual task.

// One line in events.jsonl.
struct UsageEvent: Decodable {
    let ts: Int          // epoch seconds
    let date: String     // local "YYYY-MM-DD" as the hook saw it (the key for day buckets)
    let event: String    // "run" | "tick" | "decision" | "done"
    let project: String  // basename of the session's cwd
    let cwd: String?     // full session cwd — tells same-named folders apart, and tells
                         // which project a REUSED terminal was on when the line was written
    let title: String?   // the prompt summary, present on "run" events only
    let tty: String?     // controlling terminal — pairs a "run" with its "done"

    // Per-turn token tallies, present on "done" events only (the hook reads the
    // transcript at Stop). Optional: older log lines and any turn whose transcript
    // wasn't readable simply omit them.
    let tok_in: Int?        // fresh (non-cached) input tokens
    let tok_out: Int?       // generated tokens
    let tok_cache_w: Int?   // tokens written to cache (billed ~1.25x)
    let tok_cache_r: Int?   // tokens read from cache (billed ~0.1x, grows per API call)
    let api_calls: Int?     // assistant messages in the turn = API round-trips
    let model: String?      // the turn's model id (e.g. "claude-opus-4-8") — drives cost

    // 1 when the hook saw AUTORUN_OWNER in its environment, i.e. this turn belongs to an
    // unattended autorun round rather than someone typing. Absent on every line written
    // before that stamp existed, and on every hand-typed turn — so treat nil as manual.
    let auto: Int?
    var isAuto: Bool { (auto ?? 0) != 0 }
}

// MARK: - Work clock (改任何「⏱ 时长」前必读)
//
// How a turn's WORKING seconds are counted. Naively a turn is "run.ts → done.ts", but
// that measures how long the turn was OPEN, not how long anything ran: a turn parked at
// a permission prompt while you sleep, or one whose done only lands the next morning,
// billed the whole night as work (measured: 295h of "work" over 17 days, incl. 22-hour
// single turns — the complaint this replaces).
//
// So time accrues between ACTIVITY PULSES instead, each gap capped:
//   pulses  = run / tick (the hook's 60s heartbeat while working) / decision / done
//   waitCap = the gap right after a `decision` — a dialog is up and YOU are the blocker,
//             so it buys a short grace (you may have answered instantly, and the next
//             heartbeat can be up to a throttle window away) and then stops.
//   workCap = every other gap — the machine is the blocker (a long build, a long think
//             with no tool call). Generous, because that IS work; it only fences off a
//             turn that died without ever emitting done.
// A gap never counts twice and never counts backwards.
enum WorkClock {
    static let workGapCap = 1800   // 30 min — longest blocking tool call we'll believe
    static let waitGapCap = 120    // 2 min  — grace after a permission/plan/question prompt

    // Seconds to credit for the span between two consecutive pulses of one session.
    static func credit(from: Int, to: Int, afterDecision: Bool) -> Int {
        min(max(0, to - from), afterDecision ? waitGapCap : workGapCap)
    }
}

// Running work clock for ONE session (tty), fed the session's events in ts order.
// Kept as a value type so each consumer (the row, the day/project buckets, the task
// list) can hold its own without sharing state.
struct SessionClock {
    private var openRun = false      // a run event has landed and no done has closed it
    private var last = 0             // ts of the most recent pulse inside that turn
    private var afterDecision = false

    // Feed one event; returns the seconds it adds to this session's work total (0 when
    // the event isn't a pulse, or falls outside an open turn).
    mutating func advance(_ e: UsageEvent) -> Int {
        switch e.event {
        case "run":
            // A second run without a done means the previous turn was abandoned
            // (Esc / crash): drop its tail rather than let the next done absorb it.
            openRun = true; last = e.ts; afterDecision = false
            return 0
        case "tick", "decision":
            defer { afterDecision = (e.event == "decision") }
            guard openRun else { return 0 }
            let d = WorkClock.credit(from: last, to: e.ts, afterDecision: afterDecision)
            last = e.ts
            return d
        case "done":
            defer { openRun = false; afterDecision = false }
            guard openRun else { return 0 }
            return WorkClock.credit(from: last, to: e.ts, afterDecision: afterDecision)
        default:
            return 0
        }
    }

    // Seconds the still-open turn has accrued since its last pulse — the live part of a
    // working row's clock. Same caps, so a row parked at 需确认 freezes instead of
    // running all night.
    func inFlight(now: Double) -> Int {
        guard openRun else { return 0 }
        return WorkClock.credit(from: last, to: Int(now), afterDecision: afterDecision)
    }

    // Whether a done event closed a turn this session opened — the "paired task" count.
    var hasOpenRun: Bool { openRun }
}

// MARK: - Cost model (ESTIMATED)
//
// token → USD. Rates are per million tokens (MTok), 2026 list prices. Cache write
// is billed ~1.25x input (the 5-minute tier; Claude Code also uses a 1h tier at
// ~2x that this log can't distinguish, so writes may be under-counted) and cache
// read ~0.1x input. A turn with no recorded model is estimated as Sonnet. Every
// number this produces is an ESTIMATE, not a bill — surface it as such.
enum Pricing {
    struct Rate { let inp, out, cacheW, cacheR: Double }

    static func rate(for model: String?) -> Rate {
        let m = (model ?? "").lowercased()
        if m.contains("opus")  { return Rate(inp: 5, out: 25, cacheW: 6.25, cacheR: 0.50) }
        if m.contains("haiku") { return Rate(inp: 1, out: 5,  cacheW: 1.25, cacheR: 0.10) }
        return Rate(inp: 3, out: 15, cacheW: 3.75, cacheR: 0.30)   // sonnet / unknown
    }

    static func cost(inp: Int, out: Int, cacheW: Int, cacheR: Int, model: String?) -> Double {
        let r = rate(for: model)
        return (Double(inp) * r.inp + Double(out) * r.out
              + Double(cacheW) * r.cacheW + Double(cacheR) * r.cacheR) / 1_000_000
    }

    // "claude-opus-4-8" -> "Opus 4.8", "claude-fable-5" -> "Fable 5", etc. The
    // by-model breakdown key: version-precise so distinct releases (Opus 4.8 vs
    // 4.7) bucket apart instead of collapsing into a bare family name.
    static func displayName(_ model: String?) -> String {
        let m = (model ?? "").lowercased()
        let family: String
        if m.contains("opus")        { family = "Opus" }
        else if m.contains("sonnet") { family = "Sonnet" }
        else if m.contains("haiku")  { family = "Haiku" }
        else if m.contains("fable")  { family = "Fable" }
        else { return L("未知", "Unknown") }

        if let v = version(from: m) { return "\(family) \(v)" }
        return family
    }

    // Pull the version ("4.8" / "5" / "3.5") out of a model id. Split on "-" (a
    // trailing "[1m]"-style suffix is dropped first); the version is the run of
    // short numeric tokens next to the family word — after it for current ids
    // (opus-4-8, haiku-4-5-<date>), before it for legacy ones (3-5-sonnet). Long
    // numeric tokens are date stamps and are skipped.
    private static func version(from m: String) -> String? {
        let base = m.split(separator: "[").first.map(String.init) ?? m
        let parts = base.split(separator: "-").map(String.init)
        guard let fi = parts.firstIndex(where: {
            ["opus", "sonnet", "haiku", "fable"].contains($0) }) else { return nil }
        func isVer(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 2 && s.allSatisfy(\.isNumber)
        }
        var nums: [String] = []
        var i = fi + 1
        while i < parts.count, isVer(parts[i]) { nums.append(parts[i]); i += 1 }
        if nums.isEmpty {   // legacy layout: version sits before the family word
            var j = fi - 1
            while j >= 0, isVer(parts[j]) { nums.insert(parts[j], at: 0); j -= 1 }
        }
        return nums.isEmpty ? nil : nums.joined(separator: ".")
    }
}

// MARK: - Token formatting

// Compact token count ("980" / "12.3k" / "1.2M"). The stats UI measures everything
// in tokens, so every view that prints one shares this single formatter.
enum Tok {
    static func fmt(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    // All four token classes of one "done" event; 0 for events that carry none
    // (runs / decisions, and older log lines written before the hook tallied them).
    static func total(_ e: UsageEvent) -> Int {
        guard e.event == "done" else { return 0 }
        return (e.tok_in ?? 0) + (e.tok_out ?? 0) + (e.tok_cache_w ?? 0) + (e.tok_cache_r ?? 0)
    }
}

// MARK: - Time range

enum TimeRange: Int, CaseIterable {
    case today, week, month, all

    var label: String {
        switch self {
        case .today: return L("今日", "Today")
        case .week:  return L("本周", "This Week")
        case .month: return L("本月", "This Month")
        case .all:   return L("全部", "All")
        }
    }

    // Inclusive lower-bound epoch; an event passes when ts >= it. `all` is 0.
    // Week starts Monday, month on the 1st, both in the local calendar.
    func lowerBound(now: Date = Date()) -> Int {
        var cal = Calendar.current
        cal.firstWeekday = 2   // Monday
        switch self {
        case .all:   return 0
        case .today: return Int(cal.startOfDay(for: now).timeIntervalSince1970)
        case .week:
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return Int((cal.date(from: c) ?? now).timeIntervalSince1970)
        case .month:
            let c = cal.dateComponents([.year, .month], from: now)
            return Int((cal.date(from: c) ?? now).timeIntervalSince1970)
        }
    }

    // The window immediately before this one, as [lo, hi) — the baseline the
    // overview cards compare against ("vs 昨日/上周/上月"). Nil for `all`,
    // which has no predecessor.
    func previousBounds(now: Date = Date()) -> (lo: Int, hi: Int)? {
        let hi = lowerBound(now: now)
        let step: DateComponents
        switch self {
        case .all:   return nil
        case .today: step = DateComponents(day: -1)
        case .week:  step = DateComponents(weekOfYear: -1)
        case .month: step = DateComponents(month: -1)
        }
        guard let lo = Calendar.current.date(
            byAdding: step, to: Date(timeIntervalSince1970: TimeInterval(hi))) else { return nil }
        return (Int(lo.timeIntervalSince1970), hi)
    }

    // Caption for the comparison line under the overview numbers.
    var deltaCaption: String? {
        switch self {
        case .today: return L("vs 昨日", "vs yesterday")
        case .week:  return L("vs 上周", "vs last week")
        case .month: return L("vs 上月", "vs last month")
        case .all:   return nil
        }
    }

    // Bucket width for the fine-grained rate series, in seconds. Chosen so the series
    // lands near ~300 points whatever the range: below that the line is too coarse to
    // show a burst, above it each point is under a pixel and the chart is a smear.
    // 今日 is the 5-minute grain the series was asked for; the rest scale off it.
    var rateBucket: Int {
        switch self {
        case .today: return 300      // 5 min  -> 288 points
        case .week:  return 1800     // 30 min -> 336 points
        case .month: return 7200     // 2 h    -> ~360 points
        case .all:   return 86400    // 1 day
        }
    }

    // Upper bound of the rate series: always NOW, never the end of the period.
    // Running the axis out to midnight looks tidier but reads as a lie — the empty
    // buckets between now and then plot as a flat zero line, which is exactly how
    // "nobody was working" looks. An axis that ends at the present says nothing it
    // cannot back up.
    func upperBound(now: Date = Date()) -> Int { Int(now.timeIntervalSince1970) }
}

// MARK: - Buckets

// A rolled-up bucket for one day / project / model.
struct StatBucket {
    let key: String
    var runs = 0         // task runs (prompts submitted)
    var done = 0         // turns completed

    // Token sums across this bucket's done events.
    var tokIn = 0, tokOut = 0, tokCacheW = 0, tokCacheR = 0
    // Every token class together — the weight the distribution bars rank by.
    var tokTotal: Int { tokIn + tokOut + tokCacheW + tokCacheR }
    var costUSD = 0.0    // estimated, summed per done event at its model's rate
    // Wall-clock time, summed over paired run->done tasks, plus the pair count so the
    // window can show both a total and an average.
    var durSec = 0
    var pairedTasks = 0
}

// One column of the activity histogram: the tokens consumed in that slot, the axis
// tick to draw beneath it (nil = un-labelled, so dense ranges don't crowd the axis),
// and the hover tip.
struct ActivityBar {
    let value: Int
    let tick: String?
    let tip: String
}

// One point on the fine-grained rate series — one bucket of `TimeRange.rateBucket`
// seconds. Token figures are Doubles because a turn's cost is SPREAD across the buckets
// it worked through (see `rateSeries`), so a bucket routinely holds a fraction of one.
struct RatePoint {
    let start: Int          // bucket start, epoch seconds
    var manualTok: Double = 0   // tokens from hand-typed turns
    var autoTok: Double = 0     // tokens from unattended autorun rounds
    var sessions: Int = 0       // distinct terminals that pulsed inside this bucket

    var tok: Double { manualTok + autoTok }
}

// One run->done task, for the "by task" breakdown.
struct TaskRun {
    let ts: Int          // done ts (sort key, newest first)
    let title: String    // the run's prompt summary, or project name as a fallback
    let project: String
    let durSec: Int
    let tokIn, tokOut, tokCacheW, tokCacheR: Int
    let costUSD: Double
    let model: String?
}

// MARK: - Incremental JSONL reader
//
// Shared by both append-only logs the app reads (events.jsonl from the hook,
// impact.jsonl from the app itself). Both are re-read on every refresh — and an
// FSEvent burst during a busy turn fires several of those a second, so full
// re-decoding thousands of lines was the single most expensive thing in a scan
// (~63ms at 2.5k lines). Decode only the bytes appended since last time and keep
// the events; an unchanged file costs one stat.
//
// One instance = one cached file. Holds its own lock because readers live on
// different threads (scan queue + main).
final class JSONLCache<T: Decodable> {
    private let lock = NSLock()
    private var events: [T] = []
    private var bytes: UInt64 = 0   // how far into the file we've decoded
    private var path = ""
    // Hashes of every raw line already accepted — the dedup gate below. Lives beside
    // the event cache (incremental parsing only ever sees the newest bytes, so the
    // memory of older lines has to persist) and is cleared with it.
    private var seenLines: Set<Int> = []

    func parse(_ p: String) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let fh = FileHandle(forReadingAtPath: p) else {
            path = ""; events = []; bytes = 0; seenLines = []
            return []
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // A different file, or one that SHRANK (rotated / truncated / deleted+recreated):
        // the cache describes bytes that no longer exist — start over.
        if p != path || size < bytes {
            path = p; events = []; bytes = 0; seenLines = []
        }
        guard size > bytes else { return events }
        try? fh.seek(toOffset: bytes)
        guard let data = try? fh.readToEnd(), !data.isEmpty,
              // Decode only through the last COMPLETE line: the writer may be mid-append,
              // and a half-written tail must be re-read next time, not skipped forever.
              let nl = data.lastIndex(of: UInt8(ascii: "\n")) else { return events }
        let complete = data[data.startIndex...nl]
        let dec = JSONDecoder()
        // Skip any malformed line rather than dropping the whole log — a torn line
        // (crash mid-append) must not blank the window.
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            // A byte-identical line is the same event logged twice, not two events: it
            // repeats the timestamp AND the token counts, so keeping both double-bills
            // the turn. They happen whenever two hooks are wired at once (the window
            // around the SpectiX rename left 493 dupes in a 4780-line log) — the app
            // can't stop that from the read side, so it refuses to count it. T180
            // deduped the file once; this keeps new ones from landing.
            // Keyed by hash, not by the line itself, to stay flat in memory.
            guard seenLines.insert(line.hashValue).inserted,
                  let d = line.data(using: .utf8),
                  let ev = try? dec.decode(T.self, from: d) else { continue }
            events.append(ev)
        }
        bytes += UInt64(complete.count)
        return events
    }
}

// MARK: - Store

// Reads and aggregates the append-only event log. Cheap enough to re-parse on
// every window open — one short line per turn, and the window isn't hot.
final class StatsStore {
    // READ path only — nothing in the app appends here (the status hook owns the
    // writing), which is what makes the demo redirect safe: every chart reads a
    // generated file while the real log is left untouched.
    static var logPath: String {
        Demo.enabled ? Demo.eventsPath
                     : "\(NSHomeDirectory())/.claude/spectix/events.jsonl"
    }

    private(set) var events: [UsageEvent] = []

    func reload() { events = Self.parse(Self.logPath) }

    // Called from the scan queue (fetchRows) AND the main thread (the stats window's
    // reload); JSONLCache carries the lock that makes that safe.
    private static let cache = JSONLCache<UsageEvent>()

    static func parse(_ path: String) -> [UsageEvent] { cache.parse(path) }

    // Events whose ts falls in the range, ascending by ts.
    private func filtered(_ r: TimeRange) -> [UsageEvent] {
        let lb = r.lowerBound()
        let base = lb == 0 ? events : events.filter { $0.ts >= lb }
        return base.sorted { $0.ts < $1.ts }
    }

    // MARK: Range-scoped rollups

    // Headline totals for the range: one bucket, everything keyed the same.
    func totals(_ r: TimeRange) -> StatBucket {
        aggregate(filtered(r)) { _ in "*" }.first ?? StatBucket(key: "*")
    }

    // Totals for the window right before the range — the "vs 上周" baseline.
    func previousTotals(_ r: TimeRange) -> StatBucket? {
        guard let (lo, hi) = r.previousBounds() else { return nil }
        let evs = events.filter { $0.ts >= lo && $0.ts < hi }.sorted { $0.ts < $1.ts }
        return aggregate(evs) { _ in "*" }.first ?? StatBucket(key: "*")
    }

    // Days, newest first.
    func byDay(_ r: TimeRange) -> [StatBucket] {
        aggregate(filtered(r)) { $0.date }.sorted { $0.key > $1.key }
    }

    // Projects, hungriest first (tokens), name as the tiebreak. Ranking matches what
    // the distribution bars measure, so the list always reads top-down.
    func byProject(_ r: TimeRange) -> [StatBucket] {
        aggregate(filtered(r)) { $0.project }
            .sorted { $0.tokTotal != $1.tokTotal ? $0.tokTotal > $1.tokTotal : $0.key < $1.key }
    }

    // Models, hungriest first (tokens). Only done events carry a model, so key off
    // those — runs/decisions have no model and would all pile under "未知".
    func byModel(_ r: TimeRange) -> [StatBucket] {
        let dones = filtered(r).filter { $0.event == "done" }
        return aggregate(dones) { Pricing.displayName($0.model) }
            .sorted { $0.tokTotal != $1.tokTotal ? $0.tokTotal > $1.tokTotal : $0.key < $1.key }
    }

    // Individual tasks (run->done pairs), newest first.
    func sessions(_ r: TimeRange) -> [TaskRun] {
        var open: [String: UsageEvent] = [:]   // tty -> the run in flight
        var clocks: [String: SessionClock] = [:]
        var worked: [String: Int] = [:]        // tty -> work seconds accrued this turn
        var out: [TaskRun] = []
        for e in filtered(r) {
            // Same work clock as everywhere else; here the seconds pile up per turn and
            // are read off (then cleared) when its done lands. A done with no open run —
            // the turn started before this range — must report 0, not the previous turn's.
            if let tty = e.tty {
                var clock = clocks[tty] ?? SessionClock()
                if e.event == "run" || !clock.hasOpenRun { worked[tty] = 0 }
                worked[tty, default: 0] += clock.advance(e)
                clocks[tty] = clock
            }
            switch e.event {
            case "run":
                if let tty = e.tty { open[tty] = e }
            case "done":
                let ti = e.tok_in ?? 0, to = e.tok_out ?? 0
                let cw = e.tok_cache_w ?? 0, cr = e.tok_cache_r ?? 0
                let run = e.tty.flatMap { open[$0] }
                let dur = e.tty.flatMap { worked[$0] } ?? 0
                let raw = (run?.title ?? e.title ?? "")
                let title = raw.isEmpty ? e.project : raw
                out.append(TaskRun(
                    ts: e.ts, title: title, project: e.project, durSec: dur,
                    tokIn: ti, tokOut: to, tokCacheW: cw, tokCacheR: cr,
                    costUSD: Pricing.cost(inp: ti, out: to, cacheW: cw, cacheR: cr, model: e.model),
                    model: e.model))
                if let tty = e.tty { open[tty] = nil }
            default: break
            }
        }
        return out.sorted { $0.ts > $1.ts }
    }

    // Token consumption bucketed by time slot, for the histogram under the heatmap.
    // The x-granularity tracks the range: hours for 今日, weekdays for 本周, calendar
    // days for 本月, calendar months for 全部. Bar height is tokens, not event count —
    // ten trivial turns should not out-weigh one that burned a megatoken. Each bar
    // carries its own axis tick (nil = un-labelled) and hover tip so BarsView stays
    // dumb about what a column means.
    func activity(_ r: TimeRange) -> [ActivityBar] {
        let cal = Calendar.current
        let evs = filtered(r)
        func date(_ e: UsageEvent) -> Date { Date(timeIntervalSince1970: TimeInterval(e.ts)) }

        switch r {
        case .today:
            var b = [Int](repeating: 0, count: 24)
            for e in evs { let h = cal.component(.hour, from: date(e)); if (0..<24).contains(h) { b[h] += Tok.total(e) } }
            return b.indices.map { i in
                ActivityBar(value: b[i], tick: i % 4 == 0 ? "\(i)" : nil,
                            tip: tip(b[i], cn: "\(i) 时", en: "\(i):00"))
            }

        case .week:
            let start = Date(timeIntervalSince1970: TimeInterval(r.lowerBound()))
            var b = [Int](repeating: 0, count: 7)
            for e in evs {
                let d = cal.dateComponents([.day], from: cal.startOfDay(for: start),
                                           to: cal.startOfDay(for: date(e))).day ?? -1
                if (0..<7).contains(d) { b[d] += Tok.total(e) }
            }
            let cn = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            let en = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return b.indices.map { i in
                ActivityBar(value: b[i], tick: L(cn[i], en[i]), tip: tip(b[i], cn: cn[i], en: en[i]))
            }

        case .month:
            let start = Date(timeIntervalSince1970: TimeInterval(r.lowerBound()))
            let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
            var b = [Int](repeating: 0, count: days)
            for e in evs { let d = cal.component(.day, from: date(e)) - 1; if (0..<days).contains(d) { b[d] += Tok.total(e) } }
            return b.indices.map { i in
                let day = i + 1
                return ActivityBar(value: b[i], tick: (day == 1 || day % 5 == 0) ? "\(day)" : nil,
                                   tip: tip(b[i], cn: "\(day) 日", en: "day \(day)"))
            }

        case .all:
            guard let first = events.map({ $0.ts }).min() else { return [] }
            func monthStart(_ d: Date) -> Date {
                cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            }
            let startM = monthStart(Date(timeIntervalSince1970: TimeInterval(first)))
            let nowM = monthStart(Date())
            var months: [Date] = []
            var m = startM
            while m <= nowM, months.count < 240 {
                months.append(m)
                m = cal.date(byAdding: .month, value: 1, to: m) ?? nowM.addingTimeInterval(86_400)
            }
            func key(_ d: Date) -> String {
                String(format: "%04d-%02d", cal.component(.year, from: d), cal.component(.month, from: d))
            }
            var counts: [String: Int] = [:]
            for e in events { counts[key(date(e)), default: 0] += Tok.total(e) }
            let every = max(1, months.count / 6)
            return months.enumerated().map { i, d in
                let y = cal.component(.year, from: d), mo = cal.component(.month, from: d)
                return ActivityBar(value: counts[key(d)] ?? 0,
                                   tick: i % every == 0 ? L("\(mo)月", "\(mo)/\(y % 100)") : nil,
                                   tip: tip(counts[key(d)] ?? 0, cn: "\(y)年\(mo)月", en: key(d)))
            }
        }
    }

    // MARK: Fine-grained rate series (改这块前先读下面这段)
    //
    // Two curves over the same buckets: how fast tokens were burned, and how many
    // terminals were working. One pass builds both, because they answer the same
    // question from two sides ("was the expensive hour the crowded one?") and the log
    // is the same log.
    //
    // ★ Why tokens are SPREAD instead of stamped where the log puts them.
    // The hook can only tally a turn at its Stop, so the whole turn — twenty minutes of
    // it — lands on one timestamp. Plotted literally that is not a rate, it is a record
    // of when the bill was cut: measured on this machine's own log, the spike peak runs
    // ~3x the spread peak (38.8M vs 12.9M in one day), so a spike series drawn on a
    // shared axis flattens every real burst into the floor. So each turn's tokens are
    // divided over the work segments it actually ran through — the same capped
    // pulse-to-pulse spans WorkClock credits everywhere else, NOT run.ts→done.ts, so a
    // turn parked at a permission prompt does not smear its cost across the wait.
    // The totals are preserved exactly: sum(spread) == sum(stamped).
    //
    // A turn whose work clock came out at zero (no pulse survived the caps) has nothing
    // to spread along, so it falls back to landing whole in its done bucket.
    func rateSeries(_ r: TimeRange, now: Date = Date()) -> [RatePoint] {
        let width = r.rateBucket
        let lo = (r == .all ? (events.first?.ts ?? Int(now.timeIntervalSince1970))
                            : r.lowerBound(now: now)) / width * width
        let hi = max(lo + width, r.upperBound(now: now))
        let count = min(2000, (hi - lo + width - 1) / width)   // hard cap: never plot more
        guard count > 0 else { return [] }

        var pts = (0..<count).map { RatePoint(start: lo + $0 * width) }
        var seen = [Set<String>](repeating: [], count: count)  // distinct ttys per bucket

        func idx(_ ts: Int) -> Int? {
            let i = (ts - lo) / width
            return (0..<count).contains(i) ? i : nil
        }

        // One turn in flight, per terminal: where its last pulse landed and the capped
        // work spans accumulated so far.
        struct Turn {
            var last: Int
            var afterDecision = false
            var segs: [(from: Int, to: Int)] = []
            var worked: Int { segs.reduce(0) { $0 + ($1.to - $1.from) } }
        }
        var open: [String: Turn] = [:]

        // Credit the span since this turn's previous pulse, then move the pulse forward.
        func pulse(_ tty: String, _ ts: Int, decision: Bool) {
            guard var t = open[tty] else { return }
            let d = WorkClock.credit(from: t.last, to: ts, afterDecision: t.afterDecision)
            if d > 0 { t.segs.append((t.last, t.last + d)) }
            t.last = ts
            t.afterDecision = decision
            open[tty] = t
        }

        for e in filtered(r) {
            if let tty = e.tty, let i = idx(e.ts) { seen[i].insert(tty) }
            guard let tty = e.tty else { continue }
            switch e.event {
            case "run":
                open[tty] = Turn(last: e.ts)
            case "tick", "decision":
                pulse(tty, e.ts, decision: e.event == "decision")
            case "done":
                pulse(tty, e.ts, decision: false)
                // Close the turn BEFORE any early exit below, or a zero-token done would
                // leave it open and the next run's spans would inherit its pulse.
                let turn = open[tty]
                open[tty] = nil
                let tok = Double(Tok.total(e))
                guard tok > 0 else { continue }
                let worked = turn?.worked ?? 0
                guard let segs = turn?.segs, worked > 0 else {
                    // Nothing measurable to spread along — land it whole where it closed.
                    if let i = idx(e.ts) { add(&pts[i], tok, auto: e.isAuto) }
                    continue
                }
                for seg in segs {
                    var cur = seg.from
                    while cur < seg.to {
                        let edge = cur / width * width + width
                        let stop = min(seg.to, edge)
                        if let i = idx(cur) {
                            add(&pts[i], tok * Double(stop - cur) / Double(worked), auto: e.isAuto)
                        }
                        cur = stop
                    }
                }
            default: break
            }
        }

        for i in 0..<count { pts[i].sessions = seen[i].count }
        return pts
    }

    private func add(_ p: inout RatePoint, _ tok: Double, auto: Bool) {
        if auto { p.autoTok += tok } else { p.manualTok += tok }
    }

    // "<when> · 1.2M tokens" or "<when> · 无用量" — the hover readout for one bar.
    private func tip(_ n: Int, cn: String, en: String) -> String {
        n > 0 ? L("\(cn) · \(Tok.fmt(n)) tokens", "\(en) · \(Tok.fmt(n)) tokens")
              : L("\(cn) · 无用量", "\(en) · no usage")
    }

    // MARK: Global (range-independent) views

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // Total tokens consumed per day for the last `days` days, oldest first — the
    // heatmap grid. Tokens live on "done" events only; sum all four token classes so
    // the cell intensity tracks real usage (input + output + cache write + read).
    // Keyed by the hook's own local date string, matching how the log was written.
    func heatmap(days n: Int) -> [(date: Date, tok: Int)] {
        var toks: [String: Int] = [:]
        for e in events where e.event == "done" { toks[e.date, default: 0] += Tok.total(e) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [(Date, Int)] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            out.append((d, toks[Self.df.string(from: d)] ?? 0))
        }
        return out
    }

    // Per-day token totals inside the current weekly quota period [resetsAt-7d, resetsAt),
    // oldest first, only days that actually consumed tokens. Feeds the segmented quota
    // bar: the stats UI turns each day's tokens into a share of the authoritative
    // week_pct (from usage.json), so the segments plus the remainder read as 100%.
    func weekQuotaDays(resetsAt: Double) -> [(date: Date, tok: Int)] {
        let start = resetsAt - 7 * 86_400
        let cal = Calendar.current
        var byDay: [String: (date: Date, tok: Int)] = [:]
        for e in events where e.event == "done" {
            let ts = Double(e.ts)
            guard ts >= start, ts < resetsAt else { continue }
            let tok = Tok.total(e)
            guard tok > 0 else { continue }
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: ts))
            byDay[Self.df.string(from: day), default: (day, 0)].tok += tok
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    // MARK: Core aggregation

    // One ordered pass builds every bucket. Counts, token sums and cost are per-event;
    // task duration needs pairing: a "run" opens a task on its tty, the next "done" on
    // that same tty closes it (done.ts - run.ts). A task is attributed to the bucket its
    // "done" lands in — so its tokens, cost and duration always agree.
    private func aggregate(_ events: [UsageEvent], _ keyOf: (UsageEvent) -> String) -> [StatBucket] {
        var map: [String: StatBucket] = [:]
        var clocks: [String: SessionClock] = [:]   // tty -> its running work clock
        for e in events {
            let k = keyOf(e)
            var b = map[k] ?? StatBucket(key: k)
            // Work seconds accrue per PULSE, not per finished pair (see WorkClock), so
            // they land in the bucket of the pulse that earned them — a turn spanning
            // midnight splits across both days, which is what a day bucket should say.
            if let tty = e.tty {
                var clock = clocks[tty] ?? SessionClock()
                let paired = e.event == "done" && clock.hasOpenRun
                b.durSec += clock.advance(e)
                if paired { b.pairedTasks += 1 }
                clocks[tty] = clock
            }
            switch e.event {
            case "run":
                b.runs += 1
            case "done":
                b.done += 1
                let ti = e.tok_in ?? 0, to = e.tok_out ?? 0
                let cw = e.tok_cache_w ?? 0, cr = e.tok_cache_r ?? 0
                b.tokIn += ti; b.tokOut += to; b.tokCacheW += cw; b.tokCacheR += cr
                b.costUSD += Pricing.cost(inp: ti, out: to, cacheW: cw, cacheR: cr, model: e.model)
            default:
                break
            }
            map[k] = b
        }
        return Array(map.values)
    }
}
