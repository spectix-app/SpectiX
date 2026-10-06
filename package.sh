#!/bin/bash
# Package SpectiX into a distributable zip whose whole contents are ONE
# double-clickable app: "Install SpectiX.app".
#
# That installer carries SpectiX.app and the editor extension inside its own
# Resources/ and puts all three pieces — app, Claude Code hooks, editor
# extension — in place on a single click. No dragging, no terminal, no README.
#
# Two grades of output, picked automatically:
#   • A "Developer ID Application" cert in the keychain + a stored notarytool
#     profile → both bundles get the hardened runtime, notarization and a
#     stapled ticket. The friend double-clicks and nothing warns them.
#   • Neither → an ad-hoc build; the zip then also carries a short 先看我.txt
#     telling the friend how to get past Gatekeeper by hand.
#
# BOTH bundles are notarized, not just the outer one: the payload app ends up in
# /Applications and is launched on its own from then on, so it needs its own
# stapled ticket or its first offline launch gets blocked.
#
# Order is a hard constraint — inner signed and stapled first, outer last. An
# outer bundle signed before the nested one is dropped in has a broken seal, and
# notarization rejects it as "nested code is not signed".
set -euo pipefail
cd "$(dirname "$0")"

APP="SpectiX.app"
INSTALLER="installer/build/Install SpectiX.app"
NAME="SpectiX"
VERSION="1.10"
ZIP="$NAME-$VERSION.zip"
# Deliberately still "taskbeacon": this names a credential the user stored once with
# `notarytool store-credentials`, not anything the recipient ever sees. Renaming it
# would make every release run report "profile not stored" and silently drop to an
# unnotarized build until the credential was re-created by hand.
NOTARY_PROFILE="${NOTARY_PROFILE:-taskbeacon}"

# Upload one bundle to Apple, wait for the verdict, staple the ticket into it so
# it validates offline on the recipient's Mac, and let Gatekeeper have the last
# word. Stapling adds a file to the bundle but leaves the seal intact, so the
# stapled copy is what gets embedded / zipped downstream.
notarize() {
  local bundle="$1" tmp
  echo "→ notarizing $(basename "$bundle") (uploads to Apple, usually 1-5 min)…"
  tmp="$(mktemp -d)"
  ditto -c -k --keepParent "$bundle" "$tmp/notarize.zip"
  xcrun notarytool submit "$tmp/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -rf "$tmp"
  xcrun stapler staple "$bundle"
  spctl -a -vvv -t exec "$bundle"          # fails loudly if Gatekeeper still objects
}

# 0. Pick the signing identity and decide the grade up front, so a missing
#    notarytool profile is reported before spending minutes on two builds.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
NOTARIZED=0
if [ -n "$SIGN_ID" ]; then
  echo "→ release signing as: $SIGN_ID"
  if NOTARY_ERR=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    NOTARIZED=1
  elif echo "$NOTARY_ERR" | grep -qi "agreement"; then
    # The profile is fine; Apple refuses every call until the account holder accepts
    # the updated Program License Agreement. Shipping a silently un-notarized build
    # here would be a regression users hit as a Gatekeeper block, so stop instead.
    echo "✖ notarization refused: Apple Developer agreement missing or expired (HTTP 403)."
    echo "  The account holder signs it at https://developer.apple.com/account, then rerun."
    exit 1
  else
    echo "$NOTARY_ERR" | head -2 | sed 's/^/    /'
    echo "⚠️  notarytool profile '$NOTARY_PROFILE' not stored — signed but NOT notarized."
    echo "    Run: xcrun notarytool store-credentials $NOTARY_PROFILE"
  fi
else
  echo "⚠️  no 'Developer ID Application' cert found — building ad-hoc (recipient has to get past Gatekeeper by hand)."
fi

# 1. Inner bundle: the app itself. build.sh signs it with the hardened runtime
#    and the entitlements; notarize it here so the copy the installer embeds is
#    already ticketed.
UNIVERSAL=1 SIGN_ID="$SIGN_ID" ./build.sh
echo "   archs: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
if [ "$NOTARIZED" = "1" ]; then notarize "$APP"; fi

# 2. Outer bundle: the installer. It copies the app (with its ticket) and the
#    extension into its own Resources/, then signs itself last.
UNIVERSAL=1 SIGN_ID="$SIGN_ID" ./installer/build-installer.sh
echo "   archs: $(lipo -archs "$INSTALLER/Contents/MacOS/SpectiXInstaller")"

# 2a. An installer missing part of its payload looks fine here and fails on the
#     friend's machine — check before we spend a notarization round on it.
for f in "Contents/Resources/$APP/Contents/MacOS/$NAME" \
         "Contents/Resources/$APP/Contents/Resources/hooks/spectix-status.sh" \
         "Contents/Resources/$APP/Contents/Resources/hooks/spectix-usage.py" \
         "Contents/Resources/vscode-extension/extension.js" \
         "Contents/Resources/vscode-extension/package.json"; do
  [ -e "$INSTALLER/$f" ] || { echo "✖ installer is missing $f — can't package."; exit 1; }
done

if [ "$NOTARIZED" = "1" ]; then notarize "$INSTALLER"; fi

# 3. Stage and zip. The notarized grade ships exactly one item; the ad-hoc grade
#    adds the note, since that friend does have something to read.
STAGE="$(mktemp -d)"
PKG="$STAGE/$NAME-$VERSION"
mkdir -p "$PKG"
ditto "$INSTALLER" "$PKG/$(basename "$INSTALLER")"     # ditto, not cp: keeps the signature intact
if [ "$NOTARIZED" != "1" ]; then
  cp installer/先看我-adhoc.txt "$PKG/先看我.txt"
fi

rm -f "$ZIP"
( cd "$STAGE" && ditto -c -k --keepParent "$NAME-$VERSION" "$OLDPWD/$ZIP" )
rm -rf "$STAGE"

echo "✅ Packaged $ZIP  ($(du -h "$ZIP" | cut -f1))"
if [ "$NOTARIZED" = "1" ]; then
  echo "   已 Apple 公证 + stapled（内外两层都有票据）：对方解压后双击安装器，一路无提示。"
else
  echo "   ad-hoc 包：对方需按「先看我.txt」右键打开安装器。"
fi
echo "   把这个 .zip 发给朋友：解压后只有一个「Install SpectiX.app」，双击点一下就装完。"
