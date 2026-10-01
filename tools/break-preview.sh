#!/bin/bash
# Render the break-timer chip + strip (BreakReminder.swift) to PNG, every phase, both
# appearances — run after touching BreakReminder.swift.
#
# ./tools/break-preview.sh [outdir]     # default: /tmp/spectix-break
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/spectix-break}"
mkdir -p "$OUT"
# The strip loads its photos through Bundle.main.resourceURL; for a bare binary that is
# the binary's own directory, so the two photos are placed beside it.
cp tools/cat-stretch.jpg tools/cat-glasses.jpg "$OUT/"
swiftc -Onone \
  BreakReminder.swift Impact.swift Stats.swift \
  Theme.swift ThemeSpec.swift ThemeRegistry.swift ThemeDefault.swift ThemeClay.swift \
  L10n.swift AppSettings.swift Pro.swift Tips.swift \
  tools/break-preview/stubs.swift tools/break-preview/main.swift \
  -o "$OUT/render" -framework Cocoa
"$OUT/render" "$OUT"
echo "open $OUT"
