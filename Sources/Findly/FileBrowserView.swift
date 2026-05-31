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

/// A node in the outline tree: a file/folder, or a category section header
/// (top-level only, when "Group by Kind" is on). A reference type so the outline
/// view keeps stable item identities and we can cache lazily-loaded children.
final class Node {
    enum Kind { case category(FileCategory); case file(URL) }
    let kind: Kind
    fileprivate var loadedChildren: [Node]?
    init(_ kind: Kind) { self.kind = kind }

    var url: URL? { if case .file(let u) = kind { return u }; return nil }
    var category: FileCategory? { if case .category(let c) = kind { return c }; return nil }
}

/// Finder list/tree navigation backed by `NSOutlineView` + FileManager. Folders
/// expand inline with disclosure triangles; a toolbar button picks the sort key
/// and direction and toggles category grouping, which buckets each directory
/// under collapsible section headers.
final class FileBrowserView: NSView {
    private let outline = FileOutlineView()
    private let rootURL: URL
    private var rootNodes: [Node] = []

    /// The view the controller should focus when the drawer slides in.
    var initialFirstResponder: NSView { outline }

    /// True while a QuickLook panel we own is on screen. The controller checks
    /// this so losing key focus to QuickLook doesn't park the drawer.
    var isQuickLookActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    init(root: URL) {
        self.rootURL = root
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(handleDoubleClick)
        outline.onSpaceKey = { [weak self] in self?.toggleQuickLook() }
        outline.onEnterKey = { [weak self] in self?.activateSelection() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = outline

        let toolbar = makeToolbar()
        addSubview(toolbar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        rootNodes = makeNodes(forDirectory: rootURL)
        outline.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedNode: Node? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? Node
    }

    /// URL currently selected, if any. Category headers have no URL.
    var selectedURL: URL? { selectedNode?.url }

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

    /// Rebuild the whole tree with fresh nodes so re-sorting / re-grouping takes
    /// effect at every level. Collapses expansion, which is a fair trade.
    private func reloadListing() {
        rootNodes = makeNodes(forDirectory: rootURL)
        outline.reloadData()
    }

    // MARK: - Open / QuickLook

    @objc private func handleDoubleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        open(node)
    }

    /// Enter on the selected row.
    private func activateSelection() {
        guard let node = selectedNode else { return }
        open(node)
    }

    /// Files open in their app; folders and category headers toggle expansion.
    private func open(_ node: Node) {
        if let url = node.url, isLeaf(url) {
            NSWorkspace.shared.open(url)
        } else if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
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

    /// Top-level nodes for a directory, with the current sort/group applied.
    /// When grouping, returns category headers each pre-loaded with their files;
    /// otherwise a flat, folders-first list. Folder nodes load their own
    /// children lazily via `children(of:)`.
    private func makeNodes(forDirectory url: URL) -> [Node] {
        let entries = entries(of: url)
        if Defaults.groupByKind {
            var buckets: [FileCategory: [Entry]] = [:]
            for entry in entries { buckets[entry.category, default: []].append(entry) }
            return FileCategory.allCases.compactMap { category in
                guard var items = buckets[category], !items.isEmpty else { return nil }
                items.sort(by: ordering(foldersFirst: false))
                let node = Node(.category(category))
                node.loadedChildren = items.map { Node(.file($0.url)) }
                return node
            }
        } else {
            return entries.sorted(by: ordering(foldersFirst: true)).map { Node(.file($0.url)) }
        }
    }

    private func children(of node: Node) -> [Node] {
        if let cached = node.loadedChildren { return cached }
        let result: [Node]
        switch node.kind {
        case .category:
            result = []   // categories are always pre-loaded in makeNodes
        case .file(let url):
            result = isLeaf(url) ? [] : makeNodes(forDirectory: url)
        }
        node.loadedChildren = result
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
    /// opening them launches the file instead of trying to descend.
    private func isLeaf(_ url: URL) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = vals?.isDirectory ?? false
        let isPackage = vals?.isPackage ?? false
        return !isDir || isPackage
    }
}

// MARK: - NSOutlineView data source / delegate

extension FileBrowserView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return rootNodes.count }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return rootNodes[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        switch node.kind {
        case .category:      return true
        case .file(let url): return !isLeaf(url)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.category != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.category == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let category = node.category {
            return groupCell(outlineView, title: category.title.uppercased())
        }
        return fileCell(outlineView, url: node.url!)
    }

    private func fileCell(_ outlineView: NSOutlineView, url: URL) -> NSView {
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
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

    private func groupCell(_ outlineView: NSOutlineView, title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("group")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            cell.addSubview(label)
            cell.textField = label
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

/// NSOutlineView subclass that routes the keys Finder users expect — space for
/// QuickLook, Return to open — back to the owning view.
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
