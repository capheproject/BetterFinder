import AppKit
import ImageIO
import UniformTypeIdentifiers

@Observable
final class Activity: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var total: Int
    var completed = 0
    var currentItem = ""
    var finished = false
    var error: String?

    init(title: String, symbol: String, total: Int) {
        self.title = title
        self.symbol = symbol
        self.total = total
    }

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// A recorded operation ("Footprint"). Every operation that can be reverted carries an `undo`.
struct Footprint: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let symbol: String
    let undo: (() throws -> Void)?
    var undone = false
}

@Observable
final class FileOperationCenter {
    static let shared = FileOperationCenter()

    var activities: [Activity] = []
    var footprints: [Footprint] = []
    var toastMessage: String?
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    var isBusy: Bool { activities.contains { !$0.finished } }
    private var fm: FileManager { .default }

    // MARK: Feedback

    func toast(_ message: String) {
        toastMessage = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toastMessage = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func record(_ title: String, _ symbol: String, undo: (() throws -> Void)?) {
        footprints.insert(Footprint(title: title, symbol: symbol, undo: undo), at: 0)
        if footprints.count > 300 { footprints.removeLast(footprints.count - 300) }
    }

    func undoLast() {
        guard let idx = footprints.firstIndex(where: { !$0.undone && $0.undo != nil }) else {
            NSSound.beep()
            return
        }
        undo(footprints[idx].id)
    }

    func undo(_ id: UUID) {
        guard let idx = footprints.firstIndex(where: { $0.id == id }), let undo = footprints[idx].undo, !footprints[idx].undone else { return }
        do {
            try undo()
            footprints[idx].undone = true
            toast("Undid “\(footprints[idx].title)”")
        } catch {
            toast("Couldn’t undo: \(error.localizedDescription)")
        }
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    private func startActivity(_ title: String, _ symbol: String, total: Int) -> Activity {
        let a = Activity(title: title, symbol: symbol, total: total)
        activities.insert(a, at: 0)
        return a
    }

    private func finish(_ a: Activity, error: String?) {
        a.finished = true
        a.error = error
        if let error { toast(error) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, a.error == nil else { return }
            self.activities.removeAll { $0.id == a.id }
        }
    }

    // MARK: Copy / move

    enum ConflictPolicy { case replace, keepBoth, skip }

    private func askConflictPolicy(_ conflicts: [URL], dir: URL) -> ConflictPolicy? {
        guard !conflicts.isEmpty else { return .keepBoth }
        let alert = NSAlert()
        alert.messageText = conflicts.count == 1
            ? "An item named “\(conflicts[0].lastPathComponent)” already exists in “\(dir.lastPathComponent)”."
            : "\(conflicts.count) items already exist in “\(dir.lastPathComponent)”."
        alert.informativeText = "Replaced items are moved to the Trash, so you can always get them back."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    func transfer(_ urls: [URL], to dir: URL, move: Bool) {
        let dir = dir.standardizedFileURL
        var sources: [URL] = []
        for src in urls.map(\.standardizedFileURL) {
            if dir.path == src.path || dir.path.hasPrefix(src.path + "/") {
                toast("Can’t \(move ? "move" : "copy") “\(src.lastPathComponent)” into itself.")
                continue
            }
            if move && src.deletingLastPathComponent().path == dir.path { continue }
            sources.append(src)
        }
        guard !sources.isEmpty else { return }
        let conflicts = sources.filter {
            let dst = dir.appendingPathComponent($0.lastPathComponent)
            return dst.path != $0.path && FileSystem.exists(dst)
        }
        guard let policy = askConflictPolicy(conflicts, dir: dir) else { return }

        let verb = move ? "Moving" : "Copying"
        let activity = startActivity("\(verb) \(Self.describe(sources)) to “\(dir.lastPathComponent)”", move ? "arrow.right.doc.on.clipboard" : "doc.on.doc", total: sources.count)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var done: [(src: URL, dst: URL)] = []
            var errorMessage: String?
            for src in sources {
                await MainActor.run { activity.currentItem = src.lastPathComponent }
                var dst = dir.appendingPathComponent(src.lastPathComponent)
                if FileSystem.exists(dst) {
                    if dst.path == src.path {
                        dst = FileSystem.uniqueURL(for: dst, copySuffix: true)
                    } else {
                        switch policy {
                        case .skip:
                            await MainActor.run { activity.completed += 1 }
                            continue
                        case .keepBoth: dst = FileSystem.uniqueURL(for: dst)
                        case .replace: try? fm.trashItem(at: dst, resultingItemURL: nil)
                        }
                    }
                }
                do {
                    if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
                    done.append((src, dst))
                } catch {
                    errorMessage = error.localizedDescription
                }
                await MainActor.run { activity.completed += 1 }
            }
            let finished = done
            let failure = errorMessage
            await MainActor.run {
                self.finish(activity, error: failure)
                guard !finished.isEmpty else { return }
                let what = Self.describe(finished.map(\.src))
                if move {
                    self.record("Moved \(what) to “\(dir.lastPathComponent)”", "arrow.right", undo: {
                        for p in finished.reversed() { try FileManager.default.moveItem(at: p.dst, to: p.src) }
                    })
                } else {
                    self.record("Copied \(what) to “\(dir.lastPathComponent)”", "doc.on.doc", undo: {
                        for p in finished { try FileManager.default.trashItem(at: p.dst, resultingItemURL: nil) }
                    })
                }
            }
        }
    }

    // MARK: Trash / delete

    func trash(_ urls: [URL]) {
        var moved: [(URL, URL)] = []
        var failure: String?
        for u in urls {
            var res: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &res)
                if let r = res as URL? { moved.append((u, r)) }
            } catch { failure = error.localizedDescription }
        }
        if let failure { toast(failure) }
        guard !moved.isEmpty else { return }
        NSSound(named: "Pop")?.play()
        record("Moved \(Self.describe(moved.map(\.0))) to Trash", "trash", undo: {
            for (original, trashed) in moved { try FileManager.default.moveItem(at: trashed, to: original) }
        })
    }

    func deleteImmediately(_ urls: [URL]) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(Self.describe(urls)) immediately?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for u in urls {
            do { try fm.removeItem(at: u) } catch { toast(error.localizedDescription) }
        }
        record("Deleted \(Self.describe(urls))", "xmark.bin", undo: nil)
    }

    // MARK: Rename

    @discardableResult
    func rename(_ url: URL, to newName: String) -> URL? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return nil }
        guard !name.contains("/") else {
            toast("Names can’t contain “/”.")
            return nil
        }
        let dst = url.deletingLastPathComponent().appendingPathComponent(name)
        let caseOnly = dst.path.lowercased() == url.path.lowercased()
        if !caseOnly && FileSystem.exists(dst) {
            toast("“\(name)” already exists.")
            return nil
        }
        do {
            try fm.moveItem(at: url, to: dst)
            record("Renamed “\(url.lastPathComponent)” to “\(name)”", "pencil", undo: {
                try FileManager.default.moveItem(at: dst, to: url)
            })
            return dst
        } catch {
            toast(error.localizedDescription)
            return nil
        }
    }

    /// Renames in two phases so names can be swapped or shifted without collisions.
    func batchRename(_ pairs: [(URL, String)]) {
        let changes = pairs.filter { $0.0.lastPathComponent != $0.1 && !$0.1.isEmpty }
        guard !changes.isEmpty else { return }
        var temps: [(original: URL, temp: URL, final: URL)] = []
        var renamed: [(URL, URL)] = []
        do {
            for (url, name) in changes {
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".bf-rename-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: tmp)
                temps.append((url, tmp, url.deletingLastPathComponent().appendingPathComponent(name)))
            }
            for t in temps {
                let final = FileSystem.exists(t.final) ? FileSystem.uniqueURL(for: t.final) : t.final
                try fm.moveItem(at: t.temp, to: final)
                renamed.append((t.original, final))
            }
            let done = renamed
            record("Renamed \(done.count) items", "character.cursor.ibeam", undo: {
                for (original, final) in done { try FileManager.default.moveItem(at: final, to: original) }
            })
        } catch {
            // Put everything back: finished renames and items still parked under temp names.
            for (original, final) in renamed { try? fm.moveItem(at: final, to: original) }
            for t in temps where FileSystem.exists(t.temp) { try? fm.moveItem(at: t.temp, to: t.original) }
            toast(error.localizedDescription)
        }
    }

    // MARK: Create

    @discardableResult
    func newFolder(in dir: URL, name: String = "untitled folder") -> URL? {
        let url = FileSystem.uniqueURL(for: dir.appendingPathComponent(name))
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            record("Created folder “\(url.lastPathComponent)”", "folder.badge.plus", undo: {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            })
            return url
        } catch {
            toast(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func newFile(in dir: URL, name: String, contents: Data, executable: Bool = false) -> URL? {
        let url = FileSystem.uniqueURL(for: dir.appendingPathComponent(name))
        guard fm.createFile(atPath: url.path, contents: contents, attributes: executable ? [.posixPermissions: 0o755] : nil) else {
            toast("Couldn’t create “\(name)”.")
            return nil
        }
        record("Created “\(url.lastPathComponent)”", "doc.badge.plus", undo: {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        })
        return url
    }

    func duplicate(_ urls: [URL]) -> [URL] {
        var created: [URL] = []
        for u in urls {
            let dst = FileSystem.uniqueURL(for: u, copySuffix: true)
            do {
                try fm.copyItem(at: u, to: dst)
                created.append(dst)
            } catch { toast(error.localizedDescription) }
        }
        if !created.isEmpty {
            record("Duplicated \(Self.describe(urls))", "plus.square.on.square", undo: {
                for c in created { try FileManager.default.trashItem(at: c, resultingItemURL: nil) }
            })
        }
        return created
    }

    // MARK: Archives

    func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        // zip stores paths relative to one folder; search results can span several.
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL }) else {
            toast("Select items from a single folder to compress them together.")
            return
        }
        let name = urls.count == 1 ? "\(first.lastPathComponent).zip" : "Archive.zip"
        let dst = FileSystem.uniqueURL(for: dir.appendingPathComponent(name))
        let activity = startActivity("Compressing \(Self.describe(urls))", "archivebox", total: 1)
        Task.detached(priority: .userInitiated) {
            let r: (status: Int32, out: Data, err: String)
            if urls.count == 1 {
                r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dst.path])
            } else {
                r = Shell.run("/usr/bin/zip", ["-r", "-y", "-q", dst.path] + urls.map(\.lastPathComponent), cwd: dir)
            }
            await MainActor.run {
                activity.completed = 1
                self.finish(activity, error: r.status == 0 ? nil : "Compression failed. \(r.err)")
                if r.status == 0 {
                    self.record("Compressed \(Self.describe(urls))", "archivebox", undo: {
                        try FileManager.default.trashItem(at: dst, resultingItemURL: nil)
                    })
                }
            }
        }
    }

    func extract(_ url: URL) {
        var base = url.deletingPathExtension()
        if base.pathExtension == "tar" { base = base.deletingPathExtension() }
        let dst = FileSystem.uniqueURL(for: base)
        let activity = startActivity("Extracting “\(url.lastPathComponent)”", "archivebox", total: 1)
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            let r = Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dst.path])
            await MainActor.run {
                activity.completed = 1
                self.finish(activity, error: r.status == 0 ? nil : "Couldn’t extract “\(url.lastPathComponent)”. \(r.err)")
                if r.status == 0 {
                    self.record("Extracted “\(url.lastPathComponent)”", "archivebox", undo: {
                        try FileManager.default.trashItem(at: dst, resultingItemURL: nil)
                    })
                } else {
                    try? FileManager.default.removeItem(at: dst)
                }
            }
        }
    }

    static func archiveListing(_ url: URL) -> [String] {
        let r = Shell.run("/usr/bin/tar", ["-tf", url.path])
        guard r.status == 0 else { return [] }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\n").prefix(1000).map(String.init)
    }

    // MARK: Tags

    func toggleTag(_ tag: String, on urls: [URL]) {
        let before = urls.map { ($0, FileSystem.tags(of: $0)) }
        let allHave = before.allSatisfy { $0.1.contains(tag) }
        for (u, tags) in before {
            var t = tags
            if allHave { t.removeAll { $0 == tag } } else if !t.contains(tag) { t.append(tag) }
            FileSystem.setTags(t, on: u)
        }
        record("\(allHave ? "Removed" : "Added") tag \(tag)", "tag", undo: {
            for (u, tags) in before { FileSystem.setTags(tags, on: u) }
        })
    }

    func clearTags(_ urls: [URL]) {
        let before = urls.map { ($0, FileSystem.tags(of: $0)) }
        for u in urls { FileSystem.setTags([], on: u) }
        record("Removed tags", "tag.slash", undo: {
            for (u, tags) in before { FileSystem.setTags(tags, on: u) }
        })
    }

    // MARK: Images

    func rotate(_ urls: [URL], clockwise: Bool) {
        var backups: [(URL, URL)] = []
        for u in urls {
            // Bake in the EXIF orientation first (phone photos store "rotate 90°" as a tag), then
            // rotate the upright pixels and write orientation 1 so viewers don't rotate them again.
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let type = CGImageSourceGetType(src),
                  let img = Self.uprightImage(src),
                  let rotated = Self.rotated(img, clockwise: clockwise) else { continue }
            var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            props[kCGImagePropertyOrientation] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            props[kCGImagePropertyPixelWidth] = nil
            props[kCGImagePropertyPixelHeight] = nil
            let backup = fm.temporaryDirectory.appendingPathComponent("bf-\(UUID().uuidString)-\(u.lastPathComponent)")
            guard (try? fm.copyItem(at: u, to: backup)) != nil,
                  let dst = CGImageDestinationCreateWithURL(u as CFURL, type, 1, nil) else { continue }
            CGImageDestinationAddImage(dst, rotated, props as CFDictionary)
            if CGImageDestinationFinalize(dst) { backups.append((u, backup)) }
        }
        guard !backups.isEmpty else { return }
        urls.forEach(IconCache.invalidate)
        record("Rotated \(Self.describe(backups.map(\.0)))", clockwise ? "rotate.right" : "rotate.left", undo: {
            for (u, b) in backups { _ = try FileManager.default.replaceItemAt(u, withItemAt: b) }
        })
    }

    func convert(_ urls: [URL], to type: UTType) {
        var created: [URL] = []
        let ext = type.preferredFilenameExtension ?? "png"
        for u in urls {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let dstURL = FileSystem.uniqueURL(for: u.deletingPathExtension().appendingPathExtension(ext))
            guard let dst = CGImageDestinationCreateWithURL(dstURL as CFURL, type.identifier as CFString, 1, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            CGImageDestinationAddImage(dst, img, props)
            if CGImageDestinationFinalize(dst) { created.append(dstURL) }
        }
        guard !created.isEmpty else {
            toast("Couldn’t convert the selected images.")
            return
        }
        record("Converted \(Self.describe(urls)) to \(ext.uppercased())", "photo", undo: {
            for c in created { try FileManager.default.trashItem(at: c, resultingItemURL: nil) }
        })
    }

    /// The full-size image with its EXIF orientation applied.
    static func uprightImage(_ src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func rotated(_ img: CGImage, clockwise: Bool) -> CGImage? {
        let w = img.width, h = img.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Pasted content

    @discardableResult
    func savePasted(image: NSImage, in dir: URL) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return newFile(in: dir, name: "Pasted Image \(Fmt.stampFormatter.string(from: Date())).png", contents: png)
    }
}
