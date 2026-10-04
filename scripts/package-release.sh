#!/usr/bin/env bash
# ==============================================================================
# package-release.sh — Ivy macOS Release Packaging & Notarization Pipeline
# ==============================================================================
# Builds Ivy in Release mode, constructs a production .app bundle, codesigns
# with Hardened Runtime & minimal entitlements, creates a distributable DMG,
# validates the bundle, and optionally submits to Apple Notary Service.
#
# Environment variables:
#   CODESIGN_IDENTITY  (Optional) Code signing certificate name.
#                      Defaults to 'Developer ID Application: *' or
#                      'Apple Development: *', or ad-hoc '-' if none found.
#   NOTARY_PROFILE     (Optional) notarytool keychain profile name.
#   APPLE_ID           (Optional) Apple ID email for notarization.
#   APPLE_PASSWORD     (Optional) App-specific password for notarization.
#   APPLE_TEAM_ID      (Optional) 10-character Apple Team ID for notarization.
#   SKIP_DMG           (Optional) Set to 1 to skip disk image (.dmg) creation.
# ==============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Ivy Production Release Packaging ==="

# 1. Clean and Build in Release Mode
echo "--> Compiling Ivy (release configuration)..."
swift build -c release -Xswiftc -strict-concurrency=complete

# Extract version from IvyVersion.swift
VERSION=$(grep 'marketingVersion =' Sources/IvyCore/Configuration/IvyVersion.swift | awk -F'"' '{print $2}')
BUILD=$(grep 'buildNumber =' Sources/IvyCore/Configuration/IvyVersion.swift | awk -F'"' '{print $2}')
echo "--> Release Version: $VERSION (Build $BUILD)"

# 2. Stage App Bundle
DIST_DIR="dist"
mkdir -p "$DIST_DIR"
RELEASE_STAGING="$(mktemp -d "$DIST_DIR/.release-XXXXXX")"
MOUNT_DIR=""
cleanup() {
    local packaging_status=$?
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null || { echo "ERROR: Detach $MOUNT_DIR manually before removing staging." >&2; return 1; }
        rmdir "$MOUNT_DIR"
    fi
    if [ -d "$RELEASE_STAGING/Previous-Ivy.app" ] && [ ! -d "$DIST_DIR/Ivy.app" ]; then
        mv "$RELEASE_STAGING/Previous-Ivy.app" "$DIST_DIR/Ivy.app"
    fi
    rm -rf "$RELEASE_STAGING"
    return "$packaging_status"
}
trap cleanup EXIT
APP_BUNDLE="$RELEASE_STAGING/Ivy.app"
DMG_PATH="$RELEASE_STAGING/Ivy-$VERSION.dmg"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "--> Packaging $APP_BUNDLE..."
cp ".build/release/Ivy" "$APP_BUNDLE/Contents/MacOS/Ivy"
chmod +x "$APP_BUNDLE/Contents/MacOS/Ivy"
cp "Sources/Ivy/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Sources/Ivy/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R ".build/release/Ivy_Ivy.bundle" "$APP_BUNDLE/Contents/Resources/"

# Required metadata must exist; an invalid plist stops packaging instead of hiding the failure.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ivy" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_BUNDLE/Contents/Info.plist"

# Strip extended attributes and remove any stray files
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name ".DS_Store" -delete

# 3. Determine Code Signing Identity
ENTITLEMENTS="Sources/Ivy/Resources/Ivy.entitlements"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
    echo "--> Using explicit signing identity: $IDENTITY"
else
    # Prefer Developer ID Application for distribution, fallback to Apple Development for local testing
    DEV_ID=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}' || true)
    APPLE_DEV=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}' || true)

    if [ -n "$DEV_ID" ]; then
        IDENTITY="$DEV_ID"
        echo "--> Detected Developer ID signing identity: $IDENTITY"
    elif [ -n "$APPLE_DEV" ]; then
        IDENTITY="$APPLE_DEV"
        echo "--> Detected Apple Development identity: $IDENTITY"
        echo "    (Note: Apple Development certificates cannot be notarized; use Developer ID for production distribution.)"
    else
        IDENTITY="-"
        echo "--> No codesigning identity found. Using ad-hoc signing ('-')."
        echo "    (Note: Ad-hoc signed testing builds require a manual Gatekeeper override after download.)"
    fi
fi

# 4. Code Sign with Hardened Runtime & Entitlements
echo "--> Signing $APP_BUNDLE..."
SIGN_ARGS=(
    --force
    --options runtime
    --entitlements "$ENTITLEMENTS"
    --sign "$IDENTITY"
)

# Only add --timestamp if not ad-hoc signed
if [ "$IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# 5. Verify App Signature
echo "--> Verifying application bundle signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "    Signature verified successfully."

# 6. Sanity Checks on App Bundle
echo "--> Performing artifact hygiene inspection..."
# Check for accidental API keys or credentials
if grep -rqE "AIzaSy|sk-[a-zA-Z0-9]{20,}" "$APP_BUNDLE" 2>/dev/null; then
    echo "ERROR: Potential secret or API key found inside $APP_BUNDLE!" >&2
    exit 1
else
    SCAN_STATUS=$?
    if [ "$SCAN_STATUS" != "1" ]; then
        echo "ERROR: Artifact credential scan failed." >&2
        exit "$SCAN_STATUS"
    fi
fi
echo "    Zero credential leaks in app bundle."

# 7. Create Distributable DMG
if [ "${SKIP_DMG:-0}" != "1" ]; then
    echo "--> Creating distributable disk image ($DMG_PATH)..."
    DMG_STAGING="$RELEASE_STAGING/dmg_staging"
    rm -rf "$DMG_STAGING" "$DMG_PATH"
    mkdir -p "$DMG_STAGING"

    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    # Build writable first so the mounted volume can get Ivy's icon, then compress to the read-only UDZO image.
    DMG_RW="$RELEASE_STAGING/Ivy-rw.dmg"
    rm -f "$DMG_RW"
    hdiutil create -volname "Ivy" -srcfolder "$DMG_STAGING" -ov -format UDRW "$DMG_RW" >/dev/null
    MOUNT_DIR="$(mktemp -d)"
    hdiutil attach "$DMG_RW" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen >/dev/null
    cp "Sources/Ivy/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_DIR"
    hdiutil detach "$MOUNT_DIR" >/dev/null
    rmdir "$MOUNT_DIR"
    MOUNT_DIR=""
    hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH" -ov >/dev/null
    rm -f "$DMG_RW"

    rm -rf "$DMG_STAGING"

    # Sign DMG if we have a real identity
    if [ "$IDENTITY" != "-" ]; then
        echo "--> Signing disk image..."
        codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
    fi
    echo "    DMG created at $DMG_PATH."
fi

# 8. Notarization Workflow
echo "--> Checking notarization readiness..."
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "--> Submitting to Apple Notary Service via keychain profile '$NOTARY_PROFILE'..."
    TARGET_FOR_NOTARY="$DMG_PATH"
    if [ ! -f "$TARGET_FOR_NOTARY" ]; then
        TARGET_FOR_NOTARY="$RELEASE_STAGING/Ivy.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$TARGET_FOR_NOTARY"
    fi
    xcrun notarytool submit "$TARGET_FOR_NOTARY" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "--> Stapling notarization ticket..."
    if [ -f "$DMG_PATH" ]; then
        xcrun stapler staple "$DMG_PATH"
    fi
    xcrun stapler staple "$APP_BUNDLE"
    spctl -a -t exec -v "$APP_BUNDLE"
    echo "    Notarization and stapling complete!"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    echo "--> Submitting to Apple Notary Service via Apple ID credentials..."
    TARGET_FOR_NOTARY="$DMG_PATH"
    if [ ! -f "$TARGET_FOR_NOTARY" ]; then
        TARGET_FOR_NOTARY="$RELEASE_STAGING/Ivy.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$TARGET_FOR_NOTARY"
    fi
    xcrun notarytool submit "$TARGET_FOR_NOTARY" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    echo "--> Stapling notarization ticket..."
    if [ -f "$DMG_PATH" ]; then
        xcrun stapler staple "$DMG_PATH"
    fi
    xcrun stapler staple "$APP_BUNDLE"
    spctl -a -t exec -v "$APP_BUNDLE"
    echo "    Notarization and stapling complete!"
else
    echo "--> Notarization credentials not configured in environment."
    echo "    To notarize a production release, either:"
    echo "      1. Set NOTARY_PROFILE=<profile_name> (configured via 'xcrun notarytool store-credentials'), OR"
    echo "      2. Set APPLE_ID, APPLE_PASSWORD, and APPLE_TEAM_ID environment variables."
    echo "    See docs/RELEASE.md for step-by-step instructions."
fi

# Set the disk-image file icon through its resource fork; no Finder/UI scripting is required.
if [ -f "$DMG_PATH" ]; then
    python3 - "Sources/Ivy/Resources/AppIcon.icns" "$RELEASE_STAGING/dmg-icon.r" <<'PYICON'
import pathlib, sys
payload = pathlib.Path(sys.argv[1]).read_bytes().hex().upper()
lines = ["data 'icns' (-16455) {"]
lines += ['    $"' + payload[index:index + 128] + '"' for index in range(0, len(payload), 128)]
lines += ['};']
pathlib.Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
PYICON
    Rez "$RELEASE_STAGING/dmg-icon.r" -o "$DMG_PATH"
    SetFile -a C "$DMG_PATH"
fi

# Publish validated local artifacts only after packaging completes. Keep older DMGs for rollback.
if [ -d "$DIST_DIR/Ivy.app" ]; then
    mv "$DIST_DIR/Ivy.app" "$RELEASE_STAGING/Previous-Ivy.app"
fi
mv "$APP_BUNDLE" "$DIST_DIR/Ivy.app"
APP_BUNDLE="$DIST_DIR/Ivy.app"
if [ -f "$DMG_PATH" ]; then
    mv -f "$DMG_PATH" "$DIST_DIR/Ivy-$VERSION.dmg"
fi
DMG_PATH="$DIST_DIR/Ivy-$VERSION.dmg"

# 9. Release Artifact Checksums
echo "=== Release Packaging Complete ==="
echo "Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR"
echo ""
echo "Checksums (SHA-256):"
shasum -a 256 "$APP_BUNDLE/Contents/MacOS/Ivy"
if [ -f "$DMG_PATH" ]; then
    shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
fi
