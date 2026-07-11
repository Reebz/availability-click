#!/bin/bash
set -euo pipefail

# Release script for Availability Click
# Usage: ./scripts/release.sh [--update-cask-only]
#
#   --update-cask-only  Skip the build entirely: recompute the sha256 from
#                       downloads/<dmg>, re-run the release-asset gate, and
#                       perform only the cask bump/push. Run this after
#                       `gh release create` has published the asset.
#
# Prerequisites:
#   1. "Developer ID Application" certificate installed in Keychain
#   2. XcodeGen installed (brew install xcodegen)
#   3. Store notarization credentials once:
#      xcrun notarytool store-credentials "AvailabilityClick" \
#        --apple-id "your@email.com" \
#        --team-id "YOUR_TEAM_ID" \
#        --password "app-specific-password"
#
# Run in the foreground. Do NOT background this with a pipe (e.g.
# `./scripts/release.sh | tee log &`). Some harnesses report the pipeline
# as "completed" the moment the parent shell detaches, even though the
# script keeps running for the 5-30 min notarization wait. The script
# writes /tmp/AvailabilityClick-build/RELEASE_COMPLETE_v$VERSION on success;
# poll that path if you need an external done-signal.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Build outside iCloud/FileProvider to avoid com.apple.provenance extended attributes
BUILD_DIR="/tmp/AvailabilityClick-build"
APP_NAME="AvailabilityClick"
SCHEME="AvailabilityClick"
SOURCE_DIR="$REPO_ROOT/$APP_NAME"
PROJECT="$REPO_ROOT/$APP_NAME.xcodeproj"

# Load signing config from gitignored local file
if [ -f "$SCRIPT_DIR/release.local" ]; then
  # shellcheck source=release.local
  source "$SCRIPT_DIR/release.local"
else
  echo "ERROR: scripts/release.local not found."
  echo "Copy scripts/release.local.example to scripts/release.local and fill in your signing details."
  exit 1
fi

# Read version from project.yml (single source of truth) — e.g. MARKETING_VERSION: "1.0.0"
VERSION=$(grep -m1 'MARKETING_VERSION' "$REPO_ROOT/project.yml" \
  | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read MARKETING_VERSION from project.yml"
  exit 1
fi
DMG_NAME="availability-click_v${VERSION}.dmg"
ASSET_URL="https://github.com/Reebz/availability-click/releases/download/v${VERSION}/${DMG_NAME}"

# Gate (KTD7): the cask must never point at a GitHub release asset that does
# not exist. Gate on curl exit status with -L, not a literal 200 check --
# GitHub answers 302 to the CDN for live assets (OQ1). -f fails on 4xx/5xx.
release_asset_is_live() {
  curl -sfIL --max-time 30 "$ASSET_URL" > /dev/null
}

# Best-effort in the full release flow: a failed cask bump or push must NOT
# fail the release. The DMG is already built, notarized, stapled, and copied
# to downloads/. `git push origin HEAD` targets the tap's actual default
# branch (main or master); the commit is guarded so an unchanged cask does
# not abort with "nothing to commit". On any failure, warn and let the
# caller decide -- returns nonzero so --update-cask-only can fail loudly.
update_cask() {
  local sha="$1"
  CASK_FILE="$(brew --repo Reebz/availability-click)/Casks/availability-click.rb"
  if [ -f "$CASK_FILE" ]; then
    if (
      set -e
      sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$CASK_FILE"
      sed -i '' "s/sha256 \".*\"/sha256 \"$sha\"/" "$CASK_FILE"
      cd "$(dirname "$CASK_FILE")/.."
      git add Casks/availability-click.rb
      git diff --cached --quiet || git commit -m "update availability-click to v$VERSION"
      git push origin HEAD
    ); then
      echo "    Cask updated and pushed: $sha"
      return 0
    else
      echo "    WARNING: cask bump/push failed. Update the tap by hand."
      echo "    version: $VERSION   sha256: $sha"
      return 1
    fi
  else
    echo "    WARNING: Cask file not found at $CASK_FILE"
    echo "    Tap the cask repo first (brew tap Reebz/availability-click),"
    echo "    or manually update sha256 to: $sha"
    return 1
  fi
}

# --update-cask-only: cask update without rebuilding anything.
if [ "${1:-}" = "--update-cask-only" ]; then
  DMG_LOCAL="$REPO_ROOT/downloads/$DMG_NAME"
  if [ ! -f "$DMG_LOCAL" ]; then
    echo "ERROR: $DMG_LOCAL not found. Run a full release first."
    exit 1
  fi
  DMG_SHA256=$(shasum -a 256 "$DMG_LOCAL" | awk '{print $1}')
  echo "==> Checking release asset is live: $ASSET_URL"
  if ! release_asset_is_live; then
    echo "ERROR: release asset is not live. Publish it first:"
    echo "  gh release create v$VERSION \"downloads/$DMG_NAME\" --title \"v$VERSION\" --notes-file CHANGELOG.md"
    exit 1
  fi
  echo "==> Updating Homebrew cask checksum..."
  update_cask "$DMG_SHA256"
  exit 0
elif [ $# -gt 0 ]; then
  echo "Usage: ./scripts/release.sh [--update-cask-only]"
  exit 1
fi

echo "==> Regenerating Xcode project from project.yml..."
(cd "$REPO_ROOT" && xcodegen generate)

echo "==> Cleaning extended attributes and build artifacts..."
xattr -rc "$SOURCE_DIR"
find "$SOURCE_DIR" -name ".DS_Store" -delete
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $APP_NAME v$VERSION (Release)..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  archive

echo "==> Exporting archive (Developer ID)..."
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP_PATH="$BUILD_DIR/export/$APP_NAME.app"

echo "==> Verifying code signature (Hardened Runtime, Developer ID)..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# Hard assertions: the old `grep ... || true` could never fail, so
# "Signature OK" printed even for an ad-hoc, non-hardened signature.
SIGN_INFO=$(codesign --display --verbose=4 "$APP_PATH" 2>&1)
echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application" \
  || { echo "ERROR: signature is missing the Developer ID Application authority"; exit 1; }
echo "$SIGN_INFO" | grep -Eq "flags=.*runtime" \
  || { echo "ERROR: hardened runtime flag not set on the app signature"; exit 1; }
echo "    Signature OK"

echo "==> Creating DMG with Applications shortcut..."
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create a temporary read-write DMG
DMG_TEMP="$BUILD_DIR/temp.dmg"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDRW \
  -size 200m \
  "$DMG_TEMP"

# Mount, set Finder layout, unmount
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
if [ -z "$MOUNT_DIR" ]; then
  echo "ERROR: failed to parse mount point from hdiutil attach"
  exit 1
fi
# Detach on any failure below (AppleScript, convert) so a rerun doesn't
# style a stale leftover volume and ship an unstyled DMG.
trap 'hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true' EXIT
# Wait for the volume to actually appear instead of guessing with a fixed sleep
for _ in $(seq 1 20); do
  [ -d "$MOUNT_DIR" ] && break
  sleep 0.5
done

# Set Finder window appearance via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 820, 580}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_NAME.app" of container window to {180, 240}
        set position of item "Applications" of container window to {540, 240}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"
trap - EXIT

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_TEMP"
rm -rf "$DMG_STAGING"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarizing DMG (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying notarization..."
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> Copying DMG to downloads/ and staging it..."
DOWNLOADS_DIR="$REPO_ROOT/downloads"
mkdir -p "$DOWNLOADS_DIR"
cp "$DMG_PATH" "$DOWNLOADS_DIR/$DMG_NAME"
(cd "$REPO_ROOT" && git add "downloads/$DMG_NAME")

# The release artifact is complete: signed, notarized, stapled, and in downloads/.
# Record success now, BEFORE the best-effort tap update, so a good build always
# leaves the done-signal even if the Homebrew push later fails.
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
SENTINEL="$BUILD_DIR/RELEASE_COMPLETE_v$VERSION"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SENTINEL"

echo "==> Updating Homebrew cask checksum..."
if release_asset_is_live; then
  update_cask "$DMG_SHA256" || true
else
  # Normal mid-release: `gh release create` is a documented manual step, so
  # the asset usually is not live yet. Never push a cask at a 404.
  echo "    Release asset not live yet (expected mid-release):"
  echo "      $ASSET_URL"
  echo "    Skipping cask push. version: $VERSION   sha256: $DMG_SHA256"
  echo "    After publishing the GitHub release, run:"
  echo "      ./scripts/release.sh --update-cask-only"
fi

echo ""
echo "=== Release complete ==="
echo "DMG:       $DMG_PATH"
echo "Downloads: $DOWNLOADS_DIR/$DMG_NAME (staged, not committed)"
echo "SHA-256:   $DMG_SHA256"
echo "Sentinel:  $SENTINEL"
echo ""
echo "Next steps (run by hand, in this order):"
echo "  1. Commit the DMG:   git commit -m \"release: v$VERSION DMG\" downloads/$DMG_NAME"
echo "  2. Publish release:  gh release create v$VERSION \"$DMG_PATH\" --title \"v$VERSION\" --notes-file CHANGELOG.md"
echo "  3. Update the cask:  ./scripts/release.sh --update-cask-only"
