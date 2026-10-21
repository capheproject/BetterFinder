// Renders the bundled AppIcon.icns with the default accent, using the app's own AppIconRenderer.
// Built by scripts/build-app.sh: swiftc scripts/make-icon/main.swift Sources/BetterFinder/Services/AppIconRenderer.swift
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let accent = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : AppIconRenderer.defaultAccentHex
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    NSBitmapImageRep(cgImage: AppIconRenderer.render(size: px, accentHex: accent)!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
