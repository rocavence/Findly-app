# Findly

[繁體中文](README.md) · **English**

Slide a Finder-style file drawer out from any edge of the screen. Summon it from the menu bar or a global hotkey; click into another app and it slides back off-screen automatically.

<p align="center">
  <img src="Resources/icon-1024.png" width="160" alt="Findly icon">
</p>

## What it does

Findly is a macOS menu bar utility. It's **its own window** (not the real Finder) that slides in/out from any of the four screen edges, holding a file browser styled to look a lot like Finder's list view.

- ⌘\` to summon/dismiss; ⌃⌥ ↑ / ↓ / ← / → to summon to the top/bottom/left/right
- It summons to whichever screen the mouse is on
- Switch to another app → it slides off-screen automatically; press the hotkey again to bring it back
- Drag the inner edge to resize the width/height → it remembers for next time
- Because it's its own window, a single line of `collectionBehavior` makes it appear on every Space — no touching Finder, Apple Events, or private SPI

### What's inside the drawer

A new **macOS 26 "Liquid Glass" look**: a translucent window with the sidebar and file list as two rounded inset cards, a back/forward + search toolbar, drag & drop of files in and out, and Traditional Chinese localization.

- **Sidebar**: a **native SwiftUI sidebar** (a `List` with `.listStyle(.sidebar)`, hosted via `NSHostingView`) that **mirrors Finder's Favorites** — it reads Finder's shared file list (which needs Full Disk Access) — and is **drag-reorderable**
- **File list** (right pane): a Finder list view backed by `NSOutlineView`
  - **Multiple columns**: Name / Size / Kind / Date Modified, **click a column header to sort** (natural numeric sort, so `file2` comes before `file10`)
  - **Group by Kind**: static section headers like Finder's "Arrange by → Kind" (Folders / Documents / Images / Audio …)
  - **Enter folders**: double-click to go deeper, top-left Back to go up; folders can also be expanded in place via the disclosure triangle
  - **Multi-select**: rubber-band drag / Shift / ⌘ click / ⌘A to select all
  - **Context menu**: Open / Quick Look / Show in Finder / Rename / Move to Trash
  - **Spacebar Quick Look**, Enter to open
  - Applications merge in `/System/Applications`, and symlinks (e.g. Dropbox → CloudStorage) resolve to their real folders

## Why it works this way

The original direction was "don't rebuild the file-browsing UI" — just open a real Finder window with AppleScript and control its position and size with the Accessibility API, treating the real Finder as the drawer.

That path works, but the price is steep: you have to stuff a Finder window into every Space yourself, moving windows across Spaces is impossible under SIP, you need private SkyLight/CGS SPI, you have to tell "our" windows apart from the user's own, auto-park has to guess intent from timestamps… all the complexity piles onto "borrowing someone else's window."

So the direction changed: **the drawer uses its own window.** The window is ours, so:

- A single line — `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — makes it appear on every Space, no CGS gymnastics
- No Apple Events, no Accessibility, no private SPI, no per-Space bookkeeping
- We control the slide in/out animation ourselves; parking is just moving the frame off-screen

The cost is that the file-browsing UI has to be built by hand — but with `NSOutlineView` (the component underneath Finder's list view) you can get very close, and you get a far cleaner architecture in return.

## Install

Download the latest `Findly-x.y.z.zip` from [Releases](https://github.com/rocavence/Findly-app/releases/latest), unzip it, and drag **Findly.app** into `/Applications`.

Findly is self-signed (not notarized by Apple), so the first launch may be blocked ("Apple could not verify … is free of malware"). Allow it with either:
- **Right-click → Open**, then click **Open** in the dialog; or
- Terminal: `xattr -dr com.apple.quarantine /Applications/Findly.app`, then open it.

**Full Disk Access** — the drawer browses the whole file system and mirrors Finder's Favorites in the sidebar. Grant it in System Settings → Privacy & Security → Full Disk Access. Without it, TCC-protected folders (Desktop, Documents, Downloads, CloudStorage/Dropbox…) show empty and the sidebar falls back to a built-in list.

<details><summary>Build from source</summary>

```bash
git clone https://github.com/rocavence/Findly-app.git
cd Findly-app
./Scripts/build-app.sh
open build/Findly.app
```
Requires Xcode Command Line Tools.
</details>

## Usage

| Action | Trigger |
|---|---|
| Summon / dismiss | menu bar icon → Toggle Drawer, or ⌘\` |
| Summon to an edge | menu bar icon → Snap, or ⌃⌥ + arrow keys |
| Dismiss | switch to another app (automatic), or press the hotkey again |
| Sort | click a column header; or use Group by Kind |
| Enter folder / go up | double-click a folder / top-left Back |
| Act on a file | right-click: Open / Quick Look / Show in Finder / Rename / Move to Trash |
| Resize | drag the inner edge of the window; it's remembered |

## Tech stack

- **Swift 6** / **AppKit** (pure system frameworks, no third-party dependencies)
- **`NSPanel`** custom-drawn drawer, `collectionBehavior` across all Spaces
- **SwiftUI** sidebar — a `List` with `.listStyle(.sidebar)` hosted via `NSHostingView` — alongside AppKit
- **`NSOutlineView`** for the file list (view-based, multiple columns + sortable headers + group rows)
- **`UniformTypeIdentifiers`** to classify by `UTType`; **Quick Look** previews
- **Carbon `RegisterEventHotKey`** for the global hotkey (no extra permissions needed)
- **Swift Package Manager** + a shell script to build the `.app` bundle + a stable self-signed codesign
- **`CGContext` + `sips` + `iconutil`** to generate the icon programmatically

## Project structure

```
Findly-app/
├── Package.swift
├── Sources/Findly/
│   ├── main.swift              # NSApplication entry
│   ├── AppDelegate.swift       # menu bar + summon routing (+ debug window mode)
│   ├── DrawerController.swift  # slide in/out, auto-park, drag-to-resize, animation
│   ├── DrawerWindow.swift      # custom-drawn NSPanel, across all Spaces
│   ├── FileBrowserView.swift   # Finder list view (sidebar + columns + grouping + context menu)
│   ├── FullDiskAccess.swift    # detect FDA and guide the user
│   ├── HotkeyManager.swift     # Carbon global hotkey
│   ├── ScreenEdge.swift        # edge frame calculation
│   └── Defaults.swift          # UserDefaults wrapper
├── Resources/                  # Info.plist / AppIcon.icns / icon-1024.png
├── Scripts/                    # build-app.sh / make-icon.{sh,swift}
└── Tests/FindlyTests/
```

## Debug flags

| Environment variable | Effect |
|---|---|
| `FINDLY_DEBUG_AUTOSHOW=1` | Slide the drawer out automatically on launch |
| `FINDLY_DEBUG_NOPARK=1` | Disable auto-park (pin the drawer open while testing) |
| `FINDLY_DEBUG_WINDOW=1` | Put the browser in a normal window, bypassing the drawer/FDA, for easy screenshots |
| `FINDLY_DEBUG_PATH=<path>` | Specify the path the debug window opens |

## Known limitations

- Only tested on macOS 14+, with the primary test environment being macOS 26 (Tahoe)
- A stable self-signed identity (still not Apple-notarized), so downloaded copies are Gatekeeper-blocked until the quarantine attribute is cleared (see Install)
- The file browser is an *approximation* of Finder, not the real thing — tags, tabs, column view, etc. are not yet implemented
- On first launch, if FDA hasn't been granted yet, the System Settings window can steal focus and make the auto-presented drawer park immediately

## How this project was made

The whole project grew conversationally with [Claude Code](https://claude.com/claude-code) across several sessions — including the big architectural pivot above ("drive the real Finder → custom-drawn drawer"), and the back-and-forth iteration of swapping the browser from an `NSBrowser` column view to an `NSOutlineView` list view.

## License

MIT
