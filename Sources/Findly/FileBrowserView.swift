import AppKit
import Quartz

/// Finder-style column (Miller) navigation backed by `NSBrowser` + FileManager.
/// `NSBrowser` is the system control Finder's column view descends from, so we
/// get the drill-right hierarchy, keyboard arrows and selection almost for
/// free; we add file icons, open-on-double-click/Enter and spacebar QuickLook.
final class FileBrowserView: NSView {
    let browser = FileBrowser()
    private let root: URL
    /// Cache children per directory so `NSBrowser`'s repeated child(_:ofItem:)
    /// calls get stable, identical item objects.
    private var childrenCache: [String: [URL]] = [:]

    /// True while a QuickLook panel we own is on screen. The controller checks
    /// this so losing key focus to QuickLook doesn't park the drawer.
    var isQuickLookActive: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    init(root: URL) {
        self.root = root
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

        addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: topAnchor),
            browser.bottomAnchor.constraint(equalTo: bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in self?.debugInspectCell() }
        }
    }

    private func debugInspectCell() {
        guard let cell = browser.loadedCell(atRow: 0, column: 0) as? NSCell else {
            NSLog("Findly DEBUG no loaded cell"); return
        }
        let attr = cell.attributedStringValue
        var hasAttachment = false
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if v != nil { hasAttachment = true }
        }
        NSLog("Findly DEBUG cell=\(type(of: cell)) ovType=\(type(of: cell.objectValue as Any)) attrLen=\(attr.length) hasAttachment=\(hasAttachment) str=[\(attr.string)]")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// URL currently selected in the deepest open column, if any.
    var selectedURL: URL? {
        let col = browser.selectedColumn
        guard col >= 0 else { return nil }
        return browser.item(atRow: browser.selectedRow(inColumn: col), inColumn: col) as? URL
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

    private func children(of url: URL) -> [URL] {
        if let cached = childrenCache[url.path] { return cached }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = contents.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        childrenCache[url.path] = sorted
        return sorted
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
}

// MARK: - NSBrowserDelegate (item-based)

extension FileBrowserView: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: (item as? URL) ?? root).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        children(of: (item as? URL) ?? root)[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let url = item as? URL else { return false }
        return isLeaf(url)
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let url = item as? URL else { return "" }
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
