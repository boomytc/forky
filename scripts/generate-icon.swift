import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = root.appendingPathComponent("Sources/Forky/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.055, green: 0.15, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25, y: 25, width: 974, height: 974), xRadius: 220, yRadius: 220).fill()
        NSColor(red: 0.38, green: 0.92, blue: 0.69, alpha: 1).setStroke()
        let stem = NSBezierPath()
        stem.lineWidth = 62
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 350, y: 278))
        stem.line(to: NSPoint(x: 350, y: 720))
        stem.move(to: NSPoint(x: 350, y: 410))
        stem.curve(to: NSPoint(x: 700, y: 720), controlPoint1: NSPoint(x: 350, y: 585), controlPoint2: NSPoint(x: 700, y: 490))
        stem.stroke()
        for point in [NSPoint(x: 350,y:278), NSPoint(x:350,y:740), NSPoint(x:700,y:740)] {
            NSColor(red: 0.055, green: 0.15, blue: 0.13, alpha: 1).setFill()
            let circle = NSBezierPath(ovalIn: NSRect(x: point.x-64, y: point.y-64, width: 128, height: 128))
            circle.fill()
            NSColor(red: 0.65, green: 1, blue: 0.81, alpha: 1).setStroke()
            circle.lineWidth = 35
            circle.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(pointSize)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(pointSize)x\(pointSize)", "scale": "\(scale)x", "filename": filename])
    }
}
try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["version": 1, "author": "Forky"]], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"Forky\",\"version\":1}}\n".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Generated original Forky app icon.")
