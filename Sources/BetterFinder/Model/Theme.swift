import AppKit
import SwiftUI

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex) ?? .controlAccentColor)
    }
}

struct AccentPreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let all: [AccentPreset] = [
        .init(name: "Bloom", hex: "#E8546A"),
        .init(name: "Tangerine", hex: "#F2884B"),
        .init(name: "Sun", hex: "#E0A82E"),
        .init(name: "Fern", hex: "#3FAE77"),
        .init(name: "Lagoon", hex: "#21A9B8"),
        .init(name: "Ocean", hex: "#3478F6"),
        .init(name: "Iris", hex: "#6E5CE6"),
        .init(name: "Orchid", hex: "#B05CD6"),
        .init(name: "Graphite", hex: "#7D7D85"),
    ]
}

struct FinderTag: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

    static let standard: [FinderTag] = [
        .init(name: "Red", color: Color(hex: "#FF5F57")),
        .init(name: "Orange", color: Color(hex: "#FF9F0A")),
        .init(name: "Yellow", color: Color(hex: "#FFD60A")),
        .init(name: "Green", color: Color(hex: "#32D74B")),
        .init(name: "Blue", color: Color(hex: "#0A84FF")),
        .init(name: "Purple", color: Color(hex: "#BF5AF2")),
        .init(name: "Gray", color: Color(hex: "#98989D")),
    ]

    static func color(for name: String) -> Color {
        standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color ?? Color(hex: "#98989D")
    }
}
