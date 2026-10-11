#!/bin/bash
# Is SpectiX burning CPU on writes no row depends on again? Sample a running app and fail on a regression.
#
#   ./tools/idle-cpu-probe.sh [seconds]      # default 20 per phase, auto-finds the pid (PID=… overrides)
#
# Run it next to ./tools/menubar-leak-probe.sh — that one guards memory, this one CPU.
#
# Why this exists (2026-09-24): the data-dir watcher used to kick a full ~700-pid process
# scan for EVERY write under ~/.claude/spectix/, including the companion extension's
# 2-second terminals-/window-<pid>.json heartbeats and our own *.log files. That was most
# of a 6-day, ~5 CPU-hour burn. The fix is AppController.isWatcherNoise (see
# docs/session-status.md, 监听器会跳过两类写入). Like the pill leak, a regression here
# compiles, passes every test and looks fine — it just keeps a core warm all day.
#
# Two phases of equal length, CPU time read from `ps` before and after each:
#   quiet  — nothing from us; the app's own polling baseline
#   noise  — we append to a throwaway *.log in the data dir at NOISE_HZ (default 10).
#            That is exactly the class isWatcherNoise must ignore, and nobody reads it,
#            so no row, toast or terminal can be affected by the fake writes.
# A healthy build costs about the same in both phases; a build that rescans per write
# pays one scan per tick in the noise phase. Fail on the EXTRA CPU, not the absolute
# number — the baseline moves with how many sessions are open.
set -euo pipefail
SECS="${1:-20}"
HZ="${NOISE_HZ:-10}"
# Percentage points of one core the noise phase may add. Measured 2026-10-11 at 10 Hz:
# fixed build +2.3, same build with the .log arm of isWatcherNoise flipped +24.2.
MAX_EXTRA="${MAX_EXTRA_CPU:-8}"
PID="${PID:-$(pgrep -x SpectiX | head -1)}"
[ -n "$PID" ] || { echo "❌ no running SpectiX — launch one first" >&2; exit 1; }
NOISE="$HOME/.claude/spectix/idle-cpu-probe-noise.log"
trap 'rm -f "$NOISE"' EXIT

# `ps -o time=` prints [[dd-]hh:]mm:ss.cc; fold it to seconds.
cpu() { ps -o time= -p "$PID" | awk '{n=split($1,a,/[-:]/); s=0; for (i=1;i<=n;i++) s=s*60+a[i]; if (n==4) s=a[1]*86400+a[2]*3600+a[3]*60+a[4]; print s}'; }
# Wall time from perl: the noise loop runs past SECS (one `sleep` spawn per tick), and
# dividing by the nominal length would bill that overrun to the app.
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
pct() { echo "scale=1; ($2 - $1) * 100 / ($4 - $3)" | bc; }

echo "pid $PID — ${SECS}s quiet, then ${SECS}s of ${HZ} Hz *.log writes"
# Create the file before the quiet phase: creating it is a directory event the kqueue
# source rightly reacts to; only the appends after it are the noise under test.
: > "$NOISE"
t0=$(now); c0=$(cpu); sleep "$SECS"; t1=$(now); c1=$(cpu)
ticks=$((SECS * HZ)); gap=$(echo "scale=3; 1 / $HZ" | bc)
for ((i = 0; i < ticks; i++)); do echo "$i" >> "$NOISE"; sleep "$gap"; done
t2=$(now); c2=$(cpu)

quiet=$(pct "$c0" "$c1" "$t0" "$t1"); noise=$(pct "$c1" "$c2" "$t1" "$t2")
extra=$(echo "scale=1; $noise - $quiet" | bc)
echo "quiet: ${quiet}% CPU   noise: ${noise}% CPU   extra: ${extra} pts (limit ${MAX_EXTRA})"
awk -v e="$extra" -v m="$MAX_EXTRA" 'BEGIN {
    if (e > m) {
        print "❌ writes no row depends on are triggering work again — check AppController.isWatcherNoise and the FSEvents callback"
        exit 1
    }
    print "✅ noise writes are ignored"
}'
