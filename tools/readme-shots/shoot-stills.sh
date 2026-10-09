#!/bin/bash
# Stills for README / website, demo data only. Run THROUGH term.sh (needs Terminal's grants):
#   tools/readme-shots/term.sh 'APP="<path to SpectiX Dev.app>" bash tools/readme-shots/shoot-stills.sh'
# Shoots from whatever APP points at — build it from committed HEAD (git archive) so unreleased
# work-in-progress from other tabs never reaches marketing images.
set -u
OUT=${OUT:-/tmp/spectix-media/stills}; BIN=/tmp/spectix-media
DOM=app.spectix.SpectiX.dev
X=620; Y=33; W=488; H=${H:-700}          # main window, parked on the built-in Retina display
mkdir -p "$OUT"
prev_theme=$(defaults read $DOM themeID 2>/dev/null || echo default)
prev_app=$(defaults read $DOM appearance 2>/dev/null || echo system)
prev_demo=$(defaults read $DOM demoMode 2>/dev/null || echo 0)

se()   { osascript -e "tell application \"System Events\" to tell process \"SpectiX Dev\" to $1" >/dev/null; }
wid()  { "$BIN/winlist" | awk -v n="$1" '$7==n{print $1; exit}'; }
snap() { screencapture -o -x -l "$1" "$OUT/$2.png"; echo "shot $2"; }
park() { se "set position of (first window whose name is \"SpectiX\") to {$X, $Y}"
         se "set size of (first window whose name is \"SpectiX\") to {$W, $H}"; sleep 0.8; }
tab()  { local xs=(54 150 244 338 433); "$BIN/mouse" click $((X + xs[$1])) $((Y + H - 22)); sleep 1.2; }
launch() {   # theme appearance
    defaults write $DOM demoMode -bool true
    defaults write $DOM themeID "$1"; defaults write $DOM appearance "$2"
    pkill -x SpectiX; sleep 1; open "$APP"; sleep 4; open "$APP"; sleep 2; park
    "$BIN/mouse" move 1500 1000; sleep 1      # pointer off the list: no stray hover
}

for theme in default clay; do for look in light dark; do
    launch $theme $look; w=$(wid SpectiX); s="$theme-$look"
    snap "$w" "sessions-$s"
    "$BIN/mouse" move $((X + 200)) $((Y + 175)); sleep 1.2; snap "$w" "hover-row-$s"
    "$BIN/mouse" move $((X + 200)) $((Y + 130)); sleep 1.2; snap "$w" "hover-group-$s"
    "$BIN/mouse" move 1500 1000; sleep 0.8
    if [ $theme = default ]; then
        tab 1; snap "$w" "stats-$s"; tab 3; snap "$w" "skills-$s"; tab 4; snap "$w" "settings-$s"; tab 0
        # popover: click the status item (the open hotkey is user-rebindable, the item isn't);
        # it is the layer-25 window wider than the 24pt status-item sliver
        se 'click menu bar item 1 of menu bar 2'; sleep 1.5
        p=$("$BIN/winlist" | awk '$6==25 && $4>200 {print $1; exit}'); [ -n "$p" ] && snap "$p" "popover-$s"
        osascript -e 'tell application "System Events" to key code 53'; sleep 0.8
        # account panel: an overlay INSIDE the main window. The header only takes the click
        # once the window is frontmost and the pointer has hovered the card first.
        se 'set frontmost to true'; sleep 0.5
        "$BIN/mouse" move $((X + 220)) $((Y + 95)); sleep 0.8
        "$BIN/mouse" click $((X + 225)) $((Y + 97)); sleep 1.5; snap "$w" "accounts-$s"
        osascript -e 'tell application "System Events" to key code 53'; sleep 0.8
    fi
done; done

defaults write $DOM themeID "$prev_theme"; defaults write $DOM appearance "$prev_app"
[ "$prev_demo" = 1 ] && defaults write $DOM demoMode -bool true || defaults write $DOM demoMode -bool false
echo "done → $OUT"
