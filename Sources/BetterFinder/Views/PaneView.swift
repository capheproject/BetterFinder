import AppKit
import SwiftUI

struct PanesLayoutView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let p = ws.panes
        Group {
            switch ws.layout {
            case .single:
                PaneView(pane: p[0], index: 0)
            case .sideBySide:
                HSplitView { PaneView(pane: p[0], index: 0); PaneView(pane: p[1], index: 1) }
            case .stacked:
                VSplitView { PaneView(pane: p[0], index: 0); PaneView(pane: p[1], index: 1) }
            case .triple:
                HSplitView { PaneView(pane: p[0], index: 0); PaneView(pane: p[1], index: 1); PaneView(pane: p[2], index: 2) }
            case .mainLeft:
                HSplitView {
                    PaneView(pane: p[0], index: 0)
                    VSplitView { PaneView(pane: p[1], index: 1); PaneView(pane: p[2], index: 2) }
                }
            case .quad:
                VSplitView {
                    HSplitView { PaneView(pane: p[0], index: 0); PaneView(pane: p[1], index: 1) }
                    HSplitView { PaneView(pane: p[2], index: 2); PaneView(pane: p[3], index: 3) }
                }
            }
        }
    }
}

struct PaneView: View {
    @Environment(Workspace.self) private var ws
    let pane: Pane
    let index: Int

    var body: some View {
        let tab = pane.current
        let settings = AppSettings.shared
        let isActive = ws.activePaneIndex == index
        let multi = ws.visiblePaneCount > 1
        VStack(spacing: 0) {
            if pane.tabs.count > 1 { TabStrip(pane: pane, paneIndex: index) }
            PathBar(tab: tab, paneIndex: index, isActive: isActive && multi)
            if tab.isFilterVisible { FilterBar(tab: tab) }
            Divider().opacity(0.6)
            ZStack {
                PaneContent(tab: tab, paneIndex: index)
                PaneOverlay(tab: tab)
            }
            Divider().opacity(0.6)
            StatusBar(tab: tab)
        }
        .frame(minWidth: 260, minHeight: 180)
        .background(settings.tintWindow ? settings.accent.opacity(isActive && multi ? 0.035 : 0.015) : Color.clear)
        .overlay(alignment: .top) {
            if isActive && multi {
                Rectangle().fill(settings.accent).frame(height: 2)
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { ws.paneFrames[index] = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, f in ws.paneFrames[index] = f }
        })
    }
}

struct PaneContent: View {
    @Environment(Workspace.self) private var ws
    let tab: BrowserTab
    let paneIndex: Int
    @State private var targeted = false

    var body: some View {
        switch tab.viewMode {
        case .list:
            FileTableView(tab: tab, workspace: ws, paneIndex: paneIndex,
                          items: tab.displayed, selection: tab.selection, sort: tab.sort,
                          renamingURL: tab.renamingURL, scrollTarget: tab.scrollTarget,
                          git: tab.git, accentHex: AppSettings.shared.accentHex)
                .id(tab.id)
        case .grid:
            FileGridView(tab: tab, paneIndex: paneIndex)
                .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                    guard !tab.isSearch else { return false }
                    return DropLoader.handle(providers, into: tab.url, workspace: ws)
                }
                .overlay { if targeted { DropHighlight() } }
                .id(tab.id)
        case .columns:
            ColumnsBrowserView(tab: tab, paneIndex: paneIndex)
                .id(tab.id)
        }
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(AppSettings.shared.accent, lineWidth: 2)
            .padding(3)
            .allowsHitTesting(false)
    }
}

struct PaneOverlay: View {
    let tab: BrowserTab

    var body: some View {
        if let error = tab.loadError {
            ContentUnavailableView {
                Label("Can’t Open Folder", systemImage: "lock.fill")
            } description: {
                Text(error)
            } actions: {
                if error.contains("Full Disk Access") {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            .background(.background)
        } else if tab.displayed.isEmpty && !tab.isLoading {
            VStack(spacing: 8) {
                Image(systemName: tab.isSearch ? "magnifyingglass" : "folder")
                    .font(.system(size: 34, weight: .light))
                Text(tab.isSearch ? "No Results" : (tab.filterText.isEmpty ? "Empty Folder" : "No Matches"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Tabs

struct TabStrip: View {
    @Environment(Workspace.self) private var ws
    let pane: Pane
    let paneIndex: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { i, t in
                TabChip(title: t.title, url: t.url, active: i == pane.activeTabIndex) {
                    pane.closeTab(at: i)
                    ws.persist()
                }
                .onTapGesture {
                    ws.activate(paneIndex)
                    pane.activeTabIndex = i
                    ws.persist()
                }
            }
            Button {
                ws.activate(paneIndex)
                ws.newTab()
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
    }
}

struct TabChip: View {
    let title: String
    let url: URL
    let active: Bool
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 14, height: 14)
            Text(title).font(.system(size: 12, weight: active ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || active ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5))
        .foregroundStyle(active ? .primary : .secondary)
        .onHover { hovering = $0 }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @Environment(Workspace.self) private var ws
    let tab: BrowserTab
    let paneIndex: Int
    let isActive: Bool
    @State private var editing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var crumbs: [URL] {
        var urls: [URL] = []
        var u = tab.url
        while true {
            urls.insert(u, at: 0)
            if u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        return urls
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { tab.goBack() } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                    .disabled(!tab.canGoBack)
                Button { tab.goForward() } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                    .disabled(!tab.canGoForward)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))

            if editing {
                TextField("Path", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit {
                        let url = FileSystem.expandPath(text, relativeTo: tab.url)
                        if FileSystem.isDirectory(url) { tab.navigate(to: url) }
                        else if FileSystem.exists(url) { tab.navigate(to: url.deletingLastPathComponent(), select: url) }
                        else { NSSound.beep() }
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, f in if !f { editing = false } }
                    .onAppear { fieldFocused = true }
            } else if let title = tab.searchTitle {
                Label(title, systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        let list = crumbs
                        ForEach(Array(list.enumerated()), id: \.element) { i, url in
                            Crumb(url: url, isLast: i == list.count - 1, showIcon: i == 0 || i == list.count - 1) {
                                ws.activate(paneIndex)
                                tab.navigate(to: url)
                            }
                            if i < list.count - 1 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.trailing)
                Spacer(minLength: 20)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing() }
            }

            if let git = tab.git {
                Label(git.branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("\(git.changeCount) changed file\(git.changeCount == 1 ? "" : "s") in \(git.root.lastPathComponent)")
            }
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            }
            Button { startEditing() } label: { Image(systemName: "character.cursor.ibeam") }
                .buttonStyle(.borderless)
                .help("Edit path")
                .opacity(editing ? 0 : 0.6)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isActive ? AppSettings.shared.accent.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { ws.activate(paneIndex) }
    }

    private func startEditing() {
        text = (tab.url.path as NSString).abbreviatingWithTildeInPath
        editing = true
    }
}

struct Crumb: View {
    @Environment(Workspace.self) private var ws
    let url: URL
    let isLast: Bool
    let showIcon: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showIcon {
                    Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 14, height: 14)
                }
                Text(FileSystem.displayName(url))
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(targeted ? AppSettings.shared.accent.opacity(0.25) : (hovering ? Color.primary.opacity(0.08) : .clear)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? .primary : .secondary)
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { DropLoader.handle($0, into: url, workspace: ws) }
        .contextMenu {
            Button("Copy Path") { ws.copyPath([url]) }
            Button("Open in New Tab") { ws.newTab(url) }
            Button("Open in Terminal") { ws.openInTerminal(url) }
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Environment(Workspace.self) private var ws
    @Bindable var tab: BrowserTab
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(AppSettings.shared.accent)
            TextField(tab.filterRecursive ? "Search in subfolders" : "Filter this folder", text: $tab.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { ws.focusActivePane() }
                .onExitCommand {
                    tab.closeFilter()
                    ws.focusActivePane()
                }
            Picker("", selection: $tab.filterRecursive) {
                Text("This Folder").tag(false)
                Text("Subfolders").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            Button {
                tab.closeFilter()
                ws.focusActivePane()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.03))
        .onAppear { focused = true }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Bindable var tab: BrowserTab
    @State private var free: Int64?

    var body: some View {
        let count = tab.displayed.count
        let sel = tab.selection.count
        HStack(spacing: 10) {
            Text(sel > 0 ? "\(sel) of \(count) selected" : "\(count) item\(count == 1 ? "" : "s")")
            if sel > 0 {
                let bytes = tab.selectedItems.reduce(Int64(0)) { $0 + max(0, $1.size) }
                if bytes > 0 { Text(Fmt.size(bytes)).foregroundStyle(.tertiary) }
            }
            Spacer()
            if tab.viewMode == .grid {
                Image(systemName: "photo").font(.system(size: 9))
                Slider(value: $tab.iconSize, in: 32...256)
                    .controlSize(.mini)
                    .frame(width: 90)
                Image(systemName: "photo").font(.system(size: 12))
            }
            if let free { Text("\(Fmt.size(free)) available") }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .task(id: tab.url) {
            let url = tab.url
            free = await Task.detached { FileSystem.freeSpace(url) }.value
        }
    }
}
