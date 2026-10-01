import Foundation
import Security

// Stored copies of each CLI's sign-in credential, so switching accounts is one click
// instead of a sign-in every time.
//
// ★ This file is the ONE place the app handles a secret, and it exists because the
// user decided (2026-09-02) that one-click switching is worth dropping the earlier
// "never touches a credential" stance. The public text (README, spectix.app/security,
// /privacy) says so; keep it true. Rules that make this tolerable:
//
//   • A copy is taken only on the user's own actions — the first time an address is
//     seen signed in, and at the moment of a switch (the account being left is
//     re-captured first, because refresh tokens rotate). Never on a timer.
//   • Copies live in the app's OWN Keychain items (service "SpectiX account vault"),
//     created and read with /usr/bin/security, exactly like the live item below.
//     Never a plain file. ★ They used to be made through the Security framework,
//     and that is the bug that cost the most trust: a Keychain item's access list
//     binds to the CODE SIGNATURE of whoever made it, and a dev build is ad-hoc
//     signed, so every single rebuild turned the app into a stranger to its own
//     items and macOS asked for the login password again — several times an
//     evening, "Always Allow" included, because the next build was a stranger too.
//     Items made through the tool list the TOOL, whose signature never moves.
//     The trade is stated plainly: anything that can run `security` as this user
//     can read these copies. That was already true of the CLI's own item.
//   • The live credential is read and written with /usr/bin/security — the same tool
//     Claude Code uses on the item — so the item's access list stays exactly as the
//     CLI made it and neither side gets a Keychain prompt. The blob rides on argv for
//     the ~50ms the tool runs; the same user could already read it with that tool.
//   • ★ `security find-generic-password -w` prints the secret as TEXT only when every
//     byte is printable; otherwise it prints a HEX DUMP of it. Claude Code's blob is
//     one line of JSON and comes back as text; Codex's auth.json is pretty-printed,
//     contains newlines, and comes back as hex. Measured 2026-09-04 after a switch
//     wrote that hex string into ~/.codex/auth.json and signed the user out. Every
//     read therefore goes through `plain(_:)`, which undoes the hex and refuses any
//     blob that isn't JSON — nothing that fails to parse is ever written anywhere.
//   • Nothing here signs anyone in. When a copy is missing or rejected, the caller
//     falls back to the CLI's own login.
//   • ★ One field of a Claude copy IS read: `accessToken` (with its `expiresAt`), and
//     only to ask Anthropic's usage endpoint how full that account's windows are —
//     which is the only way a row for an account that is NOT signed in can show a
//     current figure. Never the refresh token: Anthropic rotates it on use, so
//     spending it here would leave the stored copy dead and, if that account is the
//     live one, sign the CLI out. The token never reaches argv (the request config
//     goes to curl on stdin), never a log, never any other file. The request runs
//     only on the user's press of the panel's refresh button — the network promise
//     (README "Privacy: no network") makes it opt-in per click, and the binary still opens no socket:
//     curl does, the same way the watch buzz goes through curl in the hook.
//
// Codex keeps its credential in a plain file (~/.codex/auth.json), so its "live"
// side is a file read/write with mode 0600 and no tool at all.

enum CredentialVault {
    private static let service = "SpectiX account vault"
    /// Claude Code's own item. Service name is fixed; the account attribute is the
    /// login user, which is what `security add-generic-password` defaults to.
    private static let claudeService = "Claude Code-credentials"

    /// Remembered because every row of the account panel asks on every rebuild, and
    /// each ask is now a process spawn. Nothing outside this file can change the
    /// answer, so the three places that do keep it honest.
    private static var presence: [String: Bool] = [:]

    static func has(_ kind: AgentKind, email: String) -> Bool {
        retireFrameworkItems()
        let key = acct(kind, email: email)
        if let known = presence[key] { return known }
        // Attributes only, no `-w`: asking whether a copy EXISTS must never be a
        // request to decrypt one.
        let ok = run(["/usr/bin/security", "find-generic-password",
                      "-a", key, "-s", service]).status == 0
        presence[key] = ok
        return ok
    }

    /// Copy the CLI's current credential into the vault under `email`. False when
    /// there is nothing to copy (signed out) or the Keychain refused.
    @discardableResult
    static func capture(_ kind: AgentKind, email: String) -> Bool {
        guard let blob = live(kind), !blob.isEmpty else { return false }
        // ★ The label must match the token. The caller's idea of "who is signed in"
        // comes from a cached parse that survives an unreadable file, so it can be a
        // stale identity standing next to a different account's bytes. Filed under
        // the wrong name, a copy makes every later switch to that name silently land
        // on the OTHER account — measured 2026-09-04: the "work" label held the personal account's token.
        // Codex carries its address inside the blob; when they disagree, store nothing.
        if let inside = codexEmail(in: blob), inside.lowercased() != email.lowercased() { return false }
        return store(kind, email: email, blob: blob)
    }

    /// The address a Codex credential is FOR, read off its id_token. nil for Claude's
    /// blob (it carries no address) or anything that doesn't parse — the caller then
    /// has nothing to check against and proceeds on its own identity.
    private static func codexEmail(in blob: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let jwt = tokens["id_token"] as? String else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    /// Put the stored credential for `email` back as the CLI's live one. False when
    /// no copy exists or the write failed — the caller then runs the CLI's login.
    static func restore(_ kind: AgentKind, email: String) -> Bool {
        guard let blob = stash(kind, email: email) else { return false }
        switch kind {
        case .claude:
            guard let s = String(data: blob, encoding: .utf8) else { return false }
            return run(["/usr/bin/security", "add-generic-password", "-U",
                        "-a", NSUserName(), "-s", claudeService, "-w", s]).status == 0
        case .codex:
            let path = "\(NSHomeDirectory())/.codex/auth.json"
            let url = URL(fileURLWithPath: path)
            guard (try? blob.write(to: url, options: .atomic)) != nil else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        }
    }

    static func forget(_ kind: AgentKind, email: String) {
        retireFrameworkItems()
        let key = acct(kind, email: email)
        run(["/usr/bin/security", "delete-generic-password", "-a", key, "-s", service])
        presence[key] = false
    }

    // MARK: live credential

    private static func live(_ kind: AgentKind) -> Data? {
        switch kind {
        case .claude:
            let r = run(["/usr/bin/security", "find-generic-password",
                         "-a", NSUserName(), "-s", claudeService, "-w"])
            guard r.status == 0 else { return nil }
            return plain(r.stdout)
        case .codex:
            // Through plain() as well: a file the CLI can't parse is nothing to copy,
            // and copying it would overwrite a good stored copy with garbage.
            return (try? Data(contentsOf: URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json")))
                .flatMap(plain)
        }
    }

    /// What `security … -w` (or a file read) actually gave us, as the JSON the CLI
    /// wrote — or nil. Strips the newline the tool appends, undoes the hex dump it
    /// switches to for blobs with control characters, and then insists the result
    /// parses as JSON. Both CLIs store a JSON object; anything else is not a
    /// credential and must never reach a live file or the vault.
    private static func plain(_ raw: Data) -> Data? {
        var out = raw
        while let last = out.last, last == 0x0a || last == 0x0d || last == 0x20 { out.removeLast() }
        guard !out.isEmpty else { return nil }
        var candidate = out
        if out.first != UInt8(ascii: "{"), let s = String(data: out, encoding: .ascii), let hex = Data(hex: s) {
            candidate = hex
        }
        guard (try? JSONSerialization.jsonObject(with: candidate)) != nil else { return nil }
        return candidate
    }

    // MARK: live quota of a stored account

    /// The body Anthropic's usage endpoint returns for the account whose copy is
    /// stored under `email` — nil when there is no copy, it holds no usable access
    /// token, the token has expired (an expired one cannot be renewed here; see the
    /// header), or the request failed. Blocking: run it off the main thread.
    /// Claude only; Codex's quota has no endpoint this app knows of.
    static func usageResponse(_ kind: AgentKind, email: String) -> Data? {
        guard kind == .claude, let blob = stash(kind, email: email),
              let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              // Would break out of the quoted config line below. No real token has
              // either, so refusing is safer than escaping.
              !token.contains("\""), !token.contains("\n"), !token.contains("\\")
        else { return nil }
        if let exp = oauth["expiresAt"] as? Double,
           exp / 1000 < Date().timeIntervalSince1970 + 60 { return nil }
        let config = """
            url = "https://api.anthropic.com/api/oauth/usage"
            header = "Authorization: Bearer \(token)"
            header = "anthropic-beta: oauth-2025-04-20"
            header = "Accept: application/json"

            """
        // --fail: a 401/429 comes back as a non-zero exit and an empty body, which is
        // all the caller needs — the figure on screen simply stays what it was.
        let r = run(["/usr/bin/curl", "-sS", "-m", "10", "--fail", "-K", "-"],
                    stdin: Data(config.utf8))
        guard r.status == 0, !r.stdout.isEmpty else { return nil }
        return r.stdout
    }

    // MARK: vault items

    private static func acct(_ kind: AgentKind, email: String) -> String {
        "\(kind.rawValue):\(email)"
    }

    private static func stash(_ kind: AgentKind, email: String) -> Data? {
        retireFrameworkItems()
        let r = run(["/usr/bin/security", "find-generic-password",
                     "-a", acct(kind, email: email), "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        return plain(r.stdout)
    }

    private static func store(_ kind: AgentKind, email: String, blob: Data) -> Bool {
        retireFrameworkItems()
        guard let s = String(data: blob, encoding: .utf8) else { return false }
        let a = acct(kind, email: email)
        // Replace rather than update: an item carries the access list it was BORN
        // with, so overwriting one made by an earlier build would inherit that
        // build's signature and prompt all over again.
        run(["/usr/bin/security", "delete-generic-password", "-a", a, "-s", service])
        let ok = run(["/usr/bin/security", "add-generic-password",
                      "-a", a, "-s", service,
                      "-D", "SpectiX credential copy",
                      "-w", s]).status == 0
        presence[a] = ok
        return ok
    }

    /// Delete every vault item the Security-framework version left behind, once.
    /// They cannot be carried over — reading one is precisely the access that raises
    /// the password prompt this change exists to remove. The copy for the account in
    /// use is retaken on the next refresh; any other account falls back to the one
    /// sign-in its row already offers.
    private static let retiredKey = "vaultRetiredFrameworkItems"
    private static func retireFrameworkItems() {
        guard !UserDefaults.standard.bool(forKey: retiredKey) else { return }
        UserDefaults.standard.set(true, forKey: retiredKey)
        presence.removeAll()
        // Deleting needs no decryption, so this is silent. No account attribute:
        // every item under the service goes, and at this point none are new-style.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    // MARK: spawn

    /// posix_spawn with stdout captured. Not disclaimed: `security` touches nothing
    /// TCC guards, and the Keychain keys access on the item's own list, not on the
    /// responsible process.
    /// `stdin`, when given, is written to the child in full before its output is
    /// read. Only ever a few hundred bytes here, well inside the pipe buffer, so
    /// the write cannot block on a child that has not started reading.
    @discardableResult
    private static func run(_ argv: [String], stdin input: Data? = nil) -> (status: Int32, stdout: Data) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return (-1, Data()) }
        let readFD = fds[0], writeFD = fds[1]
        var inFDs: [Int32] = [-1, -1]
        if input != nil, pipe(&inFDs) != 0 { close(readFD); close(writeFD); return (-1, Data()) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inFDs[0], STDIN_FILENO)
            posix_spawn_file_actions_addclose(&actions, inFDs[1])
        }
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            cargv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, nil, &cargv, environ)
        close(writeFD)
        if input != nil { close(inFDs[0]) }
        guard rc == 0 else {
            close(readFD)
            if input != nil { close(inFDs[1]) }
            return (-1, Data())
        }
        if let input {
            input.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(inFDs[1], raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(inFDs[1])
        }
        var out = Data()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(readFD, buf, 4096)
            if n <= 0 { break }
            out.append(buf.assumingMemoryBound(to: UInt8.self), count: n)
        }
        close(readFD)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return ((status & 0x7f) == 0 ? (status >> 8) & 0xff : -1, out)
    }
}

private extension Data {
    /// Even-length hex string → bytes; nil on any non-hex character.
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57:  return c - 48
            case 65...70:  return c - 55
            case 97...102: return c - 87
            default:       return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo); i += 2
        }
        self.init(bytes)
    }
}
