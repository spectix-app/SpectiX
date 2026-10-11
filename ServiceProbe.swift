import Cocoa

// T336 — tell a long-lived SERVER apart from an ordinary background command.
//
// Both are a Bash-tool command shell that outlives its turn, so the process tree alone
// can't separate `python3 -m http.server` from `npm test`. What does: a server LISTENS
// on a TCP port. That is read straight from the kernel's per-process fd table (libproc
// PROC_PIDFDSOCKETINFO) — a local read of our own user's processes, no socket of our own
// and no network API, so the no-network gate in build.sh is untouched. (Mind that gate
// when editing here: it greps for `socket` immediately followed by an open paren.)
//
// The port sits on a DESCENDANT, never on the shell: `zsh -c '… python3 -m http.server'`
// owns no sockets, its python child does; `npm run dev` puts it two levels further down
// (npm → sh → node). Hence the bounded tree walk below.
enum ServiceProbe {

    struct Found {
        var ports: [Int]
        var kind: String
        var pids: [pid_t]
        var root: String?     // the folder a `python3 -m http.server` serves; nil otherwise
    }

    // nil when nothing under `shell` listens — an ordinary background command.
    static func scan(shell: pid_t,
                     children: (pid_t) -> [pid_t],
                     args: (pid_t) -> [String]) -> Found? {
        var listeners: [(pid: pid_t, ports: [Int])] = []
        // Bounded: a runaway tree (a test runner forking workers) must not turn the 2.5s
        // refresh into a crawl. Real dev servers sit within 3–4 levels.
        var frontier = children(shell)
        let direct = frontier
        var seen = 0
        for _ in 0..<6 {
            var next: [pid_t] = []
            for p in frontier {
                seen += 1
                if seen > 64 { break }
                let ports = listeningPorts(p)
                if !ports.isEmpty { listeners.append((p, ports)) }
                next += children(p)
            }
            if seen > 64 { break }
            frontier = next
        }
        guard !listeners.isEmpty else { return nil }
        let ports = Array(Set(listeners.flatMap(\.ports))).sorted()
        return Found(ports: ports,
                     kind: kind(of: listeners.map(\.pid) + direct, args: args),
                     pids: Array(Set(listeners.map(\.pid) + direct)),
                     root: listeners.compactMap { servedRoot($0.pid, args: args($0.pid)) }.first)
    }

    // Only Python's http.server: it serves its cwd unless `-d/--directory` says otherwise.
    // `serve dist` / `http-server ./public` take a positional folder that's easy to misread,
    // and a wrong root would make 打开 land on a 404 instead of the old directory listing.
    private static func servedRoot(_ pid: pid_t, args: [String]) -> String? {
        guard let m = args.firstIndex(of: "-m"), args.indices.contains(m + 1),
              args[m + 1] == "http.server", let cwd = cwd(of: pid) else { return nil }
        var dir: String?
        // Only flags after the module: `python3 -d -m http.server` is Python's own debug -d.
        for (i, a) in args.enumerated() where i > m + 1 {
            if a.hasPrefix("--directory=") { dir = String(a.dropFirst("--directory=".count)) }
            else if (a == "-d" || a == "--directory"), args.indices.contains(i + 1) { dir = args[i + 1] }
        }
        guard let d = dir else { return cwd }
        return d.hasPrefix("/") ? d : (cwd as NSString).appendingPathComponent(d)
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // TCP ports `pid` is listening on. Empty for anything we can't read (another user's
    // process, a pid that just exited) — never guess a server into existence.
    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sz > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sz) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, sz)
        guard got > 0 else { return [] }
        var out = Set<Int>()
        let want = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, want) == want,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport holds the port in network byte order in its low 16 bits.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            out.insert(port)
        }
        return out.sorted()
    }

    // A human name for what's serving. Recognised dev servers by name; anything else
    // falls back to the listening binary's own name rather than a guess.
    private static func kind(of pids: [pid_t], args: (pid_t) -> [String]) -> String {
        let all = pids.flatMap(args)
        let words = all.flatMap { $0.lowercased().split(whereSeparator: { " /=".contains($0) }) }.map(String.init)
        let has = { (w: String) in words.contains(w) }
        if has("expo") { return "Expo" }
        if has("vite") { return "Vite" }
        if has("next") { return "Next.js" }
        if has("astro") { return "Astro" }
        if has("webpack") || has("webpack-dev-server") { return "Webpack" }
        if has("storybook") { return "Storybook" }
        if has("http.server") || has("serve") || has("http-server") { return L("静态网页", "Static site") }
        let bin = (pids.first.flatMap { args($0).first } ?? "") as NSString
        return bin.lastPathComponent.isEmpty ? L("服务", "Server") : bin.lastPathComponent
    }

    // 停止: SIGTERM the listeners and the command's root, then SIGKILL whatever is still
    // up a moment later (a dev server that traps TERM to "gracefully" shut down sometimes
    // never does). The owning shell then exits on its own — its command is gone — which
    // is also what Claude Code's background-task bookkeeping waits for.
    static func stop(_ s: ServiceInfo) {
        if Demo.enabled { Demo.stoppedPorts.insert(s.port); return }
        for p in s.pids where p > 1 { kill(p, SIGTERM) }
        let pids = s.pids
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for p in pids where p > 1 { kill(p, SIGKILL) }
        }
    }

    static func open(_ s: ServiceInfo) {
        // A demo port has nothing listening; the browser would film an error page.
        if Demo.enabled { return }
        guard let url = URL(string: "http://localhost:\(s.port)/\(page(in: s.root))") else { return }
        NSWorkspace.shared.open(url)
    }

    // A static server with no index page answers `/` with a bare file listing. Open a page
    // instead — the most recently written one, since that's the mockup Claude just served.
    // Read at click time, so a page written after the scan still counts.
    static func page(in root: String?) -> String {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return "" }
        if names.contains(where: { ["index.html", "index.htm"].contains($0.lowercased()) }) { return "" }
        let newest = names.filter { $0.lowercased().hasSuffix(".html") || $0.lowercased().hasSuffix(".htm") }
                          .map { n -> (String, Date) in
                              let attrs = try? FileManager.default.attributesOfItem(atPath: (root as NSString).appendingPathComponent(n))
                              return (n, attrs?[.modificationDate] as? Date ?? .distantPast)
                          }
                          .max { $0.1 < $1.1 }?.0
        return newest?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    }
}
