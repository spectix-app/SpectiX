#!/bin/bash
# Account switching against a fake Keychain and a fake CLI whose refresh tokens
# rotate (only the newest generation signs in). Never touches real credentials.
# Run after any change to AccountBook.swift / AgentAccount.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"; defaults delete spectix.accounttest 2>/dev/null || true' EXIT
defaults delete spectix.accounttest 2>/dev/null || true
sed "s|NSHomeDirectory()|testHome|g; s|UserDefaults.standard|testDefaults|g" AccountBook.swift > "$T/AccountBook.swift"
sed "s|NSHomeDirectory()|testHome|g" AgentAccount.swift > "$T/AgentAccount.swift"
cp tools/account-switch-test/*.swift "$T/"
mkdir "$T/home"
swiftc -O -o "$T/t" "$T"/Stubs.swift "$T"/AgentAccount.swift "$T"/AccountBook.swift "$T"/main.swift
"$T/t" "$T/home" a && "$T/t" "$T/home" b
