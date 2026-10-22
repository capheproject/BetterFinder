import AppKit
import SwiftUI

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case list, grid, columns
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: "List"
        case .grid: "Icons"
        case .columns: "Columns"
        }
    }
    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

enum SortKey: String, Codable, CaseIterable {
    case name, modified, size, kind, created
    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        case .created: "Date Created"
        }
    }
}

struct SortSpec: Equatable, Codable {
    var key: SortKey = .name
    var ascending = true
}

/// One browsing location: a folder (or a set of search results) with its own history and selection.
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    private(set) var url: URL
    private(set) var items: [FileItem] = []
    private(set) var displayed: [FileItem] = []
    var selection: Set<URL> = [] {
        didSet { if selection != oldValue { onSelectionChange?(self) } }
    }
    var sort = SortSpec() { didSet { if sort != oldValue { refreshDisplayed() } } }
    var viewMode: ViewMode = .list
    var iconSize: Double = 72
    var filterText = "" { didSet { if filterText != oldValue { filterChanged() } } }
    var isFilterVisible = false
    var filterRecursive = false { didSet { if filterRecursive != oldValue { filterChanged() } } }
    private(set) var searchTitle: String?
    private var results: [FileItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var git: GitInfo?
    var renamingURL: URL?
    var scrollTarget: URL?
    var focusRequest = 0
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    @ObservationIgnored var gridColumns = 1
    @ObservationIgnored var anchor: URL?
    @ObservationIgnored var onNavigate: ((BrowserTab) -> Void)?
    @ObservationIgnored var onSelectionChange: ((BrowserTab) -> Void)?
    @ObservationIgnored weak var tableView: NSTableView?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedURL: URL?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let spotlight = SpotlightSearch()
    @ObservationIgnored private var selectFirstOnLoad = false
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(url: URL, viewMode: ViewMode = .list) {
        self.url = url.standardizedFileURL
        self.viewMode = viewMode
        settingsObserver = NotificationCenter.default.addObserver(forName: .displaySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplayed()
        }
        load()
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        searchTask?.cancel()
        spotlight.cancel()
    }

    var title: String { searchTitle ?? FileSystem.displayName(url) }
    var isSearch: Bool { searchTitle != nil || usingResults }
    var selectedItems: [FileItem] { displayed.filter { selection.contains($0.url) } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.path != "/" || searchTitle != nil }
    private var usingResults: Bool { searchTitle != nil || (filterRecursive && !filterText.isEmpty) }

    // MARK: Navigation

    func navigate(to newURL: URL, select: URL? = nil, record: Bool = true) {
        let target = newURL.standardizedFileURL
        if target == url && searchTitle == nil {
            if let select { selection = [select]; scrollTarget = select }
            return
        }
        if record {
            backStack.append(url)
            forwardStack.removeAll()
        }
        url = target
        resetTransient()
        load(select: select)
        onNavigate?(self)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        let from = url
        forwardStack.append(url)
        navigate(to: prev, select: from.deletingLastPathComponent() == prev ? from : nil, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        navigate(to: next, record: false)
    }

    func goUp() {
        if searchTitle != nil {
            navigate(to: url)
            return
        }
        guard url.path != "/" else { return }
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    func enterSelectedFolder() {
        guard let item = selectedItems.first, item.isFolder else { return }
        selectFirstOnLoad = true
        navigate(to: item.url)
    }

    private func resetTransient() {
        spotlight.cancel()
        searchTask?.cancel()
        searchTitle = nil
        results = []
        if !filterText.isEmpty { filterText = "" }
        isFilterVisible = false
        filterRecursive = false
        selection = []
        renamingURL = nil
        git = nil
        anchor = nil
    }

    // MARK: Loading

    func load(select: URL? = nil, rename: Bool = false) {
        let target = url
        let token = UUID()
        loadToken = token
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try FileSystem.list(target) }
            await MainActor.run {
                guard let self, self.loadToken == token else { return }
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.items = list
                    self.loadError = nil
                case .failure(let error):
                    self.items = []
                    self.loadError = (error as NSError).code == NSFileReadNoPermissionError
                        ? "BetterFinder doesn’t have permission to see this folder.\nGrant Full Disk Access in System Settings › Privacy & Security."
                        : error.localizedDescription
                }
                self.refreshDisplayed()
                if let select {
                    self.selection = [select]
                    self.anchor = select
                    self.scrollTarget = select
                    if rename { self.renamingURL = select }
                } else if self.selectFirstOnLoad, let first = self.displayed.first {
                    self.selection = [first.url]
                    self.scrollTarget = first.url
                } else {
                    let present = Set(self.displayed.map(\.url))
                    let kept = self.selection.intersection(present)
                    if kept != self.selection { self.selection = kept }
                }
                self.selectFirstOnLoad = false
            }
        }
        if watchedURL != target {
            // Opening a folder can block (a privacy prompt for Desktop/Documents, a stalled network
            // or cloud volume), so never do it on the main thread.
            watchedURL = target
            watcher = nil
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let w = DirectoryWatcher(url: target) { [weak self] in self?.reloadFromWatcher() }
                DispatchQueue.main.async {
                    guard let self, self.watchedURL == target else { return }
                    self.watcher = w
                }
            }
        }
        Task { [weak self] in
            let info = await GitService.info(for: target)
            guard let self, self.url == target, self.git != info else { return }
            self.git = info
        }
    }

    private func reloadFromWatcher() {
        guard searchTitle == nil else { return }
        load()
    }

    func reload() {
        if searchTitle == nil && !usingResults { load() } else { filterChanged() }
    }

    // MARK: Sorting & filtering

    func refreshDisplayed() {
        let settings = AppSettings.shared
        var list = usingResults ? results : items
        if !settings.showHidden { list = list.filter { !$0.isHidden } }
        if !filterText.isEmpty && !usingResults {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        let sort = self.sort
        let foldersFirst = settings.foldersFirst
        list.sort { a, b in
            if foldersFirst && a.isFolder != b.isFolder { return a.isFolder }
            var r = Self.compare(a, b, sort.key)
            if r == .orderedSame && sort.key != .name { r = a.name.localizedStandardCompare(b.name) }
            return sort.ascending ? r == .orderedAscending : r == .orderedDescending
        }
        if list != displayed { displayed = list }
    }

    static func compare(_ a: FileItem, _ b: FileItem, _ key: SortKey) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .modified: return cmp(a.modified, b.modified)
        case .created: return cmp(a.created, b.created)
        case .size: return cmp(a.size, b.size)
        case .kind: return a.kind.localizedStandardCompare(b.kind)
        }
    }

    private func filterChanged() {
        searchTask?.cancel()
        guard filterRecursive && !filterText.isEmpty else {
            if searchTitle == nil { results = []; isLoading = false }
            refreshDisplayed()
            return
        }
        let query = filterText, root = url, includeHidden = AppSettings.shared.showHidden
        isLoading = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            let found = FileSystem.search(in: root, query: query, includeHidden: includeHidden, limit: 3000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.filterText == query, self.url == root else { return }
                self.results = found
                self.isLoading = false
                self.refreshDisplayed()
            }
        }
    }

    func closeFilter() {
        isFilterVisible = false
        filterRecursive = false
        filterText = ""
    }

    // MARK: Spotlight-backed listings (tags, saved searches)

    func showSpotlight(title: String, query: String) {
        if searchTitle == nil {
            backStack.append(url)
            forwardStack.removeAll()
        }
        searchTitle = title
        results = []
        selection = []
        isLoading = true
        refreshDisplayed()
        spotlight.run(query: query, scopes: [FileSystem.home.path], limit: 3000) { [weak self] urls, finished in
            guard let self, self.searchTitle == title else { return }
            let items = urls.compactMap(FileItem.init(url:))
            self.results = items
            if finished { self.isLoading = false }
            self.refreshDisplayed()
        }
    }
}

@Observable
final class Pane: Identifiable {
    let id = UUID()
    var tabs: [BrowserTab]
    var activeTabIndex = 0
    @ObservationIgnored var configure: ((BrowserTab) -> Void)?

    init(urls: [URL]) {
        tabs = (urls.isEmpty ? [FileSystem.home] : urls).map { BrowserTab(url: $0) }
    }

    var current: BrowserTab { tabs[min(activeTabIndex, tabs.count - 1)] }

    func addTab(url: URL, activate: Bool = true) {
        let tab = BrowserTab(url: url, viewMode: current.viewMode)
        configure?(tab)
        let idx = min(activeTabIndex + 1, tabs.count)
        tabs.insert(tab, at: idx)
        if activate { activeTabIndex = idx }
    }

    /// Returns false when the last tab cannot be closed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if activeTabIndex >= index && activeTabIndex > 0 { activeTabIndex -= 1 }
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        return true
    }
}
