import CoreServices
import Foundation

/// An in-memory index of every folder in the home folder, cloud drives and iCloud Drive, so
/// Quick Open can match folder names on every keystroke without waiting for Spotlight.
///
/// Loaded from a disk cache at launch, rebuilt in the background, and kept current with
/// FSEvents while the app runs. All mutation happens on `queue`; searches read an immutable
/// snapshot, so they never block.
final class FolderIndex: @unchecked Sendable {
    static let shared = FolderIndex()

    struct Match {
        let path: String
        let score: Int
    }

    private struct Snapshot {
        var paths: [String] = []
        var names: [String] = []   // lowercased last path components, parallel to `paths`
    }

    private let queue = DispatchQueue(label: "app.betterfinder.folder-index", qos: .utility)
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var all = Set<String>()                 // queue-only
    private var children: [String: Set<String>] = [:] // queue-only: parent → child folders
    private var stream: FSEventStreamRef?
    private var publishWork: DispatchWorkItem?
    private var started = false

    private let home = FileSystem.home.standardizedFileURL.path
    /// Home plus the cloud drives the person has already opened. Set in `start()`.
    private var roots: [String] = []
    /// App-managed media libraries: privacy-protected, and not folders anyone navigates to.
    private lazy var excluded: [String] = [home + "/Music/Music", home + "/Movies/TV"]

    /// Cloud drives (File Provider storage, iCloud Drive) can raise a privacy prompt on first
    /// access, so only index the ones already visited or pinned in BetterFinder.
    private static func cloudRoots(home: String, known: [String]) -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []
        let storage = home + "/Library/CloudStorage"
        if let names = try? fm.contentsOfDirectory(atPath: storage) {
            candidates += names.filter { !$0.hasPrefix(".") }.map { storage + "/" + $0 }
        }
        candidates.append(home + "/Library/Mobile Documents/com~apple~CloudDocs")
        return candidates.filter { root in known.contains { $0 == root || $0.hasPrefix(root + "/") } }
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.betterfinder.BetterFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("folder-index.txt")
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return snapshot.paths.count }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let settings = AppSettings.shared
        let known = settings.favorites.map(\.path) + settings.recentFolders
        roots = [home] + Self.cloudRoots(home: home, known: known)
        queue.async {
            self.loadCache()
            self.startWatching()
        }
        // Rebuild after launch settles, at low priority, to pick up changes made while closed.
        queue.asyncAfter(deadline: .now() + 3) { self.fullScan() }
    }

    private func loadCache() {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return }
        let paths = text.split(separator: "\n").map(String.init).filter(isIndexable)
        replaceAll(with: paths)
    }

    private func saveCache() {
        let text = snapshotPaths().joined(separator: "\n")
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    // MARK: Scanning

    /// Whether a folder belongs in the index: not hidden, not a package, not inside ~/Library
    /// (except the cloud roots), not node_modules.
    private func isIndexable(_ path: String) -> Bool {
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        if path.hasPrefix(home + "/Library"), !roots.dropFirst().contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return false
        }
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let comps = path.dropFirst(home.count).split(separator: "/")
        return !comps.contains { $0.hasPrefix(".") || $0 == "node_modules" }
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

    private func childFolders(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(Self.keys))
            guard v?.isDirectory == true, v?.isSymbolicLink != true, v?.isPackage != true else { return nil }
            let p = u.standardizedFileURL.path
            return isIndexable(p) ? p : nil
        }
    }

    private func fullScan() {
        var found: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: Self.keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                         errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: Set(Self.keys))
                guard v?.isDirectory == true, v?.isSymbolicLink != true, v?.isPackage != true else { continue }
                let p = u.standardizedFileURL.path
                guard isIndexable(p) else {
                    e.skipDescendants()
                    continue
                }
                found.append(p)
            }
        }
        replaceAll(with: found)
        saveCache()
    }

    private func replaceAll(with paths: [String]) {
        all = Set(paths)
        children = [:]
        for p in all { children[(p as NSString).deletingLastPathComponent, default: []].insert(p) }
        publish(now: true)
    }

    /// Re-reads one folder's immediate subfolders; with `deep`, its whole subtree.
    private func refresh(_ path: String, deep: Bool) {
        if !FileManager.default.fileExists(atPath: path) {
            remove(path)
            return
        }
        if path != home && !roots.contains(path) && isIndexable(path) && !all.contains(path) {
            add(path)
        }
        let current = Set(childFolders(of: path))
        let known = children[path] ?? []
        for gone in known.subtracting(current) { remove(gone) }
        for new in current.subtracting(known) { add(new) }
        if deep { for child in current { refresh(child, deep: true) } }
    }

    private func add(_ path: String) {
        guard all.insert(path).inserted else { return }
        children[(path as NSString).deletingLastPathComponent, default: []].insert(path)
    }

    private func remove(_ path: String) {
        let prefix = path + "/"
        let doomed = all.filter { $0 == path || $0.hasPrefix(prefix) }
        guard !doomed.isEmpty else { return }
        all.subtract(doomed)
        for d in doomed { children[d] = nil }
        children[(path as NSString).deletingLastPathComponent]?.remove(path)
    }

    private func publish(now: Bool = false) {
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.all)
            let names = paths.map { ($0 as NSString).lastPathComponent.lowercased() }
            self.lock.lock()
            self.snapshot = Snapshot(paths: paths, names: names)
            self.lock.unlock()
        }
        publishWork = work
        if now { work.perform() } else { queue.asyncAfter(deadline: .now() + 0.5, execute: work) }
    }

    private func snapshotPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.paths
    }

    // MARK: FSEvents

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let index = Unmanaged<FolderIndex>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [(String, Bool)] = []
            for i in 0..<count {
                let f = flags[i]
                let deep = f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                events.append((list[i], deep))
            }
            index.handle(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func handle(_ events: [(String, Bool)]) {
        var changed = false
        for (raw, deep) in events {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard isIndexable(path) || roots.contains(path) else { continue }
            refresh(path, deep: deep)
            changed = true
        }
        if changed {
            publish()
            scheduleCacheSave()
        }
    }

    private var saveWork: DispatchWorkItem?
    private func scheduleCacheSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCache() }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: Search

    /// Folders whose name matches every word of `query`. Prefix and word-start matches rank
    /// above substring matches; recently visited and shallower folders rank higher.
    func search(_ query: String, limit: Int = 30, recent: [String] = []) -> [Match] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        lock.lock()
        let snap = snapshot
        lock.unlock()
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var matches: [Match] = []
        let separators = CharacterSet(charactersIn: " -_.()[]")
        for i in snap.names.indices {
            let name = snap.names[i]
            var score = 0
            var ok = true
            for w in words {
                guard let r = name.range(of: w) else { ok = false; break }
                if r.lowerBound == name.startIndex {
                    score += name.count == w.count ? 120 : 80
                } else if let prev = name[..<r.lowerBound].unicodeScalars.last, separators.contains(prev) {
                    score += 50
                } else {
                    score += 20
                }
            }
            guard ok else { continue }
            let path = snap.paths[i]
            if let rank = recentRank[path] { score += 60 - min(rank, 30) }
            score -= path.split(separator: "/").count * 2
            matches.append(Match(path: path, score: score))
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
        return Array(matches.prefix(limit))
    }
}
