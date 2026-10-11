#!/bin/bash
# Pin down how a VSCode terminal label is read (PaneLabel.swift) — no VSCode, no AX.
#
#   ./tools/pane-label-check.sh
#
# Includes labels with a tail sentence VSCode has never shipped: the parse must still
# name the pane from the manifest alone (docs/focus-ring.md ★ aria 文案). Exits 1 on
# any failed case.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/pane-label-check"
swiftc PaneLabel.swift tools/pane-label-check/main.swift -o "$BIN"
"$BIN"
