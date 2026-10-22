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
        // Both side panels float over one continuous surface. The panes take their new width in
        // a single step and only the panels glide; animating the panes' width (as a split view
        // does) re-lays out every list row on every frame, which is what made the sidebar lag.
        HStack(spacing: 0) {
            if ws.showSidebar {
                FloatingSidebar()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            PanesLayoutView()
                .transaction { $0.animation = nil }
            if ws.showInspector {
                FloatingInspector()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Workspace.panelAnimation, value: ws.showSidebar)
        .animation(Workspace.panelAnimation, value: ws.showInspector)
        .toolbar { BrowserToolbar() }
        .navigationTitle(ws.activeTab.title)
        .navigationSubtitle(ws.activeTab.isSearch || !AppSettings.shared.showPathInTitle
            ? "" : (ws.activeTab.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
    }
}

/// The sidebar as a floating panel, mirroring the inspector. Drag its right edge to resize.
struct FloatingSidebar: View {
    @AppStorage("sidebar.width") private var width: Double = 220
    @State private var dragStart: Double?

    var body: some View {
        SidebarView()
            .scrollContentBackground(.hidden)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(PanelSurface(cornerRadius: 18))
            .overlay(alignment: .trailing) {
                ResizeHandle { delta in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(340, max(170, start + delta))
                } onEnd: { dragStart = nil }
                .offset(x: 4)
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
            .padding(.leading, 8)
            .padding(.trailing, 2)
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
        // While the sidebar is open, reserve its width so the sidebar button lands at its top-right
        // corner and Back/Forward and the title start beside it, as with the system sidebar.
        if ws.showSidebar {
            SidebarToolbarSpacer()
        }
        ToolbarItem(placement: .navigation) {
            Button { ws.showSidebar.toggle() } label: { Label("Sidebar", systemImage: "sidebar.left") }
                .help(ws.showSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { tab.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!tab.canGoBack)
                .help("Back (⌘[)")
            Button { tab.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!tab.canGoForward)
                .help("Forward (⌘])")
        }
        // Grouped like ForkLift: view controls, browsing toggles, file actions, then search.
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
        }
        ToolbarSeparatorSpacer()
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $ws.syncBrowsing) {
                Label("Sync Browsing", systemImage: "arrow.left.arrow.right.square")
            }
            .help("Sync Browsing: selecting a folder shows its contents in the next pane")
            .disabled(ws.visiblePaneCount < 2)

            Button { ws.toggleHidden() } label: {
                Label("Hidden Files", systemImage: AppSettings.shared.showHidden ? "eye" : "eye.slash")
            }
            .help("Show/Hide hidden files (⇧⌘.)")
        }
        ToolbarSeparatorSpacer()
        ToolbarItemGroup(placement: .primaryAction) {
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
        }
        ToolbarSeparatorSpacer()
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ws.openQuickOpen() } label: { Label("Quick Open", systemImage: "magnifyingglass") }
                .help("Quick Open — folders, files, commands (⌘K)")

            Button { ws.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Inspector (⌘I)")
        }
    }
}

/// Visual gap between toolbar groups; on macOS 26 each group gets its own glass capsule.
struct ToolbarSeparatorSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}

/// The inspector as a floating, rounded panel inset from the window edges — a twin of the
/// macOS 26 sidebar — instead of a flush column. Drag its left edge to resize.
struct FloatingInspector: View {
    @AppStorage("inspector.width") private var width: Double = 290
    @State private var dragStart: Double?

    var body: some View {
        InspectorView()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(PanelSurface(cornerRadius: 18))
            .overlay(alignment: .leading) {
                ResizeHandle { delta in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(480, max(240, start - delta))
                } onEnd: { dragStart = nil }
                .offset(x: -4)
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
            .padding(.trailing, 8)
            .padding(.leading, 2)
    }
}

/// An invisible strip that resizes a panel when dragged, with the resize cursor on hover.
struct ResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { onDrag($0.translation.width) }
                .onEnded { _ in onEnd() })
    }
}

/// Liquid Glass on macOS 26, a material card on earlier systems.
struct PanelSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}

/// An empty, unstyled toolbar item as wide as the sidebar (less the traffic-light area).
struct SidebarToolbarSpacer: ToolbarContent {
    @AppStorage("sidebar.width") private var width: Double = 220

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: max(0, width - 116), height: 1)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: max(0, width - 116), height: 1)
            }
        }
    }
}
