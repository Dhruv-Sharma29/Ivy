#!/usr/bin/env bash
# Builds Ivy and launches it as a real Ivy.app bundle.
# "Hey Ivy" (speech recognition) and the microphone/calendar prompts need the app's own bundle identity;
# under `swift run Ivy` speech recognition is disabled, so Hey Ivy cannot interrupt there.
# Keys are forwarded from this shell's GEMINI_API_KEY / ELEVENLABS_API_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-debug}"
swift build -c "$config"

app=".build/Ivy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$config/Ivy" "$app/Contents/MacOS/Ivy"
cp Sources/Ivy/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R ".build/$config/Ivy_Ivy.bundle" "$app/Contents/Resources/"
cp Sources/Ivy/Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Ivy" "$app/Contents/Info.plist" 2>/dev/null || true
entitlements="Sources/Ivy/Resources/Ivy.entitlements"
# A stable signing identity keeps macOS privacy grants (mic, speech, calendar) across rebuilds; ad-hoc re-prompts each time.
identity="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --entitlements "$entitlements" --sign "${identity:--}" "$app"

for key in GEMINI_API_KEY ELEVENLABS_API_KEY; do
    [ -n "${!key:-}" ] || echo "warning: $key is not set in this shell; enter it in Ivy's settings or export it first." >&2
done

# Replace any running Ivy so two instances never fight over the push-to-talk chord.
pkill -x Ivy || true
log="$HOME/Library/Logs/Ivy.log"
: > "$log"
# `open --env NAME` alone does NOT forward the value; it must be NAME=value.
env_args=()
for key in GEMINI_API_KEY ELEVENLABS_API_KEY; do
    [ -n "${!key:-}" ] && env_args+=(--env "$key=${!key}")
done
open -n "$app" ${env_args[@]+"${env_args[@]}"} --stdout "$log" --stderr "$log"
echo "Ivy launched; diagnostics: $log"
