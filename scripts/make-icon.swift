// Draws the Shapeshift app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 24 * s; sh.shadowOffset = NSSize(width: 0, height: -10 * s); sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sh.set(); NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.98, alpha: 1)])!
        .draw(in: squircle, angle: -60)
    // Wheel: six wedges in three colours.
    let c = NSPoint(x: 512 * s, y: 512 * s)
    let colors: [NSColor] = [.white, NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.8)]
    for i in 0..<6 {
        let start = CGFloat(i) * 60 + 92, end = start + 56
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: 300 * s, startAngle: start, endAngle: end)
        p.appendArc(withCenter: c, radius: 130 * s, startAngle: end, endAngle: start, clockwise: true)
        p.close()
        colors[i % 3].setFill(); p.fill()
    }
    // Center: a curved arrow suggesting transformation.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 92 * s, y: c.y - 92 * s, width: 184 * s, height: 184 * s)).fill()
    let arrow = NSBezierPath()
    arrow.lineWidth = 22 * s; arrow.lineCapStyle = .round
    arrow.appendArc(withCenter: c, radius: 50 * s, startAngle: 120, endAngle: 400)
    NSColor(calibratedRed: 0.30, green: 0.35, blue: 0.96, alpha: 1).setStroke(); arrow.stroke()
    let tipAngle: CGFloat = 40 * .pi / 180
    let tip = NSPoint(x: c.x + cos(tipAngle) * 50 * s, y: c.y + sin(tipAngle) * 50 * s)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: tip.x + 30 * s, y: tip.y + 4 * s))
    head.line(to: NSPoint(x: tip.x - 12 * s, y: tip.y + 30 * s))
    head.line(to: NSPoint(x: tip.x - 4 * s, y: tip.y - 20 * s))
    head.close()
    NSColor(calibratedRed: 0.30, green: 0.35, blue: 0.96, alpha: 1).setFill(); head.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Wrote AppIcon.icns")
