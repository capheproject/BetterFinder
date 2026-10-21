# BetterFinder

A native macOS file manager (SwiftUI + AppKit) that takes the best of **Bloom** (beauty, theming, Quick Open, Portal, Footprints) and **ForkLift** (multi-pane power, F5/F6, activity queue, Git, workspaces), and fixes what Finder gets wrong.

## Build & run

```bash
./scripts/build-app.sh            # builds build/BetterFinder.app
./scripts/build-app.sh --install  # also copies it to /Applications
```

Requires macOS 14+ and Xcode (Swift 5.10+). No external dependencies.

## Highlights

| | |
|---|---|
| **Multi-pane layouts** | Single, side-by-side, stacked, three columns, one + two, four panes (⌃1–⌃6). Every pane has its own tabs, history, path bar and view mode. `⇥` switches panes. |
| **Three views** | List (NSTableView: type-select, multi-drag, drop onto folders, inline rename, column chooser), Icons with live thumbnails and size slider, Miller Columns with preview. |
| **Quick Open** (`⌘K`, `⇧⌘G`, and `⌘⇧↩` from any app) | Paths with `⇥` completion, Spotlight file search, favorites, recent folders and every command in one palette. |
| **Commander keys** | F5 copy / F6 move to the other pane, F7 new folder, F8 trash, F2 rename, Space Quick Look (arrow keys keep working in the panel). |
| **Footprints** | Every copy, move, rename, trash, tag change, compression and image edit is logged and individually undoable (`⌘Z` for the latest). |
| **Activity** | Background copy/move/compress/extract with progress, conflict prompt (Keep Both / Replace-to-Trash / Skip). |
| **Inspector** | Quick Look preview, sizes (folder sizes on demand), image dimensions, permissions, tags, Git status, archive contents without extracting. |
| **Git aware** | Branch chip in the path bar, per-file M/A/D/?/R badges, dirty folders highlighted. |
| **Filter & search** | `⌘F` live filter, or recursive search through subfolders. Tags in the sidebar list tagged files via Spotlight. |
| **Sync Browsing** | Selecting a folder shows its contents in the next pane. |
| **Batch rename** | Find/replace (regex), prefix/suffix, numbering, case; live preview with collision detection. |
| **Smart paste** | Paste files, images (saved as PNG) or text (saved as .txt) straight into a folder; drag images in from the web. |
| **Images** | Rotate, convert to PNG / JPEG / HEIC from the context menu. |
| **Portal** (`⌥⌘P`) | Compact single-pane window that can float on top. |
| **Workspaces** | Save and restore layouts with all their tabs. Your session is restored on launch. |
| **Theming** | Pick any accent color: selection, sidebar icons, active pane and highlights follow it. |
| **Also** | Open in Terminal / iTerm / Ghostty / Warp, copy path, new files from templates, hidden-files toggle, volumes with eject, customizable sidebar icons, drag folders into the sidebar. |

## Layout

```
Sources/BetterFinder/
  App/       App entry, menus/shortcuts, key routing
  Model/     Workspace (panes, actions), BrowserTab (navigation, listing), settings, file items
  Services/  File operations + Footprints, git, Spotlight (mdfind), watchers, Quick Look, hot key
  Views/     Window, panes, list/grid/columns, sidebar, inspector, Quick Open, panels
scripts/     build-app.sh, make-icon.swift (renders the app icon)
```
