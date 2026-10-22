import AppKit
import Carbon.HIToolbox
import Quartz
import QuickLookThumbnailing

// MARK: - Directory watching

/// Watches a single directory and calls `handler` (debounced, on main) when its contents change.
final class DirectoryWatcher {
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(url: URL, handler: @escaping () -> Void) {
        self.url = url
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: handler)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}

// MARK: - Git

enum GitFileStatus: String {
    case modified, added, deleted, renamed, untracked, conflicted

    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .modified: .systemOrange
        case .added: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemBlue
        case .untracked: .systemTeal
        case .conflicted: .systemPink
        }
    }
}

struct GitInfo: Equatable {
    let root: URL
    let branch: String
    let statuses: [String: GitFileStatus]
    let dirtyDirs: Set<String>

    func status(for url: URL) -> GitFileStatus? {
        let p = url.standardizedFileURL.path
        if let s = statuses[p] { return s }
        return dirtyDirs.contains(p) ? .modified : nil
    }

    var changeCount: Int { statuses.count }
}

enum GitService {
    static func repoRoot(for dir: URL) -> URL? {
        var u = dir.standardizedFileURL
        while u.path != "/" {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    static func info(for dir: URL) async -> GitInfo? {
        await Task.detached(priority: .utility) { () -> GitInfo? in
            guard let root = repoRoot(for: dir), FileManager.default.fileExists(atPath: "/usr/bin/git") else { return nil }
            // A dotfiles repo in $HOME would make every folder "dirty" and scanning untracked files is slow.
            let isHomeRepo = root.path == FileSystem.home.path
            var args = ["-C", root.path, "status", "--porcelain=v1", "-b", "-z"]
            if isHomeRepo { args.append("--untracked-files=no") }
            let r = Shell.run("/usr/bin/git", args)
            guard r.status == 0 else { return nil }
            var entries = String(decoding: r.out, as: UTF8.self).components(separatedBy: "\0")
            var branch = "HEAD"
            var statuses: [String: GitFileStatus] = [:]
            var dirty = Set<String>()
            var i = 0
            while i < entries.count {
                let e = entries[i]
                i += 1
                guard e.count > 3 else { continue }
                if e.hasPrefix("## ") {
                    branch = String(e.dropFirst(3)).components(separatedBy: "...").first ?? branch
                    if branch.hasPrefix("No commits yet on ") { branch = String(branch.dropFirst(18)) }
                    continue
                }
                let xy = Array(e.prefix(2))
                var path = String(e.dropFirst(3))
                if xy[0] == "R" || xy[0] == "C" { i += 1 } // skip the "from" path
                if path.hasSuffix("/") { path.removeLast() }
                let status: GitFileStatus
                if xy == ["?", "?"] { status = .untracked }
                else if xy.contains("U") { status = .conflicted }
                else if xy.contains("A") { status = .added }
                else if xy.contains("D") { status = .deleted }
                else if xy.contains("R") { status = .renamed }
                else { status = .modified }
                let full = root.appendingPathComponent(path).standardizedFileURL
                statuses[full.path] = status
                var parent = full.deletingLastPathComponent()
                while parent.path.count >= root.path.count {
                    dirty.insert(parent.path)
                    if parent.path == root.path { break }
                    parent = parent.deletingLastPathComponent()
                }
            }
            entries.removeAll()
            return GitInfo(root: root, branch: branch, statuses: statuses, dirtyDirs: dirty)
        }.value
    }
}

// MARK: - Spotlight

/// Runs Spotlight queries through `mdfind`, streaming results. NSMetadataQuery raises uncatchable
/// Objective-C exceptions for some predicates, so a subprocess is the safer engine.
final class SpotlightSearch {
    private var process: Process?
    private var generation = 0

    /// `query` is a raw Spotlight query string, e.g. `kMDItemFSName == "*foo*"cd`.
    /// Calls `completion` on main with partial results and once more with `finished == true`.
    func run(query: String, scopes: [String], limit: Int = 200, completion: @escaping ([URL], Bool) -> Void) {
        cancel()
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = scopes.flatMap { ["-onlyin", $0] } + [query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        process = p
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try p.run() } catch {
                DispatchQueue.main.async { completion([], true) }
                return
            }
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            var urls: [URL] = []
            var lastDelivery = Date()
            func deliver(_ finished: Bool) {
                let snapshot = urls
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    completion(snapshot, finished)
                }
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !line.isEmpty { urls.append(URL(fileURLWithPath: line)) }
                }
                if urls.count >= limit {
                    p.terminate()
                    break
                }
                if Date().timeIntervalSince(lastDelivery) > 0.15 {
                    lastDelivery = Date()
                    deliver(false)
                }
            }
            deliver(true)
        }
    }

    func cancel() {
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    static func escape(_ s: String) -> String {
        s.filter { !"*?\"\\'".contains($0) }
    }
}

// MARK: - Global hot key (⌘⇧↩ from anywhere)

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: (() -> Void)?

    func refresh() {
        AppSettings.shared.globalHotKey ? register() : unregister()
    }

    private func register() {
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKeyManager.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4246_4E44), id: 1)
        RegisterEventHotKey(UInt32(kVK_Return), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: - Quick Look panel

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    var urls: [URL] = []
    var keyHandler: ((NSEvent) -> Bool)?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.makeKeyAndOrderFront(nil)
        if panel.dataSource == nil {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
    }

    func update(urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return keyHandler?(event) ?? false
    }
}

// MARK: - Icons and thumbnails

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }

    static func invalidate(_ url: URL) { cache.removeObject(forKey: url.path as NSString) }
}

enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        // Include the modification date so edited files (e.g. a rotated photo) refresh.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(Int(size))#\(modified)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Volumes

struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let ejectable: Bool
    let symbol: String
    var id: URL { url }
}

@Observable
final class VolumeStore {
    static let shared = VolumeStore()
    var volumes: [Volume] = []

    private init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let ejectable = (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false)
            let symbol: String
            if v?.volumeIsLocal == false { symbol = "network" }
            else if v?.volumeIsInternal == false || ejectable { symbol = "externaldrive" }
            else { symbol = "internaldrive" }
            return Volume(url: url, name: v?.volumeName ?? url.lastPathComponent, ejectable: ejectable, symbol: symbol)
        }
    }

    func eject(_ v: Volume) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url) } catch {
            FileOperationCenter.shared.toast("Couldn’t eject “\(v.name)”: \(error.localizedDescription)")
        }
    }
}
