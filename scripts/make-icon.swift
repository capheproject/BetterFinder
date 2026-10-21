// Renders the BetterFinder app icon to an .icns file.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle body on the macOS icon grid (824pt inside 1024).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0xE8546A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFF8A7A), color(0xE8546A), color(0x8B5CF6)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    // Soft glow
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])

    // Back folder sheet with tab
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 240, y: 300))
    back.addLine(to: CGPoint(x: 240, y: 660))
    back.addArc(tangent1End: CGPoint(x: 240, y: 700), tangent2End: CGPoint(x: 280, y: 700), radius: 40)
    back.addLine(to: CGPoint(x: 420, y: 700))
    back.addArc(tangent1End: CGPoint(x: 450, y: 700), tangent2End: CGPoint(x: 470, y: 676), radius: 30)
    back.addLine(to: CGPoint(x: 500, y: 640))
    back.addLine(to: CGPoint(x: 744, y: 640))
    back.addArc(tangent1End: CGPoint(x: 784, y: 640), tangent2End: CGPoint(x: 784, y: 600), radius: 40)
    back.addLine(to: CGPoint(x: 784, y: 300))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(color(0xFFFFFF, 0.55))
    ctx.fillPath()

    // Front panel, split into two "panes"
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x3A0A2A, 0.35))
    let left = CGPath(roundedRect: CGRect(x: 240, y: 260, width: 262, height: 340), cornerWidth: 36, cornerHeight: 36, transform: nil)
    let right = CGPath(roundedRect: CGRect(x: 522, y: 260, width: 262, height: 340), cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.addPath(left)
    ctx.addPath(right)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // List lines inside panes
    ctx.setFillColor(color(0xE8546A, 0.85))
    for (i, w) in [170.0, 130, 150].enumerated() {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 280, y: 500 - Double(i) * 70, width: w, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    }
    ctx.fillPath()
    ctx.setFillColor(color(0x8B5CF6, 0.85))
    for (i, w) in [150.0, 182, 120].enumerated() {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 562, y: 500 - Double(i) * 70, width: w, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    }
    ctx.fillPath()

    // Sparkle
    func sparkle(_ c: CGPoint, _ r: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        ctx.addPath(p)
    }
    ctx.setFillColor(color(0xFFFFFF))
    sparkle(CGPoint(x: 760, y: 770), 74)
    sparkle(CGPoint(x: 660, y: 812), 30)
    ctx.fillPath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
