import CoreGraphics
import Foundation

/// Draws the BetterFinder icon — a white folder on a squircle tinted with the accent color.
/// Shared by the app (live, accent-colored Dock icon) and scripts/make-icon (the bundled .icns).
enum AppIconRenderer {
    struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat

        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }

        init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            self.init(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        }

        func mixed(with o: RGB, _ t: CGFloat) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
        var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    static let defaultAccentHex = "#E8546A"

    static func render(size px: Int, accentHex: String) -> CGImage? {
        let accent = RGB(hex: accentHex) ?? RGB(hex: defaultAccentHex)!
        let white = RGB(1, 1, 1), black = RGB(0, 0, 0)
        let bgTop = accent.mixed(with: white, 0.30)
        let bgBottom = accent.mixed(with: black, 0.05)
        let backTop = white, backBottom = white.mixed(with: accent, 0.12)
        let frontTop = white, frontBottom = white.mixed(with: accent, 0.06)

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func gradient(_ a: RGB, _ b: RGB) -> CGGradient {
            CGGradient(colorsSpace: space, colors: [a.cg, b.cg] as CFArray, locations: nil)!
        }
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        ctx.interpolationQuality = .high

        // Squircle on the macOS icon grid.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(bodyPath)
        ctx.setFillColor(bgBottom.cg)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient(bgTop, bgBottom), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

        let back = CGRect(x: 237, y: 292, width: 550, height: 440)
        ctx.saveGState()
        ctx.addPath(folderBack(back))
        ctx.clip()
        ctx.drawLinearGradient(gradient(backTop, backBottom), start: CGPoint(x: 512, y: back.maxY), end: CGPoint(x: 512, y: back.minY), options: [])
        ctx.restoreGState()

        let front = CGRect(x: 237, y: 292, width: 550, height: 356)
        let frontPath = CGPath(roundedRect: front, cornerWidth: 44, cornerHeight: 44, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: CGColor(gray: 0, alpha: 0.18))
        ctx.addPath(frontPath)
        ctx.setFillColor(frontBottom.cg)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(frontPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient(frontTop, frontBottom), start: CGPoint(x: 512, y: front.maxY), end: CGPoint(x: 512, y: front.minY), options: [])
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: front.minX + 40, y: front.maxY - 3))
        ctx.addLine(to: CGPoint(x: front.maxX - 40, y: front.maxY - 3))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Folder silhouette: a back sheet with a soft tab.
    private static func folderBack(_ r: CGRect) -> CGPath {
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
}
