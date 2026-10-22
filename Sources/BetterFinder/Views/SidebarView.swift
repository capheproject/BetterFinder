import AppKit
import SwiftUI

enum SidebarTarget: Hashable {
    case url(URL)
    case tag(String)
}

struct SidebarView: View {
    @Environment(Workspace.self) private var ws
    @State private var editingSymbolFor: Favorite?
    // Collapsed/expanded state of each section survives relaunches.
    @AppStorage("sidebar.expanded.favorites") private var favoritesExpanded = true
    @AppStorage("sidebar.expanded.locations") private var locationsExpanded = true
    @AppStorage("sidebar.expanded.recent") private var recentExpanded = true
    @AppStorage("sidebar.expanded.tags") private var tagsExpanded = true

    private var selection: Binding<SidebarTarget?> {
        Binding(
            get: {
                let tab = ws.activeTab
                if let title = tab.searchTitle, title.hasPrefix("Tag: ") { return .tag(String(title.dropFirst(5))) }
                return tab.isSearch ? nil : .url(tab.url)
            },
            set: { target in
                switch target {
                case .url(let url): ws.go(to: url)
                case .tag(let tag): ws.showTag(tag)
                case nil: break
                }
                ws.focusActivePane()
            })
    }

    var body: some View {
        let settings = AppSettings.shared
        List(selection: selection) {
            Section("Favorites", isExpanded: $favoritesExpanded) {
                ForEach(settings.favorites) { fav in
                    SidebarRow(title: fav.name, symbol: fav.resolvedSymbol, dropTarget: fav.url)
                        .tag(SidebarTarget.url(fav.url.standardizedFileURL))
                        .contextMenu {
                            Button("Open in New Tab") { ws.newTab(fav.url) }
                            Button("Open in Other Pane") { ws.openInOtherPane(fav.url) }
                            Button("Open in Terminal") { ws.openInTerminal(fav.url) }
                            Divider()
                            Button("Change Icon…") { editingSymbolFor = fav }
                            Button("Remove from Sidebar") { settings.favorites.removeAll { $0.id == fav.id } }
                        }
                }
                .onMove { settings.favorites.move(fromOffsets: $0, toOffset: $1) }
            }

            Section("Locations", isExpanded: $locationsExpanded) {
                ForEach(VolumeStore.shared.volumes) { v in
                    HStack {
                        SidebarRow(title: v.name, symbol: v.symbol, dropTarget: v.url)
                        Spacer()
                        if v.ejectable {
                            Button { VolumeStore.shared.eject(v) } label: {
                                Image(systemName: "eject.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help("Eject “\(v.name)”")
                        }
                    }
                    .tag(SidebarTarget.url(v.url.standardizedFileURL))
                }
            }

            Section("Recent", isExpanded: $recentExpanded) {
                ForEach(settings.recentFolders.prefix(5), id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    SidebarRow(title: FileSystem.displayName(url), symbol: "clock", dropTarget: url)
                        .tag(SidebarTarget.url(url.standardizedFileURL))
                }
            }

            Section("Tags", isExpanded: $tagsExpanded) {
                ForEach(FinderTag.standard) { tag in
                    Label {
                        Text(tag.name).font(.system(size: 13))
                    } icon: {
                        Circle().fill(tag.color).frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 3)
                    .tag(SidebarTarget.tag(tag.name))
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(FileSystem.isDirectory)
            folders.forEach(settings.addFavorite)
            return !folders.isEmpty
        }
        .popover(item: $editingSymbolFor) { fav in
            SymbolPicker { symbol in
                if let i = settings.favorites.firstIndex(where: { $0.id == fav.id }) { settings.favorites[i].symbol = symbol }
                editingSymbolFor = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            ActivityFooter()
        }
    }
}

struct SidebarRow: View {
    @Environment(Workspace.self) private var ws
    let title: String
    let symbol: String
    let dropTarget: URL
    @State private var targeted = false

    var body: some View {
        Label {
            Text(title).font(.system(size: 13)).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(AppSettings.shared.accent)
        }
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? AppSettings.shared.accent.opacity(0.25) : .clear).padding(-3))
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { DropLoader.handle($0, into: dropTarget, workspace: ws) }
    }
}

struct SymbolPicker: View {
    let onPick: (String) -> Void
    private let symbols = [
        "folder", "house", "doc", "doc.text", "tray.full", "archivebox", "shippingbox", "briefcase", "graduationcap",
        "hammer", "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right", "swift", "cpu",
        "photo", "camera", "film", "music.note", "headphones", "paintbrush", "paintpalette", "pencil.and.ruler",
        "book", "books.vertical", "bookmark", "star", "heart", "flag", "bolt", "leaf", "flame", "globe",
        "icloud", "externaldrive", "server.rack", "gamecontroller", "cart", "creditcard", "building.2", "person",
        "person.2", "sparkles", "lightbulb", "calendar", "clock", "lock", "key", "airplane", "car",
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(symbols, id: \.self) { s in
                    Button { onPick(s) } label: {
                        Image(systemName: s).font(.system(size: 14)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(12)
        }
        .frame(width: 310, height: 250)
    }
}

/// A small progress readout at the bottom of the sidebar while operations run.
struct ActivityFooter: View {
    var body: some View {
        let running = FileOperationCenter.shared.activities.filter { !$0.finished }
        if let a = running.first {
            VStack(alignment: .leading, spacing: 4) {
                Text(a.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                ProgressView(value: a.fraction).controlSize(.small)
                if running.count > 1 {
                    Text("+\(running.count - 1) more").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
    }
}
