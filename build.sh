#!/bin/bash
# Build SpectiX.app — a single-binary menu bar app, no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

NAME="SpectiX"

# ── No-network invariant, gate 1: the sources ────────────────────────────────
# SpectiX promises in its README ("Privacy: no network") and on its privacy page
# that it makes no network calls of its own, and invites users to verify that from outside the binary.
# A promise that lives only in prose rots the first time someone adds a
# convenient "check for updates" call, so it is enforced at build time instead:
# no networking API may appear in the sources at all. Line comments are stripped
# first, so documentation may name these APIs; code may not use them.
#
# Opening a URL in the user's browser (NSWorkspace.open) is deliberately NOT on
# this list — that hands the URL to another app and opens no connection here.
NET_API='URLSession|NSURLConnection|CFNetwork|CFSocket|CFStream|NWConnection|NWListener|NWBrowser|import +Network\b|socket\(|getaddrinfo|inet_pton'
OFFENDERS=""
for f in *.swift; do
  hits=$(sed 's#//.*##' "$f" | grep -nE "$NET_API" || true)
  if [ -n "$hits" ]; then
    OFFENDERS="$OFFENDERS$(printf '%s\n' "$hits" | sed "s#^#  $f:#")"$'\n'
  fi
done
if [ -n "$OFFENDERS" ]; then
  echo "❌ no-network invariant violated — networking API found in the sources:" >&2
  printf '%s' "$OFFENDERS" >&2
  echo "   SpectiX publicly promises no network activity (README \"Privacy: no network\", spectix.app/privacy)." >&2
  echo "   Remove the call, or change the guarantee everywhere it is published first." >&2
  exit 1
fi

# ── Editor opens must stay serialized ────────────────────────────────────────
# `open -b <editor> <folder>` sends an odoc AppleEvent, and VSCode BATCHES the
# ones that arrive close together: two DIFFERENT folders in one batch open as one
# multi-root "Untitled (Workspace)" window instead of two folder windows. That
# window then can't be resolved back to a project at all — its title carries no
# folder name, and every window→path lookup in the app is title-based — so the
# project silently drops off the list and a workspace window appears out of
# nowhere (measured 2026-08-26; see docs/jump.md).
# AppController.openInEditor() spaces those spawns out and is the ONLY place
# allowed to make this call. A new direct call would bring the bug back in a
# shape nobody reads as a bug, so it fails the build instead.
BAD_OPEN=$(grep -nE '/usr/bin/open", *\["-b"' *.swift | grep -v 'via openInEditor' || true)
if [ -n "$BAD_OPEN" ]; then
  echo "❌ editor open not serialized — spawn it through AppController.openInEditor():" >&2
  printf '%s\n' "$BAD_OPEN" | sed 's#^#  #' >&2
  echo "   Two opens within ~0.4s merge into one Untitled (Workspace) window." >&2
  exit 1
fi

# ── Dev-only features ────────────────────────────────────────────────────────
# -D DEV_BUILD turns on features that aren't ready to ship (Build.isDev in
# Pro.swift; the Settings rows that own them carry a DEV badge). A dev-only
# feature is COMPILED OUT of a release binary rather than hidden behind a flag,
# so no defaults write can bring it back.
#
# On by default because the default build IS the local one. The release path
# (package.sh, which always sets UNIVERSAL=1) gets it off; DEV_BUILD=0/1
# overrides either default explicitly.
if [ -n "${DEV_BUILD:-}" ]; then
  DEV="$DEV_BUILD"
elif [ "${UNIVERSAL:-0}" = "1" ]; then
  DEV=0
else
  DEV=1
fi
if [ "$DEV" = "1" ]; then DEV_FLAG="-D DEV_BUILD"; else DEV_FLAG=""; fi

# A separate bundle id for the dev build, because TCC keys Accessibility by
# bundle id and stores ONE record per id — holding one designated requirement.
# The release install is signed by the Developer ID identity and the dev build by
# the self-signed one (see the signing block below), so their requirements differ:
# under a shared id the two fight over that single record and whichever was
# granted last silently revokes the other. Granting each its own id ends that —
# System Settings then lists them separately and both stay granted.
#
# The id is the reverse of the domain the app ships from, spectix.app. It used to
# be com.<vendor>.<name>, and the vendor segment was personal information — a
# bundle id is world-readable (`plutil -p` on any downloaded copy) and gets written
# verbatim into a Homebrew cask's `uninstall quit:` and `zap trash:`, where it is
# indexed publicly and permanently. The app's whole public identity is the domain,
# not a person, and now the id says so too. Nothing about the string is functional:
# macOS never checks that the middle segment is a domain you own, it only has to be
# unique on the machine. T206.
#
# Changing it again is expensive and gets more so with every install: TCC keys the
# Accessibility grant by id, and there is no API to carry a grant across ids, so
# every existing user would have to re-authorize by hand. Settings survive — that is
# what Migration.legacyDomains is for — but the permission cannot. This rename was
# affordable only because it landed before the app had any users; the next one would
# not be. Treat the id as frozen from here.
#
# The BUNDLE NAME goes with it, and it has to be the name of the .app itself:
# System Settings labels its privacy lists from the bundle's FILE NAME, not from
# CFBundleDisplayName, so two bundles both named SpectiX.app produce two rows
# reading "SpectiX" with no way to tell which switch belongs to which build. The
# executable inside stays SpectiX either way, so `pkill -x SpectiX` still matches
# both and the CFBundleExecutable key below needs no branch.
if [ "$DEV" = "1" ]; then
  BUNDLE_ID="app.spectix.SpectiX.dev"; DISPLAY_NAME="SpectiX Dev"; APP="SpectiX Dev.app"
else
  BUNDLE_ID="app.spectix.SpectiX";     DISPLAY_NAME="SpectiX";     APP="SpectiX.app"
fi
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

# ── One build at a time ──────────────────────────────────────────────────────
# Two overlapping runs do not merely waste a core, they corrupt each other: the
# second `rm -rf`s the bundle the first is writing into, and the .app is left with
# no executable. It reads exactly like a compile error in the code you just
# touched, and it is not — so it costs an hour to disbelieve.
#
# Happens whenever two editors/agents share one checkout. Wait for the other one
# rather than racing it; a lock older than 30 minutes belonged to a build that died.
LOCK=".build.lock"
waited=0
while ! mkdir "$LOCK" 2>/dev/null; do
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rm -rf "$LOCK"; continue; fi
  [ "$waited" = 0 ] && echo "⏳ another build is running — waiting for it to finish"
  waited=$((waited + 1))
  if [ "$waited" -gt 900 ]; then echo "❌ gave up waiting for $LOCK after 15 min" >&2; exit 1; fi
  sleep 1
done
trap 'rm -rf "$LOCK"' EXIT

# ⚠️ The lock covers the BUILD, not the gap between your build finishing and you
# launching what it produced. The moment this script exits the lock is gone, and
# another agent's build can walk straight into the `rm -rf "$APP"` below — so an
# `open` issued a minute later (while you were reading output, or thinking) hits a
# bundle that is mid-rebuild and fails with "executable is missing" or "bundle
# format unrecognized", which reads like YOUR build broke. It didn't.
# Fix: keep build and launch in ONE command, back to back —
#   ./build.sh && pkill -x SpectiX; open "SpectiX Dev.app"
# An already-running process is unaffected by a later delete of its bundle, so once
# a launch succeeds it stays up.
#
# Related: piping this script into `head` leaves it ORPHANED, not dead — head exits,
# SIGPIPE hits, and the build keeps running to completion in the background. A few
# of those and several builds are clearing and rewriting this same bundle at once.
# Redirect to a file and grep that instead.
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

# Default: single-arch build for the host (fast local iteration).
# UNIVERSAL=1 (used by package.sh): build a fat binary that runs on both
# Apple Silicon (arm64) and Intel (x86_64) Macs.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  TMP="$(mktemp -d)"
  swiftc -O $DEV_FLAG *.swift -o "$TMP/$NAME-arm64"  -framework Cocoa -framework Carbon -target arm64-apple-macosx13.0
  swiftc -O $DEV_FLAG *.swift -o "$TMP/$NAME-x86_64" -framework Cocoa -framework Carbon -target x86_64-apple-macosx13.0
  lipo -create "$TMP/$NAME-arm64" "$TMP/$NAME-x86_64" -output "$BIN_DIR/$NAME"
  rm -rf "$TMP"
else
  swiftc -O $DEV_FLAG *.swift -o "$BIN_DIR/$NAME" -framework Cocoa -framework Carbon
fi

# ── No-network invariant, gate 2: the linked libraries ───────────────────────
# Gate 1 can be fooled by indirection (dlopen, an @objc string selector). This
# one cannot be argued with, and it is the same check the privacy page tells
# users to run themselves: the shipped binary must not link a network stack.
if otool -L "$BIN_DIR/$NAME" | grep -qE 'CFNetwork|/Network\.framework|libcurl|libssl|libcrypto'; then
  echo "❌ no-network invariant violated — the binary links a network library:" >&2
  otool -L "$BIN_DIR/$NAME" | grep -E 'CFNetwork|/Network\.framework|libcurl|libssl|libcrypto' >&2
  exit 1
fi

# App icon: scale tools/AppIcon.png (1024×1024 source) into a full iconset, pack
# to .icns. (The old Core Graphics generator lives in tools/make-icon.swift if
# we ever want to regenerate the artwork from code.)
ICONSET="SpectiX.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" tools/AppIcon.png --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET"

# Bundle the hook scripts inside the app so it can self-install them on first launch
# (recipients who got the .app on its own, without the installer). This is also the
# ONE copy the installer reads from — see installer/build-installer.sh step 2 and
# AppController.bootstrapHooks().
mkdir -p "$RES_DIR/hooks"
cp hooks/spectix-status.sh hooks/spectix-usage.py "$RES_DIR/hooks/"
# Break-timer photos (BreakPanel): Pexels-licensed, see docs/break-reminder.md.
cp tools/cat-stretch.jpg tools/cat-glasses.jpg "$RES_DIR/"
# FSL-1.1 (Redistribution clause) requires every copy to carry these terms.
cp LICENSE "$RES_DIR/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.11</string>
    <key>CFBundleShortVersionString</key><string>1.11</string>
    <key>CFBundleExecutable</key><string>SpectiX</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSAppleEventsUsageDescription</key><string>SpectiX opens Terminal to start or sign in a Claude / Codex session on the profile you picked, and raises the terminal window you jump to.</string>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity so TCC permissions (Accessibility,
# etc.) survive rebuilds — ad-hoc signing changes the cdhash every compile,
# which makes macOS forget the grant and re-prompt. Run tools/setup-signing-cert.sh
# once to create the "SpectiX Dev" identity; fall back to ad-hoc if it's absent.
#
# Release builds override SIGN_ID with the "Developer ID Application: …" identity
# (package.sh does this). That path additionally needs the hardened runtime, the
# entitlements file, and a secure timestamp — all three are preconditions for
# Apple notarization, and a failure there must abort rather than fall through to
# an unsigned bundle we'd ship by accident.
#
# The rename (T172) moved the identity name from "TaskBeacon Dev" to "SpectiX Dev",
# but the keychain on a machine that built before it still only holds the old one.
# Falling back to it keeps those machines on a stable signature instead of dropping
# to ad-hoc and re-prompting for Accessibility on every single rebuild. Drop this
# branch once every build machine has run tools/setup-signing-cert.sh again.
if [ -z "${SIGN_ID:-}" ] \
   && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "SpectiX Dev" \
   && security find-identity -v -p codesigning 2>/dev/null | grep -q "TaskBeacon Dev"; then
  SIGN_ID="TaskBeacon Dev"
fi
SIGN_ID="${SIGN_ID:-SpectiX Dev}"
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  codesign --force --options runtime --timestamp \
           --entitlements tools/SpectiX.entitlements \
           -s "$SIGN_ID" "$APP"
  echo "   signed: $SIGN_ID (hardened runtime + entitlements + timestamp)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force -s "$SIGN_ID" "$APP" >/dev/null 2>&1 || true
else
  echo "⚠️  '$SIGN_ID' identity not found — using ad-hoc (TCC will re-prompt on every rebuild)."
  echo "    Run ./tools/setup-signing-cert.sh once to fix."
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
fi

# Re-register the bundle with LaunchServices. It caches by PATH, so a rebuild that
# changes the bundle id at a path it already knows leaves it resolving the id it saw
# first. tccd then can't turn our id into an app URL ("failed to find an Application
# URL for bundle ID"), and the Accessibility list draws that row without a name or an
# icon — unclickable, so the grant can never be given. Cheap and idempotent.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP" 2>/dev/null

echo "✅ Built $APP"
if [ "$DEV" = "1" ]; then
  echo "   dev build — dev-only features are IN (release packages omit them)."
fi
echo "   Run:  open \"$(pwd)/$APP\""
