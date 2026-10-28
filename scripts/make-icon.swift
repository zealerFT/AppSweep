import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.62, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 168, y: 240, width: 420, height: 550), xRadius: 48, yRadius: 48).fill()
        let symbol = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 550, weight: .regular))!
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: 330, y: 196, width: 470, height: 590))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
