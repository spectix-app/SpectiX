#!/bin/bash
# Dump the jump diagnostics after "the hotkey landed on a terminal that was running"
# (T24). Run it whenever it happens again — right away or the next morning, the file
# keeps up to ~200 KB either way.
#
# Two reasons this wrapper exists instead of a line in the task notes:
#   * `log show …` typed as-is hits ZSH'S OWN `log` BUILTIN and dies with
#     "too many arguments" — the unified-log binary must be spelled /usr/bin/log.
#   * the unified log is not a usable channel here anyway: SpectiX's FrontBoard
#     chatter runs ~250k lines every three hours, which rotates the persisted store
#     to well under a day, so a report that arrives the next morning finds nothing.
#     ~/.claude/spectix/jump-diag.log is the primary source; the unified log is only
#     a same-day cross-check.
set -euo pipefail

LINES=${1:-80}
DIAG="$HOME/.claude/spectix/jump-diag.log"

echo "=== jump-diag.log (last $LINES lines) ==="
if [ -f "$DIAG" ]; then
  tail -n "$LINES" "$DIAG"
else
  echo "(no file yet — no jump has happened since the app last started)"
fi

echo
echo "=== how to read it ==="
cat <<'EOF'
A  pool EMPTY → returnToOrigin, then homeStatus=working
     Working as designed: the pool was empty, so the press meant "take me home",
     and home happened to be a terminal that is running.
B  verify GAVE UP — token names shNNN ... (working)
     The jump landed in the right VSCode window but focus stayed on a SIBLING
     terminal in it, and that sibling is the running one.
C  hotkey pool=[...] lists a session whose status disagrees with what the menu bar
     showed at that moment
     Stale rows — the state file was read before the hook rewrote it.
Neither: the target line says status=needs/paused/done, so the landing was correct
     and the terminal started running again after we got there.
EOF

echo
echo "=== unified log cross-check (same day only) ==="
OLDEST=$(ls -t /var/db/diagnostics/Persist/*.tracev3 2>/dev/null | tail -1)
[ -n "$OLDEST" ] && echo "persisted store reaches back to: $(stat -f '%Sm' "$OLDEST")"
/usr/bin/log show --last 12h --predicate 'process == "SpectiX" AND eventMessage BEGINSWITH "TB jump"' \
  --style compact 2>/dev/null | tail -n "$LINES"
