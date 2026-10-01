#!/usr/bin/env bash
#
# wipe-install.sh — put this Mac back into the state it was in before SpectiX
# was ever installed, so the next install exercises the first-install path a
# friend would actually walk (not the upgrade path).
#
#   ./tools/wipe-install.sh            dry run — list what would be touched
#   ./tools/wipe-install.sh --wipe     back up, then really remove, then verify
#   ./tools/wipe-install.sh --verify   verify only
#
# Dry run is the default on purpose: every other script in this repo is safe to
# re-run, this one deletes the user's data.
#
# The removal list mirrors InstallerCore.swift's uninstall() — when a new
# install target is added there, add it to the constants below too.
#
# See .claude/skills/wipe-install/SKILL.md for the reasoning behind the two
# ordering constraints and the pitfalls encoded here.

set -euo pipefail

# ── What we install, and therefore what we remove ───────────────────────────
# Old names stay on these lists forever: each rename made the old build a
# *different* app to macOS, the editors and TCC alike, so a new install never
# supersedes an old one — it has to be named to be removed. T206 renamed the id
# (com.<vendor>.* → app.spectix.*), T172 renamed the product (taskbeacon →
# spectix). A wipe that misses one leaves a grant behind and the next "fresh
# install" acceptance run is measuring the wrong machine.
#
# The pre-T206 ids are discovered, not spelled: the vendor segment was a personal
# name and this script is public. They come from two places, because either can
# be the only trace left — a Preferences plist, or a bundle still on disk.
APP_NAMES=("SpectiX.app" "SpectiX Dev.app" "TaskBeacon.app")
APP_DIRS=("/Applications" "$HOME/Applications")
BUNDLE_IDS=(app.spectix.SpectiX app.spectix.SpectiX.dev)
while IFS= read -r id; do BUNDLE_IDS+=("$id"); done < <(
  { ls "$HOME/Library/Preferences" 2>/dev/null \
      | sed -nE 's/^(com\.[A-Za-z0-9-]+\.(spectix|taskbeacon)(\.dev)?)\.plist$/\1/p'
    for d in "${APP_DIRS[@]}"; do for a in "${APP_NAMES[@]}"; do
      # PlistBuddy reports a missing file on stdout, so check first
      p="$d/$a/Contents/Info.plist"; [ -f "$p" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$p" 2>/dev/null
    done; done
  } | grep -vxE 'app\.spectix\.SpectiX(\.dev)?' | sort -u)
# Prefix match, not exact names: debugging leaves things like
# taskbeacon-status.sh.bak-dbg that an exact list walks straight past.
HOOK_PREFIXES=(spectix taskbeacon)
STATE_DIRS=("$HOME/.claude/spectix" "$HOME/.claude/taskbeacon")
SETTINGS="$HOME/.claude/settings.json"
HOOKS_DIR="$HOME/.claude/hooks"
EDITOR_DIRS=(".vscode" ".cursor" ".windsurf")
EXT_IDS=(spectix.focus taskbeacon.focus)
LOGIN_ITEMS=("SpectiX" "SpectiX Dev" "TaskBeacon")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="dry"
case "${1:-}" in
  --wipe)   MODE="wipe" ;;
  --verify) MODE="verify" ;;
  ""|--dry-run) MODE="dry" ;;
  -h|--help)
    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'
    exit 0 ;;
  *)
    echo "unknown option: $1 (expected --wipe, --verify or nothing)" >&2
    exit 2 ;;
esac

BACKUP="$HOME/spectix-wipe-$(date +%Y%m%d-%H%M%S)"

# ── Output helpers ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; RED=$'\033[31m'
  YEL=$'\033[33m'; RST=$'\033[0m'
else
  B=""; DIM=""; GRN=""; RED=""; YEL=""; RST=""
fi

step()  { printf '\n%s▸ %s%s\n' "$B" "$1" "$RST"; }
hit()   { printf '   %s● %s%s\n' "$YEL" "$1" "$RST"; }
gone()  { printf '   %s✓ %s%s\n' "$GRN" "$1" "$RST"; }
skip()  { printf '   %s· %s%s\n' "$DIM" "$1" "$RST"; }
note()  { printf '   %s%s%s\n' "$DIM" "$1" "$RST"; }

DRY() { [ "$MODE" = "dry" ]; }

# ── Backup ──────────────────────────────────────────────────────────────────
# The only rollback source there is. Most of the state directory is derived and
# self-refreshing, but the work-time log, the custom row icons and the recent
# projects list are not — the app never regenerates those.
ensure_backup_dir() {
  DRY && return 0
  [ -d "$BACKUP" ] || mkdir -p "$BACKUP"
}

backup_path() {
  local src="$1" name="$2"
  [ -e "$src" ] || return 0
  if DRY; then hit "backup $src"; return 0; fi
  ensure_backup_dir
  if [ -d "$src" ]; then
    tar -czf "$BACKUP/${name}.tar.gz" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null || true
  else
    cp -p "$src" "$BACKUP/$name" 2>/dev/null || true
  fi
}

# ── settings.json surgery (python3: the file is JSON, sed would be a guess) ──
# Three modes, one parser, so "what counts as ours" is defined exactly once.
settings_py() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, pathlib, sys

path, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
if not path.exists():
    print("0" if mode != "listuser" else "", end="")
    sys.exit(0)
try:
    root = json.loads(path.read_text())
except Exception:
    sys.exit(2)          # unparseable — caller must not write over it

OURS = ("spectix", "taskbeacon")
def ours(entry):
    return any(n in (entry.get("command") or "").lower() for n in OURS)

hooks = root.get("hooks")
if not isinstance(hooks, dict):
    print("0" if mode != "listuser" else "", end="")
    sys.exit(0)

mine = 0
theirs = []
cleaned_hooks = {}
for event, blocks in hooks.items():
    if not isinstance(blocks, list):
        cleaned_hooks[event] = blocks
        continue
    kept_blocks = []
    for block in blocks:
        entries = block.get("hooks") if isinstance(block, dict) else None
        if not isinstance(entries, list):
            kept_blocks.append(block)
            continue
        kept = []
        for e in entries:
            if isinstance(e, dict) and ours(e):
                mine += 1
            else:
                kept.append(e)
                if isinstance(e, dict) and e.get("command"):
                    theirs.append(e["command"])
        if kept:
            block = dict(block); block["hooks"] = kept
            kept_blocks.append(block)
    if kept_blocks:
        cleaned_hooks[event] = kept_blocks

if mode == "count":
    print(mine, end="")
elif mode == "listuser":
    # One per line INCLUDING a trailing newline: a last line without one is
    # dropped by `while read`, which silently turned the "user's hooks
    # survived" check into a no-op that always passed.
    for cmd in theirs:
        print(cmd)
elif mode == "unwire":
    if mine:
        if cleaned_hooks:
            root["hooks"] = cleaned_hooks
        else:
            root.pop("hooks", None)
        path.write_text(json.dumps(root, indent=2, sort_keys=True) + "\n")
    print(mine, end="")
PY
}

# ── extensions.json index surgery ───────────────────────────────────────────
# VSCode 1.74+ resolves user extensions through this index; a folder that is
# not listed does not exist to the editor, and a listed folder that is gone
# reads as installed. The two can disagree in both directions, so both get
# cleaned and both get verified.
ext_index_py() {
  python3 - "$1" "$2" "${EXT_IDS[@]}" <<'PY'
import json, pathlib, sys

path, mode, ids = pathlib.Path(sys.argv[1]), sys.argv[2], set(sys.argv[3:])
if not path.exists():
    print("0", end=""); sys.exit(0)
try:
    rows = json.loads(path.read_text())
    assert isinstance(rows, list)
except Exception:
    sys.exit(2)          # leave an index we cannot parse strictly alone

def is_ours(row):
    ident = row.get("identifier") if isinstance(row, dict) else None
    return isinstance(ident, dict) and ident.get("id") in ids

mine = [r for r in rows if is_ours(r)]
if mode == "clean" and mine:
    path.write_text(json.dumps([r for r in rows if not is_ours(r)]))
print(len(mine), end="")
PY
}

# ── Removal steps ───────────────────────────────────────────────────────────

quit_running() {
  step "Quit running copies"
  local found=0 name
  for name in "${APP_NAMES[@]}"; do
    local proc="${name%.app}"
    if pgrep -x "$proc" >/dev/null 2>&1; then
      found=1
      if DRY; then hit "would quit ${proc}"
      else pkill -x "$proc" 2>/dev/null || true; gone "quit ${proc}"; fi
    fi
  done
  [ "$found" = 1 ] || skip "nothing running"
}

# MUST run before the bundles are deleted: tccutil resolves a bundle id through
# LaunchServices, and with no copy on disk it silently does nothing — leaving a
# row in System Settings pointing at an app that no longer exists.
reset_tcc() {
  step "Reset Accessibility grants (before the bundles go)"
  local id
  for id in "${BUNDLE_IDS[@]}"; do
    if DRY; then hit "tccutil reset Accessibility ${id}"
    elif tccutil reset Accessibility "$id" >/dev/null 2>&1; then gone "${id}"
    else skip "${id} — no record"; fi
  done
}

# SMAppService registrations outlive the bundle and are not in the filesystem,
# so rm cannot reach them. Left behind, the next install starts with "launch at
# login" already on and that check is void.
remove_login_items() {
  step "Remove login items"
  local name
  for name in "${LOGIN_ITEMS[@]}"; do
    if DRY; then hit "login item ${name}"; continue; fi
    if osascript -e "tell application \"System Events\" to delete login item \"${name}\"" \
         >/dev/null 2>&1; then
      gone "${name}"
    else
      skip "${name} — not registered"
    fi
  done
  DRY || note "SMAppService entries can also linger in System Settings › Login Items; check there if the next install starts with it already on."
}

remove_apps() {
  step "Remove app bundles"
  local dir name path found=0
  for dir in "${APP_DIRS[@]}"; do
    for name in "${APP_NAMES[@]}"; do
      path="$dir/$name"
      [ -e "$path" ] || continue
      found=1
      if DRY; then hit "$path"
      else rm -rf "$path"; gone "$path"; fi
    done
  done
  # The dev build in the repo is a build artifact, not an install — moving it
  # aside is enough to keep it from answering for the installed copy, and it
  # costs a rebuild to get back.
  for name in "${APP_NAMES[@]}"; do
    path="$REPO_ROOT/$name"
    [ -e "$path" ] || continue
    found=1
    if DRY; then hit "$path (repo dev build — moved to backup, not deleted)"
    else
      ensure_backup_dir
      mv "$path" "$BACKUP/$name"
      gone "$path → backup"
    fi
  done
  [ "$found" = 1 ] || skip "no bundles found"
}

remove_hooks() {
  step "Remove hook scripts"
  [ -d "$HOOKS_DIR" ] || { skip "no ~/.claude/hooks"; return 0; }
  local found=0 prefix f
  for prefix in "${HOOK_PREFIXES[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      found=1
      if DRY; then hit "$f"
      else backup_path "$f" "hooks-$(basename "$f")"; rm -f "$f"; gone "$f"; fi
    done < <(find "$HOOKS_DIR" -maxdepth 1 -name "${prefix}*" -print 2>/dev/null)
  done
  [ "$found" = 1 ] || skip "none installed"
}

unwire_settings() {
  step "Unwire ~/.claude/settings.json"
  [ -f "$SETTINGS" ] || { skip "no settings.json"; return 0; }

  local count
  if ! count="$(settings_py count)"; then
    printf '   %s! settings.json is not parseable — leaving it untouched%s\n' "$RED" "$RST"
    note "Fix or restore it by hand; rewriting it here would destroy hooks that are not ours."
    return 0
  fi
  if [ "$count" = "0" ]; then skip "no wiring of ours"; return 0; fi

  if DRY; then hit "would drop ${count} hook entr$([ "$count" = 1 ] && echo y || echo ies)"; return 0; fi

  backup_path "$SETTINGS" "settings.json"
  # Record the user's own hooks so --verify can later prove we did not take
  # anything that was not ours. Losing someone else's hook is worse than
  # leaving one of ours behind.
  ensure_backup_dir
  settings_py listuser > "$BACKUP/user-hooks.txt" || true
  settings_py unwire >/dev/null
  gone "dropped ${count} entries, kept everything else"
}

remove_state() {
  step "Remove state directories"
  local dir found=0
  for dir in "${STATE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    found=1
    if DRY; then hit "$dir"
    else backup_path "$dir" "state-$(basename "$dir")"; rm -rf "$dir"; gone "$dir"; fi
  done
  [ "$found" = 1 ] || skip "none present"
}

remove_extensions() {
  step "Remove editor extensions (folders + index)"
  local editor root entry index n found=0
  for editor in "${EDITOR_DIRS[@]}"; do
    root="$HOME/$editor/extensions"
    [ -d "$root" ] || continue

    local id
    for id in "${EXT_IDS[@]}"; do
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        found=1
        if DRY; then hit "$entry"
        else rm -rf "$entry"; gone "$entry"; fi
      done < <(find "$root" -maxdepth 1 -type d -name "${id}-*" -print 2>/dev/null)
    done

    index="$root/extensions.json"
    [ -f "$index" ] || continue
    if DRY; then
      if n="$(ext_index_py "$index" count)" && [ "$n" != "0" ]; then
        found=1; hit "$index — ${n} index row(s)"
      fi
    else
      if n="$(ext_index_py "$index" clean)"; then
        [ "$n" = "0" ] || { found=1; gone "$index — removed ${n} row(s)"; }
      else
        printf '   %s! %s is not parseable — left alone%s\n' "$RED" "$index" "$RST"
      fi
    fi
  done
  [ "$found" = 1 ] || skip "no extensions of ours"
}

# defaults delete MUST precede removing the plist: cfprefsd holds the domain in
# memory and writes it straight back out after a bare rm, so the files vanish
# and every preference returns on next launch.
remove_prefs() {
  step "Remove Preferences"
  local id plist found=0
  for id in "${BUNDLE_IDS[@]}"; do
    plist="$HOME/Library/Preferences/${id}.plist"
    if defaults read "$id" >/dev/null 2>&1; then
      found=1
      if DRY; then hit "defaults domain ${id}"
      else backup_path "$plist" "prefs-${id}.plist"; defaults delete "$id" >/dev/null 2>&1 || true; gone "domain ${id}"; fi
    fi
    if [ -f "$plist" ]; then
      found=1
      if DRY; then hit "$plist"
      else backup_path "$plist" "prefs-${id}.plist"; rm -f "$plist"; gone "$plist"; fi
    fi
  done
  if [ "$found" = 1 ] && ! DRY; then
    killall cfprefsd >/dev/null 2>&1 || true
    note "cfprefsd restarted so nothing gets flushed back"
  fi
  [ "$found" = 1 ] || skip "no preferences stored"
}

# ── Verification ────────────────────────────────────────────────────────────
PASS=0
FAIL=0

check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1))
    printf '   %sPASS%s  %s\n' "$GRN" "$RST" "$label"
  else
    FAIL=$((FAIL + 1))
    printf '   %sFAIL%s  %s%s\n' "$RED" "$RST" "$label" \
      "$([ -n "$detail" ] && printf ' — %s' "$detail")"
  fi
}

latest_backup() {
  find "$HOME" -maxdepth 1 -type d -name 'spectix-wipe-*' 2>/dev/null | sort | tail -1
}

verify() {
  step "Verify (10 checks)"
  PASS=0; FAIL=0
  local n dir name id editor root index found

  # 1. app bundles
  found=""
  for dir in "${APP_DIRS[@]}"; do
    for name in "${APP_NAMES[@]}"; do
      [ -e "$dir/$name" ] && found="$found $dir/$name"
    done
  done
  check "no app bundle installed" "$([ -z "$found" ] && echo 1 || echo 0)" "$found"

  # 2. hook scripts — prefix match, and find (never a glob: one non-matching
  # pattern would abort the whole line and skip every check below it)
  n=0
  if [ -d "$HOOKS_DIR" ]; then
    for id in "${HOOK_PREFIXES[@]}"; do
      n=$((n + $(find "$HOOKS_DIR" -maxdepth 1 -name "${id}*" 2>/dev/null | wc -l | tr -d ' ')))
    done
  fi
  check "no hook scripts in ~/.claude/hooks" "$([ "$n" = 0 ] && echo 1 || echo 0)" "${n} left"

  # 3. + 4. settings.json: ours gone, and the file still parses. The second one
  # protects the user, not us — an unparseable settings.json breaks every hook
  # they have.
  if [ ! -f "$SETTINGS" ]; then
    check "no wiring left in settings.json" 1
    check "settings.json still parseable" 1
  elif n="$(settings_py count)"; then
    check "no wiring left in settings.json" "$([ "$n" = 0 ] && echo 1 || echo 0)" "${n} entries"
    check "settings.json still parseable" 1
  else
    check "no wiring left in settings.json" 0 "unreadable"
    check "settings.json still parseable" 0 "JSON parse failed"
  fi

  # 5. the user's own hooks survived
  local bdir="" expected=0 present=0 cmd
  bdir="$(latest_backup)"
  if [ -n "$bdir" ] && [ -f "$bdir/user-hooks.txt" ]; then
    # `|| [ -n "$cmd" ]`: read returns non-zero on a final line with no newline,
    # and without this the last hook in the list is never checked.
    while IFS= read -r cmd || [ -n "$cmd" ]; do
      [ -n "$cmd" ] || continue
      expected=$((expected + 1))
      grep -qF -- "$cmd" "$SETTINGS" 2>/dev/null && present=$((present + 1))
    done < "$bdir/user-hooks.txt"
    check "user's own hooks untouched (${present}/${expected})" \
      "$([ "$present" = "$expected" ] && echo 1 || echo 0)" \
      "$((expected - present)) missing"
  else
    check "user's own hooks untouched (no baseline to compare)" 1
  fi

  # 6. state dirs
  found=""
  for dir in "${STATE_DIRS[@]}"; do [ -d "$dir" ] && found="$found $dir"; done
  check "no state directory" "$([ -z "$found" ] && echo 1 || echo 0)" "$found"

  # 7. + 8. extension folders and the index that makes them real
  local dirs_left=0 rows_left=0
  for editor in "${EDITOR_DIRS[@]}"; do
    root="$HOME/$editor/extensions"
    [ -d "$root" ] || continue
    for id in "${EXT_IDS[@]}"; do
      dirs_left=$((dirs_left + $(find "$root" -maxdepth 1 -type d -name "${id}-*" 2>/dev/null | wc -l | tr -d ' ')))
    done
    index="$root/extensions.json"
    [ -f "$index" ] || continue
    if n="$(ext_index_py "$index" count)"; then rows_left=$((rows_left + n)); fi
  done
  check "no extension folders" "$([ "$dirs_left" = 0 ] && echo 1 || echo 0)" "${dirs_left} left"
  check "no rows in extensions.json" "$([ "$rows_left" = 0 ] && echo 1 || echo 0)" "${rows_left} left"

  # 9. preferences, both the live domain and the file on disk
  found=""
  for id in "${BUNDLE_IDS[@]}"; do
    defaults read "$id" >/dev/null 2>&1 && found="$found ${id}"
    [ -f "$HOME/Library/Preferences/${id}.plist" ] && found="$found ${id}.plist"
  done
  check "no preferences stored" "$([ -z "$found" ] && echo 1 || echo 0)" "$found"

  # 10. login items
  local items="" left=""
  items="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || true)"
  for name in "${LOGIN_ITEMS[@]}"; do
    case ",$items," in *"$name"*) left="$left ${name}";; esac
  done
  check "no login item registered" "$([ -z "$left" ] && echo 1 || echo 0)" "$left"

  printf '\n'
  if [ "$FAIL" = 0 ]; then
    printf '%s✓ clean — %d/%d checks passed%s\n' "$GRN" "$PASS" "$((PASS + FAIL))" "$RST"
    return 0
  fi
  printf '%s✗ dirty — %d of %d checks failed%s\n' "$RED" "$FAIL" "$((PASS + FAIL))" "$RST"
  note "A new FAIL usually means the installer grew a target this script does not know about yet — add it to the constants at the top."
  return 1
}

# ── Main ────────────────────────────────────────────────────────────────────
case "$MODE" in
  verify)
    verify
    ;;
  dry|wipe)
    if DRY; then
      printf '%sDRY RUN%s — nothing will be touched. Re-run with %s--wipe%s to do it.\n' \
        "$B" "$RST" "$B" "$RST"
    else
      printf '%sWIPING%s — backup: %s\n' "$B" "$RST" "$BACKUP"
    fi
    quit_running
    reset_tcc            # before remove_apps — tccutil needs the bundle on disk
    remove_login_items
    remove_apps
    remove_hooks
    unwire_settings
    remove_state
    remove_extensions
    remove_prefs         # defaults delete before rm, inside
    if DRY; then
      printf '\n%sNothing was changed.%s Re-run with --wipe to apply, then install the package you want to test.\n' \
        "$B" "$RST"
    else
      printf '\n%sBacked up to%s %s\n' "$B" "$RST" "$BACKUP"
      verify
    fi
    ;;
esac
