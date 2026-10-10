import Foundation

// MARK: - Impact log (改这个文件前先读 task/files/tasks/T227-impact-stats-neon.md)
//
// events.jsonl records what CLAUDE did — the status hook writes it and knows nothing about
// this app. Everything the 效能 panel measures happens INSIDE SpectiX instead: a
// banner fired, a jump landed, you walked into a terminal, a latch blocked an automatic
// jump. None of that ever touched disk, so this is a second append-only log beside it.
//
// ★ The one hard rule (task Background): every number the panel shows must be
// RE-COMPUTABLE BY THE USER from this file. So the log stores OBSERVATIONS ONLY, never a
// score and never a derived flag. "Was this arrival guided by a banner?" is deliberately
// NOT a field — it is re-derived below from the notify/jump lines around it, which means
// anyone reading impact.jsonl can re-derive it the same way. For this product a number
// nobody can check is worse than no number at all (LICENSE promises zero network and the
// site invites users to verify with `otool -L`; the trust story is "check it yourself").

// What one line records. Every case is a thing that HAPPENED, at the moment it happened.
enum ImpactKind: String, Codable {
    case notify                          // a banner fired — the response clock starts here
    case jumpManual    = "jump_manual"   // you clicked a row or a banner
    case jumpHotkey    = "jump_hotkey"   // you pressed the next-attention hotkey
    case jumpAutoChain = "jump_auto_chain" // answered-chain carried you onward
    case jumpAutoIdle  = "jump_auto_idle"  // idle auto-jump surfaced a prompt
    case parkedBlock   = "parked_block"  // the parked latch refused to move you (T182)
    case arrive                          // you stood in a session's terminal, and left again
    case live                            // how many sessions were active, when that changed
}

// One line in impact.jsonl. Optional fields are omitted when absent (synthesized
// `encode(to:)` uses encodeIfPresent), so a jump line stays four short keys.
struct ImpactEvent: Codable {
    let ts: Int              // epoch seconds
    let kind: ImpactKind
    let tty: String?         // the session it concerns; nil for `live`
    let status: String?      // notify: which banner. arrive: what greeted you on landing
    let idle: Int?           // notify: seconds since your last keypress — 「你在不在电脑前」
    let dwell: Int?          // arrive: seconds you stayed before focus moved on
    let active: Bool?        // arrive: did you type/click during that stay (专注 needs this)
    let n: Int?              // live: sessions not idle at that moment
}

// MARK: - Writer

enum ImpactLog {
    static let path = "\(NSHomeDirectory())/.claude/spectix/impact.jsonl"

    // Where the STORE reads from — demo mode swaps in a generated log. Deliberately
    // not the same property as `path`: `log()` keeps writing to the real file, so a
    // demo run can never append a fabricated event to the user's own record.
    static var readPath: String { Demo.enabled ? Demo.impactPath : path }

    // Serial: callers are on the main thread (refresh callbacks, focus, the 0.3s focus
    // timer) and must never block on file IO.
    private static let q = DispatchQueue(label: "app.spectix.impact-log", qos: .utility)
    private static let enc = JSONEncoder()

    static func log(_ kind: ImpactKind, tty: String? = nil, status: String? = nil,
                    idle: Int? = nil, dwell: Int? = nil, active: Bool? = nil, n: Int? = nil) {
        // Demo rows can carry a real pid (Demo.panePid), so focus tracking does reach them;
        // their fake ttys must never land in the real log (T338: 14 lines did, once).
        guard !Demo.enabled else { return }
        let ev = ImpactEvent(ts: Int(Date().timeIntervalSince1970), kind: kind, tty: tty,
                             status: status, idle: idle, dwell: dwell, active: active, n: n)
        q.async {
            guard var d = try? enc.encode(ev) else { return }
            d.append(UInt8(ascii: "\n"))
            append(d)
        }
    }

    // Rate-limited variant for call sites that fire on every refresh. The parked latch
    // blocks automatic jumps for as long as you sit on that prompt — that is ONE fact
    // about your session, not 200 events at 2.5s apart. Returns silently when the same
    // (kind, tty) pair was logged less than `minGap` seconds ago.
    private static let gateLock = NSLock()
    private static var lastLogged: [String: Int] = [:]

    static func logThrottled(_ kind: ImpactKind, tty: String?, minGap: Int,
                             status: String? = nil) {
        let key = "\(kind.rawValue)|\(tty ?? "")"
        let now = Int(Date().timeIntervalSince1970)
        gateLock.lock()
        let recent = (lastLogged[key].map { now - $0 < minGap }) ?? false
        if !recent { lastLogged[key] = now }
        gateLock.unlock()
        guard !recent else { return }
        log(kind, tty: tty, status: status)
    }

    // Append one line, creating the file (and its directory) on first write.
    private static func append(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }
}

// MARK: - The five bars

// Display order is the declaration order — 省时 · 专注 · 连续 · 托管 · 掌控 (D1/2.4).
// Identity only; the colours hang off this in Theme.swift (Metric.accent) so a sixth
// metric can't be introduced with an ad-hoc hex the way the first five nearly were.
enum Metric: String, CaseIterable {
    case saved      // 省时 — seconds
    case focus      // 专注 — seconds (longest single stretch)
    case streak     // 连续 — days
    case auto       // 托管 — count of automatic jumps
    case control    // 掌控 — peak concurrent sessions
    case work       // 工作 — seconds YOU worked (the 🍅 clock), not anything the app did
    case tokens     // 消耗 — tokens burned, all four classes (Tok.total)
}

// MARK: - Rules
//
// Every constant here ends up visible to the user, either in a 「怎么算的」 line or in
// the settings-page long form. Changing one changes a number someone may have screenshotted.
enum ImpactRule {
    static let arriveMinDwell = 3        // <3s in a terminal is passing through, not a visit
    static let arriveDedupe = 30         // re-entering the same session inside 30s is one visit
    static let guidedWindow = 60         // a banner/jump this recent is what brought you there
    static let saveCapPerJump = 300      // 5 min — the most a single jump is ever credited
    static let baselineMinSamples = 10   // fewer self-found arrivals → no 省时 number at all
    static let strandedAfter = 600       // 10 min unanswered = 被晾
    static let atDeskWindow = 120        // typed within 2 min of the banner = you were here
    static let chainGap = 90             // auto-jumps closer than this are one chain
    static let scoreMinArrivals = 10     // fewer arrivals than this → no 效能分, show 攒数据中
    static let newUserBuckets = 4        // before this many tracked periods, show numbers not bars
}

// MARK: - Rollup types

// One metric for one period, against the best period of the same size before it.
struct MetricValue {
    let metric: Metric
    let value: Int        // this period, in the metric's own unit (seconds / days / count)
    let priorBest: Int    // the best of every week BEFORE this one — what a record beats
    let previous: Int     // the period before it, for the 「较上期」 delta

    // A record needs a real predecessor: the first period ever isn't "breaking" anything
    // (priorBest == 0), it's just the first data point (see D6 新用户前 4 周).
    // 工作 / 消耗 are how much you put in, not what the app did for you — a "record" there
    // is not something to celebrate, on the row or in the headline.
    var isRecord: Bool { metric != .work && metric != .tokens && value > priorBest && priorBest > 0 }
    var best: Int { max(value, priorBest) }
    // Bar length, 0…1. A record is exactly full — the bar is 「占你的个人最佳」 and this
    // period IS the best now.
    var ratio: Double { best > 0 ? min(1, Double(value) / Double(best)) : 0 }
    var delta: Int { value - previous }
}

// 省时: how the total splits by jump type, plus the baseline it was measured against.
struct SavedDetail {
    struct Row { let kind: ImpactKind; let count: Int; let savedSec: Int }
    let rows: [Row]              // ordered manual / hotkey / auto, empty rows dropped
    let baselineSec: Int         // median delay when you found a session WITHOUT help
    let baselineSamples: Int     // how many such arrivals backed that median this period
    // Below the sample floor the whole number is withheld rather than shown weakly:
    // one unverifiable figure would poison every other number on the panel.
    var trustworthy: Bool { baselineSamples >= ImpactRule.baselineMinSamples }
}

// 专注: the stretches themselves, so the card can say more than the single max.
struct FocusDetail {
    let segments: Int
    let avgSec: Int
    let longestSec: Int
    let longestAt: Int           // epoch of the longest stretch's start (「周三下午」)
}

// 连续: where this run began and whether today is already counted.
struct StreakDetail {
    let startTs: Int             // first day of the current run (0 when there is none)
    let todayCounted: Bool
}

// 托管: the two automatic paths, plus what the parked latch held back.
struct AutoDetail {
    let chain: Int               // answered-chain jumps
    let idle: Int                // idle auto-jumps
    let longestChain: Int        // most consecutive chain jumps within ImpactRule.chainGap
    let blocked: Int             // 「先处理手头的红」 refusals — NOT counted as jumps (D2)
}

// 掌控: the peak, the everyday level, and what slipped.
struct ControlDetail {
    let peak: Int
    let peakAt: Int              // epoch of the peak
    let p75: Int                 // time-weighted 75th percentile — 「常态」
    let stranded: Int            // banners left >10 min while you were at the desk
    let scored: Int              // banners that counted toward that (the denominator)
    // Banners that fired at all, de-duplicated the way pairResponses de-duplicates them:
    // a second notify on a session whose first is still unanswered is the same prompt
    // flickering, not a new nudge. Counting raw `notify` lines instead would inflate this
    // by exactly the noise docs/session-status.md 命令外壳探测 describes.
    let notifies: Int
}

// The headline 效能分 and its three factors (D2). Nil `value` = not enough arrivals yet.
struct ImpactScore {
    let arrivals: Int            // sample size behind everything below
    let effectiveRate: Double    // 0…1 — arrivals that landed on needs/done
    let zeroMissRate: Double     // 0…1 — 1 − stranded/scored
    let speedScore: Double       // 0…100 — log-mapped median response delay
    let medianDelaySec: Int

    var enoughData: Bool { arrivals >= ImpactRule.scoreMinArrivals }
    // 「少扑空 N 次」: the arrivals that found a session actually waiting for you. Kept
    // as a count, not the rate — the sentence it feeds is about trips, not percentages.
    var effectiveArrivals: Int { Int((Double(arrivals) * effectiveRate).rounded()) }
    // 40/30/30 — a recommended split the user accepted; revisit once real data exists
    // (task 未决 3). 并行度 deliberately absent: it measures output, not attention, and
    // folding it in would reward opening 8 sessions and whiffing on all of them.
    var value: Int? {
        guard enoughData else { return nil }
        return Int((effectiveRate * 100 * 0.40 + zeroMissRate * 100 * 0.30
                    + speedScore * 0.30).rounded())
    }
}

// One bucket of the curve. It carries BOTH series, because which one gets drawn is a
// single decision about the whole curve (are there two scored buckets?) and not one that
// can be taken bucket by bucket — a line that switched units halfway would be a lie about
// its own axis. Buckets come out of the SAME aggregation as the headline, so the curve's
// last point and the ring above it can never disagree.
struct TrendPoint {
    let start: Int           // bucket start, epoch
    let score: Int?          // nil = that bucket never reached the sample floor
    let savedSec: Int
    let arrivals: Int        // visits that landed on a session wanting you
    let jumps: Int           // jumps of every kind, banner / hotkey / automatic
}

// Everything one period's panel needs. `range` travels WITH the numbers so every headline
// can name the period it is talking about, instead of the old code's assumption that the
// answer is always 「本周」.
struct PeriodImpact {
    let range: TimeRange
    let start: Int               // bucket start, epoch (0 under 全部 — that is one bucket)
    let metrics: [Metric: MetricValue]
    let score: ImpactScore
    let previousScore: Int?      // the period before this one, for 「较上期」
    let saved: SavedDetail
    let focus: FocusDetail
    let streak: StreakDetail
    let auto: AutoDetail
    let control: ControlDetail
    let bucketsTracked: Int      // < newUserBuckets → D6 says show numbers, not bars

    // 全部 is a single bucket: nothing precedes it, so 「较上期」 and 「破纪录」 have no
    // meaning there. Comparing against a missing predecessor reads as zero, and zero
    // renders as "you beat your record" on every single metric.
    var comparable: Bool { range != .all }

    func metric(_ m: Metric) -> MetricValue {
        metrics[m] ?? MetricValue(metric: m, value: 0, priorBest: 0, previous: 0)
    }
    var records: Int { comparable ? Metric.allCases.filter { metric($0).isRecord }.count : 0 }
}

// MARK: - Period bucketing
//
// The panel was week-only until T255. It now follows the same 今日/本周/本月/全部 switch as
// the usage report below it, and it does that by reusing `TimeRange` ITSELF rather than
// declaring a parallel enum — 「本周」 has to mean the same thing in both halves of this
// window, and two enums that must agree eventually stop agreeing.
extension TimeRange {

    // The bucket a timestamp aggregates into. Every figure on the panel is the bucket
    // `now` falls in; 「上一期」 is the bucket before it, 「个人最佳」 the best of all
    // buckets before that.
    func bucketStart(_ ts: Int, _ cal: Calendar) -> Int {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        switch self {
        case .all:   return 0
        case .today: return Int(cal.startOfDay(for: d).timeIntervalSince1970)
        case .week:  return Self.floor(d, [.yearForWeekOfYear, .weekOfYear], cal)
        case .month: return Self.floor(d, [.year, .month], cal)
        }
    }

    // Step whole buckets with the calendar, never by n × 86400. A DST boundary moves the
    // wall-clock start by an hour, so arithmetic yields a timestamp `bucketStart` itself
    // could never return — the dictionary lookup then misses and 「较上期」 silently reads
    // 0 twice a year.
    func bucketOffset(_ start: Int, by n: Int, _ cal: Calendar) -> Int {
        guard self != .all else { return 0 }
        let unit: Calendar.Component = self == .today ? .day
                                     : self == .week ? .weekOfYear : .month
        let d = Date(timeIntervalSince1970: TimeInterval(start))
        return Int((cal.date(byAdding: unit, value: n, to: d) ?? d).timeIntervalSince1970)
    }

    // The curve's x-granularity, matching the usage histogram below it (Stats.swift):
    // hours for 今日, days for 本周 and 本月, calendar months for 全部. Note it is NOT the
    // metric bucket — 全部 aggregates as one bucket but draws month by month.
    var trendStep: Calendar.Component {
        switch self {
        case .today:        return .hour
        case .week, .month: return .day
        case .all:          return .month
        }
    }

    func trendFloor(_ ts: Int, _ cal: Calendar) -> Int {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        switch trendStep {
        case .hour:  return Self.floor(d, [.year, .month, .day, .hour], cal)
        case .month: return Self.floor(d, [.year, .month], cal)
        default:     return Int(cal.startOfDay(for: d).timeIntervalSince1970)
        }
    }

    private static func floor(_ d: Date, _ units: Set<Calendar.Component>, _ cal: Calendar) -> Int {
        Int((cal.date(from: cal.dateComponents(units, from: d)) ?? d).timeIntervalSince1970)
    }
}

// MARK: - Store

// Reads impact.jsonl and rolls it up. Same incremental cache as the usage log, because
// the stats window reloads on every refresh while it's open.
final class ImpactStore {
    private static let cache = JSONLCache<ImpactEvent>()

    private(set) var events: [ImpactEvent] = []

    // `path` is a parameter so the aggregation can be exercised against a synthetic log
    // without writing into the user's real one — the numbers below are only worth
    // shipping if the edge cases (nobody answered, banner fired while away, terminal left
    // in front overnight) can be fed in deliberately.
    func reload(from path: String = ImpactLog.readPath) { events = Self.cache.parse(path) }

    // MARK: Bucketing

    // Monday-based, matching TimeRange.lowerBound so 「本周」 means the same thing on both
    // halves of the stats window.
    private static func cal() -> Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    // MARK: Public entry

    // One period, measured against every period of the same size before it. `usage`
    // supplies the 连续 metric: "did you use it at all today" is a fact about Claude
    // sessions, which lives in events.jsonl — re-reading it here would parse the same
    // file twice.
    /// `work`: seconds worked per local day, keyed by the day's start (BreakReminder.dailyWorkSec).
    func impact(range: TimeRange, now: Date = Date(), usage: [UsageEvent], work: [Int: Int] = [:]) -> PeriodImpact {
        let cal = Self.cal()
        let curBucket = range.bucketStart(Int(now.timeIntervalSince1970), cal)
        var byBucket: [Int: [ImpactEvent]] = [:]
        for e in events { byBucket[range.bucketStart(e.ts, cal), default: []].append(e) }

        let cur = (byBucket[curBucket] ?? []).sorted { $0.ts < $1.ts }
        let responses = Self.pairResponses(cur)
        let visits = Self.visits(cur)

        let saved = Self.savedDetail(responses)
        let focus = Self.focusDetail(visits)
        let auto = Self.autoDetail(cur)
        let control = Self.controlDetail(cur, responses: responses)
        let streakDays = Self.streak(usage: usage, now: now)

        // One pass per bucket for every metric, so "personal best" and "last period" come
        // from the same aggregation instead of five ad-hoc scans.
        var series: [Metric: [Int: Int]] = [:]
        for (bs, evs) in byBucket {
            let sorted = evs.sorted { $0.ts < $1.ts }
            let r = Self.pairResponses(sorted)
            let v = Self.visits(sorted)
            let sd = Self.savedDetail(r)
            series[.saved, default: [:]][bs] = sd.trustworthy ? sd.rows.reduce(0) { $0 + $1.savedSec } : 0
            series[.focus, default: [:]][bs] = Self.focusDetail(v).longestSec
            let a = Self.autoDetail(sorted)
            series[.auto, default: [:]][bs] = a.chain + a.idle
            series[.control, default: [:]][bs] = Self.controlDetail(sorted, responses: r).peak
        }
        // 连续 is a running count, not a per-period sum: its value for a bucket is the
        // streak as it stood at that bucket's end, so a 23-day run shows 23 rather than 7.
        series[.streak] = Self.streakByBucket(usage: usage,
                                              buckets: Set(byBucket.keys).union([curBucket]),
                                              range: range, cal: cal)
        for (day, sec) in work { series[.work, default: [:]][range.bucketStart(day, cal), default: 0] += sec }
        for e in usage where e.event == "done" {
            series[.tokens, default: [:]][range.bucketStart(e.ts, cal), default: 0] += Tok.total(e)
        }

        // 全部 is one bucket, so stepping back from it lands on ITSELF. It has to be told
        // there is no predecessor, or every 「较上期」 compares the period with a copy of
        // itself and reports ±0 forever.
        let prevBucket = range == .all ? nil : range.bucketOffset(curBucket, by: -1, cal)
        var metrics: [Metric: MetricValue] = [:]
        for m in Metric.allCases {
            let s = series[m] ?? [:]
            let value = m == .streak ? streakDays : (s[curBucket] ?? 0)
            let priorBest = s.filter { $0.key < curBucket }.values.max() ?? 0
            metrics[m] = MetricValue(metric: m, value: value, priorBest: priorBest,
                                     previous: prevBucket.flatMap { s[$0] } ?? 0)
        }

        var prevScore: Int?
        if let pb = prevBucket, let evs = byBucket[pb] {
            prevScore = Self.bucketScore(evs.sorted { $0.ts < $1.ts }).value
        }

        return PeriodImpact(
            range: range, start: curBucket, metrics: metrics,
            score: Self.score(responses: responses, visits: visits, control: control),
            previousScore: prevScore,
            saved: saved, focus: focus,
            streak: StreakDetail(startTs: Self.streakStart(usage: usage, now: now),
                                 todayCounted: Self.usedToday(usage: usage, now: now)),
            auto: auto, control: control,
            bucketsTracked: byBucket.keys.count)
    }

    // The curve's buckets, oldest first. Buckets with no log at all are still returned,
    // zeroed: a day you didn't use the app is a fact about that day, and dropping it would
    // slide its neighbours together and quietly redraw history.
    func trend(range: TimeRange, now: Date = Date()) -> [TrendPoint] {
        let cal = Self.cal()
        let nowTs = Int(now.timeIntervalSince1970)
        var byBucket: [Int: [ImpactEvent]] = [:]
        for e in events { byBucket[range.trendFloor(e.ts, cal), default: []].append(e) }

        // Never past now: padding out the rest of the period with zeros would draw a cliff
        // to the floor every Monday and make the week look like it collapsed.
        let last = range.trendFloor(nowTs, cal)
        let first = range == .all
            ? range.trendFloor(events.map { $0.ts }.min() ?? nowTs, cal)
            : range.bucketStart(nowTs, cal)
        guard first <= last else { return [] }

        var out: [TrendPoint] = []
        var cursor = Date(timeIntervalSince1970: TimeInterval(first))
        // The cap only bounds a clock bug — it sits far above any real span (24 hours,
        // 31 days, a decade of months) and a runaway loop here would freeze the UI thread.
        while out.count < 400 {
            let bs = Int(cursor.timeIntervalSince1970)
            let evs = (byBucket[bs] ?? []).sorted { $0.ts < $1.ts }
            let sd = Self.savedDetail(Self.pairResponses(evs))
            out.append(TrendPoint(
                start: bs,
                score: Self.bucketScore(evs).value,
                savedSec: sd.trustworthy ? sd.rows.reduce(0) { $0 + $1.savedSec } : 0,
                arrivals: Self.visits(evs).count,
                jumps: evs.filter { Self.jumpKinds.contains($0.kind) }.count))
            guard bs < last,
                  let next = cal.date(byAdding: range.trendStep, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    // The same three-factor score the ring shows, for one arbitrary slice of the log.
    private static func bucketScore(_ evs: [ImpactEvent]) -> ImpactScore {
        let r = pairResponses(evs)
        return score(responses: r, visits: visits(evs), control: controlDetail(evs, responses: r))
    }

    // MARK: Visits (arrive events, filtered per D3)

    struct Visit {
        let ts: Int, tty: String, status: String, dwell: Int, active: Bool
    }

    // Drop the noise D3 names: passing through (<3s) and re-entering the same session
    // within 30s. Idle/status-less arrivals are dropped too — going to a quiet terminal
    // is you starting new work, not you responding to anything.
    private static func visits(_ evs: [ImpactEvent]) -> [Visit] {
        var out: [Visit] = []
        var lastSeen: [String: Int] = [:]
        for e in evs where e.kind == .arrive {
            guard let tty = e.tty, let dwell = e.dwell,
                  dwell >= ImpactRule.arriveMinDwell else { continue }
            let status = e.status ?? ""
            guard status != "idle", !status.isEmpty else { continue }
            if let prev = lastSeen[tty], e.ts - prev < ImpactRule.arriveDedupe { continue }
            lastSeen[tty] = e.ts
            out.append(Visit(ts: e.ts, tty: tty, status: status, dwell: dwell,
                             active: e.active ?? false))
        }
        return out
    }

    // MARK: Response pairing — the spine of 省时, 响应速度 and 遗漏
    //
    // A banner opens a debt on its session; the first jump or arrival that follows pays
    // it. `via` names HOW it was paid: a jump kind, or nil when you found it yourself.
    // Nothing paid within strandedAfter is a miss.
    struct Response {
        let notifyTs: Int, tty: String, status: String
        let idleAtNotify: Int
        let respondTs: Int?          // nil = never answered inside the window
        let via: ImpactKind?         // nil = you walked over on your own
        var delay: Int? { respondTs.map { $0 - notifyTs } }
        // 「只在你在电脑前时计分」 (D2 掌控): a banner that fired while you were away
        // is not yours to miss.
        var atDesk: Bool { idleAtNotify <= ImpactRule.atDeskWindow }
        var stranded: Bool { atDesk && (delay ?? Int.max) > ImpactRule.strandedAfter }
    }

    private static let jumpKinds: Set<ImpactKind> =
        [.jumpManual, .jumpHotkey, .jumpAutoChain, .jumpAutoIdle]

    private static func pairResponses(_ evs: [ImpactEvent]) -> [Response] {
        // Only ONE open debt per session: a second banner before you answered the first
        // is the same unanswered prompt flickering (docs/session-status.md 命令外壳探测),
        // not a new thing to respond to.
        var open: [String: ImpactEvent] = [:]
        var out: [Response] = []
        let visitTs = Set(visits(evs).map { "\($0.tty)|\($0.ts)" })

        func close(_ tty: String, at ts: Int, via: ImpactKind?) {
            guard let n = open.removeValue(forKey: tty) else { return }
            out.append(Response(notifyTs: n.ts, tty: tty, status: n.status ?? "",
                                idleAtNotify: n.idle ?? Int.max, respondTs: ts, via: via))
        }

        for e in evs {
            guard let tty = e.tty else { continue }
            if e.kind == .notify {
                if open[tty] == nil { open[tty] = e }
            } else if jumpKinds.contains(e.kind) {
                close(tty, at: e.ts, via: e.kind)
            } else if e.kind == .arrive, visitTs.contains("\(tty)|\(e.ts)") {
                // A jump lands you in the terminal, so its arrival follows moments later
                // and finds the debt already paid — the jump gets the credit, as it should.
                close(tty, at: e.ts, via: nil)
            }
        }
        // Whatever is still open was never answered inside this bucket's slice of the log.
        for (tty, n) in open {
            out.append(Response(notifyTs: n.ts, tty: tty, status: n.status ?? "",
                                idleAtNotify: n.idle ?? Int.max, respondTs: nil, via: nil))
        }
        return out.sorted { $0.notifyTs < $1.notifyTs }
    }

    // MARK: 省时
    //
    // Per D2: baseline = the median delay of arrivals you made WITHOUT any help in this
    // period, and each jump type is credited the gap between that baseline and its own
    // median. Types are credited separately because they are not worth the same — an
    // auto-jump lands in ~1s, clicking a banner takes as long as you took to notice it.
    private static func savedDetail(_ responses: [Response]) -> SavedDetail {
        // 「自己猜着切过去」: no jump, and slow enough that no banner can be said to have
        // brought you (D3). Anything faster was guided — counting it as the unassisted
        // baseline would deflate the baseline with the app's own effect.
        let selfFound = responses.compactMap { r -> Int? in
            guard r.via == nil, let d = r.delay, d > ImpactRule.guidedWindow else { return nil }
            return d
        }
        let baseline = median(selfFound)
        var rows: [SavedDetail.Row] = []
        for kind in [ImpactKind.jumpManual, .jumpHotkey, .jumpAutoChain, .jumpAutoIdle] {
            let delays = responses.compactMap { $0.via == kind ? $0.delay : nil }
            guard !delays.isEmpty else { continue }
            let per = min(ImpactRule.saveCapPerJump, max(0, baseline - median(delays)))
            rows.append(SavedDetail.Row(kind: kind, count: delays.count,
                                        savedSec: per * delays.count))
        }
        // The two automatic paths read as one line to the user (「自动跳转 · 18 次」).
        var merged: [SavedDetail.Row] = []
        var autoCount = 0, autoSaved = 0
        for r in rows {
            if r.kind == .jumpAutoChain || r.kind == .jumpAutoIdle {
                autoCount += r.count; autoSaved += r.savedSec
            } else {
                merged.append(r)
            }
        }
        if autoCount > 0 {
            merged.append(SavedDetail.Row(kind: .jumpAutoChain, count: autoCount,
                                          savedSec: autoSaved))
        }
        return SavedDetail(rows: merged, baselineSec: baseline, baselineSamples: selfFound.count)
    }

    // MARK: 专注
    //
    // A stretch counts only when you were actually AT the machine for it (`active`) —
    // otherwise a terminal left in front overnight would be your best focus week ever.
    private static func focusDetail(_ visits: [Visit]) -> FocusDetail {
        let segs = visits.filter { $0.active }
        guard !segs.isEmpty else { return FocusDetail(segments: 0, avgSec: 0, longestSec: 0, longestAt: 0) }
        let total = segs.reduce(0) { $0 + $1.dwell }
        let longest = segs.max { $0.dwell < $1.dwell }!
        return FocusDetail(segments: segs.count, avgSec: total / segs.count,
                           longestSec: longest.dwell, longestAt: longest.ts)
    }

    // MARK: 托管

    private static func autoDetail(_ evs: [ImpactEvent]) -> AutoDetail {
        let chainTs = evs.filter { $0.kind == .jumpAutoChain }.map { $0.ts }
        let idle = evs.filter { $0.kind == .jumpAutoIdle }.count
        let blocked = evs.filter { $0.kind == .parkedBlock }.count
        // Longest run of chain jumps no further apart than chainGap — the 「最长 5 连」.
        // `prev` is Optional rather than a sentinel: Int.min here overflows on the first
        // subtraction and traps (Swift arithmetic is checked), which is a crash on the
        // very first auto-jump of a fresh log.
        var longest = 0, chainRun = 0
        var prev: Int?
        for ts in chainTs.sorted() {
            chainRun = (prev.map { ts - $0 <= ImpactRule.chainGap } ?? false) ? chainRun + 1 : 1
            longest = max(longest, chainRun)
            prev = ts
        }
        return AutoDetail(chain: chainTs.count, idle: idle, longestChain: longest, blocked: blocked)
    }

    // MARK: 掌控

    private static func controlDetail(_ evs: [ImpactEvent], responses: [Response]) -> ControlDetail {
        let live = evs.filter { $0.kind == .live }.compactMap { e -> (ts: Int, n: Int)? in
            e.n.map { (e.ts, $0) }
        }
        var peak = 0, peakAt = 0
        for l in live where l.n > peak { peak = l.n; peakAt = l.ts }
        let scored = responses.filter { $0.atDesk }.count
        return ControlDetail(peak: peak, peakAt: peakAt, p75: weightedP75(live),
                             stranded: responses.filter { $0.stranded }.count, scored: scored,
                             notifies: responses.count)
    }

    // `live` lines mark CHANGES, so each one owns the span until the next — the everyday
    // level has to be time-weighted or a 30-second spike to 8 would read as normal.
    private static func weightedP75(_ live: [(ts: Int, n: Int)]) -> Int {
        guard live.count > 1 else { return live.first?.n ?? 0 }
        var spans: [(n: Int, sec: Int)] = []
        for (i, l) in live.enumerated() where i + 1 < live.count {
            spans.append((l.n, max(0, live[i + 1].ts - l.ts)))
        }
        let total = spans.reduce(0) { $0 + $1.sec }
        guard total > 0 else { return live.map { $0.n }.max() ?? 0 }
        // Walk from the busiest level down until a quarter of the time is behind us.
        var acc = 0
        for s in spans.sorted(by: { $0.n > $1.n }) {
            acc += s.sec
            if acc * 4 >= total { return s.n }
        }
        return spans.map { $0.n }.max() ?? 0
    }

    // MARK: 效能分

    private static func score(responses: [Response], visits: [Visit],
                              control: ControlDetail) -> ImpactScore {
        // 有效到达 = you arrived on something that wanted you. Arrivals at a working
        // session are the wasted trips this app exists to remove.
        let effective = visits.filter { $0.status == "needs" || $0.status == "done" }.count
        let effRate = visits.isEmpty ? 0 : Double(effective) / Double(visits.count)
        let missRate = control.scored == 0 ? 1
            : 1 - Double(control.stranded) / Double(control.scored)
        let delays = responses.compactMap { $0.delay }
        let med = median(delays)
        return ImpactScore(arrivals: visits.count, effectiveRate: effRate,
                           zeroMissRate: max(0, missRate), speedScore: speedScore(med),
                           medianDelaySec: med)
    }

    // ≤15s → 100, ≥180s → 0, logarithmic in between: 15→30s is a far bigger regression
    // than 150→165s, and a linear map would call them equal.
    private static func speedScore(_ sec: Int) -> Double {
        guard sec > 0 else { return 0 }          // no measured delays = nothing to score
        if sec <= 15 { return 100 }
        if sec >= 180 { return 0 }
        return 100 * (1 - log(Double(sec) / 15) / log(12))
    }

    // MARK: 连续 (from the usage log, not this one)

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // Days on which any session ran at all — 「当天有任意会话跑起来就算」.
    private static func activeDays(_ usage: [UsageEvent]) -> Set<String> {
        Set(usage.filter { $0.event == "run" }.map { $0.date })
    }

    // Days counted back from `asOf`, stopping at the first gap. Today not being counted
    // yet does NOT break the run (it's still today) — but yesterday missing does.
    private static func streakLength(_ days: Set<String>, asOf: Date) -> Int {
        let cal = Calendar.current
        var n = 0
        var probe = cal.startOfDay(for: asOf)
        if !days.contains(dayFmt.string(from: probe)) {
            guard let y = cal.date(byAdding: .day, value: -1, to: probe) else { return 0 }
            probe = y
        }
        while days.contains(dayFmt.string(from: probe)) {
            n += 1
            guard let p = cal.date(byAdding: .day, value: -1, to: probe) else { break }
            probe = p
        }
        return n
    }

    private static func streak(usage: [UsageEvent], now: Date) -> Int {
        streakLength(activeDays(usage), asOf: now)
    }

    private static func usedToday(usage: [UsageEvent], now: Date) -> Bool {
        activeDays(usage).contains(dayFmt.string(from: Calendar.current.startOfDay(for: now)))
    }

    private static func streakStart(usage: [UsageEvent], now: Date) -> Int {
        let n = streak(usage: usage, now: now)
        guard n > 0 else { return 0 }
        let cal = Calendar.current
        let end = usedToday(usage: usage, now: now)
            ? cal.startOfDay(for: now)
            : cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        return Int((cal.date(byAdding: .day, value: -(n - 1), to: end) ?? end).timeIntervalSince1970)
    }

    // The streak as it stood at the END of each bucket — that's what makes a 23-day run
    // show as 23 in the period it peaked instead of being chopped into 7s.
    private static func streakByBucket(usage: [UsageEvent], buckets: Set<Int>,
                                       range: TimeRange, cal: Calendar) -> [Int: Int] {
        let days = activeDays(usage)
        var out: [Int: Int] = [:]
        for bs in buckets {
            let end = range == .all ? Date()
                : Date(timeIntervalSince1970: TimeInterval(range.bucketOffset(bs, by: 1, cal) - 1))
            out[bs] = streakLength(days, asOf: min(end, Date()))
        }
        return out
    }

    // MARK: Util

    // Lower median — with an even count the smaller middle wins, so a baseline built
    // from few samples never lands between two observed values (the user must be able
    // to point at the arrival their baseline came from).
    private static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[(s.count - 1) / 2]
    }
}
