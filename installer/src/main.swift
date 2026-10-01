import Cocoa

// SpectiX installer — a one-window app whose whole job is to put three things
// in place (the app, the status hook wiring, the editor extension) so the person
// receiving it never has to read a README, drag a bundle, or approve a shell
// script that Gatekeeper flagged. See installer/README.md.

// Headless mode: run the install (or uninstall) with no window and print what
// happened. Exists so the filesystem behaviour can be asserted automatically
// against a throwaway SPECTIX_INSTALL_ROOT — a GUI button is not something a
// test can press. Dormant for every real user: without the env var set, nothing
// below the guard runs.
let env = ProcessInfo.processInfo.environment
if env["SPECTIX_INSTALL_HEADLESS"] == "1" {
    let core = InstallerCore()
    print("root: \(core.paths.applications.path) | \(core.paths.home.path)")
    if env["SPECTIX_INSTALL_ACTION"] == "uninstall" {
        let removed = core.uninstall()
        print("uninstalled: \(removed.isEmpty ? "(nothing)" : removed.joined(separator: ", "))")
    } else {
        var failed = false
        for r in core.install(progress: { _ in }) {
            let mark = r.ok ? (r.skipped ? "skip" : "ok  ") : "FAIL"
            print("[\(mark)] \(r.step.title) — \(r.detail)")
            if !r.ok { failed = true }
        }
        if failed { exit(1) }
    }
    exit(0)
}

// Layout smoke test: build the window without showing it and print the resolved
// geometry. Catches a collapsed window — the one class of bug the filesystem
// assertions can't see.
if env["SPECTIX_INSTALL_DUMPLAYOUT"] == "1" {
    let probe = NSApplication.shared
    probe.setActivationPolicy(.prohibited)
    print(InstallerWindowController().layoutReport())
    exit(0)
}

let app = NSApplication.shared
let delegate = InstallerDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
