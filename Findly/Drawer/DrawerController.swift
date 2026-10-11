import AppKit

/// Slides the drawer in and out from any edge of the screen you're on, parks it
/// when another app comes forward, and remembers its size per axis. The window
/// is built when first opened and released a while after it's parked, so an
/// idle Findly holds little memory; the folder you were in is reopened.
@MainActor
final class DrawerController {
    private let defaultWidth: CGFloat = 760    // room for the sidebar and four columns
    private let defaultHeight: CGFloat = 420
    private let duration: TimeInterval = 0.22
    private let offscreenBuffer: CGFloat = 50

    private var window: DrawerWindow?
    private var browser: BrowserView?
    private var resizeToken: NSObjectProtocol?
    private var releaseTask: Task<Void, Never>?
    /// How long a parked drawer is kept, so a quick reopen is instant.
    private let keepParked: Duration = .seconds(30)
    private(set) var edge: ScreenEdge?
    private(set) var isOpen = false
    private var screenFrame: CGRect?
    private var animation: Task<Void, Never>?
    private var parkTask: Task<Void, Never>?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var hotkeys: HotkeyManager?
    var hotkeyFailures: Set<HotkeyAction> { hotkeys?.failed ?? [] }

    init() {
        edge = Defaults.lastEdge
        observe()
        hotkeys = HotkeyManager(handler: { [weak self] in self?.toggle(edge: $0) },
                                toggle: { [weak self] in self?.toggleDefault() })
    }

    // MARK: Showing

    func toggle(edge requested: ScreenEdge) {
        if isOpen, edge == requested, activeScreen().frame == screenFrame { park() } else { slideIn(requested) }
    }

    /// The toggle shortcut: the default edge if one is set, otherwise the last one (right at first).
    func toggleDefault() {
        if isOpen { return park() }
        slideIn(Defaults.defaultEdge ?? edge ?? .right)
    }

    func shutdown() {
        hotkeys?.shutdown()
        animation?.cancel()
        parkTask?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
        window?.orderOut(nil)
    }

    /// The window and browser, built on first use, in the folder you were last in.
    private func makeDrawer() -> (DrawerWindow, BrowserView) {
        releaseTask?.cancel()
        if let window, let browser { return (window, browser) }
        let start = Defaults.lastFolder.flatMap { DirectoryReader.isFolder($0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let window = DrawerWindow()
        let browser = BrowserView(start: start)
        window.contentView = browser
        browser.onDragOutEnded = { [weak self] in
            if !NSApp.isActive { self?.otherAppActivated() }
        }
        resizeToken = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        }
        self.window = window
        self.browser = browser
        return (window, browser)
    }

    /// Lets go of the parked window and everything in it.
    private func releaseSoon() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: self?.keepParked ?? .seconds(30))
            guard let self, !Task.isCancelled, !self.isOpen, self.animation == nil,
                  !(self.browser?.isQuickLookActive ?? false) else { return }
            if let resizeToken = self.resizeToken { NotificationCenter.default.removeObserver(resizeToken) }
            self.resizeToken = nil
            self.window?.contentView = nil
            self.window?.close()
            self.window = nil
            self.browser = nil
            DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// Opens on the screen the pointer is on, every time.
    private func slideIn(_ newEdge: ScreenEdge) {
        parkTask?.cancel()
        let (window, browser) = makeDrawer()
        let screen = activeScreen()
        let size = thickness(for: newEdge, on: screen.visibleFrame)
        let target = newEdge.panelFrame(on: screen.visibleFrame, thickness: size)
        // Coming from another edge or screen starts from that edge, not from where it was.
        let start = isOpen && newEdge == edge && screen.frame == screenFrame
            ? window.frame : newEdge.offscreenFrame(on: screen.frame, thickness: size, buffer: offscreenBuffer)
        window.setFrame(start, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(browser.initialFirstResponder)
        browser.willAppear()
        animate(to: target)
        edge = newEdge
        Defaults.lastEdge = newEdge
        screenFrame = screen.frame
        isOpen = true
    }

    func park() {
        guard isOpen, let edge, let window else { return }
        parkTask?.cancel()
        let screen = NSScreen.screens.first { $0.frame == screenFrame } ?? activeScreen()
        let size = edge.isHorizontal ? window.frame.height : window.frame.width
        animate(to: edge.offscreenFrame(on: screen.frame, thickness: size, buffer: offscreenBuffer)) { [weak self] in
            self?.window?.orderOut(nil)
            self?.releaseSoon()
        }
        isOpen = false
    }

    /// Back to the default width and height.
    func resetSize() {
        Defaults.resetSizes()
        guard isOpen, let edge, window != nil else { return }
        let screen = NSScreen.screens.first { $0.frame == screenFrame } ?? activeScreen()
        animate(to: edge.panelFrame(on: screen.visibleFrame, thickness: thickness(for: edge, on: screen.visibleFrame)))
    }

    // MARK: Watching

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Park when another app comes forward. (didResignActive fires as the drawer
        // itself appears, because an accessory app's activation doesn't always stick.)
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if pid == ProcessInfo.processInfo.processIdentifier { self?.parkTask?.cancel() } else { self?.otherAppActivated() }
            }
        }))
        let center = NotificationCenter.default
        // Displays added, removed or rearranged: keep the drawer flush with its edge.
        tokens.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }))
    }

    private func otherAppActivated() {
        guard Defaults.autoPark, isOpen, animation == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_NOPARK"] != nil { return }
        #endif
        if let browser, browser.isQuickLookActive || browser.isDraggingOut { return }
        // Wait a moment, so a dialog that flashes up and away doesn't close the drawer.
        parkTask?.cancel()
        parkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !NSApp.isActive, !(self.browser?.isDraggingOut ?? false) else { return }
            self.park()
        }
    }

    private func resized() {
        guard isOpen, let edge, let window else { return }
        let screen = NSScreen.screens.first { $0.frame == screenFrame } ?? activeScreen()
        let raw = edge.isHorizontal ? window.frame.height : window.frame.width
        let size = ScreenEdge.clamp(raw, for: edge, in: screen.visibleFrame)
        Defaults.setSize(size, for: edge)
        window.setFrame(edge.panelFrame(on: screen.visibleFrame, thickness: size), display: true)
    }

    private func screensChanged() {
        guard isOpen, let edge, let window else { return }
        let screen = NSScreen.screens.first { $0.frame == screenFrame }
            ?? NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? activeScreen()
        screenFrame = screen.frame
        animation?.cancel()
        animation = nil
        window.setFrame(edge.panelFrame(on: screen.visibleFrame, thickness: thickness(for: edge, on: screen.visibleFrame)), display: true)
    }

    // MARK: Motion

    /// Ease-out cubic at the display's rate; with Reduce Motion, it just appears.
    private func animate(to end: CGRect, completion: (@MainActor () -> Void)? = nil) {
        animation?.cancel()
        guard let window else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(end, display: true)
            animation = nil
            completion?()
            return
        }
        let start = window.frame
        animation = Task { [weak self] in
            let began = Date()
            while !Task.isCancelled, let self {
                let t = min(1, -began.timeIntervalSinceNow / self.duration)
                let e = 1 - pow(1 - t, 3)
                window.setFrame(CGRect(x: start.minX + (end.minX - start.minX) * e, y: start.minY + (end.minY - start.minY) * e,
                                            width: start.width + (end.width - start.width) * e,
                                            height: start.height + (end.height - start.height) * e), display: true)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            self?.animation = nil
            completion?()
        }
    }

    // MARK: Geometry

    private func thickness(for edge: ScreenEdge, on screen: CGRect) -> CGFloat {
        ScreenEdge.clamp(Defaults.size(for: edge) ?? (edge.isHorizontal ? defaultHeight : defaultWidth), for: edge, in: screen)
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
