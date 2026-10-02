# Ivy Production Release & Distribution Guide

This document describes the process for building, signing, notarizing, and distributing production releases of **Ivy** for macOS.

---

## 1. Release Architecture

Ivy is distributed as a signed, notarized macOS application bundle with **Hardened Runtime** enabled:

- **Target OS**: macOS 14.0 (Sonoma) and later (Apple Silicon & Intel)
- **Bundle Identifier**: `com.ivy.assistant`
- **Application Type**: Desktop assistant (`LSUIElement = false`)
- **Distribution Format**: Mountable Disk Image (`Ivy-<version>.dmg`) containing `Ivy.app` and `/Applications` symlink
- **Security Profile**: Developer ID Application with Hardened Runtime (`--options runtime`) and Apple Notarization ticket stapled

---

## 2. Release Prerequisites

1. **macOS Machine**: Running macOS 14.0+ with Xcode 16.0+ Command Line Tools installed.
2. **Apple Developer Account**: Enrolled in the Apple Developer Program with an active Team ID.
3. **Developer ID Certificate**: A valid `Developer ID Application: <Name> (<TeamID>)` installed in the macOS login Keychain.
4. **App-Specific Password or Keychain Profile**: Generated from [appleid.apple.com](https://appleid.apple.com) for `xcrun notarytool`.

---

## 3. Quick Start: Release Packaging

To build, sign, and assemble the release DMG:

```bash
# Build release binary, sign with local certificate, and generate DMG:
./scripts/package-release.sh
```

Artifacts are produced in the `dist/` directory:
- `dist/Ivy.app` — Packaged application bundle
- `dist/Ivy-1.0.0.dmg` — Compressed, signed distributable disk image

---

## 4. Code Signing Configuration

The packaging script (`scripts/package-release.sh`) automatically detects available signing certificates:

1. **Explicit Identity** (`CODESIGN_IDENTITY`):
   ```bash
   export CODESIGN_IDENTITY="Developer ID Application: Your Company LLC (TEAMID1234)"
   ./scripts/package-release.sh
   ```
2. **Auto-Detection**:
   If `CODESIGN_IDENTITY` is unset, the script looks for `Developer ID Application: *`. If not found, it falls back to `Apple Development: *` (for local development testing). If no certificates exist, it uses ad-hoc signing (`-`).
3. **Hardened Runtime Entitlements**:
   Every build signs with `Sources/Ivy/Resources/Ivy.entitlements`:
   - `com.apple.security.network.client`: Outbound WebSocket & HTTPS to Gemini and ElevenLabs
   - `com.apple.security.device.audio-input`: Real-time microphone capture for voice sessions
   - `com.apple.security.personal-information.calendars`: EventKit calendar scheduling
   - `com.apple.security.automation.apple-events`: AppleScript automation

---

## 5. Apple Notarization Workflow

Apple Gatekeeper requires notarization for all software distributed outside the Mac App Store.

### Step 5.1: Configure Notarytool Credentials

Store an app-specific password in your Keychain once:

```bash
xcrun notarytool store-credentials "ivy-notary" \
  --apple-id "developer@example.com" \
  --team-id "TEAMID1234" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### Step 5.2: Package and Notarize

Set `NOTARY_PROFILE` and run the release script:

```bash
export NOTARY_PROFILE="ivy-notary"
./scripts/package-release.sh
```

Alternatively, pass credentials directly via environment variables:

```bash
export APPLE_ID="developer@example.com"
export APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="TEAMID1234"
./scripts/package-release.sh
```

The script will automatically:
1. Upload `dist/Ivy-<version>.dmg` to Apple Notary Service
2. Poll until notarization succeeds (`--wait`)
3. Staple the notarization ticket to `dist/Ivy.app` and `dist/Ivy-<version>.dmg`
4. Validate the stapled ticket using macOS Gatekeeper assessment (`spctl`)

---

## 6. Validating Release Artifacts

Verify Gatekeeper acceptance locally:

```bash
# Verify application bundle signature:
codesign --verify --deep --strict --verbose=2 dist/Ivy.app

# Verify Gatekeeper acceptance:
spctl -a -t open --context context:primary-signature -v dist/Ivy.app

# Check stapled notarization ticket:
xcrun stapler validate dist/Ivy-1.0.0.dmg
```

Expected output:
```
dist/Ivy.app: accepted
source=Notarized Developer ID
```

---

## 7. Artifact Hygiene & Zero-Leak Audit

Before shipping, verify that no development secrets or debug artifacts are included:

- **Secrets**: No API keys (Gemini, ElevenLabs) exist in the `.app` bundle, resources, or Info.plist.
- **Keychain**: Users enter credentials via Settings; values are stored securely in macOS Keychain (`kSecClassGenericPassword`, service `com.ivy.assistant`).
- **Temporary Files**: `dist/Ivy.app` contains no `.DS_Store`, `DerivedData`, or build intermediary files.
- **Logging**: Production logs redact all prompts, speech text, and tool payloads.

---

## 8. Release Verification Checklist

- [ ] `swift test` passes with 0 failures across all test suites.
- [ ] `swift build -Xswiftc -strict-concurrency=complete` compiles with 0 errors and 0 warnings.
- [ ] `git diff --check` passes cleanly.
- [ ] `IvyVersion.swift` matches `Info.plist` marketing version and build number.
- [ ] `./scripts/package-release.sh` executes cleanly and generates `dist/Ivy.app` and `dist/Ivy-<version>.dmg`.
- [ ] `codesign --verify --deep --strict dist/Ivy.app` confirms valid signature.
- [ ] Notarization ticket stapled and validated with `spctl`.
