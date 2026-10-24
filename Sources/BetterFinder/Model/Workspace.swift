import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PaneLayout: String, CaseIterable, Codable, Identifiable {
    case single, sideBySide, stacked, triple, mainLeft, quad
    var id: String { rawValue }

    var paneCount: Int {
        switch self {
        case .single: 1
        case .sideBySide, .stacked: 2
        case .triple, .mainLeft: 3
        case .quad: 4
        }
    }

    var title: String {
        switch self {
        case .single: "Single"
        case .sideBySide: "Side by Side"
        case .stacked: "Stacked"
        case .triple: "Three Columns"
        case .mainLeft: "One + Two"
        case .quad: "Four Panes"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .sideBySide: "rectangle.split.2x1"
        case .stacked: "rectangle.split.1x2"
        case .triple: "rectangle.split.3x1"
        case .mainLeft: "square.split.bottomrightquarter"
        case .quad: "rectangle.split.2x2"
        }
    }
}

struct SessionState: Codable {
    var layout: PaneLayout
    var panes: [[String]]
    var activeTabs: [Int]
    var viewModes: [String]
    var showInspector: Bool

    static func load() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: "session") else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}

struct NewFileTemplate: Identifiable {
    let id: String
    let title: String
    let filename: String
    let contents: String
    let symbol: String
    var executable = false

    static let all: [NewFileTemplate] = [
        .init(id: "txt", title: "Text File", filename: "untitled.txt", contents: "", symbol: "doc.plaintext"),
        .init(id: "md", title: "Markdown", filename: "untitled.md", contents: "# Untitled\n\n", symbol: "text.document"),
        .init(id: "json", title: "JSON", filename: "untitled.json", contents: "{\n  \n}\n", symbol: "curlybraces"),
        .init(id: "html", title: "HTML", filename: "index.html", contents: "<!doctype html>\n<html>\n<head><meta charset=\"utf-8\"><title>Untitled</title></head>\n<body>\n\n</body>\n</html>\n", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "sh", title: "Shell Script", filename: "script.sh", contents: "#!/bin/zsh\nset -euo pipefail\n\n", symbol: "terminal", executable: true),
        .init(id: "swift", title: "Swift", filename: "main.swift", contents: "import Foundation\n\n", symbol: "swift"),
        .init(id: "py", title: "Python", filename: "main.py", contents: "#!/usr/bin/env python3\n\n", symbol: "chevron.left.forwardslash.chevron.right"),
    ]
}

/// Finds the workspace that owns a given window.
enum WorkspaceRegistry {
    private static let table = NSMapTable<NSWindow, Workspace>.weakToWeakObjects()
    static weak var lastActive: Workspace?

    static func register(_ ws: Workspace, window: NSWindow) {
        table.setObject(ws, forKey: window)
        if !ws.isPortal || lastActive == nil { lastActive = ws }
        ExternalOpen.flush(into: ws)
    }

    static func workspace(for window: NSWindow) -> Workspace? { table.object(forKey: window) }

    static var all: [Workspace] { table.objectEnumerator()?.allObjects as? [Workspace] ?? [] }
}

@Observable
final class Workspace {
    let isPortal: Bool
    var panes: [Pane]
    var layout: PaneLayout { didSet { if activePaneIndex >= layout.paneCount { activePaneIndex = 0 }; persist() } }
    var activePaneIndex = 0
    var showInspector: Bool { didSet { persist() } }
    var showSidebar = UserDefaults.standard.object(forKey: "sidebar.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "sidebar.visible") }
    }
    var syncBrowsing = false

    /// One curve for both side panels: unhurried, with a soft ease-out (easeOutQuint).
    static let panelAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    var showQuickOpen = false
    var batchRename: BatchRenameRequest?
    var isPinned = false { didSet { window?.level = isPinned ? .floating : .normal } }
    let quickOpen = QuickOpenModel()

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var paneFrames: [Int: CGRect] = [:]
    @ObservationIgnored private var cutURLs: Set<URL> = []
    @ObservationIgnored private var syncWork: DispatchWorkItem?
    @ObservationIgnored private var typeBuffer = ""
    @ObservationIgnored private var typeTime = Date.distantPast
    @ObservationIgnored private static var restoredOnce = false

    var ops: FileOperationCenter { .shared }

    init(portal: Bool = false) {
        isPortal = portal
        let fm = FileManager.default
        let home = FileSystem.home
        if !portal, !Workspace.restoredOnce, let s = SessionState.load() {
            Workspace.restoredOnce = true
            layout = s.layout
            showInspector = s.showInspector
            panes = (0..<4).map { i in
                let paths = i < s.panes.count ? s.panes[i] : []
                let urls = paths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
                let pane = Pane(urls: urls.isEmpty ? [home] : urls)
                if i < s.activeTabs.count { pane.activeTabIndex = min(s.activeTabs[i], pane.tabs.count - 1) }
                if i < s.viewModes.count, let mode = ViewMode(rawValue: s.viewModes[i]) { pane.tabs.forEach { $0.viewMode = mode } }
                return pane
            }
        } else {
            Workspace.restoredOnce = true
            layout = portal ? .single : .sideBySide
            showInspector = !portal
            let defaults = ["", "Downloads", "Documents", "Desktop"].map { $0.isEmpty ? home : home.appendingPathComponent($0) }
            panes = defaults.map { Pane(urls: [fm.fileExists(atPath: $0.path) ? $0 : home]) }
        }
        quickOpen.workspace = self
        for pane in panes {
            pane.configure = { [weak self] tab in self?.wire(tab) }
            pane.tabs.forEach(wire)
        }
    }

    private func wire(_ tab: BrowserTab) {
        tab.onNavigate = { [weak self] tab in
            AppSettings.shared.noteVisit(tab.url)
            self?.persist()
        }
        tab.onSelectionChange = { [weak self] tab in self?.selectionChanged(in: tab) }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        window.tabbingMode = .disallowed
        WorkspaceRegistry.register(self, window: window)
        if isPortal { window.level = isPinned ? .floating : .normal }
    }

    // MARK: Accessors

    var visiblePaneCount: Int { layout.paneCount }
    var activePane: Pane { panes[min(activePaneIndex, panes.count - 1)] }
    var activeTab: BrowserTab { activePane.current }
    var otherPaneIndex: Int? { visiblePaneCount > 1 ? (activePaneIndex + 1) % visiblePaneCount : nil }
    var otherTab: BrowserTab? { otherPaneIndex.map { panes[$0].current } }
    var targetURLs: [URL] { activeTab.selectedURLs }

    func activate(_ index: Int) {
        if activePaneIndex != index { activePaneIndex = index }
        WorkspaceRegistry.lastActive = self
    }

    func persist() {
        guard !isPortal else { return }
        let s = SessionState(
            layout: layout,
            panes: panes.map { $0.tabs.map(\.url.path) },
            activeTabs: panes.map(\.activeTabIndex),
            viewModes: panes.map(\.current.viewMode.rawValue),
            showInspector: showInspector)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "session")
    }

    private func selectionChanged(in tab: BrowserTab) {
        guard tab === activeTab else { return }
        QuickLookController.shared.update(urls: tab.selectedURLs)
        // Sync runs one way: the left pane drives the right, which drills down on its own. Driving
        // from either side made a click in the right pane change the left one back and forth.
        guard syncBrowsing, activePaneIndex == 0, visiblePaneCount > 1 else { return }
        let other = panes[1].current
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab === self.activeTab else { return }
            let sel = tab.selectedItems
            guard sel.count == 1, sel[0].isFolder else { return }
            other.navigate(to: sel[0].url)
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func focusActivePane() {
        DispatchQueue.main.async { [weak self] in
            // Never pull focus away from Quick Open while it's on screen.
            guard let self, !self.showQuickOpen else { return }
            let tab = self.activeTab
            if tab.viewMode == .list, let table = tab.tableView {
                self.window?.makeFirstResponder(table)
            } else {
                tab.focusRequest += 1
            }
        }
    }

    // MARK: Navigation

    func go(to url: URL) { activeTab.navigate(to: url) }

    func reveal(_ url: URL) {
        activeTab.navigate(to: url.deletingLastPathComponent(), select: url)
    }

    func open(_ urls: [URL]? = nil) {
        let items = (urls ?? targetURLs).compactMap(FileItem.init(url:))
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isFolder)
        for (i, f) in folders.enumerated() {
            if i == 0 { activeTab.navigate(to: f.url) } else { activePane.addTab(url: f.url, activate: false) }
        }
        for file in items where !file.isFolder { NSWorkspace.shared.open(file.url) }
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func newTab(_ url: URL? = nil) {
        activePane.addTab(url: url ?? activeTab.url)
        persist()
    }

    func closeTabOrWindow() {
        if !activePane.closeTab(at: activePane.activeTabIndex) { window?.performClose(nil) }
        persist()
    }

    func selectTab(offset: Int) {
        let pane = activePane
        guard pane.tabs.count > 1 else { return }
        pane.activeTabIndex = (pane.activeTabIndex + offset + pane.tabs.count) % pane.tabs.count
    }

    func openInOtherPane(_ url: URL) {
        if visiblePaneCount == 1 { layout = .sideBySide }
        guard let other = otherTab else { return }
        if FileSystem.isDirectory(url) { other.navigate(to: url) } else { other.navigate(to: url.deletingLastPathComponent(), select: url) }
    }

    func mirrorToOtherPane() {
        if visiblePaneCount == 1 { layout = .sideBySide }
        otherTab?.navigate(to: activeTab.url)
    }

    func swapPanes() {
        guard let o = otherPaneIndex else { return }
        panes.swapAt(activePaneIndex, o)
        activePaneIndex = o
        persist()
    }

    func switchPane(forward: Bool) {
        guard visiblePaneCount > 1 else { return }
        activePaneIndex = (activePaneIndex + (forward ? 1 : visiblePaneCount - 1)) % visiblePaneCount
        focusActivePane()
    }

    func setViewMode(_ mode: ViewMode) {
        activeTab.viewMode = mode
        persist()
        focusActivePane()
    }

    func showTag(_ tag: String) {
        activeTab.showSpotlight(title: "Tag: \(tag)", query: "kMDItemUserTags == \"\(SpotlightSearch.escape(tag))\"c")
    }

    func openQuickOpen(prefill: String = "") {
        showQuickOpen = true
        quickOpen.reset(prefill: prefill)
    }

    func closeQuickOpen() {
        showQuickOpen = false
        focusActivePane()
    }

    // MARK: File operations

    func beginRename() {
        let sel = activeTab.selectedURLs
        if sel.count == 1 {
            activeTab.renamingURL = sel[0]
        } else if sel.count > 1 {
            batchRename = BatchRenameRequest(urls: sel)
        }
    }

    func commitRename(in tab: BrowserTab, url: URL, newName: String) {
        tab.renamingURL = nil
        if let newURL = ops.rename(url, to: newName) {
            tab.load(select: newURL)
        }
        focusActivePane()
    }

    func cancelRename(in tab: BrowserTab) {
        tab.renamingURL = nil
        focusActivePane()
    }

    func newFolder() {
        let tab = activeTab
        guard !tab.isSearch else { return }
        if let url = ops.newFolder(in: tab.url) { tab.load(select: url, rename: true) }
    }

    func newFolderWithSelection() {
        let tab = activeTab
        let sel = tab.selectedURLs
        guard !sel.isEmpty, !tab.isSearch, let folder = ops.newFolder(in: tab.url, name: "New Folder With Items") else { return }
        ops.transfer(sel, to: folder, move: true)
        tab.load(select: folder, rename: true)
    }

    func newFile(_ template: NewFileTemplate) {
        let tab = activeTab
        guard !tab.isSearch else { return }
        if let url = ops.newFile(in: tab.url, name: template.filename, contents: Data(template.contents.utf8), executable: template.executable) {
            tab.load(select: url, rename: true)
        }
    }

    func duplicate() {
        let created = ops.duplicate(targetURLs)
        if let last = created.last { activeTab.load(select: last) }
    }

    func trash(_ urls: [URL]? = nil) {
        let urls = urls ?? targetURLs
        guard !urls.isEmpty else { return }
        let items = activeTab.displayed
        let firstIdx = items.firstIndex { urls.contains($0.url) }
        ops.trash(urls)
        // Keep a sensible selection after deletion, like Finder never does.
        if let firstIdx {
            let remaining = items.filter { !urls.contains($0.url) }
            if !remaining.isEmpty {
                let next = remaining[min(firstIdx, remaining.count - 1)].url
                activeTab.selection = [next]
                activeTab.scrollTarget = next
            }
        }
    }

    func deleteImmediately() {
        guard !targetURLs.isEmpty else { return }
        ops.deleteImmediately(targetURLs)
    }

    func compress() {
        guard !targetURLs.isEmpty else { return }
        ops.compress(targetURLs)
    }

    func transferToOtherPane(move: Bool) {
        guard let other = otherTab, !other.isSearch else {
            ops.toast("Open a second pane to \(move ? "move" : "copy") items across.")
            return
        }
        guard !targetURLs.isEmpty else { return }
        ops.transfer(targetURLs, to: other.url, move: move)
    }

    func drop(_ urls: [URL], into dir: URL, forceCopy: Bool? = nil) {
        let urls = urls.filter { $0.standardizedFileURL != dir.standardizedFileURL }
        guard let first = urls.first else { return }
        let flags = NSEvent.modifierFlags
        let copy: Bool
        if let forceCopy { copy = forceCopy }
        else if flags.contains(.option) { copy = true }
        else if flags.contains(.command) { copy = false }
        else { copy = !FileSystem.sameVolume(first, dir) }
        ops.transfer(urls, to: dir, move: !copy)
    }

    // MARK: Pasteboard

    func copySelection(cut: Bool = false) {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        cutURLs = cut ? Set(urls) : []
        if cut { ops.toast("Cut \(urls.count) item\(urls.count == 1 ? "" : "s") — paste to move") }
    }

    func paste(move: Bool = false) {
        let tab = activeTab
        guard !tab.isSearch else { return }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let shouldMove = move || (!cutURLs.isEmpty && Set(urls) == cutURLs)
            ops.transfer(urls, to: tab.url, move: shouldMove)
            if shouldMove { cutURLs = [] }
            return
        }
        if let image = NSImage(pasteboard: pb), let url = ops.savePasted(image: image, in: tab.url) {
            tab.load(select: url)
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty,
           let url = ops.newFile(in: tab.url, name: "Pasted Text \(Fmt.stampFormatter.string(from: Date())).txt", contents: Data(text.utf8)) {
            tab.load(select: url)
            return
        }
        NSSound.beep()
    }

    func copyPath(_ urls: [URL]? = nil) {
        let urls = urls ?? (targetURLs.isEmpty ? [activeTab.url] : targetURLs)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        ops.toast(urls.count == 1 ? "Copied path of “\(urls[0].lastPathComponent)”" : "Copied \(urls.count) paths")
    }

    func selectAll() {
        activeTab.selection = Set(activeTab.displayed.map(\.url))
    }

    // MARK: Tools

    func quickLook() {
        let urls = targetURLs
        QuickLookController.shared.keyHandler = { [weak self] e in self?.handleQuickLookKey(e) ?? false }
        QuickLookController.shared.toggle(urls: urls)
    }

    func openInTerminal(_ url: URL? = nil) {
        var dir = url ?? activeTab.url
        if !FileSystem.isDirectory(dir) { dir = dir.deletingLastPathComponent() }
        let id = AppSettings.shared.terminalBundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func toggleHidden() {
        AppSettings.shared.showHidden.toggle()
        ops.toast(AppSettings.shared.showHidden ? "Showing hidden files" : "Hiding hidden files")
    }

    func showFilter() {
        activeTab.isFilterVisible = true
    }

    func adjustIconSize(_ delta: Double) {
        let tab = activeTab
        if tab.viewMode != .grid { tab.viewMode = .grid }
        tab.iconSize = min(256, max(32, tab.iconSize + delta))
    }

    // MARK: Workspaces

    func saveWorkspace() {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Saves the layout and every open tab so you can come back to it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let ws = SavedWorkspace(name: name.isEmpty ? "Workspace \(AppSettings.shared.workspaces.count + 1)" : name,
                                layout: layout,
                                panes: panes.map { $0.tabs.map(\.url.path) },
                                showInspector: showInspector)
        AppSettings.shared.workspaces.append(ws)
        ops.toast("Saved workspace “\(ws.name)”")
    }

    func restore(_ saved: SavedWorkspace) {
        layout = saved.layout
        showInspector = saved.showInspector
        for (i, paths) in saved.panes.enumerated() where i < panes.count {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let pane = Pane(urls: urls)
            pane.configure = { [weak self] tab in self?.wire(tab) }
            pane.tabs.forEach(wire)
            panes[i] = pane
        }
        activePaneIndex = 0
        persist()
    }

    // MARK: Keyboard

    enum Arrow { case up, down, left, right }

    /// Handles keys the frontmost browser should own. Returns true when consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let tab = activeTab
        guard tab.renamingURL == nil else { return false }
        switch e.keyCode {
        case 49 where mods.isEmpty: // space
            quickLook(); return true
        case 36 where mods.isEmpty, 76 where mods.isEmpty: // return / enter
            beginRename(); return !tab.selection.isEmpty
        case 48 where mods.isEmpty || mods == .shift: // tab
            guard visiblePaneCount > 1 else { return false }
            switchPane(forward: mods.isEmpty); return true
        case 53: // escape
            if tab.isFilterVisible { tab.closeFilter(); return true }
            if !tab.selection.isEmpty { tab.selection = []; return true }
            return false
        case 123 where !mods.contains(.command) && tab.viewMode != .list: return moveSelection(.left, extend: mods.contains(.shift))
        case 124 where !mods.contains(.command) && tab.viewMode != .list: return moveSelection(.right, extend: mods.contains(.shift))
        case 125 where !mods.contains(.command) && tab.viewMode != .list: return moveSelection(.down, extend: mods.contains(.shift))
        case 126 where !mods.contains(.command) && tab.viewMode != .list: return moveSelection(.up, extend: mods.contains(.shift))
        default: break
        }
        // The list view's table does native type-select; other views get ours.
        if tab.viewMode != .list, mods.subtracting(.shift).isEmpty, let chars = e.characters, let c = chars.first,
           c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" {
            typeSelect(chars)
            return true
        }
        return false
    }

    private func handleQuickLookKey(_ e: NSEvent) -> Bool {
        let map: [UInt16: Arrow] = [123: .left, 124: .right, 125: .down, 126: .up]
        guard let arrow = map[e.keyCode] else { return false }
        if activeTab.viewMode == .list && (arrow == .left || arrow == .right) { return false }
        return moveSelection(arrow, extend: false)
    }

    @discardableResult
    func moveSelection(_ arrow: Arrow, extend: Bool) -> Bool {
        let tab = activeTab
        let items = tab.displayed
        if tab.viewMode == .columns {
            if arrow == .left { tab.goUp(); return true }
            if arrow == .right { tab.enterSelectedFolder(); return true }
        }
        guard !items.isEmpty else { return false }
        let cols = tab.viewMode == .grid ? max(1, tab.gridColumns) : 1
        let delta: Int
        switch arrow {
        case .up: delta = -cols
        case .down: delta = cols
        case .left: delta = -1
        case .right: delta = 1
        }
        let current = tab.anchor.flatMap { a in items.firstIndex { $0.url == a } } ?? items.lastIndex { tab.selection.contains($0.url) }
        let next = current.map { min(items.count - 1, max(0, $0 + delta)) } ?? 0
        let url = items[next].url
        tab.selection = extend ? tab.selection.union([url]) : [url]
        tab.anchor = url
        tab.scrollTarget = url
        return true
    }

    private func typeSelect(_ chars: String) {
        let now = Date()
        typeBuffer = now.timeIntervalSince(typeTime) > 0.9 ? chars : typeBuffer + chars
        typeTime = now
        let tab = activeTab
        guard let match = tab.displayed.first(where: { $0.name.lowercased().hasPrefix(typeBuffer.lowercased()) })
            ?? tab.displayed.first(where: { $0.name.localizedStandardCompare(typeBuffer) == .orderedDescending }) else { return }
        tab.selection = [match.url]
        tab.anchor = match.url
        tab.scrollTarget = match.url
    }

    func mouseDown(_ e: NSEvent) {
        guard let content = window?.contentView else { return }
        let p = e.locationInWindow
        let pt = CGPoint(x: p.x, y: content.bounds.height - p.y)
        for (i, f) in paneFrames where i < visiblePaneCount && f.contains(pt) {
            activate(i)
            return
        }
    }

    // MARK: Context menus

    func menuEntries(for urls: [URL], in tab: BrowserTab) -> [MenuEntry] {
        guard !urls.isEmpty else { return backgroundMenu(tab) }
        let items = urls.compactMap(FileItem.init(url:))
        guard !items.isEmpty else { return backgroundMenu(tab) }
        let single = items.count == 1 ? items[0] : nil
        var e: [MenuEntry] = []

        e.append(.action("Open", "arrow.up.forward.app") { [weak self] in self?.open(urls) })
        if let single, !single.isFolder || single.isApp {
            e.append(.submenu("Open With", "square.grid.2x2", openWithEntries(single.url)))
        }
        if items.contains(where: \.isFolder) {
            e.append(.action("Open in New Tab", "plus.square.on.square") { [weak self] in
                for f in items where f.isFolder { self?.activePane.addTab(url: f.url, activate: false) }
            })
            if let f = items.first(where: \.isFolder) {
                e.append(.action("Open in Other Pane", "rectangle.righthalf.inset.filled") { [weak self] in self?.openInOtherPane(f.url) })
            }
        }
        if tab.isSearch, let single {
            e.append(.action("Show in Enclosing Folder", "folder") { [weak self] in self?.reveal(single.url) })
        }
        e.append(.action("Quick Look", "eye") { [weak self] in
            QuickLookController.shared.keyHandler = { [weak self] ev in self?.handleQuickLookKey(ev) ?? false }
            QuickLookController.shared.toggle(urls: urls)
        })
        e.append(.divider)
        if single != nil {
            e.append(.action("Rename", "pencil") { tab.renamingURL = urls[0] })
        } else {
            e.append(.action("Rename \(items.count) Items…", "character.cursor.ibeam") { [weak self] in
                self?.batchRename = BatchRenameRequest(urls: urls)
            })
        }
        e.append(.action("Duplicate", "plus.square.on.square") { [weak self] in
            _ = self?.ops.duplicate(urls)
        })
        e.append(.action("Compress", "archivebox") { [weak self] in self?.ops.compress(urls) })
        if let single, single.isArchive {
            e.append(.action("Extract Here", "shippingbox.and.arrow.backward") { [weak self] in self?.ops.extract(single.url) })
        }
        if items.allSatisfy(\.isImage) {
            e.append(.submenu("Image", "photo", [
                .action("Rotate Left", "rotate.left") { [weak self] in self?.ops.rotate(urls, clockwise: false) },
                .action("Rotate Right", "rotate.right") { [weak self] in self?.ops.rotate(urls, clockwise: true) },
                .divider,
                .action("Convert to PNG", nil) { [weak self] in self?.ops.convert(urls, to: .png) },
                .action("Convert to JPEG", nil) { [weak self] in self?.ops.convert(urls, to: .jpeg) },
                .action("Convert to HEIC", nil) { [weak self] in self?.ops.convert(urls, to: .heic) },
            ]))
        }
        e.append(.divider)
        e.append(.action("Copy", "doc.on.doc") { [weak self] in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            self?.ops.toast("Copied \(urls.count) item\(urls.count == 1 ? "" : "s")")
        })
        e.append(.action("Copy Path", "link") { [weak self] in self?.copyPath(urls) })
        if visiblePaneCount > 1 {
            e.append(.action("Copy to Other Pane", "arrow.right.doc.on.clipboard") { [weak self] in
                if let o = self?.otherTab { self?.ops.transfer(urls, to: o.url, move: false) }
            })
            e.append(.action("Move to Other Pane", "arrow.right.square") { [weak self] in
                if let o = self?.otherTab { self?.ops.transfer(urls, to: o.url, move: true) }
            })
        }
        e.append(.divider)
        var tagEntries: [MenuEntry] = FinderTag.standard.map { tag in
            let has = items.allSatisfy { $0.tags.contains(tag.name) }
            return .action((has ? "✓ " : "") + tag.name, "circle.fill") { [weak self] in
                self?.ops.toggleTag(tag.name, on: urls)
                self?.refreshAll()
            }
        }
        tagEntries.append(.divider)
        tagEntries.append(.action("Remove All Tags", "tag.slash") { [weak self] in
            self?.ops.clearTags(urls)
            self?.refreshAll()
        })
        e.append(.submenu("Tags", "tag", tagEntries))
        e.append(.divider)
        if let single, single.isFolder {
            e.append(.action("Open in Terminal", "terminal") { [weak self] in self?.openInTerminal(single.url) })
            e.append(.action("Add to Sidebar", "sidebar.left") { AppSettings.shared.addFavorite(single.url) })
        }
        e.append(.action("Get Info", "info.circle") { [weak self] in self?.showInspector = true })
        e.append(.divider)
        e.append(.action("Move to Trash", "trash") { [weak self] in self?.trash(urls) })
        return e
    }

    private func backgroundMenu(_ tab: BrowserTab) -> [MenuEntry] {
        var e: [MenuEntry] = []
        if !tab.isSearch {
            e.append(.action("New Folder", "folder.badge.plus") { [weak self] in self?.newFolder() })
            e.append(.submenu("New File", "doc.badge.plus", NewFileTemplate.all.map { t in
                .action(t.title, t.symbol) { [weak self] in self?.newFile(t) }
            }))
            e.append(.action("Paste", "doc.on.clipboard") { [weak self] in self?.paste() })
            e.append(.divider)
        }
        e.append(.submenu("View As", "eye", ViewMode.allCases.map { m in
            .action((tab.viewMode == m ? "✓ " : "") + m.title, m.symbol) { [weak self] in self?.setViewMode(m) }
        }))
        e.append(.submenu("Sort By", "arrow.up.arrow.down", SortKey.allCases.map { k in
            .action((tab.sort.key == k ? (tab.sort.ascending ? "↑ " : "↓ ") : "") + k.title, nil) {
                if tab.sort.key == k { tab.sort.ascending.toggle() } else { tab.sort = SortSpec(key: k, ascending: k == .name || k == .kind) }
            }
        }))
        e.append(.action(AppSettings.shared.showHidden ? "Hide Hidden Files" : "Show Hidden Files", "eye.slash") { [weak self] in self?.toggleHidden() })
        e.append(.divider)
        e.append(.action("Open in Terminal", "terminal") { [weak self] in self?.openInTerminal(tab.url) })
        e.append(.action("Copy Path", "link") { [weak self] in self?.copyPath([tab.url]) })
        e.append(.action("Add to Sidebar", "sidebar.left") { AppSettings.shared.addFavorite(tab.url) })
        e.append(.action("Get Info", "info.circle") { [weak self] in self?.showInspector = true })
        return e
    }

    private func openWithEntries(_ url: URL) -> [MenuEntry] {
        let ws = NSWorkspace.shared
        let defaultApp = ws.urlForApplication(toOpen: url)
        var apps = ws.urlsForApplications(toOpen: url)
        if let d = defaultApp { apps.removeAll { $0 == d }; apps.insert(d, at: 0) }
        var seen = Set<String>()
        var e: [MenuEntry] = []
        for app in apps.prefix(20) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name).inserted else { continue }
            e.append(.action(app == defaultApp ? "\(name) (default)" : name, nil) { [weak self] in self?.open([url], with: app) })
            if app == defaultApp && apps.count > 1 { e.append(.divider) }
        }
        return e.isEmpty ? [.action("No Applications", nil) {}] : e
    }

    func refreshAll() {
        for pane in panes.prefix(visiblePaneCount) { pane.current.reload() }
    }

    // MARK: Palette commands

    var paletteCommands: [(title: String, symbol: String, action: () -> Void)] {
        var c: [(String, String, () -> Void)] = [
            ("New Folder", "folder.badge.plus", { [weak self] in self?.newFolder() }),
            ("New Tab", "plus.square.on.square", { [weak self] in self?.newTab() }),
            ("Toggle Hidden Files", "eye.slash", { [weak self] in self?.toggleHidden() }),
            ("Toggle Inspector", "sidebar.right", { [weak self] in self?.showInspector.toggle() }),
            ("Toggle Sync Browsing", "arrow.left.arrow.right", { [weak self] in self?.syncBrowsing.toggle() }),
            ("Open in Terminal", "terminal", { [weak self] in self?.openInTerminal() }),
            ("Copy Path", "link", { [weak self] in self?.copyPath() }),
            ("Filter Current Folder", "line.3.horizontal.decrease", { [weak self] in self?.showFilter() }),
            ("Show Same Folder in Other Pane", "rectangle.on.rectangle", { [weak self] in self?.mirrorToOtherPane() }),
            ("Swap Panes", "arrow.left.arrow.right.square", { [weak self] in self?.swapPanes() }),
            ("Save Workspace…", "square.stack.3d.up", { [weak self] in self?.saveWorkspace() }),
            ("Undo Last Operation", "arrow.uturn.backward", { FileOperationCenter.shared.undoLast() }),
        ]
        for t in NewFileTemplate.all {
            c.append(("New \(t.title)", t.symbol, { [weak self] in self?.newFile(t) }))
        }
        for m in ViewMode.allCases {
            c.append(("View as \(m.title)", m.symbol, { [weak self] in self?.setViewMode(m) }))
        }
        for l in PaneLayout.allCases {
            c.append(("Layout: \(l.title)", l.symbol, { [weak self] in self?.layout = l }))
        }
        for w in AppSettings.shared.workspaces {
            c.append(("Workspace: \(w.name)", "square.stack.3d.up", { [weak self] in self?.restore(w) }))
        }
        if !targetURLs.isEmpty {
            c.append(("Compress Selection", "archivebox", { [weak self] in self?.compress() }))
            c.append(("Move Selection to Trash", "trash", { [weak self] in self?.trash() }))
            c.append(("Rename Selection…", "pencil", { [weak self] in self?.beginRename() }))
        }
        return c
    }
}

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}
