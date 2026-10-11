#!/bin/bash
# Pin which pane dots the tab-stack rule hides (PipStack.swift) — no VSCode, no AX.
#
#   ./tools/pip-stack-check.sh
#
# Covers the stale-memo case (T328): after a divider drag or sidebar resize a hidden
# terminal's dot must stay hidden, while split panes both keep theirs. Exits 1 on any
# failed case.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/pip-stack-check"
swiftc PipStack.swift tools/pip-stack-check/main.swift -o "$BIN"
"$BIN"
