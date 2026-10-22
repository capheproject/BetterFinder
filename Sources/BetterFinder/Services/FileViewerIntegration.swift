import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Requests from other apps: "open this folder" (Launch Services, when BetterFinder handles
/// folders) and "reveal these files" (the NSFileViewer Apple event behind "Show in Finder").
enum ExternalOpen {
    private static var pending: (urls: [URL], reveal: Bool)?

    private static var batch: (urls: [URL], reveal: Bool)?
    private static var batchWork: DispatchWorkItem?

    /// macOS sends one request per item ("Show in Finder" on several files), so gather requests
    /// that arrive together and handle them as one — all revealed items end up selected.
    static func handle(_ urls: [URL], reveal: Bool) {
        let urls = urls.map(\.standardizedFileURL).filter(FileSystem.exists)
        guard !urls.isEmpty else { return }
        if let current = batch, current.reveal != reveal { flushBatch() }
        batch = ((batch?.urls ?? []) + urls, reveal)
        batchWork?.cancel()
        let work = DispatchWorkItem { flushBatch() }
        batchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private static func flushBatch() {
        batchWork?.cancel()
        guard let b = batch else { return }
        batch = nil
        var seen = Set<URL>()
        deliver(b.urls.filter { seen.insert($0).inserted }, reveal: b.reveal)
    }

    private static func deliver(_ urls: [URL], reveal: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        if let ws = targetWorkspace, let window = ws.window {
            // Reuse the existing window even if it's minimized or on another Space.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            show(urls, reveal: reveal, in: ws)
        } else {
            // No browser window yet (launching, or all windows closed): keep the request until one registers.
            pending = (urls, reveal)
            AppDelegate.openMainWindow?()
        }
    }

    /// Called when a browser window appears.
    static func flush(into ws: Workspace) {
        guard let p = pending, !ws.isPortal else { return }
        pending = nil
        DispatchQueue.main.async { show(p.urls, reveal: p.reveal, in: ws) }
    }

    private static var targetWorkspace: Workspace? {
        if let ws = WorkspaceRegistry.lastActive, !ws.isPortal, ws.window != nil { return ws }
        return WorkspaceRegistry.all.first { !$0.isPortal && $0.window != nil }
    }

    private static func show(_ urls: [URL], reveal: Bool, in ws: Workspace) {
        if !reveal {
            // Opening folders: the first in the active pane, the rest as tabs beside it.
            let folders = urls.filter(FileSystem.isDirectory)
            for (i, folder) in folders.enumerated() {
                if i == 0 { ws.go(to: folder) } else { ws.activePane.addTab(url: folder, activate: false) }
            }
            return
        }
        // Revealing: show each item's folder with the items selected, grouped by folder.
        var order: [URL] = []
        var groups: [URL: [URL]] = [:]
        for u in urls {
            let parent = u.deletingLastPathComponent()
            if groups[parent] == nil { order.append(parent) }
            groups[parent, default: []].append(u)
        }
        for (i, parent) in order.enumerated() {
            let items = Set(groups[parent] ?? [])
            if i == 0 {
                ws.activeTab.navigate(to: parent, selecting: items)
            } else {
                ws.activePane.addTab(url: parent, activate: false)
            }
        }
        ws.focusActivePane()
    }

    /// Handler for the reveal Apple event ('misc'/'mvis', kAEMakeObjectsVisible).
    static func urls(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        func url(_ d: NSAppleEventDescriptor) -> URL? {
            d.fileURLValue ?? d.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue
        }
        if direct.numberOfItems == 0 { return url(direct).map { [$0] } ?? [] }
        return (1...direct.numberOfItems).compactMap { direct.atIndex($0).flatMap(url) }
    }
}

/// Makes BetterFinder (or Finder again) the system's file viewer: the target of "Show in Finder"
/// (the global NSFileViewer preference) and the default app for opening folders.
enum DefaultFileViewer {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app.betterfinder.BetterFinder" }
    private static let key = "NSFileViewer" as CFString

    static var isEnabled: Bool {
        let viewer = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return viewer == bundleID
    }

    /// Only a copy in /Applications should be registered, never a build folder.
    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static func setEnabled(_ on: Bool, completion: @escaping (String?) -> Void) {
        // "Show in Finder": the global NSFileViewer preference. Apps read it when they launch.
        CFPreferencesSetValue(key, on ? bundleID as CFString : nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Opening folders: macOS refuses to hand public.folder to another app through its APIs, so
        // add (or remove) a Launch Services rule, the same one ForkLift documents. Launch Services
        // loads it at the next login.
        setFolderHandlerRule(on)
        completion(nil)
    }

    private static let launchServicesDomain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString

    private static func setFolderHandlerRule(_ on: Bool) {
        var handlers = (CFPreferencesCopyValue("LSHandlers" as CFString, launchServicesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]]) ?? []
        handlers.removeAll { ($0["LSHandlerContentType"] as? String) == UTType.folder.identifier }
        if on {
            handlers.append(["LSHandlerContentType": UTType.folder.identifier, "LSHandlerRoleAll": bundleID])
        }
        CFPreferencesSetValue("LSHandlers" as CFString, handlers as CFArray, launchServicesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(launchServicesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
