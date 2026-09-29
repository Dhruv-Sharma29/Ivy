#!/usr/bin/env bash
# Renders Sources/Ivy/Resources/AppIcon.icns from the logo geometry in Sources/IvyCore/Branding/IvyLogo.swift.
# Re-run after changing the logo; the .icns is committed so normal builds don't need this step.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

cat > "$work/render.swift" <<'SWIFT'
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let dir = CommandLine.arguments[1]
// macOS iconset: 16, 32, 128, 256, 512 pt at 1x and 2x.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let url = Optional(URL(fileURLWithPath: "\(dir)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create \(px)px canvas")
    }
    IvyLogo.drawAppIcon(in: ctx, size: CGFloat(px))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}
SWIFT

cat Sources/IvyCore/Branding/IvyLogo.swift "$work/render.swift" > "$work/main.swift"
swiftc -O "$work/main.swift" -o "$work/render"
"$work/render" "$iconset"
iconutil -c icns "$iconset" -o Sources/Ivy/Resources/AppIcon.icns
echo "Wrote Sources/Ivy/Resources/AppIcon.icns"
