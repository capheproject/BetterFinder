import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

enum DropLoader {
    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    /// Handles a drop of files (copy/move) or raw images (saved as PNG) into `dir`.
    static func handle(_ providers: [NSItemProvider], into dir: URL, workspace: Workspace) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            loadURLs(providers) { urls in workspace.drop(urls, into: dir) }
            return true
        }
        if let p = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let image = obj as? NSImage else { return }
                DispatchQueue.main.async { workspace.ops.savePasted(image: image, in: dir) }
            }
            return true
        }
        return false
    }
}

struct InlineRenameField: NSViewRepresentable {
    let initial: String
    let isDirectory: Bool
    var alignment: NSTextAlignment = .left
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: initial)
        f.font = .systemFont(ofSize: 12)
        f.alignment = alignment
        f.focusRingType = .none
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            if let editor = f.currentEditor() {
                let base = isDirectory ? initial : (initial as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
        return f
    }

    func updateNSView(_ nsView: NSTextField, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var done = false
        init(_ parent: InlineRenameField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                done = true
                parent.onCancel()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                done = true
                parent.onCommit((control as? NSTextField)?.stringValue ?? "")
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !done else { return }
            done = true
            parent.onCommit((obj.object as? NSTextField)?.stringValue ?? "")
        }
    }
}

struct ThumbnailView: View {
    let item: FileItem
    let size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            } else {
                Image(nsImage: IconCache.icon(for: item.url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(item.url.path)#\(Int(size))#\(item.modified.timeIntervalSince1970)") {
            guard !item.isDirectory || item.isPackage, !item.isApp else { thumbnail = nil; return }
            thumbnail = await Thumbnails.thumbnail(for: item.url, size: size)
        }
    }
}

extension Workspace {
    /// Click handling for custom (non-table) views, with ⌘ / ⇧ modifiers and double-click.
    func click(_ item: FileItem, in tab: BrowserTab, pane: Int) {
        activate(pane)
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            open([item.url])
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.command) {
            if tab.selection.contains(item.url) { tab.selection.remove(item.url) } else { tab.selection.insert(item.url) }
        } else if flags.contains(.shift), let anchor = tab.anchor,
                  let a = tab.displayed.firstIndex(where: { $0.url == anchor }),
                  let b = tab.displayed.firstIndex(where: { $0.url == item.url }) {
            tab.selection = Set(tab.displayed[min(a, b)...max(a, b)].map(\.url))
            return
        } else {
            tab.selection = [item.url]
        }
        tab.anchor = item.url
    }

    func contextEntries(for item: FileItem, in tab: BrowserTab) -> [MenuEntry] {
        let urls = tab.selection.contains(item.url) ? tab.selectedURLs : [item.url]
        return menuEntries(for: urls, in: tab)
    }
}

// MARK: - Icon grid

struct FileGridView: View {
    @Environment(Workspace.self) private var ws
    let tab: BrowserTab
    let paneIndex: Int
    @FocusState private var focused: Bool

    var body: some View {
        let size = CGFloat(tab.iconSize)
        let cellWidth = size + 40
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 24), spacing: 10, alignment: .top)], spacing: 16) {
                        ForEach(tab.displayed) { item in
                            GridCell(item: item, tab: tab, paneIndex: paneIndex, size: size,
                                     selected: tab.selection.contains(item.url),
                                     renaming: tab.renamingURL == item.url,
                                     git: tab.git?.status(for: item.url))
                                .id(item.url)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onChange(of: tab.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
                    tab.scrollTarget = nil
                }
            }
            .onAppear { updateColumns(geo.size.width, cellWidth) }
            .onChange(of: geo.size.width) { _, w in updateColumns(w, cellWidth) }
            .onChange(of: tab.iconSize) { _, _ in updateColumns(geo.size.width, cellWidth) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            ws.activate(paneIndex)
            tab.selection = []
        }
        .contextMenu { MenuEntriesView(entries: ws.menuEntries(for: [], in: tab)) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: tab.focusRequest) { _, _ in focused = true }
    }

    private func updateColumns(_ width: CGFloat, _ cell: CGFloat) {
        tab.gridColumns = max(1, Int((width - 32 + 10) / (cell + 10)))
    }
}

struct GridCell: View {
    @Environment(Workspace.self) private var ws
    let item: FileItem
    let tab: BrowserTab
    let paneIndex: Int
    let size: CGFloat
    let selected: Bool
    let renaming: Bool
    let git: GitFileStatus?
    @State private var targeted = false

    var body: some View {
        let accent = AppSettings.shared.accent
        VStack(spacing: 5) {
            ThumbnailView(item: item, size: size)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected || targeted ? Color.primary.opacity(0.10) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(targeted ? accent : .clear, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    CellBadges(tags: item.tags, git: git, symlink: item.isSymlink).offset(x: 2, y: 2)
                }
            if renaming {
                InlineRenameField(initial: item.name, isDirectory: item.isDirectory, alignment: .center,
                                  onCommit: { ws.commitRename(in: tab, url: item.url, newName: $0) },
                                  onCancel: { ws.cancelRename(in: tab) })
                    .frame(width: size + 36)
            } else {
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? accent : .clear))
            }
        }
        .frame(width: size + 40)
        .opacity(item.isHidden ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { ws.click(item, in: tab, pane: paneIndex) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .modifier(FolderDropModifier(item: item, targeted: $targeted))
        .contextMenu { MenuEntriesView(entries: ws.contextEntries(for: item, in: tab)) }
    }
}

struct FolderDropModifier: ViewModifier {
    @Environment(Workspace.self) private var ws
    let item: FileItem
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                DropLoader.handle(providers, into: item.url, workspace: ws)
            }
        } else {
            content
        }
    }
}

// MARK: - Columns (Miller columns)

struct ColumnsBrowserView: View {
    @Environment(Workspace.self) private var ws
    let tab: BrowserTab
    let paneIndex: Int
    @FocusState private var focused: Bool

    private var chain: [URL] {
        if tab.isSearch { return [tab.url] }
        let home = FileSystem.home.standardizedFileURL
        let root = tab.url.path.hasPrefix(home.path) ? home : URL(fileURLWithPath: "/")
        var urls: [URL] = []
        var u = tab.url
        while true {
            urls.insert(u, at: 0)
            if u.path == root.path || u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        return urls
    }

    var body: some View {
        let chain = self.chain
        let selected = tab.selectedItems
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(chain.enumerated()), id: \.element) { i, dir in
                        let isLast = i == chain.count - 1
                        Group {
                            if isLast {
                                ColumnList(dir: dir, items: tab.displayed, highlighted: tab.selection, emphasized: true, tab: tab, paneIndex: paneIndex)
                            } else {
                                AncestorColumn(dir: dir, next: chain[i + 1], tab: tab, paneIndex: paneIndex)
                            }
                        }
                        .frame(width: 230)
                        .id(dir)
                        Divider()
                    }
                    if selected.count == 1, !selected[0].isFolder {
                        ColumnPreview(item: selected[0])
                            .frame(width: 280)
                            .id("preview")
                    }
                }
            }
            .onChange(of: tab.url) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(chain.last, anchor: .trailing) }
            }
            .onChange(of: selected.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("preview", anchor: .trailing) }
            }
            .onAppear { proxy.scrollTo(chain.last, anchor: .trailing) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: tab.focusRequest) { _, _ in focused = true }
    }
}

struct AncestorColumn: View {
    let dir: URL
    let next: URL
    let tab: BrowserTab
    let paneIndex: Int
    @State private var items: [FileItem] = []

    var body: some View {
        ColumnList(dir: dir, items: items, highlighted: [next], emphasized: false, tab: tab, paneIndex: paneIndex)
            .task(id: dir) {
                let list = (try? await Task.detached { try FileSystem.list(dir) }.value) ?? []
                let showHidden = AppSettings.shared.showHidden
                items = list.filter { showHidden || !$0.isHidden }
                    .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            }
    }
}

struct ColumnList: View {
    @Environment(Workspace.self) private var ws
    let dir: URL
    let items: [FileItem]
    let highlighted: Set<URL>
    let emphasized: Bool
    let tab: BrowserTab
    let paneIndex: Int
    @State private var targeted = false

    var body: some View {
        let accent = AppSettings.shared.accent
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        let isOn = highlighted.contains(item.url)
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.icon(for: item.url))
                                .resizable()
                                .frame(width: 16, height: 16)
                            if emphasized && tab.renamingURL == item.url {
                                InlineRenameField(initial: item.name, isDirectory: item.isDirectory,
                                                  onCommit: { ws.commitRename(in: tab, url: item.url, newName: $0) },
                                                  onCancel: { ws.cancelRename(in: tab) })
                            } else {
                                Text(item.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 2)
                            CellBadges(tags: item.tags, git: tab.git?.status(for: item.url), symlink: false)
                            if item.isFolder {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isOn && emphasized ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .foregroundStyle(isOn && emphasized ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isOn ? (emphasized ? accent : Color.primary.opacity(0.12)) : .clear))
                        .opacity(item.isHidden ? 0.55 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { tapped(item) }
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .contextMenu { MenuEntriesView(entries: ws.contextEntries(for: item, in: tab)) }
                        .id(item.url)
                    }
                }
                .padding(6)
            }
            .onChange(of: tab.scrollTarget) { _, t in
                guard emphasized, let t else { return }
                proxy.scrollTo(t)
                tab.scrollTarget = nil
            }
            .onAppear { if let h = highlighted.first { proxy.scrollTo(h, anchor: .center) } }
        }
        .background(targeted ? accent.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            ws.activate(paneIndex)
            if emphasized { tab.selection = [] } else { tab.navigate(to: dir) }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { DropLoader.handle($0, into: dir, workspace: ws) }
    }

    private func tapped(_ item: FileItem) {
        ws.activate(paneIndex)
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 && !item.isFolder {
            ws.open([item.url])
            return
        }
        if item.isFolder && !(event?.modifierFlags.contains(.command) ?? false) {
            tab.navigate(to: item.url)
            return
        }
        if emphasized {
            ws.click(item, in: tab, pane: paneIndex)
        } else {
            tab.navigate(to: dir, select: item.url)
        }
    }
}

struct ColumnPreview: View {
    let item: FileItem

    var body: some View {
        VStack(spacing: 12) {
            ThumbnailView(item: item, size: 160)
                .padding(.top, 24)
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("\(item.kind) · \(Fmt.size(item.size))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Modified \(Fmt.date(item.modified))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}
