import AppKit
import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: input),
      let data = try? Data(contentsOf: input),
      let representation = NSBitmapImageRep(data: data) else {
    fatalError("Cannot decode screenshot")
}
let width = representation.pixelsWide
let height = representation.pixelsHigh
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
let scaleX = CGFloat(width) / 1865
let scaleY = CGFloat(height) / 2000
func redact(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, label: String) {
    let rect = NSRect(x: x * scaleX, y: CGFloat(height) - (top + h) * scaleY, width: w * scaleX, height: h * scaleY)
    NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()
    let text = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: 18 * scaleX),
        .foregroundColor: NSColor.darkGray,
    ])
    text.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - 10 * scaleY))
}
redact(x: 1540, top: 1010, w: 195, h: 40, label: "Папка на Mac")
redact(x: 300, top: 1350, w: 1400, h: 45, label: "VLC на iPad (локальный адрес скрыт)")
redact(x: 158, top: 1405, w: 1325, h: 43, label: "http://ipad.local/")
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot create PNG") }
try png.write(to: output, options: .withoutOverwriting)
print("Prepared documentation screenshot: \(width)×\(height), \(output.path)")
