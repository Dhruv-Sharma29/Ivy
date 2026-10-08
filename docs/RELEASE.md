# Ivy Production Release & Distribution Guide

This document describes the process for building, signing, notarizing, and distributing production releases of **Ivy** for macOS.

---

## 1. Release Architecture

The public-release target is a signed, notarized macOS application bundle with **Hardened Runtime** enabled:

- **Target OS**: macOS 14.0 (Sonoma) and later (Apple Silicon & Intel)
- **Bundle Identifier**: `com.ivy.assistant`
- **Application Type**: Companion/menu-bar assistant (`LSUIElement = true`); workspace opens on demand
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
- `dist/Ivy-1.1.0.dmg` — Compressed, signed distributable disk image

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

For the standard verified download experience, use Developer ID signing and notarization. The current friend-testing build is not notarized; see README.md for the manual installation flow.

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
xcrun stapler validate dist/Ivy-1.1.0.dmg
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

## v1.1 testing and rollback

`package-release.sh` keeps older DMGs and writes `dist/Ivy-1.1.0.dmg.sha256`. It does not publish a GitHub
release. Friend-testing builds use the available development/ad-hoc identity; leave notarization credentials
unset when intentionally building this testing artifact.

Before loading any production stores, v1.1 makes a one-time backup under
`~/Library/Application Support/Ivy/Backups/1.0/`. It includes `Conversations`, `Tasks`, `Proactive`,
`profile.json`, `workspaces.json` when present, plus `settings.plist` containing the exact
`ivy.settings.v1` UserDefaults value. `manifest.json` marks a complete backup. Fresh installs only write
`release-data-version.json`; a completed backup is never replaced. Caches/captures/Keychain items are excluded.
If the backup fails, Ivy opens a temporary session with a visible warning; no existing stores are loaded or migrated.

To downgrade, quit Ivy and preserve the current data/preferences separately first. Reinstall the retained
v1.0 DMG, then copy the backed-up store entries to the original Application Support/Ivy locations.
Restore only the `ivy.settings.v1` value from `settings.plist` into Ivy's UserDefaults domain
`com.ivy.assistant`; do not replace the entire preferences domain. The backup contains no Keychain keys.
Keep the completed backup and manifest. A later v1.1 launch can verify/reuse it even if its release marker
was removed during rollback. Test this process in a separate account before relying on a production downgrade.
