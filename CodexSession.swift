import Foundation

// MARK: - Codex rollout usage
//
// What an OpenAI Codex CLI session has spent, read out of Codex's own session
// record. The Codex hook writes that record's absolute path into
// ~/.claude/spectix/tp-<tty>; this file turns it into the numbers a row shows.
//
// The record ("rollout") is JSONL, one envelope per line:
//     {"timestamp":…,"ordinal":N,"type":…,"payload":{…}}
// Everything below comes from lines with type == "event_msg" and
// payload.type == "token_count" — Codex appends one after every request.
//
// API — one call returns the whole picture, or nil:
//
//     CodexSession.usage(rolloutPath:) -> CodexUsage?
//
//     totalTokens      payload.info.total_token_usage.total_tokens (whole session)
//     contextTokens    payload.info.last_token_usage.total_tokens  (last request)
//     contextWindow    payload.info.model_context_window
//     model            turn_context payload.model, nil until one is seen (see below)
//     sessionPct/-ResetsAt   payload.rate_limits.primary   (window_minutes 300)
//     weekPct/-ResetsAt      payload.rate_limits.secondary (window_minutes 10080)
//
// Three things measured on 61 real rollouts (~/.codex/sessions/2026/08/30) that
// this implementation depends on:
//
//  1. `total_token_usage` is CUMULATIVE, not what's in the window — one session
//     read 11,127,273 total against a 258,400-token window. Only `last_token_usage`
//     (208,337 there) describes what the model is actually carrying, so that's what
//     the context gauge has to use. Its `reasoning_output_tokens` is left in: the
//     file doesn't say whether Codex re-sends reasoning, and the observed values
//     (0–76) can't move a gauge that size either way.
//  2. `rate_limits` is null on 50 of 296 token_count lines (non-interactive `codex
//     exec` sessions never got a quota header back), so every quota field is
//     optional and a nil there is normal, not an error.
//  3. The 2025-era rollouts are a different format entirely (first line
//     {id,timestamp,instructions,git}) and contain no token_count at all. Nothing
//     special handles them — no line matches, so the call just returns nil.
struct CodexUsage {
    var totalTokens: Int
    var contextTokens: Int
    var contextWindow: Int
    var model: String?
    var sessionPct: Double?
    var sessionResetsAt: Date?
    var weekPct: Double?
    var weekResetsAt: Date?
}

enum CodexSession {
    /// The most recent usage on disk, for when no live session can supply one.
    ///
    /// ★ Why this exists: Codex publishes quota ONLY inside a session's rollout file,
    /// unlike Claude Code whose usage.json outlives every session. So the moment the
    /// user's last Codex terminal exits, the header's Codex card would go blank — the
    /// account is still logged in, the quota is still spent, but nothing on screen says
    /// so. Falling back to the newest rollout keeps the last known figures visible.
    ///
    /// ⚠️ Do NOT simply take the newest file. Importing another agent's config writes
    /// dozens of rollouts in the same second (63 on this machine, ~50 of them from one
    /// import), and those carry no rate_limits at all. So this walks newest-first and
    /// returns the first file that actually has quota in it, capped at `limit` files so
    /// a large history can't turn a 1 Hz refresh into a directory crawl.
    static func newestUsage(home: String? = nil, limit: Int = 12) -> CodexUsage? {
        let root = (home ?? "\(NSHomeDirectory())/.codex") + "/sessions"
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                       options: [.skipsHiddenFiles]) else { return nil }
        var found: [(Date, String)] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate else { continue }
            found.append((d, url.path))
        }
        for (_, path) in found.sorted(by: { $0.0 > $1.0 }).prefix(limit) {
            if let u = usage(rolloutPath: path), u.sessionPct != nil || u.weekPct != nil {
                return u
            }
        }
        return nil
    }

    /// Read the tail of a rollout .jsonl and report its newest usage. nil when the
    /// file is unreadable, isn't a rollout, or has no token_count line yet.
    ///
    /// Called once per Codex session per refresh (~1 Hz), against files that reach
    /// several MB, so it never reads more than `tailWindow` bytes and only decodes
    /// the handful of lines that pass a byte-level substring gate.
    static func usage(rolloutPath: String) -> CodexUsage? {
        guard let tail = readTail(rolloutPath) else {
            forget(rolloutPath)
            return nil
        }

        var usage: CodexUsage?
        var model: String?
        let dec = JSONDecoder()
        // Backwards: we want the LAST token_count (it carries the running totals and
        // the freshest quota), and the last model the session was running under.
        // A window that starts mid-line leaves a fragment as the final element here;
        // it can't decode as a whole JSON value, so it falls out on its own.
        for line in tail.data.split(separator: UInt8(ascii: "\n")).reversed() {
            if usage == nil, line.range(of: tokenCountNeedle) != nil,
               let row = try? dec.decode(TokenCountLine.self, from: Data(line)),
               row.payload.type == "token_count", let info = row.payload.info {
                let limits = row.payload.rate_limits
                usage = CodexUsage(
                    totalTokens: info.total_token_usage?.total_tokens ?? 0,
                    contextTokens: info.last_token_usage?.total_tokens ?? 0,
                    contextWindow: info.model_context_window ?? 0,
                    model: nil,
                    sessionPct: limits?.primary?.used_percent,
                    sessionResetsAt: date(limits?.primary?.resets_at),
                    weekPct: limits?.secondary?.used_percent,
                    weekResetsAt: date(limits?.secondary?.resets_at))
            }
            if model == nil, line.range(of: turnContextNeedle) != nil,
               let row = try? dec.decode(TurnContextLine.self, from: Data(line)),
               row.type == "turn_context" {
                model = row.payload?.model
            }
            if usage != nil && model != nil { break }
        }
        return remember(rolloutPath, size: tail.size, usage: usage, model: model)
    }

    // 64 KB. Across the 61 sample rollouts the last token_count started at most
    // 6.4 KB before EOF (median 664 B), so this is ~10x headroom for one page-cache
    // read per poll. It is deliberately not sized to always win: a single line in
    // those samples reached 2.17 MB (one big tool output), and while such a line is
    // being appended the last token_count is out of ANY sane window — that gap is
    // what the memo below covers, not a bigger read.
    private static let tailWindow: UInt64 = 64 * 1024

    /// Gates before decoding: a byte scan over the raw line, so megabyte-sized
    /// transcript lines are never handed to JSONDecoder. Both can false-positive on
    /// a line that merely *mentions* the word (a transcript quoting this code, say)
    /// — the `type` checks above are what actually decide.
    private static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private static let turnContextNeedle = Data("\"turn_context\"".utf8)

    private static func readTail(_ path: String) -> (data: Data, size: UInt64)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        // seekToEnd left the cursor at EOF — this seek is required even for start == 0.
        try? fh.seek(toOffset: size > tailWindow ? size - tailWindow : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        return (data, size)
    }

    private static func date(_ epoch: Double?) -> Date? {
        guard let e = epoch, e > 0 else { return nil }
        return Date(timeIntervalSince1970: e)
    }

    // MARK: - Per-file memo
    //
    // Two things the tail window can't supply on every single call, kept per rollout
    // path so a row doesn't blink between polls:
    //
    //   usage — while Codex appends a huge line (tool output; 2.17 MB observed) the
    //           last token_count scrolls out of the window. The numbers didn't change,
    //           only our view of them, so the previous answer stands.
    //   model — `turn_context` is written once per turn and then buried under that
    //           turn's output. It lands in the window at every turn start, which is
    //           where this picks it up.
    //
    // Entries are a path and a few numbers, and a machine only ever accumulates
    // rollout files at human speed, so there's nothing to evict; they're dropped when
    // the file becomes unreadable.
    private struct Memo {
        var size: UInt64
        var usage: CodexUsage?
        var model: String?
    }

    private static let memoLock = NSLock()
    private static var memos: [String: Memo] = [:]

    private static func remember(_ path: String, size: UInt64,
                                 usage: CodexUsage?, model: String?) -> CodexUsage? {
        memoLock.lock()
        defer { memoLock.unlock() }

        var memo = memos[path] ?? Memo(size: size, usage: nil, model: nil)
        // A file that SHRANK was rotated or replaced: what we remember describes bytes
        // that no longer exist. (Same guard as JSONLCache in Stats.swift.)
        if size < memo.size { memo = Memo(size: size, usage: nil, model: nil) }
        memo.size = size
        if let u = usage { memo.usage = u }
        if let m = model { memo.model = m }
        memos[path] = memo

        guard var out = memo.usage else { return nil }
        out.model = memo.model
        return out
    }

    private static func forget(_ path: String) {
        memoLock.lock()
        defer { memoLock.unlock() }
        memos[path] = nil
    }
}

// MARK: - Wire format
//
// Snake_case matches the JSON so the shapes read like the file (as UsageEvent in
// Stats.swift does). Every field is optional and the numbers are Double where the
// file could plausibly widen an int: one type mismatch fails the whole line, and
// losing a whole token_count over a field we don't even show would be a bad trade.

private struct TokenCountLine: Decodable {
    struct Payload: Decodable {
        struct Info: Decodable {
            struct Tokens: Decodable {
                let total_tokens: Int?
            }
            let total_token_usage: Tokens?
            let last_token_usage: Tokens?
            let model_context_window: Int?
        }
        struct Limits: Decodable {
            struct Window: Decodable {
                let used_percent: Double?
                let resets_at: Double?
            }
            let primary: Window?
            let secondary: Window?
        }
        let type: String
        let info: Info?
        let rate_limits: Limits?
    }
    let payload: Payload
}

// The session's model id. It is NOT in session_meta — checked all 61 samples, whose
// payloads only carry model_provider ("openai") and base_instructions.provenance.model,
// and provenance describes who wrote the prompt text, not what the session runs on.
// world_state.payload.state.model holds it too, but those lines run to megabytes;
// turn_context is ~1.8 KB and is rewritten every turn, so it's the cheap source.
private struct TurnContextLine: Decodable {
    struct Payload: Decodable {
        let model: String?
    }
    let type: String
    let payload: Payload?
}
