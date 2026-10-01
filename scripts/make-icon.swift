// Draws the app icon (a pointer inside a two-arrow switch ring) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

/// Draws the icon on a 1024-point canvas scaled to `pixels`. Coordinates are y-up.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Background: rounded square on the macOS icon grid (824pt body, 100pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(red: 0.27, green: 0.55, blue: 0.98, alpha: 1).cgColor,
            NSColor(red: 0.42, green: 0.24, blue: 0.91, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Switch ring: two arcs chasing each other, each ending in an arrowhead.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 290
    let ringColor = NSColor(red: 0.95, green: 0.96, blue: 1, alpha: 1).cgColor
    for start in [CGFloat(25), 205] {
        let startAngle = start * .pi / 180
        let endAngle = (start + 125) * .pi / 180
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        ctx.setStrokeColor(ringColor)
        ctx.setLineWidth(54)
        ctx.setLineCap(.round)
        ctx.strokePath()

        // Arrowhead at the arc's end, pointing along the counterclockwise tangent.
        let end = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
        let tangent = CGPoint(x: -sin(endAngle), y: cos(endAngle))
        let normal = CGPoint(x: cos(endAngle), y: sin(endAngle))
        let length: CGFloat = 105, halfWidth: CGFloat = 78
        ctx.move(to: CGPoint(x: end.x + tangent.x * length, y: end.y + tangent.y * length))
        ctx.addLine(to: CGPoint(x: end.x + normal.x * halfWidth, y: end.y + normal.y * halfWidth))
        ctx.addLine(to: CGPoint(x: end.x - normal.x * halfWidth, y: end.y - normal.y * halfWidth))
        ctx.closePath()
        ctx.setFillColor(ringColor)
        ctx.fillPath()
    }

    // Classic macOS pointer, defined tip-first in a y-down unit box and placed in the ring.
    let pointer: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0.78), CGPoint(x: 0.18, y: 0.62), CGPoint(x: 0.31, y: 0.92),
        CGPoint(x: 0.43, y: 0.87), CGPoint(x: 0.30, y: 0.57), CGPoint(x: 0.53, y: 0.57),
    ]
    let height: CGFloat = 400
    let origin = CGPoint(x: 512 - 0.25 * height, y: 512 + 0.47 * height)
    let pointerPath = CGMutablePath()
    pointerPath.addLines(between: pointer.map { CGPoint(x: origin.x + $0.x * height, y: origin.y - $0.y * height) })
    pointerPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(pointerPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(pointerPath)
    ctx.setStrokeColor(NSColor(white: 0.08, alpha: 1).cgColor)
    ctx.setLineWidth(22)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let png = drawIcon(pixels: size * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
