import Foundation
let testHome = CommandLine.arguments[1]
let testDefaults = UserDefaults(suiteName: "spectix.accounttest")!
enum AgentKind: String { case claude, codex }
func L(_ zh: String, _ en: String) -> String { zh }
struct UsageSnapshot { var sessionPct: Int?; var sessionResetsAt: Double?; var weekPct: Int?; var weekResetsAt: Double?; var updatedAt: Double = 0 }

// Fake Keychain + fake server. A credential is "<account>@gen<N>"; the server only
// accepts the newest generation of each account (refresh tokens rotate).
struct World: Codable { var live: String? = nil; var vault: [String: String] = [:]; var newest: [String: Int] = [:] }
var world: World = {
    (try? JSONDecoder().decode(World.self, from: Data(contentsOf: URL(fileURLWithPath: testHome + "/world.json")))) ?? World()
}() { didSet { try? JSONEncoder().encode(world).write(to: URL(fileURLWithPath: testHome + "/world.json")) } }
func cliUsable() -> Bool {
    guard let l = world.live, let at = l.firstIndex(of: "@") else { return false }
    return Int(l[l.index(at, offsetBy: 4)...]) == world.newest[String(l[..<at])]
}
enum CredentialVault {
    static func has(_ k: AgentKind, key: String) -> Bool { world.vault[key] != nil }
    @discardableResult static func capture(_ k: AgentKind, key: String) -> Bool {
        guard let l = world.live else { return false }; world.vault[key] = l; return true }
    static func restore(_ k: AgentKind, key: String) -> Bool {
        guard let b = world.vault[key] else { return false }; world.live = b; return true }
    static func forget(_ k: AgentKind, key: String) { world.vault[key] = nil }
    static func usageResponse(_ k: AgentKind, key: String) -> Data? { nil }
}
