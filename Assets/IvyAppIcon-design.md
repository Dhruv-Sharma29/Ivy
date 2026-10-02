# Ivy app icon

Master: `IvyAppIcon.png` (1254 × 1254 RGBA, transparent exterior).
Packaged macOS icon: `Sources/Ivy/Resources/AppIcon.icns`.

The menu bar uses a simplified paired-leaf vector sprig from `IvyLogo.sprigPath`, rendered as an 18-point monochrome template. It follows the professional icon's silhouette and omits shading and tiny veins for legibility. Sidebar, empty state, Settings and the Dock use the same full-colour PNG. `scripts/make-app-icon.sh` packages that PNG at all macOS sizes so rebuilding cannot restore the old green icon.

Generated with the built-in imagegen tool, then converted to the macOS ICNS size set with Pillow. The original image is retained unchanged. The supplied pixel character is archived as a reference asset and is not shown in the workspace.

## Generation prompt

Create a professional macOS app icon for Ivy, an intelligent Mac companion. A single bold geometric ivy sprig with two elegant pointed leaves, subtly arranged into a forward code chevron, centered inside a dark midnight charcoal rounded square. Make the leaf mark luminous lavender and rich violet, with a beautifully restrained soft highlight, precise geometric contours and generous negative space. Premium software identity, minimal, memorable, confident, polished and instantly readable at 16–32 pixel Dock sizes. Flat front-facing icon, square composition, clean silhouette, no tiny details. The rounded square fills about 86% of the canvas and has consistently smooth corners. Transparent exterior around the rounded square. No text, letters, wordmark, mascot, portrait, laptop, mockup, extra symbols, busy neon glow, decorative frame or scenery. Deliver the finished icon alone, at high resolution.
