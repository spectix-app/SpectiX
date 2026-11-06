import Cocoa

// MARK: - System scheduled jobs (launchd)
//
// The user's own launchd agents in ~/Library/LaunchAgents, listed next to scheduled
// quick actions on the drawer's "Scheduled" page. SpectiX can run one now, switch it
// off / on, and change when it runs. Switching off follows the convention already in
// use on this machine: unload, then rename to `<name>.plist.disabled`.
// launchctl is spawned, never linked: the binary still opens no socket.

struct LaunchJob: Equatable {
    enum Timing: Equatable {
        /// Fits a quick-action schedule; `interval` = StartInterval (counts from the
        /// last run, not on the clock).
        case schedule(QuickActionSchedule, interval: Bool)
        /// A StartCalendarInterval the schedule shapes can't express.
        case custom
        case keepAlive
        case atLogin
        case onDemand
    }

    let path: String
    let label: String
    let program: [String]
    let enabled: Bool
    let timing: Timing
    let logPath: String?
    /// Runs something from the user's own folders, not an app's updater or helper.
    let own: Bool

    /// "com.claude.daily-push" → "daily-push"
    var name: String {
        let parts = label.split(separator: ".")
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: ".") : label
    }

    var schedule: QuickActionSchedule? {
        if case .schedule(let s, _) = timing { return s }
        return nil
    }

    var editable: Bool {
        switch timing {
        case .schedule, .onDemand, .atLogin: return true
        case .custom, .keepAlive: return false
        }
    }
}

final class LaunchAgents {
    static let shared = LaunchAgents()
    static let didChange = Notification.Name("LaunchAgents.didChange")

    struct Status: Equatable {
        var pid: Int32?
        var lastExit: Int32?
    }

    private(set) var jobs: [LaunchJob] = []
    /// By label; missing = not loaded.
    private(set) var status: [String: Status] = [:]
    private var refreshing = false

    private static var dir: String { NSHomeDirectory() + "/Library/LaunchAgents" }
    private static var domain: String { "gui/\(getuid())" }
    private static let launchctl = "/bin/launchctl"

    /// Re-scan the folder and ask launchd what is loaded. Off the main thread; posts when done.
    func refresh() {
        if Demo.enabled {
            jobs = Demo.launchJobs
            status = Demo.launchStatus
            post()
            return
        }
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let jobs = Self.scan()
            let status = Self.loaded()
            DispatchQueue.main.async {
                self.refreshing = false
                self.jobs = jobs
                self.status = status
                self.post()
            }
        }
    }

    func lastRun(_ job: LaunchJob) -> Date? {
        guard let log = job.logPath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: log))?[.modificationDate] as? Date
    }

    func nextRun(_ job: LaunchJob) -> Date? {
        guard job.enabled, case .schedule(let s, let interval) = job.timing else { return nil }
        guard interval else { return s.next(after: Date()) }
        // launchd counts an interval from load / the last run; the log's mtime is the best guess.
        guard let last = lastRun(job), let n = s.every else { return nil }
        var next = last.addingTimeInterval(TimeInterval(n * 60))
        while next < Date() { next.addTimeInterval(TimeInterval(n * 60)) }
        return next
    }

    // MARK: Actions

    func runNow(_ job: LaunchJob) {
        guard !Demo.enabled, job.enabled else { return }
        perform {
            if self.status[job.label] == nil { Self.ctl(["bootstrap", Self.domain, job.path]) }
            Self.ctl(["kickstart", "\(Self.domain)/\(job.label)"])
        }
    }

    func setEnabled(_ job: LaunchJob, _ on: Bool) {
        guard !Demo.enabled, on != job.enabled else { return }
        let target = on ? String(job.path.dropLast(".disabled".count)) : job.path + ".disabled"
        perform {
            if !on { Self.ctl(["bootout", Self.domain, job.path]) }
            guard (try? FileManager.default.moveItem(atPath: job.path, toPath: target)) != nil else { return }
            if on { Self.ctl(["bootstrap", Self.domain, target]) }
        }
    }

    /// nil = no timing of its own (runs only when kicked). Rewrites just the timing keys,
    /// keeps everything else and the file's format, then reloads if it was loaded.
    @discardableResult
    func setSchedule(_ job: LaunchJob, _ schedule: QuickActionSchedule?) -> Bool {
        guard !Demo.enabled, job.editable,
              let data = FileManager.default.contents(atPath: job.path) else { return false }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)) as? [String: Any]
        else { return false }
        plist["StartInterval"] = nil
        plist["StartCalendarInterval"] = nil
        if let s = schedule {
            if let n = s.every { plist["StartInterval"] = n * 60 }
            else if let t = s.time {
                if let days = s.days, Set(days) != Set(1...7) {
                    plist["StartCalendarInterval"] = days.map { ["Hour": t.hour, "Minute": t.minute, "Weekday": $0 % 7] }
                } else {
                    plist["StartCalendarInterval"] = ["Hour": t.hour, "Minute": t.minute]
                }
            }
        }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0),
              (try? out.write(to: URL(fileURLWithPath: job.path), options: .atomic)) != nil else { return false }
        let wasLoaded = status[job.label] != nil
        perform {
            guard job.enabled, wasLoaded else { return }
            Self.ctl(["bootout", Self.domain, job.path])
            Self.ctl(["bootstrap", Self.domain, job.path])
        }
        return true
    }

    func revealInFinder(_ job: LaunchJob) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.path)])
    }

    // MARK: Reading

    private func perform(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @discardableResult
    private static func ctl(_ args: [String]) -> String? { QuickActionRunner.capture([launchctl] + args) }

    private static func scan() -> [LaunchJob] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { name -> LaunchJob? in
            let enabled = name.hasSuffix(".plist")
            guard enabled || name.hasSuffix(".plist.disabled") else { return nil }
            let path = dir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  let label = plist["Label"] as? String else { return nil }
            var program = plist["ProgramArguments"] as? [String] ?? []
            if let p = plist["Program"] as? String { program.insert(p, at: 0) }
            return LaunchJob(path: path, label: label, program: program, enabled: enabled,
                             timing: timing(plist), logPath: plist["StandardOutPath"] as? String,
                             own: isOwn(program))
        }
    }

    private static func timing(_ plist: [String: Any]) -> LaunchJob.Timing {
        if let ka = plist["KeepAlive"], (ka as? Bool) != false { return .keepAlive }
        if let secs = plist["StartInterval"] as? Int {
            return secs % 60 == 0 && secs / 60 >= QuickActionSchedule.minEvery
                ? .schedule(.everyMinutes(secs / 60), interval: true) : .custom
        }
        if let cal = plist["StartCalendarInterval"] {
            let entries = (cal as? [[String: Any]]) ?? [(cal as? [String: Any]) ?? [:]]
            return calendar(entries).map { .schedule($0, interval: false) } ?? .custom
        }
        return (plist["RunAtLoad"] as? Bool) == true ? .atLogin : .onDemand
    }

    /// Same Hour/Minute on every entry, optional Weekday each → a daily / weekly schedule.
    private static func calendar(_ entries: [[String: Any]]) -> QuickActionSchedule? {
        guard let first = entries.first, let h = first["Hour"] as? Int, let m = first["Minute"] as? Int else { return nil }
        var days: [Int] = []
        for e in entries {
            guard Set(e.keys).isSubset(of: ["Hour", "Minute", "Weekday"]),
                  e["Hour"] as? Int == h, e["Minute"] as? Int == m else { return nil }
            if let w = e["Weekday"] as? Int { days.append(w == 0 ? 7 : w) }
            else if entries.count > 1 { return nil }
        }
        return .daily(h, m, days: days.isEmpty ? nil : Array(Set(days)))
    }

    private static func isOwn(_ program: [String]) -> Bool {
        let home = NSHomeDirectory() + "/"
        return program.contains { $0.hasPrefix(home) && !$0.hasPrefix(home + "Library/") && !$0.contains(".app/") }
    }

    /// `launchctl list`: "PID\tStatus\tLabel", PID "-" when not running.
    private static func loaded() -> [String: Status] {
        var out: [String: Status] = [:]
        for line in (ctl(["list"]) ?? "").split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            out[String(f[2])] = Status(pid: Int32(f[0]), lastExit: Int32(f[1]))
        }
        return out
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: nil) }
}
