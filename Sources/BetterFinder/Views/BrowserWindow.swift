import AppKit
import SwiftUI

struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct BrowserWindow: View {
    @State private var ws: Workspace
    @Environment(\.openWindow) private var openWindow

    init(portal: Bool = false) {
        _ws = State(initialValue: Workspace(portal: portal))
    }

    var body: some View {
        Group {
            if ws.isPortal { PortalContent() } else { MainContent() }
        }
        .overlay {
            if ws.showQuickOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { ws.closeQuickOpen() }
                    QuickOpenView().padding(.top, 70)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.easeOut(duration: 0.15), value: ws.showQuickOpen)
        .animation(.spring(duration: 0.3), value: FileOperationCenter.shared.toastMessage)
        .sheet(item: $ws.batchRename) { req in BatchRenameView(urls: req.urls) }
        .environment(ws)
        .focusedSceneValue(\.workspace, ws)
        .background(WindowAccessor { ws.attach($0) })
        .tint(AppSettings.shared.accent)
        .onAppear {
            if !ws.isPortal {
                AppDelegate.openMainWindow = { openWindow(id: "browser") }
            }
            ws.focusActivePane()
        }
    }
}

struct MainContent: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        @Bindable var ws = ws
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
        } detail: {
            PanesLayoutView()
                .inspector(isPresented: $ws.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 290, max: 460)
                }
                .toolbar { BrowserToolbar() }
        }
        .navigationTitle(ws.activeTab.title)
        .navigationSubtitle(ws.activeTab.isSearch ? "" : (ws.activeTab.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
    }
}

struct PortalContent: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        @Bindable var ws = ws
        PaneView(pane: ws.panes[0], index: 0)
            .navigationTitle(ws.activeTab.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ViewModePicker()
                    Button { ws.openQuickOpen() } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                    Toggle(isOn: $ws.isPinned) { Label("Pin on Top", systemImage: ws.isPinned ? "pin.fill" : "pin") }
                        .help("Keep this Portal above other windows")
                }
            }
    }
}

struct ViewModePicker: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        let binding = Binding<ViewMode>(get: { ws.activeTab.viewMode }, set: { ws.setViewMode($0) })
        Picker("View", selection: binding) {
            ForEach(ViewMode.allCases) { m in
                Label(m.title, systemImage: m.symbol).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("View as List, Icons or Columns (⌘1–3)")
    }
}

struct BrowserToolbar: ToolbarContent {
    @Environment(Workspace.self) private var ws

    var body: some ToolbarContent {
        @Bindable var ws = ws
        let tab = ws.activeTab
        ToolbarItemGroup(placement: .navigation) {
            Button { tab.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!tab.canGoBack)
                .help("Back (⌘[)")
            Button { tab.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!tab.canGoForward)
                .help("Forward (⌘])")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ViewModePicker()

            Menu {
                ForEach(PaneLayout.allCases) { l in
                    Button { ws.layout = l } label: { Label(l.title, systemImage: l.symbol) }
                }
            } label: {
                Label("Layout", systemImage: ws.layout.symbol)
            }
            .help("Pane layout (⌃1–⌃6)")

            Toggle(isOn: $ws.syncBrowsing) {
                Label("Sync Browsing", systemImage: "arrow.left.arrow.right.square")
            }
            .help("Sync Browsing: selecting a folder shows its contents in the next pane")
            .disabled(ws.visiblePaneCount < 2)

            Button { ws.toggleHidden() } label: {
                Label("Hidden Files", systemImage: AppSettings.shared.showHidden ? "eye" : "eye.slash")
            }
            .help("Show/Hide hidden files (⇧⌘.)")

            Menu {
                Button { ws.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Divider()
                ForEach(NewFileTemplate.all) { t in
                    Button { ws.newFile(t) } label: { Label(t.title, systemImage: t.symbol) }
                }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                ws.newFolder()
            }
            .help("New Folder (⇧⌘N) — hold for new files")

            Button { ws.openInTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                .help("Open current folder in Terminal")

            ActivityButton()

            Button { ws.openQuickOpen() } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                .help("Quick Open — folders, files, commands (⌘K)")

            Button { ws.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Inspector (⌘I)")
        }
    }
}
