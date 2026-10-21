// Renders the BetterFinder app icon: a single, soft folder on a quiet squircle.
// Usage: swift scripts/make-icon.swift <output-dir> [variant] [--preview]
//   variant: rose (default) | light | graphite
import AppKit

let args = CommandLine.arguments.dropFirst()
let outDir = URL(fileURLWithPath: args.first { !$0.hasPrefix("-") && !["light", "rose", "graphite"].contains($0) } ?? ".")
let variant = args.first { ["light", "rose", "graphite"].contains($0) } ?? "rose"
let previewOnly = args.contains("--preview")

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

struct Palette {
    let bgTop: UInt32, bgBottom: UInt32
    let backTop: UInt32, backBottom: UInt32
    let frontTop: UInt32, frontBottom: UInt32
    let rim: CGFloat
}

let palettes: [String: Palette] = [
    "light": .init(bgTop: 0xFFFFFF, bgBottom: 0xECEBF0, backTop: 0xF08A92, backBottom: 0xD9536A,
                   frontTop: 0xFF9E8F, frontBottom: 0xEC5F78, rim: 0.10),
    "rose": .init(bgTop: 0xFF8E86, bgBottom: 0xE04F6E, backTop: 0xFFFFFF, backBottom: 0xFFE4E6,
                  frontTop: 0xFFFFFF, frontBottom: 0xFFF1F1, rim: 0),
    "graphite": .init(bgTop: 0x3A3A40, bgBottom: 0x1C1C20, backTop: 0xE86A7C, backBottom: 0xB8405A,
                      frontTop: 0xFF9C8C, frontBottom: 0xE8546A, rim: 0),
]

/// Folder silhouette: a back sheet with a soft tab, and a front panel slightly lower.
func folderBack(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let radius: CGFloat = 44, tabW = r.width * 0.36, tabH: CGFloat = 46
    p.move(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + radius, y: r.maxY), radius: radius)
    p.addLine(to: CGPoint(x: r.minX + tabW - 30, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX + tabW + 34, y: r.maxY - tabH),
               control1: CGPoint(x: r.minX + tabW + 4, y: r.maxY),
               control2: CGPoint(x: r.minX + tabW + 4, y: r.maxY - tabH))
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY - tabH))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY - tabH), tangent2End: CGPoint(x: r.maxX, y: r.maxY - tabH - radius), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX - radius, y: r.minY), radius: radius)
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX, y: r.minY + radius), radius: radius)
    p.closeSubpath()
    return p
}

func render(_ px: Int, _ pal: Palette) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.interpolationQuality = .high

    // Squircle on the macOS icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.22))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(pal.bgBottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(pal.bgTop), rgb(pal.bgBottom)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Folder
    let back = CGRect(x: 237, y: 292, width: 550, height: 440)
    ctx.saveGState()
    ctx.addPath(folderBack(back))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(pal.backTop), rgb(pal.backBottom)]), start: CGPoint(x: 512, y: back.maxY), end: CGPoint(x: 512, y: back.minY), options: [])
    ctx.restoreGState()

    let front = CGRect(x: 237, y: 292, width: 550, height: 356)
    let frontPath = CGPath(roundedRect: front, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: rgb(0x000000, 0.18))
    ctx.addPath(frontPath)
    ctx.setFillColor(rgb(pal.frontBottom))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(pal.frontTop), rgb(pal.frontBottom)]), start: CGPoint(x: 512, y: front.maxY), end: CGPoint(x: 512, y: front.minY), options: [])
    // Hairline highlight along the top edge of the front panel.
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: front.minX + 40, y: front.maxY - 3))
    ctx.addLine(to: CGPoint(x: front.maxX - 40, y: front.maxY - 3))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()

    // Thin rim so the light variant reads on light backgrounds.
    if pal.rim > 0 {
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.setStrokeColor(rgb(0x000000, pal.rim))
        ctx.setLineWidth(2)
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

func png(_ img: CGImage) -> Data { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])! }

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

if previewOnly {
    // Side-by-side contact sheet of all variants, on light and dark strips.
    let names = ["light", "rose", "graphite"]
    let cell = 300, w = cell * names.count, h = cell * 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0xF2F2F5)); ctx.fill(CGRect(x: 0, y: cell, width: w, height: cell))
    ctx.setFillColor(rgb(0x1E1E22)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: cell))
    for (i, n) in names.enumerated() {
        let img = render(512, palettes[n]!)
        ctx.draw(img, in: CGRect(x: i * cell + 25, y: cell + 25, width: 250, height: 250))
        ctx.draw(img, in: CGRect(x: i * cell + 25, y: 25, width: 250, height: 250))
    }
    try png(ctx.makeImage()!).write(to: outDir.appendingPathComponent("icon-variants.png"))
    print("Wrote \(outDir.appendingPathComponent("icon-variants.png").path)")
    exit(0)
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let pal = palettes[variant]!
for size in [16, 32, 128, 256, 512] {
    try png(render(size, pal)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(render(size * 2, pal)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outDir.appendingPathComponent("AppIcon.icns").path) (\(variant))")
