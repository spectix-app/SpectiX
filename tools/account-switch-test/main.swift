import Foundation
let personalOrg = "org-personal", teamOrg = "org-team", email = "me@example.com"
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  PASS" : "  FAIL", what); if !ok { fails += 1 } }
func writeConfig(org: String?, name: String) {
    var o: [String: Any] = ["emailAddress": email, "organizationName": name, "organizationType": org == teamOrg ? "claude_team" : "claude_max"]
    if let org { o["organizationUuid"] = org }
    let d = try! JSONSerialization.data(withJSONObject: ["oauthAccount": o])
    try! d.write(to: URL(fileURLWithPath: testHome + "/.claude.json"))
    usleep(20_000)   // mtime cache granularity
}
func cliLogin(_ org: String) {          // `claude auth login` into one org
    let acct = org; let g = (world.newest[acct] ?? 0) + 1
    world.newest[acct] = g; world.live = "\(acct)@gen\(g)"
    writeConfig(org: org, name: org == teamOrg ? "Newsbreak" : "\(email)'s Organization")
}
func cliRotate() {                       // the CLI refreshes its token while in use
    guard let l = world.live, let at = l.firstIndex(of: "@") else { return }
    let acct = String(l[..<at]); let g = (world.newest[acct] ?? 0) + 1
    world.newest[acct] = g; world.live = "\(acct)@gen\(g)"
}
func tick() { AccountBook.note(.claude, AgentAccounts.claude()) }
func key(_ org: String) -> String { AccountBook.key(email: email, orgID: org) }
func row(_ org: String) -> RememberedAccount? { AccountBook.list(.claude).first { $0.key == key(org) } }
/// What the panel's click does: switch, or fall back to the CLI's login.
func click(_ org: String) -> String {
    if AccountBook.switchTo(.claude, key: key(org)) { writeConfig(org: org, name: org == teamOrg ? "Newsbreak" : "\(email)'s Organization"); return "switched" }
    cliLogin(org); return "login"
}
// Header redraw re-enters note() on the change notifications, like the app does.
var reentries = 0
NotificationCenter.default.addObserver(forName: AccountBook.quotaDidChange, object: nil, queue: nil) { _ in
    reentries += 1; if reentries < 1000 { tick() } }

switch CommandLine.arguments[2] {
case "a":
    print("S1 today's bug: personal copy goes stale while the CLI uses it, then a terminal login to Team")
    cliLogin(personalOrg); tick()
    AccountBook.prepareLogin(.claude); cliLogin(teamOrg); tick()   // panel "add account" -> Team
    check(row(personalOrg)?.copyStale != true && world.vault[key(personalOrg)] != nil, "add account copied personal first")
    check(click(personalOrg) == "switched" && cliUsable(), "panel switch back to personal uses its copy")
    for _ in 0..<3 { cliRotate() }; tick()          // a month of use: personal's copy is now dead
    check(world.vault[key(personalOrg)] != nil, "personal still has a (now outdated) copy")
    cliLogin(teamOrg); tick()                       // external: personal left uncopied
    check(row(personalOrg)?.copyStale == true, "personal marked stale after terminal login to Team")
    check(click(personalOrg) == "login", "click stale personal -> falls back to login, not a fake switch")
    check(world.vault[key(teamOrg)] != nil, "Team copied before that login")
    tick()
    check(row(teamOrg)?.copyStale != true, "Team not marked stale by the login it was copied before")
    check(cliUsable(), "CLI signed in after the login")
    for _ in 0..<3 { cliRotate() }; tick()
    check(click(teamOrg) == "switched" && cliUsable(), "panel switch to Team works (fresh copy)")
    for _ in 0..<3 { cliRotate() }; tick()
    check(click(personalOrg) == "switched" && cliUsable(), "panel switch back to personal works")
    check(click(teamOrg) == "switched" && cliUsable(), "and to Team again")
    check(AccountBook.list(.claude).filter { $0.email == email }.count == 2, "exactly two rows for the one address")
    print("S3 half-written config (address, no org) creates no row")
    writeConfig(org: nil, name: ""); tick()
    check(AccountBook.list(.claude).count == 2, "still two rows")
    writeConfig(org: teamOrg, name: "Newsbreak"); tick()
    print("S4 notifications re-entering note() terminate")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(reentries < 50, "re-entries bounded (\(reentries))")
    print("-- quitting with Team live; next phase switches to personal while the app is closed")
    cliLogin(personalOrg)
case "b":
    print("S2 account changed while the app was closed")
    tick()
    check(row(teamOrg)?.copyStale == true, "Team (left while app closed, uncopied) marked stale on launch")
    check(click(teamOrg) == "login" && cliUsable(), "click Team -> login, CLI usable")
default: break
}
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
