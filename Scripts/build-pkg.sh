#!/bin/bash
# Build a shareable (unsigned) GhettoZones.pkg that installs into /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-GhettoZones}"
CONFIGURATION="${CONFIGURATION:-Release}"
IDENTIFIER="com.mousuppe.GhettoZones.pkg"
DIST_DIR="${DIST_DIR:-"$ROOT/dist"}"
WORK_DIR="${TMPDIR:-/tmp}/ghettozones-pkg-$$"
PAYLOAD_ROOT="$WORK_DIR/payload"
SCRIPTS_DIR="$ROOT/Scripts/pkg-scripts"
DERIVED_DATA="${DERIVED_DATA:-$WORK_DIR/DerivedData}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Building $SCHEME ($CONFIGURATION)"
xcodebuild \
  -project "$ROOT/GhettoZones.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  | /usr/bin/grep -E 'error:|warning:.*GhettoZones|BUILD SUCCEEDED|BUILD FAILED' || true

APP_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/GhettoZones.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: built app not found at $APP_SRC" >&2
  exit 1
fi

VERSION="$(/usr/bin/defaults read "$APP_SRC/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0")"
BUILD="$(/usr/bin/defaults read "$APP_SRC/Contents/Info" CFBundleVersion 2>/dev/null || echo "1")"
PKG_VERSION="${VERSION}.${BUILD}"
PKG_NAME="GhettoZones-${VERSION}.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME"

echo "==> Staging payload (version $VERSION build $BUILD)"
mkdir -p "$PAYLOAD_ROOT/Applications"
/bin/rm -rf "$PAYLOAD_ROOT/Applications/GhettoZones.app"
# Copy the app bundle without resource-fork sidecar files.
export COPYFILE_DISABLE=1
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_SRC" "$PAYLOAD_ROOT/Applications/GhettoZones.app"
/usr/bin/find "$PAYLOAD_ROOT" \( -name '._*' -o -name '.DS_Store' \) -delete
# Ad-hoc re-sign after stripping xattrs so Gatekeeper sees a consistent bundle.
/usr/bin/codesign --force --deep --sign - "$PAYLOAD_ROOT/Applications/GhettoZones.app"

# Ensure postinstall is executable in the scripts copy used by pkgbuild.
STAGE_SCRIPTS="$WORK_DIR/scripts"
mkdir -p "$STAGE_SCRIPTS"
/bin/cp "$SCRIPTS_DIR/postinstall" "$STAGE_SCRIPTS/postinstall"
/bin/chmod 755 "$STAGE_SCRIPTS/postinstall"

mkdir -p "$DIST_DIR"
/bin/rm -f "$PKG_PATH"

echo "==> Creating $PKG_PATH"
/usr/bin/pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --install-location "/" \
  --scripts "$STAGE_SCRIPTS" \
  --identifier "$IDENTIFIER" \
  --version "$PKG_VERSION" \
  "$PKG_PATH"

echo "==> Done"
echo "Package: $PKG_PATH"
echo "Size:    $(/usr/bin/du -h "$PKG_PATH" | /usr/bin/awk '{print $1}')"
echo
echo "Share notes:"
echo "  • Recipients may need right-click → Open on the .pkg (unsigned / no Dev ID)."
echo "  • After install, enable Accessibility for GhettoZones in System Settings."
