#!/bin/bash
# Pin down which model ids read as a 1M context window (ContextWindow.swift).
#
#   ./tools/context-window-check.sh
#
# Includes ids no shipped model has yet: a new native-1M model must not be read as
# 200k (docs/row-display.md, 逐行 context 占用 %). Exits 1 on any failed case.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/context-window-check"
swiftc ContextWindow.swift tools/context-window-check/main.swift -o "$BIN"
"$BIN"
