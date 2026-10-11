#!/bin/bash
# Does refreshing the session list leak AppKit dependency objects? (T318)
#
#   ./tools/list-leak-probe.sh            # exit 1 if a reload re-inserts cells
#
# Offscreen and self-contained — no running app, no live session needed (unlike
# menubar-leak-probe.sh). Compiles the whole app the same way row-preview.sh does; see
# tools/list-leak-probe/main.swift for what is measured and why.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp ./*.swift "$STAGE/"

MARK='^// MARK: - Entry point$'
grep -q "$MARK" "$STAGE/main.swift" || {
  echo "❌ main.swift no longer has the line '// MARK: - Entry point' above its entry code." >&2
  exit 1
}
sed "\\#$MARK#,\$d" "$STAGE/main.swift" > "$STAGE/AppMain.swift"
rm "$STAGE/main.swift"
mkdir "$STAGE/entry"
cp tools/list-leak-probe/main.swift "$STAGE/entry/main.swift"

echo "compiling (whole app, -Onone)…"
swiftc -Onone -suppress-warnings -D DEV_BUILD "$STAGE"/*.swift "$STAGE/entry/main.swift" \
  -o "$STAGE/probe" -framework Cocoa -framework Carbon

"$STAGE/probe"
