import Foundation

// MARK: - Which account each agent CLI is signed in as
//
// Read-only identity for the two agents this app tracks, taken from the config
// files the CLIs already keep in the user's home. Nothing here writes, spawns a
// process, or touches the Keychain — the whole point is that `otool -L` and a
// firewall keep telling the same story the license does.
//
// API:
//
//     AgentAccounts.claude(configDir:) -> AgentAccount?   nil = not signed in
//     AgentAccounts.codex(codexHome:)  -> AgentAccount?
//
// Both arguments default to nil = the standard location (~/.claude.json,
// ~/.codex). Passing a directory reads that profile instead, which is the hook
// a per-session CLAUDE_CONFIG_DIR / CODEX_HOME override will need later.
//
// ── Credentials are not read HERE ───────────────────────────────────────────
// ~/.codex/auth.json holds real secrets next to the identity fields: the
// wire structs below name `account_id` and `id_token` and nothing else, so the
// bearer/refresh secrets and the API key in that file are never bound to a
// variable in this file, never logged, and never returned. ~/.claude.json
// carries no secret at all (Claude Code keeps its token in the Keychain).
// The one place that does handle those secrets — copying them so the user can
// switch accounts without signing in again — is CredentialVault.swift, and it
// treats them as opaque blobs.
//
// The one token that IS touched is `id_token`, and only to split off its middle
// segment: a JWT payload is plain base64url JSON, and it is the only place the
// Codex email / plan exists on disk. The signature is not verified — this is
// the user's own machine describing itself, not an authentication decision —
// and the token string is dropped with the frame.

struct AgentAccount {
    var email: String?
    var displayName: String?
    var plan: String?          // short label, see planLabel below
    var organization: String?
    var accountID: String?

    var isEmpty: Bool {
        email == nil && displayName == nil && plan == nil
            && organization == nil && accountID == nil
    }
}

enum AgentAccounts {

    static func claude(configDir: String? = nil) -> AgentAccount? {
        let dir = configDir ?? NSHomeDirectory()
        return read("\(dir)/.claude.json") { data in
            guard let root = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
                return .torn
            }
            // Parsed fine but no oauthAccount: that IS the signed-out state (the
            // file keeps existing for project history and settings), so it must
            // overwrite a remembered account rather than be held onto.
            guard let a = root.oauthAccount else { return .ok(nil) }
            let acc = AgentAccount(
                email: nonEmpty(a.emailAddress),
                displayName: nonEmpty(a.displayName) ?? nonEmpty(a.fullName),
                plan: claudePlan(type: a.organizationType, tier: a.organizationRateLimitTier),
                // Personal accounts get an auto-generated "<email>'s Organization"
                // here; a caller showing both should drop the one that just echoes
                // the address.
                organization: nonEmpty(a.organizationName),
                accountID: nonEmpty(a.accountUuid))
            return .ok(acc.isEmpty ? nil : acc)
        }
    }

    static func codex(codexHome: String? = nil) -> AgentAccount? {
        let dir = codexHome ?? "\(NSHomeDirectory())/.codex"
        return read("\(dir)/auth.json") { data in
            guard let root = try? JSONDecoder().decode(CodexAuth.self, from: data) else {
                return .torn
            }
            // API-key mode leaves `tokens` null: signed in, but with no identity to
            // show. Reported as signed out because every field would be nil anyway.
            guard let t = root.tokens else { return .ok(nil) }
            let claims = t.id_token.flatMap(jwtPayload)
            let openai = claims?.openaiAuth
            let acc = AgentAccount(
                email: nonEmpty(claims?.email),
                displayName: nonEmpty(claims?.name),
                plan: planLabel(openai?.chatgpt_plan_type),
                organization: nil,   // the claim carries an org list; no shape to show it yet
                accountID: nonEmpty(t.account_id) ?? nonEmpty(openai?.chatgpt_account_id))
            return .ok(acc.isEmpty ? nil : acc)
        }
    }

    // MARK: - Plan labels
    //
    // Kept to 8 characters or fewer: these land in the narrow trailing slot of a
    // session row, beside the email, where anything longer would either push the
    // address out or wrap the row. "Max 20x" (7) is the widest real value seen.
    //
    // The mapping is mechanical rather than a lookup table, because the tier
    // strings are Anthropic's and change without notice: an unrecognized value
    // comes back as-is instead of empty, and a caller that cannot fit it clips it.
    // A truncated true label beats a confident wrong one.

    /// "claude_max" + "default_claude_max_20x" -> "Max 20x"
    private static func claudePlan(type: String?, tier: String?) -> String? {
        let family = planLabel((type ?? "").replacingOccurrences(of: "claude_", with: ""))
        guard let family else { return nonEmpty(tier) }
        // The tier only contributes the "20x"-shaped multiplier; the rest of it
        // ("default_claude_max_") repeats what `type` already said.
        let mult = (tier ?? "").lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .last(where: { $0.count > 1 && $0.hasSuffix("x")
                        && $0.dropLast().allSatisfy(\.isNumber) })
        return mult.map { "\(family) \($0)" } ?? family
    }

    /// "plus" -> "Plus". Codex's chatgpt_plan_type is already one short word.
    private static func planLabel(_ raw: String?) -> String? {
        guard let s = nonEmpty(raw)?.replacingOccurrences(of: "_", with: " ") else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - JWT payload
    //
    // Only segment 1. base64url has to be translated to the standard alphabet and
    // re-padded before Foundation will decode it; JWTs are written unpadded.
    private static func jwtPayload(_ token: String) -> CodexClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(CodexClaims.self, from: data)
    }

    // MARK: - Read + cache
    //
    // Two things this has to survive, both measured against the real files:
    //
    //  1. Both CLIs rewrite these configs with the usual write-temp-then-rename
    //     (~/.codex/auth.json gets one on every token refresh, visible as a moving
    //     `last_refresh`). A poll that lands inside that window reads bytes that
    //     don't parse — which is NOT the same fact as "signed out", and conflating
    //     the two makes an account blink out of the UI at random. So: file absent
    //     -> nil and the memory is cleared; file present but unusable -> the last
    //     value that DID parse stands, and the next poll retries.
    //     The stat/read/stat sandwich catches the narrower race where the rename
    //     lands between the stat and the read: the content would then not match the
    //     signature it'd be cached under, so it's treated as a torn read too.
    //
    //  2. This is called from the ~1 Hz refresh path. Re-decoding ~/.claude.json
    //     costs 0.19-0.22 ms there (83,808 bytes, 84 top-level keys, swiftc -O) —
    //     small, but paid for nothing 99% of the time, since the file changes at
    //     human speed. Foundation has no streaming JSON parser, so a full decode is
    //     the only option and mtime+size is what makes it rare.

    private enum Parsed {
        case ok(AgentAccount?)   // the file was readable and complete
        case torn                // unusable bytes; say nothing new about the account
    }

    private struct Signature: Equatable {
        let mtime: timespec
        let size: Int64

        static func == (a: Signature, b: Signature) -> Bool {
            a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec
                && a.mtime.tv_nsec == b.mtime.tv_nsec
        }
    }

    private struct Entry {
        var sig: Signature
        var value: AgentAccount?
    }

    // Both accessors can run off the scan queue and the main thread.
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    private static func read(_ path: String, _ parse: (Data) -> Parsed) -> AgentAccount? {
        guard let before = signature(path) else {
            forget(path)          // no file = signed out, and a stale value must not linger
            return nil
        }
        lock.lock()
        let hit = entries[path]
        lock.unlock()
        if let hit, hit.sig == before { return hit.value }

        guard let data = FileManager.default.contents(atPath: path),
              let after = signature(path), after == before else { return remembered(path) }

        switch parse(data) {
        case .torn:
            return remembered(path)
        case .ok(let account):
            lock.lock()
            entries[path] = Entry(sig: before, value: account)
            lock.unlock()
            return account
        }
    }

    private static func signature(_ path: String) -> Signature? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Signature(mtime: st.st_mtimespec, size: st.st_size)
    }

    private static func remembered(_ path: String) -> AgentAccount? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]?.value
    }

    private static func forget(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = nil
    }
}

// MARK: - Wire format
//
// Field names match the JSON so the shapes read like the files. Everything is
// optional: one type surprise must not cost the whole account, and both files
// carry keys that only exist for some plans (a personal account has no
// organizationRateLimitTier, API-key Codex has no tokens block).

private struct ClaudeConfig: Decodable {
    struct OAuthAccount: Decodable {
        let emailAddress: String?
        let displayName: String?
        let fullName: String?
        let organizationName: String?
        let organizationType: String?           // e.g. "claude_max"
        let organizationRateLimitTier: String?  // e.g. "default_claude_max_20x"
        let accountUuid: String?
    }
    let oauthAccount: OAuthAccount?
}

// Names exactly two of auth.json's fields on purpose — see the credential note at
// the top of the file. `access_token`, `refresh_token` and `OPENAI_API_KEY` are
// the ones being left out, and nothing below may grow a case for them.
private struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let account_id: String?
        let id_token: String?
    }
    let tokens: Tokens?
}

private struct CodexClaims: Decodable {
    struct OpenAIAuth: Decodable {
        let chatgpt_plan_type: String?    // e.g. "plus"
        let chatgpt_account_id: String?
    }
    let email: String?
    let name: String?
    let openaiAuth: OpenAIAuth?

    // The claim key is the URL "https://api.openai.com/auth", which no Swift
    // property name can spell.
    private enum CodingKeys: String, CodingKey {
        case email, name
        case openaiAuth = "https://api.openai.com/auth"
    }
}
