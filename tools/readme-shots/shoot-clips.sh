#!/bin/bash
# Raw clips for the demo video, demo data only. Run THROUGH term.sh, same APP rule as shoot-stills.sh.
set -u
OUT=${OUT:-/tmp/spectix-media/clips}; BIN=/tmp/spectix-media
DOM=app.spectix.SpectiX.dev
X=620; Y=33; W=488; H=700
mkdir -p "$OUT"
prev_demo=$(defaults read $DOM demoMode 2>/dev/null || echo 0)
se()  { osascript -e "tell application \"System Events\" to tell process \"SpectiX Dev\" to $1" >/dev/null; }
rec() { screencapture -v -x -V "$1" -R "$2" "$OUT/$3.mov" & }   # secs rect name
tab() { local xs=(54 150 244 338 433); "$BIN/mouse" click $((X + xs[$1])) $((Y + H - 22)); }

defaults write $DOM demoMode -bool true
defaults write $DOM themeID default; defaults write $DOM appearance "${LOOK:-light}"
pkill -x SpectiX; sleep 1; open "$APP"; sleep 4; open "$APP"; sleep 2
se "set position of (first window whose name is \"SpectiX\") to {$X, $Y}"
se "set size of (first window whose name is \"SpectiX\") to {$W, $H}"
se 'set frontmost to true'; "$BIN/mouse" move 1500 1000; sleep 1
R="$X,$Y,$W,$H"

# 1. the list living on its own: statuses flip on the demo clock
rec 20 "$R" live; wait; echo "clip live"

# 2. pointer tour: row hover, group hover, agent badge
rec 12 "$R" hover; sleep 1
for y in 175 230 300 350 420 470 520; do "$BIN/mouse" move $((X + 200)) $((Y + y)); sleep 1.4; done
"$BIN/mouse" move 1500 1000; wait; echo "clip hover"

# 3. tab tour
rec 14 "$R" tabs; sleep 1.5
for t in 1 3 4 0; do tab $t; sleep 3; done
wait; echo "clip tabs"

# 4. popover from the menu bar (built-in display's bar; region covers bar + popover)
rec 8 "880,0,560,960" popover; sleep 1.5
se 'click menu bar item 1 of menu bar 2'; sleep 4.5
osascript -e 'tell application "System Events" to key code 53'; wait; echo "clip popover"

# 5. account panel
se 'set frontmost to true'
rec 9 "$R" accounts; sleep 1.5
"$BIN/mouse" move $((X + 220)) $((Y + 95)); sleep 0.8; "$BIN/mouse" click $((X + 225)) $((Y + 97)); sleep 4
osascript -e 'tell application "System Events" to key code 53'; wait; echo "clip accounts"

[ "$prev_demo" = 1 ] && defaults write $DOM demoMode -bool true || defaults write $DOM demoMode -bool false
defaults write $DOM appearance light
echo "done → $OUT"
