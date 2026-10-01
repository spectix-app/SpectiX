#!/bin/bash
# Is the menu-bar pill leaking again? Sample a running SpectiX and report growth.
#
#   ./tools/menubar-leak-probe.sh [seconds]      # default 120, auto-finds the pid
#
# Why this exists (2026-09-15): the pill used to be redrawn by a 0.1s timer that
# wrote NSStatusBarButton.image/.title/.imagePosition on every frame. On macOS 26
# EVERY write to a status-bar button's properties registers an NSKeyValueDependency
# pair inside AppKit that is never released — ~13 objects per frame, ~1 GB/day with
# one session running. A plain NSButton taking the same writes leaks nothing, so it
# is AppKit's, not ours; the fix was to stop writing per frame at all (the dot now
# breathes as a CALayer animation inside a hosted view — see main.swift CapsuleView).
#
# Nothing in the build or the test suite can catch a regression here: it compiles,
# it runs, it just eats memory for days. So this script is the check — run it after
# touching the capsule, with at least one session in the "working" state (that is
# what used to drive the timer).
set -euo pipefail
SECS="${1:-120}"
PID="${PID:-$(pgrep -x SpectiX | head -1)}"
[ -n "$PID" ] || { echo "❌ no running SpectiX — launch one first" >&2; exit 1; }

kvd() { heap "$1" 2>/dev/null | awk '/NSKeyValueDependency/ {n += $1} END {print n+0}'; }
# No `exit` inside these awks: heap keeps writing, gets SIGPIPE, and `set -o pipefail`
# then kills the whole script with 141 before it prints anything.
nodes() { heap "$1" 2>/dev/null | awk '/nodes malloced/ && !seen {for (i=1;i<=NF;i++) if ($(i+1)=="nodes") {print $i; seen=1}}'; }

echo "pid $PID — sampling ${SECS}s"
k0=$(kvd "$PID"); n0=$(nodes "$PID")
sleep "$SECS"
k1=$(kvd "$PID"); n1=$(nodes "$PID")

per_min() { echo "scale=1; ($2 - $1) * 60 / $SECS" | bc; }
dk=$(per_min "$k0" "$k1"); dn=$(per_min "$n0" "$n1")
echo "NSKeyValueDependency*: $k0 → $k1   (${dk}/min)"
echo "all live blocks:       $n0 → $n1   (${dn}/min)"
# Read the number against TWO known sources, not one — the first version of this script
# blamed the pill for any growth at all, and that attribution is now proven wrong:
#
#   · the pill's own signature was ~13 objects per 0.1s frame ≈ 7800/min (fixed)
#   · T318: AppKit registers a dependency object every time a freshly built control is
#     inserted into a window (NSControl viewDidMoveToWindow → NSKeyValueDependencyInfo
#     addDependencyInContext:), and this app rebuilds cells on every list reload —
#     measured ~2200/min with the pill already fixed. Different bug, different fix.
#
# So only the old signature fails the check. Anything in between is T318 talking.
awk -v d="$dk" 'BEGIN {
    if (d > 5000) {
        print "❌ the old signature is back — something writes status-button properties per frame"
        exit 1
    } else if (d > 800) {
        printf "⚠️  %s/min — no per-frame pill writes, but T318 (controls inserted into windows) is still running\n", d
    } else {
        print "✅ no per-frame leak"
    }
}'
