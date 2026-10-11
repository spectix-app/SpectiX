#!/bin/bash
# Self-test for release-check.sh's "packaged extension == working tree" gate, run
# against a throwaway bundle so it needs no build, no signing and no real installer.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/Install SpectiX.app"
mkdir -p "$FAKE/Contents/Resources/vscode-extension"
cp vscode-extension/extension.js vscode-extension/package.json "$FAKE/Contents/Resources/vscode-extension/"

ok=1
expect(){ # $1=case  $2=pattern that must appear in the output
  if grep -qF "$2" "$TMP/out"; then echo "ok    $1"; else echo "FAIL  $1 —— 输出里没有「$2」"; ok=0; fi
}

tools/release-check.sh "$FAKE" > "$TMP/out" 2>&1
expect "identical copy passes"  "PASS  包内 vscode-extension/extension.js 与工作区一致"

echo "// stale" >> "$FAKE/Contents/Resources/vscode-extension/extension.js"
tools/release-check.sh "$FAKE" > "$TMP/out" 2>&1
rc=$?
expect "stale copy fails"       "FAIL  包内 vscode-extension/extension.js 与工作区同名文件不一致"
[ "$rc" = 1 ] && echo "ok    stale copy exits 1" || { echo "FAIL  stale copy exited $rc"; ok=0; }

[ "$ok" = 1 ] && echo "selftest passed" || { echo "selftest failed"; exit 1; }
