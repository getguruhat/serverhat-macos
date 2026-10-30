// Draws icon.png (1024 px) and AppIcon.icns. Run: swift make-icon.swift
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(starting: NSColor(red: 0.16, green: 0.42, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.42, green: 0.20, blue: 0.86, alpha: 1))!.draw(in: tile, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let globe = NSImage(systemSymbolName: "globe.americas.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = globe.size
    globe.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.02, width: s.width, height: s.height))
}
// A "running" light.
let dot = NSRect(x: size * 0.66, y: size * 0.17, width: size * 0.17, height: size * 0.17)
NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -size * 0.02, dy: -size * 0.02)).fill()
NSColor(red: 0.16, green: 0.80, blue: 0.38, alpha: 1).setFill(); NSBezierPath(ovalIn: dot).fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalWeb.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let small = NSImage(size: NSSize(width: px, height: px))
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    small.unlockFocus()
    let data = NSBitmapImageRep(data: small.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    if px <= 512 { try! data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try! task.run(); task.waitUntilExit()
