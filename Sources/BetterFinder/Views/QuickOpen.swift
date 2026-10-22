import AppKit
import SwiftUI

struct PaletteItem: Identifiable {
    enum Kind {
        case location(URL)
        case command(() -> Void)
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String?
    let kind: Kind
    var badge: String?

    var url: URL? {
        if case .location(let u) = kind { return u }
        return nil
    }
}

/// "Go to Folder" + search + command palette in one field.
/// - Starts with `/` or `~`: path navigation with completion (⇥).
/// - Anything else: commands, favorites, recent folders, then Spotlight file search.
@Observable
final class QuickOpenModel {
    var query = "" { didSet { if query != oldValue { update() } } }
    var results: [PaletteItem] = []
    var selectedIndex = 0
    var isSearching = false
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private let spotlight = SpotlightSearch()
    @ObservationIgnored private var pending: DispatchWorkItem?

    var isPathMode: Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    func reset(prefill: String) {
        query = prefill
        selectedIndex = 0
        update()
    }

    func update() {
        pending?.cancel()
        spotlight.cancel()
        isSearching = false
        selectedIndex = 0
        if isPathMode {
            results = pathResults()
            return
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        var local: [PaletteItem] = []
        let settings = AppSettings.shared
        if q.isEmpty {
            local += settings.recentFolders.prefix(8).map { path in
                let url = URL(fileURLWithPath: path)
                return PaletteItem(title: FileSystem.displayName(url), subtitle: abbreviate(path), symbol: nil, kind: .location(url), badge: "Recent")
            }
            local += settings.favorites.map { PaletteItem(title: $0.name, subtitle: abbreviate($0.path), symbol: nil, kind: .location($0.url), badge: "Favorite") }
            results = local
            return
        }
        if let ws = workspace {
            local += ws.paletteCommands
                .compactMap { c in Self.score(c.title, q).map { (c, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(6)
                .map { c, _ in PaletteItem(title: c.title, subtitle: "Command", symbol: c.symbol, kind: .command(c.action), badge: "Command") }
        }
        local += settings.favorites
            .filter { Self.score($0.name, q) != nil }
            .map { PaletteItem(title: $0.name, subtitle: abbreviate($0.path), symbol: nil, kind: .location($0.url), badge: "Favorite") }
        local += settings.recentFolders
            .filter { Self.score(($0 as NSString).lastPathComponent, q) != nil }
            .prefix(5)
            .map { path in
                let url = URL(fileURLWithPath: path)
                return PaletteItem(title: FileSystem.displayName(url), subtitle: abbreviate(path), symbol: nil, kind: .location(url), badge: "Recent")
            }
        results = local
        guard q.count >= 2 else { return }
        isSearching = true
        let work = DispatchWorkItem { [weak self] in self?.runSpotlight(q, local: local) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func runSpotlight(_ q: String, local: [PaletteItem]) {
        let words = q.split(separator: " ").map(String.init)
        let query = words.map { "kMDItemFSName == \"*\(SpotlightSearch.escape($0))*\"cd" }.joined(separator: " && ")
        let scopes = [FileSystem.home.path, "/Applications"]
        let seen = Set(local.compactMap { $0.url?.standardizedFileURL.path })
        spotlight.run(query: query, scopes: scopes, limit: 600) { [weak self] urls, finished in
            guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
            let lower = q.lowercased()
            let candidates = urls
                .filter { u in
                    let p = u.path
                    let cloud = p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
                    return !seen.contains(p) && (cloud || !p.contains("/Library/")) && !p.contains("/.") && !p.contains("/node_modules/")
                }
                .map { u -> (URL, Int) in
                    let name = u.lastPathComponent.lowercased()
                    var s = 0
                    if name == lower { s += 100 }
                    if name.hasPrefix(lower) { s += 40 }
                    if FileSystem.isDirectory(u) { s += 15 }
                    s -= u.pathComponents.count
                    return (u, s)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(40)
            let found = candidates.map { u, _ in
                PaletteItem(title: u.lastPathComponent, subtitle: self.abbreviate(u.deletingLastPathComponent().path), symbol: nil, kind: .location(u))
            }
            let previous = self.selectedIndex
            self.results = local + found
            self.selectedIndex = min(previous, max(0, self.results.count - 1))
            if finished { self.isSearching = false }
        }
    }

    private func pathResults() -> [PaletteItem] {
        let expanded = (query as NSString).expandingTildeInPath
        let endsWithSlash = query.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let partial = endsWithSlash ? "" : (expanded as NSString).lastPathComponent.lowercased()
        var out: [PaletteItem] = []
        if !endsWithSlash, FileManager.default.fileExists(atPath: expanded) {
            let u = URL(fileURLWithPath: expanded)
            out.append(PaletteItem(title: FileSystem.displayName(u), subtitle: abbreviate(expanded), symbol: nil, kind: .location(u), badge: "Go"))
        }
        let showHidden = partial.hasPrefix(".") || AppSettings.shared.showHidden
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
            .filter { (showHidden || !$0.hasPrefix(".")) && (partial.isEmpty || $0.lowercased().hasPrefix(partial)) && $0.lowercased() != partial }
            .map { URL(fileURLWithPath: parent).appendingPathComponent($0) }
            .sorted { a, b in
                let da = FileSystem.isDirectory(a), db = FileSystem.isDirectory(b)
                return da != db ? da : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            .prefix(80)
        out += children.map { PaletteItem(title: $0.lastPathComponent, subtitle: abbreviate($0.path), symbol: nil, kind: .location($0)) }
        return out
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Case-insensitive subsequence match; higher is better. nil = no match.
    static func score(_ text: String, _ query: String) -> Int? {
        let t = text.lowercased(), q = query.lowercased()
        if t.hasPrefix(q) { return 100 - t.count }
        if t.contains(q) { return 60 - t.count }
        var ti = t.startIndex
        for ch in q {
            guard let found = t[ti...].firstIndex(of: ch) else { return nil }
            ti = t.index(after: found)
        }
        return 20 - t.count
    }

    // MARK: Keys

    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76: activate(alternate: mods.contains(.command)); return true
        case 53: workspace?.closeQuickOpen(); return true
        case 48: complete(); return true
        default:
            if mods == .control, e.charactersIgnoringModifiers == "n" { move(1); return true }
            if mods == .control, e.charactersIgnoringModifiers == "p" { move(-1); return true }
            return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + d + results.count) % results.count
    }

    private func complete() {
        guard results.indices.contains(selectedIndex), let url = results[selectedIndex].url else { return }
        var path = abbreviate(url.path)
        if FileSystem.isDirectory(url) { path += "/" }
        query = path
    }

    func activate(alternate: Bool) {
        guard results.indices.contains(selectedIndex) else {
            if isPathMode, let ws = workspace {
                let url = FileSystem.expandPath(query, relativeTo: ws.activeTab.url)
                if FileSystem.isDirectory(url) { ws.go(to: url); ws.closeQuickOpen() } else { NSSound.beep() }
            }
            return
        }
        perform(results[selectedIndex], alternate: alternate)
    }

    func perform(_ item: PaletteItem, alternate: Bool) {
        guard let ws = workspace else { return }
        ws.closeQuickOpen()
        switch item.kind {
        case .command(let action):
            DispatchQueue.main.async(execute: action)
        case .location(let url):
            if alternate {
                NSWorkspace.shared.open(url)
            } else if FileSystem.isDirectory(url) && !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                ws.go(to: url)
            } else {
                ws.reveal(url)
            }
        }
    }
}

struct QuickOpenView: View {
    @Environment(Workspace.self) private var ws
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = ws.quickOpen
        let accent = AppSettings.shared.accent
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.isPathMode ? "folder" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                TextField("Go to folder, search files, or run a command…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if !model.results.isEmpty {
                Divider()
                // Rows are identified by their result (never by position) so a new result set or a
                // moved selection always redraws; a plain VStack because there are at most ~50 rows.
                let selectedID = model.results.indices.contains(model.selectedIndex) ? model.results[model.selectedIndex].id : nil
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.results) { item in
                                PaletteRow(item: item, selected: item.id == selectedID, accent: accent)
                                    .id(item.id)
                                    .onTapGesture {
                                        if let i = model.results.firstIndex(where: { $0.id == item.id }) { model.selectedIndex = i }
                                        model.perform(item, alternate: NSEvent.modifierFlags.contains(.command))
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Hint(keys: "↩", text: "Open")
                Hint(keys: "⌘↩", text: "Open with app")
                Hint(keys: "⇥", text: "Complete")
                Hint(keys: "~/ or /", text: "Paths")
                Spacer()
                Hint(keys: "⌘⇧↩", text: "From anywhere")
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        .onAppear { focused = true }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? .white : accent)
                } else if let url = item.url {
                    Image(nsImage: IconCache.icon(for: url)).resizable()
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07)))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? accent : .clear))
        .contentShape(Rectangle())
    }
}

struct Hint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
