// Draws the app icon: `swift icon.swift out.png` writes a 1024×1024 PNG (used by build.sh).
// Rounded-square gradient background, white SF Symbol "repeat", a red record dot.
import Cocoa

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)  // 1 pt = 1 px
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 pt rounded square centered on the 1024 canvas, with a soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
           ending: NSColor(srgbRed: 0.18, green: 0.16, blue: 0.62, alpha: 1))!.draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "repeat", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let symbolRect = NSRect(x: (CGFloat(size) - symbol.size.width) / 2, y: (CGFloat(size) - symbol.size.height) / 2 + 20,
                        width: symbol.size.width, height: symbol.size.height)
symbol.draw(in: symbolRect)

// Record dot, bottom right, with a white ring so it reads on the gradient.
let dot = NSRect(x: 650, y: 190, width: 170, height: 170)
NSColor.white.setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: -14, dy: -14)).fill()
NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
