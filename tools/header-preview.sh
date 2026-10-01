#!/bin/bash
# Render the header quota strip (QuotaTrio / MetricCard / MetricLine) to PNG at several widths.
#
# ./tools/row-preview.sh [outdir]       # default: /tmp/spectix-header
#
# Run this after touching the trio strip, its slots or the account cards — see tools/header-preview/main.swift.
# One sheet per theme × appearance: rest at three widths, then hover on the Claude column.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/spectix-header}"
mkdir -p "$OUT"

# Unlike panel-preview this compiles the WHOLE app: the row cells reach into the
# session model, the account book and half of main.swift, so there is no small subset.
# The sources are copied first so another session saving a .swift file mid-compile
# can't abort it ("input file was modified during the build").
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp ./*.swift "$STAGE/"

# main.swift ends in the app's entry point (NSApplication.run). The renderer needs its
# own, so everything from the entry marker down is dropped and the rest recompiled as a
# plain source file. If the marker is ever renamed, sed would keep the whole file and
# swiftc would fail with a baffling "expressions are not allowed at the top level".
# '#' as the sed address delimiter: the marker itself is full of slashes.
MARK='^// MARK: - Entry point$'
grep -q "$MARK" "$STAGE/main.swift" || {
  echo "❌ main.swift no longer has the line '// MARK: - Entry point' above its entry code." >&2
  echo "   Update MARK in $0 to whatever now separates the app's entry point." >&2
  exit 1
}
sed "\\#$MARK#,\$d" "$STAGE/main.swift" > "$STAGE/AppMain.swift"
rm "$STAGE/main.swift"
mkdir "$STAGE/entry"
cp tools/header-preview/main.swift "$STAGE/entry/main.swift"

echo "compiling (whole app, -Onone)…"
swiftc -Onone -suppress-warnings -D DEV_BUILD "$STAGE"/*.swift "$STAGE/entry/main.swift" \
  -o "$STAGE/render" -framework Cocoa -framework Carbon

"$STAGE/render" "$OUT"
echo
echo "open $OUT"
