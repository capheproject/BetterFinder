import AppKit
import SwiftUI

// MARK: - Activity & Footprints

struct ActivityPanel: View {
    var body: some View {
        let ops = FileOperationCenter.shared
        VStack(alignment: .leading, spacing: 0) {
            if !ops.activities.isEmpty {
                Text("Activity").font(.system(size: 12, weight: .semibold)).padding([.horizontal, .top], 14)
                VStack(spacing: 10) {
                    ForEach(ops.activities) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: a.error != nil ? "exclamationmark.triangle.fill" : (a.finished ? "checkmark.circle.fill" : a.symbol))
                                    .foregroundStyle(a.error != nil ? .orange : (a.finished ? .green : .secondary))
                                Text(a.title).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(a.completed)/\(a.total)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if !a.finished {
                                ProgressView(value: a.fraction)
                                Text(a.currentItem).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let e = a.error { Text(e).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2) }
                        }
                    }
                }
                .padding(14)
                Divider()
            }
            HStack {
                Text("Footprints").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Every operation, revertible").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 6)
            if ops.footprints.isEmpty {
                Text("Nothing yet. Copies, moves, renames and deletions show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(ops.footprints) { f in
                            HStack(spacing: 8) {
                                Image(systemName: f.symbol).frame(width: 18).foregroundStyle(AppSettings.shared.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.title).font(.system(size: 12)).lineLimit(1).strikethrough(f.undone)
                                    Text(f.date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if f.undo != nil {
                                    Button(f.undone ? "Undone" : "Undo") { ops.undo(f.id) }
                                        .controlSize(.small)
                                        .disabled(f.undone)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
        .padding(.bottom, 8)
    }
}

struct ActivityButton: View {
    @State private var show = false

    var body: some View {
        let ops = FileOperationCenter.shared
        Button { show.toggle() } label: {
            if ops.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }
        }
        .help("Activity & Footprints")
        .popover(isPresented: $show, arrowEdge: .bottom) { ActivityPanel() }
    }
}

struct ToastView: View {
    var body: some View {
        if let message = FileOperationCenter.shared.toastMessage {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(message)
        }
    }
}

// MARK: - Batch rename

struct BatchRenameView: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss

    enum Numbering: String, CaseIterable { case none = "None", prefix = "Before Name", suffix = "After Name" }
    enum CaseMode: String, CaseIterable { case keep = "Keep", lower = "lowercase", upper = "UPPERCASE", title = "Title Case" }

    @State private var find = ""
    @State private var replace = ""
    @State private var useRegex = false
    @State private var ignoreCase = true
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var numbering = Numbering.none
    @State private var start = 1
    @State private var digits = 2
    @State private var separator = " "
    @State private var caseMode = CaseMode.keep
    @State private var includeExtension = false

    private func newName(_ url: URL, index: Int) -> String {
        let full = url.lastPathComponent
        let isDir = FileSystem.isDirectory(url)
        let ext = (isDir || includeExtension) ? "" : url.pathExtension
        var base = ext.isEmpty ? full : (full as NSString).deletingPathExtension
        if !find.isEmpty {
            if useRegex {
                if let re = try? NSRegularExpression(pattern: find, options: ignoreCase ? [.caseInsensitive] : []) {
                    base = re.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replace)
                }
            } else {
                base = base.replacingOccurrences(of: find, with: replace, options: ignoreCase ? [.caseInsensitive] : [])
            }
        }
        switch caseMode {
        case .keep: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        }
        base = prefix + base + suffix
        let n = String(format: "%0\(max(1, digits))d", start + index)
        switch numbering {
        case .none: break
        case .prefix: base = n + separator + base
        case .suffix: base = base + separator + n
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    var body: some View {
        let preview = urls.enumerated().map { ($0.element, newName($0.element, index: $0.offset)) }
        let names = preview.map(\.1)
        let duplicates = Set(names.filter { n in names.filter { $0 == n }.count > 1 })
        let changed = preview.filter { $0.0.lastPathComponent != $0.1 }.count
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 18))
                    .foregroundStyle(AppSettings.shared.accent)
                Text("Rename \(urls.count) Items").font(.system(size: 16, weight: .semibold))
            }
            Form {
                Section {
                    TextField("Find", text: $find)
                    TextField("Replace with", text: $replace)
                    HStack {
                        Toggle("Regular expression", isOn: $useRegex)
                        Toggle("Ignore case", isOn: $ignoreCase)
                    }
                }
                Section {
                    HStack {
                        TextField("Add before", text: $prefix)
                        TextField("Add after", text: $suffix)
                    }
                    Picker("Case", selection: $caseMode) { ForEach(CaseMode.allCases, id: \.self) { Text($0.rawValue) } }
                    Picker("Numbering", selection: $numbering) { ForEach(Numbering.allCases, id: \.self) { Text($0.rawValue) } }
                    if numbering != .none {
                        HStack {
                            Stepper("Start at \(start)", value: $start, in: 0...100000)
                            Stepper("\(digits) digits", value: $digits, in: 1...6)
                            TextField("Separator", text: $separator).frame(width: 80)
                        }
                    }
                    Toggle("Include file extension", isOn: $includeExtension)
                }
            }
            .formStyle(.grouped)
            .frame(height: numbering == .none ? 300 : 340)

            Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            List(preview, id: \.0) { url, name in
                HStack {
                    Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(duplicates.contains(name) ? .red : (name == url.lastPathComponent ? .secondary : AppSettings.shared.accent))
                }
                .font(.system(size: 12))
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if !duplicates.isEmpty {
                    Label("Some names collide", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 11))
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename \(changed) Item\(changed == 1 ? "" : "s")") {
                    FileOperationCenter.shared.batchRename(preview)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changed == 0 || !duplicates.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutsReference().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 440)
    }
}

struct GeneralSettings: View {
    private let terminals: [(String, String)] = [
        ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"), ("Kitty", "net.kovidgoyal.kitty"), ("WezTerm", "com.github.wez.wezterm"),
    ]

    var body: some View {
        @Bindable var s = AppSettings.shared
        Form {
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $s.showHidden)
                Toggle("Keep folders on top", isOn: $s.foldersFirst)
            }
            Section("Window") {
                Toggle("Show full path in title bar", isOn: $s.showPathInTitle)
            }
            Section("Quick Open") {
                Toggle("Open Quick Open from anywhere with ⌘⇧↩", isOn: $s.globalHotKey)
            }
            Section("Terminal") {
                Picker("Open folders in", selection: $s.terminalBundleID) {
                    ForEach(terminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }, id: \.1) { t in
                        Text(t.0).tag(t.1)
                    }
                }
            }
            Section("Default File Browser") {
                DefaultViewerToggle()
            }
            Section("Full Disk Access") {
                Text("To see folders BetterFinder can’t read (like Mail or Safari data), grant Full Disk Access in System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    var body: some View {
        @Bindable var s = AppSettings.shared
        let colorBinding = Binding<Color>(
            get: { s.accent },
            set: { s.accentHex = NSColor($0).hexString })
        Form {
            Section("Accent") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 10) {
                    ForEach(AccentPreset.all) { p in
                        Button { s.accentHex = p.hex } label: {
                            Circle()
                                .fill(Color(hex: p.hex))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.primary, lineWidth: s.accentHex == p.hex ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(p.name)
                    }
                }
                .padding(.vertical, 6)
                ColorPicker("Custom color", selection: colorBinding, supportsOpacity: false)
                Toggle("Tint panes with accent color", isOn: $s.tintWindow)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsReference: View {
    private let rows: [(String, String)] = [
        ("Quick Open / search / commands", "⌘K"), ("Go to Folder", "⇧⌘G"), ("Quick Open from any app", "⌘⇧↩"),
        ("Switch pane", "⇥"), ("Copy / Move to other pane", "F5 / F6"), ("Quick Look", "Space"), ("Rename", "↩ or F2"),
        ("Open", "⌘O / ⌘↓ / double-click"), ("Enclosing folder", "⌘↑"), ("Filter folder", "⌘F"), ("New tab", "⌘T"),
        ("New folder", "⇧⌘N / F7"), ("Move to Trash", "⌘⌫ / F8"), ("Undo last operation", "⌘Z"), ("Paste / Move here", "⌘V / ⌥⌘V"),
        ("Copy path", "⌥⌘C"), ("List / Icons / Columns", "⌘1 / ⌘2 / ⌘3"), ("Layouts", "⌃1 … ⌃6"), ("Hidden files", "⇧⌘."),
        ("Inspector", "⌘I"), ("Portal window", "⌥⌘P"),
    ]

    var body: some View {
        List(rows, id: \.0) { r in
            HStack {
                Text(r.0)
                Spacer()
                Text(r.1).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings › General › Default File Browser: use BetterFinder instead of Finder for
/// "Show in Finder" and for opening folders from other apps.
struct DefaultViewerToggle: View {
    @State private var enabled = DefaultFileViewer.isEnabled
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let binding = Binding<Bool>(get: { enabled }, set: { apply($0) })
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Use BetterFinder instead of Finder", isOn: binding)
                    .disabled(working || !DefaultFileViewer.isInstalledInApplications)
                if working { ProgressView().controlSize(.small) }
            }
            Text(DefaultFileViewer.isInstalledInApplications
                 ? "“Show in Finder” in other apps opens BetterFinder with the item selected; apps that are already open switch over the next time they launch. Folders opened from the Dock or Terminal switch over after you log out and back in. Finder stays available for the Desktop and Trash."
                 : "Move BetterFinder to the Applications folder to make it your default file browser.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { enabled = DefaultFileViewer.isEnabled }
    }

    private func apply(_ on: Bool) {
        working = true
        error = nil
        DefaultFileViewer.setEnabled(on) { message in
            working = false
            error = message.map { "Couldn’t change the default folder app: \($0)" }
            enabled = DefaultFileViewer.isEnabled
        }
    }
}
