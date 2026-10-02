#!/usr/bin/env bash
# Packages the professional PNG used by the app into every macOS icon size.
# Re-run after updating IvyAppIcon.png; ordinary builds use the committed .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

source_icon="Sources/Ivy/Resources/IvyAppIcon.png"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$source_icon" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$source_icon" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Sources/Ivy/Resources/AppIcon.icns
echo "Wrote Sources/Ivy/Resources/AppIcon.icns"
