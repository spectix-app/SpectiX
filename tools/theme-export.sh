#!/bin/bash
# Regenerate docs/themes/{default,clay}.json from the built-in themes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/spectix-theme-export"
swiftc -O -o "$BIN" -framework Cocoa \
  "$ROOT/ThemeSpec.swift" "$ROOT/ThemeDefault.swift" "$ROOT/ThemeClay.swift" \
  "$ROOT/ThemeFile.swift" "$ROOT/tools/theme-export/main.swift"
"$BIN" "$ROOT/docs/themes"
