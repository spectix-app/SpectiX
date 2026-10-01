#!/bin/bash
# Exercise the GUI installer (T177 F2/F3) against a throwaway ~/.claude.
#
# Two paths matter and only one of them is what this machine looks like:
#   F2 fresh machine  — nothing of ours on disk before the run
#   F3 upgraded machine — a pre-rename install already wired up (T172 plan B4)
# F3 is the one that can regress silently. If the settings.json cleanup ever stops
# recognising the OLD hook name, both entries survive, two hooks fire per event and
# each writes a different state directory — the app still works, so nothing here
# fails except the row occasionally showing the losing hook's answer. Only an
# assertion on the entry count catches that.
#
# The installer resolves every write through InstallPaths, so SPECTIX_INSTALL_ROOT
# re-roots the whole run under a temp dir; SPECTIX_INSTALL_HEADLESS=1 runs it with
# no window. The real ~/.claude, /Applications and TCC database are never touched.
#
# Usage: tools/install-check.sh     (from the repo root; prints PASS/FAIL per check)
set -uo pipefail
cd "$(dirname "$0")/.."

INSTALLER="installer/build/Install SpectiX.app/Contents/MacOS/SpectiXInstaller"
[ -x "$INSTALLER" ] || { echo "✖ 缺少安装器 —— 先跑 ./build.sh && ./installer/build-installer.sh"; exit 1; }

EXT_VERSION=$(/usr/bin/python3 -c 'import json;print(json.load(open("vscode-extension/package.json"))["version"])')

ROOT=$(mktemp -d /tmp/spectix-instcheck.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

FAILED=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; FAILED=1; }
check(){ if [ "$1" = 1 ]; then ok "$2"; else bad "$2"; fi; }

# A hook that isn't ours, present in both scenarios. The cleanup pass rewrites the
# same events it registers under, so an over-broad filter would take this with it —
# and the person who loses their own wiring to our installer never gets it back.
FOREIGN='~/.claude/hooks/my-own-thing.sh'

seed_settings() { # $1=home  $2=our hook command to pre-wire ("" for none)
  local c="$1/.claude" ours="$2"
  mkdir -p "$c/hooks"
  if [ -n "$ours" ]; then
    cat > "$c/settings.json" <<EOF
{
  "model": "opus",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "$ours done"},
                        {"type": "command", "command": "$FOREIGN"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "$ours working"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "$ours session-start"}]}]
  }
}
EOF
  else
    cat > "$c/settings.json" <<EOF
{
  "model": "opus",
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$FOREIGN"}]}]}
}
EOF
  fi
}

# Counts commands in settings.json whose text contains $2, across every event.
count_cmds() { # $1=settings.json  $2=needle
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
root = json.load(open(sys.argv[1]))
n = sum(1 for blocks in root.get("hooks", {}).values()
          for b in blocks
          for h in b.get("hooks", [])
          if sys.argv[2] in h.get("command", ""))
print(n)
PY
}

# Every event the installer registers must end up with exactly one of our commands.
one_per_event() { # $1=settings.json
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
          "Notification", "PermissionRequest", "SessionStart"]
hooks = json.load(open(sys.argv[1])).get("hooks", {})
for e in EVENTS:
    n = sum(1 for b in hooks.get(e, []) for h in b.get("hooks", [])
              if "spectix-status.sh" in h.get("command", ""))
    if n != 1:
        print(f"{e}={n}"); sys.exit(1)
print("ok")
PY
}

RC=0
OUTF=$ROOT/installer-output.txt
# Output goes to a file, not to stdout of a $(...) call: the exit code has to reach
# the caller, and a function run inside command substitution sets $RC in a subshell
# the caller never sees — the check would then read a stale 0 and pass no matter what
# the installer did.
run_installer() { # $1=sandbox root  → output in $OUTF, exit code in $RC
  SPECTIX_INSTALL_HEADLESS=1 SPECTIX_INSTALL_ROOT="$1" "$INSTALLER" > "$OUTF" 2>&1
  RC=$?
}

# What the sandbox promises to leave alone. Snapshot before anything runs.
REAL_SETTINGS=$HOME/.claude/settings.json
REAL_HASH_BEFORE=$(shasum "$REAL_SETTINGS" 2>/dev/null | cut -d' ' -f1)
REAL_APP_BEFORE=$([ -e /Applications/SpectiX.app ] && echo yes || echo no)
APP_RUNNING_BEFORE=$(pgrep -x SpectiX > /dev/null && echo yes || echo no)

# Assertions that must hold after ANY successful install, either scenario.
assert_installed() { # $1=sandbox root  $2=label prefix
  local p="$2" h="$1/home" a="$1/Applications"
  [ -d "$a/SpectiX.app" ] && ok "$p SpectiX.app 已安装" || bad "$p SpectiX.app 未安装"
  [ ! -e "$a/TaskBeacon.app" ] && ok "$p 无旧 TaskBeacon.app" || bad "$p 旧 TaskBeacon.app 仍在"

  [ -x "$h/.claude/hooks/spectix-status.sh" ] && ok "$p spectix-status.sh 已装且可执行" \
    || bad "$p spectix-status.sh 缺失或不可执行"
  [ -f "$h/.claude/hooks/spectix-usage.py" ] && ok "$p spectix-usage.py 已装" \
    || bad "$p spectix-usage.py 缺失"
  [ -z "$(ls "$h/.claude/hooks" 2>/dev/null | grep taskbeacon)" ] \
    && ok "$p hooks/ 无旧脚本" || bad "$p hooks/ 仍有旧脚本"

  local s="$h/.claude/settings.json"
  check "$([ "$(count_cmds "$s" taskbeacon)" = 0 ] && echo 1 || echo 0)" \
        "$p settings.json 无旧 hook 条目（双写守卫）"
  check "$([ "$(one_per_event "$s")" = ok ] && echo 1 || echo 0)" \
        "$p settings.json 每个事件恰好一条我们的 hook"
  check "$([ "$(count_cmds "$s" my-own-thing)" = 1 ] && echo 1 || echo 0)" \
        "$p 第三方 hook 未被误删"
  check "$(/usr/bin/python3 -c "import json;print(1 if json.load(open('$s')).get('model')=='opus' else 0)")" \
        "$p settings.json 其余配置未被覆写"

  [ -d "$h/.vscode/extensions/spectix.focus-$EXT_VERSION" ] \
    && ok "$p 扩展 ID 为新的 spectix.focus" || bad "$p 未装 spectix.focus-$EXT_VERSION"
  [ -z "$(ls -d "$h"/.vscode/extensions/taskbeacon.focus-* 2>/dev/null)" ] \
    && ok "$p 无旧扩展 taskbeacon.focus" || bad "$p 旧扩展 taskbeacon.focus 仍在"
}

# ═════════════════════════════════════════════════ F2 全新机器
echo "F2 全新机器路径"
F2=$ROOT/fresh
mkdir -p "$F2/home/.vscode/extensions" "$F2/Applications"
seed_settings "$F2/home" ""

run_installer "$F2"
check "$([ "$RC" = 0 ] && echo 1 || echo 0)" "F2 安装器退出码 0"
if grep -q FAIL "$OUTF"; then bad "F2 安装器报告了失败步骤：$(grep FAIL "$OUTF")"
else ok "F2 三步全部成功"; fi
assert_installed "$F2" "F2"

# The installer doesn't create the state directory — the hook does, on its first
# event. So fire it once, which is also the only way to prove the wired script and
# the app agree on WHERE state lives (the T172 B2 three-way rename).
#
# Two things about this invocation are load-bearing, both learned the hard way:
#   • `< /dev/null` — the hook opens with `input=$(cat)` to read Claude Code's JSON
#     payload. Run from a terminal that happens to be at EOF it returns instantly;
#     run from anything holding stdin open (a background job, CI) it blocks forever.
#   • `script` — the hook keys state on the first ancestor owning a tty and exits 0
#     doing NOTHING when it finds none. Without a pty this assertion would quietly
#     pass or fail depending on who invoked the harness.
# The deadline is the backstop: a hang must surface as a failed check, not as a
# test run that never returns.
HOOKHOME=$F2/home
HOME="$HOOKHOME" /usr/bin/script -q /dev/null \
  "$HOOKHOME/.claude/hooks/spectix-status.sh" working < /dev/null > /dev/null 2>&1 &
HOOKPID=$!
( sleep 20; kill -9 $HOOKPID 2>/dev/null ) 2>/dev/null &
KILLER=$!
wait $HOOKPID 2>/dev/null
kill $KILLER 2>/dev/null
[ -d "$HOOKHOME/.claude/spectix" ] && ok "F2 hook 首次触发生成 ~/.claude/spectix/" \
  || bad "F2 hook 未生成 ~/.claude/spectix/"
[ ! -e "$HOOKHOME/.claude/taskbeacon" ] && ok "F2 未写旧目录 ~/.claude/taskbeacon/" \
  || bad "F2 仍在写旧目录 ~/.claude/taskbeacon/"

# ═════════════════════════════════════════════════ F3 旧装机升级
echo
echo "F3 旧装机升级路径"
F3=$ROOT/upgraded
OLDHOME=$F3/home
mkdir -p "$OLDHOME/.claude/hooks" "$OLDHOME/.claude/taskbeacon/icons" \
         "$OLDHOME/.vscode/extensions/taskbeacon.focus-0.0.5" \
         "$F3/Applications/TaskBeacon.app/Contents/MacOS"

echo '<plist/>' > "$F3/Applications/TaskBeacon.app/Contents/Info.plist"
echo '#!/bin/bash' > "$OLDHOME/.claude/hooks/taskbeacon-status.sh"
chmod +x "$OLDHOME/.claude/hooks/taskbeacon-status.sh"
echo '# old' > "$OLDHOME/.claude/hooks/taskbeacon-usage.py"
echo '{"name":"focus"}' > "$OLDHOME/.vscode/extensions/taskbeacon.focus-0.0.5/package.json"
# State worth carrying over, not regenerable: the work-time log and the icons.
echo '{"ts":1,"event":"done"}' > "$OLDHOME/.claude/taskbeacon/events.jsonl"
echo PNG > "$OLDHOME/.claude/taskbeacon/icons/proj.png"
seed_settings "$OLDHOME" '~/.claude/hooks/taskbeacon-status.sh'

run_installer "$F3"
check "$([ "$RC" = 0 ] && echo 1 || echo 0)" "F3 安装器退出码 0"
if grep -q FAIL "$OUTF"; then bad "F3 安装器报告了失败步骤：$(grep FAIL "$OUTF")"
else ok "F3 三步全部成功"; fi
assert_installed "$F3" "F3"

[ ! -e "$OLDHOME/.claude/taskbeacon" ] && ok "F3 旧状态目录已让位（无双写）" \
  || bad "F3 旧状态目录仍在 —— 新旧两份状态并存"
[ -f "$OLDHOME/.claude/spectix/events.jsonl" ] && ok "F3 事件日志已迁到新目录" \
  || bad "F3 事件日志丢失"
[ -f "$OLDHOME/.claude/spectix/icons/proj.png" ] && ok "F3 自定义图标已迁到新目录" \
  || bad "F3 自定义图标丢失"

# ═════════════════════════════════════════════════ 沙箱边界
echo
echo "沙箱边界"
[ "$(shasum "$REAL_SETTINGS" 2>/dev/null | cut -d' ' -f1)" = "$REAL_HASH_BEFORE" ] \
  && ok "真实 ~/.claude/settings.json 未被改动" || bad "真实 settings.json 被改动了"
[ "$([ -e /Applications/SpectiX.app ] && echo yes || echo no)" = "$REAL_APP_BEFORE" ] \
  && ok "真实 /Applications 未被改动" || bad "真实 /Applications 被改动了"
if [ "$APP_RUNNING_BEFORE" = yes ]; then
  pgrep -x SpectiX > /dev/null && ok "开发机上运行中的 SpectiX 未被测试杀掉" \
    || bad "测试把开发机上运行中的 SpectiX 杀掉了"
else
  echo "  SKIP  开发机上本来就没在跑 SpectiX（无法验证 quitRunningApp 的沙箱守卫）"
fi

echo
if [ $FAILED = 0 ]; then echo "✅ install-check 全部通过"; else echo "❌ install-check 有失败项"; fi
exit $FAILED
