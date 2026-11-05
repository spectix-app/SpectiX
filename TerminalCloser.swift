import Cocoa

// Closes the terminal a session lives in (row right-click → 关闭终端).
//
// Every host ends the same way — the processes on the session's tty get hung up — and
// differs only in how the now-dead pane is removed:
//   • Terminal.app: a standalone window closes quietly over AppleScript; a tab inside a
//     tabbed window ignores that, so it needs Terminal frontmost, the tab selected, and
//     the ⌘W menu item pressed through AX (disabled while Terminal is in the background).
//     Processes are killed first so ⌘W never raises "terminate running processes?".
//   • iTerm: `close` works on a session directly.
//   • VS Code family: the companion extension disposes the terminal whose processId is
//     the shell pid (close-request, same broadcast as focus-request). An older extension
//     ignores the file, so the hang-up still ends the session.
//   • Anything else: hang-up only; the emulator decides what an exited shell looks like.
enum TerminalCloser {
    private static let dataDir = "\(NSHomeDirectory())/.claude/spectix"
    private static var requestSeq = 0

    static func canClose(_ row: SessionRow) -> Bool {
        !Demo.enabled && !row.isDesktop && !row.isChatPanel && !row.tty.isEmpty
    }

    static func close(_ row: SessionRow) {
        if row.editor != nil { requestEditorClose(shellPid: row.shellPid) }
        let tty = row.tty, app = row.terminalApp
        DispatchQueue.global(qos: .userInitiated).async {
            // Located while the shell is alive: Terminal's dead tabs keep reporting their
            // old tty, and a recycled tty would otherwise match one of them.
            let tab = app == .terminal ? locateTerminalTab(tty: tty) : nil
            if row.editor != nil { Thread.sleep(forTimeInterval: 0.5) }
            hangUp(tty: tty)
            switch app {
            case .terminal?: if let tab { closeTerminalTab(window: tab) }
            case .iterm?:    closeITermSession(tty: tty)
            case nil:        break
            }
        }
    }

    private static func requestEditorClose(shellPid: pid_t) {
        requestSeq += 1
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try? "\(shellPid):\(requestSeq)".write(
            toFile: "\(dataDir)/close-request", atomically: true, encoding: .utf8)
    }

    // HUP everything on the tty, then KILL whatever ignored it (an interactive zsh and
    // `login` both shrug off HUP).
    private static func hangUp(tty: String) {
        signalAll(on: tty, SIGHUP)
        for _ in 0..<10 {
            if processes(on: tty).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        signalAll(on: tty, SIGKILL)
    }

    private static func signalAll(on tty: String, _ sig: Int32) {
        for pid in processes(on: tty) { kill(pid, sig) }
    }

    // Asked of the kernel directly: `pkill -t` / `pgrep -t` match nothing on macOS 26.
    private static func processes(on tty: String) -> [pid_t] {
        var st = stat()
        guard stat("/dev/\(tty)", &st) == 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, st.st_rdev]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }
    }

    // Terminal's AppleScript sees every tab as its own window, so the window id names the tab.
    private static func locateTerminalTab(tty: String) -> Int? {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" and (count of processes of t) > 0 then return id of w
                end repeat
            end repeat
        end tell
        """
        return spawnCapturing(["/usr/bin/osascript", "-e", script]).flatMap { Int($0) }
    }

    // `close window` removes a standalone window but does nothing to a tab of a tabbed
    // window; that one needs Terminal frontmost and ⌘W.
    private static func closeTerminalTab(window id: Int) {
        let script = """
        tell application "Terminal"
            close window id \(id)
            delay 0.3
            if not (exists window id \(id)) then return "closed"
            if not (visible of window id \(id)) then return "closed"
            set w to window id \(id)
            set selected of tab 1 of w to true
            set index of w to 1
            activate
        end tell
        """
        guard spawnCapturing(["/usr/bin/osascript", "-e", script]) != "closed",
              let pid = NSRunningApplication.runningApplications(
                  withBundleIdentifier: TerminalApp.terminal.rawValue).first?.processIdentifier
        else { return }
        // Activation is async; the ⌘W item turns enabled once Terminal is frontmost.
        for _ in 0..<15 {
            if pressMenuItem(pid: pid, cmdChar: "W") { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func closeITermSession(tty: String) {
        spawn(["/usr/bin/osascript", "-e", """
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "/dev/\(tty)" then
                                close s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """])
    }

    // Presses the enabled menu item bound to ⌘<cmdChar> (no other modifiers). Matching the
    // shortcut instead of the title keeps it working in every UI language.
    private static func pressMenuItem(pid: pid_t, cmdChar: String) -> Bool {
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(e, a as CFString, &v)
            return v
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        guard let bar = attr(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return false }
        for top in kids(bar as! AXUIElement) {
            for menu in kids(top) {
                for item in kids(menu)
                where attr(item, kAXMenuItemCmdCharAttribute) as? String == cmdChar
                    && attr(item, kAXMenuItemCmdModifiersAttribute) as? Int == 0 {
                    guard attr(item, kAXEnabledAttribute) as? Bool == true else { return false }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    // Not disclaimed: osascript's Automation grant must stay keyed to SpectiX (docs/permissions.md).
    @discardableResult
    private static func spawn(_ argv: [String]) -> Int32 {
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], nil, nil, &cargv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    private static func spawnCapturing(_ argv: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
