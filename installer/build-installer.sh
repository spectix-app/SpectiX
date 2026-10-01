#!/bin/bash
# Build "安装 SpectiX.app" — the GUI installer that carries SpectiX.app and
# the editor extension inside its own Resources/ and puts all three pieces in place
# on one click.
#
# Defaults to a fast host-arch, ad-hoc-signed build for local testing. package.sh
# drives the release build through the same script:
#   UNIVERSAL=1 SIGN_ID="Developer ID Application: …" ./installer/build-installer.sh
#
# NOTE on signing order: the payload app must already be signed before it is copied
# in, and the installer is signed AFTERWARDS (below). Signing the outer bundle
# first, then dropping a nested bundle into it, invalidates the outer seal and
# notarization rejects it as "nested code is not signed".
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="SpectiXInstaller"
APP="installer/build/Install SpectiX.app"
PAYLOAD_APP="SpectiX.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

# 0. Preconditions — the installer is nothing without its payload.
[ -d "$PAYLOAD_APP" ] || { echo "✖ 缺少 $PAYLOAD_APP —— 先跑 ./build.sh"; exit 1; }
for f in vscode-extension/package.json vscode-extension/extension.js; do
  [ -f "$f" ] || { echo "✖ 缺少 $f"; exit 1; }
done

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

# 1. Compile.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  TMP="$(mktemp -d)"
  swiftc -O installer/src/*.swift -o "$TMP/$NAME-arm64"  -framework Cocoa -target arm64-apple-macosx13.0
  swiftc -O installer/src/*.swift -o "$TMP/$NAME-x86_64" -framework Cocoa -target x86_64-apple-macosx13.0
  lipo -create "$TMP/$NAME-arm64" "$TMP/$NAME-x86_64" -output "$BIN_DIR/$NAME"
  rm -rf "$TMP"
else
  swiftc -O installer/src/*.swift -o "$BIN_DIR/$NAME" -framework Cocoa
fi

# 2. Payload. The hook scripts are NOT copied separately: they already ride inside
#    SpectiX.app/Contents/Resources/hooks (build.sh puts them there for the
#    app's own bootstrap path), and InstallerCore reads them from that one copy so
#    the two can never drift apart.
ditto "$PAYLOAD_APP" "$RES_DIR/$PAYLOAD_APP"
mkdir -p "$RES_DIR/vscode-extension"
cp vscode-extension/package.json vscode-extension/extension.js "$RES_DIR/vscode-extension/"
cp LICENSE "$RES_DIR/LICENSE"

# 3. Icon — the same artwork as the app (tools/AppIcon.png is the single source,
#    see docs/logo.md). Reuse the .icns the payload already carries.
cp "$PAYLOAD_APP/Contents/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Install SpectiX</string>
    <key>CFBundleDisplayName</key><string>Install SpectiX</string>
    <key>CFBundleIdentifier</key><string>app.spectix.SpectiX.installer</string>
    <key>CFBundleVersion</key><string>1.8</string>
    <key>CFBundleShortVersionString</key><string>1.8</string>
    <key>CFBundleExecutable</key><string>SpectiXInstaller</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 4. Sign the outer bundle last (see the note at the top). A release SIGN_ID adds
#    the hardened runtime and a secure timestamp — both preconditions for
#    notarization. The installer needs no entitlements of its own: it only writes
#    to /Applications and the user's home, neither of which the runtime restricts.
SIGN_ID="${SIGN_ID:-}"
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
  echo "   signed: $SIGN_ID (hardened runtime + timestamp)"
else
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
  echo "   signed: ad-hoc (local test build)"
fi

echo "✅ Built $APP"
echo "   Test:  SPECTIX_INSTALL_ROOT=/tmp/tb-test open \"$APP\""
