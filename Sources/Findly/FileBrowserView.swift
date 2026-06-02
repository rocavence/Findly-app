import AppKit
import Quartz
import UniformTypeIdentifiers

/// How the list is ordered. Raw value persists in `Defaults`; `columnKey`
/// bridges to the clickable `NSTableColumn` sort descriptors.
enum FileSort: String, CaseIterable {
    case name, dateModified, size, kind
    var title: String {
        switch self {
        case .name:         return NSLocalizedString("Name", comment: "File list column header")
        case .dateModified: return NSLocalizedString("Date Modified", comment: "File list column header")
        case .size:         return NSLocalizedString("Size", comment: "File list column header")
        case .kind:         return NSLocalizedString("Kind", comment: "File list column header")
        }
    }
    var columnKey: String {
        switch self {
        case .name: return "name"; case .dateModified: return "date"
        case .size: return "size"; case .kind: return "kind"
        }
    }
    init(columnKey: String) {
        self = FileSort.allCases.first { $0.columnKey == columnKey } ?? .name
    }
}

/// Broad kind buckets for "Group by Kind". Raw value is the display order.
enum FileCategory: Int, CaseIterable {
    case folder, application, document, image, audio, movie, archive, other
    var title: String {
        switch self {
        case .folder:      return NSLocalizedString("Folders", comment: "Group-by-Kind section header")
        case .application: return NSLocalizedString("Applications", comment: "Group-by-Kind section header")
        case .document:    return NSLocalizedString("Documents", comment: "Group-by-Kind section header")
        case .image:       return NSLocalizedString("Images", comment: "Group-by-Kind section header")
        case .audio:       return NSLocalizedString("Audio", comment: "Group-by-Kind section header")
        case .movie:       return NSLocalizedString("Movies", comment: "Group-by-Kind section header")
        case .archive:     return NSLocalizedString("Archives", comment: "Group-by-Kind section header")
        case .other:       return NSLocalizedString("Other", comment: "Group-by-Kind section header")
        }
    }
}

/// A node in the list/tree: a file/folder, or a category section header (shown
/// when "Group by Kind" is on). Reference type so the outline view keeps stable
/// item identities and we can cache lazily-loaded children + stat'd metadata.
final class Node {
    enum Kind { case category(FileCategory); case file(URL) }
    let kind: Kind
    var loadedChildren: [Node]?
    // File metadata (defaults for category rows).
    var isFolder = false
    var size = 0
    var date = Date.distantPast
    var kindString = ""
    /// Lowercased extension used as the shared-icon cache key, or nil when the
    /// row must use its own per-path icon (folders, bundles/packages, and files
    /// with no extension). See `nameCell(url:)`.
    var iconCacheKey: String?
    init(_ kind: Kind) { self.kind = kind }

    var url: URL? { if case .file(let u) = kind { return u }; return nil }
    var category: FileCategory? { if case .category(let c) = kind { return c }; return nil }
}

/// One sidebar entry: a standard location, or a section header.
private struct SidebarItem {
    let title: String
    let url: URL?
    let icon: NSImage?
    let isSection: Bool
    /// Stable id (POSIX path) for a reorderable Favorites row; nil otherwise.
    var dragID: String?
    /// True only for the Favorites section header — the one drop container.
    var isFavoritesSection = false
    var children: [SidebarItem] = []
}

/// Finder list-view navigation: a sidebar of standard locations beside a
/// multi-column `NSOutlineView` (Name / Size / Kind / Date) with clickable
/// sortable headers, inline folder expansion, and collapsible "Group by Kind"
/// section headers.
final class FileBrowserView: NSView {
    private let content = FileOutlineView()
    private let sidebar = NSOutlineView()
    private var rootURL: URL
    private var rootNodes: [Node] = []
    private var sidebarItems: [SidebarItem] = []
    private var titleLabel: NSTextField!
    private var backButton: NSButton!
    /// Folders we navigated out of, newest last; powers the Back button.
    private var history: [URL] = []
    /// Items the context menu acts on, captured when the menu opens.
    private var contextURLs: [URL] = []

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// List font size mirrored from Finder's List-view text-size setting
    /// (com.apple.finder → StandardViewSettings → ListViewSettings → textSize),
    /// falling back to 13 — Finder's own default — when it can't be read.
    static let listTextSize: CGFloat = {
        let defaults = UserDefaults(suiteName: "com.apple.finder")
        for key in ["StandardViewSettings", "FK_StandardViewSettings"] {
            if let standard = defaults?.dictionary(forKey: key),
               let list = standard["ListViewSettings"] as? [String: Any],
               let size = list["textSize"] as? Double, size > 0 {
                return CGFloat(size)
            }
        }
        return 13
    }()

    /// The view the controller should focus when the drawer slides in.
    var initialFirstResponder: NSView { content }

    var isQuickLookActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    init(root: URL) {
        self.rootURL = root
        super.init(frame: .zero)

        sidebarItems = makeSidebarItems()
        configureContent()
        configureSidebar()

        let toolbar = makeToolbar()
        let sidebarScroll = scrolled(sidebar, drawsBackground: false)
        let contentScroll = scrolled(content, drawsBackground: false)
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(contentScroll)
        // Without this the sidebar pane grabs the whole width and the file list
        // collapses to nothing. Pin the sidebar narrow; the list takes the rest.
        sidebarScroll.widthAnchor.constraint(equalToConstant: 170).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        addSubview(toolbar)
        addSubview(split)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        loadRoot(rootURL)
        sidebar.reloadData()
        sidebar.expandItem(nil, expandChildren: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func scrolled(_ view: NSView, drawsBackground: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = drawsBackground
        scroll.documentView = view
        return scroll
    }

    // MARK: - Content list configuration

    private func configureContent() {
        let columns: [(key: String, title: String, width: CGFloat, min: CGFloat)] = [
            ("name", NSLocalizedString("Name", comment: "File list column header"), 240, 120),
            ("size", NSLocalizedString("Size", comment: "File list column header"), 76, 60),
            ("kind", NSLocalizedString("Kind", comment: "File list column header"), 120, 80),
            ("date", NSLocalizedString("Date Modified", comment: "File list column header"), 160, 120),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.min
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key, ascending: true)
            content.addTableColumn(column)
            if spec.key == "name" { content.outlineTableColumn = column }
        }
        content.style = .plain
        // Row height tracks the Finder-derived text size (icons stay 16pt).
        content.rowSizeStyle = .custom
        content.rowHeight = max(18, ceil(Self.listTextSize) + 6)
        content.usesAlternatingRowBackgroundColors = false
        content.gridStyleMask = []
        content.indentationPerLevel = 14
        content.floatsGroupRows = false
        content.allowsColumnReordering = false
        content.allowsEmptySelection = true
        content.allowsMultipleSelection = true
        content.dataSource = self
        content.delegate = self
        content.target = self
        // Drag & drop: rows drag out to Finder/other apps, and the list accepts
        // file drops to move/copy into the shown folder (or onto a folder row).
        // Allow copy/move/link when dragging out; copy/move when dragging in.
        content.registerForDraggedTypes([.fileURL])
        content.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        content.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        content.doubleAction = #selector(handleDoubleClick)
        content.onSpaceKey = { [weak self] in self?.toggleQuickLook() }
        content.onEnterKey = { [weak self] in self?.activateSelection() }
        content.sortDescriptors = [NSSortDescriptor(key: Defaults.sortKey.columnKey,
                                                     ascending: Defaults.sortAscending)]
        let menu = NSMenu()
        menu.delegate = self
        content.menu = menu
    }

    private func configureSidebar() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sidebar.addTableColumn(column)
        sidebar.outlineTableColumn = column
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.floatsGroupRows = false
        sidebar.indentationPerLevel = 6
        sidebar.allowsEmptySelection = true
        sidebar.rowSizeStyle = .default
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.target = self
        sidebar.action = #selector(sidebarClicked)
        // Favorites rows can be dragged to reorder (a local override on top of
        // the Finder-mirrored order); see acceptDrop's sidebar branch.
        sidebar.registerForDraggedTypes([Self.sidebarType])
        sidebar.setDraggingSourceOperationMask(.move, forLocal: true)
    }

    /// Pasteboard type carrying a Favorites row's `dragID` during a reorder.
    static let sidebarType = NSPasteboard.PasteboardType("com.findly.sidebar-favorite")

    // MARK: - Toolbar

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let back = NSButton(image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back") ?? NSImage(),
                            target: self, action: #selector(goBack))
        back.bezelStyle = .toolbar
        back.imageScaling = .scaleProportionallyDown
        back.isEnabled = false
        back.translatesAutoresizingMaskIntoConstraints = false
        back.toolTip = NSLocalizedString("Back", comment: "Toolbar back button tooltip")
        bar.addSubview(back)
        backButton = back

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(titleLabel)

        let group = NSButton(checkboxWithTitle: NSLocalizedString("Group by Kind", comment: "Toolbar checkbox to group files by kind"), target: self, action: #selector(toggleGroup))
        group.state = Defaults.groupByKind ? .on : .off
        group.controlSize = .small
        group.font = .systemFont(ofSize: 11)
        group.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(group)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            back.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            group.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            group.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: group.leadingAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        Defaults.groupByKind = (sender.state == .on)
        reloadListing()
    }

    // MARK: - Roots & reload

    private func loadRoot(_ url: URL) {
        rootURL = url
        titleLabel.stringValue = displayName(url)
        reloadListing()
    }

    /// Rebuild the tree with fresh nodes so re-sorting/grouping applies at every
    /// level. Collapses expansion, a fair trade for consistent selection.
    ///
    /// The full `reloadData()` here is intentional: every caller changes the
    /// whole visible directory (navigation, sort, group toggle, trash, rename).
    /// For future *localized* updates — e.g. a file-system watcher reflecting a
    /// single added/removed/renamed row — prefer
    /// `content.reloadItem(_:reloadChildren:)` to relayout only that subtree
    /// rather than rebuilding and collapsing the entire tree.
    private func reloadListing() {
        rootNodes = makeNodes(forDirectory: rootURL)
        content.reloadData()
    }

    @objc private func sidebarClicked() {
        guard sidebar.clickedRow >= 0,
              let item = sidebar.item(atRow: sidebar.clickedRow) as? SidebarItem,
              let url = item.url, url != rootURL else { return }
        navigate(into: url)   // push history so Back works after a sidebar jump
    }

    // MARK: - Open / QuickLook

    @objc private func handleDoubleClick() {
        guard content.clickedRow >= 0,
              let node = content.item(atRow: content.clickedRow) as? Node else { return }
        open(node)
    }

    private func activateSelection() {
        guard let node = selectedNode else { return }
        open(node)
    }

    private func open(_ node: Node) {
        // Category header → expand/collapse inline.
        if node.category != nil {
            content.isItemExpanded(node) ? content.collapseItem(node) : content.expandItem(node)
            return
        }
        guard let url = node.url else { return }
        if isLeaf(url) {
            NSWorkspace.shared.open(url)          // file → launch in its app
        } else {
            navigate(into: url)                   // folder → drill into the next level
        }
    }

    private func navigate(into url: URL) {
        history.append(rootURL)
        loadRoot(url)
        updateBackButton()
    }

    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        loadRoot(previous)
        updateBackButton()
    }

    private func updateBackButton() {
        backButton.isEnabled = !history.isEmpty
    }

    // MARK: - Context menu

    /// Files the right-click acts on: the clicked row, expanded to the whole
    /// selection when the clicked row is part of it (Finder's behavior).
    private func contextTargets() -> [URL] {
        let clicked = content.clickedRow
        guard clicked >= 0, let url = (content.item(atRow: clicked) as? Node)?.url else { return [] }
        if content.selectedRowIndexes.contains(clicked) {
            let selected = selectedURLs
            return selected.isEmpty ? [url] : selected
        }
        return [url]
    }

    @objc private func ctxOpen() {
        if contextURLs.count == 1, let url = contextURLs.first, !isLeaf(url) {
            navigate(into: url)
        } else {
            contextURLs.forEach { NSWorkspace.shared.open($0) }
        }
    }

    @objc private func ctxReveal() {
        NSWorkspace.shared.activateFileViewerSelecting(contextURLs)
    }

    @objc private func ctxQuickLook() { toggleQuickLook() }

    @objc private func ctxTrash() {
        for url in contextURLs {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        reloadListing()
    }

    @objc private func ctxRename() {
        guard let url = contextURLs.first else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Rename “%@”", comment: "Rename dialog title, %@ is the current file name"), url.lastPathComponent)
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename dialog confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Rename dialog cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        try? FileManager.default.moveItem(at: url, to: dest)
        reloadListing()
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var selectedNode: Node? {
        let row = content.selectedRow
        guard row >= 0 else { return nil }
        return content.item(atRow: row) as? Node
    }

    var selectedURL: URL? { selectedNode?.url }

    /// Every selected file/folder (multi-selection), in row order.
    private var selectedURLs: [URL] {
        content.selectedRowIndexes.compactMap { (content.item(atRow: $0) as? Node)?.url }
    }

    // MARK: - Directory listing

    private struct Entry {
        let url: URL
        let isFolder: Bool
        let isPackage: Bool
        let category: FileCategory
        let name: String
        let date: Date
        let size: Int
        let kindString: String
    }

    private func makeNodes(forDirectory url: URL) -> [Node] {
        let entries = entries(of: url)
        if Defaults.groupByKind {
            // Finder "Arrange by Kind": static section headers as sibling rows,
            // items listed under each — not collapsible parent nodes.
            var buckets: [FileCategory: [Entry]] = [:]
            for entry in entries { buckets[entry.category, default: []].append(entry) }
            var rows: [Node] = []
            for category in FileCategory.allCases {
                guard var items = buckets[category], !items.isEmpty else { continue }
                // Within each kind section, order by date modified — but honour
                // the asc/desc toggle: descending (the default) is newest first,
                // ascending is oldest first. Natural-name compare breaks ties.
                let ascending = Defaults.sortAscending
                items.sort { a, b in
                    if a.date != b.date { return ascending ? a.date < b.date : a.date > b.date }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                rows.append(Node(.category(category)))
                rows.append(contentsOf: items.map(node(from:)))
            }
            return rows
        } else {
            return entries.sorted(by: ordering(foldersFirst: true)).map(node(from:))
        }
    }

    private func node(from entry: Entry) -> Node {
        let node = Node(.file(entry.url))
        node.isFolder = entry.isFolder
        node.size = entry.size
        node.date = entry.date
        node.kindString = entry.kindString
        // Only plain files with an extension share a cached generic-type icon.
        // Folders and bundles/packages (.app, .rtfd, …) carry per-item icons, so
        // they keep using the per-path icon and bypass the cache.
        if !entry.isFolder, !entry.isPackage {
            let ext = entry.url.pathExtension.lowercased()
            node.iconCacheKey = ext.isEmpty ? nil : ext
        }
        return node
    }

    private func children(of node: Node) -> [Node] {
        if let cached = node.loadedChildren { return cached }
        let result: [Node]
        switch node.kind {
        case .category:      result = []   // pre-loaded in makeNodes
        case .file(let url): result = isLeaf(url) ? [] : makeNodes(forDirectory: url)
        }
        node.loadedChildren = result
        return result
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .localizedNameKey, .localizedTypeDescriptionKey,
        .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
    ]

    private func entries(of url: URL) -> [Entry] {
        let contents = sourceDirectories(for: url).flatMap { dir in
            // Resolve symlinks first: listing ~/Dropbox (a link into
            // ~/Library/CloudStorage) returns nothing, but the resolved path lists.
            (try? FileManager.default.contentsOfDirectory(
                at: dir.resolvingSymlinksInPath(),
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        let entries: [Entry] = contents.map { item in
            let values = try? item.resourceValues(forKeys: Set(Self.resourceKeys + [.isSymbolicLinkKey]))
            // Symlinks (e.g. ~/Dropbox) report as non-directories, so resolve to
            // the target to classify and navigate them like the real folder.
            let target = resolved(item, isSymlink: values?.isSymbolicLink ?? false)
            let isPackage = target.isPackage ?? false
            let isFolder = (target.isDirectory ?? false) && !isPackage
            return Entry(
                url: item,
                isFolder: isFolder,
                isPackage: isPackage,
                category: category(isFolder: isFolder, type: target.contentType),
                name: values?.localizedName ?? item.lastPathComponent,
                date: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0,
                kindString: target.localizedTypeDescription ?? (isFolder ? "Folder" : "")
            )
        }
        // Dedupe by name — the Applications merge can surface two "Utilities".
        var seen = Set<String>()
        return entries.filter { seen.insert($0.name).inserted }
    }

    /// Directory/package/type of `url`, following a symlink to its target.
    private func resolved(_ url: URL, isSymlink: Bool) -> URLResourceValues {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .localizedTypeDescriptionKey]
        let probe = isSymlink ? url.resolvingSymlinksInPath() : url
        return (try? probe.resourceValues(forKeys: keys)) ?? URLResourceValues()
    }

    /// Directories whose contents make up a folder. Normally just the folder
    /// itself, but "Applications" merges /System/Applications too, the way
    /// Finder's Applications view shows both third-party and system apps.
    private func sourceDirectories(for url: URL) -> [URL] {
        if url.path == "/Applications" {
            return [url, URL(fileURLWithPath: "/System/Applications")]
        }
        return [url]
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
    /// directories on top regardless of key (the flat, ungrouped list).
    /// Secondary key is always an ascending natural-name compare.
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
                if cmp == .orderedSame { return false }
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

    private func isLeaf(_ url: URL) -> Bool {
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        let vals = resolved(url, isSymlink: isSymlink)
        let isDir = vals.isDirectory ?? false
        let isPackage = vals.isPackage ?? false
        return !isDir || isPackage
    }

    // MARK: - Sidebar contents

    /// Re-read Finder's Favorites and rebuild the sidebar so it stays in sync
    /// with whatever the user has in Finder. Called on each show (see
    /// `DrawerController`) and at init.
    func syncSidebar() {
        sidebarItems = makeSidebarItems()
        sidebar.reloadData()
        sidebar.expandItem(nil, expandChildren: true)
    }

    private func makeSidebarItems() -> [SidebarItem] {
        let favorites = orderedFavorites(makeFavoriteItems())
        let locations = [sidebarLocation(URL(fileURLWithPath: "/"))].compactMap { $0 }
        return [
            SidebarItem(title: NSLocalizedString("Favorites", comment: "Sidebar section header"),
                        url: nil, icon: nil, isSection: true, isFavoritesSection: true, children: favorites),
            SidebarItem(title: NSLocalizedString("Locations", comment: "Sidebar section header"),
                        url: nil, icon: nil, isSection: true, children: locations),
        ]
    }

    /// Favorites mirrored from Finder, falling back to a built-in set when
    /// Finder's list can't be read (e.g. Full Disk Access not yet granted).
    private func makeFavoriteItems() -> [SidebarItem] {
        let finder = finderFavorites()
        let urls = finder.isEmpty ? builtInFavoriteURLs() : finder
        return urls.compactMap { favoriteItem(for: $0) }
    }

    private func favoriteItem(for url: URL) -> SidebarItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        var item = SidebarItem(title: displayName(url), url: url, icon: icon, isSection: false)
        item.dragID = url.path
        return item
    }

    private func sidebarLocation(_ url: URL) -> SidebarItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return SidebarItem(title: displayName(url), url: url, icon: icon, isSection: false)
    }

    private func builtInFavoriteURLs() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func std(_ d: FileManager.SearchPathDirectory) -> URL? {
            try? fm.url(for: d, in: .userDomainMask, appropriateFor: nil, create: false)
        }
        return [
            std(.desktopDirectory), std(.downloadsDirectory), std(.documentDirectory),
            home.appendingPathComponent("Dropbox"), home, URL(fileURLWithPath: "/Applications"),
        ].compactMap { $0 }
    }

    /// Finder's sidebar Favorites, read from its shared-file-list store so our
    /// sidebar mirrors Finder. The `.sfl4`/`.sfl3`/`.sfl2` file is an
    /// NSKeyedArchiver archive of plain NSDictionary/NSArray/NSData (no custom
    /// classes), so we unarchive it and walk the ordered `items` array, pulling
    /// each item's `Bookmark` and resolving it to a reachable URL — preserving
    /// Finder's exact order. Returns [] when the store is absent or unreadable —
    /// notably without Full Disk Access, the same gate Finder's store sits
    /// behind — so the caller falls back to a built-in list.
    private func finderFavorites() -> [URL] {
        let dir = ("~/Library/Application Support/com.apple.sharedfilelist" as NSString).expandingTildeInPath
        for name in ["com.apple.LSSharedFileList.FavoriteItems.sfl4",
                     "com.apple.LSSharedFileList.FavoriteItems.sfl3",
                     "com.apple.LSSharedFileList.FavoriteItems.sfl2"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { continue }
            unarchiver.requiresSecureCoding = false
            let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
            guard let dict = root as? [String: Any],
                  let items = dict["items"] as? [[String: Any]] else { continue }
            var urls: [URL] = []
            var seen = Set<String>()
            for item in items {
                guard let bookmark = item["Bookmark"] as? Data else { continue }  // skip AirDrop/Recents/etc.
                var stale = false
                guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [],
                                              relativeTo: nil, bookmarkDataIsStale: &stale),
                      (try? resolved.checkResourceIsReachable()) == true,
                      seen.insert(resolved.path).inserted
                else { continue }
                urls.append(resolved)
            }
            if !urls.isEmpty { return urls }
        }
        return []
    }

    /// Apply the user's saved local order (by path) over the discovered set:
    /// known rows take their saved rank, freshly-appeared Finder rows keep their
    /// natural order at the end.
    private func orderedFavorites(_ items: [SidebarItem]) -> [SidebarItem] {
        let order = Defaults.sidebarOrder
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted {
            let ra = rank[$0.element.dragID ?? ""] ?? Int.max
            let rb = rank[$1.element.dragID ?? ""] ?? Int.max
            return ra != rb ? ra < rb : $0.offset < $1.offset
        }.map(\.element)
    }

    /// Move a Favorites row to `index` within the section, persist the new order
    /// locally, and refresh. Returns false if the row vanished mid-drag.
    private func reorderFavorite(dragID: String, to index: Int) -> Bool {
        guard let favIdx = sidebarItems.firstIndex(where: { $0.isFavoritesSection }) else { return false }
        var favorites = sidebarItems[favIdx].children
        guard let from = favorites.firstIndex(where: { $0.dragID == dragID }) else { return false }
        let moved = favorites.remove(at: from)
        var insert = index
        if from < insert { insert -= 1 }              // adjust for the removal
        insert = max(0, min(insert, favorites.count))
        favorites.insert(moved, at: insert)
        sidebarItems[favIdx].children = favorites
        Defaults.sidebarOrder = favorites.compactMap(\.dragID)
        sidebar.reloadData()
        sidebar.expandItem(nil, expandChildren: true)
        return true
    }
}

// MARK: - Content outline data source / delegate

extension FileBrowserView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if outlineView === sidebar {
            guard let item = item as? SidebarItem else { return sidebarItems.count }
            return item.children.count
        }
        guard let node = item as? Node else { return rootNodes.count }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if outlineView === sidebar {
            guard let item = item as? SidebarItem else { return sidebarItems[index] }
            return item.children[index]
        }
        guard let node = item as? Node else { return rootNodes[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if outlineView === sidebar { return (item as? SidebarItem)?.isSection ?? false }
        guard let node = item as? Node else { return false }
        switch node.kind {
        case .category:      return false   // static header, never collapses
        case .file(let url): return !isLeaf(url)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if outlineView === sidebar { return (item as? SidebarItem)?.isSection ?? false }
        return (item as? Node)?.category != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if outlineView === sidebar { return (item as? SidebarItem)?.url != nil }
        return (item as? Node)?.category == nil
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard outlineView === content, let descriptor = content.sortDescriptors.first,
              let key = descriptor.key else { return }
        Defaults.sortKey = FileSort(columnKey: key)
        Defaults.sortAscending = descriptor.ascending
        reloadListing()
    }

    // MARK: Drag & drop

    /// Drag source: a file/folder row vends its URL so it can be dropped into
    /// Finder, other apps, or a folder elsewhere in this list. Category headers
    /// aren't draggable.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if outlineView === sidebar {
            guard let dragID = (item as? SidebarItem)?.dragID else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(dragID, forType: Self.sidebarType)
            return pb
        }
        guard let url = (item as? Node)?.url else { return nil }
        return url as NSURL
    }

    /// Drop target: accept file URLs onto a folder row (into that folder) or
    /// anywhere else in the list (into the folder currently shown). Retarget the
    /// highlight to the whole folder/list — we never insert between rows.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if outlineView === sidebar {
            // Only a reorder within the Favorites section, dropped in a gap
            // (index >= 0) so the insertion line shows between rows.
            guard info.draggingPasteboard.availableType(from: [Self.sidebarType]) != nil,
                  (item as? SidebarItem)?.isFavoritesSection == true, index >= 0
            else { return [] }
            return .move
        }
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true])
        else { return [] }

        if let node = item as? Node, node.isFolder {
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return dropOperation(info: info, into: dropDestinationURL(for: item))
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if outlineView === sidebar {
            guard let dragID = info.draggingPasteboard.string(forType: Self.sidebarType) else { return false }
            return reorderFavorite(dragID: dragID, to: index)
        }
        let sources = draggedFileURLs(from: info)
        guard !sources.isEmpty else { return false }
        let destination = dropDestinationURL(for: item).resolvingSymlinksInPath()
        let op = dropOperation(info: info, into: destination)
        guard op == .move || op == .copy else { return false }

        let fm = FileManager.default
        var didChange = false
        for src in sources {
            let srcParent = src.deletingLastPathComponent().resolvingSymlinksInPath()
            if op == .move, srcParent == destination { continue }   // already here
            let target = uniqueDestination(for: src.lastPathComponent, in: destination,
                                           preferCopySuffix: op == .copy && srcParent == destination)
            do {
                if op == .move { try fm.moveItem(at: src, to: target) }
                else           { try fm.copyItem(at: src, to: target) }
                didChange = true
            } catch {
                NSSound.beep()
            }
        }
        if didChange { reloadListing() }
        return didChange
    }

    /// Folder a drop lands in: a folder row's URL, else the folder shown now.
    private func dropDestinationURL(for item: Any?) -> URL {
        if let node = item as? Node, node.isFolder, let url = node.url { return url }
        return rootURL
    }

    private func draggedFileURLs(from info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    /// Finder semantics: move within a volume, copy across volumes; Option/Command
    /// modifiers arrive already folded into the drag's operation mask. Refuse to
    /// drop a folder into itself or a descendant.
    private func dropOperation(info: NSDraggingInfo, into destination: URL) -> NSDragOperation {
        let sources = draggedFileURLs(from: info)
        guard !sources.isEmpty else { return [] }
        for src in sources {
            let s = src.resolvingSymlinksInPath().path
            if destination.path == s || destination.path.hasPrefix(s + "/") { return [] }
        }
        let mask = info.draggingSourceOperationMask
        if sameVolume(sources[0], destination) {
            if mask.contains(.move) { return .move }
            if mask.contains(.copy) { return .copy }
            return []
        }
        return mask.contains(.copy) ? .copy : []
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        if let va, let vb { return va.isEqual(vb) }
        return true   // unknown → assume same volume (default to move)
    }

    /// A non-existing URL in `dir` for `name`, so a drop never overwrites.
    /// `preferCopySuffix` starts from "name copy" (copying into the same folder).
    private func uniqueDestination(for name: String, in dir: URL, preferCopySuffix: Bool) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func url(_ stem: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        var candidate = url(preferCopySuffix ? "\(base) copy" : base)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url(preferCopySuffix ? "\(base) copy \(i)" : "\(base) \(i)")
            i += 1
        }
        return candidate
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if outlineView === sidebar { return sidebarView(item as! SidebarItem) }

        let node = item as! Node
        if let category = node.category {
            // Group section header. NSOutlineView requests a full-width group
            // view with a nil column; also honour the name column. Other columns
            // get nothing so the header reads as one spanning label.
            guard tableColumn == nil || tableColumn?.identifier.rawValue == "name" else { return nil }
            return groupCell(title: category.title.uppercased())
        }
        switch tableColumn?.identifier.rawValue {
        case "name": return nameCell(for: node)
        case "size": return textCell((node.isFolder || node.size == 0) ? "--" : Self.byteFormatter.string(fromByteCount: Int64(node.size)),
                                      align: .right, secondary: true)
        case "kind": return textCell(node.kindString, secondary: true)
        case "date": return textCell(node.date == .distantPast ? "" : Self.dateFormatter.string(from: node.date),
                                      secondary: true)
        default:     return nil
        }
    }

    // MARK: Cells

    /// Shared 16×16 generic-type icons, keyed by lowercased file extension, so a
    /// folder of hundreds of .png/.pdf rows reuses one icon instead of calling
    /// NSWorkspace per cell draw (which janks scrolling). Folders/bundles aren't
    /// cached — see `node(from:)` / `iconCacheKey`.
    private static let iconCache = NSCache<NSString, NSImage>()

    private func nameCell(for node: Node) -> NSView {
        let url = node.url!
        let id = NSUserInterfaceItemIdentifier("name")
        let cell = (content.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(icon); cell.addSubview(label)
            cell.imageView = icon; cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = icon(for: node, url: url)
        cell.textField?.font = .systemFont(ofSize: Self.listTextSize)
        cell.textField?.stringValue = displayName(url)
        return cell
    }

    /// Cache-backed 16×16 icon for a file row. Cacheable rows (plain files keyed
    /// by extension) share one image; everything else falls back to the per-path
    /// icon. Sizing the shared instance to 16×16 is idempotent, so it's safe.
    private func icon(for node: Node, url: URL) -> NSImage {
        if let key = node.iconCacheKey {
            if let cached = Self.iconCache.object(forKey: key as NSString) {
                return cached
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            Self.iconCache.setObject(icon, forKey: key as NSString)
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func textCell(_ text: String, align: NSTextAlignment = .left, secondary: Bool = false) -> NSView {
        let id = NSUserInterfaceItemIdentifier("text")
        let cell = (content.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.font = .systemFont(ofSize: Self.listTextSize)
        cell.textField?.stringValue = text
        cell.textField?.alignment = align
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    private func groupCell(title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("group")
        let cell = (content.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = title
        return cell
    }

    private func sidebarView(_ item: SidebarItem) -> NSView {
        if item.isSection {
            let id = NSUserInterfaceItemIdentifier("sbSection")
            let cell = (sidebar.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label); cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = item.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("sbItem")
        let cell = (sidebar.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(icon); cell.addSubview(label)
            cell.imageView = icon; cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = item.icon
        cell.textField?.font = .systemFont(ofSize: Self.listTextSize)
        cell.textField?.stringValue = item.title
        return cell
    }
}

// MARK: - QuickLook

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
        MainActor.assumeIsolated { selectedURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> NSURL? in
            let urls = selectedURLs
            return index < urls.count ? (urls[index] as NSURL) : nil
        }
    }
}

// MARK: - Context menu population

extension FileBrowserView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextURLs = contextTargets()
        guard !contextURLs.isEmpty else { return }
        let many = contextURLs.count > 1
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        add(many
            ? String(format: NSLocalizedString("Open %d Items", comment: "Context menu: open multiple selected items, %d is the count"), contextURLs.count)
            : NSLocalizedString("Open", comment: "Context menu: open a single item"),
            #selector(ctxOpen))
        add(many
            ? String(format: NSLocalizedString("Quick Look %d Items", comment: "Context menu: Quick Look multiple selected items, %d is the count"), contextURLs.count)
            : NSLocalizedString("Quick Look", comment: "Context menu: Quick Look a single item"),
            #selector(ctxQuickLook))
        add(NSLocalizedString("Reveal in Finder", comment: "Context menu: reveal item in Finder"), #selector(ctxReveal))
        menu.addItem(.separator())
        if !many { add(NSLocalizedString("Rename…", comment: "Context menu: rename item"), #selector(ctxRename)) }
        add(NSLocalizedString("Move to Trash", comment: "Context menu: move item to Trash"), #selector(ctxTrash))
    }
}

/// NSOutlineView subclass that routes space → QuickLook and Return → open.
final class FileOutlineView: NSOutlineView {
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
