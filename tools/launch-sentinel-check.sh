#!/bin/bash
# T350: the "last run didn't quit cleanly" sentinel, end to end on the dev build.
#   1. launch → running-<pid> exists
#   2. kill -9 → relaunch → the stale sentinel is consumed and logged (= prompt shown)
#   3. SIGTERM (what pkill sends) → relaunch → nothing logged (clean quit, no prompt)
# Only the dev build is touched; a running release SpectiX is left alone.
# Prereq: ./build.sh has produced "SpectiX Dev.app".
set -u
APP="SpectiX Dev.app"
BIN="$APP/Contents/MacOS/SpectiX"
DIR="$HOME/.claude/spectix"
LOG="$DIR/launch-sentinel.log"

fail() { echo "FAIL: $*"; exit 1; }

dev_pid() { pgrep -f "$BIN" | head -1; }

launch() {
    open "$APP" || fail "open failed"
    for _ in $(seq 1 40); do
        p=$(dev_pid)
        [ -n "$p" ] && [ -f "$DIR/running-$p" ] && { echo "$p"; return; }
        sleep 0.25
    done
    fail "dev app did not start / plant its sentinel"
}

wait_gone() {
    for _ in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.25; done
    fail "pid $1 did not exit"
}

log_lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

[ -d "$APP" ] || fail "$APP missing — run ./build.sh"
old=$(dev_pid); [ -n "$old" ] && { kill -TERM "$old"; wait_gone "$old"; }

p1=$(launch)
echo "launched pid $p1, sentinel present"
kill -9 "$p1"; wait_gone "$p1"
[ -f "$DIR/running-$p1" ] || fail "sentinel vanished after kill -9"

before=$(log_lines)
p2=$(launch)
[ -f "$DIR/running-$p1" ] && fail "stale sentinel running-$p1 not consumed"
tail -n +"$((before + 1))" "$LOG" | grep -q "unclean previous run pid=$p1" \
    || fail "kill -9 relaunch did not detect the unclean exit"
echo "kill -9 → relaunch pid $p2: unclean exit detected (prompt shown)"

kill -TERM "$p2"; wait_gone "$p2"
[ -f "$DIR/running-$p2" ] && fail "SIGTERM quit left its sentinel behind"
before=$(log_lines)
p3=$(launch)
[ "$(log_lines)" = "$before" ] || fail "clean quit was reported as unclean"
echo "clean quit → relaunch pid $p3: no prompt"
echo "launch-sentinel-check: PASS"
