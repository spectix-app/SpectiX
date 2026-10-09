#!/bin/bash
# Run a bash snippet inside Terminal.app and wait for it to finish (max $TERM_WAIT s, default 120).
# Why Terminal: it holds the Screen Recording + Accessibility grants this shell lacks
# (screencapture → "could not create image from display", System Events keystrokes → 1002).
# Usage: term.sh 'screencapture -l 123 /tmp/x.png'   → prints the snippet's output, exits with its status
set -u
d=$(mktemp -d /tmp/spectix-term.XXXXXX)
printf '%s\n' "$1" > "$d/cmd.sh"
osascript -e "tell application \"Terminal\" to do script \"bash '$d/cmd.sh' > '$d/out' 2>&1; echo \$? > '$d/rc'; exit\"" >/dev/null
for _ in $(seq 1 "${TERM_WAIT:-120}"); do [ -f "$d/rc" ] && break; sleep 1; done
[ -f "$d/rc" ] || { echo "term.sh: timed out, snippet left in $d" >&2; exit 124; }
# The runner window outlives its shell ("[Process completed]"). Left open, every run adds one
# more, and the next Terminal `activate` (a demo jump) raises them all into frame — with the
# user name in their titles. Minimize first: `close` is sometimes ignored.
osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  repeat with w in (every window)
    try
      if (count of processes of tab 1 of w) = 0 and ((contents of tab 1 of w) as text) contains "$d" then
        set miniaturized of w to true
        close w
      end if
    end try
  end repeat
end tell
OSA
cat "$d/out"; rc=$(cat "$d/rc"); rm -rf "$d"; exit "$rc"
