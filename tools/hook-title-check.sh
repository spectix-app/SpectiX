#!/bin/bash
# Regression check for the row-title block of hooks/spectix-status.sh — the five
# branches docs/row-display.md §行标题 describes. A title bug never throws: the row just
# reads '<ide_opened_file>The use' or 'jx' until someone notices, so pin them here.
#
#   ./tools/hook-title-check.sh
#
# Drives the REAL hook with synthetic UserPromptSubmit payloads. Two seams, no hook edits:
#   - HOME points at a scratch dir, so every state file lands there, never in the live
#     ~/.claude/spectix the running app reads.
#   - the hook keys on the controlling tty it finds by climbing its parents, so each run
#     sits under `script`, which hands it a fresh pseudo-terminal.
# Exits 1 on any failed case.
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK="${HOOK:-$PWD/hooks/spectix-status.sh}"  # override to mutation-test a patched copy
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
n=0

# run_hook <case-home> <prompt> [transcript]
# Seeds come from SEED_TITLE / SEED_AI_USED (written for whatever tty `script` hands out,
# before the hook fires — the stand-in for an earlier ai-title or a `todo.py claim`).
run_hook() {
  local home="$1" prompt="$2" tp="${3:-}"
  local payload="$home/payload.json"
  PROMPT="$prompt" TP="$tp" /usr/bin/python3 -c '
import json, os
print(json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": os.environ["PROMPT"],
                  "cwd": "/tmp/hook-title-check", "transcript_path": os.environ["TP"]}))
' > "$payload"
  HOME="$home" HOOK="$HOOK" PAYLOAD="$payload" \
  SEED_TITLE="${SEED_TITLE:-}" SEED_AI_USED="${SEED_AI_USED:-}" \
    script -q /dev/null bash -c '
d="$HOME/.claude/spectix"; mkdir -p "$d"
t=$(ps -o tty= -p $$ | tr -d " ")
[ -n "$SEED_TITLE" ] && printf "%s" "$SEED_TITLE" > "$d/title-$t"
[ -n "$SEED_AI_USED" ] && printf "%s" "$SEED_AI_USED" > "$d/title-ai-used-$t"
bash "$HOOK" working < "$PAYLOAD"
' < /dev/null > /dev/null 2>&1
}

# title_of <case-home> — the row title the app would read (empty if none written)
title_of() { cat "$1"/.claude/spectix/title-ttys* 2>/dev/null; }

# expect <label> <want> <prompt> [transcript]
expect() {
  local label="$1" want="$2" prompt="$3" tp="${4:-}" home got
  # One scratch HOME per case so no tty's files leak into the next. Not a $(…) helper:
  # the counter would increment in a subshell and every case would share one HOME.
  n=$((n + 1)); home="$WORK/h$n"; mkdir -p "$home"
  run_hook "$home" "$prompt" "$tp"
  got=$(title_of "$home")
  if [ "$got" = "$want" ]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s\n        want: %q\n        got:  %q\n' "$label" "$want" "$got"
    fails=$((fails + 1))
  fi
}

transcript="$WORK/session.jsonl"
printf '%s\n' '{"type":"user","message":"hi"}' \
              '{"type":"ai-title","aiTitle":"Autorun log 改进分析"}' > "$transcript"

echo "1. ai-title is authoritative"
SEED_TITLE="" SEED_AI_USED="" \
  expect "fresh ai-title beats a substantial prompt" "Autorun log 改进分析" \
         "please fix the login redirect bug" "$transcript"
SEED_TITLE="Autorun log 改进分析" SEED_AI_USED="Autorun log 改进分析" \
  expect "once consumed, a later prompt never rewrites" "Autorun log 改进分析" \
         "now refactor the settings window"

echo "2. no ai-title: the prompt is the fallback"
SEED_TITLE="" SEED_AI_USED="" \
  expect "substantial prompt writes, capped at 24" "please fix the login red" \
         "please fix the login redirect bug"
SEED_TITLE="old topic" SEED_AI_USED="" \
  expect "substantial prompt replaces an older prompt title" "rework the capsule layou" \
         "rework the capsule layout"

echo "3. junk/trigger prompts only seed"
SEED_TITLE="" SEED_AI_USED="" expect "jx seeds an empty session" "jx" "jx"
SEED_TITLE="Real task" SEED_AI_USED="" expect "jx T37 never overwrites" "Real task" "jx T37"
SEED_TITLE="Real task" SEED_AI_USED="" expect "bare option number never overwrites" "Real task" "2"
SEED_TITLE="Real task" SEED_AI_USED="" expect "好的 never overwrites" "Real task" "好的"

echo "4. injected blocks and dragged-in paths are stripped"
SEED_TITLE="Real task" SEED_AI_USED="" \
  expect "quoted screenshot path alone writes nothing" "Real task" \
         "'/var/folders/2c/hsqx8tg/T/Screenshot 2026-09-03 at 10.00.png'"
SEED_TITLE="Real task" SEED_AI_USED="" \
  expect "path stripped, the words after it win" "look at this layout bug" \
         "/Users/me/Desktop/shot.png look at this layout bug"
SEED_TITLE="Real task" SEED_AI_USED="" \
  expect "slash command is not a path" "/task fix the capsule" \
         "/task fix the capsule"
SEED_TITLE="Real task" SEED_AI_USED="" \
  expect "IDE context block stripped" "explain this function" \
         "<ide_opened_file>The user opened /a/b.swift</ide_opened_file> explain this function"
SEED_TITLE="Real task" SEED_AI_USED="" \
  expect "cross-session message (with attributes) writes nothing" "Real task" \
         '<cross-session-message from="uds:/tmp/cc-socks/40377.sock" from-name="x">hello there friend</cross-session-message>'

echo "5. a claimed task's title survives the jx workflow"
for p in done 继续 rr ok; do
  SEED_TITLE="T291 hook title check" SEED_AI_USED="" \
    expect "claim title survives '$p'" "T291 hook title check" "$p"
done
SEED_TITLE="T291 hook title check" SEED_AI_USED="" \
  expect "task-notification wake-up leaves it alone" "T291 hook title check" \
         "<task-notification><task-id>abc</task-id>agent finished</task-notification>"

if [ "$fails" -gt 0 ]; then
  echo "hook-title-check: $fails case(s) failed"
  exit 1
fi
echo "hook-title-check: all five branches pass"
