// Generates the DMG background image (600×400 pt @2x) with the classic
// "drag to Applications" arrow. Run once (or after design changes):
//   swift scripts/dmg-assets/make-background.swift scripts/dmg-assets/background.png
import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "background.png"

let pointSize = NSSize(width: 600, height: 400)
let scale: CGFloat = 2
let pixelSize = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pixelSize.width),
    pixelsHigh: Int(pixelSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("could not create bitmap")
}
rep.size = pointSize

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft vertical gradient background.
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
    ending: NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
)
gradient?.draw(in: NSRect(origin: .zero, size: pointSize), angle: -90)

// Title.
let title = "QuadCast Control"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(
    at: NSPoint(x: (pointSize.width - titleSize.width) / 2, y: 330),
    withAttributes: titleAttrs
)

let subtitle = "Drag the app onto the Applications folder to install"
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
]
let subSize = subtitle.size(withAttributes: subAttrs)
subtitle.draw(
    at: NSPoint(x: (pointSize.width - subSize.width) / 2, y: 52),
    withAttributes: subAttrs
)

// Arrow between the two icon positions (icons sit at x=150 and x=450,
// y≈195 in the Finder layout; Finder y grows downward, this canvas upward —
// the icons' visual center lands around y=215 here).
let arrowColor = NSColor(calibratedWhite: 0.55, alpha: 1)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 245, y: 215))
shaft.line(to: NSPoint(x: 330, y: 215))
shaft.lineWidth = 10
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 330, y: 238))
head.line(to: NSPoint(x: 366, y: 215))
head.line(to: NSPoint(x: 330, y: 192))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(Int(pixelSize.width))×\(Int(pixelSize.height)) px @\(Int(scale))x)")
