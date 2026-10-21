import AppKit

/// Keeps the app icon in step with the accent color: the Dock icon updates immediately,
/// and the bundle gets a matching custom icon so Finder, Launchpad and the Dock show it after quitting.
final class AppIconController {
    static let shared = AppIconController()
    private var appliedHex: String?
    private var pending: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    func start() {
        apply(AppSettings.shared.accentHex)
        observer = NotificationCenter.default.addObserver(forName: .displaySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleApply()
        }
    }

    /// Debounced so dragging through the color picker doesn't rewrite the bundle icon on every tick.
    private func scheduleApply() {
        let hex = AppSettings.shared.accentHex.uppercased()
        guard hex != appliedHex else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(hex) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func apply(_ rawHex: String) {
        let hex = rawHex.uppercased()
        appliedHex = hex
        let isDefault = hex == AppIconRenderer.defaultAccentHex.uppercased()
        guard let cg = AppIconRenderer.render(size: 1024, accentHex: hex) else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
        NSApp.applicationIconImage = isDefault ? nil : image

        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"), FileManager.default.isWritableFile(atPath: bundlePath) else { return }
        // The default accent matches the bundled AppIcon.icns, so clear any custom icon instead of stacking one.
        NSWorkspace.shared.setIcon(isDefault ? nil : image, forFile: bundlePath, options: [])
    }
}
