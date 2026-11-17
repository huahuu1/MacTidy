import AppKit

// Ảnh banner đầu README: icon + tên app + câu giới thiệu, bên phải là cửa sổ chính và popup thanh menu.
// Dùng: swift scripts/make_banner.swift <icon.png> <window.png> <popup.png> <out.png> <tagline>
let a = CommandLine.arguments
let W: CGFloat = 2400, H: CGFloat = 1260
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ al: CGFloat = 1) -> NSColor { NSColor(red: r/255, green: g/255, blue: b/255, alpha: al) }

// nền
NSGradient(colors: [rgb(24, 10, 52), rgb(20, 34, 70), rgb(14, 58, 78)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -25)
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(236, 72, 170, 0.35).cgColor, rgb(236, 72, 170, 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 420, y: 760), startRadius: 0, endCenter: CGPoint(x: 420, y: 760), endRadius: 700, options: [])
let glow2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(60, 220, 180, 0.25).cgColor, rgb(60, 220, 180, 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow2, startCenter: CGPoint(x: 1750, y: 600), startRadius: 0, endCenter: CGPoint(x: 1750, y: 600), endRadius: 900, options: [])

func drawShot(_ path: String, in r: NSRect, radius: CGFloat) {
    guard let im = NSImage(contentsOfFile: path) else { return }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 70, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
    im.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius); border.lineWidth = 2; border.stroke()
}

// cửa sổ chính và popup
let win = NSImage(contentsOfFile: a[2])!.size
let ww: CGFloat = 1400, wh = ww * win.height / win.width
drawShot(a[2], in: NSRect(x: 900, y: (H - wh) / 2 - 40, width: ww, height: wh), radius: 26)
let pop = NSImage(contentsOfFile: a[3])!.size
let ph: CGFloat = 860, pw = ph * pop.width / pop.height
drawShot(a[3], in: NSRect(x: 700, y: 120, width: pw, height: ph), radius: 28)

// chữ bên trái
let icon = NSImage(contentsOfFile: a[1])!
icon.draw(in: NSRect(x: 70, y: 820, width: 300, height: 300))
let title = NSAttributedString(string: "MacTidy", attributes: [
    .font: NSFont.systemFont(ofSize: 132, weight: .heavy), .foregroundColor: NSColor.white])
title.draw(at: NSPoint(x: 100, y: 640))
let para = NSMutableParagraphStyle(); para.lineSpacing = 10
let tag = NSAttributedString(string: a[5], attributes: [
    .font: NSFont.systemFont(ofSize: 46, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.82), .paragraphStyle: para])
tag.draw(with: NSRect(x: 104, y: 330, width: 560, height: 290), options: [.usesLineFragmentOrigin])

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[4]))
