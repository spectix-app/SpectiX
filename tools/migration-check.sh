#!/bin/bash
# Exercise Migration.swift (T180) against a throwaway ~/.claude.
#
# The pass it tests only ever runs ONCE per machine and only on machines that
# still have the pre-rename data — which means it can't be verified by launching
# the app here: this Mac ran the migration on the first launch after the rename and
# will never run it again. So build the enum into a tiny CLI instead, point it at a
# fake tree via SPECTIX_MIGRATE_ROOT (same hatch as SPECTIX_INSTALL_ROOT), and
# assert on what came out.
#
# Preferences are the one thing that can't be re-rooted — CFPreferences owns its
# own paths — so the CLI writes into a domain named after itself
# (~/Library/Preferences/spectix-migration-check.plist), which this script deletes
# on both sides of the run. The real ~/.claude and the real app domain are never
# touched.
#
# Usage: tools/migration-check.sh     (from the repo root; prints PASS/FAIL per check)
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT=$(mktemp -d /tmp/spectix-migcheck.XXXXXX)
BIN=$ROOT/bin
DOMAIN=spectix-migration-check
C=$ROOT/.claude
trap 'rm -rf "$ROOT"; defaults delete $DOMAIN 2>/dev/null' EXIT

mkdir -p "$BIN" "$C/taskbeacon/icons" "$C/spectix/icons"

# ---------------------------------------------------------------- fake old tree
# Out of order on purpose, and line 2 is also in the new log (a machine that ran
# both hooks in the same week has a genuine overlap).
cat > "$C/taskbeacon/events.jsonl" <<'EOF'
{"ts": 300, "event": "done", "tty": "ttys001"}
{"ts": 100, "event": "run", "tty": "ttys001"}
{"ts": 200, "event": "run", "tty": "ttys002"}
EOF
echo '[{"path":"/old/proj","lastSeen":999,"pinned":true}]' > "$C/taskbeacon/projects.json"
echo OLD > "$C/taskbeacon/icons/old.png"
echo OLD > "$C/taskbeacon/icons/dup.png"
echo Hero  > "$C/taskbeacon/sound-done"
echo Basso > "$C/taskbeacon/sound-needs"
# Derived state: must NOT come over — a stale row would come back from the dead.
echo working > "$C/taskbeacon/state-ttys999"
echo '{"pct":50}' > "$C/taskbeacon/usage.json"

# ---------------------------------------------------------------- fake new tree
cat > "$C/spectix/events.jsonl" <<'EOF'
{"ts": 200, "event": "run", "tty": "ttys002"}
{"ts": 400, "event": "done", "tty": "ttys003"}
EOF
# A lone 0xE4 byte: what the hook leaves behind when it clips a title mid-character.
# Reading this file as UTF-8 fails for the WHOLE file, so a text-based merge would
# treat the destination as empty and overwrite three weeks of history with the old
# file alone. The merge works on bytes for exactly this reason.
printf '{"ts": 500, "event": "run", "title": "\344"}\n' >> "$C/spectix/events.jsonl"
echo '[{"path":"/old/proj","lastSeen":1},{"path":"/new/proj","lastSeen":500}]' > "$C/spectix/projects.json"
echo NEW   > "$C/spectix/icons/dup.png"
echo Glass > "$C/spectix/sound-done"

# settings.json: one stale entry to rewrite (Stop), one event wired on BOTH sides of
# the rename so the duplicate has to collapse (PreToolUse), a matcher block the user
# composed themselves (left whole), and someone else's hook (never touched).
cat > "$C/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh done"}]}],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/spectix-status.sh working"}]},
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh working"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh working"}]}
    ],
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/someone-elses.sh"}]}]
  },
  "otherSetting": "must survive"
}
EOF

# ------------------------------------------------------------------- build + run
echo 'Migration.runIfNeeded()' > "$BIN/main.swift"
swiftc -O Migration.swift "$BIN/main.swift" -o "$BIN/$DOMAIN" 2>&1 | grep -v '^ *$' | head -5
[ -x "$BIN/$DOMAIN" ] || { echo "FAIL  build"; exit 1; }

defaults delete $DOMAIN 2>/dev/null
SPECTIX_MIGRATE_ROOT="$ROOT" "$BIN/$DOMAIN"

# --------------------------------------------------------------------- assertions
FAILED=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"
  else printf 'FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; FAILED=1; fi
}

check "events merged, deduped" 5 "$(wc -l < "$C/spectix/events.jsonl" | tr -d ' ')"
check "events sorted by ts" "100 200 300 400 500" \
  "$(python3 -c 'import json,sys;print(" ".join(str(json.loads(l)["ts"]) for l in open(sys.argv[1],encoding="utf-8",errors="replace")))' "$C/spectix/events.jsonl")"
check "invalid-UTF8 line survives byte-for-byte" 1 \
  "$(python3 -c 'import sys;print(sum(1 for l in open(sys.argv[1],"rb") if b"\xe4" in l))' "$C/spectix/events.jsonl")"
check "project keeps later sighting + pin" "999.0 True" \
  "$(python3 -c 'import json,sys;d={r["path"]:r for r in json.load(open(sys.argv[1]))};r=d["/old/proj"];print(float(r["lastSeen"]), r.get("pinned",False))' "$C/spectix/projects.json")"
check "project only in new file survives" "500.0" \
  "$(python3 -c 'import json,sys;d={r["path"]:r for r in json.load(open(sys.argv[1]))};print(float(d["/new/proj"]["lastSeen"]))' "$C/spectix/projects.json")"
check "icon carried over" OLD "$(cat "$C/spectix/icons/old.png")"
check "icon already there not clobbered" NEW "$(cat "$C/spectix/icons/dup.png")"
check "sound already chosen not clobbered" Glass "$(cat "$C/spectix/sound-done")"
check "sound only in old carried over" Basso "$(cat "$C/spectix/sound-needs")"
check "derived state left behind" "absent" \
  "$([ -e "$C/spectix/state-ttys999" ] && echo present || echo absent)"
check "usage cache left behind" "absent" \
  "$([ -e "$C/spectix/usage.json" ] && echo present || echo absent)"

SET=$C/settings.json
check "no stale script name anywhere" 0 "$(grep -c taskbeacon "$SET" || true)"
check "duplicate wiring collapsed" 1 \
  "$(python3 -c 'import json,sys;h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"];print(sum(1 for b in h if "matcher" not in b for e in b["hooks"] if "spectix-status" in e["command"]))' "$SET")"
check "user matcher block kept" "Bash ~/.claude/hooks/spectix-status.sh working" \
  "$(python3 -c 'import json,sys;h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"];b=[x for x in h if "matcher" in x][0];print(b["matcher"], b["hooks"][0]["command"])' "$SET")"
check "third-party hook untouched" "~/.claude/hooks/someone-elses.sh" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$SET")"
check "unrelated settings survive" "must survive" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["otherSetting"])' "$SET")"

# Preferences: read back the CLI's own domain. It starts empty (deleted above), so
# everything in it came from a legacy domain on this machine — which is why this
# check needs a machine that actually ran the old app to mean anything.
PLIST=$(defaults read $DOMAIN 2>/dev/null || echo "")
check "migration flag set" 1 "$(printf '%s' "$PLIST" | grep -c legacyMigrationDone || true)"
check "login-item seed flag NOT carried" 0 "$(printf '%s' "$PLIST" | grep -c launchAtLoginSeeded || true)"
check "framework keys NOT carried" 0 "$(printf '%s' "$PLIST" | grep -cE '^ +"?(NS|Apple)' || true)"
if printf '%s' "$PLIST" | grep -q themeID; then
  echo "PASS  real preference carried over (themeID)"
else
  echo "SKIP  no legacy domain on this machine — preference copy unverified"
fi

echo
[ $FAILED -eq 0 ] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit $FAILED
