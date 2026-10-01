#!/bin/bash
# Assemble the publishable plugin payload from the canonical hook sources.
#
# The hook scripts live in exactly one place in this repo (../hooks/). This script
# copies them into plugin/hooks/ so the plugin directory becomes a self-contained,
# publishable tree — the same single-source rule the installer follows (it reads the
# hooks out of the app bundle rather than keeping a second hand-maintained copy).
#
# plugin/hooks/*.sh and *.py are gitignored here: they are build output, not source.
# Run this before publishing to the public plugin repo, and after any hook change.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../hooks"
dst="$here/hooks"

for f in spectix-status.sh spectix-usage.py; do
  if [ ! -f "$src/$f" ]; then
    echo "missing canonical source: $src/$f" >&2
    exit 1
  fi
  cp "$src/$f" "$dst/$f"
done
chmod +x "$dst/spectix-status.sh"

# Record what was shipped, so drift between the app's hook and the published plugin's
# copy is detectable instead of silent. Compare with `shasum -c hooks/CHECKSUMS` after
# a sync, or diff this file against a fresh run to see whether a republish is due.
( cd "$dst" && shasum -a 256 spectix-status.sh spectix-usage.py > CHECKSUMS )

echo "synced -> $dst"
cat "$dst/CHECKSUMS"
