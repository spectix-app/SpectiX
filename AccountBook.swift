import Foundation

// The accounts each agent CLI has been seen signed in as, and how to put one back.
//
// ★ "Switch" = put that account's stored credential back as the CLI's live one
// (CredentialVault), so every CLI opened afterwards — any terminal, any editor — is
// on it, with no sign-in. The copy is taken the first time an address is seen and
// again whenever the user switches away from it. When there is no copy, or the CLI
// rejects a stale one, the fallback is the CLI's own login with the address
// pre-filled — the same thing the user did by hand before this existed.
//
// ★ Why not one config directory per account (CLAUDE_CONFIG_DIR / CODEX_HOME): that
// was the first version, measured 2026-08-30 to 09-02. It does isolate the
// credential — but it isolates EVERYTHING in that directory with it: settings,
// hooks, skills, memory, and this app's own status hook, so a session on the
// second account ran with an empty setup and was invisible here. And it only ever
// reached the one terminal this app opened; a `claude` typed into VS Code stayed on
// the old account.
//
// The book lives in this app's state directory, never the CLI's, and holds no
// secret: address, name, plan, id — the fields the header already shows — plus,
// for Claude, the `oauthAccount` block from ~/.claude.json (same fields, the CLI's
// own layout) so a switch can put that back too.

/// What the quota figures were last time this account was the live one.
///
/// ★ Only the signed-in account ever has CURRENT figures. Both CLIs report the
/// account they are signed in as and no other — `claude -p /usage` asks the default
/// config, and Codex's rate limits come out of the rollout the running session
/// writes. So for every other row this is a reading with a timestamp on it, and the
/// UI has to say so.
///
/// The one thing that stays true after the fact is `*ResetsAt`: once that instant is
/// past, the window is known to be full again without asking anyone. That is the
/// whole basis for telling a user "you can switch to this one now".
///
/// ★ The exception (2026-09-04): a Claude account with a stored credential copy can
/// be ASKED — its access token goes to Anthropic's usage endpoint, on the user's
/// press of the panel's refresh button, and the answer is current for that exact
/// address. Such a reading carries `probed = true`, which is what lets the row show
/// it as live even though the account is not signed in.
struct AccountUsage: Codable, Equatable {
    var sessionPct: Int?
    var weekPct: Int?
    var sessionResetsAt: Double?
    var weekResetsAt: Double?
    /// When the percentages were read.
    var readAt: Double
    /// True when the figures came from the usage endpoint for this address rather
    /// than from the signed-in CLI. Optional so older books keep decoding.
    var probed: Bool? = nil
}

struct RememberedAccount: Codable, Equatable {
    var email: String
    var displayName: String?
    var plan: String?
    var accountID: String?
    /// Unix time this address was last the signed-in one. Bookkeeping only — it
    /// does NOT order the list.
    var lastSeen: Double
    /// Unix time this address was FIRST seen. This is what orders the list, so a
    /// switch never reshuffles the rows under the click that made it: the row the
    /// user aimed at is still the row they aimed at afterwards. Optional because
    /// books written before this field existed have to keep decoding.
    var addedAt: Double? = nil
    /// Claude only: the CLI's own `oauthAccount` object, verbatim JSON, written back
    /// into ~/.claude.json on a switch so the CLI shows the right account itself.
    var oauthAccountJSON: String?
    /// Last known quota, and when. Current only for whichever account is signed in.
    var usage: AccountUsage?
}

enum AccountBook {
    static let dir = "\(NSHomeDirectory())/.claude/spectix"

    /// How long a figure fetched from the usage endpoint counts as live. A five-hour
    /// window moves slowly enough that ten minutes is honest; past that the reading
    /// steps back to the dimmed "N ago" one like any other remembered figure.
    ///
    /// ★ Lives here rather than on the panel that first needed it: the header reads
    /// it too (a just-switched account's card asks the same question), and "when does
    /// a reading stop being current" is a fact about the reading, not about a view.
    static let probeFreshFor: Double = 10 * 60

    private static var cache: [AgentKind: [RememberedAccount]] = [:]
    /// Addresses with a usage request in flight. The panel keeps its own count for
    /// its button, but the header needs this too and the panel may already be closed
    /// while the request is still out — so the fact of "we are asking" lives with the
    /// data, in one place, and both views read it.
    ///
    /// Main-thread only: every entry is added by the click that starts the request
    /// and removed by the completion, which probeUsage hops back to main to run.
    private static var probing: [AgentKind: Set<String>] = [:]
    static func isProbing(_ kind: AgentKind, email: String) -> Bool {
        probing[kind]?.contains(email) ?? false
    }
    /// Posted when a request starts or lands. The header redraws on it instead of
    /// waiting out its 2.5s poll — the request exists to make a switch look immediate,
    /// and a poll's worth of lag on either end is most of what it bought.
    static let quotaDidChange = Notification.Name("SpectiXAccountQuotaDidChange")
    /// When each CLI last had its account switched by us. ★ A quota reading taken
    /// before that instant belongs to the account we LEFT — `claude -p /usage` and
    /// Codex's rollouts both describe whoever was signed in when they ran, and
    /// neither carries an address to check against. Filing such a reading under the
    /// new account is how the panel ends up showing one account's numbers on
    /// another's row, so the timestamp is the guard.
    private static var switchedAt: [AgentKind: Double] = [:]
    static func lastSwitch(_ kind: AgentKind) -> Double { switchedAt[kind] ?? 0 }
    private static func path(_ kind: AgentKind) -> String {
        "\(dir)/accounts-\(kind.rawValue).json"
    }

    /// Every address seen signed in on this CLI, oldest first and FIXED in that
    /// order. Books from before `addedAt` existed fall back to lastSeen, which
    /// note() backfills on the next refresh.
    static func list(_ kind: AgentKind) -> [RememberedAccount] {
        if let c = cache[kind] { return c }
        var loaded = (try? Data(contentsOf: URL(fileURLWithPath: path(kind))))
            .flatMap { try? JSONDecoder().decode([RememberedAccount].self, from: $0) } ?? []
        let needsPinning = loaded.contains { $0.addedAt == nil }
        loaded.sort { ($0.addedAt ?? $0.lastSeen) < ($1.addedAt ?? $1.lastSeen) }
        guard needsPinning else { cache[kind] = loaded; return loaded }
        // Pin the position of every legacy row on first read. Waiting for note() to
        // do it wouldn't work: note() only ever sees the CURRENT account, so a row
        // for any other address would keep falling back to lastSeen — which switchTo
        // moves, taking the row with it.
        for i in loaded.indices where loaded[i].addedAt == nil { loaded[i].addedAt = loaded[i].lastSeen }
        save(kind, loaded)
        return loaded
    }

    /// Fed the default config's account on every refresh. Nothing is written unless
    /// the address is new or its details changed — the common tick costs one compare.
    ///
    /// ★ This function does NOT touch a credential, and must not start: the ONLY
    /// moment the vault takes a copy is the user's own click on another account
    /// (switchTo, which copies the account being left before restoring the target).
    /// It used to also copy whenever a new address appeared, and top the current one
    /// up at launch — both were a Keychain password prompt in the face of someone who
    /// had installed the app five seconds ago and asked for nothing. The cost of not
    /// doing it is one sign-in, once, for an account the user has never switched away
    /// from; the row says so before they click.
    static func note(_ kind: AgentKind, _ account: AgentAccount?) {
        guard let account, let email = account.email else { return }
        var book = list(kind)
        var entry = RememberedAccount(email: email,
                                      displayName: account.displayName,
                                      plan: account.plan,
                                      accountID: account.accountID,
                                      lastSeen: Date().timeIntervalSince1970,
                                      oauthAccountJSON: nil)
        if let i = book.firstIndex(where: { $0.email == email }) {
            // Known address with the same details: nothing to record. Only lastSeen
            // would move, and that is not worth a write per second.
            var same = book[i]; same.lastSeen = entry.lastSeen
            entry.oauthAccountJSON = same.oauthAccountJSON
            // Inherit the position key rather than minting a new one — updating a row
            // must never move it. A book from before the field existed gets it
            // backfilled here, once.
            entry.addedAt = same.addedAt ?? same.lastSeen
            // Carried over, not re-derived: without this the ~1 Hz caller would find
            // a difference every tick and write the book to disk every tick.
            entry.usage = same.usage
            if same == entry { return }
            if kind == .claude { entry.oauthAccountJSON = claudeOAuthAccountJSON() ?? entry.oauthAccountJSON }
            book[i] = entry
        } else {
            entry.addedAt = Date().timeIntervalSince1970
            if kind == .claude { entry.oauthAccountJSON = claudeOAuthAccountJSON() ?? entry.oauthAccountJSON }
            book.append(entry)
        }
        save(kind, book)
    }

    /// File the live quota figures against the account they actually belong to —
    /// which is always the signed-in one; see `AccountUsage`. Called from the same
    /// ~1 Hz path as note(), so it writes only when a number really moved.
    static func noteUsage(_ kind: AgentKind, email: String?, _ u: UsageSnapshot?) {
        guard let email, let u, u.sessionPct != nil || u.weekPct != nil else { return }
        // Measured before the switch, so it describes the previous account. Drop it
        // and wait for the re-probe; the row meanwhile shows its OWN last snapshot,
        // which is old but at least true of the account it sits on.
        guard u.updatedAt > lastSwitch(kind) else { return }
        var book = list(kind)
        guard let i = book.firstIndex(where: { $0.email == email }) else { return }
        let fresh = AccountUsage(sessionPct: u.sessionPct,
                                 weekPct: u.weekPct,
                                 sessionResetsAt: u.sessionResetsAt,
                                 weekResetsAt: u.weekResetsAt,
                                 readAt: Date().timeIntervalSince1970)
        // readAt moves every tick by definition, so compare everything else.
        if var old = book[i].usage {
            old.readAt = fresh.readAt
            if old == fresh { return }
        }
        book[i].usage = fresh
        save(kind, book)
    }

    /// Ask Anthropic for the current figures of a REMEMBERED Claude account, through
    /// the access token in its stored copy. Runs the request off the main thread and
    /// files the answer on it; `done(true)` means the row now holds a live reading.
    ///
    /// ★ Only ever called from a press of the user's own: the panel's refresh button,
    /// or the click on another account that switches to it. Never from a timer, never
    /// on open. That is the whole of the opt-in the network promise asks for (LICENSE
    /// §4), and it keeps the token spend to one request per press per account.
    ///
    /// ★ The switch case (2026-09-09) asks about the account that just BECAME the live
    /// one, which is the one case where the answer is about to arrive by another route
    /// anyway — `claude -p /usage` re-probes within seconds. It is worth a request
    /// because those seconds are the whole problem: measured end to end, the CLI probe
    /// takes 5.1s and sits behind a throttle window of up to 15s, and until it lands
    /// the header has nothing current to draw for the account the user just picked.
    static func probeUsage(_ kind: AgentKind, email: String, done: @escaping (Bool) -> Void) {
        probing[kind, default: []].insert(email)
        NotificationCenter.default.post(name: quotaDidChange, object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let reading = CredentialVault.usageResponse(kind, email: email).flatMap(parseUsageBody)
            DispatchQueue.main.async {
                probing[kind]?.remove(email)
                // Every exit from here changes what the header should draw — a filed
                // reading, or merely the spinner going away on a refusal.
                defer { NotificationCenter.default.post(name: quotaDidChange, object: nil) }
                guard let reading else { done(false); return }
                var book = list(kind)
                guard let i = book.firstIndex(where: { $0.email == email }) else { done(false); return }
                book[i].usage = reading
                save(kind, book)
                done(true)
            }
        }
    }

    /// `{five_hour: {utilization, resets_at}, seven_day: {...}}` → a reading stamped
    /// now. Pure, so it can be checked against a canned body.
    static func parseUsageBody(_ body: Data) -> AccountUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = root["five_hour"] as? [String: Any]
        else { return nil }
        let week = root["seven_day"] as? [String: Any]
        func pct(_ w: [String: Any]?) -> Int? {
            switch w?["utilization"] {
            case let n as Int: return n
            case let n as Double: return Int(n.rounded())
            default: return nil
            }
        }
        func resets(_ w: [String: Any]?) -> Double? {
            switch w?["resets_at"] {
            case let s as String:
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return (f.date(from: s) ?? ISO8601DateFormatter().date(from: s))?.timeIntervalSince1970
            case let n as Double: return n
            case let n as Int: return Double(n)
            default: return nil
            }
        }
        guard let s = pct(session) else { return nil }
        return AccountUsage(sessionPct: s,
                            weekPct: pct(week),
                            sessionResetsAt: resets(session),
                            weekResetsAt: resets(week),
                            readAt: Date().timeIntervalSince1970,
                            probed: true)
    }

    /// Drop the address and the credential copy behind it. The CLI's own sign-in is
    /// untouched.
    static func forget(_ kind: AgentKind, email: String) {
        let book = list(kind).filter { $0.email != email }
        save(kind, book)
        CredentialVault.forget(kind, email: email)
    }

    /// Make `email` the CLI's live account from its stored copy. False = no usable
    /// copy; the caller falls back to switchCommand. The account being left is
    /// re-captured first so its rotated tokens aren't lost.
    static func switchTo(_ kind: AgentKind, email: String) -> Bool {
        let current = kind == .claude ? AgentAccounts.claude() : AgentAccounts.codex()
        if let cur = current?.email, cur != email {
            CredentialVault.capture(kind, email: cur)
        }
        guard CredentialVault.restore(kind, email: email) else { return false }
        if kind == .claude,
           let json = list(kind).first(where: { $0.email == email })?.oauthAccountJSON {
            writeClaudeOAuthAccount(json)
        }
        switchedAt[kind] = Date().timeIntervalSince1970
        // Bookkeeping only. The row deliberately stays put: the panel rebuilds
        // straight after this, and a list that reordered itself under the click would
        // leave the pointer hovering a different account than the one just picked.
        var book = list(kind)
        if let i = book.firstIndex(where: { $0.email == email }) {
            book[i].lastSeen = Date().timeIntervalSince1970
            save(kind, book)
        }
        return true
    }

    // MARK: ~/.claude.json oauthAccount

    private static let claudeConfig = "\(NSHomeDirectory())/.claude.json"

    private static func claudeOAuthAccountJSON() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeConfig)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = root["oauthAccount"],
              let out = try? JSONSerialization.data(withJSONObject: acct)
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// Read-modify-write of the CLI's config with only `oauthAccount` replaced. The
    /// CLI rewrites this file itself on its own schedule; the window here is one read
    /// and one atomic write, on a user click.
    private static func writeClaudeOAuthAccount(_ json: String) {
        guard let acct = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? Data(contentsOf: URL(fileURLWithPath: claudeConfig)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        root["oauthAccount"] = acct
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? out.write(to: URL(fileURLWithPath: claudeConfig), options: .atomic)
    }

    private static func save(_ kind: AgentKind, _ book: [RememberedAccount]) {
        cache[kind] = book
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) {
            try? data.write(to: URL(fileURLWithPath: path(kind)), options: .atomic)
        }
    }

    /// The fallback when no stored copy can be put back: the CLI's own sign-in, with
    /// the address pre-filled where the CLI allows it. codex-cli 0.151 has no such
    /// flag; its page is where the user picks.
    static func switchCommand(_ kind: AgentKind, email: String) -> String {
        switch kind {
        case .claude: return "claude auth login --email \(shellQuote(email))"
        case .codex:  return "codex login"
        }
    }

    /// Sign in as someone not in the book yet. Same command, no address.
    static func addCommand(_ kind: AgentKind) -> String {
        kind == .claude ? "claude auth login" : "codex login"
    }

    /// Single-quote for /bin/sh, escaping embedded quotes the only way sh allows.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
