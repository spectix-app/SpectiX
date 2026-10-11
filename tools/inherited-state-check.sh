#!/bin/bash
# Pin down how a fresh Codex row reads a state-<tty> left by the tty's previous
# session (InheritedState.swift, T283) — no codex, no app.
#
#   ./tools/inherited-state-check.sh
#
# Exits 1 on any failed case.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/inherited-state-check"
swiftc InheritedState.swift tools/inherited-state-check/main.swift -o "$BIN"
"$BIN"
