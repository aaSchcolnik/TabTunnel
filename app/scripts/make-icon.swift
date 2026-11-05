// Draws TabTunnel's app icon (the extension's white cloud on a blue squircle) into an .icns.
//   swift scripts/make-icon.swift Resources/AppIcon.icns [reader]
// "reader" draws the Reader's variant: the same cloud with a small lock, so the two are easy to tell apart in
// System Settings › Full Disk Access.
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.icns"
let reader = args.count > 2 && args[2] == "reader"

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the squircle is ~80% of the canvas, centered, with room for the shadow.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: reader
        ? [NSColor(red: 0.27, green: 0.31, blue: 0.40, alpha: 1), NSColor(red: 0.15, green: 0.17, blue: 0.23, alpha: 1)]
        : [NSColor(red: 0.20, green: 0.52, blue: 1.0, alpha: 1), NSColor(red: 0.05, green: 0.36, blue: 0.90, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let cloud = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = cloud.size
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + (reader ? rect.height * 0.04 : 0))
        cloud.draw(in: NSRect(origin: origin, size: size))
    }
    if reader {
        let lockConfig = NSImage.SymbolConfiguration(pointSize: rect.width * 0.2, weight: .bold)
            .applying(.init(paletteColors: [NSColor(red: 0.15, green: 0.17, blue: 0.23, alpha: 1)]))
        if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(lockConfig) {
            let size = lock.size
            lock.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - rect.height * 0.01,
                                 width: size.width, height: size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TabTunnel-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
