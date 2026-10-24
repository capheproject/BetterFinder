import AppKit
import ImageIO
import Quartz
import SwiftUI

struct InspectorView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let tab = ws.activeTab
        let items = tab.selectedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if items.count == 1 {
                    SingleInspector(item: items[0], git: tab.git?.status(for: items[0].url))
                        .id(items[0].url)
                } else if items.count > 1 {
                    MultiInspector(items: items)
                } else if let folder = FileItem(url: tab.url) {
                    SingleInspector(item: folder, git: nil, isCurrentFolder: true)
                        .id(folder.url)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        // Images and documents render either way; this only keeps audio and video from playing
        // by themselves when the inspector opens on them.
        v.autostarts = false
        v.shouldCloseWithWindow = false
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

/// A collapsible inspector section. Its open/closed state is remembered per `id` across launches.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @AppStorage private var expanded: Bool

    init(title: String, id: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _expanded = AppStorage(wrappedValue: true, "inspector.expanded.\(id ?? title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse \(title)" : "Expand \(title)")
            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.head)
                .help(value)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }
}

struct SingleInspector: View {
    @Environment(Workspace.self) private var ws
    let item: FileItem
    let git: GitFileStatus?
    var isCurrentFolder = false
    @State private var folderSize: (Int64, Int)?
    @State private var sizing = false
    @State private var dimensions: String?
    @State private var archive: [String]?
    @State private var permissions: (owner: String, group: String, mode: Int)?

    var body: some View {
        let accent = AppSettings.shared.accent
        Group {
            Group {
                if item.isFolder || item.isApp {
                    Image(nsImage: IconCache.icon(for: item.url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                } else {
                    QuickLookPreview(url: item.url)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                }
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !isCurrentFolder {
                    Button("Open") { ws.open([item.url]) }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                }
                Button("Copy Path") { ws.copyPath([item.url]) }
                if item.isFolder {
                    Button { ws.openInTerminal(item.url) } label: { Image(systemName: "terminal") }
                        .help("Open in Terminal")
                }
            }
            .controlSize(.small)

            InspectorSection(title: "Information") {
                InfoRow(label: "Kind", value: item.kind)
                if item.isDirectory && folderSize == nil && !sizing {
                    HStack {
                        Text("Size").foregroundStyle(.secondary)
                        Spacer()
                        Button("Calculate") { Task { await computeFolderSize() } }.controlSize(.mini)
                    }
                    .font(.system(size: 11))
                } else {
                    InfoRow(label: "Size", value: sizeText)
                }
                if let dimensions { InfoRow(label: "Dimensions", value: dimensions) }
                InfoRow(label: "Created", value: Fmt.date(item.created))
                InfoRow(label: "Modified", value: Fmt.date(item.modified))
                InfoRow(label: "Where", value: (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, mono: true)
                if let git {
                    HStack {
                        Text("Git").foregroundStyle(.secondary)
                        Spacer()
                        CellBadges(tags: [], git: git, symlink: false)
                        Text(git.rawValue.capitalized)
                    }
                    .font(.system(size: 11))
                }
            }

            InspectorSection(title: "Tags") {
                HStack(spacing: 7) {
                    ForEach(FinderTag.standard) { tag in
                        let on = item.tags.contains(tag.name)
                        Button {
                            ws.ops.toggleTag(tag.name, on: [item.url])
                            ws.refreshAll()
                        } label: {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 16, height: 16)
                                .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).opacity(on ? 1 : 0))
                                .overlay(Circle().stroke(Color.primary.opacity(on ? 0.5 : 0), lineWidth: 1.5).padding(-2.5))
                        }
                        .buttonStyle(.plain)
                        .help(tag.name)
                    }
                }
            }

            if let permissions {
                InspectorSection(title: "Permissions") {
                    PermissionGrid(mode: permissions.mode)
                    InfoRow(label: "Owner", value: permissions.owner)
                    InfoRow(label: "Group", value: permissions.group)
                    InfoRow(label: "Octal", value: String(format: "%o", permissions.mode & 0o777), mono: true)
                }
            }

            if let archive {
                InspectorSection(title: "Archive Contents (\(archive.count))", id: "Archive Contents") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(archive.prefix(200), id: \.self) { entry in
                            HStack(spacing: 5) {
                                Image(systemName: entry.hasSuffix("/") ? "folder" : "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(entry).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    Button("Extract Here") { ws.ops.extract(item.url) }.controlSize(.small)
                }
            }
        }
        .task(id: item.url) { await loadDetails() }
    }

    private var subtitle: String {
        isCurrentFolder ? "Current folder" : "\(item.kind) · \(sizeText)"
    }

    private var sizeText: String {
        if item.isDirectory {
            guard let (bytes, count) = folderSize else { return "Calculating…" }
            return "\(Fmt.size(bytes)) · \(count) items"
        }
        return Fmt.size(item.size) + " (\(item.size.formatted()) bytes)"
    }

    private func loadDetails() async {
        let url = item.url
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            permissions = (attrs[.ownerAccountName] as? String ?? "—",
                           attrs[.groupOwnerAccountName] as? String ?? "—",
                           (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)
        }
        if item.isImage {
            dimensions = await Task.detached { () -> String? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return "\(w) × \(h)"
            }.value
        }
        if item.isArchive {
            archive = await Task.detached { FileOperationCenter.archiveListing(url) }.value
        }
        if item.isDirectory && !isCurrentFolder {
            await computeFolderSize()
        }
    }

    private func computeFolderSize() async {
        let url = item.url
        sizing = true
        defer { sizing = false }
        do {
            let token = CancelToken()
            folderSize = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { FileSystem.folderSize(url, cancelled: { token.isCancelled }) }.value
            } onCancel: {
                token.cancel()
            }
        }
    }
}

struct PermissionGrid: View {
    let mode: Int

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("")
                ForEach(["Read", "Write", "Exec"], id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
            ForEach(Array(["Owner", "Group", "Others"].enumerated()), id: \.offset) { i, who in
                GridRow {
                    Text(who).foregroundStyle(.secondary)
                    ForEach(0..<3, id: \.self) { bit in
                        let on = mode & (1 << (8 - (i * 3 + bit))) != 0
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? AppSettings.shared.accent : Color.secondary.opacity(0.5))
                    }
                }
            }
        }
        .font(.system(size: 11))
    }
}

struct MultiInspector: View {
    @Environment(Workspace.self) private var ws
    let items: [FileItem]

    var body: some View {
        let bytes = items.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let folders = items.filter(\.isFolder).count
        ZStack {
            ForEach(Array(items.prefix(5).enumerated().reversed()), id: \.offset) { i, item in
                Image(nsImage: IconCache.icon(for: item.url))
                    .resizable()
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(Double(i) * 7 - 14))
                    .offset(x: CGFloat(i) * 10 - 20)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)

        Text("\(items.count) items")
            .font(.system(size: 17, weight: .semibold))
        Text([folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil,
              items.count - folders > 0 ? "\(items.count - folders) file\(items.count - folders == 1 ? "" : "s")" : nil,
              bytes > 0 ? Fmt.size(bytes) : nil].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

        HStack {
            Button("Rename…") { ws.batchRename = BatchRenameRequest(urls: items.map(\.url)) }
            Button("Compress") { ws.ops.compress(items.map(\.url)) }
        }
        .controlSize(.small)
    }
}
