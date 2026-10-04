#!/usr/bin/env bash
# ==============================================================================
# package-friend-test.sh — Ivy Friend-Testing Packaging Pipeline (Phase 19.10)
# ==============================================================================
# Builds Ivy in Release mode, creates a testing .app bundle, codesigns with
# Hardened Runtime & minimal entitlements (using Developer ID, Apple Development,
# or ad-hoc signing), creates an isolated friend-test DMG under dist/Previous-Builds,
# validates the bundle for zero credential leaks, and outputs SHA-256 checksums.
#
# IMPORTANT:
# - Does NOT overwrite or alter dist/Ivy-1.1.0.dmg or existing release artifacts.
# - Explicitly documents that notarization is deferred and Windows is unsupported.
# ==============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Ivy Friend-Testing Release Packaging ==="

# 1. Clean and Build in Release Mode
echo "--> Compiling Ivy in release configuration with Swift 6 strict concurrency..."
swift build -c release -Xswiftc -strict-concurrency=complete

# Extract version from IvyVersion.swift
VERSION=$(grep 'marketingVersion =' Sources/IvyCore/Configuration/IvyVersion.swift | awk -F'"' '{print $2}')
BUILD=$(grep 'buildNumber =' Sources/IvyCore/Configuration/IvyVersion.swift | awk -F'"' '{print $2}')
DATE_TAG="$(date +%Y-%m-%d)"
OUTPUT_DIR="dist/Previous-Builds/Friend-Test-Computer-Control-$DATE_TAG"
mkdir -p "$OUTPUT_DIR"

echo "--> Target Version: $VERSION (Build $BUILD)"
echo "--> Destination: $OUTPUT_DIR"

# 2. Stage App Bundle
STAGING="$(mktemp -d "/tmp/ivy-friend-test-XXXXXX")"
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

APP_BUNDLE="$STAGING/Ivy.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "--> Staging $APP_BUNDLE..."
cp ".build/release/Ivy" "$APP_BUNDLE/Contents/MacOS/Ivy"
chmod +x "$APP_BUNDLE/Contents/MacOS/Ivy"
cp "Sources/Ivy/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Sources/Ivy/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R ".build/release/Ivy_Ivy.bundle" "$APP_BUNDLE/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ivy" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_BUNDLE/Contents/Info.plist"

xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name ".DS_Store" -delete

# 3. Determine Code Signing Identity
ENTITLEMENTS="Sources/Ivy/Resources/Ivy.entitlements"
IDENTITY="-"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
    echo "--> Using specified signing identity: $IDENTITY"
else
    DEV_ID=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}' || true)
    APPLE_DEV=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}' || true)

    if [ -n "$DEV_ID" ]; then
        IDENTITY="$DEV_ID"
        echo "--> Detected Developer ID signing identity: $IDENTITY"
    elif [ -n "$APPLE_DEV" ]; then
        IDENTITY="$APPLE_DEV"
        echo "--> Detected Apple Development identity: $IDENTITY"
    else
        IDENTITY="-"
        echo "--> No codesigning identity found. Using ad-hoc signing ('-')."
    fi
fi

# 4. Code Sign App Bundle
echo "--> Signing $APP_BUNDLE..."
SIGN_ARGS=(
    --force
    --options runtime
    --entitlements "$ENTITLEMENTS"
    --sign "$IDENTITY"
)
if [ "$IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# 5. Verify App Signature
echo "--> Verifying application bundle signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "    App bundle signature verified."

# 6. Hygiene and Credential Leak Inspection
echo "--> Checking bundle hygiene and credential leak prevention..."
if grep -rqE "AIzaSy|sk-[a-zA-Z0-9]{20,}" "$APP_BUNDLE" 2>/dev/null; then
    echo "ERROR: Potential credential leak found inside $APP_BUNDLE!" >&2
    exit 1
fi
echo "    Zero credential leaks found in app bundle."

# 7. Create Distributable DMG
DMG_PATH="$OUTPUT_DIR/Ivy-$VERSION-friend-test.dmg"
DMG_STAGING="$STAGING/dmg_staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "--> Creating friend-test disk image ($DMG_PATH)..."
hdiutil create -volname "Ivy Friend Test" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
fi

# Move app bundle to output directory
rm -rf "$OUTPUT_DIR/Ivy.app"
cp -R "$APP_BUNDLE" "$OUTPUT_DIR/Ivy.app"

# 8. Checksums and Signing Limits Notice
echo ""
echo "=== Friend-Test Packaging Complete ==="
echo "Artifacts preserved in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
echo ""
echo "Checksums (SHA-256):"
shasum -a 256 "$OUTPUT_DIR/Ivy.app/Contents/MacOS/Ivy"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
echo ""
echo "--- DISTRIBUTION LIMITS NOTICE ---"
echo "1. Platform Support: macOS 14.0+ (Sonoma) / macOS 15.0+ (Sequoia) on Apple Silicon (arm64). Intel untested. Windows unsupported."
echo "2. Notarization: Friend-test builds are not notarized through Apple notarytool. Testers must right-click -> Open to bypass Gatekeeper."
echo "3. Permissions Required: Accessibility (AX) and Screen Recording must be granted in macOS System Settings > Privacy & Security."
echo "-----------------------------------"
