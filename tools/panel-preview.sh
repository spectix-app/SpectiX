#!/bin/bash
# Render the 效能 panel to PNG so a human (or Claude) can actually LOOK at it.
#
# ./tools/panel-preview.sh [outdir]     # default: /tmp/spectix-panel
#
# Run this after touching ImpactView.swift / Impact.swift / Theme.swift. It reads your
# real logs and writes one PNG per time range. See tools/panel-preview/main.swift for
# what this can and cannot show — notably it does NOT render the blur underneath, so
# judge layout and wording here, colours on the real thing.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/spectix-panel}"
mkdir -p "$OUT"

# Only the files the panel actually needs; main.swift (415KB) is deliberately absent and
# tools/panel-preview/stubs.swift stands in for the two symbols it would have provided.
swiftc -Onone \
  Impact.swift Stats.swift ImpactView.swift \
  Theme.swift ThemeSpec.swift ThemeRegistry.swift ThemeFile.swift ThemeDefault.swift ThemeClay.swift \
  L10n.swift AppSettings.swift Pro.swift Tips.swift \
  tools/panel-preview/stubs.swift tools/panel-preview/main.swift \
  -o "$OUT/render" -framework Cocoa

"$OUT/render" "$OUT"
echo
echo "open $OUT"
