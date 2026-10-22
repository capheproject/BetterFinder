import AppKit
import Carbon.HIToolbox
import Quartz
import SwiftUI

@main
struct BetterFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("BetterFinder", id: "browser") {
            BrowserWindow()
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1320, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands()
        }

        WindowGroup("Portal", id: "portal") {
            BrowserWindow(portal: true)
                .frame(minWidth: 360, minHeight: 300)
        }
        .defaultSize(width: 480, height: 560)
        .windowToolbarStyle(.unifiedCompact)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?
    private var monitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Installed before launch completes so a reveal that launched the app isn't missed.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleReveal(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    /// "Show in Finder" from other apps, when BetterFinder is the file viewer.
    @objc private func handleReveal(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        ExternalOpen.handle(ExternalOpen.urls(from: event), reveal: true)
    }

    /// Open-documents requests. Folders come from Launch Services (Dock stacks, `open` in
    /// Terminal); files come from "Show in Finder" — AppKit delivers a reveal to the NSFileViewer
    /// app as an open request for the file itself, and BetterFinder only opens folders.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { FileSystem.isDirectory($0) && !NSWorkspace.shared.isFilePackage(atPath: $0.path) }
        let files = urls.filter { !folders.contains($0) }
        if !folders.isEmpty { ExternalOpen.handle(folders, reveal: false) }
        if !files.isEmpty { ExternalOpen.handle(files, reveal: true) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        installKeyMonitor()
        HotKeyManager.shared.action = { AppDelegate.summonQuickOpen() }
        HotKeyManager.shared.refresh()
        _ = VolumeStore.shared
        AppIconController.shared.start()
        FolderIndex.shared.start()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow, let ws = WorkspaceRegistry.workspace(for: w) { WorkspaceRegistry.lastActive = ws }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // A window that's minimized or on another Space counts as "not visible" here; bring it
        // back rather than piling up new windows.
        if let window = WorkspaceRegistry.all.first(where: { !$0.isPortal })?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            AppDelegate.openMainWindow?()
        }
        return false
    }

    static func summonQuickOpen() {
        NSApp.activate(ignoringOtherApps: true)
        if let ws = WorkspaceRegistry.lastActive, let w = ws.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            ws.openQuickOpen()
        } else if let ws = WorkspaceRegistry.all.first(where: { !$0.isPortal }), let w = ws.window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            ws.openQuickOpen()
        } else {
            openMainWindow?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WorkspaceRegistry.lastActive?.openQuickOpen() }
        }
    }

    /// Routes keys like Space, Return, Tab and arrows to the browser before AppKit's
    /// default handling, but never while a text field is being edited.
    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard let window = event.window, let ws = WorkspaceRegistry.workspace(for: window) else { return event }
            if event.type == .leftMouseDown {
                ws.mouseDown(event)
                return event
            }
            if ws.showQuickOpen { return ws.quickOpen.handleKey(event) ? nil : event }
            if window.attachedSheet != nil { return event }
            if window.firstResponder is NSText { return event }
            return ws.handleKey(event) ? nil : event
        }
    }

    // Quick Look panel control lives at the end of the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

enum TextResponder {
    static var isEditing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    /// Sends `selector` to the text field being edited, or runs `otherwise`.
    static func route(_ selector: String, otherwise: () -> Void) {
        if isEditing { NSApp.sendAction(Selector(selector), to: nil, from: nil) } else { otherwise() }
    }
}

private func fn(_ key: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(key)!)) }

struct BrowserCommands: Commands {
    @FocusedValue(\.workspace) private var ws
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { ws?.newTab() }.keyboardShortcut("t")
            Button("New Portal") { openWindow(id: "portal") }.keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("New Folder") { ws?.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder (F7)") { ws?.newFolder() }.keyboardShortcut(fn(NSF7FunctionKey), modifiers: [])
            Button("New Folder with Selection") { ws?.newFolderWithSelection() }.keyboardShortcut("n", modifiers: [.command, .control])
            Menu("New File") {
                ForEach(NewFileTemplate.all) { t in Button(t.title) { ws?.newFile(t) } }
            }
            Button("New Text File") { ws?.newFile(NewFileTemplate.all[0]) }.keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open") { ws?.open() }.keyboardShortcut("o")
            Button("Open Selection") { ws?.open() }.keyboardShortcut(.downArrow)
            Button("Open in New Tab") {
                guard let ws else { return }
                for item in ws.activeTab.selectedItems where item.isFolder { ws.activePane.addTab(url: item.url, activate: false) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Quick Look") { ws?.quickLook() }.keyboardShortcut("y")
            Button("Get Info") { ws?.showInspector.toggle() }.keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { ws?.closeTabOrWindow() }.keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { TextResponder.route("undo:") { FileOperationCenter.shared.undoLast() } }.keyboardShortcut("z")
            Button("Redo") { TextResponder.route("redo:") {} }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { TextResponder.route("cut:") { ws?.copySelection(cut: true) } }.keyboardShortcut("x")
            Button("Copy") { TextResponder.route("copy:") { ws?.copySelection() } }.keyboardShortcut("c")
            Button("Paste") { TextResponder.route("paste:") { ws?.paste() } }.keyboardShortcut("v")
            Button("Move Item Here") { ws?.paste(move: true) }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Copy Path") { ws?.copyPath() }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Select All") { TextResponder.route("selectAll:") { ws?.selectAll() } }.keyboardShortcut("a")
            Divider()
            Button("Rename (F2)") { ws?.beginRename() }.keyboardShortcut(fn(NSF2FunctionKey), modifiers: [])
            Button("Batch Rename…") { if let ws { ws.batchRename = BatchRenameRequest(urls: ws.targetURLs) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Duplicate") { ws?.duplicate() }.keyboardShortcut("d")
            Button("Compress") { ws?.compress() }
            Divider()
            Button("Move to Trash") { TextResponder.route("deleteToBeginningOfLine:") { ws?.trash() } }.keyboardShortcut(.delete)
            Button("Move to Trash (F8)") { ws?.trash() }.keyboardShortcut(fn(NSF8FunctionKey), modifiers: [])
            Button("Delete Immediately…") { ws?.deleteImmediately() }.keyboardShortcut(.delete, modifiers: [.command, .option])
        }
        CommandGroup(before: .toolbar) {
            Button("Show/Hide Sidebar") { ws?.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Show/Hide Inspector") { ws?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { i, m in
                Button("as \(m.title)") { ws?.setViewMode(m) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Menu("Layout") {
                ForEach(Array(PaneLayout.allCases.enumerated()), id: \.element) { i, l in
                    Button(l.title) { ws?.layout = l }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
                }
            }
            Button("Toggle Sync Browsing") { ws?.syncBrowsing.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Show/Hide Hidden Files") { ws?.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Bigger Icons") { ws?.adjustIconSize(16) }.keyboardShortcut("=")
            Button("Smaller Icons") { ws?.adjustIconSize(-16) }.keyboardShortcut("-")
            Button("Refresh") { ws?.refreshAll() }.keyboardShortcut("r")
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { ws?.activeTab.goBack() }.keyboardShortcut("[")
            Button("Forward") { ws?.activeTab.goForward() }.keyboardShortcut("]")
            Button("Enclosing Folder") { ws?.activeTab.goUp() }.keyboardShortcut(.upArrow)
            Divider()
            Button("Home") { ws?.go(to: FileSystem.home) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { ws?.go(to: FileSystem.home.appendingPathComponent("Desktop")) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { ws?.go(to: FileSystem.home.appendingPathComponent("Documents")) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { ws?.go(to: FileSystem.home.appendingPathComponent("Downloads")) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { ws?.go(to: URL(fileURLWithPath: "/Applications")) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("iCloud Drive") { ws?.go(to: FileSystem.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Quick Open…") { ws?.openQuickOpen() }.keyboardShortcut("k")
            Button("Go to Folder…") { ws?.openQuickOpen(prefill: "~/") }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Filter…") { ws?.showFilter() }.keyboardShortcut("f")
            Divider()
            Button("Next Tab") { ws?.selectTab(offset: 1) }.keyboardShortcut("}", modifiers: [.command, .shift])
            Button("Previous Tab") { ws?.selectTab(offset: -1) }.keyboardShortcut("{", modifiers: [.command, .shift])
            Divider()
            Button("Copy to Other Pane") { ws?.transferToOtherPane(move: false) }.keyboardShortcut(fn(NSF5FunctionKey), modifiers: [])
            Button("Move to Other Pane") { ws?.transferToOtherPane(move: true) }.keyboardShortcut(fn(NSF6FunctionKey), modifiers: [])
            Button("Show Same Folder in Other Pane") { ws?.mirrorToOtherPane() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Swap Panes") { ws?.swapPanes() }.keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Open in Terminal") { ws?.openInTerminal() }.keyboardShortcut("t", modifiers: [.command, .control])
        }
        CommandMenu("Workspaces") {
            ForEach(AppSettings.shared.workspaces) { w in
                Button(w.name) { ws?.restore(w) }
            }
            if !AppSettings.shared.workspaces.isEmpty { Divider() }
            Button("Save Current Workspace…") { ws?.saveWorkspace() }.keyboardShortcut("s", modifiers: [.command, .control])
            if !AppSettings.shared.workspaces.isEmpty {
                Menu("Delete Workspace") {
                    ForEach(AppSettings.shared.workspaces) { w in
                        Button(w.name) { AppSettings.shared.workspaces.removeAll { $0.id == w.id } }
                    }
                }
            }
        }
    }
}
