#!/usr/bin/env python3
"""Cold-start a codex TUI in a fresh pty and report whether ANY hook rewrote
state-<tty> before the first prompt (T283).

The pty is pre-seeded with a stale "done" state, exactly what a terminal inherits from
the session that used it before. Exit 0 only if the SessionStart hook overwrote it
with "idle" during startup. On codex-cli 0.151.0 it exits 1: Codex defers SessionStart
to the first prompt, which is why the app ignores a codex row's pre-launch state
(InheritedState.swift). Rerun after a Codex upgrade — exit 0 means Codex started
firing it at launch. Needs codex logged in and the SpectiX hooks installed + approved
in ~/.codex (/hooks); sends nothing to the model.

usage: tools/codex-sessionstart-probe.py [seconds=15]
"""
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 15
state_dir = os.path.expanduser("~/.claude/spectix")

# Terminal queries codex's TUI blocks on at startup; a pty with no terminal emulator
# behind it must answer them or the TUI never gets far enough to start a session.
REPLIES = {
    b"\x1b[6n": b"\x1b[1;1R",
    b"\x1b[c": b"\x1b[?62;22c",
    b"\x1b]10;?": b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
    b"\x1b]11;?": b"\x1b]11;rgb:0000/0000/0000\x1b\\",
    b"\x1b[?u": b"\x1b[?0u",
}

# Seed the stale state on the pty BEFORE codex starts, so a missed reset shows up.
master, slave = pty.openpty()
tty = os.ttyname(slave).removeprefix("/dev/")
# A fresh pty is 0x0; codex's TUI draws nothing (and starts no session) until it has a size.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
state = os.path.join(state_dir, f"state-{tty}")
os.makedirs(state_dir, exist_ok=True)
with open(state, "w") as f:
    f.write("done")

# The hook keys on `ps -o tty=`, which is only set for a CONTROLLING terminal.
def controlling_tty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

# The "Update available!" picker blocks startup until someone presses enter.
proc = subprocess.Popen(["codex", "--no-alt-screen", "-c", "check_for_update_on_startup=false"], stdin=slave, stdout=slave,
                        stderr=slave, preexec_fn=controlling_tty)
os.close(slave)
deadline = time.time() + secs
result = "done"
screen = b""
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if master in r:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        screen += data
        for q, a in REPLIES.items():
            if q in data:
                os.write(master, a)
    result = open(state).read() if os.path.exists(state) else "missing"
    if result == "idle":
        break
proc.terminate()
try:
    proc.wait(5)
except subprocess.TimeoutExpired:
    proc.kill()
os.remove(state) if os.path.exists(state) else None

if os.environ.get("PROBE_SCREEN"):
    open(os.environ["PROBE_SCREEN"], "wb").write(screen)
print(f"{tty}: state after codex cold start = {result}")
sys.exit(0 if result == "idle" else 1)
