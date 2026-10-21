import AppKit
import SwiftUI

extension Notification.Name {
    static let displaySettingsChanged = Notification.Name("BFDisplaySettingsChanged")
}

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var symbol: String?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { FileManager.default.displayName(atPath: path) }
    var resolvedSymbol: String { symbol ?? Favorite.defaultSymbol(for: path) }

    static func defaultSymbol(for path: String) -> String {
        let home = NSHomeDirectory()
        switch path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "square.grid.2x2"
        case home + "/Pictures": return "photo"
        case home + "/Music": return "music.note"
        case home + "/Movies": return "film"
        default:
            if path.contains("com~apple~CloudDocs") { return "icloud" }
            return "folder"
        }
    }
}

struct SavedWorkspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var layout: PaneLayout
    var panes: [[String]]
    var showInspector: Bool
}

@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    var showHidden: Bool { didSet { d.set(showHidden, forKey: "showHidden"); changed() } }
    var foldersFirst: Bool { didSet { d.set(foldersFirst, forKey: "foldersFirst"); changed() } }
    var accentHex: String { didSet { d.set(accentHex, forKey: "accentHex"); changed() } }
    var tintWindow: Bool { didSet { d.set(tintWindow, forKey: "tintWindow") } }
    var terminalBundleID: String { didSet { d.set(terminalBundleID, forKey: "terminalBundleID") } }
    var globalHotKey: Bool { didSet { d.set(globalHotKey, forKey: "globalHotKey"); HotKeyManager.shared.refresh() } }
    var favorites: [Favorite] { didSet { save(favorites, "favorites") } }
    var workspaces: [SavedWorkspace] { didSet { save(workspaces, "workspaces") } }
    var recentFolders: [String] { didSet { d.set(recentFolders, forKey: "recentFolders") } }

    var accent: Color { Color(hex: accentHex) }
    var nsAccent: NSColor { NSColor(hex: accentHex) ?? .controlAccentColor }

    private init() {
        d.register(defaults: [
            "showHidden": false,
            "foldersFirst": true,
            "accentHex": "#E8546A",
            "tintWindow": true,
            "terminalBundleID": "com.apple.Terminal",
            "globalHotKey": true,
        ])
        showHidden = d.bool(forKey: "showHidden")
        foldersFirst = d.bool(forKey: "foldersFirst")
        accentHex = d.string(forKey: "accentHex") ?? "#E8546A"
        tintWindow = d.bool(forKey: "tintWindow")
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
        globalHotKey = d.bool(forKey: "globalHotKey")
        recentFolders = d.stringArray(forKey: "recentFolders") ?? []
        workspaces = Self.load("workspaces") ?? []
        favorites = Self.load("favorites") ?? Self.defaultFavorites()
    }

    private static func defaultFavorites() -> [Favorite] {
        let home = NSHomeDirectory()
        var paths = [home, "/Applications", home + "/Desktop", home + "/Documents", home + "/Downloads",
                     home + "/Pictures", home + "/Music", home + "/Movies"]
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { paths.append(icloud) }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }.map { Favorite(path: $0) }
    }

    func addFavorite(_ url: URL) {
        guard !favorites.contains(where: { $0.path == url.path }) else { return }
        favorites.append(Favorite(path: url.path))
    }

    func noteVisit(_ url: URL) {
        var r = recentFolders.filter { $0 != url.path }
        r.insert(url.path, at: 0)
        recentFolders = Array(r.prefix(30))
    }

    private func changed() {
        NotificationCenter.default.post(name: .displaySettingsChanged, object: nil)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        d.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
