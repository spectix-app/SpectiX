#!/bin/bash
# Render the 技能 tab (SkillsPane) and the 5-tab bottom bar to PNG.
#
# ./tools/skills-preview.sh [outdir]   # default: /tmp/spectix-skills
#
# Run this after touching SkillsPane.swift or BottomTabBar.swift. One sheet per
# theme × appearance × width — see tools/skills-preview/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/spectix-skills}"
mkdir -p "$OUT"

# Compiles the WHOLE app, same as row-preview: the pane reaches into Demo, Theme and
# ProjectHistory, so there is no small subset.
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
cp tools/skills-preview/main.swift "$STAGE/entry/main.swift"

echo "compiling (whole app, -Onone)…"
swiftc -Onone -suppress-warnings -D DEV_BUILD "$STAGE"/*.swift "$STAGE/entry/main.swift" \
  -o "$STAGE/render" -framework Cocoa -framework Carbon

"$STAGE/render" "$OUT"
echo
echo "open $OUT"
