#!/bin/bash
# One-step logo swap. tools/AppIcon.png is the SINGLE SOURCE for every logo
# surface — the app icon (Dock/Finder/System-Settings, via AppIcon.icns that
# build.sh generates from it) AND every in-app mark (main-window header,
# session-tab / popover statsHeader), which all read NSApp.applicationIconImage.
# Replace that one file and everything updates.
#
# This script normalizes any source image into tools/AppIcon.png:
#   1. auto-trim a solid-colour or transparent border (any shade — white,
#      black, brand colour) down to the artwork's bounding box
#   2. pad to a square so sips -z can't distort it
#   3. apply macOS rounded corners
# then rebuilds the app and refreshes icon caches.
#
# Usage: ./tools/set-logo.sh <image> [--no-trim] [--no-build]
#   --no-trim   keep the source framing as-is (skip border auto-crop)
#   --no-build  only update tools/AppIcon.png, skip rebuild
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: ./tools/set-logo.sh <image> [--no-trim] [--no-build]}"
TRIM=1; BUILD=1
shift
for a in "$@"; do
  case "$a" in
    --no-trim) TRIM=0 ;;
    --no-build) BUILD=0 ;;
    --trim) ;;                                # accepted for backwards-compat, now default
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

python3 - "$SRC" "$TRIM" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageChops
src, trim = sys.argv[1], sys.argv[2] == "1"
im = Image.open(src).convert("RGBA")
w, h = im.size

if trim:                                      # crop a uniform border (any shade / transparent)
    alpha = im.getchannel("A")
    bb = None
    if alpha.getextrema()[0] < 10:            # image has real transparency -> crop to opaque area
        bb = alpha.point(lambda p: 255 if p > 10 else 0).getbbox()
    else:                                     # opaque image -> detect a solid background from corners
        rgb = im.convert("RGB")
        corners = [rgb.getpixel(p) for p in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]]
        close = lambda a, b: all(abs(a[i] - b[i]) <= 12 for i in range(3))
        if all(close(corners[0], c) for c in corners[1:]):
            bg = tuple(sorted(c[i] for c in corners)[len(corners) // 2] for i in range(3))
            diff = ImageChops.difference(rgb, Image.new("RGB", im.size, bg)).convert("L")
            bb = diff.point(lambda p: 255 if p > 32 else 0).getbbox()
    if bb and bb != (0, 0, w, h):
        im = im.crop(bb)
        print(f"trimmed border -> bbox {bb}")

w, h = im.size                                # pad to square so sips -z won't distort
s = max(w, h)
if (w, h) != (s, s):
    sq = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sq.paste(im, ((s - w) // 2, (s - h) // 2))
    im = sq

S, r = 4, int(s * 0.2237)                     # macOS rounded-corner mask, 4x supersampled
m = Image.new("L", (s * S, s * S), 0)
ImageDraw.Draw(m).rounded_rectangle([0, 0, s * S - 1, s * S - 1], radius=r * S, fill=255)
m = m.resize((s, s), Image.LANCZOS)
im.putalpha(ImageChops.darker(im.getchannel("A"), m))

im.save("tools/AppIcon.png")
print(f"wrote tools/AppIcon.png  {s}x{s}  rounded r={r}  trim={trim}")
PY

if [ "$BUILD" = "0" ]; then
  echo "ℹ️  tools/AppIcon.png updated — run ./build.sh to apply."
  exit 0
fi

./build.sh
pkill -x SpectiX 2>/dev/null || true
sleep 1
open SpectiX.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREG" -f "$(pwd)/SpectiX.app"
killall Dock 2>/dev/null || true
echo "✅ logo swapped + app rebuilt + icon caches refreshed"
