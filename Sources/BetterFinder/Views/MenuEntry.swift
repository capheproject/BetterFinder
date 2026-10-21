import AppKit
import SwiftUI

/// A menu description that renders both as an AppKit NSMenu (list view) and SwiftUI menu (grid/columns).
indirect enum MenuEntry {
    case action(String, String?, () -> Void)
    case submenu(String, String?, [MenuEntry])
    case divider

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
            }
        }
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
            }
        }
    }
}
