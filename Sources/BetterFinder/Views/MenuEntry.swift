import AppKit
import SwiftUI

/// A menu description that renders both as an AppKit NSMenu (list view) and SwiftUI menu (grid/columns).
indirect enum MenuEntry {
    case action(String, String?, () -> Void)
    case submenu(String, String?, [MenuEntry])
    case divider
    /// The color tags: a row of dots in AppKit menus, a submenu of colored items in SwiftUI ones.
    case tags(TagMenuState, toggle: (String) -> Void, clear: () -> Void)

    static func populate(_ menu: NSMenu, with entries: [MenuEntry]) {
        menu.removeAllItems()
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case let .action(title, symbol, action):
                let item = ClosureMenuItem(title: title, handler: action)
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            case let .submenu(title, symbol, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                let sub = NSMenu(title: title)
                populate(sub, with: children)
                item.submenu = sub
                menu.addItem(item)
            case let .tags(state, toggle, clear):
                let item = NSMenuItem()
                item.view = TagRowView(state: state, toggle: toggle, clear: clear)
                menu.addItem(item)
            }
        }
    }
}

/// Which tags a set of items carries: every item (checkmark) or only some (dash).
struct TagMenuState {
    var all: Set<String> = []
    var some: Set<String> = []

    init(items: [FileItem]) {
        for tag in FinderTag.standard {
            let n = items.filter { $0.tags.contains(tag.name) }.count
            if n == items.count, n > 0 { all.insert(tag.name) } else if n > 0 { some.insert(tag.name) }
        }
    }

    var isEmpty: Bool { all.isEmpty && some.isEmpty }

    /// A colored dot, marked with a checkmark or dash. Not a template, so menus keep its color.
    static func dot(_ tag: FinderTag, all: Bool, some: Bool, size: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(tag.color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            if all || some, let mark = NSImage(systemSymbolName: all ? "checkmark" : "minus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.55, weight: .heavy).applying(.init(paletteColors: [.white]))) {
                let m = mark.size
                mark.draw(in: NSRect(x: rect.midX - m.width / 2, y: rect.midY - m.height / 2, width: m.width, height: m.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Finder-style row of tag dots inside a context menu; a click toggles that tag and closes the menu.
final class TagRowView: NSView {
    private let toggle: (String) -> Void
    private let clear: () -> Void

    init(state: TagMenuState, toggle: @escaping (String) -> Void, clear: @escaping () -> Void) {
        self.toggle = toggle
        self.clear = clear
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        var buttons: [NSButton] = FinderTag.standard.map { tag in
            let b = NSButton(image: TagMenuState.dot(tag, all: state.all.contains(tag.name), some: state.some.contains(tag.name), size: 18),
                             target: self, action: #selector(tagClicked(_:)))
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(tag.name)
            b.toolTip = tag.name
            b.setButtonType(.momentaryChange)
            return b
        }
        if !state.isEmpty {
            let b = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Remove All Tags")!,
                             target: self, action: #selector(clearClicked))
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "Remove All Tags"
            buttons.append(b)
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tagClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        toggle(name)
    }

    @objc private func clearClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        clear()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

struct MenuEntriesView: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .divider:
                Divider()
            case let .action(title, symbol, action):
                Button(action: action) {
                    if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                }
            case let .submenu(title, symbol, children):
                Menu {
                    AnyView(MenuEntriesView(entries: children))
                } label: {
                    if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                }
            case let .tags(state, toggle, clear):
                // SwiftUI menus can't host custom views, so the dots become a submenu here.
                Menu {
                    ForEach(FinderTag.standard) { tag in
                        Button { toggle(tag.name) } label: {
                            Label {
                                Text(tag.name)
                            } icon: {
                                Image(nsImage: TagMenuState.dot(tag, all: state.all.contains(tag.name), some: state.some.contains(tag.name)))
                            }
                        }
                    }
                    if !state.isEmpty {
                        Divider()
                        Button(action: clear) { Label("Remove All Tags", systemImage: "tag.slash") }
                    }
                } label: {
                    Label("Tags", systemImage: "tag")
                }
            }
        }
    }
}
