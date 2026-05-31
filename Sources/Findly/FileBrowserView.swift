import AppKit
import Quartz
import UniformTypeIdentifiers

/// How the list is ordered. Raw value persists in `Defaults`; `columnKey`
/// bridges to the clickable `NSTableColumn` sort descriptors.
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

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
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
            ("name", "Name", 240, 120),
            ("size", "Size", 76, 60),
            ("kind", "Kind", 120, 80),
            ("date", "Date Modified", 160, 120),
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
        content.rowSizeStyle = .default
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
        content.doubleAction = #selector(handleDoubleClick)
        content.onSpaceKey = { [weak self] in self?.toggleQuickLook() }
        content.onEnterKey = { [weak self] in self?.activateSelection() }
        content.sortDescriptors = [NSSortDescriptor(key: Defaults.sortKey.columnKey,
                                                     ascending: Defaults.sortAscending)]
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
    }

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
        back.toolTip = "Back"
        bar.addSubview(back)
        backButton = back

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(titleLabel)

        let group = NSButton(checkboxWithTitle: "Group by Kind", target: self, action: #selector(toggleGroup))
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
    private func reloadListing() {
        rootNodes = makeNodes(forDirectory: rootURL)
        content.reloadData()
    }

    @objc private func sidebarClicked() {
        guard sidebar.clickedRow >= 0,
              let item = sidebar.item(atRow: sidebar.clickedRow) as? SidebarItem,
              let url = item.url else { return }
        history.removeAll()
        updateBackButton()
        loadRoot(url)
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
                items.sort(by: ordering(foldersFirst: false))
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
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        let entries: [Entry] = contents.map { item in
            let values = try? item.resourceValues(forKeys: Set(Self.resourceKeys + [.isSymbolicLinkKey]))
            // Symlinks (e.g. ~/Dropbox) report as non-directories, so resolve to
            // the target to classify and navigate them like the real folder.
            let target = resolved(item, isSymlink: values?.isSymbolicLink ?? false)
            let isFolder = (target.isDirectory ?? false) && !(target.isPackage ?? false)
            return Entry(
                url: item,
                isFolder: isFolder,
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

    private func makeSidebarItems() -> [SidebarItem] {
        let fm = FileManager.default
        func loc(_ url: URL?, _ fallback: String) -> SidebarItem? {
            guard let url else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return SidebarItem(title: displayName(url), url: url, icon: icon, isSection: false)
        }
        let home = fm.homeDirectoryForCurrentUser
        let favorites = [
            loc(try? fm.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false), "Desktop"),
            loc(try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false), "Downloads"),
            loc(try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false), "Documents"),
            loc(home, "Home"),
            loc(URL(fileURLWithPath: "/Applications"), "Applications"),
        ].compactMap { $0 }
        let locations = [
            loc(URL(fileURLWithPath: "/"), "Computer"),
        ].compactMap { $0 }
        return [
            SidebarItem(title: "Favorites", url: nil, icon: nil, isSection: true, children: favorites),
            SidebarItem(title: "Locations", url: nil, icon: nil, isSection: true, children: locations),
        ]
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
        case "name": return nameCell(url: node.url!)
        case "size": return textCell((node.isFolder || node.size == 0) ? "--" : Self.byteFormatter.string(fromByteCount: Int64(node.size)),
                                      align: .right, secondary: true)
        case "kind": return textCell(node.kindString, secondary: true)
        case "date": return textCell(node.date == .distantPast ? "" : Self.dateFormatter.string(from: node.date),
                                      secondary: true)
        default:     return nil
        }
    }

    // MARK: Cells

    private func nameCell(url: URL) -> NSView {
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
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        cell.textField?.stringValue = displayName(url)
        return cell
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
