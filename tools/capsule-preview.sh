#!/bin/bash
# Look at the menu-bar pill (MenuCapsule.swift) without a screen.
#
#   ./tools/capsule-preview.sh [outdir]      # default: /tmp/spectix-capsule
#
# Same shape as tools/row-preview.sh: the view reaches into Theme/Status/AppSettings,
# so there is no small subset — the whole app compiles, minus main.swift's entry point.
# Sources are staged first so another session saving a .swift file mid-compile can't
# abort it ("input file was modified during the build", which reads like an error in
# your own code and is not).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/spectix-capsule}"
mkdir -p "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp ./*.swift "$STAGE/"

MARK='^// MARK: - Entry point$'
grep -q "$MARK" "$STAGE/main.swift" || {
  echo "❌ main.swift no longer has the line '// MARK: - Entry point' above its entry code." >&2
  echo "   Update MARK in $0 to whatever now separates the app's entry point." >&2
  exit 1
}
sed "\\#$MARK#,\$d" "$STAGE/main.swift" > "$STAGE/AppMain.swift"
rm "$STAGE/main.swift"
mkdir "$STAGE/entry"
cp tools/capsule-preview/main.swift "$STAGE/entry/main.swift"

echo "compiling (whole app, -Onone)…"
swiftc -Onone -suppress-warnings -D DEV_BUILD "$STAGE"/*.swift "$STAGE/entry/main.swift" \
  -o "$STAGE/render" -framework Cocoa -framework Carbon

"$STAGE/render" "$OUT"
echo
echo "open $OUT"
