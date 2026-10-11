import AppKit

/// Shared look for the drawer's AppKit pieces: list text follows Finder's
/// list-view text size, icons stay 16 pt.
@MainActor
enum BrowserStyle {
    /// Finder's List-view text size (View › Show View Options), 13 if unset.
    static let textSize: CGFloat = {
        let defaults = UserDefaults(suiteName: "com.apple.finder")
        for key in ["StandardViewSettings", "FK_StandardViewSettings"] {
            if let list = (defaults?.dictionary(forKey: key))?["ListViewSettings"] as? [String: Any],
               let size = list["textSize"] as? Double, size > 0 { return CGFloat(size) }
        }
        return 13
    }()

    static let rowHeight = max(20, ceil(textSize) + 8)
    static let byteFormatter: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    /// Date formats from longest to shortest; the list uses the longest that fits
    /// the Date column, as Finder does.
    static let dateFormatters: [DateFormatter] = [
        (.medium, .short), (.short, .short), (.medium, .none), (.short, .none),
    ].map { date, time in
        let f = DateFormatter()
        f.dateStyle = date
        f.timeStyle = time
        f.doesRelativeDateFormatting = true
        return f
    }

    /// The accent as an AppKit colour, for template icons and highlights.
    static var accent: NSColor { Accent.current.nsColor }
}

/// One shared 16-pt icon per file extension, so a folder of hundreds of
/// files doesn't ask NSWorkspace for each row.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        if let key = item.iconKey {
            if let cached = cache.object(forKey: key as NSString) { return cached }
            let image = sized(NSWorkspace.shared.icon(forFile: item.url.path))
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        return sized(NSWorkspace.shared.icon(forFile: item.url.path))
    }

    static func icon(for url: URL) -> NSImage { sized(NSWorkspace.shared.icon(forFile: url.path)) }

    /// Drawn once into small bitmaps (16 and 32 pixels). Handing NSImageView the workspace
    /// icon itself makes it render the 1024-pixel version, 4 MB for each kind of file.
    private static func sized(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let small = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            small.addRepresentation(rep)
        }
        return small
    }
}

/// A slim message across the top of the list, with an optional action and a close button.
final class NoticeBar: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let closeButton = NSButton()
    private let progress = NSProgressIndicator()
    /// The tinted, rounded part; inset so the bar doesn't touch the toolbar or the list.
    private let box = NSView()
    private var action: (() -> Void)?
    private var dismissTask: Task<Void, Never>?
    /// Holds the bar at zero height while hidden, so it takes no room.
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)

    override var isHidden: Bool {
        didSet { collapsed.isActive = isHidden }
    }

    init() {
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        isHidden = true
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        actionButton.bezelStyle = .push
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(runAction)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(hide)
        closeButton.setAccessibilityLabel(String(localized: "Close"))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        let stack = NSStackView(views: [icon, progress, label, actionButton, closeButton])
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)   // stretches, so the close button sits at the right
        box.addSubview(stack)
        let bottom = box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        bottom.priority = .defaultHigh   // gives way while the bar is collapsed
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 6), bottom,
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    enum Tone { case info, warning, error }

    /// Shows a message. Errors and warnings stay until closed; info fades after a few seconds.
    func show(_ text: String, tone: Tone, working: Bool = false, action: (title: String, run: () -> Void)? = nil) {
        dismissTask?.cancel()
        label.stringValue = text
        let color: NSColor = tone == .error ? .systemRed : tone == .warning ? .systemOrange : BrowserStyle.accent
        box.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        icon.image = NSImage(systemSymbolName: tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.isHidden = working
        working ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        progress.isHidden = !working   // a stopped spinner still takes its space in the stack
        self.action = action?.run
        actionButton.title = action?.title ?? ""
        actionButton.isHidden = action == nil
        closeButton.isHidden = working
        isHidden = false
        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if tone == .info, !working {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    @objc func hide() {
        dismissTask?.cancel()
        progress.stopAnimation(nil)
        isHidden = true
    }

    @objc private func runAction() { action?() }
}

/// A message in the middle of the list when there's nothing to show.
final class EmptyStateView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(run)
        let stack = NSStackView(views: [title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ titleText: String, detail detailText: String = "", action: (title: String, run: () -> Void)? = nil) {
        title.stringValue = titleText
        detail.stringValue = detailText
        detail.isHidden = detailText.isEmpty
        self.action = action?.run
        button.title = action?.title ?? ""
        button.isHidden = action == nil
        isHidden = false
    }

    func hide() { isHidden = true }

    var titleText: String { title.stringValue }

    @objc private func run() { action?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit   // let clicks reach the list unless on the button
    }
}
