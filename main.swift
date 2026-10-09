import Cocoa
import Darwin
import ApplicationServices

// ─── NO-NETWORK INVARIANT ────────────────────────────────────────────────────
// SpectiX never opens a network connection. This is not a style preference —
// it is a public commitment (README "Privacy: no network") and the central claim
// of the privacy page, and users are explicitly invited to audit it from outside the
// binary (entitlements, linked libraries, live sockets, outbound firewall).
//
// Concretely, this app must never gain: an account or login, telemetry or
// analytics of any kind, crash reporting, an update ping, or a license-key
// check that phones home. Everything it needs is already local — process state
// via libproc, status files under ~/.claude/spectix/, and window titles via
// AXUIElement.
//
// build.sh enforces this twice: it fails the build if any networking API
// appears in the sources, and again if the linked binary pulls in a network
// stack. If a future feature genuinely requires the network, the guarantee has
// to be changed everywhere it is published (LICENSE, README, privacy page,
// changelog) and made opt-in — before the code lands, not after.
// ─────────────────────────────────────────────────────────────────────────────

// Private-but-ubiquitous libsystem call (Chromium, VSCode et al. use it): mark a
// posix_spawn'd child as responsible for its own TCC (privacy-permission) requests,
// instead of macOS billing every protected-file access to the spawning app.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

// Private-but-stable AX call (AltTab/yabai use it): read the CGWindowID behind an
// AXUIElement. Lets us map an on-current-Space VSCode AX window to a window number
// we can later feed switchToSpace — WITHOUT Screen Recording (which is otherwise
// the only way to read cross-Space window titles). See vscodeWindowCache.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// Carbon Process Manager call — still shipped, but marked unavailable to Swift. Bind the
// C symbol directly (AltTab does the same) to turn a pid into the ProcessSerialNumber that
// the SLPS front-process focus calls require. See slpsFocusWindow.
@_silgen_name("GetProcessForPID")
func TB_GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// One row in the menu = one live Claude session (one interactive `claude`
// process). Two sessions in the same VSCode window become two rows.
// Which agent CLI a session is running. The rawValue is the executable's basename,
// which is exactly what discoverSessions matches against — adding an agent is adding
// a case here plus its non-interactive argv denylist below.
//
// ★ Both kinds write the SAME per-tty state files (state-<tty>, title-<tty>, …). The
// hook script never asks who invoked it — it walks the parent chain for a tty and
// writes — and Codex ships a hook system whose event names and JSON payloads are
// Claude-compatible, so `spectix-status.sh` runs unmodified under both. Keeping it
// byte-identical is not just tidiness: Codex gates hooks behind a content-hash trust
// table (~/.codex/config.toml [hooks.state]), so editing the script silently disables
// it until the user re-approves in /hooks.
//
// What the kind DOES gate is enrichment that reads Claude-private sources: ~/.claude.json
// token/model tallies, the daemon's sessions/<pid>.json, Claude's transcript schema, and
// the shell-snapshot busy probe. Every one of those is legitimately empty for a Codex
// session, so they must be skipped by kind rather than left to "return nothing" — an
// empty read is indistinguishable from a real zero (see fetchRows).
enum AgentKind: String {
    case claude = "claude"
    case codex  = "codex"

    // argv words that prove this process is NOT an interactive session.
    //
    // The two CLIs need different tests, so this can't be one shared list. Claude's
    // non-interactive modes are FLAGS on the same argv (`-p`, `--print`, `daemon`);
    // Codex's are SUBCOMMANDS, and its interactive TUI carries none at all. `codex exec`
    // is the one that actually bites: unlike the app-server processes it runs on a real
    // tty, so the "has a tty" test alone would let a scripted batch run masquerade as a
    // session the user is sitting in front of.
    var nonInteractiveArgs: Set<String> {
        switch self {
        case .claude:
            return ["daemon", "--bg-pty-host", "--bg-spare", "-p", "--print"]
        case .codex:
            return ["exec", "app-server", "mcp-server", "mcp",
                    "login", "logout", "doctor", "completion",
                    "generate-json-schema"]
        }
    }
}

// A native terminal emulator a `claude` session can run under (as opposed to
// VSCode's integrated terminal or the desktop app). Each case's rawValue is the
// app's bundle id — used both to identify the session's top-level app and to drive
// its AppleScript in focus(). Adding a terminal = adding a case here plus its jump
// script in focusTerminal(_:app:precise:).
enum TerminalApp: String {
    case terminal = "com.apple.Terminal"
    case iterm    = "com.googlecode.iterm2"
}

// Which VSCode-family editor a `claude` session runs under. rawValue = the host app's
// bundle id, mirroring TerminalApp. VSCode is the default AND the unknown-host fallback,
// so every VSCode session — and any host we don't recognize — resolves to .vscode; all
// the jump/window-scan/FocusRing paths keyed on editor therefore behave exactly as they
// did before this abstraction existed (rawValue is the same string they hardcoded).
enum EditorApp: String, CaseIterable {
    case vscode   = "com.microsoft.VSCode"
    case cursor   = "com.todesktop.230313mzl4w4u92"
    case windsurf = "com.exafunction.windsurf"

    // The editor's per-user extension directory (~/.vscode|.cursor|.windsurf/extensions),
    // where the companion spectix.focus extension lives.
    var extDir: String {
        let name: String
        switch self {
        case .vscode:   name = ".vscode"
        case .cursor:   name = ".cursor"
        case .windsurf: name = ".windsurf"
        }
        return "\(NSHomeDirectory())/\(name)/extensions"
    }

    // The editor's ~/Library/Application Support/<name> folder, where its
    // globalStorage/storage.json lists the folders it currently has open
    // (see EditorWorkspaces).
    var appSupportName: String {
        switch self {
        case .vscode:   return "Code"
        case .cursor:   return "Cursor"
        case .windsurf: return "Windsurf"
        }
    }

    // The project-header source badge for this editor. Model-layer enum (not the
    // view's LogoBadge.Mode) so EditorApp stays free of view types; HeaderCell maps
    // HeaderSource → LogoBadge.Mode at render time.
    var headerSource: HeaderSource {
        switch self {
        case .vscode:   return .vscode
        case .cursor:   return .cursor
        case .windsurf: return .windsurf
        }
    }
}

// Context occupancy → 0–100 for the gauge. Shared by session rows and agent sublist
// nodes so both read the same window the same way. An unknown limit (nothing populated
// in .claude.json) is inferred from the occupancy itself — over 200k can only be a 1M
// window — so a captured reading never goes ungauged for want of a limit.
func ctxPercent(tokens: Int, limit: Int) -> Int {
    let lim = limit > 0 ? limit : (tokens > 200_000 ? 1_000_000 : 200_000)
    return max(0, min(100, Int((Double(tokens) / Double(lim) * 100).rounded())))
}

struct SessionRow {
    let title: String      // display title — folder name, suffixed with the tty
                           // when the same folder has >1 session, e.g. "fleet-bar · ttys006"
    let folder: String     // top folder name of the cwd, e.g. ".claude"
    let cwd: String        // the session's working directory
    let shellPid: pid_t    // parent shell pid == VSCode `terminal.processId`, used to focus
    let tty: String        // controlling tty, e.g. "ttys006" (label + disambiguation)
    let status: String     // internal: needs / working / done / seen / idle
    let taskTitle: String  // human-readable task summary the hook writes to
                           // ~/.claude/spectix/title-<tty>: Claude Code's own AI-generated
                           // title (transcript "ai-title") when available, else the user's
                           // prompt as a fallback; empty until set.
    let seq: Int           // stable 1-based session number, for a clean L("会话 01", "Session 01") fallback
                           // label when there's no task title — never the bare ttysNNN.

    // Which agent CLI this row is. Defaulted so every existing construction site (and
    // DemoData) keeps compiling unchanged; discoverSessions is the only thing that ever
    // sets it to something else. It gates the enrichment that reads Claude-private
    // sources — see AgentKind — and it must be part of renderKey, or a tty that swaps
    // agents would keep the previous agent's model chip until something else changed.
    var agentKind: AgentKind = .claude


    // This session's usage since it began (its process start, or the last /clear —
    // see sessionUsage). workSec = time actually spent RUNNING (gap-capped活动脉冲,
    // see WorkClock — not the span a turn was open, which counts the hours a prompt
    // sat waiting on you); tokens = all tokens consumed. Reset when the session is
    // cleared or the terminal is reopened.
    var workSec: Int = 0
    var tokens: Int = 0
    // True when tokens were summed from this session's own logged turns (per-tty,
    // transcript-based) rather than the per-project fallback that sibling sessions
    // in one folder share. Drives the header total: exact rows sum individually.
    var tokensExact = false

    // Current CONTEXT occupancy (distinct from `tokens`, the cumulative spend): how
    // full this session's context window is right now — the last assistant message's
    // input side (input + cache read + cache creation), written by the hook to
    // ctx-<tty>. ctxLimit is the model's window (200k / 1M) resolved from the cwd's
    // last model (ctxLimit(for:), which now falls back to the account default). ctxPct
    // maps the pair to 0–100 for the gauge; the fresh-session and desktop/idle hide cases
    // are handled by the caller (MainWindow), so here we always yield a real number.
    var ctxTokens: Int = 0
    var ctxLimit: Int = 0
    var ctxPct: Int {
        // A fresh/just-started session hasn't had its context captured yet — show 0%
        // from the outset rather than hiding the gauge (desktop/idle/not-started rows are
        // forced to -1 by the caller, so they stay hidden regardless of this).
        guard ctxTokens > 0 else { return 0 }
        return ctxPercent(tokens: ctxTokens, limit: ctxLimit)
    }

    // The model this session is currently on, already humanised for display
    // ("Opus 5" / "Sonnet 5" / "Haiku 4.5"). Primary source is the session's OWN last
    // completed turn (events.jsonl's per-tty `model`, which the hook lifts from the
    // transcript at Stop), so sibling tabs in one project can show different models;
    // the per-project fallback (~/.claude.json lastModelUsage) only fills sessions that
    // haven't finished a turn yet. Empty when neither source knows.
    var model: String = ""

    // What a WORKING session is doing right now — the hook's per-tty step-<tty> file,
    // e.g. "Edit · main.swift" / "Bash · git push". Empty unless a tool is in flight;
    // shown beneath the title in place of the usage line while 运行中.
    var step: String = ""

    // How many background subagents this session is still waiting on (the hook's
    // bg-<tty> ledger line count). 0 unless a run_in_background Agent/Task is in
    // flight; drives the "Agent ×N" step badge so you can see how many are running.
    var bgAgents: Int = 0

    // Who those background subagents ARE — the hook's agents-<tty> roster joined
    // with each running agent's live step file. Drives the expandable agent sublist
    // under this row (click the 🤖 badge). Running ones only: an agent leaves the list
    // as soon as it finishes (see backgroundAgents).
    var agents: [AgentInfo] = []

    // How many backgrounded Bash-tool command shells are still alive under this session
    // while its own turn has already ended (run_in_background: `npx expo run:ios` &c).
    // >0 is what paints the row 运行中 even though the hook said done/idle — and since
    // Stop already wiped step-<tty>, it also supplies the subtitle that says so, instead
    // of leaving a blue row with nothing but a clock (which reads as "stuck").
    var bgShells: Int = 0

    // Epoch (timeIntervalSince1970) of the OLDEST live background command shell, so the
    // subtitle can show how long it's been running ("…运行中 · 2m"). 0 when bgShells == 0.
    var bgShellsSince: Double = 0

    // This row's 暂停 came from the staleness gate (both signal sources dead AND no live
    // command shell — see fetchRows), not from a real interrupt. Same fuchsia pill, but
    // excluded from every attention pool via awaitsYou.
    var isFrozen: Bool = false

    // "This row is waiting on YOU" — the attention pool behind the jump paths, the
    // parked-attention chain and auto-return. A frozen row wears 暂停 but is NOT in it:
    // it is a corpse, not a prompt. Leaving it in would be worse than the bug the gate
    // fixes — paused is the TOP jump bucket and every pool is strict-bucketed (first
    // non-empty status wins), so ONE permanently-frozen row would pin every jump to
    // itself and 需确认 rows would never become reachable at all, forever.
    var awaitsYou: Bool { (status == "needs" || status == "paused") && !isFrozen }

    // The Claude desktop app (claude.ai native client) instead of a terminal `claude`
    // session. Discovered via AX, not a hook; focused by activating the app, not by
    // revealing a VSCode terminal. Drives the header's source icon too.
    var isDesktop: Bool = false

    // Which of the desktop app's windows this row stands for (chat vs Design vs a
    // second chat window). One app, many windows: the pid is shared by all of them, so
    // the window number is the only thing that tells the rows apart — it keys the row
    // identity, the per-window working/done latches, and the jump target.
    var desktopWid: CGWindowID = 0

    // The Claude Code chat panel inside a VSCode-family editor (sidebar, tab, or its
    // own window) rather than a session running in an integrated terminal. It has no
    // tty and no shell, so `tty` holds the pid-derived key ("pid<PID>") the hook writes
    // its state under — a key that must never reach the UI (see `display`, which has
    // always refused to show a bare ttysNNN; a bare pid12345 is no better). Focused by
    // asking the companion extension to focus the chat input, not by revealing a
    // terminal — shellPid here is the editor's extension host, one per window.
    var isChatPanel: Bool = false

    // Non-nil when this session runs under a native terminal emulator (Terminal.app /
    // iTerm) rather than VSCode or the desktop app. Drives focus() down the AppleScript
    // jump path instead of the VSCode-reveal path, and (Session 2) the header source
    // badge. nil = VSCode terminal (the default) or desktop row.
    var terminalApp: TerminalApp? = nil

    // Which VSCode-family editor (VSCode / Cursor / Windsurf) hosts this session, used
    // by every jump/window/FocusRing path. Meaningless for native-terminal rows
    // (terminalApp != nil, which take the AppleScript path) and desktop rows.
    //
    // ★ nil means "host NOT recognized" — NOT "assume VSCode" (改这里前必读). It used to
    // default to .vscode as an unknown-host fallback, which was harmless while VSCode
    // was the only editor but became the "高亮画到奇怪的地方" bug once people ran claude
    // under Warp / Ghostty / kitty / Hyper / tmux / ssh: those sessions claimed to live
    // in a VSCode pane, so a jump raised the real VSCode and the ring/caption landed on
    // an unrelated pane there, and flashPaused fired the same misdirected ring with no
    // click at all. Unknown host now stays nil and `hostSupported` gates every draw.
    var editor: EditorApp? = nil

    // Whether we know how to point AT this session — the single whitelist gate behind
    // every jump, ring and caption. Supported hosts are exactly: Terminal.app, iTerm
    // (TerminalApp), VS Code / Cursor / Windsurf (EditorApp) and the Claude desktop app.
    // Anything else (Warp, Ghostty, kitty, Hyper, Alacritty, a tmux server, a bare ssh
    // login…) resolves to none of the three and is deliberately NOT adapted to: we don't
    // maintain a grey list of "sort of jumpable" hosts.
    //
    // Unsupported does NOT mean invisible: status comes from the hooks keyed by tty, so
    // these rows still report working/needs/done perfectly. Only the things that need a
    // window/pane to point at are withheld — jump does nothing, no ring, no caption.
    var hostSupported: Bool { isDesktop || terminalApp != nil || editor != nil }

    // Stable identity for ack/toast bookkeeping. shellPid (the session's parent
    // shell) is unique per live process; tty+cwd keep it stable and readable even
    // if shellPid is momentarily unavailable.
    // Desktop rows share one pid and carry no tty, so their identity comes from the
    // window number instead — otherwise the chat and Design rows collide on one id and
    // ack/toast bookkeeping treats them as the same session.
    var id: String {
        isDesktop ? "desktop:\(desktopWid)" : "tty:\(tty):\(cwd)#\(shellPid)"
    }

    // "01", "02", … — the user-facing session number used wherever we'd otherwise
    // have shown the ttysNNN.
    var seqLabel: String { String(format: "%02d", seq) }

    // What the list/menu shows for this row: the task summary when we have one,
    // otherwise the folder-based title — never the bare ttysNNN.
    var display: String { taskTitle.isEmpty ? title : taskTitle }

    // The project name a toast/header shows: the cwd's leaf folder, or — for a desktop
    // row — the sentinel cwd itself, which IS the label ("Claude App" / "Claude
    // Design"). Matches ListModel.projectItems' folder derivation so a banner names the
    // project exactly like its list header.
    var projectName: String {
        isDesktop ? cwd : (cwd as NSString).lastPathComponent
    }

    // The project icon a toast shows in its left tile — same source badge the list
    // header uses (LogoBadge.Mode): a user-picked icon wins, else desktop/terminal/
    // editor is derived from this row alone (single-session banner, no group to poll).
    var badgeMode: LogoBadge.Mode {
        if let ic = AppSettings.customIcon(cwd: cwd) { return LogoBadge.mode(for: ic) }
        if isDesktop { return .desktop }
        if terminalApp != nil { return .terminal }
        switch editor {
        case .vscode:   return .vscode
        case .cursor:   return .cursor
        case .windsurf: return .windsurf
        // Unsupported host (Warp, Ghostty, tmux, ssh…): it IS a terminal session, we
        // just can't point at its pane — so it wears the generic terminal badge rather
        // than borrowing VS Code's.
        case nil:       return .terminal
        }
    }
}

// One background subagent of a session, from the hook's agents-<tty> roster (JSONL:
// one line per Agent/Task launch carrying an agentId). type/desc come from the launch's
// tool_input (subagent_type / description); step mirrors the agent's own live tool call
// (the hook keys it by the agent_id its tool events carry). Feeds the expandable agent
// sublist — which only ever holds RUNNING agents: a finished one is filtered out at the
// source (backgroundAgents), so there is no completion state to model here.
struct AgentInfo: Equatable {
    var id: String
    var type: String        // "general-purpose" / "Explore" / …
    var desc: String        // launch description — the agent's task name
    var start: Double       // launch epoch
    var step: String = ""   // live "Tool · detail"
    // The launch's explicit model override ("opus"/"sonnet"/"haiku"), empty when the
    // agent just inherits the session's model — the row then shows the parent's label.
    var model: String = ""
    // This agent's OWN context occupancy, tailed from its own transcript (a subagent
    // gets a separate file — see agentCtxTokens), plus the window it's measured against.
    // The limit is inherited from the parent session: a subagent's tier isn't recorded
    // anywhere readable, and an agent without a model override runs the parent's model
    // anyway. 0 tokens = not measurable yet (no reply on record) → ctxPct hides.
    var ctxTokens: Int = 0
    var ctxLimit: Int = 0
    // -1 (hidden) rather than 0% while unknown: a fabricated 0% on every agent node was
    // the bug this replaces. A real reading is only ever a percentage of a real window.
    var ctxPct: Int { ctxTokens > 0 ? ctxPercent(tokens: ctxTokens, limit: ctxLimit) : -1 }
}

// Your Claude *subscription* usage, as printed by `/usage` and captured by the status
// hook into ~/.claude/spectix/usage.json (see hooks/spectix-usage.py). Global, not
// per-session — the whole account shares these windows. Percentages are 0–100; the
// resets-at values are Unix epochs the header counts down from. All optional so a partial
// parse still renders what it has. Absent file (non-subscription, or not yet probed) → nil.
struct UsageSnapshot {
    var sessionPct: Int?
    var sessionResetsAt: Double?
    var weekPct: Int?
    var weekResetsAt: Double?
    var weekModelPct: Int?
    var weekModelLabel: String?
    var updatedAt: Double = 0
    /// False when these figures are a REMEMBERED reading for the account on the card
    /// rather than a current one — the state right after a switch, before anything has
    /// measured the new account. The card then draws them set back half a step, the
    /// same grammar the account panel's rows already use. Never dress a remembered
    /// figure up as a live one: it is the one way a quota display can lie.
    var live = true
    /// A usage request for this account is in flight (the switch fires one). The card
    /// spins while it is true, which is what tells the user the figures they are
    /// looking at are about to be replaced rather than simply wrong.
    var fetching = false
}

// What the header's three cards need beyond the Claude UsageSnapshot. Assembled by
// AppController rather than by the view, because only it knows where the state files
// live and which rows are Codex — the view gets finished figures, not file paths.
struct HeaderAgentInfo {
    /// ★ Claude's figures come through here too, even though the caller already holds
    /// the raw usage.json snapshot: only this assembly knows WHICH ACCOUNT that
    /// snapshot describes, and right after a switch the answer is "the one we left".
    /// A caller passing the raw snapshot straight to the header is how the card ends
    /// up showing one account's percentages under another's name.
    var claudeUsage: UsageSnapshot?
    var codexUsage: UsageSnapshot?
    var claudeAccount: AgentAccount?
    var codexAccount: AgentAccount?
    // Whether the book remembers any address for each CLI. Without this the card is
    // hidden whenever the CLI isn't signed in — and the account panel is reachable
    // only through that card, so a user who signed out could no longer get back to
    // the accounts they had already used.
    var claudeRemembered = false
    var codexRemembered = false
}

// MARK: - Status (internal taxonomy)
//   needs   红   等你确认（ground truth from Notification hook flag file）
//   working 蓝   正在执行（转圈圈）
//   done    绿   跑完等输入
//   seen    灰  done 已被点开看过（点击跳转落到终端），回落成灰「闲置」直到该会话出现
//               新动静（needs 不走这里，它保持红色直到 hook 反映真实确认）
//   idle    灰白 闲置/连接中

enum Status {
    static func label(_ s: String) -> String {
        switch s {
        // English labels are all four letters on purpose: the pill sits in a fixed
        // column next to two-character Chinese labels, so an 8-letter "Watching"
        // would make the same row jump width between languages.
        case "needs":   return L("确认", "Wait")
        case "checking": return L("查看", "View")
        case "working": return L("运行", "Busy")
        case "paused":  return L("暂停", "Held")
        case "done":    return L("完成", "Done")
        case "await":   return L("等待", "Hold")   // a background shell runs; the model resumes on its own
        case "rest":    return L("休息", "Rest")   // the break-reminder banner / chip only
        default:        return L("闲置", "Idle")   // seen / idle 都显示灰「闲置」
        }
    }
}

// MARK: - Toast (floating banner)
//
// A borderless, non-activating panel that pops in the top-right corner when a
// session transitions to "needs" / "done". Click → jump to VSCode + dismiss;
// otherwise auto-dismisses. Multiple toasts stack downward.

// Apple-notification-style close affordance: a small circular ✕ that reveals on
// hover in the top-left corner of a "needs" banner. Clicking it force-dismisses
// the toast immediately (the one way to make a sticky red banner go away without
// actually answering the prompt).
final class ToastCloseButton: NSView {
    var onClose: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 0.35, alpha: 0.72).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(cfg)
        let iv = NSImageView(image: glyph ?? NSImage())
        iv.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim clicks while visible; a hidden (alpha 0) ✕ must let the click
        // fall through to the banner beneath it (which is itself one big button).
        guard alphaValue > 0.01 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// The toast's surface — one big button that also carries the banner's material.
//
// It used to BE the frost pane (an NSVisualEffectView subclass). Whether there is
// a blur at all is now a theme decision — a `.clay` theme paints an opaque warm
// surface and skips the pass entirely — so the banner is a plain view that HOSTS
// a frost pane when the theme asks for one. Everything else is unchanged: the
// whole banner is still a single click target, with a hover-revealed ✕ sibling.
final class ToastSurfaceView: NSView {
    var onClick: (() -> Void)?
    // The hover-revealed close button, if this banner has one. It lives as a sibling
    // above this view (in the host), so clicks land on it directly; this ref is only
    // for the tracking area that fades it in/out on hover.
    weak var closeButton: NSView?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, radius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        if Theme.material == .frostedGlass {
            let blur = NSVisualEffectView(frame: bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .hudWindow
            blur.state = .active
            blur.blendingMode = .withinWindow
            // Clip the blur material with a resizable rounded-rect maskImage. Plain
            // layer.cornerRadius + masksToBounds does NOT reliably clip an
            // NSVisualEffectView's material, so the square corners of the blur leak
            // out as light/white triangles — this masks them off cleanly.
            blur.maskImage = Theme.roundedMask(radius: radius)
            addSubview(blur)
        }
        resolveColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Uniform fill — the same tile the window cards use. Without it a frosted toast
    // is just bare .hudWindow blur, so the wallpaper's own light/dark variation
    // bleeds through unevenly and reads as "the white stops on one side"; on clay it
    // IS the surface. The fill gives every toast a consistent base regardless of
    // what's behind it.
    private func resolveColors() {
        layer?.backgroundColor = Theme.cardFill.cg(in: self)
        layer?.borderColor = Theme.hairline.cg(in: self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { setCloseHidden(false) }
    override func mouseExited(with event: NSEvent)  { setCloseHidden(true) }
    private func setCloseHidden(_ hidden: Bool) {
        guard let cb = closeButton else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            cb.animator().alphaValue = hidden ? 0 : 1
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    // The toast rides a non-activating panel, so its window is never key — without
    // this the click that would jump gets eaten as a mere focus click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    // Route every click (even over the labels/bar) to self, so the whole banner
    // is one button — otherwise an NSTextField label swallows the mouseDown. The
    // close ✕ sits above this view as a sibling, so it intercepts its own clicks
    // before they ever reach here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }
}

// A looping status highlight hugging a toast's icon tile. It plays the SAME
// RingView animation — and the same per-status RingStyle (needs→corners,
// paused→ants, …) — the terminal FocusRing shows, so a banner's icon ripples /
// converges / breathes in step with the ring that fired for the same event,
// instead of a generic pulse of its own. Sized to hug the 40pt tile with a small
// margin for glow/ripple travel; each pass replays just after the flourish clears
// (the same loop SettingsWindow's live preview uses), and swaps style + color when
// the toast morphs needs → checking → done.
final class ToastTileRing: NSView {
    // Travel room around the tile for the glow / ripples. Smaller than the terminal
    // ring's 24pt (the tile is only 40pt) so waves read without spilling onto the
    // banner text 12pt to the tile's right.
    static let margin: CGFloat = 14
    private var ring: RingView?
    private var replayTimer: Timer?
    private var status = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // The frame that hugs `tile` (in its superview's coords) with `margin` of travel
    // room on every side — where the overlay must be placed to trace the tile edge.
    static func frame(around tile: NSView) -> NSRect {
        tile.frame.insetBy(dx: -margin, dy: -margin)
    }

    // (Re)start the loop in `status`'s color + style. Off/highlights-disabled draws
    // nothing (the tile's own faint resting frame is then the whole highlight).
    func configure(status: String) {
        self.status = status
        replay()
    }

    // Re-run the loop for the current status (e.g. after the settings toggle flips)
    // so a live banner starts or stops animating without waiting for a morph.
    func refresh() { replay() }

    private func replay() {
        replayTimer?.invalidate(); replayTimer = nil
        ring?.removeFromSuperview(); ring = nil
        let style = AppSettings.ringStyle(for: status)
        // The banner highlight has its own switch (independent of the terminal-ring
        // master); off or an .off style leaves just the tile's static status frame.
        guard AppSettings.notifHighlightEnabled, style != .off else { return }
        // Empty project/task → a pure ring flourish (no caption / titlebar band).
        let r = RingView(frame: bounds, margin: Self.margin,
                         accent: Status.accent(status), style: style)
        addSubview(r)
        ring = r
        // One-shot flourish → replay a hair past its lifetime (so the fade-to-0 lands
        // first) for a steady "still calling you" loop while the banner is up.
        replayTimer = Timer.scheduledTimer(withTimeInterval: r.lifetime + 0.4,
                                           repeats: false) { [weak self] _ in self?.replay() }
    }

    // Tear down the loop when the banner is removed so neither the retained timer
    // nor the ring outlives it.
    func stop() {
        replayTimer?.invalidate(); replayTimer = nil
        ring?.removeFromSuperview(); ring = nil
    }

    deinit { replayTimer?.invalidate() }
}

// One live banner: the panel plus the inner views a resolve animation recolors.
// Holding these refs is what lets a "needs" toast morph green + check in place
// instead of being torn down and rebuilt.
final class Toast {
    let panel: NSPanel
    let path: String
    // The left tile frames the project icon; its faint resting frame/wash is what a
    // resolve/check morph recolors (the icon itself is the project's fixed identity).
    let iconTile: NSView
    // The animated highlight around the tile — the per-status RingView flourish that
    // makes the banner read as "alive / calling you", swapped on each morph.
    let tileRing: ToastTileRing
    let pill: CapsuleLabel
    let closeButton: NSView?
    // A "needs" banner is sticky: neither a click-to-jump nor focusing the terminal
    // clears it — only answering (resolve) or its ✕. Informational banners aren't.
    let sticky: Bool
    var resolving = false
    var checking = false
    init(panel: NSPanel, path: String, iconTile: NSView, tileRing: ToastTileRing,
         pill: CapsuleLabel, closeButton: NSView?, sticky: Bool) {
        self.panel = panel; self.path = path; self.iconTile = iconTile
        self.tileRing = tileRing; self.pill = pill
        self.closeButton = closeButton; self.sticky = sticky
    }
}

final class ToastManager {
    static let shared = ToastManager()

    private var toasts: [Toast] = []
    // Apple-notification proportions: icon-height + padding, just tall enough for
    // a two-line text block. The status pill caps the top-right like a timestamp,
    // so the card reads as one tight unit instead of a sparse bar.
    private let width: CGFloat = 356
    private let height: CGFloat = 78
    private let margin: CGFloat = 14
    private let spacing: CGFloat = 10
    private let lifetime: TimeInterval = 8
    // How long a banner's session may stay missing from the live scan before we call it
    // gone (see retain). Long enough to ride out a transient scan miss, short enough
    // that a stranded banner clears before you'd reach for its ✕.
    private let orphanGrace: TimeInterval = 6
    // path → when that banner's session first went missing. Cleared the moment it
    // reappears, so a flicker never accumulates toward the grace window.
    private var missingSince: [String: Date] = [:]

    // path is the identity: a fresh transition for the same project replaces the
    // old toast instead of stacking a duplicate — including one mid-resolve (a quick
    // needs→done→needs), so the new red isn't left stacked behind a lingering check.
    // title = line 1 (the project name); subtitle = line 2 (what the session is doing);
    // icon = the project badge shown in the left tile.
    func show(title: String, subtitle: String, icon: LogoBadge.Mode,
              status: String, path: String, onClick: @escaping () -> Void) {
        if let existing = toasts.first(where: { $0.path == path }) { remove(existing) }

        // A "needs" banner is sticky: clicking it jumps to VSCode but does NOT dismiss
        // it — it only clears when you actually answer (resolve → green ✓ → fade) or hit
        // its ✕. Jumping to the terminal isn't answering, so the red stays up as a
        // reminder. An informational (done) banner still dismisses on click, as before.
        // A "rest" banner (BreakReminder) fades like a done one: the chip and strip stay
        // red until you rest, so the banner is only the heads-up (2026-10-04 user call).
        let sticky = status == "needs"
        let toast = makeToast(title: title, subtitle: subtitle, icon: icon, status: status, path: path,
                              onClick: { [weak self] in
                                  onClick()
                                  // A sticky "needs" banner doesn't dismiss on click — instead it
                                  // morphs into the L("查看", "View") eye: you clicked, you're now looking.
                                  if status == "needs" { self?.check(path) } else { self?.dismiss(path) }
                              },
                              onClose: { [weak self] in self?.forceDismiss(path) })
        let panel = toast.panel
        toasts.append(toast)

        // Existing toasts slide to make room; the newcomer starts parked off the right
        // edge and slides left into its slot (Apple-notification entrance).
        let origins = restingOrigins()
        let target = origins[toasts.count - 1]
        for (i, t) in toasts.enumerated() where t !== toast {
            t.panel.animator().setFrame(
                NSRect(origin: origins[i], size: NSSize(width: width, height: height)), display: true)
        }
        panel.setFrameOrigin(offRight(target))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(origin: target, size: NSSize(width: width, height: height)), display: true)
            panel.animator().alphaValue = 1
        }

        // "needs" (red, awaiting your input) is the one you must not miss, so it stays
        // put until you answer (resolve) or dismiss it with its ✕ — neither a click-to-
        // jump nor focusing the terminal clears it. Any other (informational) status
        // auto-dismisses after its lifetime.
        if !sticky {
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
                self?.dismiss(path)
            }
        }
    }

    // Explicit user dismissal via the ✕ button: tear the banner down now,
    // unconditionally (even a resolving one), no green-check morph. This is the only
    // way to clear a still-red "needs" banner short of actually answering it.
    func forceDismiss(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }) else { return }
        remove(toast)
    }

    // Dismiss the (informational) toast belonging to a given session shell pid — used
    // when the user focuses that terminal. Paths end with "#<shellPid>" (see
    // SessionRow.id). Sticky "needs" banners are deliberately NOT cleared here: going
    // to the terminal isn't answering the prompt, so the red must stay until you
    // actually respond (resolve) or dismiss it with its ✕.
    func dismiss(shellPid pid: pid_t) {
        let suffix = "#\(pid)"
        for toast in toasts where toast.path.hasSuffix(suffix) && !toast.sticky {
            dismiss(toast.path)
        }
    }

    // The tile's STATIC status skin: a faint matching wash + a faint resting frame,
    // recolored on each needs/checking/done morph. The project icon inside never
    // changes (it's the project's fixed identity). The ANIMATED highlight — the
    // "alive / calling you" flourish — is a separate ToastTileRing overlay playing
    // the status's own RingStyle (see configure), so this frame only needs to hold
    // the color steady between animation loops.
    private func styleTile(_ tile: NSView, status: String) {
        guard let layer = tile.layer else { return }
        let accent = Status.accent(status)
        layer.masksToBounds = false   // the ring overlay's glow/ripples aren't clipped here
        layer.backgroundColor = Status.tint(status).cgColor
        layer.borderColor = accent.withAlphaComponent(0.4).cgColor
    }

    // Re-apply the icon highlight on every live banner — called when the settings
    // toggle flips so a sticky "needs" banner starts/stops animating in place
    // (each tileRing replays for its stored status, honoring the new switch).
    func refreshHighlights() {
        for toast in toasts { toast.tileRing.refresh() }
    }

    // The L("查看", "View") beat: clicking a sticky "needs" banner acknowledges it in
    // place — the tile border/pill turn amber. The banner still stays up (you haven't
    // answered yet), but it now reads "I'm on it". No-op once checking or resolved.
    func check(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }),
              !toast.resolving, !toast.checking else { return }
        toast.checking = true
        toast.pill.configure(status: "checking", text: Status.label("checking"))
        styleTile(toast.iconTile, status: "checking")
        toast.tileRing.configure(status: "checking")
    }

    // The "walked away" beat: focus moved to a different terminal while this toast
    // was showing the watching eye — you're no longer looking, so it reverts to the
    // unanswered red exactly as it was. No-op unless it's actually checking.
    func uncheck(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }),
              toast.checking, !toast.resolving else { return }
        toast.checking = false
        toast.pill.configure(status: "needs", text: Status.label("needs"))
        styleTile(toast.iconTile, status: "needs")
        toast.tileRing.configure(status: "needs")
    }

    // The "confirmed" beat: a needs-toast whose session just answered morphs green
    // + check in place, holds a moment, then fades — so answering gets an instant,
    // unmistakable acknowledgement instead of the banner blinking out (or lingering
    // red while the state file catches up). No-op if there's no toast for the id or
    // it's already resolving.
    func resolve(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }), !toast.resolving else { return }
        toast.resolving = true

        // The ✕ is a "needs" affordance; once we're morphing to the green confirmed
        // state it's no longer relevant, so retire it. The tile frame + pill go green
        // (the icon stays the project's own) — an unmistakable "answered" beat.
        toast.closeButton?.animator().alphaValue = 0
        toast.pill.configure(status: "done", text: Status.label("done"))
        styleTile(toast.iconTile, status: "done")
        toast.tileRing.configure(status: "done")

        // Hold on the green check long enough to register, then fade + tear down.
        // Capture the instance so a replaced toast (re-show) isn't torn down by us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.remove(toast)
        }
    }

    // Dismiss any toast whose owning session is no longer live. A "needs" toast
    // never auto-times-out (you must not miss it), so without this it outlives a
    // session that ended — or changed identity — while still awaiting confirmation,
    // leaving a L("确认", "Wait") banner stranded on screen forever after the work is gone.
    //
    // Liveness is probed by the owning shell PID directly (kill(pid,0)), NOT by
    // matching against the latest scan's id set. The old id-match approach keyed on
    // SessionRow.id, which embeds cwd — and a scan can transiently drop a session
    // (processCWD momentarily fails → the row is skipped) or report a drifted cwd,
    // flipping the id. That made every extra refresh — e.g. the ones a sibling's
    // completion triggers — a chance to wrongly declare a still-live "needs" session
    // orphaned and nuke its sticky red banner ("3 reds vanish when a done appears").
    // A PID probe only fires when the shell process is genuinely gone (ESRCH), so a
    // toast survives scan omissions and cwd drift for as long as its session lives.
    //
    // ★ The PID probe alone is NOT enough: it watches the SHELL, and plenty of ways to
    // walk out on a prompt leave that shell running — quitting `claude` while the tab
    // stays open, closing an editor's chat panel (its "shell" is the extension host),
    // closing a Claude-desktop window (whose path carries no pid at all). In all of
    // those the session is gone but the red banner hung around forever. So absence from
    // the live scan counts too — with a grace window, since it was a bare absence check
    // (no grace) that used to nuke live banners on a transient scan miss.
    func retain(live: Set<String>) {
        let now = Date()
        for path in toasts.map({ $0.path }) {
            // "!"-prefixed paths (the break reminder) belong to no session: never orphaned.
            if path.hasPrefix("!") { continue }
            if !shellAlive(path) { dismiss(path); continue }
            guard !live.contains(path) else { missingSince[path] = nil; continue }
            let since = missingSince[path] ?? now
            missingSince[path] = since
            if now.timeIntervalSince(since) >= orphanGrace { dismiss(path) }
        }
        let shown = Set(toasts.map { $0.path })
        missingSince = missingSince.filter { shown.contains($0.key) }
    }

    // True unless the shell PID embedded in a toast path (…#<shellPid>) is provably
    // gone. kill(pid,0) returns 0 while the process exists and -1/ESRCH once it's
    // reaped; EPERM (exists, not signalable) still counts as alive. An unparseable
    // path is treated as alive so we never tear a banner down on a parse slip.
    private func shellAlive(_ path: String) -> Bool {
        guard let tail = path.split(separator: "#").last, let pid = pid_t(tail) else { return true }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    // A resolving toast owns its own teardown (green → check → fade), so an
    // incidental dismiss — the needs→done transition's own clear, a focus sweep,
    // a retain pass — must not yank it early. remove() is the unconditional path.
    func dismiss(_ path: String) {
        guard let toast = toasts.first(where: { $0.path == path }), !toast.resolving else { return }
        remove(toast)
    }

    // Teardown is keyed on the Toast instance, not its path: a session can bounce
    // needs→done→needs faster than the resolve hold, leaving a stale removal timer
    // that would otherwise fade the fresh red toast sharing the same path.
    private func remove(_ toast: Toast) {
        guard let idx = toasts.firstIndex(where: { $0 === toast }) else { return }
        toast.tileRing.stop()   // kill the replay loop so it doesn't outlive the banner
        let panel = toasts.remove(at: idx).panel
        // Slide out to the right + fade (Apple-notification exit), then order out.
        let out = NSRect(origin: offRight(panel.frame.origin), size: panel.frame.size)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(out, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        relayout(animated: true)   // survivors glide up to close the gap
    }

    // Resting slot for each stacked toast: flush to the right edge, stacked downward
    // from the top. Index-aligned with `toasts`.
    private func restingOrigins() -> [NSPoint] {
        guard let screen = NSScreen.main else { return [] }
        let vf = screen.visibleFrame
        let x = vf.maxX - width - margin
        var y = vf.maxY - margin - height
        var pts: [NSPoint] = []
        for _ in toasts {
            pts.append(NSPoint(x: x, y: y))
            y -= (height + spacing)
        }
        return pts
    }

    // The off-screen parking spot just past the right edge, at the same height — the
    // start of a slide-in and the end of a slide-out.
    private func offRight(_ p: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return p }
        return NSPoint(x: screen.visibleFrame.maxX + margin, y: p.y)
    }

    // Move every toast to its resting slot. Animated when the stack shifts (a sibling
    // slid out / a new one pushed in) so rows glide up/down instead of snapping.
    private func relayout(animated: Bool = false) {
        let origins = restingOrigins()
        for (i, toast) in toasts.enumerated() {
            let frame = NSRect(origin: origins[i], size: NSSize(width: width, height: height))
            if animated { toast.panel.animator().setFrame(frame, display: true) }
            else        { toast.panel.setFrame(frame, display: false) }
        }
    }

    private func makeToast(title: String, subtitle: String, icon: LogoBadge.Mode,
                           status: String, path: String,
                           onClick: @escaping () -> Void,
                           onClose: @escaping () -> Void) -> Toast {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let radius: CGFloat = 19   // softer, Apple-notification squircle
        // Opaque base + within-window frost — same recipe as the windows, so a
        // toast is fully opaque (no desktop bleeding through the banner).
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let base = OpaquePane(radius: radius)
        base.frame = host.bounds
        base.autoresizingMask = [.width, .height]
        host.addSubview(base)

        let effect = ToastSurfaceView(frame: host.bounds, radius: radius)
        effect.autoresizingMask = [.width, .height]
        effect.onClick = onClick

        // Left "app icon" tile — a rounded square framing the project's own icon
        // (LogoBadge), the whole block reading as an Apple notification. The frame's
        // border + faint wash carry the STATUS highlight (red/green/amber); the icon
        // inside is the project's fixed identity, so the two never fight.
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 12
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.borderWidth = 1.5
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(iconTile)
        // Border/wash color + the breathing highlight glow (see styleTile).
        styleTile(iconTile, status: status)

        // The project badge (VS monogram / custom emoji / terminal / desktop asterisk),
        // same source icon the list header shows — so a banner is recognizably "that
        // project" at a glance, not a bare status dot.
        let badge = LogoBadge()
        badge.configure(icon)
        iconTile.addSubview(badge)

        // The animated highlight — a RingView flourish looping around the tile in the
        // status's own RingStyle, so the banner ripples/converges/breathes in step with
        // the terminal ring. A front sibling of the tile (its empty center leaves the
        // badge visible); positioned below once layout has resolved the tile's frame.
        let tileRing = ToastTileRing(frame: .zero)
        effect.addSubview(tileRing)

        // Line 1 = the project name. Truncates (never widens the fixed-width panel);
        // project names are short, so no glyph cap is needed.
        let nameLabel = NSTextField(labelWithString: title)
        nameLabel.font = Theme.font(14.5, .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(nameLabel)

        // Line 2 = what this session is doing (its task title). Truncates to fit.
        let hintLabel = NSTextField(labelWithString: subtitle)
        hintLabel.font = Theme.font(12, .medium)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hintLabel)

        let pill = CapsuleLabel()
        pill.configure(status: status, text: Status.label(status))
        pill.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(pill)

        // Close ✕ — only on "needs" banners (the sticky red ones). Hidden until hover
        // (alpha 0). It's attached to `host` (not the rounded-masked `effect`) further
        // down, so it renders as a whole circle hanging at the corner rather than a
        // sliver sheared off by the banner's mask.
        var closeBtn: ToastCloseButton?
        if status == "needs" {
            let cb = ToastCloseButton()
            cb.onClose = onClose
            cb.alphaValue = 0
            cb.translatesAutoresizingMaskIntoConstraints = false
            effect.closeButton = cb
            closeBtn = cb
        }

        // Two-line text block (title + hint) sits centered on the icon's vertical
        // axis; the pill aligns to the title baseline like an Apple timestamp.
        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            iconTile.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 40),
            iconTile.heightAnchor.constraint(equalToConstant: 40),

            badge.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: effect.centerYAnchor, constant: -1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: effect.centerYAnchor, constant: 3),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -15),

            pill.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -15),
            pill.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])

        host.addSubview(effect)
        // ✕ goes on last, above `effect`, pinned to host's top-left corner so it floats
        // at the banner's corner (partly over the rounded-off transparent zone), like an
        // Apple notification. As a front sibling it also intercepts its own clicks.
        if let cb = closeBtn {
            host.addSubview(cb)
            NSLayoutConstraint.activate([
                cb.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
                cb.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
                cb.widthAnchor.constraint(equalToConstant: 20),
                cb.heightAnchor.constraint(equalToConstant: 20),
            ])
        }
        panel.contentView = host
        // Resolve the tile's Auto Layout frame, then hug it with the ring overlay and
        // start the loop (same "force layout, read frame, place a frame-based RingView"
        // recipe SettingsWindow's live preview uses).
        host.layoutSubtreeIfNeeded()
        tileRing.frame = ToastTileRing.frame(around: iconTile)
        tileRing.configure(status: status)
        return Toast(panel: panel, path: path, iconTile: iconTile, tileRing: tileRing,
                     pill: pill, closeButton: closeBtn,
                     sticky: status == "needs")
    }
}

// MARK: - App controller

class AppController: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    // The menu-bar pill. A VIEW inside the status button, not an image written to it —
    // writing a status button's properties leaks inside AppKit, and this used to happen
    // 10× a second. See MenuCapsule.swift for the measurements.
    private var capsule: MenuCapsuleView?
    // Last size handed to the status item, so an unchanged pill writes nothing at all.
    private var capsuleWidth: CGFloat = 0
    // Per-display resting menu-bar band (screen top → visibleFrame top), sampled every
    // poll but ONLY when the cursor isn't in that screen's top strip. Auto-hidden bar
    // rests at ≈0; always-shown bar rests at its height. Needed because at popover-open
    // time the menu bar is momentarily revealed (activation/hover), so the live
    // visibleFrame/menuBarVisible() both lie — they read "shown" and leave a dead gap.
    private var restingMenuBand: [CGDirectDisplayID: CGFloat] = [:]
    // Sampling holdoff after the popover closes (the bar it revealed hides with a lag).
    private var menuBandHoldUntil = Date.distantPast
    // While the popover is up, re-clamps its top edge to the menu bar's LIVE position
    // (the status button's window rides the bar as it slides). Without it the system
    // repositions the popover with its own margins when the bar reveals — a jump far
    // bigger than the bar height — and never moves it back up when the bar hides.
    private var popoverClampTimer: Timer?
    // Stationary invisible anchor the popover attaches to INSTEAD of the status
    // button. The button's window rides the menu bar's slide, so anchoring there
    // makes the system re-position the popover with its own animated margins on
    // every bar reveal — an unwinnable per-frame fight (our clamp only sticks after
    // that animation lands: the "slides down then jumps back" glitch). A fixed
    // anchor never moves → the system never repositions → the clamp timer alone
    // owns the y position and follows the bar smoothly. Same panel config as the
    // FocusRing overlay (required to show up on fullscreen Spaces).
    //
    // Rebuilt on every open and dropped on close — NEVER kept across opens.
    //
    // Why: after ~20h uptime spanning an external display being plugged/unplugged and
    // several sleep/wake cycles, clicking the icon stopped producing a panel entirely
    // (2026-08-12, 20:21 onward). Every click still logged isShown=1, so AppKit
    // believed it had shown; nothing was on screen. Restarting the process fixed it
    // instantly. The one structural difference we can point at: this panel was the
    // only long-lived window in the process — FocusRing builds its overlays fresh per
    // use and kept working throughout the same window of failure.
    //
    // That is circumstantial, not proven (do NOT write it up as proven — an earlier
    // attempt to confirm it via CGWindowList was a false positive; see togglePopover).
    // Rebuilding per open costs one borderless panel per click and removes the whole
    // class of "this object went stale while we weren't looking", so it is worth doing
    // on the strength of the correlation alone. See makePopoverAnchor().
    private var popoverAnchor: NSPanel?
    private let popover = NSPopover()
    private lazy var popoverController = MenuPopoverController(model: model)
    // Closes the popover on any click that lands in another app / another screen.
    // The popover is `.transient`, but we intentionally never NSApp.activate() when
    // showing it (that would drag focus to the main window's screen), so the app
    // stays inactive — and a transient popover's built-in auto-dismiss doesn't fire
    // for clicks routed to other apps. Without this, clicking another display leaves
    // the panel stranded on the wrong menu bar instead of closing.
    private var popoverClickMonitor: Any?
    // Arrow-key navigation while the popover is up: ↑/↓ move the highlighted session,
    // ⏎ jumps to it — no mouse needed. Local (not global) since the popover window is
    // key; torn down alongside the click monitor in popoverDidClose.
    private var popoverKeyMonitor: Any?
    private var rows: [SessionRow] = []
    // Subscription usage cached once per refresh — the header reads it on every
    // reload, far too often to re-read usage.json each call.
    private var usage: UsageSnapshot?
    // Shared grouping / ordering / collapse state, also handed to the main window
    // so both surfaces stay in sync.
    private let model = ListModel()
    private var dataTimer: Timer?
    private var flashTimer: Timer?
    private var lastFlashToken = ""
    // Monotonic refresh stamp + serial scan queue: every refresh() bumps the stamp and
    // enqueues its scan on `scanQueue`. Serial = scans run in dispatch order, so the
    // highest-stamp scan also reads the freshest state files; a stale snapshot can neither
    // be produced (in-order reads) nor applied (the stamp guard drops it). A concurrent
    // queue couldn't promise that — a later-stamped scan could read older files and still
    // win, which is what left the residual twitch. The stamp is touched only on main.
    private var refreshGen = 0
    private let scanQueue = DispatchQueue(label: "com.spectix.scan", qos: .userInitiated)
    // tty → (transcript identity, model read from it). Touched only from fetchRows on the
    // serial scanQueue, so no locking. See liveModelKey(tty:).
    private var liveModelCache: [String: (stamp: String, info: LiveInfo?)] = [:]
    // agent id → (its transcript's identity, the context occupancy + finished flag read
    // from it). Same thread discipline and purpose as liveModelCache. See agentTail.
    private var agentCtxCache: [String: (stamp: String, ctx: Int, finished: Bool)] = [:]
    // Watches the data dir so a hook writing state-<tty> refreshes the UI within
    // tens of ms instead of waiting up to one 2.5s poll. The timer stays on as a
    // fallback + to discover new/dead sessions (which don't touch a state file).
    private var stateWatcher: FSEventStreamRef?
    // Second, kernel-level watchers on the same dirs. FSEvents can lag or miss an
    // in-place file rewrite; a kqueue DispatchSource fires synchronously on the
    // directory's vnode write (the hook now writes via atomic rename, so every state
    // change is a dir-entry change this catches) — that's what makes the row flip the
    // instant Claude asks instead of waiting for the 2.5s poll. One per watched dir
    // (spectix state dir + the daemon sessions dir); held for the app's lifetime.
    private var dirSources: [DispatchSourceFileSystemObject] = []
    // Held for the app's lifetime to opt out of App Nap. Without it, macOS
    // throttles our timers the moment we drop to the background (which happens
    // every time a click jumps focus to VSCode), freezing the spinner *and* the
    // poll that would recover it.
    private var activityToken: NSObjectProtocol?

    private var mainWindowController: MainWindowController?

    // Global hotkeys (bindable in Settings, persisted per-action). `.open` pops the
    // session list; `.nextAttention` jumps to the next needs→done session.
    private let hotKeys = GlobalHotKeyCenter.shared
    // The session the last nextAttention jump landed on, so repeated presses cycle
    // through the candidates instead of sticking on the first one.
    private var lastJumpedId: String?
    // Where the user was working when a jump-burst began, so once every attention
    // item is cleared one more press takes them home (space + window + terminal).
    // Captured on the first jump of a burst (or whenever the press starts from a
    // non-attention spot); consumed when we return there.
    private struct JumpOrigin {
        let pid: pid_t            // frontmost app at capture time
        let wid: CGWindowID       // its focused window (0 if none) — for switchToSpace/SLPS
        let window: AXUIElement?  // focused window element, to kAXRaise on return
        let shellPid: pid_t       // >0 when the origin was a VSCode terminal we track
    }
    private var jumpOrigin: JumpOrigin?
    // Armed when an *idle* auto-jump carried you off to a prompt (only that
    // involuntary path arms it — the manual hotkey keeps its press-again-to-return
    // semantics). While armed, the moment no session still needs you the recorded
    // origin is restored automatically, so you don't have to hop back yourself after
    // confirming (the "I confirmed, now I must jump back manually" gripe).
    private var pendingAutoReturn = false
    // Continuously-tracked "home": the last app the user genuinely activated that ISN'T
    // us and ISN'T a session awaiting attention. This — not whatever is frontmost at
    // jump time — is the origin an idle auto-jump returns to. Capturing live at jump
    // time was wrong: when the SpectiX window happens to be frontmost, we'd record
    // ourselves as home and "return" to our own window instead of the doc.
    private var homeApp: JumpOrigin?

    // Last seen status per session id; used to fire a toast only on the
    // transition *into* needs/done. `primed` suppresses a burst of toasts for
    // whatever was already needs/done at launch.
    private var lastStatus: [String: String] = [:]
    private var primed = false

    // Sessions whose "needs" you just answered (needs → working), so the "done" that
    // concludes that same authorized run is a continuation — NOT a fresh "your turn"
    // completion — and must not fire a second banner on top of the green ✓ you already
    // saw. Cleared when that done arrives, or when the run ends without one.
    private var resolvedNeeds: Set<String> = []

    // Sessions the user has clicked-to-acknowledge: session id → the needs/done
    // status that was dismissed. While the real status stays equal to this, the
    // row is shown gray (L("闲置", "Idle")); once it moves on (new work) the entry is
    // dropped and the real color returns. Mutated only on the main thread.
    private var acked: [String: String] = [:]

    // ★ T144: acks are ARMED on arrival, applied on departure (改这块前必读).
    // Landing in a done session used to gray it instantly ("点绿色，跳过去直接就是灰的"),
    // which is both jarring and untrue: green means 「该你了」 and it's still your turn
    // while you sit there reading the result — you haven't replied yet. So focusing a
    // done terminal only ARMS the ack here (id → the status seen at focus time); it is
    // promoted into `acked` (→ gray) once you actually leave that session, which is the
    // moment "seen and moved on" becomes true. Typing instead flips the hook state to
    // working and the entry is dropped as stale, so the common path never grays at all.
    private var pendingAck: [String: String] = [:]

    // Sessions you've started looking at (clicked the banner, or focused the terminal)
    // while they're still "needs". Their row + toast show the amber L("查看", "View") watching
    // eye instead of dead red, until the session actually leaves "needs" (you answered).
    // View-only overlay: it never touches lastStatus/notifyTransitions, so the green ✓
    // resolve still fires off the real needs→working/done transition. Main thread only.
    private var checkingIds: Set<String> = []

    // The companion extension writes "<shellPid>:<nonce>" to active-terminal on
    // every terminal focus; `lastFocusToken` dedupes so each poll acts only on a
    // genuinely new focus, never re-acting on an unchanged value.
    private var lastFocusToken = ""

    private let dataDir = "\(NSHomeDirectory())/.claude/spectix"
    // Claude Code v2.1's daemon writes per-session status here (sessions/<pid>.json).
    // The interrupt signal that becomes "paused" (No/Esc/Ctrl+C) fires NO hook, so it
    // never touches dataDir — only this dir changes. Watched so an interrupt flips the
    // row (and flashes the paused ring) at once instead of lagging the 2.5s poll.
    private let sessionsDir = "\(NSHomeDirectory())/.claude/sessions"

    // Claude desktop app AX probe: a ~1s throttle (each tree walk costs ~100ms and
    // FSEvents fire refresh() many times a second) plus a tiny state machine that
    // synthesizes "done" (turn just finished) from the working→idle edge — see
    // desktopStatus().
    private var desktopProbeAt: Double = 0
    private var desktopCache: (pid: pid_t, windows: [DesktopWindow])?
    // Per-window latches: one app, many windows, and the chat window streaming a reply
    // must not latch `done` onto the Design row. Keyed by window number, pruned to the
    // windows still present on each probe so a closed window can't leak its state onto
    // a later window that reuses the number.
    private var desktopWasWorking: [CGWindowID: Bool] = [:]
    private var desktopDoneLatched: [CGWindowID: Bool] = [:]

    // App launch time (Unix epoch). A `done` state file written before this is a
    // completion from a previous run — the turn ended before we were watching. Showing
    // it green 完成 lights up every idle session on startup as if it just finished
    // (the "一开启就全绿" bug). Only a `done` written while we're running — a real,
    // observed completion — turns a row green; older ones fall back to 闲置.
    private let launchTime = Date().timeIntervalSince1970

    /// One-time bootstrap for machines that received the app standalone (copied in
    /// by hand rather than by the installer): copy the bundled hook scripts into ~/.claude/hooks/ and
    /// wire them into ~/.claude/settings.json. Idempotent — on a machine already wired
    /// (e.g. the dev's own), every step no-ops. All IO failures are swallowed so a
    /// read-only or hostile filesystem never blocks app launch.
    private func bootstrapHooks() {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")

        // 1. Copy bundled hook scripts → ~/.claude/hooks/, but only when missing, so a
        //    user's own hand-tuned version is never clobbered by the bundled copy.
        guard let resHooks = Bundle.main.resourceURL?.appendingPathComponent("hooks") else { return }
        try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for name in ["spectix-status.sh", "spectix-usage.py"] {
            let src = resHooks.appendingPathComponent(name)
            let dst = hooksDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        // 2. Merge hook wiring into settings.json (idempotent). Must mirror the exact
        //    command format the app reads: `~/.claude/hooks/spectix-status.sh <arg>`,
        //    where <arg> tells the script which state to write for that event.
        //    Only once the script is actually on disk: wiring an event to a missing
        //    command makes Claude Code error on every single prompt, which is worse
        //    than this app simply showing nothing.
        guard fm.fileExists(atPath: hooksDir.appendingPathComponent("spectix-status.sh").path)
        else { return }
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let hookCmd = "~/.claude/hooks/spectix-status.sh"
        let events: [(String, String)] = [
            ("UserPromptSubmit", "working"), ("PreToolUse", "working"),
            ("PostToolUse", "working"), ("Stop", "done"),
            ("Notification", "needs"), ("PermissionRequest", "needs"),
            ("SessionStart", "session-start"),
        ]

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for (event, arg) in events {
            var arr = hooks[event] as? [[String: Any]] ?? []
            // Already wired for this event? Any entry whose command names our script —
            // OR the pre-rename one (T172). A machine wired before the rename still runs
            // taskbeacon-status.sh; matching only the new name would append a SECOND
            // entry and leave both hooks writing state for the same tty. This passive
            // path can't clean up (it must never touch a user's own edits), so it only
            // declines to make it worse; the installer is what actually retires the old
            // wiring — see InstallerCore.wireSettings.
            let already = arr.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains {
                    let cmd = ($0["command"] as? String) ?? ""
                    return cmd.contains("spectix-status") || cmd.contains("taskbeacon-status")
                } ?? false
            }
            if already { continue }
            arr.append(["hooks": [["type": "command", "command": "\(hookCmd) \(arg)"]]])
            hooks[event] = arr
            changed = true
        }
        guard changed else { return }   // fully wired already → touch nothing
        root["hooks"] = hooks
        if let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular = full app with a Dock icon + main window (not a pure menu-bar
        // accessory). The status item and toasts still work alongside it.
        NSApp.setActivationPolicy(.regular)

        // Restore the saved light/dark override before any window is built, so
        // every pane resolves its colors under the right appearance from frame one.
        AppSettings.applyAppearance()

        // First launch on this machine opts into the login item (设置 → 显示 → 应用 turns
        // it back off). No-op on every launch after that.
        AppSettings.seedLaunchAtLogin()

        // Same shape: wire ~/.claude ourselves for a hand-copied app (no installer run).
        // Idempotent, so it no-ops on every already-wired machine — but it must run
        // BEFORE the watchers below, or the first session after a fresh copy reports
        // nothing until the next launch.
        bootstrapHooks()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        // A click toggles a popover (not a native NSMenu) — the dropdown hosts the
        // same drag-reorderable list as the main window, which a menu's modal
        // tracking loop can't support.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Left-click toggles the popover; right-click drops a tiny quit menu (the
        // only quit entry, since the popover's power button is gone).
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        // No open animation: togglePopover() repositions the popover window to an
        // absolute y right after show(), and an in-flight animation would fight
        // that setFrame (the window would slide back to the system-chosen spot).
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = popoverController
        wirePopover()

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Live Claude session monitoring")

        // Global hotkeys — bind each action's saved (or default) combo so it works
        // from any app. A nil combo means the user cleared that binding.
        for action in HotKeyAction.allCases {
            hotKeys.bind(action, combo: HotKeyStore.load(action)) { [weak self] in
                self?.fireHotKey(action)
            }
        }

        // Settings changes that affect WHICH rows exist (hide/unhide a project)
        // need a full re-scan, not the list's view-only re-render — otherwise a
        // hidden session lingers until the next 2.5s poll. Cheap enough to re-scan
        // on any settings change; toggles are rare.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange),
            name: AppSettings.didChange, object: nil)
        NotificationCenter.default.addObserver(
            forName: BreakReminder.restStarted, object: nil, queue: .main) { _ in
            ToastManager.shared.dismiss(Self.breakToastPath)
        }

        // A language switch changes text baked into statically-built labels, so the
        // windows + popover must be rebuilt wholesale to re-resolve through L().
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: AppSettings.languageDidChange, object: nil)

        // A theme switch is the same shape of problem: colors, radii and material
        // are baked into layers when views are built, so no amount of re-rendering
        // in place will re-tint them — the same wholesale rebuild is required.
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: AppSettings.themeDidChange, object: nil)

        // A fetched quota reading arrives asynchronously (a switch fires one), and so
        // does the spinner that says one is on its way. Redraw on both edges rather
        // than letting the 2.5s poll pick them up: this is the one place where a poll's
        // delay is the entire cost the request was spent to avoid. Rows are unchanged,
        // so this re-renders what we already have — no re-scan.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accountQuotaDidChange),
            name: AccountBook.quotaDidChange, object: nil)

        lastFocusToken = readFocusToken()   // prime: ignore whatever focus is already recorded
        TerminalFocusRing.shared.prewarm()  // expand VSCode's a11y tree before the first jump
        // Pop the main window on launch. Deferred to the next runloop tick: this app
        // starts as an LSUIElement accessory and flips to .regular just above, and a
        // showWindow() issued synchronously here (before that policy change settles)
        // gets its order-front swallowed — the window never appears, only the Dock
        // icon does. By the next tick launch is complete (same state the reopen path
        // runs in, which works), so the window shows reliably.
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        refresh()
        // Surface the one permission this app needs up front, so the user enables it
        // before discovering a dead-feeling click later (rather than on first jump).
        requestAccessibilityIfNeeded()
        // Scheduled on .common so they keep firing while the status-bar menu is
        // open (event-tracking mode); App Nap is handled by activityToken above.
        let dt = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Click-flash needs sub-second reaction; the 2.5s data poll is way too
        // slow, so a dedicated cheap check (one string read + compare) runs fast.
        let ft = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkFocusFlash() }
        RunLoop.main.add(dt, forMode: .common)
        RunLoop.main.add(ft, forMode: .common)
        dataTimer = dt
        flashTimer = ft
        lastFlashToken = readFocusToken()   // prime: never flash a pre-launch focus

        startStateWatcher()
        startDirSource(dataDir, create: true)
        startDirSource(sessionsDir, create: false)

        // Track "home" (where the user is working) so an idle auto-jump can bring them
        // back. Fires whenever the frontmost app changes; we snapshot only genuine home
        // spots (not ourselves, not an attention session, not mid-jump-burst).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Switching apps is also when an editor's window titles are most likely to
            // have changed (you were just in there) — re-confirm them on the next scan.
            self?.requestForceAXScan()
            self?.trackHome()
            self?.ackOnAppSwitch()
        }
        // AX lists only the CURRENT Space, so the window cache accumulates as you move
        // between them. Now that the AX pass is gated, a Space switch has to force the
        // next one: otherwise a window on the Space you just arrived at could stay
        // unknown — and therefore unjumpable — for up to axRescanInterval.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.requestForceAXScan()
            self?.refresh()
        }
        // Displays changed (plugged, unplugged, rearranged, resolution). Only the main
        // window needs anything here: unplugging the display it sits on can strand it at
        // coordinates no screen covers, and our one rescue for that runs a single time
        // inside showMainWindow() — so a window that is ALREADY open never gets re-checked.
        // Everything else survives on its own and is deliberately left alone: the AX/window
        // caches are keyed by CGWindowID (unaffected by displays) and validate-then-evict at
        // use, and every screen-coordinate cache is either recomputed per use or gated on
        // exact-bounds equality, which a display change breaks by itself. Idempotent — it
        // recenters only when the frame intersects no screen at all.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.ensureWindowOnScreen()
        }
        trackHome()
        maybeShowEditorReloadHint()
    }

    // Update `homeApp` — where the user is working — from the LIVE frontmost app + the
    // active-terminal token. Read live (not from the activation event) so it also catches
    // switches BETWEEN windows/terminals of one app (VSCode's Harvest-Tycoon window vs its
    // SpectiX window share one pid, so NSWorkspace fires no activation event between
    // them — the very case that returned to the wrong terminal). Called from the
    // activation observer, the 0.3s focus-token watcher, and each refresh, so any way the
    // user moves is caught. Skips: ourselves (returning to our own window is useless) and
    // a session currently awaiting you (that's a jump *target*, not home). Not gated on
    // jumpOrigin — returnToOrigin uses the origin captured at arm time, so keeping homeApp
    // fresh mid-burst is safe and stops a stale burst from freezing tracking.
    private func trackHome() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !appIsAttentionSession(app),
              let snap = originSnapshot(of: app) else { return }
        homeApp = snap
    }

    // Switching to an app that doesn't host an armed session = you left that session, so
    // its ack applies and the row grays (T144). Activating OURSELVES is not leaving —
    // opening the list to check on the session you're working in shouldn't gray it out
    // from under you — and neither is switching to its own host app (another window of
    // the same editor is handled by the per-terminal focus report instead).
    private func ackOnAppSwitch() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier else { return }
        promotePendingAck(exceptHost: bid)
    }

    // Whether `app` is (the editor window hosting) a session that currently needs you —
    // i.e. a jump target rather than a home. Mirrors frontmostIsInPool but for an
    // arbitrary app against the live needs/paused pool.
    private func appIsAttentionSession(_ app: NSRunningApplication) -> Bool {
        let pool = rows.filter { $0.awaitsYou }
        if pool.isEmpty { return false }
        if let bid = app.bundleIdentifier, EditorApp(rawValue: bid) != nil {
            guard let head = readFocusToken().split(separator: ":").first,
                  let p = pid_t(head) else { return false }
            return pool.contains { $0.shellPid == p }
        }
        if app.bundleIdentifier == "com.anthropic.claudefordesktop" {
            return pool.contains { $0.isDesktop }
        }
        return false
    }

    // kqueue directory watcher — the instant path. Fires on the kernel vnode event
    // for any dir-entry change (the hook's atomic rename), with no latency parameter
    // to batch it. Runs alongside FSEvents as belt-and-suspenders; refresh() is
    // idempotent so a double fire from both watchers is harmless.
    // `create`: true for our own dataDir (make it if missing); false for the daemon's
    // sessions dir — never ours to create, so if it's absent (no v2.1 session yet) we
    // just skip the kqueue and lean on FSEvents (which tolerates a not-yet-existing path).
    private func startDirSource(_ dir: String, create: Bool) {
        if create {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSources.append(src)
    }

    // Event-driven refresh: an FSEvents stream on the data dir fires the moment a
    // hook writes a state-<tty> file (e.g. you answer a prompt → "working"), so the
    // UI flips immediately instead of lagging behind the 2.5s poll. Latency 0 ⇒ no
    // batching, deliver ASAP; the kqueue dirSource backs it up for instant delivery.
    fileprivate static func isWatcherNoise(_ name: String) -> Bool {
        if name.hasSuffix(".log") { return true }
        guard name.hasSuffix(".json") else { return false }
        return name.hasPrefix("terminals-") || name.hasPrefix("window-")
    }

    private func startStateWatcher() {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // ★ Skip batches made only of writes no row depends on. The companion extension
        // rewrites terminals-/window-<pid>.json every 2s per editor window as a liveness
        // heartbeat (readers go by mtime, so it can't write-on-change), and our own
        // *-diag.log files live here too — each used to kick a full 700-pid scan, which
        // was most of a 6-day, ~5 CPU-hour burn (measured 2026-09-24: 55 of 85 writes in
        // 20s were these). Those files still get read on the 2.5s dataTimer poll.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info = info else { return }
            let ps = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let relevant = (0..<count).contains { i in
                let name = (String(cString: ps[i]) as NSString).lastPathComponent
                return !AppController.isWatcherNoise(name)
            }
            guard relevant else { return }
            Unmanaged<AppController>.fromOpaque(info).takeUnretainedValue().refresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [dataDir, sessionsDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        stateWatcher = stream
    }

    // MARK: Data

    @objc private func settingsDidChange() { refresh() }

    /// Only the header's figures moved, so re-render the rows we already have rather
    /// than calling refresh() — that would kick a full process scan for a change that
    /// cannot possibly have altered the session list.
    @objc private func accountQuotaDidChange() { renderRows() }

    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    // Sample each screen's resting menu-bar band. Two contamination guards:
    // (1) skip entirely while our own popover is up — opening it (click or hotkey)
    //     reveals an auto-hidden bar for as long as it's shown, and the 2.5s poll keeps
    //     running meanwhile, so a sample then would freeze the revealed height as
    //     "resting" and leave a dead gap on the next open (the stale-25pt bug);
    // (2) skip a screen while the cursor is in its top strip — hovering there reveals
    //     the bar too, misclassifying auto-hide as always-on.
    private func sampleMenuBands() {
        if popover.isShown || Date() < menuBandHoldUntil { return }
        let mouse = NSEvent.mouseLocation
        for s in NSScreen.screens {
            if NSMouseInRect(mouse, s.frame, false) && mouse.y > s.frame.maxY - 40 { continue }
            restingMenuBand[AppController.displayID(s)] = max(0, s.frame.maxY - s.visibleFrame.maxY)
        }
    }

    // The band the menu bar occupies on this screen RIGHT NOW. Preferred signal:
    // the status button's own window — it rides the bar as it slides, so (screen
    // top − its bottom) is the bar's live onscreen depth: full height when shown,
    // ≤0 when parked offscreen. Falls back to the fullscreen/resting-sample logic
    // when that window is on another display. Never less than the physical notch
    // inset (safeAreaInsets.top; 0 on externals → flush to the top).
    private func popoverBand(screen: NSScreen) -> CGFloat {
        let safeTop = screen.safeAreaInsets.top
        if let bw = statusItem.button?.window, bw.screen === screen {
            return max(safeTop, screen.frame.maxY - bw.frame.minY)
        }
        let did = AppController.displayID(screen)
        let resting = restingMenuBand[did]
            ?? max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return isFullscreenSpace(display: did) ? safeTop : max(safeTop, resting)
    }

    // Pin the popover's top edge to the current band (see popoverBand).
    private func clampPopoverTop(win: NSWindow, screen: NSScreen) {
        var f = win.frame
        let targetY = screen.frame.maxY - popoverBand(screen: screen) - f.height
        guard abs(f.origin.y - targetY) > 0.5 else { return }
        f.origin.y = targetY
        win.setFrame(f, display: true)
    }

    private func refresh() {
        if Demo.enabled { renderDemo(); return }
        if demoStageTried { unstageDemoTerminals() }

        let t0 = Date()
        if ProcessInfo.processInfo.environment["TB_DEBUG"] != nil {
            NSLog("TB refresh() fired")
        }
        sampleMenuBands()
        // Three sources drive refresh() — the 2.5s dataTimer, the FSEvents stream, and
        // the kqueue dirSource — all on the main thread. Each bumps refreshGen and hands
        // the (variable-length) process scan to the SERIAL scanQueue. Two guards then keep
        // exactly one scan meaningful: the head guard skips the expensive scan outright when
        // a newer refresh has already been queued (burst coalescing — a flurry of FSEvents
        // during an active turn collapses to a single real scan), and the tail guard drops
        // any snapshot a newer refresh superseded. Serial ordering means the surviving
        // (latest) scan also read the freshest state files, so a row can no longer flash
        // back a frame to a stale color (the needs→done→needs / idle→needs→idle twitch).
        refreshGen &+= 1
        let gen = refreshGen
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            // Burst coalescing: bail before the scan if a newer refresh already superseded
            // us. Reading refreshGen on main keeps it single-threaded; scanQueue→main.sync
            // can't deadlock (the main thread never waits back on scanQueue).
            if DispatchQueue.main.sync(execute: { gen != self.refreshGen }) { return }
            let realRows = self.fetchRows()
            // Keep the cwd→VSCode-window-id cache current off the same scan, so a jump
            // can switch Spaces without Screen Recording (see vscodeWindowCache).
            let vscodeWins = self.scanVSCodeWindows()
            DispatchQueue.main.async {
                guard gen == self.refreshGen else { return }
                self.updateVSCodeWindowCache(seen: vscodeWins.seen, live: vscodeWins.live)
                let rows = self.applyAck(realRows)
                self.rows = rows
                self.logLiveCount(rows)
                // Always-on rings: keep a steady status-colored ring on every
                // visible Claude terminal pane (no-op unless ringAlwaysOn is set).
                TerminalFocusRing.shared.updateAlwaysOn(rows: rows)
                // Corner status pips: a status dot in each visible terminal's top-right
                // corner (no-op unless cornerPips is set). Separate ledger and overlay
                // level from the rings above — see StatusPip.swift.
                TerminalStatusPips.shared.update(rows: rows)
                #if DEV_BUILD
                AXProbe.pollMarker()
                #endif
                // Measure the panes ahead of the jump that will want them, so the ring
                // and caption land at 0ms instead of after the token/AX resolve. Cheap
                // by design: no AX work at all once every visible pane is warm.
                TerminalFocusRing.shared.warmPaneMemo(rows: rows)
                // Keep a 常驻 caption+ring tracking its session's live status/title
                // (the one-shot overlay is otherwise frozen at jump/click time).
                TerminalFocusRing.shared.refreshLiveCaption(rows: rows)
                // Remember every live project dir so the 最近项目 window can
                // reopen it after its VSCode window is closed.
                ProjectHistory.record(rows.map { $0.cwd })
                // Open-but-session-less VSCode windows get a header-only group. Computed
                // here (after the window cache merge above, so it sees this scan's windows)
                // and stashed on the model, which renderRows() then reads.
                self.model.setEmptyProjects(
                    self.openProjectsWithoutSessions(activeCwds: Set(rows.map { $0.cwd })))
                self.usage = self.loadUsage()
                // While a panel is up you're actively reading the quota — keep it
                // fresh even mid-turn (the hook's turn-end probe can't fire then).
                if self.popover.isShown
                    || self.mainWindowController?.isShown == true {
                    self.requestUsageProbe(minAge: 75)
                }
                self.updateButton()
                // Before both automatic jump paths (notifyTransitions runs the
                // answered-chain): decides whether the user is mid-way through a prompt
                // and must therefore not be carried anywhere.
                self.updateParkedAttention(rows)
                self.notifyTransitions(rows)
                self.trackHome()
                self.maybeIdleAutoJump(rows)
                self.maybeRemindBreak(rows)
                self.maybeAutoReturn(rows)
                // Focus handling runs before the render so a just-focused "needs"
                // session shows its L("查看", "View") eye in the SAME pass (no one-poll lag).
                self.dismissFocusedToast()
                self.pruneChecking()
                self.renderRows()
                if ProcessInfo.processInfo.environment["TB_DEBUG"] != nil {
                    NSLog("TB refresh() done in %.0f ms", Date().timeIntervalSince(t0) * 1000)
                }
            }
        }
    }

    // Build one row per live Claude session by discovering them ourselves.
    //
    // We don't shell out to c9watch anymore: Claude Code v2.1's daemon/bg-pty-host
    // architecture stopped putting `--session-id` in the argv of interactive
    // terminal sessions, so any argv-scraping tool silently misses them (that was
    // the "3 VSCode windows but only 1 shows" bug). Instead we enumerate processes,
    // keep the interactive `claude` ones, and read each one's cwd, parent-shell pid
    // and tty (via libproc). Status comes from the per-tty state file the hook writes.
    // Each process is its own row, so two AIs sharing one VSCode window show separately.
    private func fetchRows() -> [SessionRow] {
        let sessions = discoverSessions()
        // A folder is "shared" when >1 session live in it; those rows get a short
        // session number appended to the title so they're distinguishable at a glance.
        var folderCount: [String: Int] = [:]
        for s in sessions { folderCount[s.cwd, default: 0] += 1 }

        // Stable 1-based number per session (ordered by parent-shell pid) so the
        // fallback label reads "会话 01 / 02" instead of the ttysNNN device name.
        var seqOf: [pid_t: Int] = [:]
        for (i, pid) in sessions.map({ $0.seqKey }).sorted().enumerated() { seqOf[pid] = i + 1 }

        // Per-session usage. Parse the append-only event log once and group by tty;
        // each session sums only its own run→done spans (time) and done-event token
        // tallies since it began (see sessionUsage). Token fields land on done events
        // only when the session writes a transcript — sessions that inherit
        // CLAUDE_CODE_CHILD_SESSION skip the write and fall back to per-project totals.
        var eventsByTty: [String: [UsageEvent]] = [:]
        // The model each tty last completed a turn on, carrying WHEN and WHERE that turn
        // happened. Walking the log in order and overwriting leaves the newest one
        // standing, so a mid-session /model switch is picked up at the next turn end.
        // Deliberately NOT clipped to the usage boundary: a /clear changes the
        // conversation, not the model.
        //
        // ★ ts+cwd ride along because a tty OUTLIVES the session that wrote those events
        // (改这里前必读). Terminals get reused: ttys007 ran TaskBeacon on Fable at 01:47
        // and another project on Sonnet at 20:29 the same day, and until that second session
        // finished its first turn a bare per-tty lookup put the Fable label — another
        // project's model, hours stale — on that other project's row. The reader below only
        // accepts the entry when it provably belongs to THIS session.
        var modelByTty: [String: (model: String, ts: Int, cwd: String)] = [:]
        for e in StatsStore.parse(StatsStore.logPath) {
            guard let t = e.tty else { continue }
            eventsByTty[t, default: []].append(e)
            // Only done events carry a model, and only a real "claude-…" id is one — a
            // local/non-API turn logs "<synthetic>", which must not overwrite the last
            // genuine model. Cheap prefix test, not a full parse: this runs per log line.
            if e.event == "done", let m = e.model, m.hasPrefix("claude-") {
                modelByTty[t] = (m, e.ts, e.cwd ?? "")
            }
        }
        // Fallback token source: per-project totals from Claude Code's own state file,
        // shared by sibling sessions in one folder (see loadTokensByCwd).
        let tokensByCwd = loadTokensByCwd()
        // Context-window limit per project (200k / 1M), from the cwd's last model in
        // ~/.claude.json — drives each row's context-occupancy gauge denominator.
        let modelKeyByCwd = loadModelKeyByCwd()
        let ctxLimitByCwd = ctxLimits(from: modelKeyByCwd)
        let now = Date().timeIntervalSince1970

        // Real status only; ack-overlay + final sort happen on the main thread.
        var rows: [SessionRow] = sessions.map { s in
            let folder = (s.cwd as NSString).lastPathComponent
            let seq = seqOf[s.seqKey] ?? 0
            let dup = (folderCount[s.cwd] ?? 0) > 1
            let title = dup ? "\(folder) · \(String(format: "%02d", seq))" : folder
            // A "needs" row means a PermissionRequest hook fired when a dialog appeared,
            // but Claude Code emits no hook the instant you APPROVE — see runningToolShells.
            // If a command that started AFTER the dialog is running, you've approved and
            // work resumed: paint 蓝, not 红. The `needs` write time = the state file mtime.
            var status = sessionStatus(tty: s.tty)
            if status == "needs" {
                let since = fileMTime("\(dataDir)/state-\(s.tty)")
                if runningToolShells(kind: s.kind, claudePid: s.claudePid, since: since).count > 0 {
                    status = "working"
                }
            } else if status == "done",
                      fileMTime("\(dataDir)/state-\(s.tty)") < launchTime {
                // Stale completion from before the app started watching — show 闲置,
                // not a fresh green 完成. A done observed live keeps its newer mtime.
                status = "idle"
            }
            // A backgrounded Bash command (run_in_background) outlives the main turn's
            // Stop: its command shell stays a live child of `claude` while the row reads
            // done/idle. Per T54 this is NOT "busy" — a background command doesn't hold
            // the main loop, you can talk to Claude directly while `npx expo run:ios`
            // compiles — so the row must not flip to 运行中(蓝). But it is not 完成 either:
            // the model wakes by itself when the command exits, so nothing is yours to
            // do yet. That third answer is `await` (青「等待」, T312) — forced over done AND
            // stale idle, so a live background command always reads as 等待 and never
            // trips the daemon idle→paused branch below. A dev server that runs for hours
            // keeps its row on 等待 by design (the subtitle carries the elapsed time).
            //
            // Keep the COUNT regardless: the "▸ N 个后台命令运行中" subtitle (rendered on
            // the await row, see MainWindow) says how many and for how long. `since` is 0
            // (no start-time guard): the
            // shell predates the Stop, and done/idle has no pending dialog to confuse a
            // lingering shell with. The shell-snapshot signature (see runningToolShells)
            // keeps this from counting long-lived MCP-server shells.
            var bgShells = 0
            var bgShellsSince = 0.0
            if status == "done" || status == "idle" {
                let probe = runningToolShells(kind: s.kind, claudePid: s.claudePid, since: 0)
                bgShells = probe.count
                bgShellsSince = probe.oldest
                if bgShells > 0 { status = "await" }
            }
            // Daemon authority for two cases the tty-keyed hooks structurally miss.
            // Override last — after the runningToolShells probe — so a lingering
            // dev-server shell can't win. The daemon's per-session status:
            //   "waiting" = parked on a pending interaction you must answer (permission
            //               / question / plan). A BACKGROUND subagent's permission
            //               request fires no PermissionRequest hook on the parent tty,
            //               so the state file stays pinned at working by the bg ledger
            //               while the session actually sits waiting on you → force needs.
            //   "idle"    = turn ended, back at the input prompt. Reached by a genuine
            //               Stop (hook already wrote done 绿) OR by an INTERRUPT — a
            //               rejected permission (No/Esc) or a mid-run Ctrl+C, neither of
            //               which emits ANY hook, so the state file stays stuck at
            //               needs(红)/working(蓝) forever (the "拒绝后一直红" bug; the
            //               hook's idle_prompt→paused fallback measured NOT firing —
            //               a real session sat red 49 min). When the hook still says
            //               needs/working but the daemon has since gone idle, the turn
            //               was interrupted, not completed → paused (洋红「暂停」).
            let daemon = daemonSessionStatus(s.claudePid)
            if daemon.status == "waiting" {
                status = "needs"
            } else if daemon.status == "busy", status == "needs",
                      daemon.updatedAt > fileMTime("\(dataDir)/state-\(s.tty)") {
                // You just answered the prompt (AskUserQuestion / ExitPlanMode / a
                // permission approval) and the model resumed thinking — but that answer
                // emits NO hook until the next PreToolUse, so the state file stays pinned
                // at needs(红) through the whole think phase (the "答完还红一会儿" bug).
                // runningToolShells can't rescue it: nothing is spawned yet while the
                // model reasons. The daemon flips to busy the instant you answer, so a
                // busy write NEWER than the needs write = answered, work resumed → 蓝.
                // Guard updatedAt > state mtime so a dialog that just appeared (daemon
                // still on its pre-dialog busy, older than the needs write) stays red.
                status = "working"
            } else if daemon.status == "idle", status == "needs" || status == "working",
                      bgShells == 0,
                      daemon.updatedAt > fileMTime("\(dataDir)/state-\(s.tty)") {
                // bgShells > 0 excluded (belt-and-suspenders): a live background command
                // forces status=await above, so it can't reach this needs/working
                // branch anyway — but keep the guard so a running background command can
                // never be read as 洋红「暂停」 (interrupted/stuck) while work continues,
                // which is the whole complaint this branch must not cause.
                // Guard on updatedAt > state mtime: the daemon idle must be NEWER than
                // the hook's needs/working write. A just-started turn (PreToolUse wrote
                // working now, daemon still on its previous idle) has an OLDER daemon
                // idle → excluded, so a fresh 运行中 never flickers to 暂停. A genuine
                // Yes goes waiting→busy (never idle), so approving never trips this.
                status = "paused"
            }
            // ★ Staleness gate for 运行中 (the "冻死的会话一直显示蓝色" bug, 2026-08-25).
            // BOTH signal sources can go silent at once, and when they do every branch
            // above votes 蓝. A turn that ends without a Stop — background agents launched,
            // their wake-up notification never lands — emits no further hook, so
            // state-<tty> keeps its last `working` indefinitely; and sessions/<pid>.json
            // records the last status CHANGE, not a heartbeat, so it freezes on the same
            // stale `busy`. No daemon branch above matches busy+working, and their
            // `updatedAt > state mtime` guards can never fire against a state file that
            // also stopped moving — the daemon rescue structurally retires exactly when
            // it is needed most. `done` has had a staleness check since day one (above);
            // `working` had none, so a row frozen six days ago painted identically to one
            // written a second ago (observed: a .claude session frozen 6 days reading
            // 运行中 the whole time, its ledger agent long since end_turn). 蓝 reads as
            // "busy, leave it alone", so a false 蓝 is the one that costs you days.
            // Require BOTH stale — but know what each one actually buys, because the
            // daemon one is WEAKER than it looks. `daemon.updatedAt` is the last status
            // CHANGE, not a heartbeat: it stamps once when a turn flips to busy and then
            // sits still for the entire turn (measured: a session actively running tools
            // read a 668s-old `busy` while its state file was 2s old). So it only guards
            // roughly the first 600s of a turn; past that it goes stale right alongside
            // the state file and the real gatekeepers are the other two. Keep it anyway —
            // it can only make the gate MORE conservative, never less. Editor chat rows
            // have no `status`/`statusUpdatedAt` at all (see docs/session-status.md), so
            // for them `updatedAt` is 0 and this condition is permanently true.
            // The other two do carry their weight: ANY tool event refreshes the state
            // file (including a background subagent's — its hooks key to the parent tty),
            // and a long foreground command leaves a live command shell. The shell probe
            // runs LAST — it is a process scan, and the two cheap mtime tests short-
            // circuit it away on every healthy row. 600s matches the hook's own
            // stale-ledger sweep threshold.
            var frozen = false
            if status == "working",
               now - fileMTime("\(dataDir)/state-\(s.tty)") > 600,
               now - daemon.updatedAt > 600,
               runningToolShells(kind: s.kind, claudePid: s.claudePid, since: 0).count == 0 {
                status = "paused"
                frozen = true
            }
            // Count this session's time/tokens from whichever is later: the claude
            // PROCESS start (covers a brand-new terminal — new PID zeroes naturally) or
            // the last real /clear within that process. The hook stamps clear-boundary
            // ONLY on source=clear, never startup — reconnects fire startup constantly
            // and stamping there is what used to lop the count back to ~0 (the old
            // session-<tty> bug). So /clear now zeroes the counters; reconnects don't.
            let procStart = processStartEpoch(s.claudePid) ?? 0
            let boundary = max(procStart, fileEpoch("\(dataDir)/clear-boundary-\(s.tty)"))
            // Count the in-flight run's live seconds while the turn is still open —
            // "working" AND "needs": a session awaiting a permission/plan/question is
            // still mid-turn (the run event fired, no done yet) and WILL resume and
            // complete, so its clock should keep ticking, not vanish. Gating this to
            // working alone made the ⏱ time (and, on turn 1, the whole usage line) drop
            // out the instant the row went 需确认 — the "确认时时间/token/上下文都不显示" bug.
            // "paused" (Esc-interrupted, no done ever comes) stays frozen — excluded.
            // A needs row does NOT then run all night: WorkClock caps the gap after the
            // dialog, so its clock ticks a couple of minutes and holds (T146).
            // Hoisted out of the row body: the agent roster below needs it too, and it
            // must exist before the initializer (see T314 note).
            let baseCtxLimit = ctxLimit(for: s.cwd, in: ctxLimitByCwd)
            let usage = sessionUsage(eventsByTty[s.tty] ?? [], boundary: boundary,
                                     inFlight: status == "working" || status == "needs",
                                     now: now)
            // ★ T314: subagents still out → 等待 (await), never 完成 (绿). This reverses
            // the half of T54 that let a parked main turn keep reading "done": the green
            // dot, its banner and the chime all say "your turn", and nothing IS yours
            // until every agent is back — the session wakes ITSELF on the task-notification
            // and carries on. Same third answer T312 gave background Bash commands,
            // reached from the other signal source: a hook-written ledger here, a live
            // process probe there.
            // Only done/idle are overridden: a daemon-detected needs (a subagent asking
            // for permission) outranks this and must stay red.
            // The count comes from the ROSTER, which drops an agent the moment its own
            // transcript ends the turn — so this self-heals without waiting for the hook's
            // wake-up retire or the 600s sweep, and a leftover ledger line can't pin a row
            // 青 forever (it only can on a pre-roster hook, where the count falls back to
            // the raw ledger — bounded by that same sweep).
            // Computed HERE, above the row, because SessionRow.status is a `let`: the
            // status has to be final before the initializer runs. The window handed to
            // the roster is the cwd-derived one rather than a Codex row's own — Codex
            // sessions never have an agent ledger (the hook's Task bookkeeping is Claude
            // Code's), so that roster is always empty and the limit never reaches a node.
            let agentRoster = backgroundAgents(tty: s.tty, ctxLimit: baseCtxLimit)
            let agentCount = backgroundAgentCount(tty: s.tty, roster: agentRoster.count)
            if agentCount > 0, status == "done" || status == "idle" { status = "await" }
            var row = SessionRow(title: title, folder: folder, cwd: s.cwd,
                                 shellPid: s.shellPid, tty: s.tty,
                                 status: status,
                                 taskTitle: sessionTitle(tty: s.tty), seq: seq)
            row.agentKind = s.kind
            row.workSec = usage.workSec
            // Prefer the session's own logged token tallies (exact, per-tty); only
            // sessions with no logged tokens fall back to the shared project total.
            // ★ The fallback is gated on the whole PROCESS, not on the boundary (T185).
            // Right after a /clear the boundary-scoped tally is legitimately 0, and a
            // plain `usage.tokens > 0` test would hand that row the cwd cumulative
            // instead — so ◆ wouldn't just fail to reset, it would jump to a BIGGER
            // number. A tty that has logged a token at any point in this process owns
            // its figure and keeps it, zero included.
            let loggedTokens = (eventsByTty[s.tty] ?? []).contains {
                $0.event == "done" && Double($0.ts) >= procStart
                    && ($0.tok_in ?? 0) + ($0.tok_out ?? 0)
                        + ($0.tok_cache_w ?? 0) + ($0.tok_cache_r ?? 0) > 0
            }
            if usage.tokens > 0 || loggedTokens {
                row.tokens = usage.tokens
                row.tokensExact = true
            } else {
                row.tokens = tokensByCwd[s.cwd] ?? 0
            }
            // Current context occupancy (last assistant message's input side) + the
            // model's window limit, for the per-row context gauge. ctxTokens comes from
            // the hook's ctx-<tty> (0 = no transcript / freshly cleared); ctxLimit from
            // the model behind this cwd (loadCtxLimitByCwd), falling back to the account's
            // default window when this cwd has no lastModelUsage entry of its own.
            // One tail scan feeds both the context gauge and the model chip.
            // ★ Claude-only. liveInfo parses CLAUDE's transcript schema, and Codex parks
            // a rollout file at the same tp-<tty> pointer — so this would happily tail a
            // multi-MB file every poll to find none of the keys it wants. Returning nil
            // by construction is cheaper and, more importantly, honest: "I did not look"
            // is a different thing from "I looked and found nothing", and only the first
            // one stays correct if Codex's format ever drifts toward Claude's.
            let live = s.kind == .claude ? liveInfo(tty: s.tty) : nil
            // Live occupancy updates DURING a turn; the hook's ctx-<tty> only lands at
            // Stop, so it's the fallback (no pointer yet / transcript unreadable). 0 from
            // either means "nothing captured" — freshly cleared, or no transcript at all.
            row.ctxTokens = (live?.ctxTokens ?? 0) > 0
                ? live!.ctxTokens
                : fileInt("\(dataDir)/ctx-\(s.tty)")
            row.ctxLimit = baseCtxLimit
            // Freshest first: the live transcript tail (updates mid-turn), then this
            // session's own last completed turn, then the project's last model — only
            // reached when the session has never completed one (fresh terminal, or no
            // transcript).
            //
            // "This session's own" is a claim that has to be EARNED, not assumed from the
            // tty alone: the log entry must post-date this claude process. procStart == 0
            // means we couldn't read the process (the time test then passes vacuously), so
            // that case falls back to matching the cwd — either way a terminal's previous
            // occupant never gets to speak for the session sitting in it now.
            let ownModel: String? = modelByTty[s.tty].flatMap { e -> String? in
                guard Double(e.ts) >= procStart,
                      procStart > 0 || e.cwd == s.cwd else { return nil }
                return e.model
            }
            let sessionModel = live?.model ?? ownModel
            row.model = Self.modelLabel(sessionModel
                                        ?? modelKey(for: s.cwd, in: modelKeyByCwd))
            // The cwd's window is its project's LAST model, not this session's: a
            // session on native-1M Opus 5.5 in a dir last used with a 200k model read ~5x
            // high. Upgrade-only — transcript ids never carry "[1m]", so a 1M-beta
            // session's own id can't prove a 200k window and must not downgrade it.
            if let m = sessionModel, Self.isNative1M(m) { row.ctxLimit = 1_000_000 }
            // ★ Codex enrichment. Every number above this line came from a Claude-private
            // source — events.jsonl's per-turn token tallies, ~/.claude.json, the Claude
            // transcript — and all of them are legitimately empty for a Codex session, so
            // the row would render three blank columns. Codex publishes the same facts in
            // its own rollout file, and the hook already parked that file's absolute path
            // in tp-<tty>, so there is nothing to search for or guess: read the one file
            // it names. A nil here (no turn completed yet, unreadable, 2025-era format)
            // correctly leaves the row blank rather than substituting a Claude figure.
            if s.kind == .codex, let cu = codexUsage(tty: s.tty) {
                row.tokens = cu.totalTokens
                row.tokensExact = true
                row.ctxTokens = cu.contextTokens
                row.ctxLimit = cu.contextWindow
                // nil model is normal, not an error: turn_context scrolls out of the
                // tail window on a long session (see CodexSession), so the chip stays
                // empty until the next turn rewrites it.
                row.model = Self.modelLabel(cu.model ?? "")
            }
            row.step = status == "working" ? sessionStep(tty: s.tty) : ""
            // Background subagents are surfaced by the standalone 🤖 ×N badge (方案 A),
            // which shows in ANY status — a session can Stop (done) or sit at a prompt
            // (needs/idle) while still waiting on background agents. So the count is read
            // regardless of status, not gated to 运行中 like the live step above.
            // The nodes come first: the badge's count IS the roster's size, so building
            // it once and measuring that beats reading the roster file twice per poll.
            // Each node carries this session's window so its own occupancy can be a %.
            row.agents = agentRoster
            row.bgAgents = agentCount
            row.bgShells = bgShells
            row.bgShellsSince = bgShellsSince
            row.isFrozen = frozen
            row.terminalApp = s.terminalApp
            row.editor = s.editor
            row.isChatPanel = s.isChatPanel
            return row
        }
        // Guard before desktopRows() so hidden desktop groups skip the AX probe too —
        // but only when BOTH are hidden: hiding chat must not cost Design its row.
        if !AppSettings.isHidden(cwd: Self.desktopCwd)
            || !AppSettings.isHidden(cwd: Self.desktopDesignCwd) {
            rows.append(contentsOf: desktopRows().filter { !AppSettings.isHidden(cwd: $0.cwd) })
        }
        return rows
    }

    // The Claude desktop app's windows as synthetic rows — one per window, empty when
    // the app isn't running. cwd is a sentinel (never a real path) so each kind forms
    // its own header group and the token/VSCode-focus paths keyed by real cwds skip
    // them harmlessly. Chat and Design are separate surfaces of the same app (Design is
    // just a second Electron window, same pid, same bundle), so they get separate
    // groups: independent status, independent hide toggle, independent jump target.
    static let desktopCwd = "Claude App"
    static let desktopDesignCwd = "Claude Design"

    // True for either desktop sentinel. UI that special-cases the desktop group (hidden
    // list, header menu) must ask this rather than compare against one sentinel — that
    // check silently stopped covering half the desktop rows when Design was added.
    static func isDesktopCwd(_ cwd: String) -> Bool {
        cwd == desktopCwd || cwd == desktopDesignCwd
    }
    private func desktopRows() -> [SessionRow] {
        guard let probe = desktopStatus() else { return [] }
        var seqByCwd: [String: Int] = [:]
        return probe.windows.map { w in
            let cwd = w.isDesign ? Self.desktopDesignCwd : Self.desktopCwd
            let seq = (seqByCwd[cwd] ?? 0) + 1
            seqByCwd[cwd] = seq
            var row = SessionRow(title: cwd, folder: cwd, cwd: cwd,
                                 shellPid: probe.pid, tty: "",
                                 status: w.status, taskTitle: w.label, seq: seq)
            row.isDesktop = true
            row.desktopWid = w.wid
            row.model = w.model
            return row
        }
    }

    // Sum a session's WORKING seconds and token spend from its own log events since
    // `boundary`. Time is the gap-capped活动脉冲 model — see SessionClock/WorkClock in
    // Stats.swift before touching it; the short version is that a turn's open span is
    // NOT its work time (a turn parked at a permission prompt overnight used to bill the
    // whole night). If the session is still mid-turn, the open segment counts live up to
    // `now`. Tokens sum the done events' per-turn tallies — 0 when the session writes
    // no transcript (the hook can't capture them); callers then fall back to the
    // per-project totals (loadTokensByCwd).
    private func sessionUsage(_ events: [UsageEvent], boundary: Double,
                              inFlight: Bool, now: Double) -> (workSec: Int, tokens: Int) {
        var work = 0
        var tokens = 0
        var clock = SessionClock()
        for e in events.sorted(by: { $0.ts < $1.ts }) where Double(e.ts) >= boundary {
            work += clock.advance(e)
            if e.event == "done" {
                tokens += (e.tok_in ?? 0) + (e.tok_out ?? 0)
                        + (e.tok_cache_w ?? 0) + (e.tok_cache_r ?? 0)
            }
        }
        if inFlight { work += clock.inFlight(now: now) }
        return (work, tokens)
    }

    // Cumulative token spend per project cwd, read from Claude Code's own state file
    // (~/.claude.json) — the FALLBACK for sessions whose log events carry no token
    // fields (no transcript on disk, so the hook can't tally per turn). Keyed by
    // project directory and holding the most recent session's running totals, so
    // sibling sessions sharing one directory show the same project total.
    private func loadTokensByCwd() -> [String: Int] {
        let path = "\(NSHomeDirectory())/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (cwd, v) in projects {
            guard let p = v as? [String: Any] else { continue }
            let t = (p["lastTotalInputTokens"] as? Int ?? 0)
                  + (p["lastTotalOutputTokens"] as? Int ?? 0)
                  + (p["lastTotalCacheCreationInputTokens"] as? Int ?? 0)
                  + (p["lastTotalCacheReadInputTokens"] as? Int ?? 0)
            if t > 0 { out[cwd] = t }
        }
        return out
    }

    // Models whose NATIVE context window is 1M, so their lastModelUsage key carries NO
    // "[1m]" suffix (that suffix only marks the Sonnet/Opus 1M-beta variants). Matched as
    // a substring of the model id, e.g. "claude-fable-5". Without this, a native-1M
    // session under 200k tokens is misjudged as a 200k window and its % reads ~5x high.
    // "opus-5-5" is listed exact, not as "opus-5": Opus 5 itself was a 1M-beta model
    // (seen here as "claude-opus-5[1m]"), so a bare Opus 5 key is a 200k window.
    private static let native1MModels = ["fable-5", "mythos-5", "opus-5-5"]

    private static func isNative1M(_ modelKey: String) -> Bool {
        modelKey.contains("[1m]") || native1MModels.contains { modelKey.contains($0) }
    }

    // The context-window limit (in tokens) per project cwd, inferred from the model it
    // last used. ~/.claude.json's projects.<cwd>.lastModelUsage is keyed by model id.
    // A 1M window shows up two ways: the "[1m]" suffix on Sonnet/Opus 1M-beta sessions,
    // or a natively-1M model id (see native1MModels) that carries no suffix at all —
    // isNative1M covers both. Anything else is the default 200,000. A cwd with no usable
    // model key is omitted (0 → gauge shows raw tokens, no %).
    // Split out of loadCtxLimitByCwd so ONE parse of ~/.claude.json feeds both the
    // window-size map and the per-row model label (a session with no completed turn of
    // its own falls back to whatever model its project last used).
    private func loadModelKeyByCwd() -> [String: String] {
        let path = "\(NSHomeDirectory())/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (cwd, v) in projects {
            guard let p = v as? [String: Any],
                  let usage = p["lastModelUsage"] as? [String: Any] else { continue }
            // Ignore haiku (the background/summarizer model); the main model's key
            // drives both the window size and the label the user cares about.
            let mains = usage.keys.filter { !$0.contains("haiku") }
            guard let key = mains.first(where: { Self.isNative1M($0) }) ?? mains.first else { continue }
            out[cwd] = key
        }
        return out
    }

    private func ctxLimits(from modelKeys: [String: String]) -> [String: Int] {
        modelKeys.mapValues { Self.isNative1M($0) ? 1_000_000 : 200_000 }
    }

    // "claude-opus-4-8[1m]" → "Opus 4.8", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    // Generic on purpose (family + dotted version) so a model id this build has never
    // heard of still renders sensibly instead of dropping off the row. The "[1m]" tier
    // is stripped: only ~/.claude.json's keys carry it — the transcript-derived ids in
    // events.jsonl never do — so keeping it would make the same session's label flip
    // depending on which source answered. Occupancy already conveys the window.
    static func modelLabel(_ id: String) -> String {
        var s = id.lowercased()
        // Codex reports OpenAI ids ("gpt-5-codex", "gpt-5.6-sol" — both observed on this
        // machine 2026-08-30). They can't go through the Claude path below: that one
        // reads a version out of the segments it can parse as Int, so a dotted "5.6"
        // yields no version at all, and .capitalized would turn GPT into "Gpt".
        //
        // ★ Only vendor + version, never the trailing codename. The chip lives in a fixed
        // 70pt slot whose widest existing label measured 60.7pt at 9 characters
        // (docs/row-display.md); "GPT-5 Codex" is 11 and would push past it, and a chip
        // that outgrows its slot doesn't just clip — it shifts the step column that every
        // other row aligns against. "GPT-5.6" is 7 and safe.
        if s.hasPrefix("gpt-") {
            let version = s.dropFirst("gpt-".count).split(separator: "-").first.map(String.init)
            return version.map { "GPT-\($0)" } ?? "GPT"
        }
        guard s.hasPrefix("claude-") else { return "" }   // "<synthetic>" and friends
        s = String(s.dropFirst("claude-".count))
        if let r = s.range(of: "[1m]") { s = String(s[s.startIndex..<r.lowerBound]) }
        var parts = s.split(separator: "-").map(String.init)
        // Trailing build date ("20251001") is noise in a row label.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        // The family is the first NON-numeric segment and the version is every numeric
        // one, joined — which reads correctly whichever side the digits sit on:
        // "opus-4-8" → Opus 4.8, and the legacy "3-5-sonnet" → Sonnet 3.5 (a naive
        // first-part-is-the-family rule turns that one into "3 5.sonnet").
        guard let family = parts.first(where: { Int($0) == nil }) else { return "" }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    // Resolve a cwd's context-window limit, falling back to the nearest ANCESTOR that
    // has one, then to the ACCOUNT default. Claude Code records lastModelUsage under
    // whatever dir it was launched from, which is often a monorepo root (…/nextad) while
    // sessions actually run in a subpackage (…/nextad/apps/event-alarm) that has no entry
    // of its own — an exact match then misses. Walk up parents until a known dir is hit;
    // on a full miss use the account default rather than 0 (which would hide the gauge).
    //
    // Account default: recent Claude Code builds leave most projects' lastModelUsage
    // EMPTY ({}), so the per-cwd walk misses for nearly every session and the % gauge
    // vanished for any row that had captured context. The one reliably-populated entry
    // is the global ~/.claude bootstrap dir, which carries the user's actual model+tier.
    // If ANY populated entry is a 1M window, the account clearly has 1M access → default
    // unknown cwds to 1M; else if we know any window at all → 200k; else 0 (nothing known,
    // ctxPct then upgrades by observed occupancy).
    private func ctxLimit(for cwd: String, in byCwd: [String: Int]) -> Int {
        var dir = cwd
        while !dir.isEmpty, dir != "/" {
            if let lim = byCwd[dir] { return lim }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if byCwd.values.contains(1_000_000) { return 1_000_000 }
        return byCwd.isEmpty ? 0 : 200_000
    }

    // What a session is doing RIGHT NOW — its model and its context occupancy — tailed
    // from its own transcript instead of waiting for the turn-end `done` event. The hook
    // stamps tp-<tty> with the payload's transcript_path on EVERY event; we read that
    // file's tail and take the newest non-sidechain assistant message. So a /model switch
    // and a growing context both surface within one refresh (~2.5s, or instantly on the
    // FSEvent a hook write fires) instead of one whole turn, and a fresh tab is filled in
    // from its first reply rather than from the project fallback.
    //
    // Both values ride ONE scan of one file — reading the model and then the tokens
    // separately would double the work for nothing.
    private struct LiveInfo {
        var model: String?
        var ctxTokens: Int      // 0 = not found; caller falls back to the hook's ctx-<tty>
        // Why the model stopped on that message: "tool_use" = mid-turn (a tool call is in
        // flight), anything else ("end_turn", "max_tokens", …) = the turn is over. nil on
        // a streamed fragment that carries no reason. Only the agent path reads it —
        // that's how a finished subagent is told from a running one (see agentTail).
        var stopReason: String?
    }

    private func liveInfo(tty: String) -> LiveInfo? {
        guard let raw = try? String(contentsOfFile: "\(dataDir)/tp-\(tty)", encoding: .utf8)
        else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        // Re-read only when the transcript actually changed: a busy turn fires many
        // FSEvent refreshes, and each would otherwise re-scan every session's tail.
        // A nil result is cached too — a miss costs the same scan as a hit.
        let stamp = "\(path)|\(size)|\(mtime)"
        if let hit = liveModelCache[tty], hit.stamp == stamp { return hit.info }
        let info = Self.scanTranscriptTail(path: path, size: size)
        liveModelCache[tty] = (stamp, info)
        return info
    }

    // Newest non-sidechain assistant message in a transcript's tail, as (model, context).
    // Lines are compact one-message JSON (~1-3 KB each), so the last 256 KB always spans
    // several — reading whole files would be megabytes per session per poll. A truncated
    // leading line is harmless: we only substring-match, and it's the oldest one here.
    private static func scanTranscriptTail(path: String, size: UInt64) -> LiveInfo? {
        lastAssistantInfo(inTranscript: path, size: size, skipSidechain: true)
    }

    // Same ancestor walk as ctxLimit(for:in:) — Claude Code records lastModelUsage under
    // whatever dir it was launched from, often a monorepo root above the session's own
    // cwd. No account-wide default on a full miss: guessing a model from an unrelated
    // project would put a confidently WRONG name on the row, and a blank slot is the
    // honest answer (unlike the window size, where a missing gauge is the worse outcome).
    private func modelKey(for cwd: String, in byCwd: [String: String]) -> String {
        var dir = cwd
        while !dir.isEmpty, dir != "/" {
            if let k = byCwd[dir] { return k }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return ""
    }

    // Read a small state file's contents as an Int (the hook writes ctx-<tty> as a bare
    // number). Absent / unparseable → 0.
    private func fileInt(_ path: String) -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // Read a state file whose CONTENT is a Unix epoch the hook stamped (clear-boundary-<tty>).
    // Absent / unparseable → 0. Distinct from fileMTime, which reads the file's own mtime.
    private func fileEpoch(_ path: String) -> Double {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // The subscription usage snapshot the hook writes (usage.json). Nil when the file is
    // absent (non-subscription account, or the first probe hasn't landed yet) — the header
    // then simply omits the usage line. Reading a small JSON on the main thread is cheap.
    private func loadUsage() -> UsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: "\(dataDir)/usage.json"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = o["session_pct"] as? Int else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        var u = UsageSnapshot()
        u.sessionPct = session
        u.sessionResetsAt = num("session_resets_at")
        u.weekPct = o["week_pct"] as? Int
        u.weekResetsAt = num("week_resets_at")
        u.weekModelPct = o["week_model_pct"] as? Int
        u.weekModelLabel = o["week_model_label"] as? String
        u.updatedAt = num("updated_at") ?? 0
        return u
    }

    // Kick a detached `claude -p "/usage"` probe when the snapshot is older than
    // `minAge`, so the header quota is fresh WHILE you're looking at it. The hook's
    // own probe fires only on turn end — during a long working turn nothing completes,
    // so the number starves exactly when you're watching. Same guards as the hook:
    // claim the throttle window up front by bumping the file's mtime (a failed probe
    // won't retry every call, and the hook's own 120s check backs off too), mark the
    // nested claude with SPECTIX_USAGE_PROBE so its hooks no-op, and background
    // the pipeline inside sh so this returns in milliseconds. The regular poll reads
    // usage.json every refresh, so the fresh figures land within a cycle.
    //
    // TCC: the claude CLI pokes protected locations at startup (Downloads, media
    // library, other apps' data — none of which this app reads), and macOS bills a
    // child's accesses to the RESPONSIBLE process — us — so every probe rained
    // "SpectiX would like to access …" prompts on the user. Spawn through
    // spawnDisclaimed() so claude carries its own TCC identity, and cd into our
    // data dir so it doesn't treat launchd's cwd (/) as a project root to scan.
    /// True while the newest quota reading predates the last account switch — i.e.
    /// it describes the account we left. See AccountBook.lastSwitch.
    private var usageOutdatedBySwitch: Bool {
        AccountBook.lastSwitch(.claude) > (usage?.updatedAt ?? 0)
    }

    private func requestUsageProbe(minAge: TimeInterval) {
        guard AppSettings.usageProbeEnabled else { return }
        let path = "\(dataDir)/usage.json"
        guard Date().timeIntervalSince1970 - fileMTime(path) >= minAge else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: path)
        // GUI apps don't inherit the shell PATH; resolve `claude` from its usual homes.
        let parser = "\(NSHomeDirectory())/.claude/hooks/spectix-usage.py"
        let candidates = ["\(NSHomeDirectory())/.local/bin/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let claude = candidates.first(
                  where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.isReadableFile(atPath: parser) else { return }
        Self.spawnDisclaimed(["/bin/sh", "-c", """
            cd '\(dataDir)' && ( SPECTIX_USAGE_PROBE=1 '\(claude)' -p '/usage' 2>/dev/null \
              | /usr/bin/python3 '\(parser)' > '\(path).tmp' 2>/dev/null \
              && mv -f '\(path).tmp' '\(path)' || rm -f '\(path).tmp' \
            ) >/dev/null 2>&1 &
            """])
    }

    // posix_spawn with TCC responsibility disclaimed: the child (and its whole
    // subtree — the backgrounded pipeline survives sh's exit) is responsible for
    // its own privacy-permission requests instead of billing them to SpectiX.
    // Process/NSTask has no hook for spawn attributes, hence raw posix_spawn.
    private static func spawnDisclaimed(_ argv: [String]) {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], nil, &attr, &cargv, environ) == 0 else { return }
        waitpid(pid, nil, 0)   // sh exits instantly (the pipeline is backgrounded)
    }

    // Overlay the user's acknowledgements, then sort into a FIXED order. Runs on the
    // main thread so `acked` is only ever touched from one queue.
    private func applyAck(_ realRows: [SessionRow]) -> [SessionRow] {
        let live = Set(realRows.map { $0.id })
        acked = acked.filter { live.contains($0.key) }   // forget vanished sessions
        pendingAck = pendingAck.filter { live.contains($0.key) }

        var rows = realRows.map { r -> SessionRow in
            // An armed-but-not-applied ack dies with the status it was armed on: you
            // typed (done → working), so the row never grays and re-greens on its own.
            if let p = pendingAck[r.id], p != r.status { pendingAck.removeValue(forKey: r.id) }
            if let a = acked[r.id] {
                if a == r.status {                        // still the acked state → gray
                    var seen = SessionRow(title: r.title, folder: r.folder, cwd: r.cwd,
                                          shellPid: r.shellPid, tty: r.tty, status: "seen",
                                          taskTitle: r.taskTitle, seq: r.seq)
                    seen.workSec = r.workSec
                    seen.tokens = r.tokens
                    seen.ctxTokens = r.ctxTokens
                    seen.ctxLimit = r.ctxLimit
                    seen.model = r.model
                    // Background-agent/shell ledger and live step survive the recolor:
                    // acking a row changes its COLOR, not what it's running. Dropping
                    // these made the 🤖 badge (and the bg subtitle) vanish the moment
                    // you clicked a 需确认 row.
                    seen.bgAgents = r.bgAgents
                    seen.bgShells = r.bgShells
                    seen.step = r.step
                    seen.isDesktop = r.isDesktop
                    // Identity for a desktop row, not decoration: drop it and the
                    // rebuilt row's id no longer matches the ack we just looked up.
                    seen.desktopWid = r.desktopWid
                    seen.terminalApp = r.terminalApp
                    seen.editor = r.editor
                    return seen
                }
                acked.removeValue(forKey: r.id)           // moved on → real color returns
            }
            return r
        }
        // Position is FIXED: rows sort by a stable key (folder, then session number),
        // never by status. A status change only recolors a row in place — it never
        // makes the row jump to a new position.
        rows.sort {
            $0.cwd != $1.cwd ? $0.cwd < $1.cwd : $0.seq < $1.seq
        }
        return rows
    }

    // Demo mode's whole refresh: swap in the scripted world and draw it.
    //
    // ★ It is deliberately NOT the tail of the real refresh with a different row
    // source. Everything the real path does BESIDES drawing acts on the outside
    // world — rings and captions get painted onto editor panes, toasts fire, the
    // answered-chain and idle auto-jump can carry your focus somewhere, and
    // ProjectHistory remembers cwds for the 最近项目 tab. A fake row has no pane
    // behind it and its cwd doesn't exist, so every one of those would either point
    // at an unrelated window or write invented projects into real state. Demo mode
    // shows; it doesn't act — except toward the Terminal windows it opened itself
    // (Demo, MARK Staged windows), which get jumps, rings and toasts for real.
    private func renderDemo() {
        Demo.ensureLogs()
        if !demoStageTried { stageDemoTerminals() }
        rows = Demo.rows()
        usage = Demo.usage()
        model.setEmptyProjects([])
        notifyDemoTransitions(rows)
        updateButton()
        renderRows()
    }

    // MARK: Demo staged windows (DEV-only)

    // Once per demo run, even when staging fails (Automation denied): renderDemo runs
    // every 2.5s and would otherwise retry osascript forever.
    private var demoStageTried = false
    // Bumped by every unstage, so a staging round still in flight when demo mode goes
    // off (or off and on again) closes its own windows instead of publishing them.
    private var demoStageGen = 0
    private var demoLastStatus: [String: String] = [:]
    private let demoQueue = DispatchQueue(label: "spectix.demo-stage")

    private func stageDemoTerminals() {
        demoStageTried = true
        let gen = demoStageGen
        let leftovers = Demo.leftoverStaged()
        let targets = Demo.stageTargets
        demoQueue.async { [weak self] in
            guard let self else { return }
            leftovers.forEach { self.closeStagedWindow($0) }
            var made: [String: Demo.Staged] = [:]
            for fake in targets {
                // `do script ""` opens a bare shell — nothing typed, so nothing in history.
                // Title = cwd (repointed by Demo.screen) + process; no device name, no
                // custom title (it would just repeat the project name).
                let script = """
                tell application "Terminal"
                    set t to do script ""
                    set w to front window
                    set title displays device name of t to false
                    set title displays shell path of t to false
                    set title displays window size of t to false
                    set title displays file name of t to false
                    set title displays custom title of t to false
                    return (tty of t) & " " & (id of w)
                end tell
                """
                let out = self.spawnResponsibleCapturing(["/usr/bin/osascript", "-e", script]) ?? ""
                let parts = out.split(separator: " ")
                guard parts.count == 2, parts[0].hasPrefix("/dev/"), let wid = Int(parts[1]) else {
                    NSLog("TB demo: staging %@ failed: %@", fake, out)
                    continue
                }
                made[fake] = Demo.Staged(tty: String(parts[0].dropFirst(5)), wid: wid)
            }
            // The new shell prints its prompt (user@host) once it starts; paint over it
            // only after that, or the prompt lands below the mock.
            Thread.sleep(forTimeInterval: 2)
            DispatchQueue.main.async {
                guard gen == self.demoStageGen else {
                    self.demoQueue.async { made.values.forEach { self.closeStagedWindow($0) } }
                    return
                }
                Demo.staged = made
                self.refresh()
            }
        }
    }

    private func unstageDemoTerminals() {
        demoStageTried = false
        demoStageGen += 1
        demoLastStatus = [:]
        let windows = Array(Demo.staged.values)
        Demo.staged = [:]
        demoQueue.async { [weak self] in windows.forEach { self?.closeStagedWindow($0) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Demo.staged.values.forEach { closeStagedWindow($0) }
    }

    // The one check behind rule 2's exception: the window id still exists AND its shell
    // is alive on the tty we opened. A dead shell frees the tty for the next terminal
    // the user opens, yet its window keeps reporting it — painting would then write
    // into someone else's terminal.
    // `is running` first: a `tell` would launch Terminal just to ask.
    // `live: false` is for closing: a dead-shell window by our id is still ours to close.
    // Blocks on osascript — off the main thread except at quit.
    private func stagedWindowIsOurs(_ s: Demo.Staged, live: Bool = true) -> Bool {
        let script = """
        if application "Terminal" is running then
            tell application "Terminal"
                if exists window id \(s.wid) then
                    set t to tab 1 of window id \(s.wid)
                    if \(live ? "(count of processes of t) > 0" : "true") then return tty of t
                end if
            end tell
        end if
        return ""
        """
        return spawnResponsibleCapturing(["/usr/bin/osascript", "-e", script]) == "/dev/\(s.tty)"
    }

    private func closeStagedWindow(_ s: Demo.Staged) {
        guard stagedWindowIsOurs(s, live: false) else { return }
        spawnResponsible(["/usr/bin/osascript", "-e",
                          "tell application \"Terminal\" to close window id \(s.wid)"])
    }

    // Repaint the staged window's mock screen for the row's current status.
    private func paintDemoTerminal(_ row: SessionRow) {
        guard let s = Demo.stagedWindow(for: row), let text = Demo.screen(for: row) else { return }
        demoQueue.async { [weak self] in
            guard let self, self.stagedWindowIsOurs(s) else { return }
            Self.writeTty(s.tty, text)
        }
    }

    private static func writeTty(_ tty: String, _ text: String) {
        let fd = open("/dev/\(tty)", O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return }
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    // The toast half of notifyTransitions, for staged rows only — the rest of that
    // function (answered-chain, break clock, impact log) acts on real state.
    private func notifyDemoTransitions(_ rows: [SessionRow]) {
        let staged = rows.filter { Demo.stagedWindow(for: $0) != nil }
        for row in staged {
            let prev = demoLastStatus[row.id]
            guard prev != row.status else { continue }
            demoLastStatus[row.id] = row.status
            paintDemoTerminal(row)
            guard prev != nil else { continue }
            if row.status == "needs" || (row.status == "done" && prev == "working") {
                ToastManager.shared.show(title: row.projectName, subtitle: row.display,
                                         icon: row.badgeMode, status: row.status,
                                         path: row.id) { [weak self] in self?.focus(row) }
            } else if prev == "needs" {
                ToastManager.shared.resolve(row.id)
            }
        }
        // No retain(live:) here: it also drops any toast whose path's shellPid is dead, and a
        // demo row's shellPid is invented — every demo toast vanished the instant it showed.
        // Turning demo off hands back to the real refresh, whose retain sweeps these.
    }

    // Push the current rows to every view, with the L("查看", "View") eye overlaid on any
    // session you're actively looking at. Callable outside a refresh (e.g. on a
    // banner click) so the list updates the instant you enter checking.
    private func renderRows() {
        let view = applyChecking(rows)
        model.update(view)
        // reload() feeds the 最近项目 tab fresh openCwds too, so 已打开 badges
        // stay truthful while that tab is showing.
        //
        // Only reload a *visible* surface: this is a menu-bar app, so the main
        // window is closed most of the time and the popover is up only briefly.
        // Reloading a hidden window every 2.5s poll is pure waste — full
        // statsHeader.update + tableView.reloadData (rebuilds every cell) +
        // hoverDidReload against nothing on screen. Both open paths
        // (openMainWindow / togglePopover) reload on show, so a hidden surface
        // has no stale data to worry about. `model.update(view)` above stays
        // unconditional — keyboard-jump priority reads the shared model even
        // when no surface is visible.
        // Sample CPU/memory only while a surface is actually up: the header's left
        // card is the sole consumer, so polling a hidden window would just burn
        // mach traps. CPU is a rate, so the first sample after a surface opens can
        // only set a baseline — that row reads "—" for one poll, by design.
        if mainWindowController?.isShown == true || popover.isShown {
            SystemMonitor.shared.sample()
            // Assembled ONCE and handed to both surfaces. It reads both account files
            // and files the quota into the book, so calling it per surface did all of
            // that twice on every tick with the popover open.
            let hdr = headerAgentInfo(rows: view)
            if mainWindowController?.isShown == true {
                mainWindowController?.reload(view, usage: hdr.claudeUsage, header: hdr)
            }
            if popover.isShown { popoverController.reload(view, usage: hdr.claudeUsage, header: hdr) }
        }
    }

    // Overlay "checking" (amber watching-eye) on rows you're looking at while they're
    // still "needs". View-only — `rows`/lastStatus keep the real "needs".
    private func applyChecking(_ rows: [SessionRow]) -> [SessionRow] {
        guard !checkingIds.isEmpty else { return rows }
        return rows.map { r in
            guard checkingIds.contains(r.id), r.status == "needs" else { return r }
            var c = SessionRow(title: r.title, folder: r.folder, cwd: r.cwd,
                               shellPid: r.shellPid, tty: r.tty, status: "checking",
                               taskTitle: r.taskTitle, seq: r.seq)
            c.workSec = r.workSec
            c.tokens = r.tokens
            c.ctxTokens = r.ctxTokens
            c.ctxLimit = r.ctxLimit
            c.model = r.model
            // Same as applyAck: the watching-eye overlay is a recolor, so the agent
            // ledger and live step must ride through it — otherwise clicking a 需确认
            // row (→ checking) drops the 🤖 badge and collapses its sublist.
            c.bgAgents = r.bgAgents
            c.bgShells = r.bgShells
            c.step = r.step
            c.isDesktop = r.isDesktop
            c.desktopWid = r.desktopWid   // identity, see applyAck
            c.terminalApp = r.terminalApp
            c.editor = r.editor
            return c
        }
    }

    // Drop checking marks once a session leaves "needs" (you answered) or vanishes —
    // the eye reverts to the real color / disappears on the next render.
    private func pruneChecking() {
        guard !checkingIds.isEmpty else { return }
        checkingIds = checkingIds.filter { id in
            rows.first(where: { $0.id == id })?.status == "needs"
        }
    }

    // You started looking at a still-"needs" session (clicked its banner or focused
    // its terminal): morph its banner + row into the amber watching eye. No-op if it
    // isn't needs or is already checking.
    private func enterChecking(_ row: SessionRow) {
        guard row.status == "needs", checkingIds.insert(row.id).inserted else { return }
        ToastManager.shared.check(row.id)
        renderRows()
    }

    // Mark a `done` session seen, so its row greys to L("闲置", "Idle") until new work arrives.
    // The ONLY trigger is the companion extension reporting you actually focused that
    // terminal (via dismissFocusedToast) — never a mere click on the toast/row/menu.
    // `done` has no ground-truth "seen" signal of its own, so this focus-driven ack
    // is the mechanism; it's dropped once the real status moves on.
    //
    // `needs` is deliberately NOT ack-able: focusing the terminal isn't answering the
    // prompt. It stays red until you actually respond and the hook flips the state
    // (working/done) — the authoritative signal. Graying it on anything less would
    // misreport L("闲置", "Idle") before you'd confirmed anything.
    // ★ Arms, does NOT apply — see `pendingAck`. Landing in the session is not yet
    // "seen and done with it"; leaving it is (promotePendingAck).
    private func acknowledge(_ id: String, status: String) {
        guard status == "done" else { return }
        pendingAck[id] = status
    }

    // You left an armed session → its ack applies now and the row grays. `keepId` is the
    // session you just moved TO (still being looked at, so its own arm stays pending).
    // Called from the two places a departure is observable: a new active-terminal focus
    // report (switch between terminals, even inside one editor window) and a frontmost-app
    // change to something that doesn't host the armed session.
    private func promotePendingAck(keepId: String? = nil, exceptHost: String? = nil) {
        guard !pendingAck.isEmpty else { return }
        var applied = false
        for (id, status) in pendingAck {
            if id == keepId { continue }
            if let host = exceptHost, hostBundleId(forSessionId: id) == host { continue }
            acked[id] = status
            pendingAck.removeValue(forKey: id)
            applied = true
        }
        if applied { refresh() }
    }

    // Bundle id of the app hosting this session's row, for "did the user leave it?".
    // nil when the row is gone or its host isn't one we recognize (unsupported terminal) —
    // an unknown host can't be matched against the frontmost app, so such an arm is
    // applied on the next departure rather than pinned green forever.
    private func hostBundleId(forSessionId id: String) -> String? {
        guard let row = rows.first(where: { $0.id == id }) else { return nil }
        if row.isDesktop { return "com.anthropic.claudefordesktop" }
        if let editor = row.editor { return editor.rawValue }
        return row.terminalApp?.rawValue
    }

    // MARK: Session discovery (libproc)

    // A live interactive `claude` process and the bits we need to render + focus it.
    private struct LiveSession {
        let kind: AgentKind    // which agent CLI this is; gates the Claude-only enrichment
        let cwd: String
        let shellPid: pid_t
        let tty: String
        let claudePid: pid_t   // the interactive agent process itself (for the busy probe)
        let terminalApp: TerminalApp?   // native terminal emulator behind it, else nil
        let editor: EditorApp?  // VSCode-family host; nil when the host isn't one we support
        // True for the Claude Code chat panel inside a VSCode-family editor: no tty, no
        // shell, keyed on the claude pid, and focused via the extension rather than by
        // revealing an integrated terminal. False for every terminal session.
        let isChatPanel: Bool

        // The pid that gives this session its user-facing number ("01", "02", …).
        // A terminal session is one per shell, so shellPid identifies it — but several
        // chat panels in one editor WINDOW share a single extension host, which would
        // hand them all the same number (and the same "folder · 02" title). Those
        // number by their own claude pid instead. Both are real pids, so the two kinds
        // can never collide on one key.
        var seqKey: pid_t { isChatPanel ? claudePid : shellPid }
    }

    // Does this tty-less `claude` belong to an editor's chat panel (as opposed to a
    // headless scripted run)? The daemon writes ~/.claude/sessions/<pid>.json for every
    // live session and labels the chat panel `entrypoint: "claude-vscode"` with
    // `kind: "interactive"` — a self-declared answer that survives extension upgrades,
    // unlike matching on the install path. False when the file is absent (the daemon
    // writes it a moment after launch, so a brand-new panel simply appears one poll
    // later) or when it describes a different pid.
    private func isEditorChatSession(_ pid: pid_t) -> Bool {
        let path = "\(NSHomeDirectory())/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["pid"] as? Int) == Int(pid)
        else { return false }
        return (obj["entrypoint"] as? String)?.hasPrefix("claude-vscode") == true
            && (obj["kind"] as? String) == "interactive"
    }

    private func discoverSessions() -> [LiveSession] {
        var out: [LiveSession] = []
        // Projects the user manually hid. Read once (UserDefaults reads are
        // thread-safe) and drop matching sessions the moment we know their cwd —
        // before any status read, usage tally, or busy-probe runs.
        let hidden = AppSettings.hiddenCwds
        let pids = allPIDs()
        pruneArgsCache(live: pids)
        for pid in pids {
            let args = processArgs(pid)
            guard let arg0 = args.first,
                  let kind = AgentKind(rawValue: (arg0 as NSString).lastPathComponent)
            else { continue }
            // Skip the daemon supervisor, bg-pty-host/spare workers, and Electron
            // helper subprocesses — none are user-facing terminal sessions.
            // ★ Skip -p/--print one-shots too: our own `claude -p '/usage'` usage
            // probe (see requestUsageProbe) cd's into ~/.claude/spectix and lives
            // ~1s, so without this it flashes a phantom "spectix" header every poll
            // even when no session runs there. Print mode is non-interactive by
            // definition — a real terminal session never carries -p.
            // ★ The per-kind half of that test lives on AgentKind.nonInteractiveArgs,
            // because the two CLIs disagree on shape: Claude's non-interactive modes are
            // flags, Codex's are subcommands. `--type=` stays common to both — it marks
            // an Electron helper regardless of who spawned it. Skipping arg0 matters for
            // Codex, whose argv[0] is an absolute path with the binary name in it.
            let nonInteractive = kind.nonInteractiveArgs
            if args.dropFirst().contains(where: {
                nonInteractive.contains($0) || $0.hasPrefix("--type=")
            }) { continue }
            // stream-json over stdio means one of two very different things, and the
            // flags alone can't tell them apart:
            //   • the Claude Code chat panel inside VSCode (sidebar / tab / window) —
            //     a fully interactive session a user is talking to RIGHT NOW, and
            //   • a genuinely headless scripted run.
            // We used to skip both, on the reasoning that the process owns no tty and
            // "never resolves a status". The tty half is still true; the status half is
            // not: the chat panel fires every hook a terminal session does (verified
            // 2026-08-05 on 2.1.222), so the hook now keys those on the claude pid
            // ("pid<PID>", see spectix-status.sh) and the state resolves fine.
            // The daemon declares which kind this is, so ask it rather than pattern-
            // matching the extension's install path (which changes every release).
            // ★ Claude-only: Codex has no chat-panel equivalent to rescue here. Its
            // editor and desktop integrations run `codex app-server`, already dropped
            // above, and they own no tty — so for Codex this whole branch is dead and
            // asking isEditorChatSession about a Codex pid would only misread the
            // Claude daemon's sessions/<pid>.json for an unrelated process.
            let streamStdio = kind == .claude
                && args.contains { $0 == "--output-format" || $0 == "--input-format" }
            let chatPanel = streamStdio && isEditorChatSession(pid)
            if streamStdio && !chatPanel { continue }
            guard let cwd = processCWD(pid), !cwd.isEmpty else { continue }
            if hidden.contains(cwd) { continue }
            let bsd = processBSDInfo(pid)
            // ★ Every Codex session we can key is a terminal one, so a missing tty means
            // this is a helper, not a session. Belt-and-braces with the subcommand
            // denylist: ChatGPT.app and the VSCode extension each ship their OWN `codex`
            // binary, and their argv is theirs to change — the tty test doesn't care.
            if kind == .codex && (bsd?.tty ?? "").isEmpty { continue }
            // One parent-chain walk resolves the host GUI app; map its bundle id onto
            // both a TerminalApp (native emulator) and an EditorApp (VSCode family).
            // ★ Both stay nil for a host we don't support — no `?? .vscode` fallback
            // (see SessionRow.editor / hostSupported for why that fallback was a bug).
            let hostBid = hostAppBundleId(forClaudePid: pid)
            out.append(LiveSession(
                kind: kind,
                cwd: cwd,
                // For a chat panel this is the extension host (Code Helper (Plugin)),
                // one per editor WINDOW — which is exactly what the jump needs to tell
                // windows apart, and what the companion extension already keys its own
                // per-window manifest on (terminals-<process.pid>.json).
                // A terminal session wants the interactive SHELL, which is not always
                // the direct parent — see shellPID(above:).
                shellPid: chatPanel ? (bsd?.ppid ?? 0) : shellPID(above: pid, ppid: bsd?.ppid ?? 0),
                // The state key. A chat panel has no tty anywhere on its chain, so it
                // keys on the claude pid — the same string the hook derives (pid<PID>),
                // which makes every per-session file (state-/step-/title-/bg-/ctx-/…)
                // line up with no further plumbing.
                tty: chatPanel ? "pid\(pid)" : (bsd?.tty ?? ""),
                claudePid: pid,
                terminalApp: hostBid.flatMap(TerminalApp.init(rawValue:)),
                editor: hostBid.flatMap(EditorApp.init(rawValue:)),
                isChatPanel: chatPanel))
        }
        return out
    }

    // The bundle id of the top-level GUI app hosting a `claude` session — the ancestor
    // whose parent is launchd (ppid <= 1). Callers map it onto TerminalApp (native
    // emulator) and/or EditorApp (VSCode family). The chain is shallow (claude → -zsh →
    // login → Terminal → launchd) and sysctl is a local, unprivileged call, so this is
    // cheap on the discovery hot path. nil when the chain can't be resolved.
    // ★ Uses parentPID (sysctl), NOT processBSDInfo (proc_pidinfo): Terminal.app spawns a
    // setuid-ROOT `login` between the shell and itself, and proc_pidinfo(PROC_PIDTBSDINFO)
    // returns EPERM on a root-owned process from our unprivileged app → the walk dead-ended
    // at `login` and every native-terminal session came back nil (the "jump does nothing /
    // no ring, falls through to the VSCode path" bug). KERN_PROC_PID reads ppid cross-uid.
    private func hostAppBundleId(forClaudePid pid: pid_t) -> String? {
        var cur = pid
        for _ in 0..<8 {                       // depth guard; real chains are ≤5 deep
            guard let ppid = parentPID(cur) else { return nil }
            if ppid <= 1 {                     // cur is the top-level app (child of launchd)
                return NSRunningApplication(processIdentifier: cur)?.bundleIdentifier
            }
            cur = ppid
        }
        return nil
    }

    // A process's parent pid via sysctl(KERN_PROC_PID). Unlike proc_pidinfo, this reads
    // across uid boundaries, so the parent-chain walk can step through a setuid-root
    // `login` (opaque to proc_pidinfo) that sits between the shell and Terminal.app.
    private func parentPID(_ pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func allPIDs() -> [pid_t] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, cap)
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    // Direct children of `pid` (one libproc call, filtered by parent pid).
    private func childPIDs(_ pid: pid_t) -> [pid_t] {
        let cap = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size)
        let n = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, cap)
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    // A file's mtime as a Unix epoch, or 0 if it can't be read.
    private func fileMTime(_ path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let d = attrs[.modificationDate] as? Date else { return 0 }
        return d.timeIntervalSince1970
    }

    // A process's start time as a Unix epoch (wall clock), so it can be compared
    // against a file's mtime. From proc_bsdinfo's pbi_start_tv{sec,usec}.
    private func processStartEpoch(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    // Bridge the permission-approval blind spot behind the red "needs" pill.
    //
    // A row goes red because the PermissionRequest hook fires the instant a dialog
    // appears. But Claude Code emits NO hook when you APPROVE — the next signal for
    // that tool is its PostToolUse, which for a long *foreground* command only fires
    // when the command finally exits. So an already-approved, still-running command
    // sits red the entire time it runs (the "确认过了还是红" bug).
    //
    // Ground truth for "the dialog is gone and work is underway" lives in the process
    // tree: Claude Code runs a Bash tool by spawning its snapshot shell — `zsh -c …`
    // (or bash/sh -c) — as a child of the `claude` process. The `-c` keeps this precise:
    // only command-invocation shells carry it, never an idle interactive login shell.
    //
    // But a command shell alone isn't enough: a session can have a LEFTOVER command
    // still alive (an earlier `expo start` dev server) AND a fresh, genuinely-pending
    // dialog for a different tool. That leftover must NOT clear the red. The tell is
    // TIMING: the just-approved command spawns AFTER the dialog appeared, i.e. after the
    // state file flipped to "needs". So only count a command shell that started later
    // than that `needs` write (`since`). Leftovers predate it and are correctly ignored.
    //
    // Returns the NUMBER of qualifying command shells, not just a yes/no: a session can
    // have several backgrounded commands alive at once, and the row surfaces that count
    // ("2 个命令在跑") so a blue row with no step doesn't read as "stuck" (see
    // SessionRow.bgShells).
    private func runningToolShells(kind: AgentKind, claudePid: pid_t, since: Double) -> (count: Int, oldest: Double) {
        // ★ Claude-only, deliberately. Measured 2026-08-30: Codex spawns a tool command
        // as a DIRECT child of the agent process (`sleep 12` with ppid == the codex
        // binary) — no `sh -c`, no shell snapshot to source. So every signature below
        // misses, and the honest thing is to say so here rather than let the probe walk
        // the child list to always return 0.
        //
        // The tempting fix — "for Codex, count any long-lived child" — is exactly what
        // the snapshot signature exists to prevent: an MCP server is also a long-lived
        // child, and counting it would pin a finished row blue forever, which is a worse
        // bug than the one the probe fixes. Codex sessions therefore rely on hooks alone,
        // the same tradeoff editor chat panels already make (docs/session-status.md).
        guard kind == .claude else { return (0, 0) }
        guard claudePid > 0 else { return (0, 0) }
        let now = Date().timeIntervalSince1970
        var count = 0
        var oldest = 0.0
        for c in childPIDs(claudePid) {
            let args = processArgs(c)
            guard let a0 = args.first else { continue }
            let name = (a0 as NSString).lastPathComponent
            guard name == "zsh" || name == "bash" || name == "sh", args.contains("-c")
            else { continue }
            // Claude Code runs its HOOKS through the exact same shell shape as Bash
            // tool commands (`sh -c ~/.claude/hooks/….sh …`, sometimes snapshot-
            // wrapped), as direct children of `claude`. A session parked on an
            // unanswered dialog keeps receiving idle-ping/Notification hooks every
            // few seconds; each hook shell starts AFTER the needs write by
            // definition, so it passes the timing guard and repaints the red row
            // blue for the few hundred ms it lives (the "闲置行时不时闪蓝" bug).
            // Hook shells carry their script path inside the -c argument — skip them.
            if args.contains(where: { $0.contains(".claude/hooks/") }) { continue }
            // A Claude Code Bash-tool command shell ALWAYS sources the session's shell
            // snapshot (`zsh -c 'source …/shell-snapshots/snapshot-….sh 2>/dev/null || <cmd>'`)
            // — foreground and run_in_background alike. Requiring that signature keeps this
            // to real Bash-tool commands and excludes long-lived non-Bash children that are
            // themselves `sh -c` shells (e.g. an MCP server launched as `sh -c server`).
            // The timing guard below already excludes those in the needs case, but the
            // background-command probe passes since=0 (no guard), so this is what stops a
            // stray MCP shell from pinning a done/idle row blue forever.
            if !args.contains(where: { $0.contains("shell-snapshots/") }) { continue }
            // Belt-and-suspenders against other transient helper shells claude may
            // spawn while a dialog is pending: only count a shell that has lived
            // ≥1s. A genuinely approved command outlives that easily, and a 1s-late
            // blue repaint is imperceptible next to the minutes-long command run;
            // a short helper (or an unfiltered future hook) never qualifies.
            if let started = processStartEpoch(c), started > since, now - started > 1.0 {
                count += 1
                if oldest == 0 || started < oldest { oldest = started }
            }
        }
        return (count, oldest)
    }

    // Claude Code v2.1's daemon maintains ~/.claude/sessions/<pid>.json per live
    // session, carrying a `status` the tty-keyed hooks never see: "busy" (model
    // working), "idle" (turn ended, awaiting your next prompt), or "waiting" (parked
    // on a pending interaction — the sibling `waitingFor` names it: "permission
    // prompt", a question, a plan approval). We read it to catch what the hooks
    // structurally can't: a background subagent's permission request fires no hook on
    // the parent tty. Keyed by pid — unique per process like the tty, so it never
    // collapses sibling sessions the way a shared session id would. Returns "" when the
    // file is absent or unreadable, so callers fall back to the hook state.
    private func daemonSessionStatus(_ pid: pid_t) -> (status: String, updatedAt: Double) {
        guard pid > 0 else { return ("", 0) }
        let path = "\(NSHomeDirectory())/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["pid"] as? Int) == Int(pid)   // sanity: a well-formed session file for this pid
        else { return ("", 0) }
        let status = (obj["status"] as? String) ?? ""
        // statusUpdatedAt is epoch MILLISECONDS; convert to seconds so it compares
        // directly against fileMTime (timeIntervalSince1970). Used to prove a daemon
        // idle is NEWER than the hook state (the interrupt signal — see fetchRows).
        let ms = (obj["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0
        return (status, ms / 1000.0)
    }

    // MARK: Claude desktop app probe (AX)

    // One window of the Claude desktop app as the probe sees it. The app is a single
    // process hosting several surfaces (chat windows + the Design window), so every
    // fact here is per WINDOW, not per app.
    struct DesktopWindow {
        var wid: CGWindowID
        var isDesign: Bool
        var status: String   // working / done / idle
        var label: String    // conversation or project name; "" for a generic shell
        var model: String    // the window's own model picker ("Opus 5"), "" if unread
    }

    // Probe the Claude desktop app's live state. Returns nil ONLY when the app isn't
    // running. Throttled to ~2s: refresh() can fire many times a second (FSEvents during
    // active terminal turns) and each AX tree walk costs ~100ms, so between probes we
    // reuse the cached result.
    //
    // WHO DECIDES A ROW EXISTS (don't flip this back): WindowServer, via CGWindowList,
    // which needs no permission at all. Accessibility only ENRICHES those rows with
    // status/kind/model. It used to be the other way around — AX produced the rows — and
    // that made both desktop rows vanish for a whole session whenever the first probes
    // failed: every failure path returned the (still empty) cache, so there was nothing
    // to hand back. The first probe after launch fails BY DESIGN (Chromium hasn't built
    // its tree yet), and Electron's main thread also stalls past our messaging timeout
    // while streaming, right after launch, and during a Squirrel self-update. Missing
    // rows hide a whole session's state; a row that's briefly grouped as chat instead of
    // Design (or reads 闲置 for a beat) is self-correcting — see desktopFallback.
    //
    // Chromium/Electron only builds its a11y tree when an assistive client asks for it,
    // so we set AXManualAccessibility on the app first (Electron's own private switch;
    // the tree stays collapsed otherwise). Then a "Stop response" button under a WINDOW
    // means that window is streaming a reply → working.
    //
    // working/idle come straight from that button; "done" (turn ended, your turn) is
    // synthesized — latched on the working→not-working edge, then cleared the moment
    // that window is the one you're looking at, so it pings exactly once. Both latches
    // are per window: the chat window finishing a turn must not light up Design.
    private func desktopStatus() -> (pid: pid_t, windows: [DesktopWindow])? {
        guard let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.anthropic.claudefordesktop").first,
              !app.isTerminated else {
            desktopWasWorking.removeAll(); desktopDoneLatched.removeAll()
            desktopCache = nil; desktopFallbackCache = nil
            desktopModelByWid.removeAll(); desktopModelAt.removeAll()
            // Its window numbers died with it, and a number the system later recycles for
            // some other app's window would resurrect a phantom row. Written only when
            // there is something to forget: this branch runs on every refresh for as long
            // as the desktop app stays closed.
            if !desktopKnownWids.isEmpty || !desktopDesignWids.isEmpty {
                desktopKnownWids.removeAll(); desktopDesignWids.removeAll()
                saveKnownWindows()
            }
            return nil
        }
        let pid = app.processIdentifier
        let now = Date().timeIntervalSince1970
        // ~2s throttle: an idle window has no "Stop response" to early-exit on, so each
        // probe walks its whole a11y tree (~200ms); chat working/done state doesn't
        // need sub-second latency, so we reuse the cache between probes to bound cost.
        // The throttle must also hold when there is NO cache (AX failing) — otherwise a
        // failing probe re-walks the tree on every single refresh, several times a second
        // during an active turn, which is the state where we can least afford it.
        if now - desktopProbeAt < 2.0 {
            if let c = desktopCache, c.pid == pid { return c }
            return desktopFallback(pid: pid)
        }
        desktopProbeAt = now

        let axApp = AXUIElementCreateApplication(pid)
        // SetMessagingTimeout applies ONLY to the object it is set on (AXUIElement.h) — it
        // is NOT inherited by the windows and subtree elements we get back from this app
        // element, so the old comment claiming this bounded the tree walk was wrong (the
        // walk has always run on the process default, and still does — the only way to
        // change that is the system-wide element, which would also re-tune every VSCode /
        // FocusRing walk, so it is deliberately left alone).
        //
        // What this budget does cover is the one call that decides whether we see any
        // windows at all. 0.3s was routinely too short for Electron's main thread — on
        // launch, while streaming, during a Squirrel self-update — and each timeout used to
        // cost us every desktop row. Windows get their own budget below for the same reason
        // (title/subrole/frame reads are what classify them).
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        // Keep the activation's own error: this is the one call that is supposed to make
        // Chromium build its tree, and until now we threw its result away — which is why
        // "err=0 ax=0" (the read succeeds, the window array is empty) was undiagnosable.
        // It separates "we asked and were refused" from "we asked, were told OK, and the
        // tree still never appeared" — a different bug with a different fix.
        let manErr = AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // AXEnhancedUserInterface is VoiceOver's switch, kept only as a fallback for
        // builds where Electron's own attribute doesn't take. Set it ONCE per app launch,
        // never on a 2s loop: repeatedly enabling it degrades window positioning and
        // makes window operations sluggish (Mozilla bug 1664992) — i.e. it would sabotage
        // our own raise/FocusRing paths.
        if desktopEnhancedForPid != pid {
            desktopEnhancedForPid = pid
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        var windowsV: AnyObject?
        var axErr = AXUIElementCopyAttributeValue(
            axApp, kAXWindowsAttribute as CFString, &windowsV)
        if axErr != .success {
            // One failure means nothing: Chromium builds the tree asynchronously, so the
            // answer can arrive a fraction of a second later. Retry once in the same pass
            // rather than writing the whole app off for another 2s.
            usleep(250_000)
            axErr = AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsV)
        }
        let axWindows = windowsV as? [AXUIElement] ?? []
        // Standard windows only: dialogs/panels (settings sheets, updater popups) are
        // not sessions and must not each sprout a row.
        let cgWindows = desktopWindowList(pid: pid)
        var live: [(wid: CGWindowID, el: AXUIElement)] = []
        var claimed = Set<CGWindowID>()
        var widMisses = 0
        for win in axWindows {
            AXUIElementSetMessagingTimeout(win, 1.0)
            guard axStringAttr(win, kAXSubroleAttribute as String) != "AXDialog" else { continue }
            var wid = CGWindowID(0)
            if _AXUIElementGetWindow(win, &wid) != .success || wid == 0 {
                // The private wid API has no guarantee and does fail on live windows.
                // Fall back to matching the window's AX frame against WindowServer's
                // bounds (both are global, top-left origin), accepting only an
                // unambiguous hit — dropping the window instead would cost it its row.
                widMisses += 1
                guard let matched = matchDesktopWid(win, in: cgWindows, taken: claimed)
                else { continue }
                wid = matched
            }
            guard !claimed.contains(wid) else { continue }
            claimed.insert(wid)
            live.append((wid, win))
        }
        // The windows WindowServer vouches for, which unlike AX spans every Space. Asked
        // once here and handed to the fallback so the two paths can't disagree — and so a
        // pass that ends in the fallback doesn't pay for the enumeration twice.
        let wsReal = WindowServerWindows.realWindows(cgWindows)
        logDesktopProbe(err: axErr, manErr: manErr, axCount: axWindows.count,
                        usable: live.count, cgCount: cgWindows.count, wsCount: wsReal?.count,
                        widMisses: widMisses, pid: pid, now: now)
        // AX told us nothing usable. WindowServer is the authority on EXISTENCE, so the
        // rows stay (degraded) — and when it says there are no windows either, the user
        // really did close them all.
        if live.isEmpty {
            var degraded = desktopFallback(pid: pid, wsReal: wsReal)
            // Adopt the degraded answer as the cached truth. This probe IS a verdict —
            // AX walked and came back with nothing — so leaving desktopCache holding the
            // last AX-backed answer makes the two exits disagree for the whole 2s window:
            // the probe returns the degraded rows while every refresh in between keeps
            // serving the stale ones, and a row the degraded path drops blinks out and
            // back once per probe. Observed 2026-08-25 with the desktop app open and its
            // window closed (ws=0 for 18 minutes) — one row flashing every 2s.
            // Only the real-probe exit adopts; the throttled call above must NOT, which is
            // why desktopFallback itself still never writes desktopCache (see there).
            // Titles are the one thing the degraded path cannot rebuild — they come from
            // AX and nowhere else — so carry them over per wid instead of blanking them
            // (model already survives via desktopModelByWid, kind via desktopDesignWids).
            var labels: [CGWindowID: String] = [:]
            if let prev = desktopCache, prev.pid == pid {
                for w in prev.windows where !w.label.isEmpty { labels[w.wid] = w.label }
            }
            if !labels.isEmpty {
                degraded.windows = degraded.windows.map { w in
                    guard w.label.isEmpty, let l = labels[w.wid] else { return w }
                    var w = w; w.label = l; return w
                }
            }
            desktopCache = degraded
            return degraded
        }
        let focusedWid = axWindowID(axAttr(axApp, kAXFocusedWindowAttribute as String))
        // Piggyback on this (already throttled) probe to keep the window AX cache
        // current — that cache is what makes a jump switch to the app's OWN Space
        // instead of dragging its window here (see cacheDesktopWindows).
        cacheDesktopWindows(live, focused: focusedWid, pid: pid)

        // Drop state for windows that are gone, so a recycled window number can't
        // inherit a stale latch or classification. Pruned against WINDOWSERVER's list,
        // not the AX one: a window whose AX element we missed this pass still exists, and
        // wiping its Design flag would bounce its row between groups.
        let liveWids = Set(cgWindows.map { $0.wid }).union(live.map { $0.wid })
        desktopWasWorking = desktopWasWorking.filter { liveWids.contains($0.key) }
        desktopDoneLatched = desktopDoneLatched.filter { liveWids.contains($0.key) }
        desktopModelByWid = desktopModelByWid.filter { liveWids.contains($0.key) }
        desktopModelAt = desktopModelAt.filter { liveWids.contains($0.key) }

        // This is what makes the degraded path possible at all: every window AX vouched
        // for this pass joins the remembered set, so a LATER probe failure still has rows
        // to hand back. Windows AX missed this pass are kept (they're still alive per
        // WindowServer) — the miss is usually Electron being busy, not the window closing.
        let before = desktopWindowStore
        desktopKnownWids = desktopKnownWids.intersection(liveWids).union(live.map { $0.wid })
        desktopDesignWids = desktopDesignWids.intersection(liveWids)

        var windows: [DesktopWindow] = []
        for (wid, el) in live {
            let title = axStringAttr(el, kAXTitleAttribute as String) ?? ""
            // Two independent tells, because neither alone is reliable: the native
            // title reads "Design" only on the project list (it becomes the project's
            // name once you open one), and the web area's title is the durable
            // identity. Sticky for the window's lifetime, so an already-classified
            // window costs nothing to re-check and can't flip to chat later.
            if !desktopDesignWids.contains(wid),
               title == "Design" || title.hasPrefix("Claude Design")
                   || axIsDesignSurface(el, depth: 0) {
                desktopDesignWids.insert(wid)
            }
            let isDesign = desktopDesignWids.contains(wid)
            dumpTreeIfAsked(el, wid: wid, isDesign: isDesign, now: now)

            let status: String
            if axIsGenerating(el, isDesign: isDesign) {
                desktopWasWorking[wid] = true
                desktopDoneLatched[wid] = false
                status = "working"
            } else {
                if desktopWasWorking[wid] == true {
                    desktopDoneLatched[wid] = true
                    desktopWasWorking[wid] = false
                }
                // "Seen" is per window now: the app being frontmost proves nothing when
                // the window you're actually reading is a different one of its windows.
                if app.isActive, wid == focusedWid { desktopDoneLatched[wid] = false }
                status = desktopDoneLatched[wid] == true ? "done" : "idle"
            }
            // The generic shell titles carry no information the header doesn't already
            // show — blank them so the row falls back to its "Claude App"/"Claude
            // Design" name instead of repeating it.
            let label = (title == "Design" || title == "Claude") ? "" : title
            windows.append(DesktopWindow(wid: wid, isDesign: isDesign, status: status,
                                         label: label, model: desktopModel(el, wid: wid, now: now)))
        }
        // Windows AX missed entirely. On a mixed setup — chat window here, Design window
        // full-screen or on another desktop — AX returns only the ones sharing your Space,
        // so without this the other row is missing for exactly as long as you don't go
        // looking for it. They join as degraded rows (same shape the fallback produces):
        // no status, no model, and grouped as chat until a probe on their Space classifies
        // them. Not added to desktopKnownWids — that set means "a11y vouched for this",
        // and it is what the fallback trusts when SkyLight itself goes away.
        let axSeen = Set(windows.map { $0.wid })
        for wid in (wsReal ?? []).subtracting(axSeen).sorted() {
            windows.append(DesktopWindow(wid: wid, isDesign: desktopDesignWids.contains(wid),
                                         status: desktopDoneLatched[wid] == true ? "done" : "idle",
                                         label: "", model: desktopModelByWid[wid] ?? ""))
        }
        // One write per probe, and only when the membership actually moved — the probe runs
        // every 2s for as long as the app is open, and re-encoding an unchanged set each
        // time would be pure disk churn.
        if desktopWindowStore != before { saveKnownWindows() }

        let result = (pid: pid, windows: windows)
        desktopCache = result
        return result
    }

    // Whether AXEnhancedUserInterface has been set for this app launch (see desktopStatus
    // for why it must not be re-set on the probe loop).
    private var desktopEnhancedForPid: pid_t = 0

    // The rows that survive without Accessibility: windows AX has positively identified
    // (now or in an earlier run), still alive according to WindowServer.
    //
    // WHY NOT "every CGWindowList entry": the desktop app publishes ~13 layer-0 windows —
    // one 3440×30 / 1728×33 strip per display for its native top bar, a 500×500 helper, a
    // couple of never-shown 800×600 shells — for a single visible chat window. Rows built
    // from that list raw would be a dozen phantoms, which is a worse bug than the one being
    // fixed. So WindowServer is used only to answer "does this window still exist", never
    // "is this window a session".
    //
    // What degrades while AX is down:
    //   • status — no a11y tree means no "Stop response", so no way to see a stream in
    //     progress; a pending done latch still shows, everything else reads 闲置.
    //   • model — the last value read for that window, blank if never read.
    //   • kind — from the sticky per-wid classification, saved with the window list.
    //   • brand-new windows — a11y has never described them, so they carry no status, no
    //     model and no kind. They are still shown: WindowServer can tell a real window
    //     from a top-bar strip on its own (WindowServerWindows), which is what lets a
    //     window that has only ever existed on another Space have a row at all. If that
    //     path is unavailable they stay invisible, as they did before it existed —
    //     inventing rows is the worse failure, and the probe log explains the silence.
    // Deliberately does NOT write desktopCache when called from the THROTTLED path: that
    // call is not a verdict, just a stand-in between probes, and overwriting the cache with
    // it would make the throttle serve guesses. The real-probe path is the opposite case —
    // AX walked and came back empty, which IS a verdict — so desktopStatus adopts the
    // result there itself (see the live.isEmpty branch; the two exits must agree or the
    // rows flicker at the probe period).
    //
    // `wsReal` is passed in when the caller already asked WindowServer this pass; nil means
    // "ask now" (the throttled path, which has no probe of its own).
    private func desktopFallback(pid: pid_t,
                                 wsReal: Set<CGWindowID>? = nil) -> (pid: pid_t, windows: [DesktopWindow]) {
        let t = Date().timeIntervalSince1970
        if t - desktopFallbackAt < 2.0, let c = desktopFallbackCache, c.pid == pid { return c }
        let cgWindows = desktopWindowList(pid: pid)
        let liveWids = Set(cgWindows.map { $0.wid })
        if liveWids.isEmpty {
            // Really none left. Cache the empty answer (the throttle branch would
            // otherwise keep handing back the last non-empty one for 2s and flicker the
            // rows back) and drop the per-window state with it.
            desktopWasWorking.removeAll(); desktopDoneLatched.removeAll()
            desktopModelByWid.removeAll(); desktopModelAt.removeAll()
            // Only rewrite the file when there is something to forget: this branch runs on
            // every probe while the app sits with no windows open.
            if !desktopKnownWids.isEmpty || !desktopDesignWids.isEmpty {
                desktopKnownWids.removeAll(); desktopDesignWids.removeAll()
                saveKnownWindows()
            }
            let empty = (pid: pid, windows: [DesktopWindow]())
            // Both memos, not just one. They are two views of the same answer and the
            // throttle reads whichever is live, so clearing one and leaving the other
            // holding a non-empty snapshot keeps rows alive for another 2s after the
            // windows are provably gone.
            desktopCache = empty
            desktopFallbackCache = empty
            desktopFallbackAt = t
            return empty
        }
        // Union, not replacement: the remembered set is the stronger evidence (a11y saw
        // that window itself), and it also covers windows WindowServer's own filter would
        // reject — a chat window shrunk below the size gate stays on screen.
        var wids = desktopKnownWids.intersection(liveWids)
        wids.formUnion(wsReal ?? WindowServerWindows.realWindows(cgWindows) ?? [])
        let windows = wids.sorted().map { wid in
            DesktopWindow(wid: wid, isDesign: desktopDesignWids.contains(wid),
                          status: desktopDoneLatched[wid] == true ? "done" : "idle",
                          label: "", model: desktopModelByWid[wid] ?? "")
        }
        let result = (pid: pid, windows: windows)
        desktopFallbackCache = result
        desktopFallbackAt = Date().timeIntervalSince1970
        return result
    }

    // Memo for the degraded answer. Without it the throttle stops bounding anything on the
    // one machine state where it matters most: while AX is down, EVERY refresh takes the
    // fallback path, and each one enumerates every window on the system
    // (CGWindowListCopyWindowInfo is system-wide, not per-app). refresh() fires several
    // times a second during an active turn, and "AX is down" can be the permanent state.
    // Kept separate from desktopCache on purpose — that one holds the last AX-backed truth
    // and must not be overwritten with a guess.
    private var desktopFallbackCache: (pid: pid_t, windows: [DesktopWindow])?
    private var desktopFallbackAt: Double = 0

    // A window's CGWindowID recovered from its geometry, for when _AXUIElementGetWindow
    // fails. AX positions/sizes and CGWindowBounds are both global and top-left-origin,
    // so they compare directly (2pt slack absorbs rounding). Ambiguity → nil: two windows
    // stacked at the same frame can't be told apart, and guessing would swap two rows'
    // identities, which is worse than one row briefly lacking AX detail.
    private func matchDesktopWid(_ win: AXUIElement,
                                 in cg: [(wid: CGWindowID, frame: CGRect)],
                                 taken: Set<CGWindowID>) -> CGWindowID? {
        guard let posV = axAttr(win, kAXPositionAttribute as String),
              let sizeV = axAttr(win, kAXSizeAttribute as String) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posV as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeV as! AXValue, .cgSize, &s) else { return nil }
        let hits = cg.filter {
            !taken.contains($0.wid)
                && abs($0.frame.origin.x - p.x) < 2 && abs($0.frame.origin.y - p.y) < 2
                && abs($0.frame.width - s.width) < 2 && abs($0.frame.height - s.height) < 2
        }
        return hits.count == 1 ? hits[0].wid : nil
    }

    // Which windows AX has vouched for, and which of those are Design — persisted so both
    // survive a SpectiX restart. They live in ONE file because they are only ever read
    // together (a fallback row needs its kind) and must never disagree about which windows
    // exist. Window numbers are stable for a window's lifetime and unique within a boot, so
    // the only risk is a number recycled by a later window — pruning to LIVE windows on load
    // and on every probe keeps a dead entry from being inherited.
    //
    // Backing both sets with one stored property keeps that to a single file read: two lazy
    // vars would each decode the file, and the second would do it at some later, unrelated
    // moment.
    private struct DesktopWindowStore: Codable, Equatable {
        var known: Set<CGWindowID> = []
        var design: Set<CGWindowID> = []
    }
    private lazy var desktopWindowStore: DesktopWindowStore = loadKnownWindows()
    private var desktopKnownWids: Set<CGWindowID> {
        get { desktopWindowStore.known }
        set { desktopWindowStore.known = newValue }
    }
    private var desktopDesignWids: Set<CGWindowID> {
        get { desktopWindowStore.design }
        set { desktopWindowStore.design = newValue }
    }

    private var knownWindowsPath: String { "\(dataDir)/desktop-windows.json" }
    private func loadKnownWindows() -> DesktopWindowStore {
        // Superseded by the file below (it held the Design set alone, as a bare array).
        // Dropping it rather than migrating: the whole store is a cache keyed by window
        // numbers, so it is worthless the moment the desktop app restarts, and one probe
        // rebuilds it.
        try? FileManager.default.removeItem(atPath: "\(dataDir)/desktop-design-wids.json")
        guard let data = FileManager.default.contents(atPath: knownWindowsPath),
              var store = try? JSONDecoder().decode(DesktopWindowStore.self, from: data)
        else { return DesktopWindowStore() }
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let live = Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        store.known.formIntersection(live)
        store.design.formIntersection(live)
        return store
    }
    private func saveKnownWindows() {
        try? JSONEncoder().encode(desktopWindowStore)
            .write(to: URL(fileURLWithPath: knownWindowsPath))
    }

    // A line in desktop-probe.log whenever the probe is NOT clean, so the next report of
    // "the Claude rows are missing" is diagnosable instead of a guessing game. The reason
    // codes separate the three causes that look identical from the outside:
    //   err=-25211 (APIDisabled)   → our Accessibility grant is gone/dead
    //   err=-25204 (CannotComplete) + finder=0 → Claude's main thread was too busy
    //   err=0, ax=0, cg>0, on=0    → NOT A FAULT: every window is on another Space (see
    //                                below). Logged, but never counted as a failure.
    //   err=0, ax=0, cg>0, on>0    → windows are right here and AX still won't list them —
    //                                THIS is the "tree not built yet" case (Chromium's lazy
    //                                a11y), and the only one worth chasing.
    //   man!=0                     → the app REFUSED the AXManualAccessibility activation
    //                                (-25205 attributeUnsupported = this Electron build no
    //                                longer honours it, so no amount of waiting will help)
    //   finder!=0 while trusted=1  → TCC says granted but AX is dead for this process
    //                                (a real macOS bug; re-toggling the switch fixes it)
    //   ws=N                       → how many real windows WindowServer found across ALL
    //                                Spaces (WindowServerWindows). "ax=0 ws=1" is the
    //                                off-Space case with a row still delivered; ws=0 means
    //                                Claude genuinely has no window open; ws=off means the
    //                                SkyLight symbols are gone and only a11y-vouched
    //                                windows can produce rows.
    //
    // WHY on= EXISTS (this one cost a whole investigation): kAXWindows enumerates ONLY the
    // windows on the CURRENT Space — the same constraint that caused the multi-window jump
    // bug, already written down at raiseDesktopWindow. desktopWindowList asks CGWindowList
    // for .optionAll, which spans every Space. So "cg=12 ax=0" is the EXPECTED reading
    // whenever Claude sits on another desktop or full-screen (a full-screen window is on a
    // Space of its own by definition), and it stays that way for as long as you're looking
    // elsewhere. Measured on a real machine mid-investigation: optionAll=12, onScreenOnly=0.
    // Without on= this reads exactly like a broken a11y tree and sends the next reader after
    // Chromium, Electron and the TCC database — all three innocent.
    // Finder is the canary because it's always running, native, and never Chromium.
    // Quiet by construction: same signature is logged at most once a minute, and the file
    // is truncated when it passes 200KB, so a permanently broken state can't fill the disk.
    private func logDesktopProbe(err: AXError, manErr: AXError, axCount: Int, usable: Int,
                                 cgCount: Int, wsCount: Int?, widMisses: Int,
                                 pid: pid_t, now: Double) {
        // "AX delivered" — rows came out of the a11y tree, or there were genuinely no
        // windows to find. A wid recovered by frame matching still counts as delivered
        // (the row is complete); it only earns a log line, because a private API quietly
        // starting to fail is exactly the kind of thing we want to find in the log later.
        let delivered = err == .success && (usable > 0 || cgCount == 0)
        // Only asked for on the unhappy path: it is a second system-wide window enumeration,
        // and on the happy path nobody needs it.
        let onScreen = delivered ? cgCount : desktopOnScreenCount(pid: pid)
        // Nothing on this Space to enumerate, so an empty AX answer is the CORRECT one.
        // Counting it would peg desktopProbeFails at "permanently broken" for the entirely
        // ordinary case of Claude living on another desktop.
        let offSpace = err == .success && axCount == 0 && onScreen == 0 && cgCount > 0
        if delivered || offSpace {
            desktopProbeFails = 0
            if delivered { AppController.setAXDegraded(false) }
        } else {
            desktopProbeFails += 1
        }
        guard !delivered || widMisses > 0 else { return }
        let trusted = AXIsProcessTrusted()
        // Three strikes before crying permission: a busy app or an unbuilt tree recovers on
        // its own, a dead grant does not. The canary is cached for 30s — when the failure is
        // permanent this runs every 2s forever, and it is an AX round trip of its own.
        let finderErr = axCanaryCached(now: now)
        if desktopProbeFails >= 3 { AppController.setAXDegraded(finderErr != 0 || !trusted) }
        let sig = "err=\(err.rawValue) man=\(manErr.rawValue) ax=\(axCount)"
                + " usable=\(usable) cg=\(cgCount) on=\(onScreen)"
                + " ws=\(wsCount.map(String.init) ?? "off")"
                + " widMiss=\(widMisses) trusted=\(trusted ? 1 : 0) finder=\(finderErr)"
                + (offSpace ? " OFF-SPACE(normal)" : "")
        guard desktopProbeLastSig != sig || now - desktopProbeLastLog > 60 else { return }
        desktopProbeLastSig = sig
        desktopProbeLastLog = now
        let path = "\(dataDir)/desktop-probe.log"
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > 200_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let line = "[\(Int(now))] \(sig) fails=\(desktopProbeFails)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    private var desktopProbeFails = 0
    private var desktopProbeLastSig = ""
    private var desktopProbeLastLog: Double = 0

    // Every jump decision, in a file that is still there tomorrow (T24 "sometimes the
    // hotkey lands on a terminal that is running"). NSLog alone could not close that
    // bug: this app's own FrontBoard chatter runs ~250k unified-log lines every three
    // hours, which rotates /var/db/diagnostics to well under a day, so `log show` came
    // back empty at every attempt to collect the evidence — the report always arrives
    // hours after the press. Same shape as desktop-probe.log above, and equally cheap:
    // each of these lines is caused by a human pressing a key or clicking a row, never
    // by a timer (the per-poll idle trace at maybeIdleAutoJump stays NSLog-only and
    // TB_DEBUG-gated for exactly that reason).
    private func jumpDiag(_ msg: String) {
        // ★ Home path → "~" before ANY of this is written (改这里前必读). These lines carry the
        // jump's cwd and the editor windows' TITLES, and the account name inside /Users/<name>
        // is usually a real person's name — the one field in this file that identifies a human
        // rather than describing a window. Stripping it at the single choke point every line
        // passes through is why a new call site can't forget to. NSLog gets the redacted copy
        // too: the unified log is exportable.
        // Project and file names are deliberately KEPT. Title matching is precisely what this
        // log exists to debug ("NO title matched components=…"), and hashing them would buy a
        // little privacy at the cost of the file's whole purpose. Nothing here is ever sent
        // anywhere — the exposure this guards against is the user pasting the log into a bug
        // report by hand, and a project name is a far smaller thing to hand over than a name.
        let msg = msg.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        NSLog("TB jump: %@", msg)
        let path = "\(dataDir)/jump-diag.log"
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > 200_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let line = "[\(AppController.jumpDiagClock.string(from: Date()))] \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    // Wall-clock, not epoch: the reader of this file is a human matching lines against
    // "it happened right after lunch", and a DateFormatter costs too much to rebuild.
    private static let jumpDiagClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    // 0 when Accessibility genuinely works for this process. Asking FINDER (always
    // running, native, never Chromium) is the only way to tell "our grant is dead" from
    // "that Electron app is being difficult" — and it catches the case where
    // AXIsProcessTrusted() reports true while every AX call comes back empty.
    private func axCanaryCached(now: Double) -> Int32 {
        if now - axCanaryAt < 30 { return axCanaryLast }
        axCanaryAt = now
        axCanaryLast = axCanaryError()
        return axCanaryLast
    }
    private var axCanaryAt: Double = 0
    private var axCanaryLast: Int32 = 0

    private func axCanaryError() -> Int32 {
        guard let finder = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.finder").first else { return 0 }
        let el = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
        // Finder with zero windows is normal and still proves AX works.
        return err == .success || err == .noValue ? 0 : err.rawValue
    }

    // Accessibility is granted on paper but not working (see axCanaryError). Written from
    // the scan queue, read by the popover's warning button on main.
    private(set) static var axDegraded = false
    private static func setAXDegraded(_ v: Bool) {
        guard axDegraded != v else { return }
        DispatchQueue.main.async { axDegraded = v }
    }

    // True if this window is streaming a reply. Two tells, because the two surfaces
    // announce it completely differently:
    //
    //  1. A button described "Stop response" — the chat window's tell.
    //  2. A short status line ending in "…" ("Thinking…", "Shelling…", "Generating
    //     questions…") — the DESIGN window's tell. Design's stop control carries NO
    //     accessible name at all (empty title and description; its label is an
    //     invisible icon glyph), so there is nothing to match on the button itself —
    //     which is why Design used to sit at 闲置 through an entire turn.
    //
    // Design's rule needs BOTH halves, and neither survives alone:
    //
    //  - a short status line ending in "…" ("Thinking…", "Shelling…") — but those
    //    labels stay in the transcript as step history after the turn ends, so on its
    //    own this pins the row at 运行中 forever;
    //  - the composer's "Send" label being GONE — while streaming, Send is swapped for
    //    the (anonymous) stop button. On its own an absence test is unsafe: any state
    //    that doesn't render a composer would read as "generating".
    //
    // Together they're tight: streaming = status line AND no Send. Once Send comes
    // back the turn is over no matter what the transcript still says, and a window with
    // no composer at all lacks the status line, so it stays idle. Every ambiguity
    // resolves toward "not working" on purpose — a false positive pins a row at 运行中
    // forever, which is far worse than a missed turn.
    private func axDesignIsGenerating(_ el: AXUIElement, depth: Int,
                                      found: inout (status: Bool, send: Bool)) {
        // Both settled → the answer can't change, stop walking.
        if depth > 60 || (found.status && found.send) { return }
        if axStringAttr(el, kAXRoleAttribute as String) == "AXStaticText",
           let v = axStringAttr(el, kAXValueAttribute as String) {
            if v == "Send" { found.send = true }
            // Narrow on purpose (≤30 chars, ≤3 words) so transcript prose that happens
            // to trail off can't pass for a status line.
            if v.hasSuffix("…"), v.count <= 30, v.split(separator: " ").count <= 3 {
                found.status = true
            }
        }
        var kidsV: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsV) == .success,
              let kids = kidsV as? [AXUIElement] else { return }
        for k in kids {
            axDesignIsGenerating(k, depth: depth + 1, found: &found)
            if found.status && found.send { return }
        }
    }

    // True if this window is streaming a reply. The two surfaces announce it in
    // completely different ways, so they get different tests:
    //
    //  - CHAT: a button described "Stop response". Exact, and it early-exits on the
    //    first hit, which is what keeps the probe affordable when the app is busiest.
    //  - DESIGN: see axDesignIsGenerating. Design's stop control has NO accessible name
    //    at all (empty title and description; its label is an invisible icon glyph), so
    //    there is nothing to match on the button itself — which is why Design used to
    //    sit at 闲置 through an entire turn.
    private func axIsGenerating(_ win: AXUIElement, isDesign: Bool) -> Bool {
        guard isDesign else { return axHasStopButton(win, depth: 0) }
        var found = (status: false, send: false)
        axDesignIsGenerating(win, depth: 0, found: &found)
        return found.status && !found.send
    }

    private func axHasStopButton(_ el: AXUIElement, depth: Int) -> Bool {
        if depth > 60 { return false }
        if axStringAttr(el, kAXRoleAttribute as String) == "AXButton",
           let d = axStringAttr(el, kAXDescriptionAttribute as String),
           d.lowercased().contains("stop response") {
            return true
        }
        var kidsV: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsV) == .success,
              let kids = kidsV as? [AXUIElement] else { return false }
        for k in kids where axHasStopButton(k, depth: depth + 1) { return true }
        return false
    }

    // The desktop app's a11y tree, dumped for investigation. Opt in by touching
    // ~/.claude/spectix/design-ax-dump.request (delete it to stop); writes
    // design-tree-<wid>-<0…5>.txt, one file per DISTINCT tree state per window.
    //
    // Why "while streaming" and not a one-shot: everything worth finding here (the stop
    // control, the status line) exists ONLY during a turn, so a dump taken before or
    // after shows nothing — you diff a generating snapshot against a finished one. And
    // why a file flag rather than an env var: the app has to be launched through
    // LaunchServices to keep its Accessibility grant (a process started from a terminal
    // is attributed to the terminal for TCC and gets NO AX access — see
    // docs/permissions.md), so there is no launch we could attach an env var to.
    private func dumpTreeIfAsked(_ win: AXUIElement, wid: CGWindowID,
                                 isDesign: Bool, now: Double) {
        guard FileManager.default.fileExists(atPath: "\(dataDir)/design-ax-dump.request")
        else { return }
        var out: [String] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth <= 60, out.count < 3000 else { return }
            let role = axStringAttr(el, kAXRoleAttribute as String) ?? "?"
            let fields = [kAXSubroleAttribute as String, kAXTitleAttribute as String,
                          kAXDescriptionAttribute as String, kAXValueAttribute as String,
                          "AXDOMIdentifier", "AXDOMClassList"]
                .compactMap { k -> String? in
                    guard let v = axStringAttr(el, k) else { return nil }
                    return "\(k.replacingOccurrences(of: "AX", with: ""))=\(v)"
                }
            out.append(String(repeating: " ", count: depth) + role
                       + (fields.isEmpty ? "" : " | " + fields.joined(separator: " | ")))
            var kidsV: AnyObject?
            guard AXUIElementCopyAttributeValue(
                      el, kAXChildrenAttribute as CFString, &kidsV) == .success,
                  let kids = kidsV as? [AXUIElement] else { return }
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(win, depth: 0)
        // Only on CHANGE: at one snapshot per 2s poll a 6-slot ring covers 12 seconds,
        // which a generating window can easily outlive. Keyed on the tree's content, the
        // same ring holds the last 6 DISTINCT states — which is what a diff needs.
        let body = out.joined(separator: "\n")
        guard probeLastBody[wid] != body else { return }
        probeLastBody[wid] = body
        try? "[\(Int(now))] wid=\(wid) isDesign=\(isDesign) nodes=\(out.count)\n\(body)"
            .write(toFile: "\(dataDir)/design-tree-\(wid)-\(probeSnapshot[wid] ?? 0).txt",
                   atomically: true, encoding: .utf8)
        probeSnapshot[wid] = ((probeSnapshot[wid] ?? 0) + 1) % 6
    }
    private var probeSnapshot: [CGWindowID: Int] = [:]
    private var probeLastBody: [CGWindowID: String] = [:]

    // The model that window's own picker is set to ("Opus 5"), cached per window and
    // re-read at most every 30s. This is the ONE genuinely per-window fact the desktop
    // app exposes — its spend is not reported anywhere local (see the usage section of
    // docs/desktop-app.md) — but the picker sits deep in the tree (~depth 25 in a chat
    // window), so it gets its own slow cadence instead of riding the 2s status probe.
    private var desktopModelByWid: [CGWindowID: String] = [:]
    private var desktopModelAt: [CGWindowID: Double] = [:]
    private func desktopModel(_ win: AXUIElement, wid: CGWindowID, now: Double) -> String {
        if let at = desktopModelAt[wid], now - at < 30 { return desktopModelByWid[wid] ?? "" }
        desktopModelAt[wid] = now
        let model = axFindModel(win, depth: 0) ?? desktopModelByWid[wid] ?? ""
        desktopModelByWid[wid] = model
        return model
    }

    // The model picker's popup button under this window, reduced to just the model
    // name. Three spellings seen in the wild — "Model  Opus 5" (Design home),
    // "Model: Opus 5 High" (chat) and a bare "Opus 5 Medium " (Design inside a
    // project) — so the "Model" label is optional and the real test is that what's
    // left NAMES A MODEL FAMILY. Matching any popup would pick up the window's other
    // ones ("No file open", "Account menu").
    private static let modelFamilies: Set<String> = ["Opus", "Sonnet", "Haiku", "Fable", "Claude"]
    private func axFindModel(_ el: AXUIElement, depth: Int) -> String? {
        if depth > 60 { return nil }
        if axStringAttr(el, kAXRoleAttribute as String) == "AXPopUpButton",
           let t = axStringAttr(el, kAXTitleAttribute as String) {
            var name = t
            if name.hasPrefix("Model") { name = String(name.dropFirst("Model".count)) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ": \u{00a0}\t\n"))
            if let first = name.split(separator: " ").first,
               Self.modelFamilies.contains(String(first)) {
                return name
            }
        }
        var kidsV: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsV) == .success,
              let kids = kidsV as? [AXUIElement] else { return nil }
        for k in kids { if let m = axFindModel(k, depth: depth + 1) { return m } }
        return nil
    }

    // Is this window the Design surface? Every Electron window has exactly one web
    // area near the top of its tree, and that area names itself — so we descend only
    // until the FIRST one and answer from its title. Bounded on purpose: this is the
    // durable half of the classification (the native window title stops saying
    // "Design" once you open a project), and it must not cost a second full tree walk.
    private func axIsDesignSurface(_ el: AXUIElement, depth: Int) -> Bool {
        // 12, measured: the web area sits at depth 7 (Design) / 8 (chat), so this is
        // margin for a layout change rather than a tight fit that would silently
        // reclassify Design as chat.
        if depth > 12 { return false }
        if axStringAttr(el, kAXRoleAttribute as String) == "AXWebArea" {
            return axStringAttr(el, kAXTitleAttribute as String) == "Claude Design"
                || axStringAttr(el, kAXDescriptionAttribute as String) == "Claude Design"
        }
        var kidsV: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsV) == .success,
              let kids = kidsV as? [AXUIElement] else { return false }
        for k in kids where axIsDesignSurface(k, depth: depth + 1) { return true }
        return false
    }

    // Small AX accessors shared by the desktop probe. The desktop app puts the active
    // conversation (or Design project) name in each window's title, so a row can label
    // itself with what that window is showing instead of a generic tag.
    private func axAttr(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let out = v else { return nil }
        return (out as! AXUIElement)
    }

    private func axStringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    private func axWindowID(_ win: AXUIElement?) -> CGWindowID? {
        guard let win = win else { return nil }
        var wid = CGWindowID(0)
        guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    // argv via KERN_PROCARGS2 layout:
    //   [Int32 argc][exec_path\0][pad\0…][argv…][env…]
    // We only need argv (to recognize `claude` and skip daemon/bg-host workers); the
    // env that follows is ignored — session identity now comes from the per-tty state
    // file, not from the (inherited, unreliable) CLAUDE_CODE_* env vars.
    //
    // ★ Cached per process incarnation. Every refresh walks all ~700 pids on the machine,
    // and two KERN_PROCARGS2 sysctls per pid were the single biggest CPU cost of a scan
    // (sampled 2026-09-24: ~40% of scanQueue time). argv only changes on exec, and exec
    // keeps the pid AND the start time but replaces pbi_comm — so comm must be in the
    // key, or a shell that just forked-then-exec'd `claude` stays "zsh" forever and the
    // session never shows up.
    private struct ProcKey: Hashable { let pid: pid_t; let sec: UInt64; let usec: UInt64; let comm: String }
    private var argsCache: [pid_t: (key: ProcKey, args: [String])] = [:]
    private let argsCacheLock = NSLock()

    private func processArgs(_ pid: pid_t) -> [String] {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return readProcessArgs(pid) }
        let comm = withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let key = ProcKey(pid: pid, sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec, comm: comm)
        argsCacheLock.lock()
        if let hit = argsCache[pid], hit.key == key { argsCacheLock.unlock(); return hit.args }
        argsCacheLock.unlock()
        let args = readProcessArgs(pid)
        // Empty = refused or mid-exec; don't pin that.
        guard !args.isEmpty else { return args }
        argsCacheLock.lock()
        argsCache[pid] = (key, args)
        argsCacheLock.unlock()
        return args
    }

    private func pruneArgsCache(live: [pid_t]) {
        let keep = Set(live)
        argsCacheLock.lock()
        argsCache = argsCache.filter { keep.contains($0.key) }
        argsCacheLock.unlock()
    }

    private func readProcessArgs(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) < 0 || size == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) < 0 { return [] }
        guard size > MemoryLayout<Int32>.size else { return [] }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<MemoryLayout<Int32>.size]) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // skip exec_path
        while i < size && buf[i] == 0 { i += 1 }   // skip padding NULs
        var args: [String] = []
        var collected: Int32 = 0
        while collected < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if let s = String(bytes: buf[start..<i], encoding: .utf8) { args.append(s) }
            i += 1
            collected += 1
        }
        return args
    }

    // The interactive shell a terminal session lives in — what VSCode reports as
    // `terminal.processId`, the key the companion extension matches on to reveal the
    // right pane (and the FocusRing / StatusPip pane lookups, and the active-terminal
    // token the ack + frontmostIsSession checks compare against).
    //
    // ★ That is NOT always the direct parent. npm-installed Codex runs its native binary
    // UNDER a `node` launcher (measured 2026-09-08: zsh 69989 → node 70568 → codex 70569),
    // so ppid handed back the launcher and every pane-keyed path aimed at a pid VSCode
    // has never heard of: the window came forward, term.show revealed nothing, verify
    // logged `wanted sh70568` against a token that could never match, and the row's
    // done-ack never fired (the "click a Codex row, doesn't land on its terminal" bug).
    // Walk up to the nearest shell instead; a native `claude` under zsh resolves to its
    // parent exactly as before. No shell within reach (exotic launcher) → the old ppid.
    private func shellPID(above pid: pid_t, ppid: pid_t) -> pid_t {
        var cur = ppid
        for _ in 0..<6 {
            guard cur > 1 else { break }
            if let comm = processComm(cur), Self.shellNames.contains(comm) { return cur }
            guard let next = parentPID(cur) else { break }
            cur = next
        }
        return ppid
    }
    private static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "xonsh", "elvish",
    ]

    // Executable name (proc_bsdinfo.pbi_comm, ≤16 chars) — "zsh" for a login shell whose
    // argv[0] reads "-zsh". nil where proc_pidinfo is refused (setuid-root `login`).
    private func processComm(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    // ppid + controlling-tty name (e.g. "ttys006") via libproc. ppid is the parent
    // process; for the interactive shell behind a session use shellPID(above:ppid:).
    private func processBSDInfo(_ pid: pid_t) -> (ppid: pid_t, tty: String)? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        var tty = ""
        if info.e_tdev != UInt32.max { tty = ttyName(dev_t(info.e_tdev)) }
        return (pid_t(info.pbi_ppid), tty)
    }

    // devname() lstat()s its way through /dev on every call (~20% of a scan in the
    // 2026-09-24 sample). A device number always names the same ttysNNN node.
    private var ttyNames: [dev_t: String] = [:]
    private let ttyNamesLock = NSLock()
    private func ttyName(_ dev: dev_t) -> String {
        ttyNamesLock.lock(); defer { ttyNamesLock.unlock() }
        if let n = ttyNames[dev] { return n }
        guard let c = devname(dev, S_IFCHR) else { return "" }
        let n = String(cString: c)
        ttyNames[dev] = n
        return n
    }

    private func processCWD(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // MARK: Session status
    //
    // The status comes straight from the per-tty state file the spectix-status hook
    // writes (~/.claude/spectix/state-<tty>). We no longer infer it from the transcript:
    // Claude Code v2.1's daemon stopped writing a discoverable <session>.jsonl for live
    // terminal sessions, so transcript-mtime made everything look "working". The hooks
    // fire on the exact transitions instead:
    //   needs   红   permission/confirmation Notification
    //   working 蓝   UserPromptSubmit / PreToolUse (model is busy)
    //   done    绿   Stop (turn ended) or idle "waiting for your input" Notification
    //   idle    灰   no state reported yet (fresh session, or hook hasn't fired)
    private func sessionStatus(tty: String) -> String {
        guard !tty.isEmpty else { return "idle" }
        let s = (try? String(contentsOfFile: "\(dataDir)/state-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch s {
        case "needs", "working", "paused", "done": return s
        default:                                   return "idle"
        }
    }

    // The task summary the hook derived from the session's latest prompt
    // (~/.claude/spectix/title-<tty>). Empty when no prompt has been seen yet —
    // callers fall back to the folder/tty label.
    private func sessionTitle(tty: String) -> String {
        guard !tty.isEmpty else { return "" }
        let t = (try? String(contentsOfFile: "\(dataDir)/title-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // ★ Last line of defence against an INJECTED block leaking through as a title
        // (改这块前必读). The hook strips <ide_opened_file>…, dragged-in paths and
        // cross-session messages, but that gate has now been widened three times, each
        // time because a row was already wearing the leak — '<cross-session-message f'
        // (2026-09-12) being the latest. An opening tag cut mid-attribute by the hook's
        // 24-char slice has no '>' in it, which a real prompt about markup ('<Button> 怎么写')
        // does — so this drops the leak without ever eating a legitimate title.
        if t.hasPrefix("<"), !t.contains(">") { return "" }
        return t
    }

    // Usage for a Codex session, read from the rollout file the hook pointed at.
    //
    // ★ The pointer is why this is cheap and exact. Codex names the rollout in every
    // hook payload (transcript_path), the hook writes it to tp-<tty> verbatim, so we
    // never scan ~/.codex/sessions to guess which file belongs to this terminal — which
    // matters more than it sounds: that directory is full of decoys. Importing another
    // agent's config writes dozens of rollouts in the same second, so picking "the
    // newest file" or matching on mtime would attach a terminal to a session it never
    // ran. Empty pointer (no turn completed yet) yields nil, and the row stays blank.
    private func codexUsage(tty: String) -> CodexUsage? {
        guard !tty.isEmpty else { return nil }
        let path = (try? String(contentsOfFile: "\(dataDir)/tp-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return CodexSession.usage(rolloutPath: path)
    }

    // Everything the header's Claude and Codex cards need. Called once per poll.
    //
    // ★ Codex quota is ACCOUNT-level, not session-level — every live Codex session's
    // rollout carries the same rate_limits block. So this doesn't merge anything, it
    // just picks the freshest rollout and reads it: a session that hasn't completed a
    // turn yet has no token_count line at all, and an old one can carry a stale
    // percentage. Newest mtime wins, which is the only ordering that survives the user
    // running two Codex sessions at once.
    /// Last quota read off disk when no live Codex session could supply one, plus when
    /// it was taken — the read walks ~/.codex/sessions, so it is not a per-poll cost.
    private var codexDiskQuota: CodexUsage? = nil
    private var codexDiskQuotaAt: Double = 0

    private func headerAgentInfo(rows: [SessionRow]) -> HeaderAgentInfo {
        // ★ Before anything below touches the book: the demo's fake percentages must
        // not be filed under the user's real address (see Demo, MARK Accounts).
        if Demo.enabled {
            return HeaderAgentInfo(claudeUsage: Demo.usage(),
                                   codexUsage: Demo.codexUsage(),
                                   claudeAccount: Demo.account(.claude),
                                   codexAccount: Demo.account(.codex),
                                   claudeRemembered: true,
                                   codexRemembered: true)
        }
        var best: (mtime: Double, usage: CodexUsage)? = nil
        for r in rows where r.agentKind == .codex && !r.tty.isEmpty {
            let ptr = "\(dataDir)/tp-\(r.tty)"
            guard let path = (try? String(contentsOfFile: ptr, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let u = CodexSession.usage(rolloutPath: path)
            else { continue }
            if best == nil || mod > best!.mtime { best = (mod, u) }
        }
        // ★ No live session could supply quota — either none is running, or the ones
        // that are haven't completed a turn yet (a rollout has no token_count line until
        // then). Fall back to the newest rollout on disk so the card keeps showing the
        // last known figures instead of going blank while the account is still logged in.
        // Throttled: that path walks a directory, and this runs at ~1 Hz.
        if best == nil {
            let now = Date().timeIntervalSince1970
            if now - codexDiskQuotaAt > 60 {
                codexDiskQuotaAt = now
                codexDiskQuota = CodexSession.newestUsage()
            }
            if let u = codexDiskQuota { best = (codexDiskQuotaAt, u) }
        }
        var snap: UsageSnapshot? = nil
        if let u = best?.usage, u.sessionPct != nil || u.weekPct != nil {
            snap = UsageSnapshot(sessionPct: u.sessionPct.map { Int($0.rounded()) },
                                 sessionResetsAt: u.sessionResetsAt?.timeIntervalSince1970,
                                 weekPct: u.weekPct.map { Int($0.rounded()) },
                                 weekResetsAt: u.weekResetsAt?.timeIntervalSince1970,
                                 weekModelPct: nil, weekModelLabel: nil,
                                 updatedAt: best?.mtime ?? 0)
        }
        // Accounts are read straight from disk every poll — the reader caches on
        // mtime+size internally, so a hit is ~10µs and a logout still propagates.
        // The book is fed here too: one compare per tick, a write only when the
        // signed-in address changes.
        let claude = AgentAccounts.claude()
        let codex = AgentAccounts.codex()
        AccountBook.note(.claude, claude)
        AccountBook.note(.codex, codex)
        // File the quota against the account it was measured on. This is the only
        // moment that association exists: the numbers arrive with no owner attached,
        // and the owner is whoever is signed in right now.
        // ★ The RAW snapshots are what get filed — never the ones headerUsage hands
        // back below. Those may be a reading lifted out of the book, and writing it
        // back would restamp it as freshly measured (and drop the `probed` flag that
        // is the only reason a fetched figure counts as live).
        AccountBook.noteUsage(.claude, email: claude?.email, usage)
        AccountBook.noteUsage(.codex, email: codex?.email, snap)
        return HeaderAgentInfo(claudeUsage: headerUsage(usage, kind: .claude, email: claude?.email),
                               codexUsage: headerUsage(snap, kind: .codex, email: codex?.email),
                               claudeAccount: claude,
                               codexAccount: codex,
                               claudeRemembered: !AccountBook.list(.claude).isEmpty,
                               codexRemembered: !AccountBook.list(.codex).isEmpty)
    }

    /// What the header should draw for one CLI, given the newest reading we have and
    /// who is signed in.
    ///
    /// ★ Neither source of quota figures carries an address. `claude -p /usage` asks
    /// the default config and Codex's limits come out of a rollout — both describe
    /// whoever was signed in when they ran, and nothing in the answer says who that
    /// was. So the instant the user switches accounts, the newest reading on disk
    /// belongs to the account they LEFT, and drawing it on the new account's card is
    /// simply a wrong number under a name. `AccountBook.lastSwitch` is the guard: a
    /// reading older than the switch is disowned, and the card falls back to what this
    /// address itself last measured — marked as remembered, never as live.
    ///
    /// Nil out of here means "we have no figure for this account", which the card
    /// draws as "—". That is the honest answer for an address the app has never seen
    /// signed in, and it is better than a stranger's percentage.
    private func headerUsage(_ raw: UsageSnapshot?, kind: AgentKind, email: String?) -> UsageSnapshot? {
        let switchedAt = AccountBook.lastSwitch(kind)
        // No switch this run, or the reading is newer than one: it describes whoever
        // is signed in now, which is the account on the card. The common path.
        if switchedAt == 0 || (raw?.updatedAt ?? 0) > switchedAt { return raw }
        guard let email,
              let u = AccountBook.list(kind).first(where: { $0.email == email })?.usage
        else { return nil }
        let now = Date().timeIntervalSince1970
        var snap = UsageSnapshot()
        snap.sessionPct = u.sessionPct
        snap.sessionResetsAt = u.sessionResetsAt
        snap.weekPct = u.weekPct
        snap.weekResetsAt = u.weekResetsAt
        snap.updatedAt = u.readAt
        // A reading fetched from the usage endpoint FOR THIS ADDRESS is live on its
        // own terms — it was asked about this account by name, which is exactly what
        // the two local sources cannot do. Same window the panel's rows use.
        snap.live = u.probed == true && now - u.readAt < AccountBook.probeFreshFor
        snap.fetching = AccountBook.isProbing(kind, email: email)
        return snap
    }

    // The live step the hook recorded for a working session (~/.claude/spectix/
    // step-<tty>): the tool + target currently in flight, e.g. "Edit · main.swift".
    // Empty when no tool is running (turn start/end clear it), so the row falls back
    // to its usage line. Read verbatim; the cell truncates it grapheme-safely.
    private func sessionStep(tty: String) -> String {
        guard !tty.isEmpty else { return "" }
        return (try? String(contentsOfFile: "\(dataDir)/step-\(tty)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // How many agents the 🤖 ×N badge reports — i.e. how many nodes the sublist will
    // show, which is exactly what backgroundAgents kept after dropping the finished ones.
    // The badge must agree with the list it opens (a "×1" that opens onto nothing is the
    // same bug as 2 nodes under "×1"), so the caller passes the roster it already built.
    //
    // Falls back to the bg-<tty> running ledger ONLY when no roster file exists — an
    // older hook (or a session that launched agents before the roster existed) still gets
    // a count. It must NOT fall back on an empty-after-filtering roster: bg-<tty> keeps
    // an entry until the wake-up retires it, so a just-finished agent would come back as
    // a badge with no nodes behind it.
    private func backgroundAgentCount(tty: String, roster: Int) -> Int {
        if roster > 0 { return roster }
        guard !tty.isEmpty,
              !FileManager.default.fileExists(atPath: "\(dataDir)/agents-\(tty)"),
              let s = try? String(contentsOfFile: "\(dataDir)/bg-\(tty)", encoding: .utf8)
        else { return 0 }
        return s.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    // The roster behind that count: agents-<tty> (one JSON line per agent — id/type/
    // desc/start) joined with each running agent's live step file agent-step-<tty>-<id>.
    // A malformed line is skipped, not fatal: the hook hand-builds these lines, and one
    // bad launch mustn't blank the sublist.
    //
    // ★ Only RUNNING agents are listed. A finished one leaves as soon as it finishes,
    // by either of two independent signals — whichever lands first:
    //   1. its own transcript ended the turn (agentTail's finished flag) — immediate,
    //      and the only one available while the session sits idle;
    //   2. the hook removed / stamped `end` on its line — that needs the wake-up to
    //      reach a UserPromptSubmit, i.e. the user typing again.
    // Reading `end` here keeps a roster written by an older hook (which stamps instead
    // of removing) from showing returned agents forever.
    // `ctxLimit` is the parent session's window, carried onto every node so each agent's
    // occupancy renders as a percentage (see AgentInfo.ctxTokens).
    private func backgroundAgents(tty: String, ctxLimit: Int) -> [AgentInfo] {
        guard !tty.isEmpty,
              let s = try? String(contentsOfFile: "\(dataDir)/agents-\(tty)", encoding: .utf8)
        else { return [] }
        // The parent transcript pointer, read once per session rather than per agent —
        // every subagent transcript hangs off it (see agentCtxTokens).
        let parentTranscript = (try? String(contentsOfFile: "\(dataDir)/tp-\(tty)",
                                            encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = d["id"] as? String, !id.isEmpty else { return nil }
            guard (d["end"] as? NSNumber)?.doubleValue ?? 0 <= 0 else { return nil }
            let tail = agentTail(parentTranscript: parentTranscript, agentId: id)
            guard !tail.finished else { return nil }
            var a = AgentInfo(id: id,
                              type: d["type"] as? String ?? "",
                              desc: d["desc"] as? String ?? "",
                              start: (d["start"] as? NSNumber)?.doubleValue ?? 0)
            a.model = d["model"] as? String ?? ""
            a.ctxTokens = tail.ctx
            a.ctxLimit = ctxLimit
            a.step = (try? String(contentsOfFile: "\(dataDir)/agent-step-\(tty)-\(id)",
                                  encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return a
        }
    }

    // One background subagent's OWN context occupancy. A subagent doesn't share the
    // session's window and has no ctx-<tty> of its own — but it does get its own
    // transcript, written beside the session's:
    //
    //   ~/.claude/projects/<proj>/<session-id>/subagents/agent-<agentId>.jsonl
    //
    // and that agentId is exactly the one the hook ledgers into agents-<tty>, so a
    // roster entry keys straight into the path. The parent transcript pointer the hook
    // stamps on every event (tp-<tty>) gives the stem. Occupancy is then read the same
    // way the hook reads the session's own: the last assistant message's input side.
    //
    // Live, not just at completion: the file grows as the agent works, so a running
    // node's % climbs with it. 0 when the pointer, the file or a usable reading is
    // missing — the node then shows no % instead of a fabricated 0%.
    private func agentTail(parentTranscript: String, agentId: String) -> (ctx: Int, finished: Bool) {
        guard !parentTranscript.isEmpty, !agentId.isEmpty else { return (0, false) }
        let stem = (parentTranscript as NSString).deletingPathExtension
        // resolvingSymlinksInPath, because these files often ARE symlinks (a resumed or
        // forked session's subagents dir links back to the original session's). Attribute
        // reads don't follow a link, so the size/mtime would be the LINK's — frozen
        // forever — and the cache below would then never re-read a growing transcript:
        // whatever the first poll saw (typically "still running") would stick for good.
        let path = ("\(stem)/subagents/agent-\(agentId).jsonl" as NSString)
            .resolvingSymlinksInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return (0, false) }
        // Same bargain as liveModelCache: a busy turn fires many FSEvent refreshes, and
        // each would otherwise re-scan every agent's tail. Returned agents never change
        // again, so their entry is a permanent hit. Ids accumulate over a long uptime
        // (the roster prunes, the cache wouldn't) — drop the lot past a sane bound
        // rather than track liveness; the next poll simply re-reads the live few.
        let stamp = "\(size)|\(mtime)"
        if let hit = agentCtxCache[agentId], hit.stamp == stamp { return (hit.ctx, hit.finished) }
        if agentCtxCache.count > 512 { agentCtxCache.removeAll(keepingCapacity: true) }
        // An agent gets its own file, so nothing in it is a sidechain to skip, and its
        // model chip comes from the ledger — only the token side and the stop reason of
        // the newest assistant message are wanted.
        let info = Self.lastAssistantInfo(inTranscript: path, size: size, skipSidechain: false)
        let ctx = info?.ctxTokens ?? 0
        // "The agent is done" — its last message ended the turn instead of calling
        // another tool. This is the ONLY signal that arrives the moment it happens: the
        // hook can't retire the roster entry until the wake-up reaches a UserPromptSubmit,
        // which on an idle session is whenever the user next types (so a finished agent
        // used to sit in the list indefinitely). A missing/unreadable reason means "keep
        // showing it" — never guess a live agent away.
        let finished = (info?.stopReason.map { $0 != "tool_use" }) ?? false
        agentCtxCache[agentId] = (stamp, ctx, finished)
        return (ctx, finished)
    }

    // The newest assistant message in a transcript's tail, as (model, context occupancy).
    // Context = that message's whole input side (fresh input + everything replayed from
    // cache), which is what actually fills the window — the same definition the hook
    // writes to ctx-<tty> at Stop, except this one is readable mid-turn.
    //
    // Tail-only: whole files are megabytes, and one message can run tens of KB because a
    // usage block is fat. A truncated oldest line simply fails to parse and is skipped.
    //
    // `skipSidechain` is for the MAIN transcript, where a subagent's turns can also be
    // logged (flagged isSidechain): they must not relabel the parent's model, nor lend it
    // their context size. The hook's own ctx-<tty> pass does NOT filter these, so this
    // reading is the more accurate of the two.
    private static func lastAssistantInfo(
        inTranscript path: String, size: UInt64, skipSidechain: Bool) -> LiveInfo? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let window: UInt64 = 256 * 1024
        if size > window { try? fh.seek(toOffset: size - window) }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            // Cheap reject first: only assistant messages carry usage, and parsing every
            // line of the window as JSON to find that out would be the expensive way.
            guard line.contains("\"usage\":") else { continue }
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any],
                  d["type"] as? String == "assistant",
                  let msg = d["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { continue }
            if skipSidechain, d["isSidechain"] as? Bool == true { continue }
            // Only a real "claude-…" id is a model; local/non-API turns log "<synthetic>".
            let id = msg["model"] as? String
            let model = (id?.hasPrefix("claude-") ?? false) ? id : nil
            let ctx = (u["input_tokens"] as? Int ?? 0)
                + (u["cache_read_input_tokens"] as? Int ?? 0)
                + (u["cache_creation_input_tokens"] as? Int ?? 0)
            if ctx > 0 {
                return LiveInfo(model: model, ctxTokens: ctx,
                                stopReason: msg["stop_reason"] as? String)
            }
        }
        return nil
    }

    // Fire a toast on the transitions that matter, keyed on the per-session status
    // change (prev → new):
    //   * → needs           红  sticky banner — the one you must not miss.
    //   needs → done/other  绿  you answered: resolve() morphs the red banner green
    //                           with a ✓ (L("已确认", "Confirmed")) in place, then fades — instant,
    //                           visible acknowledgement instead of it blinking out.
    //   working/idle → done 绿  a turn wrapped up on its own → L("完成", "Done") banner,
    //                           auto-dismissing after its lifetime.
    // A done that materializes on a freshly-discovered session (prev == nil) stays
    // silent: it's not a completion we watched happen, so toasting it would be noise.
    // A done that concludes a permission you JUST answered (needs → working → done)
    // is also silent: the green ✓ resolve already acknowledged it — a second banner
    // is the "shows once more" duplicate.
    private func notifyTransitions(_ newRows: [SessionRow]) {
        var answered = false
        if primed {
            for row in newRows {
                let prev = lastStatus[row.id]
                guard prev != row.status else { continue }   // no change → nothing to announce
                // A session starting a turn is the "you're working" signal the break
                // clock restarts on after a rest (BreakReminder.noteActivity).
                if row.status == "working", prev != nil { BreakReminder.shared.noteActivity() }
                // A prompt just got answered (needs → running/done) or an interrupted
                // session resumed (paused → running: you typed its next prompt). Either
                // way you're DONE with this one — if more await, jump to the next after
                // this pass. Without the paused arm, resuming a paused session the idle
                // jump carried you to left you stranded until a fresh idle spell ran
                // the full threshold again (the "等了好一会才跳下一个" bug).
                if prev == "needs" || prev == "paused",
                   row.status == "working" || row.status == "done" || row.status == "await" {
                    answered = true
                }
                // The highlight ring exists to point at a needs/paused session; the
                // moment that reason is gone — you answered the confirm, or typed after
                // an interrupt (paused → working) — drop the breathing ring on that
                // terminal at once. needs → paused (a rejection) is excluded: flashPaused
                // draws a fresh interrupt ring there instead of leaving it empty.
                if (prev == "needs" || prev == "paused"), row.status != "needs", row.status != "paused" {
                    TerminalFocusRing.shared.dismissIfTarget(row.shellPid)
                }
                switch row.status {
                case "needs":
                    resolvedNeeds.remove(row.id)             // a fresh prompt, not yet answered
                    logNotified(row)
                    ToastManager.shared.show(title: row.projectName, subtitle: row.display,
                                             icon: row.badgeMode, status: "needs", path: row.id) { [weak self] in
                        self?.focus(row)
                        self?.enterChecking(row)             // clicking = looking → eye on row + toast
                    }
                case "paused":
                    // Interrupted, NOT completed — a rejected permission (No/Esc) or a
                    // Ctrl+C on a running turn. Neither answers the prompt, so DON'T morph
                    // the red banner green (that's the default branch's needs→resolve, which
                    // reads as 完成). Drop the now-stale needs banner outright (forceDismiss =
                    // no ✓) and flash a fuchsia ring on its terminal if you're still there.
                    resolvedNeeds.remove(row.id)
                    if prev == "needs" { ToastManager.shared.forceDismiss(row.id) }
                    // A frozen row is not a fresh interrupt — no ring. It also points at
                    // a terminal that may have been reused since, so the ring could land
                    // on an unrelated pane (the misdirected-ring hazard, see FocusRing).
                    if !row.isFrozen { flashPaused(row) }
                case "done":
                    if prev == "needs" {
                        ToastManager.shared.resolve(row.id)  // answered → green ✓ in place
                    } else if prev == "await" {
                        // 等待 → 完成 is not a fresh completion: the state file still holds
                        // the SAME done a Stop wrote before the wait began — all that
                        // changed is the last background agent/shell going away. The
                        // session then wakes itself (that is what the wake-up is for), so
                        // announcing here fires a banner moments before the row turns
                        // 运行中 again, plus a second one when that turn really ends. A
                        // genuine completion always passes through working first, and that
                        // transition still rings. Spend this run's silence credit either
                        // way, so the real done afterwards is free to announce.
                        resolvedNeeds.remove(row.id)
                    } else if resolvedNeeds.remove(row.id) == nil, prev != nil {
                        // Not the tail of an answered permission, and a completion we
                        // actually watched happen → a real L("完成", "Done") banner.
                        logNotified(row)
                        ToastManager.shared.show(title: row.projectName, subtitle: row.display,
                                                 icon: row.badgeMode, status: "done", path: row.id) { [weak self] in
                            self?.focus(row)
                        }
                    }
                default:
                    // Leaving "needs" (answered) → morph any red banner green + ✓, and
                    // remember this run so its upcoming done stays silent. Any other
                    // transition (a run ending without a done) drops that flag.
                    if prev == "needs" {
                        ToastManager.shared.resolve(row.id)
                        resolvedNeeds.insert(row.id)
                    } else if row.status != "working" {
                        resolvedNeeds.remove(row.id)
                    }
                }
            }
        }
        // Sweep orphaned toasts: a session that ended (or changed identity) while
        // "needs" left no row above to clear it, so clear it by absence here — newRows
        // is the full live set, so any toast whose path isn't in it is dead work.
        let live = Set(newRows.map { $0.id })
        ToastManager.shared.retain(live: live)
        resolvedNeeds.formIntersection(live)   // drop vanished sessions
        // Defensive merge: ids are unique by shellPid, but never let a stray
        // collision trap the whole app.
        lastStatus = Dictionary(newRows.map { ($0.id, $0.status) }, uniquingKeysWith: { _, new in new })
        primed = true

        if answered { autoJumpToNextNeeds(newRows) }
    }

    // ★ 「手头这个红还没处理完，别把我拽去下一个红」(T182, 改两条自动路径前必读)
    // The session the user is currently PARKED IN while it still awaits them. Both
    // AUTOMATIC jump paths refuse to move anywhere while this is set: a second prompt
    // popping up elsewhere must not yank you off the one you're mid-way through
    // answering. It simply waits — the pass right after this latch clears picks it up.
    // The manual hotkey is untouched (pressing it IS asking to be taken elsewhere).
    private var parkedAttentionId: String?

    // How recently the user must have typed for "the parked session left needs" to read
    // as "they answered it" rather than the 红→蓝→红 flicker a stopped prompt produces
    // all by itself on its idle-ping hooks (docs/session-status.md 「命令外壳探测」).
    // Answering is always a keystroke, the flicker never is — that's the whole
    // discriminator, and it needs no grace period on top: FSEvents turns the answer's
    // state write into a refresh within a fraction of a second.
    private let parkedReleaseInputWindow: Double = 3

    // Seconds since the last mouse/keyboard event. kCGAnyInputEventType == 0xFFFFFFFF,
    // which is the valid `.tapDisabledByUserInput` case, so the init never nils.
    private func secondsSinceLastInput() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: anyInput)
    }

    // Maintain `parkedAttentionId`. Runs once per refresh, BEFORE notifyTransitions
    // (whose answered-chain reads the latch) and before maybeIdleAutoJump.
    //
    // Latched while the user stands in a session that awaits them. Released when either
    // (a) they moved elsewhere — there's nothing left to protect, or (b) that session
    // left needs/paused AND they typed within parkedReleaseInputWindow, i.e. they
    // really answered it, so the backlog may now carry them onward. A session dropping
    // out of the pool with NO input behind it is merely flickering and keeps the latch:
    // that's what stops the flicker from re-opening the door every few seconds.
    private func updateParkedAttention(_ rows: [SessionRow]) {
        if let id = parkedAttentionId {
            guard let row = rows.first(where: { $0.id == id }),
                  frontmostIsSession(row) else {
                parkedAttentionId = nil          // walked away, or the session vanished
                return
            }
            let awaits = row.awaitsYou
            if !awaits && secondsSinceLastInput() < parkedReleaseInputWindow {
                parkedAttentionId = nil          // answered by hand → the chain may move
            }
            return
        }
        // Cheap test first: only needs/paused rows are candidates, and
        // frontmostIsSession reads the focus token off disk, so let status short-circuit it.
        parkedAttentionId = rows.first {
            $0.awaitsYou && frontmostIsSession($0)
        }?.id
    }

    // You just dealt with one session (answered its prompt, or resumed it from
    // paused) and others still await: jump to the next one so a backlog clears
    // without hunting for each. The target follows the user's jump priority filtered
    // to the buckets they marked 自动 (Settings › 高亮 › 跳转优先级, factory
    // paused+needs = what this used to hardcode); a lower bucket stays unreachable
    // while a higher one has rows. focus() raises its terminal and draws the ring;
    // enterChecking marks a needs target watched (amber eye, no-ops for paused) in
    // this same pass. No-op when nothing else awaits or the user opted out.
    // The TRIGGER (`answered` = needs/paused → working) deliberately stays as it is
    // even when "done" is an eligible target: it means "YOU finished something", and
    // a session completing on its own is not you having done anything.
    private func autoJumpToNextNeeds(_ rows: [SessionRow]) {
        guard AppSettings.autoJumpNextNeeds else { return }
        // ★ Standing in a prompt you haven't answered → nobody gets to move you (T182).
        // The chain fires on ANY row going needs/paused → working, including the one the
        // user is reading flickering on its own hooks, so without this a second red
        // appearing elsewhere pulled them off a prompt mid-answer.
        guard parkedAttentionId == nil else { logParkedBlock(rows); return }
        let next = AppSettings.jumpAutoPriority
            .lazy
            .compactMap { status in rows.first { $0.status == status } }
            .first
        guard let next = next else { return }
        // ★ Already parked in that very session → stay put (改这里前必读). The chain
        // fires on `answered` = a row going needs/paused → working, and a session
        // STOPPED ON ITS PROMPT produces that transition all by itself, over and over:
        // it keeps receiving idle-ping hooks whose short-lived shell trips the busy
        // probe's timestamp guard, so it flickers 红→蓝→红 every few seconds (see
        // docs/session-status.md "命令外壳探测"). Each flicker re-entered this chain,
        // picked the first still-red row — typically the very terminal the user was
        // sitting in, working the prompt — and re-focused + re-ringed it. Nothing moved
        // (the raise and term.show are no-ops), but the breathing ring restarted on a
        // loop and the terminal tab kept getting re-revealed. Jumping to where you
        // already are was never the point of "答完一个跳下一个", so gate it out; a real
        // backlog elsewhere is unaffected, and the next flicker with a genuinely other
        // target still carries you there.
        guard !frontmostIsSession(next) else { return }
        // Landing on a "done" ends the burst: nothing is owed on a finished session, so
        // maybeAutoReturn (which only counts needs/paused) would find the queue empty on
        // the very next refresh and yank you off the page you were just carried to.
        // Keep jumpOrigin — the hotkey can still walk you home on demand.
        if next.status == "done" { pendingAutoReturn = false }
        // Labelled so the diag file separates "the hotkey took me here" from "the app
        // took me here on its own" — T24 is reported against the hotkey specifically.
        jumpDiag("answered-chain → target \(next.display) status=\(next.status) shellPid=\(next.shellPid)")
        focus(next, via: .jumpAutoChain)
        enterChecking(next)
    }

    // Latch for the idle auto-jump: every session already surfaced during the current
    // idle spell. A SET, not a single id — with one id, whichever session sorts FIRST
    // among the pending ones pins the latch, and a prompt that pops up LATER in the
    // same idle spell never gets jumped to: you'd have to touch the machine (clearing
    // the latch) and then idle out the full threshold all over again before it
    // surfaced. That's the "I was already idle, why do I have to wait another 15s"
    // bug. Cleared wholesale the moment input resumes; individual ids drop out as soon
    // as their session stops needing you, so needs → answered → needs surfaces twice.
    private var idleJumpedIds: Set<String> = []

    // "没有动作 + 有需要选择就弹出来": once you've been idle (no mouse/keyboard) for
    // the configured threshold and a session is waiting on you (needs/paused), jump
    // straight to its terminal so the prompt is in front of you when you look back.
    // Driven off the same refresh as everything else — and a new "needs" writes its
    // state file, which the FSEvents watcher turns into an immediate refresh — so a
    // prompt arriving while you're ALREADY idle is surfaced right away, with no second
    // threshold wait. Deliberately quiet while a panel is up (you're already looking)
    // and no-ops unless enabled.
    static let breakToastPath = "!break"

    // Advance the break clock (BreakReminder) once per poll and, when it crosses 0,
    // put up the sticky "rest" banner with the done chime (clicking it opens the
    // window on the strip). Demo mode is skipped with the rest of the automation.
    private func maybeRemindBreak(_ rows: [SessionRow]) {
        let running = rows.contains { $0.status == "working" }
        // A prompt awaiting you counts as busy too: you can't step out mid-confirmation,
        // and the red "needs" banner must not have a tomato stacked on top of it.
        let busy = rows.contains { $0.status == "working" || $0.status == "needs" }
        let event = BreakReminder.shared.poll(idle: secondsSinceLastInput(), running: running, busy: busy)
        // Backstop for restStarted: a rest that began mid-poll, or an idle that ended
        // the round, must not leave "该休息了" up.
        let phase = BreakReminder.shared.phase
        if phase != .working && phase != .overtime { ToastManager.shared.dismiss(Self.breakToastPath) }
        guard case .overtime(let sec)? = event else { return }
        ToastManager.shared.show(
            title: L("该休息了", "Time for a break"),
            subtitle: L("已连续工作 \(BreakReminder.fmt(sec)) · 出去走走，伸伸懒腰",
                        "At it for \(BreakReminder.fmt(sec)) · step out, stretch a little"),
            icon: .custom("🍅"), status: "rest", path: Self.breakToastPath) { [weak self] in
            self?.showMainWindow(tab: .sessions)
            self?.mainWindowController?.showBreakPanel()
        }
        let name = AppSettings.doneSound
        if name != AppSettings.soundOff, let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = Float(AppSettings.soundVolume)
            sound.play()
        }
    }

    private func maybeIdleAutoJump(_ rows: [SessionRow]) {
        guard AppSettings.idleAutoJump else {
            idleJumpedIds.removeAll(); pendingAutoReturn = false; return
        }
        // ★ Standing in a prompt you haven't answered → stay there (T182). Being idle
        // ON a red is "reading it", not "away from the machine": a newer red elsewhere
        // must not steal the screen out from under the one being worked. The latch
        // survives that session's 红→蓝→红 flicker, which would otherwise make the new
        // red the only pool member and carry the user off after all.
        guard parkedAttentionId == nil else { logParkedBlock(rows); return }
        let idle = secondsSinceLastInput()
        let threshold = Double(AppSettings.idleAutoJumpSeconds)
        // The pool follows the user's jump priority (Settings › 高亮 › 跳转优先级),
        // narrowed to the buckets whose 自动 pill is on. Out of the box that is
        // paused+needs — "done" doesn't warrant yanking an idle user anywhere unless
        // they asked for it, and when they do it's honored wherever it sits in the
        // order. Strict bucketing,
        // exactly like the hotkey (jumpToNextAttention): the highest-priority
        // non-empty bucket IS the pool, and a lower bucket is unreachable while any
        // higher one has rows. A flat paused+needs concatenation walked wrong: with
        // the user parked on their own just-paused terminal, jump #1 was an invisible
        // no-op (already there) that latched it, and the NEXT poll dropped to a
        // "needs" — reading as "idle jump ignores my paused-first order". Pinning the
        // bucket means needs is simply not a target until every paused is resolved.
        // Idle-jump only — the manual hotkey builds its own pool in jumpToNextAttention.
        let pending = AppSettings.jumpAutoPriority
            .lazy
            .map { status in rows.filter { $0.status == status && !$0.isFrozen } }
            .first { !$0.isEmpty } ?? []
        // The latch only has to suppress re-jumping to prompts that are STILL up:
        // drop every id that left the pool (answered/resumed) or vanished with its
        // session.
        idleJumpedIds.formIntersection(pending.map { $0.id })
        // First still-pending session, in pool order, that this idle spell hasn't
        // surfaced yet. Answering/resuming one drops it out of the pool, and a fresh
        // one landing mid-spell is simply not in the latch — either way the next poll
        // picks it up, so a backlog clears itself without any further idle wait.
        let target = pending.first(where: { !idleJumpedIds.contains($0.id) })
        if ProcessInfo.processInfo.environment["TB_DEBUG"] != nil {
            NSLog("TB idleJump idle=%.1f thr=%.0f target=%@ latched=%d",
                  idle, threshold, target?.id ?? "nil", idleJumpedIds.count)
        }
        // Idle long enough (the idle gate itself already means you aren't touching
        // any of the app's own UI, so no separate popover/window guard is needed).
        guard idle >= threshold else {
            idleJumpedIds.removeAll()            // active again → re-arm for next spell
            return
        }
        guard let target = target else { return }
        idleJumpedIds.insert(target.id)
        // ★ Already parked in the target → latch it (above) but don't jump. Same reason
        // as the answered-chain guard: a session stopped on its prompt flickers
        // 红→蓝→红 on its idle-ping hooks, and every dip out of the pool drops it from
        // the latch (formIntersection), so the moment it comes back red it reads as a
        // brand-new target and gets "surfaced" again — an endless re-ring of the very
        // terminal the user is reading. This supersedes the earlier "就算我本来就已经在
        // 对的地方了 也显示高亮": ringing in place is only ever a nice-to-have, and it
        // cannot be had without also ringing on every flicker.
        if frontmostIsSession(target) { return }
        // Arm auto-return to the tracked home (where the user was working before this
        // jump) — NOT whatever is frontmost now, which may be our own window. Armed once
        // per burst; repeated idle-jumps in one spell keep the original home rather than a
        // terminal we already bounced through. `pendingAutoReturn` (NOT `jumpOrigin ==
        // nil`) is what marks a burst as live: jumpOrigin is only ever cleared by
        // returnToOrigin, so a manual hotkey jump the user walked back from by hand (never
        // pressing the key a second time) leaves it set forever — gating on it silently
        // disabled the entire return leg from then on ("自动跳转最后没有跳转回一开始的地方").
        // Overwriting that stale origin is also the right call: homeApp is where the user
        // actually is now, which is where the return should land.
        // ★ Never arm on a "done" target: maybeAutoReturn fires the moment no needs/paused
        // is left, which for a done-only pool is already true — you'd be bounced back home
        // ~200ms after landing. A finished session owes you nothing, so there is nothing to
        // come back FROM; leaving means you leaving.
        if target.status == "done" {
            pendingAutoReturn = false          // see above; also disarms a burst that ends here
        } else if !pendingAutoReturn, let origin = homeApp ?? captureJumpOrigin() {
            jumpOrigin = origin
            pendingAutoReturn = true
        }
        // A shown popover would bury the jump target — close it first (as the
        // next-attention hotkey does) so focus lands on the terminal cleanly.
        if popover.isShown { popover.performClose(nil) }
        // The target is somewhere else than where the user is parked (the guard above
        // saw to that), so this is a real move: raise its window's Space, reveal the
        // pane, ring it. The extension reports the landing directly on term.show (see
        // focusByPid), which is what satisfies the ring's token check.
        jumpDiag("idle-auto → target \(target.display) status=\(target.status) shellPid=\(target.shellPid)")
        focus(target, via: .jumpAutoIdle)
        enterChecking(target)
    }

    // The return leg of an idle auto-jump: once you've dealt with the prompt it carried
    // you to, bring you back to where you were reading — no manual hop. Fires the instant
    // no session still needs you: answering a "needs" flips it to "working", and "done"
    // deliberately doesn't hold you (the chosen "答完当前待办即回" trigger). "paused"
    // counts as fresh attention, so an interrupt keeps you put rather than yanking you
    // home. Only ever armed by maybeIdleAutoJump, so the manual hotkey is untouched.
    // ★ This judgement is hardcoded needs/paused and deliberately does NOT follow
    // jumpAutoStatuses: it answers "is anything still owed you", and a "done" owes
    // nothing — it's a notice, not a task. It's also a state with no natural exit (only
    // typing in that terminal leaves it), so counting it here would mean one green
    // session parks you away from home forever. The two paths that CAN now land you on a
    // done disarm the burst instead (see maybeIdleAutoJump / autoJumpToNextNeeds).
    private func maybeAutoReturn(_ rows: [SessionRow]) {
        guard pendingAutoReturn, jumpOrigin != nil else { return }
        let attentionLeft = rows.contains { $0.awaitsYou }
        guard !attentionLeft else { return }
        pendingAutoReturn = false
        returnToOrigin()
    }

    // A session just went "paused" (interrupted). Flash a fuchsia ring on its terminal
    // so you see WHERE it stalled — but only if you're still parked there (you just
    // pressed No/Ctrl+C in it). flashInterrupted's lenient-token + live-xterm check
    // draws nothing once focus has moved on, so it never rings a terminal you left.
    // Never jumps: an interrupt shouldn't yank you anywhere, just annotate in place.
    private func flashPaused(_ row: SessionRow) {
        // ★ `editor` must be non-nil, not merely "some host we guessed at": this fires
        // with NO user click, so an unsupported host that used to fall back to .vscode
        // painted an unprompted magenta ring on a random VS Code pane — the most visible
        // half of the "奇怪的地方突然显示高亮" report.
        guard AppSettings.highlightsEnabled, row.shellPid > 0,
              let editor = row.editor,
              let vs = NSRunningApplication.runningApplications(
                  withBundleIdentifier: editor.rawValue).first else { return }
        TerminalFocusRing.shared.flashInterrupted(
            vscodePid: vs.processIdentifier, shellPid: row.shellPid,
            editorBundleId: editor.rawValue, project: row.folder, task: row.taskTitle,
            icon: row.badgeMode)
    }

    // MARK: Rendering

    /// Push the current counts into the menu-bar pill.
    ///
    /// ★ Runs on every poll, and must WRITE NOTHING unless the numbers actually moved:
    /// every property write on an NSStatusBarButton registers a KVO dependency pair
    /// inside AppKit that is never released (measurements in MenuCapsule.swift). The
    /// pill used to be redrawn at 10 Hz and leaked about a gigabyte a day.
    private func updateButton() {
        let needs   = rows.filter { $0.status == "needs"   }.count
        let working = rows.filter { $0.status == "working" }.count
        let paused  = rows.filter { $0.status == "paused"  }.count
        let done    = rows.filter { $0.status == "done"    }.count
        let waiting = rows.filter { $0.status == "await"   }.count
        let idle    = rows.count - needs - working - paused - done - waiting

        var segs: [MenuSeg] = []
        func seg(_ n: Int, _ status: String, pulse: Bool = false) {
            guard n > 0 else { return }
            segs.append(MenuSeg(count: n, status: status, drawNum: true, pulse: pulse))
        }
        seg(needs, "needs")
        seg(working, "working", pulse: true)
        seg(paused, "paused")                        // fuchsia — interrupted, waiting on you
        seg(waiting, "await")                        // teal — a background command still runs
        seg(done, "done")
        // idle count only surfaces when nothing else is active — a quiet "N sessions,
        // all idle" instead of a bare dot. Active buckets take the whole capsule otherwise.
        if segs.isEmpty { seg(idle, "idle") }
        // no sessions at all → a single bare gray dot, no figure.
        if segs.isEmpty {
            segs.append(MenuSeg(count: 0, status: "idle", drawNum: false, pulse: false))
        }

        guard let button = statusItem.button else { return }
        let view = capsule ?? installCapsule(in: button)
        guard view.apply(segs) else { return }       // same counts → not one write

        // Sizing still goes through an EMPTY image of the capsule's size rather than
        // statusItem.length: it keeps AppKit's own side padding, so the pill sits
        // exactly where the image renderer used to put it. Written only when the width
        // changes — a width write is the most expensive of the leaks (+160 objects).
        let w = view.width(for: segs)
        guard abs(w - capsuleWidth) > 0.5 else { return }
        capsuleWidth = w
        button.image = NSImage(size: NSSize(width: w, height: 18))
    }

    /// Put the pill inside the status button. Once, at first render.
    private func installCapsule(in button: NSStatusBarButton) -> MenuCapsuleView {
        let view = MenuCapsuleView()
        view.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""                            // drop the "…" placeholder
        button.imagePosition = .imageOnly
        button.addSubview(view)
        // Pinned to the button, which is wider than the capsule (AppKit pads a status
        // item); the view centers its own drawing inside that.
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        capsule = view
        return view
    }

    // MARK: Popover (menu-bar dropdown)

    // Route a fired global hotkey to its action.
    private func fireHotKey(_ action: HotKeyAction) {
        switch action {
        case .open:          togglePopover()          // pop the list (press again to dismiss)
        case .nextAttention: jumpToNextAttention()
        }
    }

    // Jump straight to the next session awaiting you: cycle through "needs" (红,
    // awaiting confirmation), then "paused", then "done" rows. If none match, do
    // nothing. `lastJumpedId` advances the cycle so repeated presses walk the whole
    // set instead of re-focusing the first.
    private func jumpToNextAttention() {
        // Strict priority, not a flat cycle: always work the highest-priority
        // non-empty bucket, in the user-configured order (Settings › 跳转优先级,
        // default [needs, paused, done]). Repeated presses cycle WITHIN that bucket;
        // only when it fully empties (all reds answered) does the hotkey drop to the
        // next bucket. A flat needs+paused+done pool let a lingering lastJumpedId
        // that landed on a green keep walking greens while a red still waited (the
        // "jumps to green first" bug) — priority bucketing makes that impossible:
        // any higher-priority status present pins the pool to it.
        let pool = AppSettings.jumpPriority
            .lazy
            .map { status in self.rows.filter {
                $0.status == status && !$0.isFrozen
                    && (!Demo.enabled || Demo.stagedWindow(for: $0) != nil || Demo.hasPane($0))
            } }
            .first { !$0.isEmpty } ?? []
        // Demo: return-to-origin would raise a real window on an empty pool.
        if Demo.enabled && pool.isEmpty { return }
        // Diagnostic (T24 "jumps to a running terminal"): pool is strict-bucketed and
        // can never contain a working row, so a landing on a running terminal is either
        // returnToOrigin (pool empty, home was running), a wrong-pane landing in a shared
        // VSCode window (verify give-up log), or stale rows. Log the press so the next
        // repro is diagnosable from `log show … "TB jump"`.
        let frontInPool = frontmostIsInPool(pool)
        jumpDiag("hotkey pool=[\(pool.map { "\($0.display)/\($0.status)/sh\($0.shellPid)" }.joined(separator: " "))]"
                 + " lastJumped=\(lastJumpedId ?? "-") frontInPool=\(frontInPool ? 1 : 0)")
        // Nothing needs attention → the press means "take me back to where I started
        // the burst" (the requested return-to-origin). No origin recorded → no-op.
        guard !pool.isEmpty else { jumpDiag("pool EMPTY → returnToOrigin"); returnToOrigin(); return }
        // Record home BEFORE anything shifts focus. Refresh it whenever the press
        // starts from a spot that ISN'T one of the attention items — that's the
        // user's real work location. Pressing again while sitting on an attention
        // target (mid-burst) keeps the original home, so the final return lands
        // where the burst began, not on the last item handled.
        // ...unless an idle-jump burst already owns the origin (the doc you were
        // reading): keep that home through manual hotkey presses so the eventual
        // auto-return lands back on the doc, not on a terminal you passed through.
        if !frontInPool && !pendingAutoReturn { jumpOrigin = captureJumpOrigin() }
        // The menu-bar popover would otherwise stay up covering the jump target —
        // it steals no focus but visually buries the terminal we're jumping to. Get
        // it out of the way so the hotkey lands on the terminal (+ FocusRing) cleanly.
        if popover.isShown { popover.performClose(nil) }
        let idx: Int
        if let last = lastJumpedId, let i = pool.firstIndex(where: { $0.id == last }) {
            idx = (i + 1) % pool.count        // advance from where we last landed
        } else {
            idx = 0
        }
        lastJumpedId = pool[idx].id
        jumpDiag("hotkey → target \(pool[idx].display) status=\(pool[idx].status)"
                 + " shellPid=\(pool[idx].shellPid) (idx \(idx)/\(pool.count))")
        focus(pool[idx], via: .jumpHotkey)
    }

    // True when the frontmost window is itself one of the sessions awaiting attention —
    // i.e. the user is mid-burst, standing on an item they just handled. In that case
    // the recorded origin must be preserved, not overwritten with the attention spot.
    private func frontmostIsInPool(_ pool: [SessionRow]) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if let bid = app.bundleIdentifier, EditorApp(rawValue: bid) != nil {
            // Any VSCode-family editor (VSCode / Cursor / Windsurf) — the active-terminal
            // token names the focused terminal's shellPid regardless of which one.
            guard let head = readFocusToken().split(separator: ":").first,
                  let p = pid_t(head) else { return false }
            return pool.contains { $0.shellPid == p }
        }
        if app.bundleIdentifier == "com.anthropic.claudefordesktop" {
            return pool.contains { $0.isDesktop }
        }
        return false   // a browser/native terminal/etc. is home, not an attention item
    }

    // True when `row` is the session the user is ALREADY parked in: its editor is
    // frontmost AND the extension's active-terminal token names its shell (for the
    // desktop row, Claude for Desktop being frontmost is the whole test). Both
    // AUTOMATIC jump paths gate on it — a jump onto the spot you're already standing
    // on carries you nowhere, it just re-rings the terminal you're reading (see the
    // callers for the loop this breaks). The manual hotkey is untouched: pressing it
    // while parked on a target is a deliberate "show me again".
    // Native-terminal rows report false (no companion extension announces focus), the
    // same blind spot frontmostIsInPool has.
    private func frontmostIsSession(_ row: SessionRow) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if row.isDesktop {
            // Not just "Claude is frontmost": with chat and Design open you can be
            // parked in one while the other needs you, and treating them as the same
            // spot would suppress the auto-jump between them.
            guard app.bundleIdentifier == "com.anthropic.claudefordesktop" else { return false }
            guard row.desktopWid != 0 else { return true }
            // The probe's cached focused window, NOT a live AX query: this runs on the
            // main thread and a synchronous round trip to a busy Electron app would
            // stall the UI for the messaging timeout. Up to ~2s stale is fine for a
            // "are you already standing here" gate.
            desktopAXLock.lock()
            let focused = desktopFocusedWid
            desktopAXLock.unlock()
            return focused == row.desktopWid
        }
        // Native terminals and unsupported hosts have no focus token to consult, so we
        // can't tell whether you're standing in them — report "not here", which is the
        // conservative answer (it never suppresses a jump that should happen; jumps to an
        // unsupported host are refused by focus() itself).
        guard let editor = row.editor, app.bundleIdentifier == editor.rawValue,
              let head = readFocusToken().split(separator: ":").first,
              let p = pid_t(head) else { return false }
        return p == row.shellPid
    }

    // Snapshot the frontmost app's focused window as the burst's "home". Returns nil
    // when there's nothing usable to raise later. If home is a VSCode terminal we
    // track, remember its shellPid so the return reuses the full pane-focus jump.
    private func captureJumpOrigin() -> JumpOrigin? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return originSnapshot(of: app)
    }

    // Snapshot a given app's focused window as a returnable "home". nil when there's
    // nothing usable to raise later (no focused window and not a tracked terminal). If
    // it's a VSCode-family terminal we track, remember its shellPid so the return reuses
    // the full pane-focus jump.
    private func originSnapshot(of app: NSRunningApplication) -> JumpOrigin? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let window: AXUIElement?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            window = (w as! AXUIElement)
        } else {
            window = nil
        }
        var wid: CGWindowID = 0
        if let w = window { _ = _AXUIElementGetWindow(w, &wid) }
        // Electron apps (Notion, VSCode, …) don't expose a focused window via plain AX,
        // so AX gives no wid. Fall back to the frontmost on-screen window this pid owns
        // via CGWindowList — enough for the Space switch on return (activation by pid
        // does the rest). This uses only owner/number/layer, never kCGWindowName, so it
        // needs no Screen Recording permission.
        if wid == 0 { wid = frontWindowID(ofPID: pid) }
        var shellPid: pid_t = 0
        if let bid = app.bundleIdentifier, EditorApp(rawValue: bid) != nil,
           let head = readFocusToken().split(separator: ":").first, let p = pid_t(head),
           rows.contains(where: { $0.shellPid == p }) {
            shellPid = p
        }
        // Usable as long as we can bring it back: a window to raise, a wid to Space-switch
        // to, or a tracked terminal to re-focus. pid alone (no window) still activates.
        guard window != nil || wid != 0 || shellPid > 0 else { return nil }
        return JumpOrigin(pid: pid, wid: wid, window: window, shellPid: shellPid)
    }

    // Frontmost normal (layer-0) on-screen window id owned by `pid`. The on-screen list
    // is front-to-back, so the first match is the frontmost. 0 if the app has none up.
    private func frontWindowID(ofPID pid: pid_t) -> CGWindowID {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return num
        }
        return 0
    }

    // Return to the recorded burst origin and clear it (so the next attention starts a
    // fresh burst). A still-live tracked terminal reuses focus() for an identical jump
    // (space switch + term.show + ring); anything else (browser, native terminal, …)
    // gets a generic space-switch + window raise.
    private func returnToOrigin() {
        guard let origin = jumpOrigin else { jumpDiag("returnToOrigin — no origin recorded (no-op)"); return }
        // Diagnostic (T24): homeStatus=working here means the burst origin was a running
        // terminal, so the return legitimately lands on a running terminal — path A.
        jumpDiag("returnToOrigin pid=\(origin.pid) wid=\(origin.wid) shellPid=\(origin.shellPid)"
                 + " homeStatus=\(rows.first(where: { $0.shellPid == origin.shellPid })?.status ?? "n/a")")
        jumpOrigin = nil
        lastJumpedId = nil
        pendingAutoReturn = false
        if origin.shellPid > 0, let row = rows.first(where: { $0.shellPid == origin.shellPid }) {
            focus(row, via: nil)   // walking home saved you nothing — see focus(_:via:)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        jumpSeq += 1
        // Same combo the desktop jump uses: synchronous CGS space switch so the display
        // follows, then front the specific window via SLPS (cross-app activate() alone
        // won't switch Spaces). kAXRaise orders it within its own app. A wid of 0 means
        // the window id never resolved — still raise + activate, just without the
        // Space/SLPS half rather than giving up on the return entirely.
        if origin.wid != 0 { switchToSpace(of: origin.wid) }
        // Validate before raising, for the same reason raiseEditorWindow does: kAXRaiseAction
        // on a dead element is a SILENT no-op, and this was the one AX reference in the app
        // with no liveness check — the window it names can be closed (or its app quit) any
        // time between capture and return, and the failure reads as "pressed the key, nothing
        // happened" with nothing in the log. Bound the messaging as well: this runs on the
        // main thread, so an origin app that is wedged (Electron right after a wake) would
        // otherwise stall the UI for the process-default timeout on a call we don't even need.
        if let w = origin.window {
            AXUIElementSetMessagingTimeout(w, 0.5)
            var checkWid = CGWindowID(0)
            if _AXUIElementGetWindow(w, &checkWid) == .success, origin.wid == 0 || checkWid == origin.wid {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            } else {
                jumpDiag("returnToOrigin — origin AX element is stale, skipping raise (wid=\(origin.wid) got=\(checkWid))")
            }
        }
        NSRunningApplication(processIdentifier: origin.pid)?.activate(options: [.activateIgnoringOtherApps])
        if origin.wid != 0 { slpsFocusWindow(pid: origin.pid, wid: origin.wid) }
    }

    // User rebound (or cleared) an action's hotkey in Settings. Persist it and
    // re-register the Carbon binding; nil clears it entirely.
    // Persists either way: a combo another app already owns is still what the user
    // asked for, and the status lets Settings say so instead of faking success.
    @discardableResult
    private func rebindHotKey(_ action: HotKeyAction, _ combo: HotKeyCombo?) -> OSStatus {
        HotKeyStore.persist(action, combo)
        return hotKeys.rebind(action, combo: combo)
    }

    // Settings, stats, and recent projects are all tabs of the main window now —
    // open it deep-linked to the requested tab.
    private func openSettings()       { showMainWindow(tab: .settings) }
    private func openStats()          { showMainWindow(tab: .stats) }
    private func openRecentProjects() { showMainWindow(tab: .recent) }

    // Open a project from history: a live session in that dir → the normal jump
    // (switchToSpace + AX raise); otherwise hand the folder to VSCode — `open -b`
    // launches it if needed and opens the folder as a window either way.
    private func openProject(_ path: String) {
        // Demo projects are names, not folders — opening one would launch VSCode on a
        // path that doesn't exist. Same rule as focus(): demo mode shows, it doesn't act.
        if Demo.enabled { return }
        if let row = rows.first(where: { $0.cwd == path }) {
            focus(row, via: nil)   // reopening a project isn't answering a session
            return
        }
        NSLog("TB recent: open %@ in VSCode", path)
        openInEditor("com.microsoft.VSCode", path)
        requestTerminalOpen(path)
    }

    // Ask the companion extension to reveal/create an integrated terminal in the
    // window that owns `path`, so the project opens ready for `claude`. Every
    // window watches open-terminal-request; only the one whose workspace folder
    // matches acts. A freshly opened window's extension host starts AFTER this
    // write, so the extension also checks the file once on activation — `ts`
    // lets it ignore stale requests.
    private func requestTerminalOpen(_ path: String) {
        // Recent-projects "open" defaults to VSCode (see openInVSCode / decision #1),
        // so gate on the VSCode extension to match where the terminal will be revealed.
        guard extensionInstalled(.vscode) else { return }
        let req: [String: Any] = ["path": path, "ts": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return }
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: "\(dataDir)/open-terminal-request"), options: .atomic)
    }

    // One line per popover open/close into ~/.claude/spectix/popover-debug.log.
    // The unreproduced "click the icon and nothing appears" report needs evidence from
    // the moment it happens, and this bundle's NSLog never reaches the unified log
    // (ad-hoc signature), so a file is the only channel that survives to be read later.
    // Self-trimming so it can't grow without bound.
    private static let popoverLogStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func popoverLog(_ line: String) {
        let path = "\(dataDir)/popover-debug.log"
        guard let data = "\(Self.popoverLogStamp.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? data.write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    // A fresh anchor panel for one open. See the popoverAnchor property for why this
    // is never cached.
    private func makePopoverAnchor() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 24, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 1))
        return p
    }

    // Don't try to verify the anchor against CGWindowList — measured 2026-08-12, it
    // cannot answer this question. Our own windows never appear in that list (checked
    // 24x1 and 410x854, clear and opaque, both the by-id lookup and the on-screen
    // sweep: all empty while the windows were provably on screen). Gating the show on
    // it swallowed the panel on every click, and reading it as evidence of a dead
    // window is a false positive — it reads the same when everything is healthy.
    @objc private func togglePopover() {
        // Right-click → drop a one-item quit menu instead of the popover. Attach it
        // transiently and performClick so it tracks like a native status menu, then
        // detach so the next left-click still toggles the popover.
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("退出 SpectiX", "Quit SpectiX"), action: #selector(quit), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popoverLog("toggle → close (was shown)"); popover.performClose(nil); return }
        guard let button = statusItem.button else { popoverLog("toggle ABORTED — no status button"); return }
        refresh()                       // land fresh data before the panel appears
        usage = loadUsage()             // fresh quota for the header (refresh() lands async)
        // 15 instead of 60 when a switch has outdated the snapshot outright: it was
        // measured on the account we just left, so waiting out the normal staleness
        // window would leave a minute of the wrong account's numbers on the card.
        requestUsageProbe(minAge: usageOutdatedBySwitch ? 15 : 60)
        popoverController.prepareForShow()   // scroll to the active session once on this open
        SystemMonitor.shared.sample()   // baseline now, so the CPU row reads on the next poll
        let hdr = headerAgentInfo(rows: rows)
        popoverController.reload(rows, usage: hdr.claudeUsage, header: hdr)
        // Land on the currently-focused terminal's session (not a stale pin from last time),
        // so the popover opens positioned on "the right one". Same runloop as reload → no
        // visible double-scroll. Skipped when the focus isn't a session in this list.
        if let head = readFocusToken().split(separator: ":").first,
           let pid = pid_t(head), rows.contains(where: { $0.shellPid == pid }) {
            popoverController.focusSession(shellPid: pid)
        }
        // The popover anchors to the status-bar button, so by default it inherits the
        // *system* appearance (the menu bar always follows macOS), NOT NSApp.appearance.
        // That's why a forced light/dark override moved the main window but left the
        // popover on the system look. Pin it to NSApp.appearance: nil in .system mode
        // (falls back to the status bar = system), the forced NSAppearance otherwise.
        popover.appearance = NSApp.appearance
        // Anchor to the stationary invisible panel (see popoverAnchor), placed at the
        // button's x on the button's screen so multi-display targeting still follows
        // the menu bar that was clicked. Do NOT NSApp.activate() first — that pulls
        // focus to the main window's screen and the popover follows it there. Instead
        // make just the popover's own window key so it still receives the list's
        // clicks/drags and the click-outside that dismisses it.
        // Show on the screen the POINTER is on (the menu bar the user is looking
        // at), not necessarily the screen the status item physically lives on.
        // Opened by hotkey the pointer decides; opened by click the pointer is
        // already over the button's screen, so both paths stay consistent.
        let mouseLoc = NSEvent.mouseLocation
        let anchorScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) }
            ?? button.window?.screen ?? NSScreen.main
        var anchorFrame = NSRect(x: 0, y: 0, width: 24, height: 1)
        if let screen = anchorScreen {
            var anchorX: CGFloat = screen.frame.maxX - 12
            if let bw = button.window {
                let btnMid = bw.convertToScreen(button.convert(button.bounds, to: nil)).midX
                if let bs = bw.screen, bs !== screen {
                    // Status item lives on another screen — mirror its distance
                    // from the right edge so the popover drops from the SAME spot
                    // on this screen's menu bar (status items sit at the right),
                    // instead of chasing the pointer's x all over the screen.
                    anchorX = screen.frame.maxX - (bs.frame.maxX - btnMid)
                } else {
                    // Status item is on this screen — drop straight under it.
                    anchorX = btnMid
                }
            }
            anchorX = min(max(anchorX, screen.frame.minX + 12), screen.frame.maxX - 12)
            let top = screen.frame.maxY - popoverBand(screen: screen)
            anchorFrame = NSRect(x: anchorX - 12, y: top - 1, width: 24, height: 1)
        }
        // Build a FRESH anchor and raise it. Rebuilding unconditionally is the actual
        // fix — a panel that never survives to the next open can never go stale.
        popoverAnchor?.orderOut(nil)
        let anchor = makePopoverAnchor()
        popoverAnchor = anchor
        anchor.setFrame(anchorFrame, display: false)
        anchor.orderFrontRegardless()
        if let screen = anchorScreen {
            popoverLog(String(format: "open rows=%d screen=%@ anchorX=%.0f band=%.0f anchor=%@ anchorVisible=%d size=%@",
                              rows.count, NSStringFromRect(screen.frame), anchorFrame.midX,
                              popoverBand(screen: screen),
                              NSStringFromRect(anchor.frame), anchor.isVisible ? 1 : 0,
                              NSStringFromSize(popoverController.preferredContentSize)))
        } else {
            popoverLog("open rows=\(rows.count) NO anchorScreen resolved")
        }
        if let av = anchor.contentView {
            popover.show(relativeTo: av.bounds, of: av, preferredEdge: .minY)
        }
        // Self-heal: a show that didn't take is what the "click the icon and nothing
        // appears" report looks like from here. Re-front the anchor and try once more —
        // a no-op on the normal path, where the first show already stuck.
        if !popover.isShown, let av = anchor.contentView {
            popoverLog("show did NOT take → retrying once")
            anchor.orderFrontRegardless()
            popover.show(relativeTo: av.bounds, of: av, preferredEdge: .minY)
        }
        popoverLog(String(format: "after show isShown=%d win=%@ winVisible=%d",
                          popover.isShown ? 1 : 0,
                          NSStringFromRect(popover.contentViewController?.view.window?.frame ?? .zero),
                          (popover.contentViewController?.view.window?.isVisible ?? false) ? 1 : 0))
        // Pin the popover's top edge to an ABSOLUTE y measured from the screen top,
        // independent of whether the menu bar is currently shown or auto-hidden.
        // In a fullscreen Space the menu bar hides and NSPopover otherwise pushes
        // the popover's top past the top of the screen (clipping the first project
        // header). Anchoring to a fixed band below the screen top keeps the whole
        // popover on-screen either way. x stays as the system placed it (aligned
        // under the status button); only y is overridden.
        if let win = popover.contentViewController?.view.window,
           let screen = anchorScreen ?? win.screen {
            // The top strip the popover must clear. Two contributors, take the larger:
            // (1) safeAreaInsets.top = physical notch inset, persists on a built-in even
            // when the menu bar is hidden (notch is hardware; external reports 0);
            // (2) restingMenuBand = the menu bar's off-hover height (0 when auto-hidden).
            // We deliberately DON'T read the live visibleFrame/menuBarVisible() here —
            // at open time the bar is momentarily revealed and would leave a dead gap.
            clampPopoverTop(win: win, screen: screen)
            popoverLog("after clamp win=\(NSStringFromRect(win.frame)) onScreen=\(NSIntersectsRect(win.frame, screen.frame) ? 1 : 0)")
            // Keep clamping while shown: the system re-margins the popover when the
            // bar slides in (a jump far bigger than the bar) and never restores it
            // when the bar slides back out. Cheap — runs only while the popover is up.
            popoverClampTimer?.invalidate()
            // 60Hz so the popover FOLLOWS the bar's ~0.25s slide frame-by-frame
            // instead of snapping after it lands; early-exits when already in place.
            // .common mode keeps it firing during mouse tracking (hover reveals).
            let clamp = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, self.popover.isShown,
                      let w = self.popover.contentViewController?.view.window,
                      let s = w.screen else { return }
                self.clampPopoverTop(win: w, screen: s)
            }
            RunLoop.main.add(clamp, forMode: .common)
            popoverClampTimer = clamp
        }
        popover.contentViewController?.view.window?.makeKey()
        // Global monitor fires only for events delivered to *other* apps — i.e. a click
        // on another window or another screen's menu bar. Clicks inside our own popover
        // go through the local responder chain, not here, so they don't dismiss it.
        popoverClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.popover.performClose(nil) }
        // ↑/↓ move the selection, ⏎ jumps. Consume those keys (return nil) so the
        // table doesn't also scroll; pass everything else through untouched.
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            switch event.keyCode {
            case 126: self.popoverController.selectPrevSession(); return nil   // ↑
            case 125: self.popoverController.selectNextSession(); return nil   // ↓
            case 36, 76: self.popoverController.activateSelectedSession(); return nil  // ⏎ / ⌤
            default: return event
            }
        }
    }

    // MARK: Actions

    // Jump to this session. When the companion extension is installed we also write
    // the target shellPid to the focus-request file that every VSCode window watches;
    // the window owning the terminal whose `processId` == shellPid reveals that exact
    // pane, landing on its input.
    //
    // The OS-level window raise is done by `raiseVSCodeWindow` (Accessibility API),
    // not the extension's `term.show` (which only swaps the pane *inside* its window).
    //
    // `via` is the impact log's single jump instrument: EVERY jump funnels through here,
    // so recording it at the one shared exit is what keeps the four paths from drifting
    // apart as they get edited. Pass nil for moves that aren't you answering a session
    // (returning home, opening a recent project) — crediting those would inflate 省时
    // with trips that saved nothing.
    private func focus(_ clicked: SessionRow, via: ImpactKind? = .jumpManual) {
        // A demo row stands for nothing: there is no pane to reveal and no window to
        // raise, so a click would raise whatever editor happens to be running and land
        // the ring on an unrelated pane. Clicking rows stays harmless instead — unless
        // the row points at a window the demo opened and that window is still it.
        // No impact log / ack: those write real state.
        // A VS Code pane the rig opened on the demo's scratch folder (the row already carries
        // its shell pid, see Demo.panePid): the real editor path below takes it. Never
        // painted: whatever runs in that pane (often a real claude TUI) stays as is.
        let demoPane = Demo.enabled && Demo.hasPane(clicked)
        if Demo.enabled && !demoPane {
            guard let s = Demo.stagedWindow(for: clicked) else { return }
            let row = rows.first(where: { $0.id == clicked.id }) ?? clicked
            // Repainted on every jump too: a resize makes the shell redraw its
            // user@host prompt under the mock.
            let text = Demo.screen(for: row)
            jumpSeq += 1
            demoQueue.async { [weak self] in
                guard let self else { return }
                guard self.stagedWindowIsOurs(s) else {
                    DispatchQueue.main.async { Demo.staged = Demo.staged.filter { $0.value != s } }
                    return
                }
                if let text { Self.writeTty(s.tty, text) }
                // By window id, not focusTerminal's tty match: Terminal's closed-shell
                // windows still report a tty, often the very one the staged window got.
                self.spawnResponsible(["/usr/bin/osascript", "-e", """
                    tell application "Terminal"
                        set index of window id \(s.wid) to 1
                        activate
                    end tell
                    """])
                DispatchQueue.main.async { self.ringNativeTerminal(row, app: .terminal) }
            }
            return
        }
        // Toast/row click closures capture the row AT RENDER TIME; by click time the
        // status may have moved on (needs→done, done→acked…). Re-resolve the live row
        // so the ring color and ack logic reflect NOW, not the stale snapshot (the
        // "ring lights in the old status color" bug).
        let row = rows.first(where: { $0.id == clicked.id }) ?? clicked
        if let via = via, !row.tty.isEmpty { ImpactLog.log(via, tty: row.tty) }
        // Every jump supersedes the previous one: pending term.show/verify work from
        // an earlier click checks this and aborts, so consecutive clicks on different
        // rows never tug-of-war over focus (each verify loop used to keep re-yanking
        // focus back to ITS target for up to ~1.9s).
        jumpSeq += 1
        // ★ Free tier lands on the WINDOW only (ProFeature.preciseJump, 改跳转前必读):
        // the editor or emulator still comes forward, but nothing below asks it to reveal
        // the exact pane / tab / chat input this session lives in — you arrive wherever
        // that window already was. The window-level raise deliberately stays paid-free:
        // from a background app the cached-AX raise is the ONLY thing that follows an
        // off-Space window (see raiseEditorWindow's "why we cache AXUIElement"), so
        // degrading that too would make a click on another Space do nothing visible at
        // all — and "bringing the editor forward" is core function that must stay
        // free. Desktop rows are unaffected: a window has no panes to miss.
        let precise = Pro.enabled(.preciseJump)
        if row.isDesktop {
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return }
            // activate() alone won't bring back a minimized window — the Dock keeps it
            // stashed. Un-minimize every window via AX first, then raise to front.
            deminiaturizeWindows(pid: app.processIdentifier)
            // Cross-Space: raise the window through its CACHED AXUIElement, which takes
            // us TO the Space the window lives on (the editor jump's proven route, see
            // raiseEditorWindow). The old switchToSpace + activate + SLPS trio did the
            // opposite from a background app: setSpace only flips the WindowServer flag
            // without moving the physical display, so activate/SLPS then hauled Claude's
            // window onto the Space we were already on (the "summoned it here instead of
            // going there" bug). Fallback keeps that trio for the cache-miss case (app
            // never probed while its Space was current) — it at least surfaces the app.
            if !raiseDesktopWindow(pid: app.processIdentifier, wid: row.desktopWid) {
                // Fallback targets this row's own window too, so a cache miss still
                // lands on the right one instead of the app's biggest window.
                let dwid = row.desktopWid != 0
                    ? row.desktopWid : desktopWindowID(pid: app.processIdentifier)
                if let dwid = dwid { switchToSpace(of: dwid) }
                app.activate(options: [.activateIgnoringOtherApps])
                // activate() is advisory on macOS 14+ and often won't actually surface
                // the window (the "only the ring shows" bug). Front the specific window
                // via SLPS, same as the VSCode jump path.
                if let dwid = dwid { slpsFocusWindow(pid: app.processIdentifier, wid: dwid) }
            }
            // Glowing ring around the desktop app's window, same as a terminal jump
            // (status-colored), so the desktop row gets the same "here it is" cue.
            TerminalFocusRing.shared.highlightWindow(
                appPid: app.processIdentifier,
                bundleId: "com.anthropic.claudefordesktop", status: row.status,
                // Ring THIS row's window: the raise runs async on jumpQueue, so asking
                // for "the focused window" would often still resolve to the window we
                // just left (chat) and leave the ring on the wrong one.
                windowID: row.desktopWid != 0 ? row.desktopWid : nil,
                project: row.folder, task: row.taskTitle, icon: row.badgeMode,
                // Claude desktop is an app window, not a terminal session — a jump
                // shows only the status ring, never the titlebar caption (the caption
                // is a terminal-only "here it is" head; "Claude App" needs no label).
                captionEligible: false)
            return
        }
        if let term = row.terminalApp {
            focusTerminal(row, app: term, precise: precise)
            // Native terminals have no companion extension, so there's no active-terminal
            // focus report to drive the "seen" ack (that's how VSCode/desktop grey a done
            // row). Here the click IS the focus — we just raised the window — so ack it
            // directly. No-op unless done (needs stays red until actually answered).
            acknowledge(row.id, status: row.status)
            return
        }
        // ★ Unsupported host (Warp, Ghostty, kitty, Hyper, tmux, ssh…): do nothing at all
        // (改这里前必读). This used to fall through with editor defaulted to .vscode, so
        // clicking such a row raised the REAL VS Code, asked its extension to reveal a
        // shellPid it doesn't own, and drew the ring on whatever pane happened to be
        // there. Refusing is the honest answer — we have no window to point at, and a
        // wrong landing is worse than no landing. The row itself stays fully functional
        // as a status readout (see SessionRow.hostSupported).
        guard let editor = row.editor else { return }
        // ★ A chat panel owns no terminal pane. Its shellPid is the editor's extension
        // host, not a shell, so the pane path below would arm the ring for a target that
        // never reports back and ask the extension to reveal a terminal it doesn't have —
        // the same shape of wrong landing the guard above exists to prevent. It gets its
        // own three steps instead: raise the window, ask THAT window's extension host to
        // focus the chat input, and ring the window itself (no pane to ring).
        if row.isChatPanel {
            let wid = raiseEditorWindow(cwd: row.cwd, editor: editor)
            // Same FIFO-marker ordering as the terminal path: raiseEditorWindow enqueued
            // its AX IPC on jumpQueue, so this runs only once the raise completed (or
            // timed out), and +150ms keeps VSCode's activation focus-restore from
            // overriding us. No verify loop — unlike a terminal there's no per-target
            // token to check the landing against (active-terminal only reports terminals).
            //
            // Focusing the chat input is in-window landing, so it is the same paid step
            // the terminal path skips: free tier gets the window and stops there.
            if precise {
                let seq = jumpSeq
                let hostPid = row.shellPid
                jumpQueue.async { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard let self = self, seq == self.jumpSeq else { return }
                        self.requestChatFocus(hostPid: hostPid)
                    }
                }
            }
            // Ring the WINDOW, not a pane — the panel is a webview with no xterm frame to
            // resolve. Aims at the wid the raise picked (the desktop row's reason: the
            // raise is async, so "the focused window" would often still be the one we
            // just left). No caption: it would sit on the window's own title bar, and the
            // ring already answers the only question here — which window.
            if let pid = NSRunningApplication.runningApplications(
                    withBundleIdentifier: editor.rawValue).first?.processIdentifier {
                TerminalFocusRing.shared.highlightWindow(
                    appPid: pid, bundleId: editor.rawValue, status: row.status,
                    windowID: wid, fromJump: true, captionEligible: false)
            }
            acknowledge(row.id, status: row.status)
            return
        }
        // One flag carries the whole downgrade for this path: dropping it skips armJump,
        // the extension's term.show, the landing verification AND the ring's pane target
        // (all four already keyed off it), leaving a plain window raise.
        // ★ Two questions, not one (T229): "is the extension on disk" and "is a live host
        // serving this terminal" diverge for every fresh install until the editor window
        // is reloaded. Targeting the pane on the first answer alone sends a focus-request
        // nobody reads and arms a ring that polls into GIVE UP and draws nothing — the
        // silent "highlights are broken" first run. The second answer is what the pane
        // path actually depends on, so it is what gates it; on-disk-but-not-serving takes
        // the plain window ring and says, on its caption, what to do about it.
        let onDisk = extensionInstalled(editor)
        let serving = onDisk && extensionServing(shellPid: row.shellPid)
        let paneTargeted = precise && row.shellPid > 0 && serving
        let needsReload = precise && row.shellPid > 0 && onDisk && !serving
        if needsReload {
            jumpDiag("extension on disk but no live host lists sh\(row.shellPid) "
                     + "→ window ring + reload hint (\(editor.appSupportName))")
        }
        // Arm the ring's jump target BEFORE the raise: activation makes VSCode
        // re-focus its previously-active terminal, whose active-terminal report
        // would otherwise flash a ring there first (see FocusRing.armJump).
        if paneTargeted { TerminalFocusRing.shared.armJump(target: row.shellPid) }
        // Switch to the window's Space + raise it FIRST (cached-AX raise, see
        // raiseVSCodeWindow), THEN reveal the target terminal. Order matters: the
        // extension's `term.show` brings the window forward on whatever Space the display
        // is CURRENTLY showing (a cross-Space drag if done first). Raising to the window's
        // own Space first means term.show then only selects the pane inside an already-
        // fronted, on-Space window — no drag.
        raiseEditorWindow(cwd: row.cwd, editor: editor)
        if paneTargeted {
            // FIFO marker on the jump queue: raiseVSCodeWindow enqueued its AX IPC
            // there, so this block runs only once the raise has actually completed
            // (or timed out) — the ordering the old blocking raise provided, without
            // freezing the main thread. term.show then goes out raise+150ms; firing
            // it mid-raise would let VSCode's activation focus-restore override it
            // (the "first click lands on the wrong terminal" bug).
            let seq = jumpSeq
            let shellPid = row.shellPid
            jumpQueue.async { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let self = self, seq == self.jumpSeq else { return }
                    self.requestTerminalFocus(shellPid: shellPid)
                    // The raise can still return before VSCode finishes activating
                    // (timeout), and activation restores focus to ITS last-active
                    // terminal, overriding our term.show. Verify the landing via the
                    // extension's active-terminal token and re-send while it names
                    // someone else. Aborts the moment a newer jump takes over.
                    self.verifyTerminalFocus(shellPid: shellPid, seq: seq, attempt: 0)
                }
            }
        }
        // Glowing ring on the target session's pane (FocusRing.swift) — stays until you
        // type, so it survives the eye-travel while you hunt for it. Starts polling
        // IMMEDIATELY: presentation is gated by the extension token + pane-owner check
        // anyway (the ring appears the moment both confirm the target, typically
        // ~250-450ms in), so a fixed head-start delay only added latency. Safe Space-wise:
        // the one-shot ring window uses .canJoinAllSpaces + .stationary, so it stays
        // visible on the destination Space even when created mid-transition (the old
        // 400ms delay predates that fix).
        if let pid = NSRunningApplication.runningApplications(
                withBundleIdentifier: editor.rawValue).first?.processIdentifier {
            TerminalFocusRing.shared.highlight(
                vscodePid: pid, targetShellPid: paneTargeted ? row.shellPid : 0,
                status: row.status, editorBundleId: editor.rawValue,
                fromJump: paneTargeted, project: row.folder,
                // The caption is the one surface that is on screen at the exact moment
                // the user wonders where the pane ring went, so the instruction goes
                // there instead of in an alert they'd have to dismiss mid-jump.
                task: needsReload ? Self.reloadHintCaption : row.taskTitle,
                icon: row.badgeMode)
        }
    }

    // Jump to a native-terminal session: drive the emulator's AppleScript to raise the
    // window/tab owning this session's tty, then ring its focused window (same path the
    // desktop row uses). tty is "ttysNNN"; both emulators' scripting expose the device
    // as "/dev/ttysNNN".
    // ★ osascript runs NON-disclaimed (unlike the /usage probe): Apple Events need an
    // Automation grant, and TCC keys it by the RESPONSIBLE process. Disclaimed, that's
    // the generic /usr/bin/osascript → the prompt reads "osascript wants to control
    // Terminal" and the grant is fragile. Non-disclaimed, SpectiX is responsible →
    // clean one-time "SpectiX wants to control Terminal" that persists. The
    // permission-rain that motivated disclaiming is a claude-probe problem (it touches
    // Downloads/media); osascript only sends an Apple Event, so there's nothing to rain.
    //
    // `precise` false (free tier) keeps the window hunt — the tty is still what tells us
    // WHICH window to front — and drops only the tab/session selection inside it, the
    // exact counterpart of skipping term.show on the editor path.
    private func focusTerminal(_ row: SessionRow, app: TerminalApp, precise: Bool) {
        guard !row.tty.isEmpty else { return }
        let dev = "/dev/\(row.tty)"
        let script: String
        switch app {
        // ★ Multi-window ordering (改这块前必读 — the "点击都跳到同一个 terminal" bug):
        // `activate` must come LAST, only after the target window is selected — and it
        // must be the window-fronting primitive, NOT `set frontmost of w to true`.
        // Empirically (multiple native Terminal windows, each a claude session):
        //   • `activate` up front loses the race — it asynchronously restores Terminal's
        //     LAST-active window AFTER the synchronous `set …` runs, so every jump lands
        //     on whatever was frontmost before, never the target.
        //   • `set frontmost of w to true` is an unreliable no-op when the app isn't
        //     already frontmost — it does not bring the window forward.
        //   • `set index of w to 1` reliably reorders the target to Terminal's front slot;
        //     a trailing `activate` then surfaces exactly that window (and follows it
        //     cross-Space, since a self-activating app tracks its front window's Space).
        case .terminal:
            let selectTab = precise ? "set selected of t to true" : ""
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            \(selectTab)
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case .iterm:
            let selectTab = precise ? "select t" : ""
            let selectSession = precise ? "select s" : ""
            script = """
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                select w
                                \(selectTab)
                                \(selectSession)
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        }
        spawnResponsible(["/usr/bin/osascript", "-e", script])
        ringNativeTerminal(row, app: app)
    }

    // Ring the emulator's focused window (= the tab we just raised). The ring poll
    // retries a few ticks, covering the async gap while osascript brings it front.
    private func ringNativeTerminal(_ row: SessionRow, app: TerminalApp) {
        if let appPid = NSRunningApplication.runningApplications(
                withBundleIdentifier: app.rawValue).first?.processIdentifier {
            TerminalFocusRing.shared.highlightWindow(
                appPid: appPid, bundleId: app.rawValue, status: row.status,
                pad: TerminalFocusRing.termWinPad, project: row.folder, task: row.taskTitle,
                icon: row.badgeMode)
        }
    }

    // posix_spawn a child WITHOUT disclaiming responsibility, so TCC attributes its
    // access to SpectiX (a stable, signed identity) rather than the child binary.
    // Used for osascript Automation, where the Apple Events grant must key to us for a
    // clean one-time prompt. The opposite of spawnDisclaimed — see focusTerminal.
    /// Run one shell command in a new Terminal.app window — the CLI's own sign-in, from
    /// the account panel.
    ///
    /// ★ Apple Events, so this MUST go through spawnResponsible and NOT the disclaimed
    /// path (docs/permissions.md): Automation TCC is keyed on the responsible process,
    /// and disclaiming would make that the generic /usr/bin/osascript — the user then
    /// gets "osascript wants to control Terminal" over and over, because the grant is
    /// attached to a binary every app on the machine shares. Undisclaimed, the prompt
    /// names SpectiX and is granted once.
    ///
    /// ★ Terminal.app specifically, even though most sessions here run in VSCode's
    /// integrated terminal: there is no supported way to run a command in an editor's
    /// integrated terminal from outside the editor. Rather than half-support that, the
    /// panel offers the command verbatim so it can be pasted anywhere.
    func runInTerminal(_ cmd: String) {
        // Two levels of quoting: AppleScript string, then whatever sh sees inside it.
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        // ★ Non-zero here is almost always TCC: the Automation grant for Terminal was
        // declined (or never asked) and osascript dies with -1743 — and nothing else
        // on screen changes. That was reported as "I clicked Add account and nothing
        // happened", so the failure has to be said out loud, with the way out.
        guard spawnResponsible(["/usr/bin/osascript", "-e", script]) != 0 else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("打不开终端", "Couldn't open Terminal")
        a.informativeText = L(
            "SpectiX 没有控制「终端」的权限。去 系统设置 → 隐私与安全性 → 自动化，把 SpectiX 下面的「终端」打开，再点一次。\n\n或者自己在任意终端里跑：\n\(cmd)",
            "SpectiX isn't allowed to control Terminal. Open System Settings → Privacy & Security → Automation, turn on Terminal under SpectiX, then try again.\n\nOr run this in any terminal yourself:\n\(cmd)")
        a.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        a.addButton(withTitle: L("复制命令", "Copy command"))
        a.addButton(withTitle: L("关闭", "Close"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            // LaunchServices, not a spawn (docs/permissions.md) — no prompt, no entitlement.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        default:
            break
        }
    }

    /// Returns the child's exit status; -1 if it couldn't be spawned at all.
    @discardableResult
    private func spawnResponsible(_ argv: [String]) -> Int32 {
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], nil, nil, &cargv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // WIFEXITED / WEXITSTATUS by hand: the macros don't import into Swift.
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    // Like spawnResponsible, but captures stdout — used to ask a native terminal for its
    // focused tab's tty. Non-disclaimed (same TCC reasoning as spawnResponsible) so the
    // Automation grant keys to SpectiX. Blocks on the child, so call it off the main
    // thread. Returns trimmed stdout, or nil on spawn failure.
    private func spawnResponsibleCapturing(_ argv: [String]) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            cargv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, nil, &cargv, environ)
        close(writeFD)   // parent only reads
        guard rc == 0 else { close(readFD); return nil }
        var out = Data()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(readFD, buf, 4096)
            if n <= 0 { break }
            out.append(buf.assumingMemoryBound(to: UInt8.self), count: n)
        }
        close(readFD)
        waitpid(pid, nil, 0)
        return String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The app's main (largest) top-level window id, for switchToSpace. Uses only
    // window number/owner/layer/bounds — none of which need Screen Recording (only
    // window NAMES do), so this works regardless of that permission.
    private func desktopWindowID(pid: pid_t) -> CGWindowID? {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (wid: CGWindowID, area: CGFloat)?
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"] else { continue }
            let area = width * height
            if best == nil || area > best!.area { best = (wid, area) }
        }
        return best?.wid
    }

    // wid → AXUIElement for Claude-desktop windows seen while their Space was current,
    // plus which of them the app itself considers focused. Exactly the vscodeAXCache
    // trick (see it for the full rationale): a retained element stays valid after its
    // window moves to another Space, and kAXRaiseAction on it makes macOS VISUALLY
    // switch to that Space — the one thing a background app can do. switchToSpace +
    // activate + SLPS (the old desktop path) only flips the WindowServer's current-Space
    // flag and then drags the window onto whatever the display is showing.
    // Written on scanQueue (desktopStatus), read on main (focus) — hence the lock.
    private let desktopAXLock = NSLock()
    private var desktopAXCache: [CGWindowID: AXUIElement] = [:]
    private var desktopFocusedWid: CGWindowID?

    // Retain the app's current windows (already-open a11y tree — call only from inside
    // desktopStatus, after AXManualAccessibility, with the windows it just walked).
    // Closed windows are evicted by the live-wid filter so the cache can't grow or hand
    // out dead elements forever. `focused` is the window the app itself last used — the
    // one "where Claude is" when several are spread over Spaces, used as the jump
    // target only when the row doesn't name a window of its own.
    private func cacheDesktopWindows(_ windows: [(wid: CGWindowID, el: AXUIElement)],
                                     focused: CGWindowID?, pid: pid_t) {
        let live = desktopLiveWindowIDs(pid: pid)
        desktopAXLock.lock()
        desktopAXCache = desktopAXCache.filter { live.contains($0.key) }
        for (wid, elem) in windows { desktopAXCache[wid] = elem }
        desktopFocusedWid = focused
        desktopAXLock.unlock()
    }

    // Window numbers of all the app's live top-level windows, across every Space.
    // Same Screen-Recording-free fields as desktopWindowID.
    private func desktopLiveWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        Set(desktopWindowList(pid: pid).map { $0.wid })
    }

    // How many of the app's windows are on the Space you are looking at RIGHT NOW. The one
    // number that tells "AX can't see them because they're elsewhere" (on=0, normal) from
    // "AX can't see them though they're right here" (on>0, an actual a11y fault).
    // .optionOnScreenOnly is what makes it Space-scoped; still no permission required, and
    // still no kCGWindowName (that is the Screen-Recording-gated field, never read).
    private func desktopOnScreenCount(pid: pid_t) -> Int {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.reduce(into: 0) { n, w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"],
                  width > 1, height > 1 else { return }
            n += 1
        }
    }

    // The app's real top-level windows with their frames, straight from WindowServer.
    // This is the SOURCE OF TRUTH for which desktop rows exist (see desktopStatus): it
    // needs no permission whatsoever, unlike a11y — and unlike kCGWindowName, which is the
    // one field Screen Recording gates, and which we therefore never read.
    // Zero-sized windows are Electron's offscreen helpers, not sessions.
    private func desktopWindowList(pid: pid_t) -> [(wid: CGWindowID, frame: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w -> (wid: CGWindowID, frame: CGRect)? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"],
                  width > 1, height > 1 else { return nil }
            return (wid, CGRect(x: x, y: y, width: width, height: height))
        }
    }

    // Cross-Space raise of the desktop app's own window via its cached AXUIElement.
    // Returns false when nothing usable is cached (app never probed on a Space we've
    // visited, or its a11y objects were rebuilt) so focus() can fall back.
    private func raiseDesktopWindow(pid: pid_t, wid: CGWindowID = 0) -> Bool {
        desktopAXLock.lock()
        let cache = desktopAXCache
        let focused = desktopFocusedWid
        desktopAXLock.unlock()

        var candidates: [CGWindowID] = []
        // A row names its OWN window, and that is the only acceptable target: falling
        // back to "focused, else largest" is exactly how a click on the Design row used
        // to land in the chat window. The app-level guesses are for callers with no
        // window in hand (and for a row whose window died between render and click).
        if wid != 0 { candidates.append(wid) }
        if let f = focused, !candidates.contains(f) { candidates.append(f) }
        if let largest = desktopWindowID(pid: pid), !candidates.contains(largest) {
            candidates.append(largest)
        }
        for wid in candidates {
            guard let elem = cache[wid] else { continue }
            // Validate before raising: Chromium rebuilds a11y objects, and a raise on a
            // dead element is a silent no-op (= "clicked and nothing happened").
            var checkWid = CGWindowID(0)
            guard _AXUIElementGetWindow(elem, &checkWid) == .success, checkWid == wid else {
                jumpDiag("desktop wid=\(wid) cached AX element is STALE → evict")
                desktopAXLock.lock()
                desktopAXCache.removeValue(forKey: wid)
                desktopAXLock.unlock()
                continue
            }
            jumpDiag("desktop wid=\(wid) → cached-AX raise")
            // Synchronous cross-process IPC — off the main thread, same as the editor
            // raise (a busy app would otherwise freeze the UI for the timeout).
            jumpQueue.async {
                AXUIElementSetMessagingTimeout(elem, 0.5)
                AXUIElementSetAttributeValue(elem, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(elem, kAXRaiseAction as CFString)
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.5)
                AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            return true
        }
        jumpDiag("desktop has no cached AX window → activate fallback")
        return false
    }

    // Clear kAXMinimized on all of an app's windows so a following activate() can
    // actually bring one to the front (a minimized window ignores activate()).
    private func deminiaturizeWindows(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var windowsV: AnyObject?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsV) == .success,
              let windows = windowsV as? [AXUIElement] else { return }
        for win in windows {
            var minV: AnyObject?
            if AXUIElementCopyAttributeValue(
                   win, kAXMinimizedAttribute as CFString, &minV) == .success,
               (minV as? Bool) == true {
                AXUIElementSetAttributeValue(
                    win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
    }

    // Serial home for a jump's VSCode-bound AX IPC (raise/frontmost). These are
    // synchronous round-trips that can each stall up to their 0.5s timeout while
    // VSCode is busy (e.g. a prior jump's Space switch) — on the main thread they
    // froze the whole app during consecutive jumps. FIFO order doubles as the
    // "term.show only after the raise finished" guarantee (see focus()).
    private let jumpQueue = DispatchQueue(label: "spectix.jump", qos: .userInitiated)
    // Bumped on every focus() call; pending term.show/verify closures from an older
    // jump compare against it and abort (superseded).
    private var jumpSeq = 0

    // Post-jump landing check: ~0.6s after each term.show request, confirm the
    // extension reports the TARGET as the focused terminal; if activation's
    // focus-restore (or any other race) put focus elsewhere, re-send the focus
    // request (the nonce makes the rewrite fire the extension's watcher) and
    // check once more. Two resends max (~1.9s window) — beyond that a foreign
    // token means the user actively went elsewhere; yanking focus back would fight them.
    private func verifyTerminalFocus(shellPid: pid_t, seq: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.75 : 0.6)) { [weak self] in
            guard let self = self, seq == self.jumpSeq else { return }   // superseded by a newer jump
            let head = self.readFocusToken().split(separator: ":").first.map(String.init) ?? ""
            if pid_t(head) == shellPid { return }   // landed on the target — done
            // Diagnostic (T24 path B): giving up while the active-terminal token names a
            // sibling in the same VSCode window — that sibling may be the running terminal
            // the user ends up staring at.
            guard attempt < 2 else {
                self.jumpDiag("verify GAVE UP — token names sh\(head), wanted sh\(shellPid)"
                    + " (\(self.rows.first(where: { $0.shellPid == pid_t(head) ?? 0 })?.status ?? "n/a"))")
                return
            }
            self.requestTerminalFocus(shellPid: shellPid)
            self.verifyTerminalFocus(shellPid: shellPid, seq: seq, attempt: attempt + 1)
        }
    }

    // The nonce makes every request a distinct write, so the extension's file
    // watcher fires even when the same session is focused twice in a row.
    private var focusSeq = 0
    private func requestTerminalFocus(shellPid: pid_t) {
        focusSeq += 1
        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true)
        try? "\(shellPid):\(focusSeq)".write(
            toFile: "\(dataDir)/focus-request", atomically: true, encoding: .utf8)
    }

    // Ask the Claude Code chat panel living in ONE editor window to focus its input.
    //
    // ★ Broadcast, not a `vscode://` URI (改这里前必读): the URI handler is delivered only
    // to the last-active window, so it can't reach a panel in another one — the same
    // reason focus-request exists for terminals. Every window's companion extension
    // watches this file and acts only when the pid names its own extension host
    // (process.pid), which is exactly the pid discoverSessions recorded as the panel's
    // shellPid. The nonce forces a distinct write so the watcher fires on a repeat jump.
    private func requestChatFocus(hostPid: pid_t) {
        focusSeq += 1
        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true)
        try? "\(hostPid):\(focusSeq)".write(
            toFile: "\(dataDir)/chat-focus-request", atomically: true, encoding: .utf8)
    }

    // MARK: Auto-dismiss on terminal focus
    //
    // The companion extension writes "<shellPid>:<nonce>" to active-terminal each
    // time the user focuses a terminal. On every poll we read it and, on a *new*
    // token, clear that session's toast and mark it seen: going to the terminal
    // yourself is the same as clicking the banner.
    private func readFocusToken() -> String {
        (try? String(contentsOfFile: "\(dataDir)/active-terminal", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func dismissFocusedToast() {
        let token = readFocusToken()
        guard token != lastFocusToken else { return }   // no new focus since last poll
        lastFocusToken = token
        guard let head = token.split(separator: ":").first,
              let pid = pid_t(head), pid > 0 else { return }
        ToastManager.shared.dismiss(shellPid: pid)
        // The eye means "I'm looking", and looking follows terminal focus — which is
        // exclusive. Any checking session that is NOT the newly focused terminal
        // reverts to its real unanswered red (row + banner alike).
        dropChecking(exceptShellPid: pid)
        // Terminal focus is exclusive, so a new focus report means every OTHER armed
        // session was just left behind → its ack applies now (T144). The newly focused
        // one keeps its arm: you're looking at it, it's still 「该你了」.
        promotePendingAck(keepId: rows.first(where: { $0.shellPid == pid })?.id)
        if let row = rows.first(where: { $0.shellPid == pid }) {
            if row.status == "needs" {
                enterChecking(row)   // focusing a needs terminal = "I'm looking" → eye
            } else {
                acknowledge(row.id, status: row.status)   // no-op unless done
            }
        }
    }

    // MARK: Chat-panel focus → list sync (T204)
    //
    // Clicking a terminal reveals its row in the list; clicking the Claude Code panel in
    // a VSCode sidebar had to do the same. It can't reuse the terminal path: that one is
    // fed by the extension's active-terminal token, and VSCode gives third-party
    // extensions no way to know a webview holds keyboard focus (`activeTextEditor` keeps
    // naming the last editor after focus moves to the sidebar, so the negative space is
    // no help either). So the answer is split in half — the a11y tree knows WHETHER a
    // chat panel has focus, the extension knows WHICH WINDOW that is. Neither alone is
    // enough: `frontmostApplication` is the Code MAIN process, while a chat row's
    // shellPid is its extension host, one per window.
    //
    // The measured markers behind `Message input` / `Claude Code` — and why the check is
    // a positive whitelist rather than a role test — are in docs/focus-ring.md.

    /// What the frontmost editor's focused element is, as far as the list cares.
    private enum EditorFocus { case chatPanel, terminal, other }

    /// One focused-element read, three verdicts — the poll runs every 0.3s, so asking
    /// separately per question would triple the AX traffic for nothing.
    private func editorFocusKind() -> EditorFocus {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier, EditorApp(rawValue: bid) != nil,
              let focused = axAttr(AXUIElementCreateApplication(app.processIdentifier),
                                   kAXFocusedUIElementAttribute)
        else { return .other }
        // xterm's hidden input, keyed on the DOM class because that is
        // locale-independent — the same reason FocusRing resolves ring panes by it
        // rather than by the localised "终端 N" description.
        var classes: AnyObject?
        if AXUIElementCopyAttributeValue(focused, "AXDOMClassList" as CFString,
                                         &classes) == .success,
           let list = classes as? [String],
           list.contains(where: { $0.contains("xterm-helper-textarea") }) {
            return .terminal
        }
        // The message box, by far the common chat case — done in one more read.
        if axStringAttr(focused, kAXDescriptionAttribute) == "Message input" { return .chatPanel }
        // Otherwise the transcript area, whose own element is an anonymous web area; the
        // panel container a step or two up is what carries the name. Measured at up1, so
        // four is slack, not a search — going deeper would start charging AX round trips
        // on every poll for shapes that were never observed.
        var cur: AXUIElement? = axAttr(focused, kAXParentAttribute)
        for _ in 0..<4 {
            guard let c = cur else { return .other }
            if axStringAttr(c, kAXDescriptionAttribute) == "Claude Code" { return .chatPanel }
            cur = axAttr(c, kAXParentAttribute)
        }
        return .other
    }

    /// The extension host pid of the editor window the user is in — a chat row's shellPid.
    private func activeWindowPid() -> pid_t {
        guard let s = try? String(contentsOfFile: "\(dataDir)/active-window", encoding: .utf8),
              let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
                  .split(separator: ":").first,
              let p = pid_t(head) else { return 0 }
        return p
    }

    private func focusTokenAge() -> TimeInterval {
        guard let m = try? FileManager.default
            .attributesOfItem(atPath: "\(dataDir)/active-terminal")[.modificationDate] as? Date
        else { return .infinity }
        return Date().timeIntervalSince(m)
    }

    private func checkChatFocus() {
        let kind = editorFocusKind()
        guard kind == .chatPanel else {
            // ★ Going chat → a terminal in the SAME window is invisible to the extension
            // (改这段前必读): window focus never changed, and `activeTerminal` never
            // changed either — a sidebar is not a terminal, so the terminal you came back
            // to is still the one VSCode considers active. Neither event fires, no token
            // is written, and the pin would sit on the chat row while you type in the
            // terminal. (extension.js records the mirror image of this hole at
            // focusByPid: `term.show()` on the already-active terminal is silent too.)
            // Fix = replay the standing token, which names that window's focused
            // terminal — precisely where focus just landed. Gated on actually seeing a
            // terminal: leaving the panel for the editor or the file tree must NOT drag
            // the pin onto some terminal the user isn't in.
            if chatFocusPid != 0, kind == .terminal { lastFlashToken = "" }
            chatFocusPid = 0   // left the panel; a later return to it must re-pin
            return
        }
        // Focus is exclusive, so the a11y tree separates chat from terminal on its own —
        // except right after a terminal click, when Electron's tree still reports the
        // panel the user just left (the same lag documented for the ring's pane
        // reconciliation). The extension's token is exact, so a fresh one outranks us.
        //
        // ★ This window must be sized to the LAG, not to how fast a user might click
        // (改这个数字前必读). It was 1.5s on the second reading and the delay was
        // visible: going terminal → sidebar within 1.5s left the row unlit until the
        // window expired, for no reason — the tree had long since caught up. The lag
        // itself measures 100–400ms, and overshoot is cheap here anyway: the terminal
        // path runs LATER in this same tick (checkFocusFlash below), so on the one tick
        // where a click does land, its exact token overwrites whatever we pinned.
        guard focusTokenAge() > 0.5 else { return }
        let pid = activeWindowPid()
        guard pid > 0, pid != chatFocusPid else { return }   // steady focus must not re-pin
        chatFocusPid = pid
        // List sync only. Deliberately NOT the toast/ack path that terminal focus runs:
        // that one acts on the extension's exact report, while this is an a11y poll, and
        // a misread there would mark a genuinely unanswered "needs" row as seen.
        mainWindowController?.focusSession(shellPid: pid)
        if popover.isShown { popoverController.focusSession(shellPid: pid) }
    }
    private var chatFocusPid: pid_t = 0

    // MARK: Ring flash on manual terminal click
    //
    // The extension writes active-terminal on EVERY terminal focus, jumps and
    // manual clicks alike. A new token here (own dedup state — dismissFocusedToast
    // has its own consumer on the same file, at the slower refresh cadence) means
    // the user landed in a terminal; flash the ring there so the landing spot is
    // obvious. flashFocused() itself skips the case where a jump already ringed
    // this terminal.
    private func checkFocusFlash() {
        // Shares this timer rather than opening a second one: chat focus changes no file,
        // so it can only be found by polling, and 0.3s is already the focus cadence.
        checkChatFocus()
        tickFocusSegment()
        let token = readFocusToken()
        guard token != lastFlashToken else { return }
        lastFlashToken = token
        // The focused terminal just changed — refresh "home" now so a switch between two
        // terminals of one VSCode app (no NSWorkspace activation event) is still tracked.
        trackHome()
        // Focus moved, so whatever stretch was running ended here — close it before the
        // guard below, which returns early on an unparseable token.
        closeFocusSegment()
        guard let head = token.split(separator: ":").first,
              let pid = pid_t(head), pid > 0 else { return }
        openFocusSegment(shellPid: pid)

        // List sync: reveal + highlight the focused terminal's session in whichever
        // surface is open. Independent of the ring toggle — following focus in the list
        // shouldn't be disabled just because the jump ring is off.
        mainWindowController?.focusSession(shellPid: pid)
        if popover.isShown { popoverController.focusSession(shellPid: pid) }

        // Ring flash: gated on the highlight/ring settings and a live VSCode, and
        // ONLY for terminals that actually run a Claude session — a plain terminal
        // has no status to report, so it gets no ring at all. Note this can't be
        // expressed by mapping it onto a status: "idle" means a SESSION sitting
        // idle, which is legitimately ringable and whose style the user may have
        // set to something visible (that mapping is what drew a gray ripple on
        // plain terminals; working blue before that claimed a turn was running).
        // Two independent switches decide what a manual click shows: ringOnFocusClick
        // for the ring, captionOnFocusClick for the label (the latter needs the caption
        // enabled at all). Attempt the flash if EITHER wants something; flashFocused
        // then draws ring, caption, or both per these eligibilities.
        let ringClick = AppSettings.ringOnFocusClick
        let captionClick = AppSettings.captionOnFocusClick && AppSettings.captionEnabled
        // `row.editor` non-nil is the whitelist gate: a session whose host we don't
        // recognize gets no ring and no caption, ever — we have no pane of ITS to draw
        // on, and the old .vscode fallback drew on somebody else's.
        guard AppSettings.highlightsEnabled, ringClick || captionClick,
              let row = rows.first(where: { $0.shellPid == pid }),
              let editor = row.editor,
              let vs = NSRunningApplication.runningApplications(
                  withBundleIdentifier: editor.rawValue).first else { return }
        TerminalFocusRing.shared.flashFocused(
            vscodePid: vs.processIdentifier, shellPid: pid, status: row.status,
            editorBundleId: editor.rawValue, project: row.folder, task: row.taskTitle,
            icon: row.badgeMode,
            ringEligible: ringClick, captionEligible: AppSettings.captionOnFocusClick)
    }

    // MARK: Impact log — arrivals and focus stretches (T227)
    //
    // One tracked stretch serves both metrics the panel needs from terminal focus:
    // 到达 (you went to a session, and what greeted you when you got there) and 专注
    // (how long you stayed without being pulled away). They're the same observation seen
    // from two ends, so recording it once keeps them from ever disagreeing — the
    // filtering that splits them (D3's <3s / dedupe / idle rules) happens at read time in
    // ImpactStore, where the user can see and re-apply it.
    private struct FocusSegment {
        let tty: String
        let status: String     // what the session was showing WHEN YOU GOT THERE
        let startTs: Int
        var active = false     // you actually typed or clicked during the stay
    }
    private var focusSegment: FocusSegment?

    // Driven by the 0.3s focus timer. Two jobs: notice that you were really here (a
    // terminal left in front while you sleep must not become your best focus week), and
    // close the stretch when you leave the editor entirely. The extension writes no token
    // on the way OUT to a browser, so without this half a stretch would run until the
    // next terminal click — hours later.
    private func tickFocusSegment() {
        guard var seg = focusSegment else { return }
        if secondsSinceLastInput() < 1 { seg.active = true }
        focusSegment = seg
        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bid == nil || EditorApp(rawValue: bid!) == nil { closeFocusSegment() }
    }

    private func openFocusSegment(shellPid: pid_t) {
        guard let row = rows.first(where: { $0.shellPid == shellPid }), !row.tty.isEmpty else { return }
        // `rows` is up to one refresh (2.5s) stale, so this is the status as of the last
        // scan, not to the millisecond. That's the right grain anyway: the question is
        // "was this session wanting you when you walked over", and a status that flipped
        // in the last two seconds hadn't reached the screen you were reacting to either.
        focusSegment = FocusSegment(tty: row.tty, status: row.status,
                                    startTs: Int(Date().timeIntervalSince1970))
    }

    private func closeFocusSegment() {
        guard let seg = focusSegment else { return }
        focusSegment = nil
        let dwell = Int(Date().timeIntervalSince1970) - seg.startTs
        guard dwell > 0 else { return }
        ImpactLog.log(.arrive, tty: seg.tty, status: seg.status, dwell: dwell, active: seg.active)
    }

    // The parked latch just refused to carry you off the prompt in front of you. Both
    // automatic paths report it, and the idle one is re-evaluated every 2.5s refresh —
    // so it's rate-limited to one line a minute per session. Sitting on a prompt for ten
    // minutes is ONE thing the app did for you, not 240.
    private func logParkedBlock(_ rows: [SessionRow]) {
        ImpactLog.logThrottled(.parkedBlock,
                               tty: rows.first { $0.id == parkedAttentionId }?.tty,
                               minGap: 60)
    }

    // A banner just went up. This is where the response clock starts for every number the
    // panel reports, so it stores the raw "seconds since you last touched the machine"
    // instead of an 在电脑前 verdict — the threshold that turns it into one lives in
    // ImpactRule, in the open, where a user re-computing the numbers can apply it too.
    private func logNotified(_ row: SessionRow) {
        guard !row.tty.isEmpty else { return }
        ImpactLog.log(.notify, tty: row.tty, status: row.status,
                      idle: Int(secondsSinceLastInput()))
    }

    // 掌控 measures how many sessions you ran at once. Logged on CHANGE, not sampled:
    // one line per refresh would be ~34k lines a day and say exactly the same thing.
    // Each line owns the span until the next, which is what lets the P75 be time-weighted.
    private var lastLiveCount = -1
    private func logLiveCount(_ rows: [SessionRow]) {
        let n = rows.filter { !$0.isDesktop && $0.status != "idle" }.count
        guard n != lastLiveCount else { return }
        lastLiveCount = n
        ImpactLog.log(.live, n: n)
    }

    // Revert the watching eye on every checking session except the one owning
    // `shellPid` (session ids end with "#<shellPid>", see SessionRow.id).
    private func dropChecking(exceptShellPid pid: pid_t) {
        let dropped = checkingIds.filter { !$0.hasSuffix("#\(pid)") }
        guard !dropped.isEmpty else { return }
        checkingIds.subtract(dropped)
        dropped.forEach { ToastManager.shared.uncheck($0) }
        renderRows()
    }

    // MARK: cwd → VSCode window cache (Screen-Recording-free cross-Space jumps)
    //
    // Cross-Space jumping needs the target window's CGWindowID to feed switchToSpace.
    // Identifying that window cross-Space by its TITLE would need Screen Recording; we
    // sidestep it by CACHING. Every refresh we look at the VSCode windows on the CURRENT
    // Space — AX title reads need only Accessibility, not Screen Recording — and record
    // wid → title (wid via _AXUIElementGetWindow). A window keeps its wid when it moves
    // to another Space, so once we've seen it here even once we can still switch to it
    // later. Never-seen-on-this-Space → cache miss → plain activate fallback.
    //
    // main-thread only (merged in refresh()'s main hop, read in raiseVSCodeWindow), so
    // no lock — same pattern as `rows`. Loaded from disk at launch so a SpectiX restart
    // with VSCode still open (rebuild / manual relaunch — the common restart) restores the
    // cache, incl. other-Space windows, without re-accumulating; stale ids are pruned on the
    // first scan by updateVSCodeWindowCache's `live` filter (see persistWindowCache).
    // --- AX rescan gate (see scanVSCodeWindows) ---------------------------------
    // How stale the window-title cache may get when nothing observable changed. Window
    // titles only shift when you switch project/file in an editor, so seconds of lag is
    // invisible — whereas re-enumerating on every FSEvent burst cost ~112ms a pop.
    private static let axRescanInterval: TimeInterval = 10
    // Both touched only on scanQueue (scanVSCodeWindows is called from fetchRows alone).
    private var lastAXScan: TimeInterval = 0
    private var liveWindowIDs = Set<CGWindowID>()
    // Set from the MAIN thread (Space-change notification), consumed on scanQueue — hence
    // the lock, and hence take-and-clear in one step so a concurrent set can't be lost.
    // Starts true: the first scan after launch must always run.
    private let axForceLock = NSLock()
    private var pendingForceAXScan = true
    private func takeForceAXScan() -> Bool {
        axForceLock.lock(); defer { axForceLock.unlock() }
        let v = pendingForceAXScan; pendingForceAXScan = false; return v
    }
    private func requestForceAXScan() {
        axForceLock.lock(); pendingForceAXScan = true; axForceLock.unlock()
    }

    private var vscodeWindowCache: [CGWindowID: String] = AppController.loadPersistedWindowCache()

    // wid → AXUIElement for VSCode windows seen on the current Space. A retained element
    // stays valid after its window moves to another Space, and kAXRaiseAction on it brings
    // the window forward AND makes macOS switch to its Space — the reliable cross-Space jump
    // (proven: setSpace only flips the WindowServer flag from a background app without moving
    // the physical display; a cached-element raise, the AltTab way, actually switches). Not
    // persisted (AXUIElements can't cross a process restart) — repopulated on the first scan.
    private var vscodeAXCache: [CGWindowID: AXUIElement] = [:]

    // wid → which VSCode-family editor owns the window, so raiseEditorWindow can pick the
    // right candidate windows (a folder open in both VSCode and Cursor must resolve to the
    // row's editor) and target the right `open -b` fallback. Not persisted (like vscodeAXCache):
    // a restart repopulates it on the first scan; until then a missing entry defaults to
    // .vscode, matching the pre-multi-editor behavior for the common case.
    private var vscodeWindowEditor: [CGWindowID: EditorApp] = [:]

    // wid → the path of the file the window currently shows (its AXDocument). A window
    // TITLE carries only the folder NAME, so two git worktrees of one repo — .../nextad/
    // apps/deal-alarm and .../nextad-wt-deal-alarm/apps/deal-alarm — produce byte-identical
    // titles and every name→path lookup silently picks whichever the ranking happens to
    // put first. The document path is the one window attribute that says which of them
    // this window really is. Used ONLY as a tie-breaker (see resolve sites): a webview or
    // welcome-page window has no document at all, so it must never be a precondition.
    // Not persisted (like vscodeAXCache) — the first AX scan after a restart refills it.
    private var vscodeWindowDoc: [CGWindowID: String] = [:]

    // AXDocument comes back as a percent-encoded file:// URL string (some hosts hand back
    // a bare path — accept both). Anything that isn't an absolute path is dropped rather
    // than guessed at: a nil document simply means "no tie-breaker for this window".
    private static func pathFromAXDocument(_ raw: String) -> String? {
        let p = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? "") : raw
        return p.hasPrefix("/") ? p : nil
    }

    // Off-main (refresh scan): the VSCode windows on the CURRENT Space as (wid, title),
    // plus the window numbers of ALL live VSCode windows (across every Space) so the
    // caller can evict closed ones. Both need only Accessibility / plain CGWindowList —
    // never Screen Recording. Empty when VSCode isn't running.
    private func scanVSCodeWindows()
        -> (seen: [(wid: CGWindowID, title: String, doc: String?,
                    elem: AXUIElement, editor: EditorApp)],
            live: Set<CGWindowID>) {
        // All live top-level window numbers — CGWindowList exposes number/owner/layer
        // without Screen Recording (only window NAMES are gated). Read once; filter per
        // editor pid below.
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen: [(CGWindowID, String, String?, AXUIElement, EditorApp)] = []
        var live = Set<CGWindowID>()

        // Every VSCode-family editor that's running gets scanned the same way. For the
        // common single-editor case (only VSCode open) this resolves one real pid; the
        // others fall out immediately at the running-app guard.
        let editors: [(editor: EditorApp, pid: pid_t)] = EditorApp.allCases.compactMap {
            guard let app = NSRunningApplication.runningApplications(
                      withBundleIdentifier: $0.rawValue).first else { return nil }
            return ($0, app.processIdentifier)
        }

        // PASS 1 — cheap, runs EVERY time: live window ids from CGWindowList (no AX, no
        // Screen Recording). This must always be complete, because the caller prunes its
        // cache to exactly this set — handing back a partial one wipes live entries.
        for (_, pid) in editors {
            for w in info {
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let wid = w[kCGWindowNumber as String] as? CGWindowID else { continue }
                live.insert(wid)
            }
        }

        // Gate for PASS 2 only. The AX title enumeration is cross-process IPC and orders
        // of magnitude more expensive than pass 1, yet it used to run on EVERY refresh —
        // including the FSEvent bursts a busy turn fires several times a second — while
        // windows open, close and get retitled on a HUMAN timescale. Skipping it returns
        // an empty `seen`, which is safe: updateVSCodeWindowCache keeps every entry that
        // `live` still vouches for, so the cache is simply not re-confirmed this round.
        let forced = takeForceAXScan()                       // Space switch / app switch
        let axDue = liveWindowIDs != live                    // a window opened or closed
            || forced
            || Date().timeIntervalSince1970 - lastAXScan >= Self.axRescanInterval
        liveWindowIDs = live
        guard axDue else { return (seen, live) }
        lastAXScan = Date().timeIntervalSince1970

        // PASS 2 — gated: window titles + AX elements.
        for (editor, pid) in editors {
            // Current-Space windows via AX: titles come from the native Cocoa layer
            // (Accessibility only, no Screen Recording), the CGWindowID via _AXUIElementGetWindow.
            // AX lists only the current Space, so the cache ACCUMULATES across Spaces over time —
            // updateVSCodeWindowCache keeps entries for windows now on other Spaces, so a window
            // visited once stays jumpable from anywhere. (A WindowServer cross-Space enumeration
            // was tried but CGSCopyWindowProperty's title comes back empty for off-Space windows.)
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            var windowsV: AnyObject?
            guard AXUIElementCopyAttributeValue(
                      axApp, kAXWindowsAttribute as CFString, &windowsV) == .success,
                  let windows = windowsV as? [AXUIElement] else { continue }
            for win in windows {
                var titleV: AnyObject?
                guard AXUIElementCopyAttributeValue(
                          win, kAXTitleAttribute as CFString, &titleV) == .success,
                      let title = titleV as? String, !title.isEmpty else { continue }
                var wid = CGWindowID(0)
                guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0 else { continue }
                // Retain the AXUIElement — a jump can kAXRaiseAction it later even when the
                // window has since moved to another Space (AX's window list only shows the
                // current Space, but a cached element stays valid and raising it crosses
                // Spaces, the way AltTab focuses off-Space windows). See raiseEditorWindow.
                // The open file's full path — the only per-window signal that tells two
                // same-named worktrees apart (see vscodeWindowDoc). Optional by design:
                // plenty of windows (webviews, the welcome page) have no document.
                var docV: AnyObject?
                let doc = AXUIElementCopyAttributeValue(
                              win, kAXDocumentAttribute as CFString, &docV) == .success
                    ? (docV as? String).flatMap(Self.pathFromAXDocument) : nil
                seen.append((wid, title, doc, win, editor))
            }
        }
        return (seen, live)
    }

    // Projects whose VSCode window is OPEN but which have no live Claude session — they
    // render as a header-only group (grey ●0, no children) so an open-but-unused window
    // is still visible in the list instead of vanishing until someone runs `claude` in it.
    //
    // vscodeWindowCache is exactly the set of currently-open VSCode windows (closed ones
    // are evicted by updateVSCodeWindowCache's `live` filter), but a window title carries
    // only the FOLDER NAME — never the path. Header identity is keyed by cwd everywhere
    // (hiddenCwds / customIcons / folderOrder / raiseVSCodeWindow), so a folder-name key
    // would give the same project two different identities depending on whether a session
    // happens to be live — losing its icon, rank and collapse state the moment one starts.
    // So every window has to be resolved to a REAL path, and windows that don't resolve
    // are skipped: without a cwd there's nothing to key, hide or raise against.
    //
    // Two sources, in order — the second covers whatever the first can't vouch for:
    //   1. The window says so. The companion extension (>= 0.0.8) writes the folders its
    //      own window has open. Only source that can't be wrong, but only as complete as
    //      the extension's rollout, so it is trusted per editor and only when ALL of that
    //      editor's windows answered.
    //   2. Title -> path against ProjectHistory (projects Claude has been run in) plus
    //      EditorWorkspaces (folders the editor reports having open). A title carries a
    //      folder NAME, so two git worktrees of one repo are indistinguishable and the
    //      choice is a judgement call — see WindowFolderResolve, and docs/jump.md for the
    //      phantom group that comes back whenever that judgement guesses.
    //
    // Main-thread only — reads vscodeWindowCache (same contract as `rows`).
    //
    // Each result carries the editor that owns the window, because a sessionless group has
    // no row to derive it from — the header badge and, more importantly, the click-to-jump
    // both need to know which app to raise.
    private func openProjectsWithoutSessions(activeCwds: Set<String>) -> [(cwd: String, editor: EditorApp)] {
        guard !vscodeWindowCache.isEmpty else { return [] }
        var out: [(cwd: String, editor: EditorApp)] = []
        var taken = Set<String>()

        // ---- Source 1: the windows themselves (companion extension >= 0.0.8).
        //
        // Trusted PER EDITOR and only when every one of its open windows answered. A
        // window running an older extension — or one not reloaded since the install —
        // writes no window file, and acting on a partial list would silently drop that
        // window's header. Counting is the cheapest way to tell "this editor is fully
        // covered" from "some of it is", and an editor that isn't covered falls back
        // whole rather than half.
        var reportedWindows: [EditorApp: Int] = [:]
        var reportedFolders: [EditorApp: [String]] = [:]
        for report in CompanionExtension.liveWindowFolders() {
            // The host is an extension-host child of the editor app, so the same
            // parent-chain walk that maps a Claude pid to its terminal app names it.
            guard let bid = hostAppBundleId(forClaudePid: report.hostPid),
                  let editor = EditorApp(rawValue: bid) else { continue }
            reportedWindows[editor, default: 0] += 1
            reportedFolders[editor, default: []].append(contentsOf: report.folders)
        }
        var openWindows: [EditorApp: Int] = [:]
        for (wid, _) in vscodeWindowCache {
            openWindows[vscodeWindowEditor[wid] ?? .vscode, default: 0] += 1
        }
        let trusted = Set(openWindows.filter { reportedWindows[$0.key] == $0.value }.keys)
        noteFolderReportTrust(trusted: trusted, open: openWindows, reported: reportedWindows)

        for editor in EditorApp.allCases where trusted.contains(editor) {
            for cwd in reportedFolders[editor] ?? [] {
                guard !activeCwds.contains(cwd),        // has sessions -> a real group already
                      !taken.contains(cwd),             // two windows on one project -> one header
                      !AppSettings.isHidden(cwd: cwd) else { continue }
                taken.insert(cwd)
                out.append((cwd, editor))
            }
        }

        // ---- Source 2: title -> path lookup, for the editors source 1 can't vouch for.
        guard !trusted.isSuperset(of: openWindows.keys) else { return out }
        // (folder name, path) in ProjectHistory order — pinned first, then most-recently
        // seen. Scanning in THAT order (rather than picking the first title segment that
        // resolves) means two known projects sharing a folder name resolve to the one you
        // actually use, and a filename segment can't outrank the real workspace folder.
        // Names are computed once here, not per window x project pair.
        //
        // ProjectHistory only knows projects a Claude session has been seen in, so on its
        // own it can never resolve the very case this function exists for: a window that
        // has never run Claude. EditorWorkspaces appends the folders the editor reports
        // having open — LAST, so the priority above is preserved for names history knows.
        let editorFolders = EditorWorkspaces.openFolders()
        let known = (ProjectHistory.all().map { $0.path } + editorFolders)
            .map { (name: ($0 as NSString).lastPathComponent, path: $0) }
        let editorFolderSet = Set(editorFolders)
        for (wid, title) in vscodeWindowCache {
            let editor = vscodeWindowEditor[wid] ?? .vscode
            if trusted.contains(editor) { continue }
            let segs = Set(titleSegments(title))
            // Every known project whose folder name this title could mean. Normally one;
            // two git worktrees of the same repo make it several — see WindowFolderResolve
            // for how that is settled and why guessing there produced a phantom group.
            let cands = known.filter { segs.contains($0.name) }.map { $0.path }
            let doc = vscodeWindowDoc[wid]
            // Only fires when a name really is ambiguous, so it can't spam the log — and
            // when this bug comes back, the phantom group is invisible in every other
            // record: both candidates are legitimate paths and the title looks fine.
            if Set(cands).count > 1 {
                jumpDiag("ambiguous folder name in \"\(title)\" → \(cands) | doc=\(doc ?? "-")")
            }
            guard let cwd = WindowFolderResolve.resolve(
                      candidates: cands, doc: doc, activeCwds: activeCwds,
                      editorFolders: editorFolderSet, taken: taken),
                  !AppSettings.isHidden(cwd: cwd) else { continue }
            taken.insert(cwd)
            // The editor map is filled by the same scan that filled the title cache, so a
            // miss can only mean a title restored from the persisted cache before this
            // launch's first scan re-saw it; VS Code is the right guess for that window.
            out.append((cwd, editor))
        }
        return out
    }

    // Whether each editor's windows all reported their own folders on the last pass. A
    // flip here switches openProjectsWithoutSessions between its two sources, and nothing
    // else on disk says which one produced a given header — so log the TRANSITION, and
    // only the transition: this runs every 2.5s.
    private var folderReportTrust: [EditorApp: Bool] = [:]
    private func noteFolderReportTrust(trusted: Set<EditorApp>,
                                       open: [EditorApp: Int],
                                       reported: [EditorApp: Int]) {
        for (editor, windows) in open {
            let now = trusted.contains(editor)
            guard folderReportTrust[editor] != now else { continue }
            folderReportTrust[editor] = now
            jumpDiag("window folder reports \(now ? "trusted" : "unusable") for "
                     + "\(editor.rawValue): \(reported[editor] ?? 0)/\(windows) answered")
        }
        // Forget editors that quit, so relaunching one logs its state again rather than
        // comparing against a verdict from hours ago.
        folderReportTrust = folderReportTrust.filter { open[$0.key] != nil }
    }

    // Merge a scan into the cache (main thread). Evict windows that have closed, upsert
    // the ones we just saw on the current Space. Entries for windows now on OTHER Spaces
    // survive (still in `live`, just not in `seen`) — that's the whole point.
    private func updateVSCodeWindowCache(
        seen: [(wid: CGWindowID, title: String, doc: String?,
                elem: AXUIElement, editor: EditorApp)],
        live: Set<CGWindowID>) {
        vscodeWindowCache = vscodeWindowCache.filter { live.contains($0.key) }
        vscodeAXCache = vscodeAXCache.filter { live.contains($0.key) }
        vscodeWindowEditor = vscodeWindowEditor.filter { live.contains($0.key) }
        vscodeWindowDoc = vscodeWindowDoc.filter { live.contains($0.key) }
        for (wid, title, doc, elem, editor) in seen {
            vscodeWindowCache[wid] = title
            vscodeAXCache[wid] = elem
            vscodeWindowEditor[wid] = editor
            // Keep the last known document when this scan finds none: switching to a
            // webview tab clears AXDocument without changing which project the window
            // belongs to, and dropping it there would resurrect the same-name ambiguity.
            // A window that genuinely changes workspace re-titles AND re-documents itself
            // as soon as a file is opened, which overwrites this.
            if let doc { vscodeWindowDoc[wid] = doc }
        }
        persistWindowCache()
    }

    // Persist wid→title so a SpectiX restart with VSCode still running (rebuild / manual
    // relaunch — the common restart) restores the whole cache, incl. OTHER-Space windows,
    // with zero re-accumulation. A CGWindowID stays valid while its window lives, so the saved
    // wids are still good. Stale ones (window closed, or macOS/VSCode restarted → ids reassigned)
    // fail updateVSCodeWindowCache's `live` filter on the first scan and drop out — we never
    // switchToSpace/SLPS a dead id. A recycled wid pointing at a different window self-heals
    // when that window next reaches the current Space and the scan overwrites its title.
    private static let windowCacheKey = "vscodeWindowCache"
    private static func loadPersistedWindowCache() -> [CGWindowID: String] {
        guard let dict = UserDefaults.standard.dictionary(
                  forKey: windowCacheKey) as? [String: String] else { return [:] }
        var out: [CGWindowID: String] = [:]
        for (k, v) in dict { if let wid = UInt32(k) { out[wid] = v } }
        return out
    }
    private func persistWindowCache() {
        var dict: [String: String] = [:]
        for (wid, title) in vscodeWindowCache { dict[String(wid)] = title }
        UserDefaults.standard.set(dict, forKey: Self.windowCacheKey)
    }

    // Bring the editor window that owns `cwd` to the front — across desktops/displays.
    // `editor` is the row's host (VSCode / Cursor / Windsurf); all three share this path.
    //
    // Each editor window can live on its own macOS Space (a Mission Control desktop, or
    // a display when "Displays have separate Spaces" is on). The Accessibility API's
    // window list (kAXWindowsAttribute) only enumerates windows on the CURRENT Space,
    // so it literally cannot see — let alone raise — a window sitting on another
    // desktop: that was the multi-window jump bug.
    //
    // So: find the target window in vscodeWindowCache (matched by title, which carries
    // the workspace folder name), look up its Space with the private CGS API, switch to
    // that Space, then activate the editor so the now-current-Space window comes forward.
    // The cache is built from current-Space AX scans (see vscodeWindowCache) — reading
    // titles that way needs only Accessibility, NOT Screen Recording. A window we've
    // never seen on a visited Space isn't cached → we fall back to a plain activate.
    // Returns the window it decided to raise, or nil when it could only fall back to a
    // plain activate/open (no wid resolved). The chat-panel jump rings THAT window, so
    // raise and ring always name the same one even if the title match picked wrong.
    @discardableResult
    private func raiseEditorWindow(cwd: String, editor: EditorApp) -> CGWindowID? {
        jumpDiag("raiseEditorWindow cwd=\(cwd) editor=\(editor.rawValue)")
        guard let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: editor.rawValue).first else {
            jumpDiag("no \(editor.rawValue) running → open")
            openInEditor(editor.rawValue, cwd)
            return nil
        }
        let pid = app.processIdentifier

        // Every cached window that belongs to THIS editor — accumulated across Spaces from
        // the current-Space AX scan, no Screen Recording (see vscodeWindowCache). Filtering
        // by editor keeps a folder that's open in two editors at once resolving to the right
        // host (a missing editor entry defaults to .vscode — the common/restart case).
        let titled: [(wid: CGWindowID, title: String)] = vscodeWindowCache.compactMap {
            (vscodeWindowEditor[$0.key] ?? .vscode) == editor ? ($0.key, $0.value) : nil
        }

        // Log each window's document too: when a jump lands on the wrong checkout of a
        // same-named repo, the title column looks identical and only this column shows why.
        jumpDiag("pid=\(pid) cached windows=\(titled.count)"
                 + " → \(titled.map { "[\($0.wid):\($0.title)|doc=\(vscodeWindowDoc[$0.wid] ?? "-")]" }.joined(separator: " "))")

        // Empty cache — VSCode just launched, or the target has never been on a Space
        // we've visited since launch. Can't map cwd→window; fall back to plain activate.
        if titled.isEmpty {
            app.activate(options: [.activateIgnoringOtherApps])
            return nil
        }

        // cwd path components, deepest first (deepest-first prefers the most specific
        // window when a session's cwd nests under an opened parent workspace).
        let home = NSHomeDirectory()
        var components: [String] = []
        var dir = cwd
        while dir.count > home.count && dir != "/" {
            components.append((dir as NSString).lastPathComponent)
            dir = (dir as NSString).deletingLastPathComponent
        }

        // Pass 1 exact segment, Pass 2 loose substring fallback (decorated titles).
        // titleSegments() explains the matching rules.
        //
        // Each pass can match SEVERAL windows at once — same-named worktrees carry the
        // same title — and picking the first would jump to the other checkout of the same
        // repo: right-looking window, wrong tree. pickByDoc breaks that tie by the file
        // each window has open, and falls straight back to first-match otherwise.
        var target: CGWindowID?
        for name in components where target == nil {
            target = pickByDoc(titled.filter { titleSegments($0.title).contains(name) }, cwd: cwd)
        }
        for name in components where target == nil {
            target = pickByDoc(titled.filter { $0.title.contains(name) }, cwd: cwd)
        }
        guard let wid = target else {
            jumpDiag("NO title matched components=\(components.joined(separator: ",")) → plain activate")
            app.activate(options: [.activateIgnoringOtherApps])
            return nil
        }
        // Cross-Space raise via the CACHED AXUIElement for this window (captured while it
        // was on the current Space; see vscodeAXCache). kAXRaiseAction on a cached element
        // brings the window forward AND makes macOS switch to its Space — even when it now
        // lives on another one. This is the ONLY approach that visually switches from a
        // background app: setSpace merely flips the WindowServer's current-Space flag without
        // moving the physical display, and SLPS/activate then drag the window onto whatever
        // the display is actually showing. Raising the retained element is how AltTab reaches
        // off-Space windows.
        //
        // The element is VALIDATED first (still resolves to the same wid): Electron can
        // rebuild its a11y objects, and kAXRaiseAction on a dead element is a silent no-op
        // (= "clicked and nothing happened"). Dead entries are evicted so the next scan
        // re-caches the live element.
        if let elem = vscodeAXCache[wid] {
            var checkWid = CGWindowID(0)
            if _AXUIElementGetWindow(elem, &checkWid) == .success, checkWid == wid {
                jumpDiag("matched wid=\(wid) → cached-AX raise")
                // Synchronous IPC round-trips into VSCode, up to 0.5s each (bounded
                // timeout) — worst ~1.5s when VSCode is busy with a prior jump's Space
                // switch. Run them on jumpQueue, NOT the main thread: on main they froze
                // the app between consecutive jumps (clicks queued behind the stall).
                // Serial FIFO also lets focus() order term.show after the raise.
                jumpQueue.async { [weak self] in
                    AXUIElementSetMessagingTimeout(elem, 0.5)
                    AXUIElementSetAttributeValue(elem, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(elem, kAXRaiseAction as CFString)
                    let axApp = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(axApp, 0.5)
                    AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    // ★ Hand the window the KEYBOARD FOCUS too, not just the front (改这里前必读).
                    // AXMain ("is the main window") and AXFocused ("holds key focus") are separate
                    // attributes, and kAXFocusedUIElement follows the FOCUSED window — so the three
                    // calls above leave the window frontmost and main while focus stays parked in
                    // whatever window you jumped FROM. term.show then selects the terminal inside
                    // the target window (the extension's token is right), but that is VSCode's own
                    // selection, not OS-level focus. FocusRing's third identity check reads the app's
                    // kAXFocusedUIElement, so it kept resolving to a pane in the OLD window and
                    // vetoed every draw: the ring never appeared (no pane memo), or appeared from
                    // memory and was withdrawn 2s later unconfirmed (with memo). Measured 5.1s of
                    // zero focus movement after a raise — this is not slowness, focus never arrives.
                    // Electron's acceptance of a settable AXFocusedWindow is the thing to watch:
                    // an `err` here means this route is closed and the identity check has to stop
                    // depending on app-level focus (walk the TARGET window's tree by paneIdentity).
                    let focused = AXUIElementSetAttributeValue(
                        axApp, kAXFocusedWindowAttribute as CFString, elem)
                    self?.jumpDiag("focus wid=\(wid) → "
                                   + (focused == .success ? "ok" : "err \(focused.rawValue)"))
                }
                return wid
            }
            jumpDiag("wid=\(wid) cached AX element is STALE → evict + fallback")
            vscodeAXCache.removeValue(forKey: wid)
        } else {
            jumpDiag("matched wid=\(wid) but no cached AX element → open fallback")
        }
        // No usable element (window never seen on a current Space since launch, or its
        // a11y object was rebuilt). `open -b` makes the editor SELF-activate and focus the
        // window owning this folder — self-activation is the one activation macOS follows
        // across Spaces (the native-terminal/`NSApp.activate` formula); a cross-app
        // NSRunningApplication.activate() would neither switch Space nor front an
        // off-Space window. Once the jump lands, the next 2.5s scan caches this Space's
        // elements, so future jumps take the fast cached-raise path (self-healing).
        openInEditor(editor.rawValue, cwd)
        // The title match still names the target window; `open` just gets us there by a
        // different route. Returning it lets the ring aim at that window rather than
        // "whatever is focused" (pollWindow falls back to the focused window anyway when
        // the wid can't be resolved on this Space).
        return wid
    }

    // VSCode titles look like "file.ext — RootName — Visual Studio Code", joined by the
    // title separator (default em-dash, customizable to "-"/"|"). Split a title into its
    // segments so we can compare the workspace-root segment to a folder name EXACTLY. A
    // loose substring test mis-fires: a generic subdir like "web" is a substring of another
    // project's title "web-dashboard". Exact-segment match skips that false hit and keeps
    // walking up to the real root ("myapp"). We split only on whole separators (em/en-dash,
    // pipe) — never bare "-", which appears inside folder names like "vscode-extension" —
    // and also treat the whole trimmed title as one segment so plain single-folder titles
    // ("myapp") still match.
    // Of the windows a title match accepted, the one whose open document actually lives
    // under `cwd` — the only thing that separates two worktrees with identical titles.
    // Pure tie-breaker: with one candidate, or none carrying a usable document, this is
    // exactly the old first-match, so it can never make a previously-correct jump wrong.
    private func pickByDoc(_ hits: [(wid: CGWindowID, title: String)], cwd: String) -> CGWindowID? {
        if hits.count > 1,
           let m = hits.first(where: { WindowFolderResolve.isUnder(vscodeWindowDoc[$0.wid], cwd) }) { return m.wid }
        return hits.first?.wid
    }

    private func titleSegments(_ title: String) -> [String] {
        var segs = title.components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        segs.append(title.trimmingCharacters(in: .whitespaces))
        return segs.filter { !$0.isEmpty }
    }

    // MARK: Private CGS — cross-Space window control
    //
    // SkyLight/CoreGraphics has long-stable private symbols for reading a window's Space
    // and switching the active Space (the same ones yabai/AltTab use). We resolve them
    // by name at runtime; if any is missing on a future macOS, switchToSpace just no-ops
    // and the jump degrades to a plain activate rather than crashing.
    private typealias CGSIntFn = @convention(c) () -> Int32
    private typealias CGSDispForWinFn = @convention(c) (Int32, CGWindowID) -> Unmanaged<CFString>?
    private typealias CGSSpacesFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CGSSetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
    // SLPS front-process focus (see slpsFocusWindow): front a specific window across Spaces
    // by injecting a WindowServer event, letting macOS follow — the AltTab/yabai/Amethyst way.
    private typealias SLPSSetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias SLPSPostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private lazy var cgHandle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    // SLPS/SLS symbols live in SkyLight on modern macOS (CoreGraphics only re-exports some).
    private lazy var skyHandle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private lazy var cgsConn: Int32 = {
        guard let h = cgHandle, let s = dlsym(h, "CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(s, to: CGSIntFn.self)()
    }()

    private typealias CGSCopyManagedSpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    // True when this display currently shows a FULLSCREEN Space. That's the one case
    // where the menu bar is hidden at rest yet every public signal lies about it:
    // visibleFrame keeps reserving the bar's band (probed: 25pt gap persists) and
    // menuBarVisible() stays true — so the popover was left floating below a bar that
    // isn't there. CGS "Current Space" type 4 = fullscreen; dlsym'd with graceful
    // false fallback like the other CGS calls.
    private func isFullscreenSpace(display: CGDirectDisplayID) -> Bool {
        guard cgsConn != 0, let sym = cgsSym("CGSCopyManagedDisplaySpaces") else { return false }
        let fn = unsafeBitCast(sym, to: CGSCopyManagedSpacesFn.self)
        guard let arr = fn(cgsConn)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let uuid = CGDisplayCreateUUIDFromDisplayID(display).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        for d in arr {
            let ident = d["Display Identifier"] as? String
            // Single-display setups report the literal identifier "Main".
            guard ident == uuid || (ident == "Main" && display == CGMainDisplayID()),
                  let cur = d["Current Space"] as? [String: Any] else { continue }
            return (cur["type"] as? Int) == 4
        }
        return false
    }

    private func switchToSpace(of wid: CGWindowID) {
        guard let h = cgHandle, cgsConn != 0,
              let dispSym = dlsym(h, "CGSCopyManagedDisplayForWindow"),
              let spacesSym = dlsym(h, "CGSCopySpacesForWindows"),
              let setSym = dlsym(h, "CGSManagedDisplaySetCurrentSpace") else {
            NSLog("TB space: CGS symbols NOT found (cg=%@)", cgHandle == nil ? "nil" : "ok")
            return }
        let dispForWin = unsafeBitCast(dispSym, to: CGSDispForWinFn.self)
        let copySpaces = unsafeBitCast(spacesSym, to: CGSSpacesFn.self)
        let setSpace = unsafeBitCast(setSym, to: CGSSetSpaceFn.self)
        // 0x7 = all space types (user + fullscreen + system).
        guard let disp = dispForWin(cgsConn, wid)?.takeRetainedValue(),
              let spaces = copySpaces(cgsConn, 0x7, [wid] as CFArray)?.takeRetainedValue() as? [UInt64],
              let space = spaces.first else { return }
        setSpace(cgsConn, disp, space)
    }

    // Cross-Space focus WITHOUT switching Spaces: the front-process event sequence AltTab,
    // yabai and Amethyst all converge on. _SLPSSetFrontProcessWithOptions fronts the process
    // + the specific window (wid); two synthesized key-window events make WindowServer treat
    // it as key; the public AX raise back in raiseVSCodeWindow orders it within the app.
    // macOS follows to the window's Space on its own — no CGSManagedDisplaySetCurrentSpace
    // (locked down), no window move. Accessibility only, no Screen Recording, no SIP. dlsym'd
    // with graceful no-op fallback like switchToSpace.
    private func slpsFocusWindow(pid: pid_t, wid: CGWindowID) {
        guard let frontSym = cgsSym("_SLPSSetFrontProcessWithOptions"),
              let postSym = cgsSym("SLPSPostEventRecordTo") else {
            NSLog("TB slps: symbols NOT found (sky=%@ cg=%@)",
                  skyHandle == nil ? "nil" : "ok", cgHandle == nil ? "nil" : "ok")
            return }
        let setFront = unsafeBitCast(frontSym, to: SLPSSetFrontFn.self)
        let postEvent = unsafeBitCast(postSym, to: SLPSPostEventFn.self)

        var psn = ProcessSerialNumber()
        guard TB_GetProcessForPID(pid, &psn) == noErr else { return }

        // Front the process AND the specific window. 0x200 = kCPSUserGenerated.
        _ = setFront(&psn, wid, 0x200)

        // Two synthesized "key window" events carrying wid. The record's declared length is
        // 0xf8, but WindowServer on macOS 14.7.4+ reads past it and SIGABRTs a short buffer,
        // so we allocate 0x100 (AltTab #4507/#5586). Byte layout from yabai/Amethyst:
        // [0x04]=0xf8, [0x08]=event code (0x01 then 0x02), [0x3a]=0x10, [0x20..0x30]=0xff,
        // wid little-endian at [0x3c].
        for code: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0x100)
            bytes[0x04] = 0xf8
            bytes[0x08] = code
            bytes[0x3a] = 0x10
            for i in 0x20..<0x30 { bytes[i] = 0xff }
            withUnsafeBytes(of: wid.littleEndian) { raw in
                for j in 0..<4 { bytes[0x3c + j] = raw[j] }
            }
            _ = postEvent(&psn, bytes)
        }
    }

    // Resolve a private WindowServer symbol — SkyLight first (that's where SLPS/CGS live on
    // modern macOS), CoreGraphics as fallback. Shared by SLPS focus and Plan-B enumeration.
    private func cgsSym(_ name: String) -> UnsafeMutableRawPointer? {
        if let h = skyHandle, let s = dlsym(h, name) { return s }
        if let h = cgHandle, let s = dlsym(h, name) { return s }
        return nil
    }

    // Accessibility is the one permission this app needs: raiseVSCodeWindow uses
    // kAXRaiseAction to bring the target VSCode window forward even when VSCode is
    // already frontmost. Without it, jumping falls back to `open`, which can't raise
    // a window across monitors / a fullscreen Space while VSCode is already active —
    // the click feels dead. So we explain exactly what's gated (rather than popping
    // the bare system prompt) and route the user straight to the settings pane.
    //
    // Shown at most once per session (`promptedForAX`); once granted, AXIsProcessTrusted
    // is true and this never fires again. A persistent menu item (added while untrusted)
    // lets the user re-open this if they dismissed it.
    private var promptedForAX = false

    /// Drop this build's own Accessibility record so the user's next toggle writes a
    /// fresh one.
    ///
    /// That switch is bound to a stored CODE REQUIREMENT, not to the app's name. A
    /// record left behind by a different copy — another signing identity, another
    /// path, a bundle id LaunchServices no longer resolves to any app — keeps reading
    /// as ON while granting this process nothing, and flipping it by hand only
    /// re-applies the same dead requirement. Dropping the record is the only way out,
    /// and tccutil is the only thing that can do it.
    ///
    /// There is deliberately no counterpart that grants one back: macOS has no API for
    /// that (a program that could authorize itself would defeat TCC entirely). This
    /// clears the way for the user's own click, nothing more.
    ///
    /// Synchronous on purpose — whatever prompts next has to see the record already
    /// gone, or the system stays silent because it still thinks it has an answer.
    /// Callers must first confirm AX is actually broken: run against a working grant,
    /// this throws it away.
    static func resetAccessibilityGrant() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        spawnDisclaimed(["/usr/bin/tccutil", "reset", "Accessibility", id])
    }

    // Guarded entry: fires at most once per session and only while untrusted. Used by
    // launch and the jump fallback so a dead click doesn't nag on every attempt.
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !promptedForAX else { return }
        promptedForAX = true
        presentAccessibilityPrompt()
    }

    // Force entry: the menu item ("⚠️ 开启跳转权限") always re-opens this.
    @objc private func presentAccessibilityPrompt() {
        // Granted on paper, dead in practice (see AppController.axDegraded): the switch IS
        // on, so telling the user to turn it on reads as a bug in us. macOS won't let us
        // re-grant it, but we can drop the dead record on the way out (below) so their
        // click lands on a fresh one instead of re-applying the same broken requirement.
        if AXIsProcessTrusted() {
            guard Self.axDegraded else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("「辅助功能」权限已失效", "Accessibility permission has gone stale")
            alert.informativeText = L(
                """
                系统设置里 SpectiX 的「辅助功能」开关看着是开的，但实际读不到任何窗口 —— macOS 上的已知问题，通常发生在 App 重新安装 / 更新之后（授权记录对不上新的签名）。

                ⚠️ 现在受影响：
                • Claude 桌面版（Claude App / Claude Design）那几行只显示「闲置」，或整组消失
                • 点列表跳转跨屏 / 跨全屏 Space 的窗口不准

                ✅ 修法：点下面的「打开辅助功能设置」—— 失效的那条授权会被自动清掉，你只需在打开的列表里把 SpectiX 重新打开一次。
                """,
                """
                SpectiX's Accessibility switch looks enabled in System Settings, but no window can actually be read — a known macOS issue, usually after the app is reinstalled or updated (the stored grant no longer matches the new signature).

                ⚠️ Affected right now:
                • The Claude desktop rows (Claude App / Claude Design) sit at Idle, or vanish entirely
                • Clicking a row can't reach a window on another screen / full-screen Space

                ✅ Fix: click "Open Accessibility settings" below — the dead grant is cleared for you, and all you have to do is switch SpectiX back on in the list that opens.
                """)
            alert.addButton(withTitle: L("打开辅助功能设置", "Open Accessibility settings"))
            alert.addButton(withTitle: L("稍后", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                // This branch only runs when the switch reads on and AX still returns
                // nothing, so the stored record is the problem by definition — drop it
                // rather than sending the user to toggle the same dead one back on.
                Self.resetAccessibilityGrant()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("需要开启「辅助功能」权限", "Accessibility permission needed")
        alert.informativeText = L(
            """
            SpectiX 需要「辅助功能」权限，才能在你点击会话时把对应的 VSCode 窗口抬到最前 —— 尤其是跨显示器、或目标窗口在另一个全屏 Space 时。

            ⚠️ 未开启时无法使用：
            • 点列表 / 通知横幅跳转到另一台屏幕（或全屏）上的 VSCode 窗口
            • 多窗口时只能切到当前最前那个，点谁都跳不准

            ✅ 不受影响：状态监控、通知横幅、提示音照常工作。

            开启：系统设置 → 隐私与安全性 → 辅助功能 → 打开 SpectiX。
            """,
            """
            SpectiX needs Accessibility permission to bring the matching VSCode window to the front when you click a session — especially across displays, or when the target window sits in another full-screen Space.

            ⚠️ Without it:
            • Clicking a row / notification banner can't reach a VSCode window on another screen (or in full screen)
            • With several windows open, only the frontmost one is reachable — every click lands on the wrong one

            ✅ Unaffected: status monitoring, notification banners and sounds keep working.

            To enable: System Settings → Privacy & Security → Accessibility → turn on SpectiX.
            """)
        alert.addButton(withTitle: L("打开辅助功能设置", "Open Accessibility settings"))
        alert.addButton(withTitle: L("稍后", "Later"))
        let openSettings = alert.runModal() == .alertFirstButtonReturn

        // No AXIsProcessTrustedWithOptions(prompt:true) here — that pops a *second*,
        // redundant system dialog on top of this explainer. SpectiX is already
        // registered in the Accessibility list by its ambient AX usage (prewarm /
        // scanVSCodeWindows run before this), so we just deep-link to the pane.
        if openSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // The companion extension is installed when its folder exists under the editor's
    // extensions dir (~/.vscode|.cursor|.windsurf/extensions, "spectix.focus-<version>").
    //
    // The pre-rename id (taskbeacon.focus-*) deliberately does NOT count (T172): that
    // build watches ~/.claude/taskbeacon/focus-request, which this app no longer writes,
    // so it is present-but-dead. Counting it would report the feature as installed while
    // every jump silently does nothing — the installer is what removes it.
    private func extensionInstalled(_ editor: EditorApp) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: editor.extDir)
        else { return false }
        return names.contains { $0.hasPrefix("spectix.focus") }
    }

    // On disk is not running (T226 E3, both directions): an editor loads extensions at
    // window startup, so a freshly installed one serves nothing until the window is
    // reloaded — and a deleted one keeps running until the editor quits. The pane path
    // needs the RUNNING answer, and the only honest source for it is the extension's own
    // output: each live host rewrites terminals-<hostPid>.json every ~2s listing the
    // shell pids of the terminals it can see. A terminal in that list has a host that
    // will answer a focus-request and write the token the ring waits for.
    private func extensionServing(shellPid: pid_t) -> Bool {
        CompanionExtension.liveManifests().contains { $0.shellPids.contains(shellPid) }
    }

    // Any live host at all belonging to this editor (the host's top-level app).
    private func extensionServing(_ editor: EditorApp) -> Bool {
        CompanionExtension.liveManifests().contains {
            hostAppBundleId(forClaudePid: $0.hostPid) == editor.rawValue
        }
    }

    // Computed, not stored: L() reads the language setting at call time, and a stored
    // string would keep the language the first jump happened in.
    static var reloadHintCaption: String {
        L("按 \(SettingsPane.reloadShortcut) 开启高亮",
          "\(SettingsPane.reloadShortcut) to enable highlights")
    }

    /// Say once per version that the editor has to be reloaded before highlights work.
    ///
    /// This is the one thing a fresh install cannot do for the user, and the failure it
    /// prevents is invisible: the jump still lands on the right terminal, so nothing
    /// looks broken except a ring that never appears (T226). The installer says it too,
    /// on its finish screen — but that screen is gone by the time anyone jumps, and a
    /// hand-copied app never showed it at all.
    ///
    /// Only for editors that actually have the extension on disk. Someone who never
    /// installed it has nothing to reload, and telling them to would send them looking
    /// for a setting that isn't the problem.
    ///
    /// And only while the state is really "installed but not loaded": the editor is
    /// running and no live host of it lists any terminal (T229). An editor that isn't
    /// open will load the extension when it starts; one whose hosts already report has
    /// nothing to reload — and an app-version bump used to re-fire this at both of them.
    /// The once-per-version flag is consumed only when the alert actually shows, so a
    /// launch that skipped it leaves the next one free to judge again.
    private func maybeShowEditorReloadHint() {
        let installed = EditorApp.allCases.filter { editor in
            extensionInstalled(editor)
                && !NSRunningApplication.runningApplications(withBundleIdentifier: editor.rawValue).isEmpty
                && !extensionServing(editor)
        }
        guard !installed.isEmpty, AppSettings.consumeEditorReloadHint() else { return }

        let names = installed.map { editor -> String in
            switch editor {
            case .vscode:   return "VS Code"
            case .cursor:   return "Cursor"
            case .windsurf: return "Windsurf"
            }
        }.joined(separator: L("、", ", "))

        // After the status item and window exist. An alert thrown up mid-launch has
        // nothing behind it and reads as a crash report rather than a tip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            // The keystroke goes in messageText, which AppKit sets bold and large — so
            // the one thing to actually do is emphasised without an accessory view, and
            // a reader who bails after the first line still got the whole instruction.
            alert.messageText = L("在 \(names) 里按 \(SettingsPane.reloadShortcut)，高亮才会出现",
                                  "Press \(SettingsPane.reloadShortcut) in \(names) to switch highlights on")
            alert.informativeText = L(
                "编辑器启动时才读取扩展，已经开着的窗口还没加载它。在那之前跳转照常，只是没有落点高亮圈。",
                "Editors load extensions at startup, so a window that was already open hasn't picked it up. Until then jumps still work — they just land without the ring.")
            alert.addButton(withTitle: L("知道了", "Got it"))
            alert.runModal()
        }
    }

    // ★ Every `open -b <editor> <folder>` goes through here, NEVER through run() directly
    // (the "凭空冒出一个 Untitled (Workspace) 窗口" bug, 2026-08-26).
    // `open` delivers an odoc AppleEvent, and VSCode BATCHES the ones that arrive close
    // together: two DIFFERENT folders in one batch do not open as two folder windows —
    // they open as ONE multi-root "Untitled (Workspace)" window holding both. That window
    // then also drops out of the list, because its title carries no folder name and every
    // window→path lookup here is title-based (openProjectsWithoutSessions,
    // raiseEditorWindow). So the user sees a workspace window appear by itself AND a
    // project go missing, from one mis-timed pair of opens.
    // Measured 2026-08-26: two back-to-back opens merged into one workspace every time;
    // the same two 400ms apart did not merge. Two opens landing that close together is
    // ordinary — an auto-jump's open fallback while a click fires another, or a fast
    // double click — so serialize them with a gap comfortably above the batch window.
    // Main-thread only (owns the queue state, same contract as its callers).
    private static let editorOpenGap: TimeInterval = 0.6
    private var editorOpenDue: TimeInterval = 0      // earliest time the next open may fire
    private var editorOpenPending = Set<String>()    // bundle+path already queued

    private func openInEditor(_ bundleID: String, _ path: String) {
        let key = "\(bundleID)\u{0}\(path)"
        // A second click on the same row would otherwise queue a second open that lands
        // 0.6s later on a window that is already front: lag with no effect.
        guard !editorOpenPending.contains(key) else { return }
        let now = Date().timeIntervalSince1970
        let due = max(now, editorOpenDue + Self.editorOpenGap)
        editorOpenDue = due
        guard due > now else {                       // idle queue → the click stays instant
            run("/usr/bin/open", ["-b", bundleID, path])   // via openInEditor
            return
        }
        editorOpenPending.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + (due - now)) { [weak self] in
            self?.editorOpenPending.remove(key)
            self?.run("/usr/bin/open", ["-b", bundleID, path])   // via openInEditor
        }
    }

    private func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
    }

    // Wire the popover controller's callbacks. Extracted so a language switch can
    // rebuild the controller and re-attach them.
    private func wirePopover() {
        popoverController.onJump         = { [weak self] row in self?.popover.performClose(nil); self?.focus(row) }
        popoverController.onOpenWindow   = { [weak self] in self?.popover.performClose(nil); self?.openMainWindow() }
        popoverController.onOpenStats    = { [weak self] in self?.popover.performClose(nil); self?.openStats() }
        popoverController.onOpenRecent   = { [weak self] in self?.popover.performClose(nil); self?.openRecentProjects() }
        popoverController.onOpenSettings = { [weak self] in self?.popover.performClose(nil); self?.openSettings() }
        popoverController.onFixPermission = { [weak self] in self?.popover.performClose(nil); self?.presentAccessibilityPrompt() }
    }

    // Rebuild both surfaces after a language change so every statically-built label
    // re-resolves through L() in the new language. The menu-bar button/toasts read
    // L() live, so they need no explicit rebuild — a refresh() repaints them.
    @objc private func languageDidChange() { rebuildUIWholesale() }

    @objc private func themeDidChange() { rebuildUIWholesale() }

    // Tear the windows down and build them again from scratch. The only remedy for
    // a change that was baked into views at construction time and cannot be
    // re-rendered in place — localized text (languageDidChange) and theme colors /
    // radii / material (themeDidChange). Both switches are made from the settings
    // pane, so a visible window reopens there.
    //
    // The always-on focus rings live in overlay windows on OTHER apps and are not
    // touched here; they re-tint themselves off the trailing refresh(), which
    // compares each overlay's RESOLVED accent hex rather than its status string —
    // so a new palette under an unchanged status still counts as a change.
    private func rebuildUIWholesale() {
        let wasVisible = mainWindowController?.isShown ?? false
        mainWindowController?.closeForRebuild()   // a real teardown, not the red button's hide
        mainWindowController = nil
        popover.performClose(nil)
        popoverController = MenuPopoverController(model: model)
        popover.contentViewController = popoverController
        wirePopover()
        if wasVisible { showMainWindow(tab: .settings) }
        refresh()
    }

    @objc private func openMainWindow() { showMainWindow() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Main window

    private func showMainWindow(tab: MainTab = .sessions) {
        if mainWindowController == nil {
            let wc = MainWindowController(model: model)
            wc.onJump = { [weak self] row in self?.focus(row) }
            wc.onOpenProject = { [weak self] path in self?.openProject(path) }
            wc.onRebindHotKey = { [weak self] action, combo in self?.rebindHotKey(action, combo) ?? noErr }
            mainWindowController = wc
        }
        usage = loadUsage()   // fresh on open; also feeds the menu-bar quota suffix
        requestUsageProbe(minAge: usageOutdatedBySwitch ? 15 : 60)
        SystemMonitor.shared.sample()   // baseline now, so the CPU row reads on the next poll
        let hdr = headerAgentInfo(rows: rows)
        mainWindowController?.reload(rows, usage: hdr.claudeUsage, header: hdr)
        mainWindowController?.showTab(tab)   // deep-link + refresh the target tab's pane
        // Returning to a put-away window is a SPACE SWITCH, not a window move: it was
        // parked in place (alpha 0, still ordered-in — see MainWindowController.isParked)
        // precisely so it kept the Space it was left on. Switch there before ordering it
        // front rather than leaning on macOS's "switch to a Space with open windows"
        // preference, which the user can turn off. Same graceful no-op as the jump path
        // if the CGS symbols ever vanish — you'd just land where the old build did.
        if let wc = mainWindowController, wc.isParked, let wid = wc.window?.windowNumber, wid > 0 {
            switchToSpace(of: CGWindowID(wid))
        }
        mainWindowController?.showWindow(nil)
        ensureWindowOnScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    // A stale restored frame (AppSettings.mainWindowFrame) can put the window onto a
    // display that's since been disconnected, stranding it off-screen where it can't
    // be seen or focused. If its frame doesn't intersect any active screen, recenter
    // it on the main one.
    private func ensureWindowOnScreen() {
        guard let window = mainWindowController?.window else { return }
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onScreen { window.center() }
    }

    // Stay alive when AppKit's "last window" bookkeeping trips — the transient panels
    // (toasts, focus rings, popover anchor) come and go constantly, and quitting on
    // theirs would kill a menu-bar-only session. The main window never quits either:
    // its red button hides it (MainWindowController.windowShouldClose). Quitting is
    // the status item's right-click menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon reopens the main window. `flag` can't be trusted here: it
    // counts the transient panels (toasts, focus rings, popover anchor) as "visible
    // windows", so a hidden main window plus a live toast would report true and leave
    // the Dock icon feeling dead. Decide on the main window itself instead — it's the
    // only window a reopen is ever about.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindowController?.isShown != true { showMainWindow() }
        return true
    }

    // ⌘Tab and menu-bar clicks activate the app without passing through showMainWindow.
    // A put-away window is still ordered-in (parked at alpha 0 so it keeps its Space —
    // see MainWindowController.isParked), so AppKit brings it forward on activation,
    // switching Spaces to reach a window the user cannot see. Un-park it here so the
    // Space it pulls you to actually has the window on it. The popover deliberately
    // never activates the app, so this can't fire behind it.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let wc = mainWindowController, wc.isParked else { return }
        showMainWindow(tab: wc.currentTab)
    }
}

// MARK: - Popover lifecycle

extension AppController: NSPopoverDelegate {
    // Every close path funnels through here (outside click, jump, action button),
    // so tear the global monitor down in one place.
    func popoverDidClose(_ notification: Notification) {
        popoverLog("didClose")
        if let m = popoverClickMonitor { NSEvent.removeMonitor(m); popoverClickMonitor = nil }
        if let m = popoverKeyMonitor { NSEvent.removeMonitor(m); popoverKeyMonitor = nil }
        popoverClampTimer?.invalidate(); popoverClampTimer = nil
        // Drop the anchor entirely, don't just hide it — a panel kept between opens is
        // what goes stale across sleep/wake (see the popoverAnchor property).
        popoverAnchor?.orderOut(nil)
        popoverAnchor = nil
        // The bar our popover revealed takes ~1s to slide back; hold off band sampling
        // so a poll landing in that window can't freeze the revealed height as resting.
        menuBandHoldUntil = Date().addingTimeInterval(3)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
// Carry a pre-rename install over before anything can read a setting — AppController
// touches AppSettings while it is still building itself. No-ops on every launch after
// the first, and on every machine that never ran the old name.
Migration.runIfNeeded()
let controller = AppController()
app.delegate = controller
app.run()
