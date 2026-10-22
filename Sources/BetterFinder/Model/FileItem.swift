import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    /// Logical size in bytes, -1 for folders.
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String
    let tags: [String]

    var id: URL { url }
    var isFolder: Bool { isDirectory && !isPackage }
    var isApp: Bool { isPackage && url.pathExtension == "app" }
    var ext: String { url.pathExtension.lowercased() }
    var contentType: UTType? { UTType(filenameExtension: ext) }
    var isImage: Bool { !isDirectory && (contentType?.conforms(to: .image) ?? false) }
    var isArchive: Bool { !isDirectory && Self.archiveExtensions.contains(ext) }

    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "jar", "cpio", "xar"]

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]
    static let keySet = Set(keys)

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Self.keySet) else { return nil }
        var isDir = v.isDirectory ?? false
        let isLink = v.isSymbolicLink ?? false
        if isLink {
            var flag: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) { isDir = flag.boolValue }
        }
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDir
        self.isPackage = v.isPackage ?? false
        self.isHidden = (v.isHidden ?? false) || url.lastPathComponent.hasPrefix(".")
        self.isSymlink = isLink
        self.size = isDir ? -1 : Int64(v.fileSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
        self.created = v.creationDate ?? .distantPast
        self.kind = v.localizedTypeDescription ?? (isDir ? "Folder" : "Document")
        self.tags = v.tagNames ?? []
    }
}

enum Fmt {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ s: Int64) -> String { s < 0 ? "--" : byteFormatter.string(fromByteCount: s) }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func date(_ d: Date) -> String { d == .distantPast ? "--" : dateFormatter.string(from: d) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jjmm")
        return f
    }()

    private static let thisYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd jjmm")
        return f
    }()

    private static let olderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    /// Compact list-column dates: "Today 11:48", "Yesterday 15:13", "Oct 5 11:48", "Oct 8, 2025".
    static func shortDate(_ d: Date) -> String {
        guard d != .distantPast else { return "--" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today \(timeFormatter.string(from: d))" }
        if cal.isDateInYesterday(d) { return "Yesterday \(timeFormatter.string(from: d))" }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return thisYearFormatter.string(from: d) }
        return olderFormatter.string(from: d)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}

enum FileSystem {
    static var fm: FileManager { .default }
    static var home: URL { fm.homeDirectoryForCurrentUser }

    static func list(_ dir: URL) throws -> [FileItem] {
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileItem.keys, options: [])
        return urls.compactMap(FileItem.init(url:))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    static func displayName(_ url: URL) -> String {
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        return fm.displayName(atPath: url.path)
    }

    static func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true || fm.fileExists(atPath: url.path)
    }

    /// Returns `desired` or a non-existing sibling: "name 2.ext" or "name copy.ext".
    static func uniqueURL(for desired: URL, copySuffix: Bool = false) -> URL {
        guard exists(desired) else { return desired }
        let dir = desired.deletingLastPathComponent()
        let isDir = isDirectory(desired)
        let ext = isDir ? "" : desired.pathExtension
        let base = ext.isEmpty ? desired.lastPathComponent : desired.deletingPathExtension().lastPathComponent
        var n = copySuffix ? 1 : 2
        while true {
            let candidate: String
            if copySuffix { candidate = n == 1 ? "\(base) copy" : "\(base) copy \(n)" } else { candidate = "\(base) \(n)" }
            let url = dir.appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)")
            if !exists(url) { return url }
            n += 1
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }

    static func freeSpace(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let c = v?.volumeAvailableCapacityForImportantUsage, c > 0 { return c }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    static func expandPath(_ s: String, relativeTo base: URL) -> URL {
        let t = s.trimmingCharacters(in: .whitespaces)
        let expanded = (t as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Recursive name search. Honors Task cancellation.
    static func search(in root: URL, query: String, includeHidden: Bool, limit: Int) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: FileItem.keys, options: options) else { return [] }
        var out: [FileItem] = []
        var visited = 0
        for case let url as URL in e {
            visited += 1
            if visited % 500 == 0 && Task.isCancelled { return out }
            if url.lastPathComponent.localizedCaseInsensitiveContains(query), let item = FileItem(url: url) {
                out.append(item)
                if out.count >= limit { break }
            }
        }
        return out
    }

    static func folderSize(_ url: URL, cancelled: () -> Bool) -> (bytes: Int64, count: Int) {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: []) else { return (0, 0) }
        var total: Int64 = 0
        var count = 0
        for case let u as URL in e {
            count += 1
            if count % 1000 == 0 && cancelled() { break }
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return (total, count)
    }

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func setTags(_ tags: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data, String(decoding: errData, as: UTF8.self))
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}
