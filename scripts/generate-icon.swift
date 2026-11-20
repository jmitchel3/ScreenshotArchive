import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let context = NSGraphicsContext.current!.cgContext
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // macOS icon grid inset (~10% padding) and rounded squircle corner radius (~22.5%)
    let inset = size * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft drop shadow
    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.shadowBlurRadius = size * 0.032
    shadow.set()
    NSColor(calibratedRed: 0.14, green: 0.45, blue: 0.94, alpha: 1.0).setFill()
    cardPath.fill()
    context.restoreGState()

    // Gradient fill inside card
    context.saveGState()
    cardPath.addClip()
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.24, green: 0.62, blue: 1.0, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.86, alpha: 1.0)
    )!
    gradient.draw(in: cardRect, angle: -90)

    // Subtle top gloss highlight
    let borderPath = NSBezierPath(
        roundedRect: cardRect.insetBy(dx: max(0.5, size * 0.008), dy: max(0.5, size * 0.008)),
        xRadius: cornerRadius * 0.96,
        yRadius: cornerRadius * 0.96
    )
    borderPath.lineWidth = max(1.0, size * 0.015)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    borderPath.stroke()
    context.restoreGState()

    // Centered white tray.and.arrow.down.fill SF Symbol
    let pointSize = size * 0.40
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let drawRect = NSRect(
            x: (size - symbolSize.width) / 2.0,
            y: (size - symbolSize.height) / 2.0 - size * 0.008,
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in specs {
    let data = renderIcon(pixelSize: pixels)
    try data.write(to: outputDir.appendingPathComponent(filename))
}
