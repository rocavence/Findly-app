import AppKit

/// The folder's path along the bottom, as in Finder: each folder is a button
/// that opens it, and accepts files dropped on it.
@MainActor
final class PathBar: NSView {
    var onOpen: (URL) -> Void = { _ in }
    weak var dropHost: FileListHost?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Path"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `url`'s folders from the volume down. A plain title replaces it for results.
    func show(_ url: URL?, title: String? = nil) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            return
        }
        guard let url else { return }
        var chain: [URL] = []
        var cursor = url.standardizedFileURL
        while true {
            chain.insert(cursor, at: 0)
            if isVolumeRoot(cursor) { break }
            let up = cursor.deletingLastPathComponent()
            if up.path == cursor.path { break }
            cursor = up
        }
        for (i, folder) in chain.enumerated() {
            if i > 0 {
                let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
                chevron.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
                chevron.contentTintColor = .tertiaryLabelColor
                stack.addArrangedSubview(chevron)
            }
            let segment = PathSegment(folder, isLast: i == chain.count - 1)
            segment.onOpen = { [weak self] in self?.onOpen($0) }
            segment.dropHost = dropHost
            stack.addArrangedSubview(segment)
        }
        layoutSubtreeIfNeeded()
        scroll.documentView?.scroll(NSPoint(x: max(0, stack.fittingSize.width - scroll.bounds.width), y: 0))
    }

    private func isVolumeRoot(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One folder in the path: icon and name; click opens, drop moves or copies into it.
private final class PathSegment: NSButton {
    let url: URL
    var onOpen: (URL) -> Void = { _ in }
    weak var dropHost: FileListHost?
    private var dropHighlight = false { didSet { needsDisplay = true } }

    init(_ url: URL, isLast: Bool) {
        self.url = url
        super.init(frame: .zero)
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        title = name
        image = FileIcons.icon(for: url)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        font = .systemFont(ofSize: 11, weight: isLast ? .medium : .regular)
        contentTintColor = isLast ? .labelColor : .secondaryLabelColor
        target = self
        action = #selector(open)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func open() { onOpen(url) }

    override func draw(_ dirtyRect: NSRect) {
        if dropHighlight {
            BrowserStyle.accent.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = MainActor.assumeIsolated { DropRules.operation(sender, into: url) }
        dropHighlight = !op.isEmpty
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { DropRules.operation(sender, into: url) }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        return MainActor.assumeIsolated { DropRules.perform(sender, into: url, host: dropHost) }
    }
}
