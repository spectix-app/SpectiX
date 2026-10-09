#!/bin/bash
# Every clip of the launch tour (T338), demo data only, in one ~2.5 min run. Run THROUGH term.sh.
# The main window is parked TALL (the shape people actually keep it in) on the built-in display,
# over a black backdrop, so no desktop / menu bar / Dock reaches a frame.
#   CAL=1 shoot-tour.sh   → set everything up, screenshot the display to $BIN/cal.png, stop.
# The VS Code take needs the aurora-web scratch folder TRUSTED once (Restricted Mode disables the
# companion extension, and without it no pane exists): CAL=1 opens it, trust it by hand once.
# Hands off the machine while it runs: switching Space or app mid-take ruins it.
set -u
OUT=${OUT:-/tmp/spectix-media/clips2}; BIN=/tmp/spectix-media
DOM=app.spectix.SpectiX.dev
APP=${APP:-$(cd "$(dirname "$0")/../.." && pwd)/SpectiX Dev.app}
X=200; Y=40; W=460; H=1060                    # tall main window; bottom stays clear of the Dock edge
TPOS="700, 260"; TSIZE="640, 420"             # staged Terminal (notes-api), right of the window
VPOS="{456, 33}"; VSIZE="{1272, 1084}"       # VS Code on the aurora-web scratch folder, right of the window
# Toasts land top-right (x ≥ ~1400): every wide region stops short of it except attention's,
# and the VS Code take runs 15s after the last toast (notes-api done, ~25s).
R_WIN="$((X-10)),$((Y-4)),$((W+20)),$((H+8))"
R_TERM="190,36,1160,1068"
R_VS="0,33,1728,1084"                          # VS Code take: window at x 0, VS Code fills the rest
R_ATT="190,36,1538,1068"
# Points inside the window, from a CAL screenshot (window at X,Y above).
ROW_NOTES=${ROW_NOTES:-"400 413"}             # notes-api session row
ROW_AURORA=${ROW_AURORA:-"400 230"}           # aurora-web "Wire the checkout flow" row
HDR_MAC=${HDR_MAC:-"279 139"}; HDR_CLAUDE=${HDR_CLAUDE:-"439 139"}; HDR_CODEX=${HDR_CODEX:-"585 139"}
ACCT2=${ACCT2:-"371 315"}                     # second account in the Claude panel
SVC_OPEN=${SVC_OPEN:-"565 337"}               # :5173 Open
SVC_STOP=${SVC_STOP:-"607 468"}               # :8000 Stop
TAB_SESS=${TAB_SESS:-"252 1070"}; TAB_STATS=${TAB_STATS:-"343 1070"}
TAB_RECENT=${TAB_RECENT:-"429 1070"}; TAB_SKILLS=${TAB_SKILLS:-"518 1070"}
STAGED="$(getconf DARWIN_USER_TEMP_DIR)spectix-demo-staged.json"
PANE="$(getconf DARWIN_USER_TEMP_DIR)spectix-demo-panes/aurora-web"   # = Demo.paneRoot/aurora-web
mkdir -p "$OUT"
prev_demo=$(defaults read $DOM demoMode 2>/dev/null || echo 0)
# The owner may have rebound next-attention to ⌘2, which the main window's own tab switch
# (⌘1–⌘5) swallows while it is key. Film the shipped default ⌃⌥⌘N, put theirs back after.
prev_hk_key=$(defaults read $DOM hotkey.2.keyCode 2>/dev/null || echo)
prev_hk_mod=$(defaults read $DOM hotkey.2.modifiers 2>/dev/null || echo)
se()  { osascript -e "tell application \"System Events\" to tell process \"SpectiX Dev\" to $1" >/dev/null; }
sev() { osascript -e "tell application \"System Events\" to tell process \"Code\" to $1" >/dev/null; }
key() { osascript -e "tell application \"System Events\" to $1" >/dev/null; }
m()   { "$BIN/mouse" "$@"; }
# Re-raise the backdrop before every take: killing/relaunching an app lets macOS activate the
# next one (Finder), whose windows then sit above the backdrop.
front() { kill -USR1 $BD; sleep 0.4; se 'set frontmost to true'; sleep 0.4; }
rec() { front; screencapture -v -x -V "$1" -R "$3" "$OUT/$2.mov" & REC=$!; }   # secs name region
# `wait` alone would also wait on the backdrop, which never exits.
done_rec() { wait $REC; echo "clip $1"; }
staged_wid() { python3 -c "import json;print(json.load(open('$STAGED'))[0]['wid'])" 2>/dev/null; }
park() { m move 1500 1000; }
palette() { key 'keystroke "p" using {command down, shift down}'; sleep 0.7; key "keystroke \"$1\""; sleep 0.7; key 'key code 36'; sleep 0.8; }
# zsh shells sitting in the pane folder, lowest pid first (the pane — same rule as Demo.panePid).
pane_pids() { lsof -a -d cwd -c zsh -Fpn 2>/dev/null | awk -v w="$(cd "$PANE" && pwd -P)" '/^p/{p=substr($0,2)} /^n/{if(substr($0,2)==w) print p}' | sort -n; }
cleanup() {
    kill $BD 2>/dev/null
    # The aurora-web VS Code window stays: closing it kills whatever its terminals run.
    [ "$prev_demo" = 1 ] || defaults write $DOM demoMode -bool false   # app then closes its window
    if [ -n "$prev_hk_key" ]; then defaults write $DOM hotkey.2.keyCode -int "$prev_hk_key"
                                  defaults write $DOM hotkey.2.modifiers -int "$prev_hk_mod"
    else defaults delete $DOM hotkey.2.keyCode 2>/dev/null; defaults delete $DOM hotkey.2.modifiers 2>/dev/null; fi
}
trap cleanup EXIT

# ---- VS Code scratch project: fake files, and a window stripped of the owner's chrome ----
mkdir -p "$PANE/.vscode" "$PANE/src/checkout" "$PANE/api/payments"
cat > "$PANE/.vscode/settings.json" <<'EOF'
{
  "workbench.startupEditor": "none",
  "workbench.secondarySideBar.defaultVisibility": "hidden",
  "workbench.statusBar.visible": false,
  "workbench.activityBar.location": "hidden",
  "workbench.layoutControl.enabled": false,
  "window.commandCenter": false,
  "chat.commandCenter.enabled": false,
  "breadcrumbs.enabled": false,
  "editor.minimap.enabled": false,
  "git.enabled": true,
  "gitlens.showWhatsNewAfterUpgrades": false
}
EOF
cat > "$PANE/src/checkout/CheckoutSheet.tsx" <<'EOF'
import { usePaymentIntent } from "./usePaymentIntent";
import { Button, Sheet, Summary } from "@aurora/ui";

export function CheckoutSheet({ cart, onClose }: CheckoutSheetProps) {
  const { intent, confirm, status } = usePaymentIntent(cart.total);

  return (
    <Sheet open onClose={onClose} title="Checkout">
      <Summary items={cart.items} total={cart.total} />
      <Button
        disabled={!intent || status === "pending"}
        onClick={() => confirm()}
      >
        Pay {formatPrice(cart.total)}
      </Button>
    </Sheet>
  );
}
EOF
printf 'export function usePaymentIntent(total: number) {\n  // …\n}\n' > "$PANE/src/checkout/usePaymentIntent.ts"
printf 'export async function createPaymentIntent(amount: number) {\n  // …\n}\n' > "$PANE/api/payments/intent.ts"
printf '{ "name": "aurora-web", "private": true }\n' > "$PANE/package.json"

osascript -e 'tell application "Terminal" to set bounds of front window to {1250, 820, 1700, 1100}'   # this runner, out of frame
defaults write $DOM demoMode -bool true
defaults write $DOM hotkey.2.keyCode -int 45; defaults write $DOM hotkey.2.modifiers -int 6400   # N, ⌃⌥⌘
defaults write $DOM themeID default; defaults write $DOM appearance "${LOOK:-dark}"
"$BIN/backdrop" 0 33 1728 1084 & BD=$!; sleep 1

# VS Code first: its terminals must exist before the app's first refresh can see the pane.
open -b com.microsoft.VSCode "$PANE"; sleep 5
open -b com.microsoft.VSCode "$PANE/src/checkout/CheckoutSheet.tsx"; sleep 2
vw='(first window whose name contains "aurora-web")'
for _ in $(seq 1 10); do sev "set position of $vw to $VPOS" 2>/dev/null && break; sleep 1; done
sev "set size of $vw to $VSIZE"; sev "perform action \"AXRaise\" of $vw"
osascript -e 'tell application "Visual Studio Code" to activate'; sleep 1
if [ -z "$(pane_pids)" ]; then
    key 'keystroke "`" using control down'; sleep 2.5      # terminal 1 = the pane
    key 'keystroke "\\" using command down'; sleep 3       # split = scenery
fi
# Paint both over their prompts (user@host): the pane gets a Claude Code screen, the other Vite.
python3 - $(pane_pids) <<'PY'
import subprocess, sys
pids = [int(a) for a in sys.argv[1:]]
# A shell with a child is running something (the owner may start claude in it): leave it be.
busy = lambda p: subprocess.run(["pgrep", "-P", str(p)], capture_output=True).returncode == 0
tty = lambda p: subprocess.run(["ps", "-o", "tty=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
E = "\x1b"; dim, bold, orange, cyan, green, off = E+"[2m", E+"[1m", E+"[38;5;209m", E+"[36m", E+"[32m", E+"[0m"
clear = E+"[2J"+E+"[3J"+E+"[H"
pane = [" "+orange+"✻"+off+" "+bold+"Claude Code"+off+" "+dim+"· Opus 5"+off, "   "+dim+"~/Developer/aurora-web"+off, "",
        " "+dim+">"+off+" Wire the checkout flow to the new payments API", "",
        " ⏺ "+bold+"Read"+off+"(api/payments/intent.ts)", "   "+dim+"⎿  ok"+off,
        " ⏺ "+bold+"Edit"+off+"(src/checkout/CheckoutSheet.tsx)", "   "+dim+"⎿  ok"+off, "",
        " "+orange+"✻ Working…"+off+" "+dim+"(esc to interrupt)"+off, "", " "+dim+">"+off+" "]
vite = ["", "  "+green+bold+"VITE"+off+" "+green+"v6.2.0"+off+"  "+dim+"ready in"+off+" "+bold+"412"+off+" "+dim+"ms"+off, "",
        "  "+green+"➜"+off+"  "+bold+"Local"+off+":   "+cyan+"http://localhost:"+bold+"5173"+off+cyan+"/"+off,
        "  "+green+"➜"+off+"  "+dim+"Network: use --host to expose"+off, "",
        "  "+dim+"12:04:31"+off+" "+cyan+bold+"[vite]"+off+" "+green+"hmr update"+off+" "+dim+"/src/checkout/CheckoutSheet.tsx"+off]
for p, lines in zip(pids, [pane, vite]):
    t = tty(p)
    if t and t != "??" and not busy(p):
        with open("/dev/" + t, "w") as f: f.write(clear + "\r\n".join(lines))
print("panes", pids)
PY

old=$(staged_wid)
pkill -x SpectiX; sleep 1; open "$APP"; T0=$(date +%s); sleep 4; open "$APP"; sleep 2
# The main window can take a few seconds to show while demo staging runs at launch.
for _ in $(seq 1 10); do se "set position of (first window whose name is \"SpectiX\") to {$X, $Y}" 2>/dev/null && break; sleep 1; done
# Twice: after one programmatic resize the header's three columns can keep the old split.
se "set size of (first window whose name is \"SpectiX\") to {$((W + 1)), $H}"; sleep 0.5
se "set size of (first window whose name is \"SpectiX\") to {$W, $H}"
# Staging lands ~3s after launch (close leftovers, open, wait out the shell prompt).
for _ in $(seq 1 20); do wid=$(staged_wid); [ -n "$wid" ] && [ "$wid" != "$old" ] && break; sleep 1; done
[ -n "$wid" ] && [ "$wid" != "$old" ] || { echo "no staged window (Automation for Terminal denied?)"; exit 1; }
tw="(first window of process \"Terminal\" whose name starts with \"notes-api\")"
osascript -e "tell application \"System Events\" to set position of $tw to {$TPOS}" \
          -e "tell application \"System Events\" to set size of $tw to {$TSIZE}" >/dev/null
front; park

if [ -n "${CAL:-}" ]; then
    sleep 2; screencapture -x -R 0,33,1728,1084 "$BIN/cal.png"
    sev "perform action \"AXRaise\" of $vw"; osascript -e 'tell application "Visual Studio Code" to activate'
    sleep 1.5; screencapture -x -R 0,33,1728,1084 "$BIN/cal-vs.png"
    echo "calibration shots in $BIN"; exit 0      # through cleanup: hotkey and demo flag go back
fi

# notes-api's demo cycle (116s, phase 61), seconds since launch, ±2.5s refresh lag:
# needs 0–11, working 11–25, done 25–55, idle 55–75, working 75–103, needs 103–127.
# aurora-web "Wire the checkout flow" (84s, phase 0): working 0–48, done 48–70, idle 70–84.
at() { local d=$(( T0 + $1 - $(date +%s) )); [ $d -gt 0 ] && sleep $d; }

# 1. the tall list living on its own (notes-api flips needs → working at 11)
at 4;  rec 12 live "$R_WIN"; done_rec live
# 2. click notes-api → its Terminal comes forward, ringed (working = blue)
at 17; rec 10 jump "$R_TERM"; sleep 2; m click $ROW_NOTES; sleep 3; park; done_rec jump
# 3. header: this Mac's load, then each CLI's quota with its reset countdown
at 28; rec 9 header "$R_WIN"; sleep 1; m move $HDR_MAC; sleep 2.5; m move $HDR_CLAUDE; sleep 3
       m move $HDR_CODEX; sleep 2; park; done_rec header
# 4. VS Code, side by side: show a terminal other than the pane, then click aurora-web → VS Code
#    comes forward and switches to the pane, ringed. The window moves to x 0 for this take only.
at 38; sev "perform action \"AXRaise\" of $vw"; osascript -e 'tell application "Visual Studio Code" to activate'; sleep 0.8
       palette "Clear All Notifications"
       target=$(pane_pids | head -1)
       active=$(cut -d: -f1 ~/.claude/spectix/active-terminal 2>/dev/null)
       [ -n "$target" ] && [ "$active" = "$target" ] && palette "Terminal: Focus Next Terminal"
       echo "pane=$target active-before=$active"
       se "set position of (first window whose name is \"SpectiX\") to {0, 33}"
at 42; rec 10 vscode "$R_VS"; sleep 2; m click $(( ${ROW_AURORA% *} - X )) $(( ${ROW_AURORA#* } - Y + 33 )); sleep 3.5; park; done_rec vscode
       se "set position of (first window whose name is \"SpectiX\") to {$X, $Y}"
# 5. accounts: open the Claude card's panel, pick another account (demo: only the check moves)
at 55; rec 10 accounts "$R_WIN"; sleep 1.5; m click $HDR_CLAUDE; sleep 3.5; m click $ACCT2; sleep 2.5
       park; done_rec accounts
       m click $((X + 240)) $((Y + 12)); sleep 0.5   # Esc leaves the panel up, and the next click would only close it
# 6. servers: hover Open on the fresh one, Stop the one up for days (demo: the row just goes)
at 67; rec 11 services "$R_WIN"; sleep 1.5; m move $SVC_OPEN; sleep 2.5; m move $SVC_STOP; sleep 1.5
       m click $SVC_STOP; sleep 3; park; done_rec services
# 7. the other tabs
at 80; rec 13 tabs "$R_WIN"; sleep 1; m click $TAB_STATS; sleep 2; m scroll 430 600 -60; sleep 2.5
       m click $TAB_RECENT; sleep 3; m click $TAB_SKILLS; sleep 1.5; m scroll 430 600 -60; sleep 2; done_rec tabs
       m click $TAB_SESS; park
# 8. needs toast slides in → hotkey jumps there → answered: toast turns ✓
# Toasts open on NSScreen.main = the screen with keyboard focus; a title-bar click makes the
# main window key so the toast lands in frame (built-in top-right), not on the external display.
at 96; m click $((X + 240)) $((Y + 14)); park
at 99; rec 30 attention "$R_ATT"
at 110; key 'keystroke "n" using {control down, option down, command down}'
done_rec attention
