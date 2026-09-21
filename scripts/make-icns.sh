#!/usr/bin/env bash
# Generates an AppIcon.icns for the .app bundle — an alarm-clock glyph (matches the ⏰ menu-bar
# theme) on a blue rounded-square, rendered from the built-in SF Symbol so we ship no binary asset.
# Output: $1 (default: .build/AppIcon.icns). Dependency-free beyond the Swift toolchain + iconutil.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${1:-$REPO_ROOT/.build/AppIcon.icns}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
SWIFT_SRC="$WORK/render.swift"

cat > "$SWIFT_SRC" <<'SWIFT'
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square background with a vertical blue gradient (macOS "squircle"-ish radius).
    let radius = s * 0.2237
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.00, green: 0.32, blue: 0.85, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -90)

    // Alarm-clock glyph, white, centered.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let gs = sym.size
        let drawRect = NSRect(x: (s - gs.width) / 2, y: (s - gs.height) / 2, width: gs.width, height: gs.height)
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    _ = ctx
    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at size \(size)")
    }
    return png
}

let dir = CommandLine.arguments[1]
let specs: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for spec in specs {
    let data = render(spec.size)
    try! data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(spec.name))
}
print("rendered \(specs.count) icon sizes")
SWIFT

echo "==> Rendering icon PNGs…"
swift "$SWIFT_SRC" "$ICONSET"

echo "==> iconutil → $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Icon ready: $OUT"
