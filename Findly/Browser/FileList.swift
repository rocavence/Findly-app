import AppKit
import Carbon.HIToolbox
import Quartz

/// A row in the outline: a kind header, or an item whose folder children load on demand.
final class FileNode {
    let row: Arrangement.Row
    var children: [FileNode]?

    init(_ row: Arrangement.Row) { self.row = row }

    var item: FileItem? { if case .item(let i) = row { i } else { nil } }
    var url: URL? { item?.url }
}

/// What the list asks of the browser around it.
@MainActor
protocol FileListHost: AnyObject, Sendable {
    func open(_ url: URL)
    func goBack()
    func goForward()
    func goUp()
    func focusSearch()
    func toggleHiddenFiles()
    func notify(_ text: String, tone: NoticeBar.Tone, working: Bool)
    func listDidChangeSelection()
    func dragOutEnded()
    var arrangement: Arrangement { get set }
}

/// Finder's list view: columns, kind groups, folders that expand in place,
/// inline rename, Finder's shortcuts, Quick Look, and drag and drop.
@MainActor
final class FileListController: NSObject {
    let outline = FileOutlineView()
    weak var host: FileListHost?
    private(set) var rootNodes: [FileNode] = []
    /// While a drag is leaving the list; the drawer won't park mid-drag.
    private(set) var isDraggingOut = false
    private var renaming: URL?
    private var contextURLs: [URL] = []
    /// Results mode (search across subfolders, or a tag): a flat list with locations shown.
    private(set) var showsLocations = false
    /// The folder shown, where drops on empty space go.
    var dropTarget: URL?

    override init() {
        super.init()
        configure()
    }

    // MARK: Setup

    private func configure() {
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("name", String(localized: "Name"), 260, 120),
            ("size", String(localized: "Size"), 76, 60),
            ("kind", String(localized: "Kind"), 130, 80),
            ("date", String(localized: "Date Modified"), 160, 110),
        ]
        for (key, title, width, min) in columns {
            let column = NSTableColumn(identifier: .init(key))
            column.title = title
            column.width = width
            column.minWidth = min
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            column.headerCell.font = .systemFont(ofSize: 11)
            column.headerCell.textColor = .secondaryLabelColor
            if key == "size" { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if key == "name" { outline.outlineTableColumn = column }
        }
        outline.style = .plain
        outline.headerView = PlainHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.rowHeight = BrowserStyle.rowHeight
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        outline.allowsColumnReordering = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        outline.setAccessibilityLabel(String(localized: "Files"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
    }

    // MARK: Column widths

    /// Widths Size, Kind and Date go back to when there's room (the defaults, or as the user dragged them).
    /// Kept in Findly's own preference rather than AppKit's column autosave, which would also
    /// save the squeezed widths of a narrow drawer.
    private var preferredWidths: [String: CGFloat] = ["size": 76, "kind": 130, "date": 160]
        .merging(Defaults.columnWidths) { _, saved in saved }
    private var fitting = false

    /// Starts following the list's width and the user's column drags.
    func followWidth(of clip: NSClipView) {
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitColumns() }
        }
        NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: outline, queue: .main) { [weak self] note in
            nonisolated(unsafe) let resized = note.userInfo?["NSTableColumn"] as? NSTableColumn
            MainActor.assumeIsolated {
                guard let self, !self.fitting, let column = resized,
                      self.preferredWidths[column.identifier.rawValue] != nil else { return }
                self.preferredWidths[column.identifier.rawValue] = column.width
                Defaults.columnWidths = self.preferredWidths
                self.fitColumns()
            }
        }
    }

    /// Name takes what's left. When it's tight, Date gives way first, then Kind, then Size, so names stay readable.
    func fitColumns() {
        guard let available = outline.enclosingScrollView?.contentView.bounds.width, available > 0,
              let name = outline.tableColumn(withIdentifier: .init("name")) else { return }
        fitting = true
        defer { fitting = false }
        let spacing = outline.intercellSpacing.width * CGFloat(outline.numberOfColumns)
        let others = ["date", "kind", "size"].compactMap { outline.tableColumn(withIdentifier: .init($0)) }
        var widths = Dictionary(uniqueKeysWithValues: others.map { ($0.identifier.rawValue, preferredWidths[$0.identifier.rawValue] ?? $0.width) })
        let nameWanted: CGFloat = 220
        var overflow = nameWanted + widths.values.reduce(0, +) + spacing - available
        for column in others where overflow > 0 {
            let key = column.identifier.rawValue
            let give = min(overflow, widths[key]! - column.minWidth)
            widths[key]! -= give
            overflow -= give
        }
        for column in others { column.width = widths[column.identifier.rawValue]! }
        name.width = max(name.minWidth, available - widths.values.reduce(0, +) - spacing)
        fitDateFormat()
    }

    /// Index into `BrowserStyle.dateFormatters`: the longest format that fits the Date column.
    private var dateFormat = 0

    private func fitDateFormat() {
        guard let column = outline.tableColumn(withIdentifier: .init("date")) else { return }
        // A wide sample date, so every date in the list fits once this one does.
        let sample = DateComponents(calendar: .current, year: 2026, month: 12, day: 28, hour: 22, minute: 58).date ?? .now
        let font = NSFont.systemFont(ofSize: BrowserStyle.textSize)
        let room = column.width - 12
        let fitting = BrowserStyle.dateFormatters.firstIndex {
            ($0.string(from: sample) as NSString).size(withAttributes: [.font: font]).width <= room
        } ?? BrowserStyle.dateFormatters.count - 1
        guard fitting != dateFormat else { return }
        dateFormat = fitting
        let index = outline.column(withIdentifier: .init("date"))
        guard index >= 0, outline.numberOfRows > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: [index])
    }

    func applySortIndicator(_ arrangement: Arrangement) {
        guard outline.sortDescriptors.first?.key != arrangement.sort.columnKey
                || outline.sortDescriptors.first?.ascending != arrangement.ascending else { return }
        outline.sortDescriptors = [NSSortDescriptor(key: arrangement.sort.columnKey, ascending: arrangement.ascending)]
    }

    // MARK: Showing items

    /// Replaces the list, keeping expanded folders, the selection and the scroll position.
    /// `childrenByFolder` holds already-read contents for folders that were expanded.
    func show(_ items: [FileItem], childrenByFolder: [URL: [FileItem]], arrangement: Arrangement, showsLocations: Bool) {
        let expanded = expandedURLs()
        let selected = Set(selectedURLs)
        let scroll = outline.enclosingScrollView?.contentView.bounds.origin
        self.showsLocations = showsLocations
        outline.tableColumn(withIdentifier: .init("kind"))?.title = showsLocations ? String(localized: "Location") : String(localized: "Kind")
        rootNodes = arrangement.rows(items).map(FileNode.init)
        func attach(_ nodes: [FileNode]) {
            for node in nodes {
                guard let url = node.url, let kids = childrenByFolder[url.standardizedFileURL] else { continue }
                node.children = arrangement.rows(kids).compactMap { row in if case .item = row { FileNode(row) } else { nil } }
                attach(node.children!)
            }
        }
        attach(rootNodes)
        outline.reloadData()
        restoreExpansion(rootNodes, expanded)
        let rows = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? FileNode)?.url.map(selected.contains) ?? false })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let scroll { outline.enclosingScrollView?.contentView.scroll(to: scroll) }
        outline.enclosingScrollView?.reflectScrolledClipView(outline.enclosingScrollView!.contentView)
    }

    private func restoreExpansion(_ nodes: [FileNode], _ expanded: Set<URL>) {
        for node in nodes {
            guard let url = node.url?.standardizedFileURL, expanded.contains(url), node.children != nil else { continue }
            outline.expandItem(node)
            restoreExpansion(node.children ?? [], expanded)
        }
    }

    /// Folders currently expanded, which the watcher should also watch.
    func expandedURLs() -> Set<URL> {
        Set((0..<outline.numberOfRows).compactMap { row -> URL? in
            guard let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) else { return nil }
            return node.url?.standardizedFileURL
        })
    }

    var selectedURLs: [URL] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
    }

    func select(_ url: URL) {
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.url?.standardizedFileURL == url.standardizedFileURL }
        if let row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: Opening

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode, let url = node.url else { return }
        host?.open(url)
    }

    private func openSelection() {
        let urls = selectedURLs
        if urls.count == 1 { host?.open(urls[0]) } else { urls.forEach { NSWorkspace.shared.open($0) } }
    }

    // MARK: Keyboard (Finder's shortcuts)

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (Int(event.keyCode), flags) {
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            beginRename(); return true
        case (kVK_DownArrow, .command), (kVK_ANSI_O, .command):
            openSelection(); return true
        case (kVK_Delete, .command):
            trash(selectedURLs); return true
        case (kVK_ANSI_LeftBracket, .command):
            host?.goBack(); return true
        case (kVK_ANSI_RightBracket, .command):
            host?.goForward(); return true
        case (kVK_UpArrow, .command):
            host?.goUp(); return true
        case (kVK_ANSI_F, .command):
            host?.focusSearch(); return true
        case (kVK_ANSI_Period, [.command, .shift]):
            host?.toggleHiddenFiles(); return true
        case (kVK_Space, []):
            toggleQuickLook(fullScreen: false); return true
        case (kVK_Space, .option):
            toggleQuickLook(fullScreen: true); return true
        default:
            return false
        }
    }

    // MARK: Rename in place

    func beginRename() {
        let urls = selectedURLs
        guard urls.count == 1, let url = urls.first else { return }
        let row = outline.selectedRow
        let column = outline.column(withIdentifier: .init("name"))
        guard row >= 0, column >= 0, let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = url
        field.isEditable = true
        field.stringValue = url.lastPathComponent   // the real name, with extension
        field.delegate = self
        outline.window?.makeFirstResponder(field)
        // Select the name without its extension, as Finder does.
        let name = url.lastPathComponent as NSString
        let stem = DirectoryReader.isFolder(url) || name.pathExtension.isEmpty ? name.length : name.deletingPathExtension.count
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    private func finishRename(_ field: NSTextField, commit: Bool) {
        guard let url = renaming else { return }
        renaming = nil
        field.isEditable = false
        let newName = field.stringValue
        outline.window?.makeFirstResponder(outline)
        guard commit else { return outline.reloadData() }
        do {
            let renamed = try FileOperations.rename(url, to: newName)
            pendingSelection = renamed
        } catch {
            host?.notify(error.localizedDescription, tone: .error, working: false)
            field.stringValue = displayName(url)
        }
    }

    /// Selected after the next refresh (a renamed or dropped item).
    var pendingSelection: URL?

    // MARK: Trash

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let failed = FileOperations.trash(urls)
        if !failed.isEmpty {
            host?.notify(failed.count == 1
                         ? String(localized: "“\(failed[0].lastPathComponent)” couldn't be moved to the Trash.")
                         : String(localized: "\(failed.count) items couldn't be moved to the Trash."), tone: .error, working: false)
        }
    }

    // MARK: Quick Look

    var isQuickLookActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    func toggleQuickLook(fullScreen: Bool) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selectedURLs.isEmpty else { return }
        panel.updateController()
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        if fullScreen { panel.enterFullScreenMode(nil, withOptions: nil) }
    }

    func displayName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
    }
}

// MARK: - Data source and cells

extension FileListController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rootNodes.count }
        if node.children == nil { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rootNodes[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.item?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .header = (item as? FileNode)?.row { true } else { false }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileNode)?.item != nil
    }

    /// Reads an expanded folder off the main thread, then fills it in.
    private func loadChildren(of node: FileNode) {
        guard let url = node.url else { node.children = []; return }
        node.children = []
        let arrangement = host?.arrangement ?? Arrangement()
        Task { [weak self] in
            let items = await Task.detached { (try? DirectoryReader.read(url)) ?? [] }.value
            node.children = arrangement.rows(items).compactMap { row in if case .item = row { FileNode(row) } else { nil } }
            self?.outline.reloadItem(node, reloadChildren: true)
            self?.host?.listDidChangeSelection()   // lets the browser watch the newly expanded folder
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isQuickLookActive { QLPreviewPanel.shared()?.reloadData() }
        host?.listDidChangeSelection()
    }

    func outlineViewItemDidExpand(_ notification: Notification) { host?.listDidChangeSelection() }
    func outlineViewItemDidCollapse(_ notification: Notification) { host?.listDidChangeSelection() }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key, var arrangement = host?.arrangement else { return }
        let sort = FileSort(columnKey: key)
        guard sort != arrangement.sort || descriptor.ascending != arrangement.ascending else { return }
        arrangement.sort = sort
        arrangement.ascending = descriptor.ascending
        host?.arrangement = arrangement
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView.makeView(withIdentifier: RoundedRowView.id, owner: self) as? RoundedRowView ?? RoundedRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        if case .header(let category) = node.row {
            guard tableColumn == nil || tableColumn?.identifier.rawValue == "name" else { return nil }
            return headerCell(category.title)
        }
        guard let file = node.item else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "name": return nameCell(file)
        case "size":
            return textCell(file.isFolder || file.size == 0 ? "--" : BrowserStyle.byteFormatter.string(fromByteCount: Int64(file.size)), align: .right)
        case "kind":
            return textCell(showsLocations ? displayName(file.url.deletingLastPathComponent()) : file.kind)
        case "date":
            return textCell(file.date == .distantPast ? "" : BrowserStyle.dateFormatters[dateFormat].string(from: file.date))
        default: return nil
        }
    }

    private func nameCell(_ file: FileItem) -> NSView {
        let id = NSUserInterfaceItemIdentifier("name")
        let cell = (outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.isScrollable = false
            for v in [icon, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = FileIcons.icon(for: file)
        cell.textField?.font = .systemFont(ofSize: BrowserStyle.textSize)
        cell.textField?.stringValue = file.name
        cell.textField?.isEditable = false
        cell.setAccessibilityLabel(file.isFolder ? String(localized: "\(file.name), folder") : file.name)
        return cell
    }

    private func textCell(_ text: String, align: NSTextAlignment = .left) -> NSView {
        let id = NSUserInterfaceItemIdentifier("text")
        let cell = (outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.font = .systemFont(ofSize: BrowserStyle.textSize)
        cell.textField?.stringValue = text
        cell.textField?.alignment = align
        cell.textField?.textColor = .secondaryLabelColor
        return cell
    }

    private func headerCell(_ title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("header")
        let cell = (outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2 + FileOutlineView.sideInset),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = title
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel(String(localized: "\(title) section"))
        return cell
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        isDraggingOut = true
        // Dragging a row that isn't selected selects it, as in Finder, so what's dragged stays highlighted.
        let rows = IndexSet(draggedItems.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        if !rows.isSubset(of: outlineView.selectedRowIndexes) {
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingOut = false
        host?.dragOutEnded()
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !showsLocations else { return [] }
        if let node = item as? FileNode, node.item?.isFolder == true {
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return DropRules.operation(info, into: dropFolder(item))
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        DropRules.perform(info, into: dropFolder(item), host: host)
    }

    private func dropFolder(_ item: Any?) -> URL? {
        if let node = item as? FileNode, node.item?.isFolder == true { return node.url }
        return dropTarget
    }

}

/// Finder's drop rules, shared by the list and the path bar.
@MainActor
enum DropRules {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Move within a volume, copy across; never into itself or a subfolder.
    static func operation(_ info: NSDraggingInfo, into folder: URL?) -> NSDragOperation {
        guard let folder else { return [] }
        let sources = urls(info)
        guard let first = sources.first else { return [] }
        let dest = folder.resolvingSymlinksInPath().path
        for s in sources {
            let p = s.resolvingSymlinksInPath().path
            if dest == p || dest.hasPrefix(p + "/") { return [] }
        }
        let mask = info.draggingSourceOperationMask
        if FileOperations.sameVolume(first, folder) {
            return mask.contains(.move) ? .move : mask.contains(.copy) ? .copy : []
        }
        return mask.contains(.copy) ? .copy : []
    }

    static func perform(_ info: NSDraggingInfo, into folder: URL?, host: FileListHost?) -> Bool {
        guard let folder else { return false }
        let op = operation(info, into: folder)
        let sources = urls(info)
        guard !sources.isEmpty, op == .move || op == .copy else { return false }
        // No progress or "Done" message, as in Finder; only failures are reported.
        Task { @MainActor [weak host] in
            let failed = await FileOperations.transfer(sources, to: folder.resolvingSymlinksInPath(), op == .move ? .move : .copy)
            if failed.count == 1 {
                host?.notify(String(localized: "“\(failed[0].lastPathComponent)” couldn't be copied or moved."), tone: .error, working: false)
            } else if failed.count > 1 {
                host?.notify(String(localized: "\(failed.count) items couldn't be copied or moved."), tone: .error, working: false)
            }
        }
        return true
    }
}

// MARK: - Rename field

extension FileListController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? NSTextField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(field, commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(field, commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, renaming != nil else { return }
        finishRename(field, commit: true)
    }
}

// MARK: - Quick Look

extension FileListController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selectedURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> NSURL? in
            let urls = selectedURLs
            return index < urls.count ? urls[index] as NSURL : nil
        }
    }

    /// Arrow keys move the selection, and the preview follows (Finder's behaviour).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            nonisolated(unsafe) let key = event
            MainActor.assumeIsolated {
                outline.keyDown(with: key)
                QLPreviewPanel.shared()?.reloadData()
            }
            return true
        default:
            return false
        }
    }

    /// The row icon's place on screen, so the preview zooms out of and back into it.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item?.previewItemURL else { return .zero }
        return MainActor.assumeIsolated {
            guard let window = outline.window, window.isVisible else { return .zero }
            let column = outline.column(withIdentifier: .init("name"))
            let visible = outline.rows(in: outline.visibleRect)
            for row in visible.lowerBound..<visible.upperBound {
                guard (outline.item(atRow: row) as? FileNode)?.url == url,
                      let icon = (outline.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.imageView else { continue }
                return window.convertToScreen(icon.convert(icon.bounds, to: nil))
            }
            return .zero
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL else { return nil }
        return MainActor.assumeIsolated { NSWorkspace.shared.icon(forFile: url.path) }
    }
}

// MARK: - Context menu

extension FileListController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.clickedRow
        guard clicked >= 0, let url = (outline.item(atRow: clicked) as? FileNode)?.url else { contextURLs = []; return }
        contextURLs = outline.selectedRowIndexes.contains(clicked) ? selectedURLs : [url]
        let many = contextURLs.count > 1
        func add(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        add(many ? String(localized: "Open \(contextURLs.count) Items") : String(localized: "Open"), #selector(menuOpen), key: "o")
        add(many ? String(localized: "Quick Look \(contextURLs.count) Items") : String(localized: "Quick Look"), #selector(menuQuickLook), key: " ", mods: [])
        add(String(localized: "Reveal in Finder"), #selector(menuReveal))
        menu.addItem(.separator())
        if !many { add(String(localized: "Rename"), #selector(menuRename), key: "\r", mods: []) }
        add(String(localized: "Move to Trash"), #selector(menuTrash), key: String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
    }

    @objc private func menuOpen() {
        if contextURLs.count == 1 { host?.open(contextURLs[0]) } else { contextURLs.forEach { NSWorkspace.shared.open($0) } }
    }

    @objc private func menuQuickLook() {
        selectOnly(contextURLs)
        toggleQuickLook(fullScreen: false)
    }

    @objc private func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting(contextURLs) }

    @objc private func menuRename() {
        selectOnly(contextURLs)
        beginRename()
    }

    @objc private func menuTrash() { trash(contextURLs) }

    private func selectOnly(_ urls: [URL]) {
        let set = Set(urls)
        let rows = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? FileNode)?.url.map(set.contains) ?? false })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }
}

/// The outline view, handing keystrokes to the controller first.
final class FileOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?

    /// Room between the card's edges and the rows; the header still runs edge to edge.
    static let sideInset: CGFloat = 8

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: Self.sideInset, dy: 0)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if column == 0 { frame.origin.x += Self.sideInset; frame.size.width -= Self.sideInset }
        if column == numberOfColumns - 1 { frame.size.width -= Self.sideInset }
        return frame
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = delegate as? QLPreviewPanelDataSource
            panel.delegate = delegate as? QLPreviewPanelDelegate
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

/// A row whose selection is a rounded rectangle, as in Finder's list.
private final class RoundedRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
        // The row can run past the visible width; round the corners inside what's on screen.
        var rect = bounds
        if let visible = enclosingScrollView?.contentView.bounds.width { rect.size.width = min(rect.width, visible) }
        NSBezierPath(roundedRect: rect.insetBy(dx: FileOutlineView.sideInset, dy: 0.5), xRadius: 5, yRadius: 5).fill()
    }
}

/// The column titles on the card's own colour, with Finder's thin dividers, instead of
/// the lighter header bar AppKit draws. Clicking to sort and dragging to resize stay AppKit's.
final class PlainHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        let sort = table.sortDescriptors.first
        for (index, column) in table.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            if index < table.numberOfColumns - 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: rect.maxX - 1, y: rect.minY + 6, width: 1, height: rect.height - 12).fill()
            }
            let sorted = sort?.key == column.sortDescriptorPrototype?.key
            let cell = column.headerCell
            let style = NSMutableParagraphStyle()
            style.alignment = cell.alignment
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: column.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: sorted ? .semibold : .regular),
                .foregroundColor: sorted ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
            let height = title.size().height
            var text = rect.insetBy(dx: 8, dy: 0)
            if sorted { text.size.width -= 14 }
            text.origin.y = rect.midY - height / 2
            text.size.height = height
            title.draw(in: text)
            if sorted, let sort, let chevron = NSImage(systemSymbolName: sort.ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
                let tinted = NSImage(size: chevron.size, flipped: false) { r in
                    chevron.draw(in: r)
                    NSColor.secondaryLabelColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.maxX - 8 - chevron.size.width, y: rect.midY - chevron.size.height / 2,
                                       width: chevron.size.width, height: chevron.size.height))
            }
        }
    }
}
