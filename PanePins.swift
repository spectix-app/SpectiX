import Foundation

// On-disk form of FocusRing's pane-identity cache (~/.claude/spectix/pane-pins.json):
// `{"<CG window id>": {"<pane number>": <shell pid>}}`.
//
// ★ Decoding must never trap (改这里前必读). The file is read on the first pane scan
// after launch, so a value that crashes the decoder crashes SpectiX on every start
// until the user finds and deletes a file they have never heard of. `pid_t(Int)` traps
// on anything outside Int32 — a hand edit, a truncated write, or a future format all
// get there — so every conversion goes through `exactly:` and drops what doesn't fit.
// Dropping is safe: a missing pin only means that pane is unresolved until the next
// click, exactly as before persistence existed. tools/pane-pins-check pins this down
// and build.sh runs it.
enum PanePins {
    static func decode(_ data: Data) -> [UInt32: [Int: pid_t]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var out: [UInt32: [Int: pid_t]] = [:]
        for (w, raw) in obj {
            guard let wid = UInt32(w), wid != 0,
                  let pins = raw as? [String: Any] else { continue }
            for (i, value) in pins {
                guard let index = Int(i),
                      let n = value as? NSNumber,
                      CFNumberIsFloatType(n) == false,
                      let pid = pid_t(exactly: n.int64Value), pid > 0 else { continue }
                out[wid, default: [:]][index] = pid
            }
        }
        return out
    }

    static func encode(_ cache: [UInt32: [Int: pid_t]]) -> Data? {
        var obj: [String: [String: Int]] = [:]
        for (wid, pins) in cache {
            var m: [String: Int] = [:]
            for (i, pid) in pins { m[String(i)] = Int(pid) }
            obj[String(wid)] = m
        }
        return try? JSONSerialization.data(withJSONObject: obj)
    }
}
