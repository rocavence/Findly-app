import AppKit

/// Finder's sidebar: Favorites, iCloud, Locations and Tags, as a source list.
/// Symbols take the system accent, as in Finder; volumes have an eject button.
@MainActor
final class SidebarController: NSObject {
    let outline = NSOutlineView()
    private(set) var sections: [SidebarSection] = []
    /// Clicked a folder or a tag. Clicking the selected one again also fires (it re-opens).
    var onSelect: (SidebarItem.Target) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    /// Accepts files dropped on a folder row.
    weak var dropHost: FileListHost?
    private var volumeTokens: [NSObjectProtocol] = []
    private var syncing = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setAccessibilityLabel(String(localized: "Sidebar"))
        reload()
        // Drives plugging in, ejecting and network mounts.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        volumeTokens.append(NotificationCenter.default.addObserver(forName: .findlySidebarChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    /// Re-reads Finder's sidebar, keeping the selection.
    func reload() {
        let fresh = FinderSidebar.sections()
        guard fresh != sections else { return }
        let selected = selectedTarget
        sections = fresh
        syncing = true
        outline.reloadData()
        let collapsed = Defaults.collapsedSidebarSections
        for section in sections where !collapsed.contains(section.kind.rawValue) { outline.expandItem(SectionBox.box(section.kind)) }
        syncing = false
        if let selected { select(selected) }
    }

    private var selectedTarget: SidebarItem.Target? {
        (outline.item(atRow: outline.selectedRow) as? ItemBox)?.item.target
    }

    /// Highlights the row for where the list is (or nothing, if it's not in the sidebar).
    func select(_ target: SidebarItem.Target?) {
        syncing = true
        defer { syncing = false }
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? ItemBox)?.item.target.matches(target) ?? false }
        if let row { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
    }

    @objc private func clicked() {
        guard outline.clickedRow >= 0 else { return }
        let item = outline.item(atRow: outline.clickedRow)
        if let section = item as? SectionBox {
            // Clicking a section's title folds it, as the chevron that appears on hover does.
            outline.isItemExpanded(section) ? outline.collapseItem(section) : outline.expandItem(section)
        } else if let box = item as? ItemBox {
            onSelect(box.item.target)
        }
    }

    /// Remembers which sections are folded.
    private func sectionFolded(_ notification: Notification, _ folded: Bool) {
        guard !syncing, let section = notification.userInfo?["NSObject"] as? SectionBox else { return }
        var collapsed = Defaults.collapsedSidebarSections
        if folded { collapsed.insert(section.kind.rawValue) } else { collapsed.remove(section.kind.rawValue) }
        Defaults.collapsedSidebarSections = collapsed
    }

    @objc private func eject(_ sender: NSButton) {
        guard let url = URL(string: sender.identifier?.rawValue ?? "") else { return }
        if let message = FinderSidebar.eject(url) { onError(message) } else { reload() }
    }

    /// Sections and items wrapped as stable objects, since NSOutlineView keys rows by identity.
    final class SectionBox {
        let kind: SidebarSection.Kind
        private init(_ kind: SidebarSection.Kind) { self.kind = kind }
        @MainActor private static var boxes: [SidebarSection.Kind: SectionBox] = [:]
        @MainActor static func box(_ kind: SidebarSection.Kind) -> SectionBox {
            if let b = boxes[kind] { return b }
            let b = SectionBox(kind); boxes[kind] = b; return b
        }
    }

    final class ItemBox {
        let item: SidebarItem
        init(_ item: SidebarItem) { self.item = item }
    }

    private var itemBoxes: [SidebarItem: ItemBox] = [:]
    private func box(_ item: SidebarItem) -> ItemBox {
        if let b = itemBoxes[item] { return b }
        let b = ItemBox(item); itemBoxes[item] = b; return b
    }
}

private extension SidebarItem.Target {
    func matches(_ other: SidebarItem.Target?) -> Bool {
        switch (self, other) {
        case (.folder(let a), .folder(let b)?): a.standardizedFileURL.path == b.standardizedFileURL.path
        case (.tag(let a), .tag(let b)?): a == b
        default: false
        }
    }
}

extension SidebarController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let section = item as? SectionBox else { return item == nil ? sections.count : 0 }
        return sections.first { $0.kind == section.kind }?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let section = item as? SectionBox else { return SectionBox.box(sections[index].kind) }
        return box(sections.first { $0.kind == section.kind }!.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SectionBox }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SectionBox }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ItemBox }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { item is SectionBox }
    func outlineViewItemDidCollapse(_ notification: Notification) { sectionFolded(notification, true) }
    func outlineViewItemDidExpand(_ notification: Notification) { sectionFolded(notification, false) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SectionBox {
            let cell = outlineView.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = .init("header")
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = sections.first { $0.kind == section.kind }?.title ?? ""
            return cell
        }
        guard let item = (item as? ItemBox)?.item else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("item"), owner: self) as? SidebarCell ?? SidebarCell()
        cell.configure(item, ejectTarget: self, ejectAction: #selector(eject(_:)))
        return cell
    }

    // Drops onto a folder row: move or copy there, like Finder.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let url = (item as? ItemBox)?.item.url, index == NSOutlineViewDropOnItemIndex else { return [] }
        return DropRules.operation(info, into: url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        DropRules.perform(info, into: (item as? ItemBox)?.item.url, host: dropHost)
    }
}

/// A sidebar row: symbol (or the item's own icon, or a tag dot), name, and an eject button for volumes.
final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = .init("item")
        label.lineBreakMode = .byTruncatingTail
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: String(localized: "Eject"))
        ejectButton.isBordered = false
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        // A stack drops the eject button from the layout while it's hidden, so names get the room.
        let stack = NSStackView(views: [icon, label, ejectButton])
        stack.spacing = 6
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)   // stretches, so eject sits at the right
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 16),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: SidebarItem, ejectTarget: AnyObject, ejectAction: Selector) {
        label.stringValue = item.title
        switch item.target {
        case .tag:
            icon.image = Self.tagDot(item.tagColor)
            icon.contentTintColor = nil
        case .folder(let url):
            if let provided = item.providerSymbol?.image {
                icon.image = provided
                icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
                icon.contentTintColor = .controlAccentColor
            } else if let symbol = item.symbol {
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
                icon.contentTintColor = .controlAccentColor   // Finder tints with the system accent
            } else {
                icon.image = FileIcons.icon(for: url)
                icon.contentTintColor = nil
            }
        }
        ejectButton.isHidden = !item.ejectable
        ejectButton.identifier = .init(item.url?.absoluteString ?? "")
        ejectButton.target = ejectTarget
        ejectButton.action = ejectAction
        ejectButton.setAccessibilityLabel(String(localized: "Eject \(item.title)"))
        setAccessibilityLabel(item.title)
    }

    /// Finder's tag colours, by its 0–7 index (0 is "no colour").
    static func tagDot(_ index: Int) -> NSImage {
        let colors = NSWorkspace.shared.fileLabelColors
        let color = index > 0 && index < colors.count ? colors[index] : NSColor.tertiaryLabelColor
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
