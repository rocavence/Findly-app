import AppKit
import Quartz
import UniformTypeIdentifiers

/// How a column's entries are ordered. Raw value persists in `Defaults`.
enum FileSort: String, CaseIterable {
    case name, dateModified, size, kind
    var title: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .size:         return "Size"
        case .kind:         return "Kind"
        }
    }
}

/// Broad kind buckets for "Group by Kind". Raw value is the display order.
enum FileCategory: Int, CaseIterable {
    case folder, application, document, image, audio, movie, archive, other
    var title: String {
        switch self {
        case .folder:      return "Folders"
        case .application: return "Applications"
        case .document:    return "Documents"
        case .image:       return "Images"
        case .audio:       return "Audio"
        case .movie:       return "Movies"
        case .archive:     return "Archives"
        case .other:       return "Other"
        }
    }
}

/// A row in a browser column: a file/folder, or a category header (shown only
/// when "Group by Kind" is on). A reference type so `NSBrowser` sees stable item
/// identities across its repeated `child(_:ofItem:)` calls.
final class BrowserRow: NSObject {
    enum Kind { case header(FileCategory); case file(URL) }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    var url: URL? { if case .file(let u) = kind { return u }; return nil }
    var isHeader: Bool { if case .header = kind { return true }; return false }
}

/// Finder-style column (Miller) navigation backed by `NSBrowser` + FileManager,
/// with a toolbar to pick the sort key/direction and toggle category grouping.
/// `NSBrowser` is the system control Finder's column view descends from, so we
/// get the drill-right hierarchy, keyboard arrows and selection almost for
/// free; we add file icons, open-on-double-click/Enter and spacebar QuickLook.
final class FileBrowserView: NSView {
    let browser = FileBrowser()
    private let rootURL: URL
    private let rootRow: BrowserRow
    /// Cache rows per directory so `NSBrowser`'s repeated child(_:ofItem:) calls
    /// get stable, identical item objects (and we don't re-stat on every call).
    private var rowCache: [String: [BrowserRow]] = [:]

    /// True while a QuickLook panel we own is on screen. The controller checks
    /// this so losing key focus to QuickLook doesn't park the drawer.
    var isQuickLookActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    init(root: URL) {
        self.rootURL = root
        self.rootRow = BrowserRow(.file(root))
        super.init(frame: .zero)

        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.delegate = self
        browser.minColumnWidth = 200
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.separatesColumns = false
        browser.allowsEmptySelection = true
        browser.allowsMultipleSelection = false
        browser.target = self
        browser.doubleAction = #selector(openSelection)
        browser.onSpaceKey = { [weak self] in self?.toggleQuickLook() }
        browser.onEnterKey = { [weak self] in self?.openSelection() }

        let toolbar = makeToolbar()
        addSubview(toolbar)
        addSubview(browser)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            browser.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            browser.bottomAnchor.constraint(equalTo: bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// URL currently selected in the deepest open column, if any. Headers have
    /// no URL, so they never count as a selection.
    var selectedURL: URL? {
        let col = browser.selectedColumn
        guard col >= 0 else { return nil }
        let row = browser.selectedRow(inColumn: col)
        guard row >= 0 else { return nil }
        return (browser.item(atRow: row, inColumn: col) as? BrowserRow)?.url
    }

    // MARK: - Toolbar (sort / group controls)

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(showSortMenu(_:)))
        button.isBordered = false
        button.bezelStyle = .toolbar
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Sort & grouping"
        bar.addSubview(button)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, sort) in FileSort.allCases.enumerated() {
            let item = NSMenuItem(title: sort.title, action: #selector(pickSort(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (sort == Defaults.sortKey) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let reversed = NSMenuItem(title: "Descending", action: #selector(toggleReversed(_:)), keyEquivalent: "")
        reversed.target = self
        reversed.state = Defaults.sortAscending ? .off : .on
        menu.addItem(reversed)

        menu.addItem(.separator())
        let group = NSMenuItem(title: "Group by Kind", action: #selector(toggleGroup(_:)), keyEquivalent: "")
        group.target = self
        group.state = Defaults.groupByKind ? .on : .off
        menu.addItem(group)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pickSort(_ sender: NSMenuItem) {
        let all = FileSort.allCases
        guard all.indices.contains(sender.tag) else { return }
        Defaults.sortKey = all[sender.tag]
        reloadListing()
    }

    @objc private func toggleReversed(_ sender: NSMenuItem) {
        Defaults.sortAscending.toggle()
        reloadListing()
    }

    @objc private func toggleGroup(_ sender: NSMenuItem) {
        Defaults.groupByKind.toggle()
        reloadListing()
    }

    /// Re-sort/re-group from the root. Resets the drill-down path, which is a
    /// fair trade for keeping selection state consistent after a reorder.
    private func reloadListing() {
        rowCache.removeAll()
        browser.loadColumnZero()
    }

    // MARK: - Open / QuickLook

    @objc private func openSelection() {
        guard let url = selectedURL else { return }
        // Folders open as a real Finder window; files open in their app. (The
        // column view already drills into folders on single-click.)
        NSWorkspace.shared.open(url)
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Directory listing

    /// One directory entry with everything the sort/group needs, stat'd once.
    private struct Entry {
        let url: URL
        let isFolder: Bool
        let category: FileCategory
        let name: String
        let date: Date
        let size: Int
    }

    private func rows(of url: URL) -> [BrowserRow] {
        if let cached = rowCache[url.path] { return cached }
        let entries = entries(of: url)
        let result: [BrowserRow]
        if Defaults.groupByKind {
            var buckets: [FileCategory: [Entry]] = [:]
            for entry in entries { buckets[entry.category, default: []].append(entry) }
            var out: [BrowserRow] = []
            for category in FileCategory.allCases {
                guard var items = buckets[category], !items.isEmpty else { continue }
                items.sort(by: ordering(foldersFirst: false))
                out.append(BrowserRow(.header(category)))
                out.append(contentsOf: items.map { BrowserRow(.file($0.url)) })
            }
            result = out
        } else {
            result = entries.sorted(by: ordering(foldersFirst: true)).map { BrowserRow(.file($0.url)) }
        }
        rowCache[url.path] = result
        return result
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .localizedNameKey,
        .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
    ]

    private func entries(of url: URL) -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.map { item in
            let values = try? item.resourceValues(forKeys: Set(Self.resourceKeys))
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            return Entry(
                url: item,
                isFolder: isFolder,
                category: category(isFolder: isFolder, type: values?.contentType),
                name: values?.localizedName ?? item.lastPathComponent,
                date: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0
            )
        }
    }

    private func category(isFolder: Bool, type: UTType?) -> FileCategory {
        if isFolder { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .text)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation)
            || type.conforms(to: .content) { return .document }
        return .other
    }

    /// Comparator for the current sort key/direction. `foldersFirst` keeps
    /// directories on top regardless of key (used for the flat, ungrouped list).
    /// The secondary key is always an ascending natural-name compare.
    private func ordering(foldersFirst: Bool) -> (Entry, Entry) -> Bool {
        let key = Defaults.sortKey
        let ascending = Defaults.sortAscending
        return { a, b in
            if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
            func byName() -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
            let result: Bool
            switch key {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp == .orderedSame { return false }   // equal → stable, neither precedes
                result = (cmp == .orderedAscending)
            case .dateModified:
                if a.date == b.date { return byName() }
                result = a.date < b.date
            case .size:
                if a.size == b.size { return byName() }
                result = a.size < b.size
            case .kind:
                if a.category != b.category {
                    let r = a.category.rawValue < b.category.rawValue
                    return ascending ? r : !r
                }
                return byName()
            }
            return ascending ? result : !result
        }
    }

    private func displayName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
    }

    /// Folders are branches; files and packages (.app, .rtfd, …) are leaves so
    /// a double-click opens them instead of trying to descend.
    private func isLeaf(_ url: URL) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = vals?.isDirectory ?? false
        let isPackage = vals?.isPackage ?? false
        return !isDir || isPackage
    }

    /// Directory whose contents `item` represents: the root, or a folder row.
    private func directory(for item: Any?) -> URL? {
        guard let row = item as? BrowserRow else { return rootURL }
        return row.url
    }
}

// MARK: - NSBrowserDelegate (item-based)

extension FileBrowserView: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { rootRow }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let dir = directory(for: item) else { return 0 }
        return rows(of: dir).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        rows(of: directory(for: item) ?? rootURL)[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let row = item as? BrowserRow else { return false }
        switch row.kind {
        case .header:        return true
        case .file(let url): return isLeaf(url)
        }
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let row = item as? BrowserRow else { return "" }
        switch row.kind {
        case .header(let category):
            return NSAttributedString(string: category.title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case .file(let url):
            // The column cell is a text-only NSTextFieldCell that ignores cell
            // images, but it does render an attributed string — so we embed the
            // file icon as an inline text attachment ahead of the name.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
            let result = NSMutableAttributedString(attachment: attachment)
            result.append(NSAttributedString(string: "  " + displayName(url)))
            return result
        }
    }

    /// Disable header rows so they read as section labels and can't be selected
    /// or drilled into.
    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell,
              let item = browser.item(atRow: row, inColumn: column) as? BrowserRow else { return }
        if item.isHeader {
            cell.isEnabled = false
            cell.isLeaf = true
        } else {
            cell.isEnabled = true
        }
    }
}

// MARK: - QuickLook
//
// QuickLook's informal protocol is nonisolated; these callbacks all arrive on
// the main thread, so we hop back onto the main actor to read our state.
extension FileBrowserView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selectedURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { selectedURL as NSURL? }
    }
}

/// NSBrowser subclass that routes the keys Finder users expect — space for
/// QuickLook, Return to open — back to the owning view.
final class FileBrowser: NSBrowser {
    var onSpaceKey: (() -> Void)?
    var onEnterKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            onSpaceKey?()
        case "\r", "\u{3}":
            onEnterKey?()
        default:
            super.keyDown(with: event)
        }
    }
}
