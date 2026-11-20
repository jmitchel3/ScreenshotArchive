import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

/// Renders an original geometric macOS app icon (no SF Symbols embedded).
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

    // macOS icon grid inset (~9.5% padding) and squircle-like corner radius (~22.5%)
    let inset = size * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft drop shadow beneath the tile
    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.shadowBlurRadius = size * 0.032
    shadow.set()
    NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.92, alpha: 1.0).setFill()
    cardPath.fill()
    context.restoreGState()

    // Background gradient + subtle highlight rim
    context.saveGState()
    cardPath.addClip()
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.23, green: 0.61, blue: 1.0, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.84, alpha: 1.0)
    )!
    gradient.draw(in: cardRect, angle: -90)

    let borderPath = NSBezierPath(
        roundedRect: cardRect.insetBy(dx: max(0.5, size * 0.008), dy: max(0.5, size * 0.008)),
        xRadius: cornerRadius * 0.96,
        yRadius: cornerRadius * 0.96
    )
    borderPath.lineWidth = max(1.0, size * 0.014)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    borderPath.stroke()

    // Back stacked screenshot card (translucent, gently tilted)
    context.saveGState()
    let backCardRect = CGRect(
        x: size * 0.27,
        y: size * 0.43,
        width: size * 0.46,
        height: size * 0.32
    )
    let backCard = NSBezierPath(roundedRect: backCardRect, xRadius: size * 0.045, yRadius: size * 0.045)
    NSColor.white.withAlphaComponent(0.26).setFill()
    backCard.fill()
    context.restoreGState()

    // Front screenshot card with minimal viewfinder/capture marks
    let frontCardRect = CGRect(
        x: size * 0.23,
        y: size * 0.36,
        width: size * 0.54,
        height: size * 0.35
    )
    let frontCard = NSBezierPath(roundedRect: frontCardRect, xRadius: size * 0.05, yRadius: size * 0.05)
    NSColor.white.withAlphaComponent(0.95).setFill()
    frontCard.fill()

    // Small horizon/sun motif inside the screenshot card
    let sunRadius = size * 0.038
    let sunRect = CGRect(
        x: frontCardRect.minX + size * 0.085,
        y: frontCardRect.maxY - size * 0.13,
        width: sunRadius * 2,
        height: sunRadius * 2
    )
    NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.95, alpha: 0.38).setFill()
    NSBezierPath(ovalIn: sunRect).fill()

    // Foreground archive tray at the bottom
    let trayRect = CGRect(
        x: size * 0.19,
        y: size * 0.21,
        width: size * 0.62,
        height: size * 0.23
    )
    let trayPath = NSBezierPath(roundedRect: trayRect, xRadius: size * 0.055, yRadius: size * 0.055)
    let trayGradient = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.98),
        ending: NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.0, alpha: 0.98)
    )!
    context.saveGState()
    let trayShadow = NSShadow()
    trayShadow.shadowColor = NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.45, alpha: 0.28)
    trayShadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    trayShadow.shadowBlurRadius = size * 0.025
    trayShadow.set()
    NSColor.white.setFill()
    trayPath.fill()
    context.restoreGState()

    context.saveGState()
    trayPath.addClip()
    trayGradient.draw(in: trayRect, angle: -90)
    context.restoreGState()

    // Centered tray notch cutout (gives the classic archive-box silhouette)
    let notchWidth = size * 0.22
    let notchHeight = size * 0.075
    let notchRect = CGRect(
        x: (size - notchWidth) / 2.0,
        y: trayRect.maxY - notchHeight + size * 0.01,
        width: notchWidth,
        height: notchHeight
    )
    let notchPath = NSBezierPath(roundedRect: notchRect, xRadius: size * 0.032, yRadius: size * 0.032)
    NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.91, alpha: 1.0).setFill()
    notchPath.fill()

    // Crisp downward archive arrow centered above the tray notch
    let arrowCenterX = size * 0.5
    let arrowTipY = trayRect.maxY - size * 0.025
    let arrowShaftTopY = frontCardRect.maxY - size * 0.085
    let shaftWidth = max(2.0, size * 0.056)
    let headHalfWidth = size * 0.095
    let headHeight = size * 0.095

    let arrowPath = NSBezierPath()
    arrowPath.lineCapStyle = .round
    arrowPath.lineJoinStyle = .round
    arrowPath.lineWidth = shaftWidth
    arrowPath.move(to: NSPoint(x: arrowCenterX, y: arrowShaftTopY))
    arrowPath.line(to: NSPoint(x: arrowCenterX, y: arrowTipY + headHeight * 0.35))
    NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.90, alpha: 1.0).setStroke()
    arrowPath.stroke()

    let chevron = NSBezierPath()
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.lineWidth = shaftWidth
    chevron.move(to: NSPoint(x: arrowCenterX - headHalfWidth, y: arrowTipY + headHeight))
    chevron.line(to: NSPoint(x: arrowCenterX, y: arrowTipY))
    chevron.line(to: NSPoint(x: arrowCenterX + headHalfWidth, y: arrowTipY + headHeight))
    chevron.stroke()

    context.restoreGState()
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
