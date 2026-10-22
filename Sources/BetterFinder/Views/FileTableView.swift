import AppKit
import SwiftUI

/// The list view. Built on NSTableView for native type-select, multi-item drag, drop-on-folder,
/// inline rename and smooth scrolling of very large folders.
struct FileTableView: NSViewRepresentable {
    let tab: BrowserTab
    let workspace: Workspace
    let paneIndex: Int
    // Passed explicitly so SwiftUI re-runs updateNSView when they change.
    let items: [FileItem]
    let selection: Set<URL>
    let sort: SortSpec
    let renamingURL: URL?
    let scrollTarget: URL?
    let git: GitInfo?
    let accentHex: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileNSTableView()
        table.style = .inset
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []

        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat, alignRight: Bool = false) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name" || id == "kind")
            if alignRight { c.headerCell.alignment = .right }
            return c
        }
        // ForkLift-like defaults: Name, Size, Date Modified. Kind and Date Created are a
        // right-click on the header away.
        table.addTableColumn(column("name", "Name", width: 320, min: 160))
        table.addTableColumn(column("size", "Size", width: 76, min: 50, alignRight: true))
        table.addTableColumn(column("modified", "Date Modified", width: 112, min: 80))
        let kind = column("kind", "Kind", width: 120, min: 60)
        kind.isHidden = true
        table.addTableColumn(kind)
        let created = column("created", "Date Created", width: 112, min: 80)
        created.isHidden = true
        table.addTableColumn(created)

        for column in table.tableColumns {
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            column.headerCell.textColor = .secondaryLabelColor
        }
        let c = context.coordinator
        c.table = table
        table.delegate = c
        table.dataSource = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL, .png, .tiff])
        table.setDraggingSourceOperationMask([.copy, .move, .link, .delete], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu
        table.headerView?.menu = c.headerMenu()
        table.autosaveName = "BFFileTable.v4"
        table.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tab.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        tab.tableView = c.table
        let table = c.table!

        // A folder change mid-rename would end the edit and commit a half-typed name; hold the
        // reload until editing finishes (the coordinator reloads then).
        if c.editingURL == nil, c.items != items || c.git != git || c.accentHex != accentHex {
            c.items = items
            c.git = git
            c.accentHex = accentHex
            c.applyingSelection = true
            table.reloadData()
            c.applyingSelection = false
        }

        let wanted = NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)
        if table.sortDescriptors.first?.key != wanted.key || table.sortDescriptors.first?.ascending != wanted.ascending {
            c.applyingSort = true
            table.sortDescriptors = [wanted]
            c.applyingSort = false
        }

        let current = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
        if current != selection {
            c.applyingSelection = true
            table.selectRowIndexes(IndexSet(items.indices.filter { selection.contains(items[$0].url) }), byExtendingSelection: false)
            c.applyingSelection = false
        }

        if let target = scrollTarget, let row = items.firstIndex(where: { $0.url == target }) {
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { if tab.scrollTarget == target { tab.scrollTarget = nil } }
        }

        if let r = renamingURL, c.editingURL != r, items.contains(where: { $0.url == r }) {
            DispatchQueue.main.async {
                if let row = c.items.firstIndex(where: { $0.url == r }) { c.beginEditing(row: row) }
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FileTableView
        var items: [FileItem] = []
        var git: GitInfo?
        var accentHex = ""
        weak var table: NSTableView!
        var applyingSelection = false
        var applyingSort = false
        var editingURL: URL?
        private var editCancelled = false
        private var draggedURLs: [URL] = []

        init(_ parent: FileTableView) { self.parent = parent }

        private var tab: BrowserTab { parent.tab }
        private var ws: Workspace { parent.workspace }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AccentRowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < items.count else { return nil }
            let item = items[row]
            let id = column.identifier
            if id.rawValue == "name" {
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NameCellView) ?? NameCellView(identifier: id)
                cell.configure(item, git: git?.status(for: item.url))
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView) ?? TextCellView(identifier: id)
            switch id.rawValue {
            case "modified": cell.set(Fmt.shortDate(item.modified), alignRight: false)
            case "created": cell.set(Fmt.shortDate(item.created), alignRight: false)
            case "size": cell.set(item.isDirectory ? "--" : Fmt.size(item.size), alignRight: true)
            default: cell.set(item.kind, alignRight: false)
            }
            cell.alphaValue = item.isHidden ? 0.5 : 1
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn == nil || tableColumn?.identifier.rawValue == "name", row < items.count else { return nil }
            return items[row].name
        }

        // MARK: Selection & sorting

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection else { return }
            let sel = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
            if tab.selection != sel { tab.selection = sel }
            if let row = table.selectedRowIndexes.last, row < items.count { tab.anchor = items[row].url }
            ws.activate(parent.paneIndex)
            if let editing = editingURL, !sel.contains(editing) { table.window?.makeFirstResponder(table) }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  column.identifier.rawValue != "name" else { return }
            (table as? FileNSTableView)?.fitNameColumn()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let d = tableView.sortDescriptors.first, let key = SortKey(rawValue: d.key ?? "") else { return }
            tab.sort = SortSpec(key: key, ascending: d.ascending)
        }

        @objc func doubleClicked(_ sender: Any?) {
            let row = table.clickedRow
            guard row >= 0, row < items.count else { return }
            ws.open([items[row].url])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            let row = table.clickedRow
            var urls: [URL] = []
            if row >= 0, row < items.count {
                if table.selectedRowIndexes.contains(row) {
                    urls = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
                } else {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    urls = [items[row].url]
                }
            }
            ws.activate(parent.paneIndex)
            MenuEntry.populate(menu, with: ws.menuEntries(for: urls, in: tab))
        }

        func headerMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = NSUserInterfaceItemIdentifier("header")
            return menu
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard menu.identifier?.rawValue == "header" else { return }
            menu.removeAllItems()
            for column in table.tableColumns where column.identifier.rawValue != "name" {
                let item = ClosureMenuItem(title: column.title) { [weak self] in
                    column.isHidden.toggle()
                    (self?.table as? FileNSTableView)?.fitNameColumn()
                }
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        // MARK: Drag source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < items.count else { return nil }
            return items[row].url as NSURL
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            draggedURLs = rowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if operation == .delete { ws.ops.trash(draggedURLs) }
            draggedURLs = []
        }

        // MARK: Drop target

        private func destination(for row: Int, _ op: NSTableView.DropOperation) -> URL? {
            if op == .on, row >= 0, row < items.count, items[row].isFolder { return items[row].url }
            return tab.isSearch ? nil : tab.url
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            var target: URL?
            if op == .on, row >= 0, row < items.count, items[row].isFolder, !urls.contains(items[row].url) {
                target = items[row].url
            } else {
                guard !tab.isSearch else { return [] }
                tableView.setDropRow(-1, dropOperation: .on)
                target = tab.url
            }
            guard let target else { return [] }
            if urls.isEmpty { return NSImage.canInit(with: info.draggingPasteboard) ? .copy : [] }
            if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL }) { return [] }
            let flags = NSEvent.modifierFlags
            if flags.contains(.option) { return .copy }
            if flags.contains(.command) { return .move }
            return FileSystem.sameVolume(urls[0], target) ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            guard let dest = destination(for: row, op) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if urls.isEmpty, let image = NSImage(pasteboard: info.draggingPasteboard) {
                return ws.ops.savePasted(image: image, in: dest) != nil
            }
            guard !urls.isEmpty else { return false }
            ws.drop(urls, into: dest)
            return true
        }

        // MARK: Inline rename

        func beginEditing(row: Int) {
            guard row < items.count, let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView,
                  let field = cell.textField else { return }
            let item = items[row]
            editingURL = item.url
            editCancelled = false
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            field.stringValue = item.name
            table.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let base = item.isDirectory ? item.name : (item.name as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                table.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let url = editingURL else { return }
            field.isEditable = false
            field.isSelectable = false
            editingURL = nil
            // Catch up on any folder changes that arrived while editing.
            if items != parent.items {
                items = parent.items
                applyingSelection = true
                table.reloadData()
                applyingSelection = false
            }
            if editCancelled {
                field.stringValue = url.lastPathComponent
                ws.cancelRename(in: tab)
            } else {
                ws.commitRename(in: tab, url: url, newName: field.stringValue)
            }
        }
    }
}

final class FileNSTableView: NSTableView {
    private var fitting = false

    override func drawBackground(inClipRect clipRect: NSRect) {}

    /// The Name column absorbs whatever width the pane has left, so other columns never get
    /// pushed off the edge and names get every spare point.
    func fitNameColumn() {
        guard !fitting, let clip = enclosingScrollView?.contentView,
              let name = tableColumns.first(where: { $0.identifier.rawValue == "name" }) else { return }
        fitting = true
        defer { fitting = false }
        let visible = tableColumns.filter { !$0.isHidden }
        let others = visible.filter { $0 !== name }.reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = intercellSpacing.width * CGFloat(visible.count)
        let insets: CGFloat = style == .inset ? 20 : 0
        let target = max(name.minWidth, clip.bounds.width - others - spacing - insets)
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        fitNameColumn()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.fitNameColumn() }
    }
}

final class AccentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let accent = AppSettings.shared.nsAccent
        let color = isEmphasized ? accent : accent.withAlphaComponent(0.18)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 7, yRadius: 7).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

final class TextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, alignRight: Bool) {
        textField?.stringValue = text
        textField?.alignment = alignRight ? .right : .left
        textField?.font = alignRight ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
    }
}

final class NameCellView: NSTableCellView {
    private let badge = NSHostingView(rootView: CellBadges(tags: [], git: nil, symlink: false))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.focusRingType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A stack detaches hidden views, so the name gets the full width when there's no badge.
        let stack = NSStackView(views: [icon, field, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(6, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = field
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem, git: GitFileStatus?) {
        imageView?.image = IconCache.icon(for: item.url)
        textField?.stringValue = item.name
        textField?.isEditable = false
        imageView?.alphaValue = item.isHidden ? 0.5 : 1
        textField?.alphaValue = item.isHidden ? 0.6 : 1
        badge.rootView = CellBadges(tags: item.tags, git: git, symlink: item.isSymlink)
        badge.isHidden = item.tags.isEmpty && git == nil && !item.isSymlink
    }
}

struct CellBadges: View {
    let tags: [String]
    let git: GitFileStatus?
    let symlink: Bool

    var body: some View {
        HStack(spacing: 4) {
            if symlink {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !tags.isEmpty {
                HStack(spacing: -3) {
                    ForEach(tags.prefix(4), id: \.self) { t in
                        Circle()
                            .fill(FinderTag.color(for: t))
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                            .frame(width: 9, height: 9)
                    }
                }
            }
            if let git {
                Text(git.letter)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: git.nsColor))
                    .frame(width: 14, height: 14)
                    .background(Color(nsColor: git.nsColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 3.5))
            }
        }
        .fixedSize()
    }
}
