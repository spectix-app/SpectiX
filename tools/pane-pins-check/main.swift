import Foundation

var failures = 0
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got == want { print("ok    \(what)") } else {
        print("FAIL  \(what): got \(got), want \(want)")
        failures += 1
    }
}
func decode(_ json: String) -> [UInt32: [Int: pid_t]] { PanePins.decode(Data(json.utf8)) }

// Round trip of what the app itself writes.
let cache: [UInt32: [Int: pid_t]] = [4242: [1: 501, 3: 9001], 77: [2: 123]]
expect(PanePins.encode(cache).map(PanePins.decode), cache, "round trip")

// Hostile or stale files: each must decode without trapping, keeping what is valid.
expect(decode(#"{"10":{"1":2147483648}}"#), [:], "pid above Int32")
expect(decode(#"{"10":{"1":99999999999999999999}}"#), [:], "pid above Int64")
expect(decode(#"{"10":{"1":-5,"2":0}}"#), [:], "non-positive pid")
expect(decode(#"{"10":{"1":12.5}}"#), [:], "fractional pid")
expect(decode(#"{"10":{"1":"501"}}"#), [:], "string pid")
expect(decode(#"{"10":{"1":501,"x":7,"2":"y"}}"#), [10: [1: 501]], "mixed keeps the valid pin")
expect(decode(#"{"0":{"1":501},"4294967296":{"1":501},"w":{"1":501}}"#), [:], "bad window ids")
expect(decode(#"{"10":[501]}"#), [:], "pins not an object")
expect(decode(#"[1,2,3]"#), [:], "top level not an object")
expect(decode(#"{"10":{"1":5"#), [:], "truncated write")
expect(decode(""), [:], "empty file")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all pane-pins cases pass")
