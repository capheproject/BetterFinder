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
            PaneHeader(tab: tab, paneIndex: index, isActive: isActive || !multi)
            if tab.isFilterVisible { FilterBar(tab: tab) }
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            ZStack {
                PaneContent(tab: tab, paneIndex: index)
                PaneOverlay(tab: tab)
            }
        }
        .frame(minWidth: 280, minHeight: 200)
        .background(settings.tintWindow && isActive && multi ? settings.accent.opacity(0.025) : Color.clear)
        .overlay(alignment: .top) {
            // A soft accent capsule marks the active pane.
            Capsule()
                .fill(settings.accent)
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.top, 1)
                .opacity(isActive && multi ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isActive)
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

// MARK: - Pane header

/// Two lines: folder icon + breadcrumb, then a quiet summary (items, selection, free space).
struct PaneHeader: View {
    @Environment(Workspace.self) private var ws
    @Bindable var tab: BrowserTab
    let paneIndex: Int
    let isActive: Bool
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @State private var free: Int64?
    @FocusState private var fieldFocused: Bool

    private var crumbs: [URL] {
        var urls: [URL] = []
        var u = tab.url
        while true {
            urls.insert(u, at: 0)
            if u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        // Start at the home folder when inside it, like a person would describe the path.
        if let home = urls.firstIndex(where: { $0.path == FileSystem.home.path }) { urls.removeFirst(home) }
        return urls
    }

    private var summary: String {
        let count = tab.displayed.count
        let sel = tab.selection.count
        var parts: [String] = []
        if sel > 0 {
            var s = "\(sel) of \(count) selected"
            let bytes = tab.selectedItems.reduce(Int64(0)) { $0 + max(0, $1.size) }
            if bytes > 0 { s += " (\(Fmt.size(bytes)))" }
            parts.append(s)
        } else {
            parts.append("\(count) item\(count == 1 ? "" : "s")")
        }
        if let free { parts.append("\(Fmt.size(free)) available") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: tab.isSearch ? FileSystem.home : tab.url))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(isActive ? 1 : 0.75)
                .overlay {
                    if tab.isSearch {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: 2)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Path", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
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
                    Text(title).font(.system(size: 13, weight: .semibold))
                } else {
                    let list = crumbs
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(Array(list.enumerated()), id: \.element) { i, url in
                                    Crumb(url: url, isLast: i == list.count - 1) {
                                        ws.activate(paneIndex)
                                        tab.navigate(to: url)
                                    }
                                    .id(url)
                                    if i < list.count - 1 {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        // Keep the current folder in view when the path is longer than the pane.
                        .onAppear { proxy.scrollTo(list.last, anchor: .trailing) }
                        .onChange(of: tab.url) { _, _ in proxy.scrollTo(list.last, anchor: .trailing) }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                            proxy.scrollTo(list.last, anchor: .trailing)
                        }
                    }
                    .onTapGesture(count: 2) { startEditing() }
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 8)

            if tab.isLoading {
                ProgressView().controlSize(.small)
            }
            if let git = tab.git {
                Label(git.branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("\(git.changeCount) changed file\(git.changeCount == 1 ? "" : "s") in \(git.root.lastPathComponent)")
            }
            if tab.viewMode == .grid {
                Slider(value: $tab.iconSize, in: 32...256)
                    .controlSize(.mini)
                    .frame(width: 80)
                    .help("Icon size")
            }
            Button { startEditing() } label: {
                Image(systemName: "character.cursor.ibeam").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Type a path")
            .opacity(hovering && !editing ? 0.7 : 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .contentShape(Rectangle())
        .onTapGesture { ws.activate(paneIndex) }
        .onHover { hovering = $0 }
        .task(id: tab.url) {
            let url = tab.url
            free = await Task.detached { FileSystem.freeSpace(url) }.value
        }
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
    let action: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            Text(FileSystem.displayName(url))
                .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(targeted ? AppSettings.shared.accent.opacity(0.25) : (hovering ? Color.primary.opacity(0.07) : .clear)))
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
