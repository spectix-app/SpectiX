#!/bin/bash
# Promo stills for one feature: English UI, demo data, default theme, light + dark.
# Run THROUGH term.sh (needs Terminal's grants):
#   tools/readme-shots/term.sh 'APP="$PWD/SpectiX Dev.app" FEATURE=quick-actions bash tools/readme-shots/shoot-feature.sh'
# Add a feature = add a case to shots() below. Helpers: swiftc -O tools/readme-shots/{winlist,mouse}.swift -o /tmp/spectix-media/{winlist,mouse}
set -u
FEATURE=${FEATURE:?FEATURE=<name>}
OUT=${OUT:-/tmp/spectix-media/promo/$FEATURE}; BIN=/tmp/spectix-media
DOM=app.spectix.SpectiX.dev
X=620; Y=33; W=488; H=${H:-640}
mkdir -p "$OUT"
saved=()
for k in themeID appearance demoMode language; do saved+=("$k=$(defaults read $DOM $k 2>/dev/null || echo __unset)"); done

se()   { osascript -e "tell application \"System Events\" to tell process \"SpectiX Dev\" to $1" >/dev/null; }
wid()  { "$BIN/winlist" | awk -v n="$1" '$7==n{print $1; exit}'; }
snap() { screencapture -o -x -l "$1" "$OUT/$2.png"; echo "shot $2"; }
park() { se "set position of (first window whose name is \"SpectiX\") to {$X, $Y}"
         se "set size of (first window whose name is \"SpectiX\") to {$W, $H}"; sleep 0.8; }
click() { "$BIN/mouse" click $((X + $1)) $((Y + $2)); sleep "${3:-1.2}"; }
launch() {   # appearance
    defaults write $DOM demoMode -bool true
    defaults write $DOM language en
    defaults write $DOM themeID default; defaults write $DOM appearance "$1"
    rm -f "${TMPDIR:-/tmp/}spectix-demo-actions.json"
    pkill -x SpectiX; sleep 1; open "$APP"; sleep 4; open "$APP"; sleep 2; park
    "$BIN/mouse" move 1500 1000; sleep 1
}

shots() {   # look window-id
    case $FEATURE in
    quick-actions)
        snap "$2" "0-sessions-$1"
        click $((W - 23)) $((H - 22)); "$BIN/mouse" move 1500 1000; sleep 0.8
        snap "$2" "1-drawer-$1"
        click ${TILE_X:-80} ${TILE_Y:-0} 1.5; "$BIN/mouse" move 1500 1000; sleep 0.5
        snap "$2" "2-running-$1"
        sleep 5; snap "$2" "3-done-$1"
        ;;
    *) echo "unknown FEATURE=$FEATURE" >&2; return 1 ;;
    esac
}

for look in dark light; do
    launch $look; shots $look "$(wid SpectiX)"
done

for kv in "${saved[@]}"; do
    k=${kv%%=*}; v=${kv#*=}
    if [ "$v" = __unset ]; then defaults delete $DOM "$k" 2>/dev/null
    elif [ "$k" = demoMode ]; then defaults write $DOM demoMode -bool "$([ "$v" = 1 ] && echo true || echo false)"
    else defaults write $DOM "$k" "$v"; fi
done
pkill -x SpectiX; sleep 1; open "$APP"
echo "done → $OUT"
