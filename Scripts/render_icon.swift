import AppKit
import Foundation

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(size: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let cg = graphics.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setShouldAntialias(true)

    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.shadowBlurRadius = 26
    shadow.shadowColor = color(0x0A282C, alpha: 0.28)
    shadow.set()
    color(0x153F43).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x153F43), ending: color(0x2C7C70))!.draw(in: tile, angle: 90)
    color(0xC9F0DB, alpha: 0.22).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow()
    markShadow.shadowOffset = NSSize(width: 0, height: -8)
    markShadow.shadowBlurRadius = 9
    markShadow.shadowColor = color(0x0A282C, alpha: 0.22)
    markShadow.set()
    color(0xF4F6EE).setFill()
    let upper = NSBezierPath()
    upper.move(to: NSPoint(x: 377, y: 507))
    upper.line(to: NSPoint(x: 646, y: 762))
    upper.line(to: NSPoint(x: 746, y: 762))
    upper.line(to: NSPoint(x: 746, y: 681))
    upper.line(to: NSPoint(x: 474, y: 423))
    upper.close()
    upper.fill()
    let lower = NSBezierPath()
    lower.move(to: NSPoint(x: 386, y: 547))
    lower.line(to: NSPoint(x: 488, y: 547))
    lower.line(to: NSPoint(x: 760, y: 286))
    lower.line(to: NSPoint(x: 760, y: 246))
    lower.line(to: NSPoint(x: 630, y: 246))
    lower.line(to: NSPoint(x: 386, y: 481))
    lower.close()
    lower.fill()
    NSBezierPath(roundedRect: NSRect(x: 274, y: 246, width: 132, height: 516), xRadius: 25, yRadius: 25).fill()
    NSGraphicsContext.restoreGraphicsState()

    for (index, y) in [282, 366, 450, 534, 618, 702].enumerated() {
        (index == 5 ? color(0xF3B65A) : color(0x1C554F)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 313, y: y, width: 54, height: 30), xRadius: 6, yRadius: 6).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 1)
    }
    try data.write(to: url)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024, to: directory.appendingPathComponent("Logo.png"))
print("Rendered native app icon sizes in \(directory.path)")
