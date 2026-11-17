import AppKit

// Icon 1024x1024: nền tím đậm bo góc, giữa là màn hình máy Mac bóng màu hồng → tím,
// trên màn hình có dấu lấp lánh trắng (nghĩa: máy Mac sạch).
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

// 1. Nền bo góc theo khung chuẩn macOS
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); bg.fill()
ctx.restoreGState()
NSGradient(colors: [rgb(28, 10, 60), rgb(62, 22, 110), rgb(96, 34, 140)])!.draw(in: bg, angle: 90)
NSGraphicsContext.saveGraphicsState()
bg.addClip()
// quầng sáng hồng phía sau màn hình
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(255, 80, 170, 0.50).cgColor, rgb(255, 80, 170, 0.18).cgColor, rgb(255, 80, 170, 0).cgColor] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
NSGraphicsContext.restoreGraphicsState()

// 2. Chân đế màn hình
let neck = NSBezierPath()
neck.move(to: NSPoint(x: 452, y: 360)); neck.line(to: NSPoint(x: 572, y: 360))
neck.line(to: NSPoint(x: 598, y: 262)); neck.line(to: NSPoint(x: 426, y: 262)); neck.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSGradient(colors: [rgb(150, 60, 220), rgb(110, 40, 190)])!.draw(in: neck, angle: -90)
let foot = NSBezierPath(roundedRect: NSRect(x: 372, y: 236, width: 280, height: 40), xRadius: 20, yRadius: 20)
NSGradient(colors: [rgb(200, 120, 255), rgb(120, 50, 200)])!.draw(in: foot, angle: -90)
ctx.restoreGState()

// 3. Thân màn hình bóng: hồng → tím
let body = NSRect(x: 196, y: 330, width: 632, height: 470)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(20, 0, 40, 0.6).cgColor)
NSColor.black.setFill(); bodyPath.fill()
ctx.restoreGState()
NSGradient(colors: [rgb(255, 110, 190), rgb(236, 72, 170), rgb(150, 70, 245)])!.draw(in: bodyPath, angle: -55)
// viền sáng phía trên cho cảm giác bóng
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.maxY - 120, width: body.width, height: 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 4. Mặt kính màn hình
let glass = body.insetBy(dx: 34, dy: 34).offsetBy(dx: 0, dy: 6)
let glassPath = NSBezierPath(roundedRect: glass, xRadius: 36, yRadius: 36)
NSGradient(colors: [rgb(60, 14, 90), rgb(110, 26, 120), rgb(170, 40, 140)])!.draw(in: glassPath, angle: -60)
// vệt phản chiếu chéo trên kính
NSGraphicsContext.saveGraphicsState()
glassPath.addClip()
let shine = NSBezierPath()
shine.move(to: NSPoint(x: glass.minX, y: glass.maxY))
shine.line(to: NSPoint(x: glass.minX + glass.width * 0.55, y: glass.maxY))
shine.line(to: NSPoint(x: glass.minX + glass.width * 0.20, y: glass.minY))
shine.line(to: NSPoint(x: glass.minX, y: glass.minY)); shine.close()
NSColor.white.withAlphaComponent(0.08).setFill(); shine.fill()
NSGraphicsContext.restoreGraphicsState()

// 5. Dấu lấp lánh trắng giữa màn hình
let cfg = NSImage.SymbolConfiguration(pointSize: 210, weight: .bold).applying(.init(paletteColors: [.white]))
let spark = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let ss = spark.size
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(255, 170, 230, 0.95).cgColor)
spark.draw(in: NSRect(x: glass.midX - ss.width / 2, y: glass.midY - ss.height / 2, width: ss.width, height: ss.height))
ctx.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
