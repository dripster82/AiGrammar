#!/bin/zsh
# Generate App/AppIcon.icns — an "Abc" spellcheck glyph in the AR Workspace icon style
# (dark gradient squircle + white glyph). Run once (or after changing the design);
# build-app.sh copies the .icns into the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PNG="$TMP/icon_1024.png"

swift - "$PNG" <<'SWIFT'
import AppKit
_ = NSApplication.shared
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Dark squircle background with a top-lit gradient (matches AR Workspace).
let inset = size * 0.085
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
])!
grad.draw(in: path, angle: -90)

// "Abc" wordmark, centred, with a dotted spellcheck underline in the violet accent.
let text = "Abc" as NSString
let font = NSFont.systemFont(ofSize: 420, weight: .semibold)
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
]
let textSize = text.size(withAttributes: attrs)
let tx = (size - textSize.width) / 2
let ty = (size - textSize.height) / 2 + size * 0.03
text.draw(in: NSRect(x: tx, y: ty, width: textSize.width, height: textSize.height), withAttributes: attrs)

// Dotted underline beneath the wordmark.
let accent = NSColor(calibratedRed: 0.486, green: 0.361, blue: 0.988, alpha: 1)
accent.setStroke()
let underline = NSBezierPath()
let uy = ty + size * 0.03
underline.move(to: NSPoint(x: tx + size * 0.02, y: uy))
underline.line(to: NSPoint(x: tx + textSize.width - size * 0.02, y: uy))
underline.lineWidth = size * 0.028
underline.lineCapStyle = .round
underline.setLineDash([1, size * 0.055], count: 2, phase: 0)
underline.stroke()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
SWIFT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/App/AppIcon.icns"
echo "Wrote $ROOT/App/AppIcon.icns"
