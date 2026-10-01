const vscode = require('vscode');
const os = require('os');
const path = require('path');

// SpectiX focuses the exact integrated terminal of a Claude session.
//
// The app writes the target shell pid to ~/.claude/spectix/focus-request. EVERY
// open VSCode window runs this extension and watches that one file, so a single
// write wakes all windows; only the window that actually owns a terminal whose
// `processId` == pid reveals it — and revealing a terminal brings its window to
// the front. This is why focus works across multiple windows.
//
// The old `vscode://spectix.focus/focus?pid=<pid>` URI is delivered to
// only the last-active window, so it can't reach a terminal living in another
// window. It's still handled here for backward compatibility with older app
// builds, but the app now uses the file-watch path above.

const FOCUS_DIR = path.join(os.homedir(), '.claude', 'spectix');
const FOCUS_FILE = 'focus-request';
const ACTIVE_FILE = 'active-terminal';
const OPEN_TERM_FILE = 'open-terminal-request';
// Same broadcast trick for the Claude Code chat panel (sidebar / tab / window), which
// is not a terminal and so can't be revealed by pid. The app writes the pid of the
// extension host that owns the panel; every window reads it and only the one whose
// own process.pid matches focuses its chat input.
const CHAT_FOCUS_FILE = 'chat-focus-request';
// Which editor WINDOW the user is in, as "<extensionHostPid>:<nonce>". The app pairs
// this with its own accessibility-tree read to follow chat-panel focus in the list:
// the a11y tree can tell that a Claude Code panel holds focus, but names only the
// Code MAIN process, while a chat session's shellPid is its extension host — one per
// window. Neither half can answer alone. Same pid this file already keys the terminal
// manifest on, so a chat row and its window agree without further plumbing.
const ACTIVE_WINDOW_FILE = 'active-window';
// Per-window terminal manifest for the app's always-on rings. The app locates
// terminal panes via the macOS accessibility tree, which exposes each pane's
// on-screen frame + its VSCode tab name — but NOT its shell pid. This file
// bridges the gap: "<name>" (as shown in the tab) -> shell pid, so the app can
// map a located pane to the Claude session that owns it. Keyed by the extension
// host's pid so each VSCode window writes its own file; the app merges them all.
const TERMINALS_FILE = `terminals-${process.pid}.json`;
// This window's open folders, so SpectiX never has to guess which project a title
// means. A title carries the folder NAME only, and two git worktrees of one repo are
// byte-identical from outside. Deliberately its own file: four readers parse
// TERMINALS_FILE as a bare array, and mixed extension versions run side by side.
const WINDOW_FILE = `window-${process.pid}.json`;
// A request older than this is stale (e.g. re-read when the user reopens the
// same project by hand later). Generous because a cold VSCode launch — app
// start + window restore + extension host boot — can take a while.
const OPEN_TERM_MAX_AGE_SEC = 120;

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      handleUri(uri) {
        if (uri.path !== '/focus') return;
        const pid = parseInt(new URLSearchParams(uri.query).get('pid') || '', 10);
        if (Number.isInteger(pid)) focusByPid(pid);
      },
    })
  );

  // Watch the request file. RelativePattern with an absolute base lets us watch a
  // path outside the workspace; the watcher lives in every window's extension
  // host, so all windows react to a single write.
  const watcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(vscode.Uri.file(FOCUS_DIR), FOCUS_FILE)
  );
  watcher.onDidCreate(handleFocusRequest);
  watcher.onDidChange(handleFocusRequest);
  context.subscriptions.push(watcher);

  const chatWatcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(vscode.Uri.file(FOCUS_DIR), CHAT_FOCUS_FILE)
  );
  chatWatcher.onDidCreate(handleChatFocusRequest);
  chatWatcher.onDidChange(handleChatFocusRequest);
  context.subscriptions.push(chatWatcher);

  // SpectiX just opened a project from the 最近项目 window and wants its
  // integrated terminal ready. Every window watches the same request file;
  // only the one whose workspace folder matches the requested path acts.
  const termWatcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(vscode.Uri.file(FOCUS_DIR), OPEN_TERM_FILE)
  );
  termWatcher.onDidCreate(handleOpenTerminalRequest);
  termWatcher.onDidChange(handleOpenTerminalRequest);
  context.subscriptions.push(termWatcher);
  // A freshly opened window's extension host boots AFTER SpectiX wrote the
  // request, so the watcher never fires for the very window the request is
  // for — check the file once on activation (the ts guard drops stale ones).
  handleOpenTerminalRequest();

  // Report the terminal the user just focused, so the app can auto-dismiss that
  // session's toast — going to the terminal yourself is the same as clicking the
  // banner. Fires when the active terminal changes, and when this window regains
  // focus (the user switched back to it to deal with its Claude session).
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTerminal((term) => {
      reportActiveTerminal(term);
      scheduleManifestWrite();
    }),
    vscode.window.onDidChangeWindowState((state) => {
      if (!state.focused) return;
      reportActiveTerminal(vscode.window.activeTerminal);
      reportActiveWindow();
    })
  );
  // The window that owns the extension host we're running in may already be focused
  // when we activate (VSCode restores a window, then boots extensions), and no state
  // change will fire for it — report once so the app isn't blind until the next switch.
  if (vscode.window.state.focused) reportActiveWindow();

  // Keep the terminal manifest (name -> shell pid) current so the app's rings can
  // resolve every visible pane. Rewrite on open/close and — because VSCode fires
  // no event when a terminal's title changes (Claude updates "✳ <task>" as work
  // moves) — on a light interval too. Writes are debounced and cheap (name is
  // sync; processId resolves once then caches). Deleted on deactivate.
  context.subscriptions.push(
    vscode.window.onDidOpenTerminal(() => scheduleManifestWrite()),
    vscode.window.onDidCloseTerminal(() => scheduleManifestWrite())
  );
  manifestInterval = setInterval(scheduleManifestWrite, 2000);
  scheduleManifestWrite();
}

let manifestTimer = null;
let manifestInterval = null;

// Debounce a manifest write; coalesces the burst of events a layout change fires.
function scheduleManifestWrite() {
  if (manifestTimer) return;
  manifestTimer = setTimeout(() => {
    manifestTimer = null;
    writeManifest();
  }, 300);
}

// Snapshot this window's terminals as [{pid, name}] and write the manifest.
async function writeManifest() {
  const entries = [];
  for (const term of vscode.window.terminals) {
    let pid;
    try {
      pid = await term.processId;
    } catch {
      continue;
    }
    if (!Number.isInteger(pid)) continue;
    entries.push({ pid, name: term.name });
  }
  try {
    await vscode.workspace.fs.writeFile(
      vscode.Uri.file(path.join(FOCUS_DIR, TERMINALS_FILE)),
      Buffer.from(JSON.stringify(entries), 'utf8')
    );
  } catch {
    /* best-effort */
  }
  try {
    await vscode.workspace.fs.writeFile(
      vscode.Uri.file(path.join(FOCUS_DIR, WINDOW_FILE)),
      Buffer.from(
        JSON.stringify({
          folders: (vscode.workspace.workspaceFolders || [])
            .filter((f) => f.uri.scheme === 'file')
            .map((f) => f.uri.fsPath),
        }),
        'utf8'
      )
    );
  } catch {
    /* best-effort */
  }
}

// Write "<shellPid>:<nonce>" to active-terminal. The nonce (a timestamp) makes
// every focus a distinct write so the app acts only on genuine new focus events,
// never on a stale value re-read when some other file in the dir changes.
async function reportActiveTerminal(term) {
  if (!term) return;
  let pid;
  try {
    pid = await term.processId;
  } catch {
    return;
  }
  if (!Number.isInteger(pid)) return;
  try {
    await vscode.workspace.fs.writeFile(
      vscode.Uri.file(path.join(FOCUS_DIR, ACTIVE_FILE)),
      Buffer.from(`${pid}:${Date.now()}`, 'utf8')
    );
  } catch {
    /* best-effort */
  }
}

// Announce that this window is the one the user is in. Nonce for the same reason
// reportActiveTerminal has one: a distinct write every time, so the app reacts to a
// genuine focus change rather than to a stale value re-read when a sibling file moves.
async function reportActiveWindow() {
  try {
    await vscode.workspace.fs.writeFile(
      vscode.Uri.file(path.join(FOCUS_DIR, ACTIVE_WINDOW_FILE)),
      Buffer.from(`${process.pid}:${Date.now()}`, 'utf8')
    );
  } catch {
    /* best-effort */
  }
}

async function handleFocusRequest() {
  let text;
  try {
    const bytes = await vscode.workspace.fs.readFile(
      vscode.Uri.file(path.join(FOCUS_DIR, FOCUS_FILE))
    );
    text = Buffer.from(bytes).toString('utf8');
  } catch {
    return;
  }
  // Content is "<pid>:<nonce>"; the nonce only exists to force a distinct write
  // so the watcher fires even when the same session is focused twice in a row.
  const pid = parseInt(text.split(':')[0].trim(), 10);
  if (Number.isInteger(pid)) focusByPid(pid);
}

// Focus this window's Claude Code chat input when the request names our extension
// host. `claude-vscode.focus` ("Claude Code: Focus input") is a contributed command of
// Anthropic's official extension; it reveals whichever panel this window holds
// (sidebar, tab, or its own window). When one window holds SEVERAL panels they share
// this pid, so the jump can only land on the window — that limitation is by design.
async function handleChatFocusRequest() {
  let text;
  try {
    const bytes = await vscode.workspace.fs.readFile(
      vscode.Uri.file(path.join(FOCUS_DIR, CHAT_FOCUS_FILE))
    );
    text = Buffer.from(bytes).toString('utf8');
  } catch {
    return;
  }
  // "<extensionHostPid>:<nonce>" — the nonce only forces a distinct write.
  const pid = parseInt(text.split(':')[0].trim(), 10);
  if (pid !== process.pid) return;
  try {
    await vscode.commands.executeCommand('claude-vscode.focus');
  } catch {
    /* extension not installed in this window — nothing to focus */
  }
}

// Reveal (or create) this window's integrated terminal when the request is
// fresh and targets one of our workspace folders.
async function handleOpenTerminalRequest() {
  let req;
  try {
    const bytes = await vscode.workspace.fs.readFile(
      vscode.Uri.file(path.join(FOCUS_DIR, OPEN_TERM_FILE))
    );
    req = JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch {
    return;
  }
  if (!req || typeof req.path !== 'string' || typeof req.ts !== 'number') return;
  if (Date.now() / 1000 - req.ts > OPEN_TERM_MAX_AGE_SEC) return;
  const mine = (vscode.workspace.workspaceFolders || []).some(
    (f) => f.uri.fsPath === req.path
  );
  if (!mine) return;
  const term =
    vscode.window.activeTerminal ??
    vscode.window.terminals[0] ??
    vscode.window.createTerminal();
  term.show(false); // preserveFocus=false → cursor lands in the terminal
}

async function focusByPid(pid) {
  for (const term of vscode.window.terminals) {
    let tpid;
    try {
      tpid = await term.processId;
    } catch {
      continue;
    }
    if (tpid === pid) {
      term.show(false); // preserveFocus=false → terminal takes keyboard focus
      // Report the focus directly rather than relying on onDidChangeActiveTerminal:
      // when this terminal is ALREADY the window's active terminal (the common case —
      // you were just there, or it's the only terminal), term.show() fires no change
      // event, so the app would never learn the session was focused and a "done" row
      // would stay green forever. A direct write (fresh nonce) always reaches the app.
      reportActiveTerminal(term);
      return;
    }
  }
}

function deactivate() {
  // Stop refreshing and remove this window's files so the app doesn't map panes
  // against a dead window's stale terminals, or draw a header for a folder whose
  // window closed.
  if (manifestInterval) clearInterval(manifestInterval);
  if (manifestTimer) clearTimeout(manifestTimer);
  // Spelled out rather than looped so that each path stays a literal join of the
  // state dir and a named constant — tools/web-check.py reads these to check the
  // /security table, and a loop variable reads to it as a file called `f`.
  for (const p of [path.join(FOCUS_DIR, TERMINALS_FILE), path.join(FOCUS_DIR, WINDOW_FILE)]) {
    try {
      require('fs').unlinkSync(p);
    } catch {
      /* already gone */
    }
  }
}

module.exports = { activate, deactivate };
