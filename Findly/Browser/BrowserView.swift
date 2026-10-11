import AppKit
import Quartz

/// The drawer's content: a glass backdrop with the sidebar on it, and the file
/// list on a solid card with its toolbar, notices and path bar.
@MainActor
final class BrowserView: NSView, FileListHost {
    let list = FileListController()
    private let sidebar = SidebarController()
    private let navigation: Navigation
    let notice = NoticeBar()
    let empty = EmptyStateView()
    private let pathBar = PathBar()
    private let titleLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let search = NSSearchField()
    private let scope = NSSegmentedControl()
    private var scopeHeight: NSLayoutConstraint!
    private lazy var watcher = FolderWatcher { [weak self] _ in self?.reload() }
    private let spotlight = SpotlightSearch()
    private var loadTask: Task<Void, Never>?
    /// A tag whose files are shown instead of a folder.
    private var shownTag: String?
    private var folderItems: [FileItem] = []
    /// Contents of expanded folders, by folder, so a refresh keeps them open.
    private var childItems: [URL: [FileItem]] = [:]

    var arrangement = Defaults.arrangement {
        didSet {
            Defaults.arrangement = arrangement
            list.applySortIndicator(arrangement)
            render()
        }
    }

    /// Fired after a drag out of the list ends (the drawer re-checks parking).
    var onDragOutEnded: () -> Void = {}
    var initialFirstResponder: NSView { list.outline }
    var isQuickLookActive: Bool { list.isQuickLookActive }
    var isDraggingOut: Bool { list.isDraggingOut }

    init(start: URL) {
        navigation = Navigation(start: start)
        super.init(frame: .zero)
        list.host = self
        list.applySortIndicator(arrangement)
        navigation.onChange = { [weak self] in self?.navigated() }
        sidebar.dropHost = self
        sidebar.onSelect = { [weak self] target in
            switch target {
            case .folder(let url): self?.showFolder(url)
            case .tag(let name): self?.showTag(name)
            }
        }
        sidebar.onError = { [weak self] in self?.notify($0, tone: .error, working: false) }
        pathBar.dropHost = self
        pathBar.onOpen = { [weak self] in self?.showFolder($0) }
        build()
        navigated()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        // A legacy scroller would take a slice of the narrow sidebar; it floats over it instead.
        let sidebarScroll = scrolled(sidebar.outline, OverlayScrollView())

        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        let toolbar = makeToolbar()
        configureScope()
        let listScroll = scrolled(list.outline)
        list.followWidth(of: listScroll.contentView)
        let divider = NSBox()
        divider.boxType = .separator

        for v in [backdrop, sidebarScroll, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [toolbar, scope, notice, listScroll, empty, divider, pathBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        scopeHeight = scope.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor), backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            sidebarScroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            sidebarScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sidebarScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 184),

            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            card.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            toolbar.topAnchor.constraint(equalTo: card.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 46),

            scope.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scope.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scopeHeight,

            notice.topAnchor.constraint(equalTo: scope.bottomAnchor),
            notice.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            notice.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),

            listScroll.topAnchor.constraint(equalTo: notice.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: divider.topAnchor),

            empty.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 30),
            empty.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: -20),

            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: pathBar.topAnchor),

            pathBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func scrolled(_ view: NSView, _ scroll: NSScrollView = NSScrollView()) -> NSScrollView {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // The drawer's hidden title bar would otherwise push the list down.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = view
        return scroll
    }

    private func makeToolbar() -> NSView {
        func iconButton(_ icon: Reicon, _ label: String, _ action: Selector, _ b: NSButton = NSButton()) -> NSButton {
            b.image = Icon.nsImage(icon, size: 16)
            b.target = self
            b.action = action
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = label
            b.setAccessibilityLabel(label)
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        _ = iconButton(.chevronLeft, String(localized: "Back"), #selector(goBack), backButton)
        _ = iconButton(.chevronRight, String(localized: "Forward"), #selector(goForward), forwardButton)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityRole(.staticText)

        let options = iconButton(.category, String(localized: "View Options"), #selector(showViewOptions(_:)))

        search.placeholderString = String(localized: "Search")
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = false
        search.target = self
        search.action = #selector(searchChanged)
        search.controlSize = .regular
        search.widthAnchor.constraint(equalToConstant: 180).isActive = true
        search.setAccessibilityLabel(String(localized: "Search"))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [backButton, forwardButton, titleLabel, spacer, options, search])
        stack.spacing = 6
        stack.setCustomSpacing(12, after: forwardButton)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return stack
    }

    private func configureScope() {
        scope.segmentCount = 2
        scope.setLabel(String(localized: "This Folder"), forSegment: 0)
        scope.setLabel(String(localized: "Subfolders Too"), forSegment: 1)
        scope.segmentStyle = .rounded
        scope.controlSize = .small
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(searchChanged)
        scope.isHidden = true
        scope.setAccessibilityLabel(String(localized: "Search scope"))
    }

    // MARK: Navigation

    private var isSearchingSubfolders: Bool { !searchText.isEmpty && scope.selectedSegment == 1 }
    private var searchText: String { search.stringValue.trimmingCharacters(in: .whitespaces) }

    func showFolder(_ url: URL) {
        let leavingTag = shownTag != nil
        shownTag = nil
        clearSearch()
        if leavingTag, url.standardizedFileURL == navigation.current.standardizedFileURL { return navigated() }
        navigation.go(to: url)
    }

    private func showTag(_ name: String) {
        shownTag = name
        clearSearch()
        spotlight.cancel()
        titleLabel.stringValue = name
        pathBar.show(nil, title: String(localized: "Files tagged “\(name)”"))
        notify(String(localized: "Searching…"), tone: .info, working: true)
        spotlight.tagged(name) { [weak self] urls in self?.showResults(urls) }
    }

    private func clearSearch() {
        search.stringValue = ""
        updateScopeVisibility()
    }

    /// The current folder changed (or was re-opened): reload and update everything around the list.
    private func navigated() {
        let url = navigation.current
        Defaults.lastFolder = url
        childItems = [:]
        backButton.isEnabled = navigation.canGoBack
        forwardButton.isEnabled = navigation.canGoForward
        titleLabel.stringValue = list.displayName(url)
        titleLabel.setAccessibilityLabel(String(localized: "Folder: \(list.displayName(url))"))
        pathBar.show(url)
        sidebar.select(.folder(url))
        list.dropTarget = url
        notice.hide()
        load(scrollToTop: true)
    }

    func open(_ url: URL) {
        if DirectoryReader.isFolder(url) {
            if shownTag != nil || isSearchingSubfolders { shownTag = nil; clearSearch() }
            showFolder(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func goBack() { shownTag = nil; clearSearch(); navigation.goBack() }
    @objc func goForward() { shownTag = nil; clearSearch(); navigation.goForward() }
    func goUp() { shownTag = nil; clearSearch(); navigation.goUp() }

    /// The mouse's side buttons go Back and Forward.
    override func otherMouseUp(with event: NSEvent) {
        guard Defaults.mouseNavEnabled else { return super.otherMouseUp(with: event) }
        switch event.buttonNumber {
        case 3: goBack()
        case 4: goForward()
        default: super.otherMouseUp(with: event)
        }
    }

    // MARK: Loading

    /// Reads the folder (and any expanded subfolders) off the main thread.
    private func load(scrollToTop: Bool = false) {
        guard shownTag == nil, !isSearchingSubfolders else { return }
        let url = navigation.current
        let expanded = scrollToTop ? [] : list.expandedURLs()
        let hidden = Defaults.showHidden
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<([FileItem], [URL: [FileItem]]), DirectoryReader.Failure> in
                do throws(DirectoryReader.Failure) {
                    let items = try DirectoryReader.read(url, showHidden: hidden)
                    var children: [URL: [FileItem]] = [:]
                    for folder in expanded { children[folder] = (try? DirectoryReader.read(folder, showHidden: hidden)) ?? [] }
                    return .success((items, children))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled, url == self.navigation.current else { return }
            switch result {
            case .success(let (items, children)):
                self.folderItems = items
                self.childItems = children
                self.render()
                if scrollToTop { self.list.outline.scrollRowToVisible(0) }
            case .failure(let failure):
                self.folderItems = []
                self.childItems = [:]
                self.render(failure: failure)
            }
            self.watchVisibleFolders()
        }
    }

    func reload() {
        if shownTag != nil || isSearchingSubfolders { return }
        load()
    }

    private func render(failure: DirectoryReader.Failure? = nil) {
        let items = shownTag != nil || isSearchingSubfolders ? folderItems : Arrangement.filter(folderItems, searchText)
        list.show(items, childrenByFolder: childItems, arrangement: arrangement, showsLocations: shownTag != nil || isSearchingSubfolders)
        if let pending = list.pendingSelection {
            list.select(pending)
            list.pendingSelection = nil
        }
        switch failure {
        case .noPermission:
            empty.show(String(localized: "Findly can't open this folder"),
                       detail: String(localized: "macOS needs to let Findly in. Turn on Full Disk Access for Findly, then come back."),
                       action: (String(localized: "Open Full Disk Access Settings"), { FullDiskAccess.openSettings() }))
        case .missing:
            empty.show(String(localized: "This folder no longer exists"),
                       action: (String(localized: "Go to Enclosing Folder"), { [weak self] in self?.goUp() }))
        case nil where items.isEmpty:
            empty.show(searchText.isEmpty ? String(localized: "This folder is empty") : String(localized: "No matches"))
        case nil:
            empty.hide()
        }
    }

    private func watchVisibleFolders() {
        guard shownTag == nil, !isSearchingSubfolders else { return watcher.watch([]) }
        watcher.watch(list.expandedURLs().union([navigation.current]))
    }

    // MARK: Search

    @objc private func searchChanged() {
        updateScopeVisibility()
        spotlight.cancel()
        if isSearchingSubfolders {
            pathBar.show(nil, title: String(localized: "Searching in “\(list.displayName(navigation.current))” and its subfolders"))
            notify(String(localized: "Searching…"), tone: .info, working: true)
            spotlight.names(containing: searchText, under: navigation.current) { [weak self] urls in self?.showResults(urls) }
        } else if shownTag == nil {
            pathBar.show(navigation.current)
            notice.hide()
            load()
        }
    }

    private func updateScopeVisibility() {
        let show = !searchText.isEmpty
        scope.isHidden = !show
        scopeHeight.constant = show ? 28 : 0
    }

    /// Shows Spotlight results as a flat list, with each item's location in the Kind column.
    private func showResults(_ urls: [URL]) {
        Task { [weak self] in
            let items = await Task.detached { urls.compactMap(DirectoryReader.item(for:)) }.value
            guard let self else { return }
            self.folderItems = items
            self.childItems = [:]
            self.notice.hide()
            self.render()
            self.watchVisibleFolders()
        }
    }

    // MARK: View options

    @objc private func showViewOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let group = menu.addItem(withTitle: String(localized: "Group by Kind"), action: #selector(toggleGroup), keyEquivalent: "")
        group.state = arrangement.groupByKind ? .on : .off
        group.target = self
        let hidden = menu.addItem(withTitle: String(localized: "Show Hidden Files"), action: #selector(toggleHiddenFiles), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.state = Defaults.showHidden ? .on : .off
        hidden.target = self
        menu.addItem(.separator())
        let sortMenu = NSMenu()
        for (sort, title) in [(FileSort.name, String(localized: "Name")), (.kind, String(localized: "Kind")),
                              (.dateModified, String(localized: "Date Modified")), (.size, String(localized: "Size"))] {
            let item = sortMenu.addItem(withTitle: title, action: #selector(pickSort(_:)), keyEquivalent: "")
            item.representedObject = sort.rawValue
            item.state = arrangement.sort == sort ? .on : .off
            item.target = self
        }
        menu.addItem(withTitle: String(localized: "Sort By"), action: nil, keyEquivalent: "").submenu = sortMenu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func toggleGroup() { arrangement.groupByKind.toggle() }

    @objc private func pickSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sort = FileSort(rawValue: raw) else { return }
        arrangement.sort = sort
    }

    @objc func toggleHiddenFiles() {
        Defaults.showHidden.toggle()
        load()
    }

    // MARK: FileListHost

    func focusSearch() { window?.makeFirstResponder(search) }

    func notify(_ text: String, tone: NoticeBar.Tone, working: Bool) {
        notice.show(text, tone: tone, working: working)
    }

    func listDidChangeSelection() { watchVisibleFolders() }

    func dragOutEnded() { onDragOutEnded() }

    /// Called each time the drawer slides in.
    func willAppear() {
        sidebar.reload()
        if shownTag == nil, !isSearchingSubfolders { load() }
    }

    override func cancelOperation(_ sender: Any?) {
        if !search.stringValue.isEmpty {
            clearSearch()
            searchChanged()
            window?.makeFirstResponder(list.outline)
        }
    }
}

/// Always uses overlay scrollers, even with "Show scroll bars: Always", which
/// AppKit would otherwise reapply over a plain `scrollerStyle` setting.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
