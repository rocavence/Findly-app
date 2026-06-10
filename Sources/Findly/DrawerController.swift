import AppKit

/// Drives the native drawer: slide on/off from any screen edge, park when the
/// user clicks away, persist per-edge thickness from drag-resizing. Because the
/// drawer is our own `DrawerWindow`, it already lives on every Space — there is
/// no Finder process, no Apple Events, no CGS, no per-Space bookkeeping.
@MainActor
final class DrawerController {
    private let defaultThickness: CGFloat = 760   // room for the sidebar + 4 list columns
    private let animationDuration: TimeInterval = 0.22
    private let animationTickNanos: UInt64 = 8_000_000   // ~120 Hz target
    private let offscreenBuffer: CGFloat = 50            // clear any shadow

    private let window: DrawerWindow
    private let browserView: FileBrowserView

    private var lastEdge: ScreenEdge?
    private var isParked = true
    private var currentFrame: CGRect?
    private var isAnimating = false
    private var animationTask: Task<Void, Never>?

    private var resignKeyToken: NSObjectProtocol?
    private var endResizeToken: NSObjectProtocol?
    private var hotkeyManager: HotkeyManager?

    /// Pending auto-park, debounced so a brief focus flicker (e.g. the Full Disk
    /// Access dialog popping up and dismissing) can't drive a park/unpark loop.
    private var parkDebounceTask: Task<Void, Never>?
    private let parkDebounceNanos: UInt64 = 150_000_000   // 150 ms

    init() {
        lastEdge = Defaults.lastEdge

        let root = FileManager.default.homeDirectoryForCurrentUser
        browserView = FileBrowserView(root: root)
        window = DrawerWindow()
        window.contentView = browserView

        observeResignKey()
        observeEndResize()
        // A drag that ended in another app may have activated it while parking
        // was suppressed (see handleResignKey) — re-apply the rule now.
        browserView.onDragOutEnded = { [weak self] in
            guard !NSApp.isActive else { return }
            self?.handleResignKey()
        }
        hotkeyManager = HotkeyManager(
            handler: { [weak self] edge in self?.toggle(edge: edge) },
            toggle: { [weak self] in self?.toggleDefault() }
        )
    }

    // MARK: - Public

    func toggle(edge: ScreenEdge) {
        if lastEdge == edge, !isParked {
            parkOffscreen(edge: edge)
        } else {
            slideOnscreen(edge: edge)
        }
    }

    /// ⌘` and the menu item: toggle on the last-used edge (right by default).
    func toggleDefault() {
        toggle(edge: lastEdge ?? .right)
    }

    func shutdown() {
        hotkeyManager?.shutdown()
        hotkeyManager = nil
        animationTask?.cancel()
        parkDebounceTask?.cancel()
        if let t = resignKeyToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        if let t = endResizeToken { NotificationCenter.default.removeObserver(t) }
        window.orderOut(nil)
    }

    // MARK: - Slide on / off

    private func slideOnscreen(edge: ScreenEdge) {
        // A deliberate re-open cancels any park still pending from a focus flicker.
        parkDebounceTask?.cancel()
        let screen = activeScreen()
        let t = thickness(for: edge)
        let target = edge.panelFrame(on: screen.visibleFrame, thickness: t)
        let start = currentFrame ?? edge.offscreenFrame(on: screen.frame, thickness: t, buffer: offscreenBuffer)

        window.setFrame(start, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(browserView.initialFirstResponder)
        browserView.syncSidebar()   // mirror Finder's Favorites each time we show

        animate(from: start, to: target)
        lastEdge = edge
        Defaults.lastEdge = edge
        isParked = false
        currentFrame = target
    }

    private func parkOffscreen(edge: ScreenEdge) {
        let screen = screenContaining(currentFrame) ?? activeScreen()
        let t = thickness(for: edge)
        let target = edge.offscreenFrame(on: screen.frame, thickness: t, buffer: offscreenBuffer)
        let start = currentFrame ?? edge.panelFrame(on: screen.visibleFrame, thickness: t)
        animate(from: start, to: target) { [weak self] in
            self?.window.orderOut(nil)
        }
        isParked = true
        currentFrame = target
    }

    // MARK: - Auto-park

    private func observeResignKey() {
        // Park only when *another app* is brought to the front. Listening for
        // didResignActive instead parked the drawer the instant it appeared,
        // because a background agent's NSApp.activate doesn't reliably hold on
        // macOS 14+ (activate → immediate resign → park). Watching for another
        // app's activation avoids that, and ignores our own sort menu/QuickLook.
        resignKeyToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                // Focus came back to us before a pending park fired — cancel it,
                // so a flicker out-and-back doesn't slam the drawer shut.
                guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
                    self?.parkDebounceTask?.cancel()
                    return
                }
                self?.handleResignKey()
            }
        }
    }

    private func handleResignKey() {
        guard lastEdge != nil, !isParked, !isAnimating else { return }
        // Debug/testing: keep the drawer pinned open across focus changes.
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_NOPARK"] != nil { return }
        // Don't park when focus left only because a QuickLook panel we drove
        // took over — the drawer should still be sitting there behind it.
        if browserView.isQuickLookActive { return }
        // Don't park mid-drag: dropping a file on another app's window (browser
        // upload zones especially) can activate it while the drag session is
        // still live, and parking would yank the drawer out from under the drag.
        if browserView.isDraggingOut { return }
        // Debounce: schedule the park and replace any still-pending one, so a
        // momentary activation flicker resolves into at most one park.
        parkDebounceTask?.cancel()
        parkDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.parkDebounceNanos ?? 150_000_000)
            guard !Task.isCancelled, let self else { return }
            // Re-check: focus or state may have changed during the wait —
            // including a drag that began inside the debounce window.
            guard let edge = self.lastEdge, !self.isParked, !self.isAnimating,
                  !self.browserView.isDraggingOut else { return }
            self.parkOffscreen(edge: edge)
        }
    }

    // MARK: - Drag-to-resize → thickness

    private func observeEndResize() {
        endResizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEndResize()
            }
        }
    }

    private func handleEndResize() {
        guard let edge = lastEdge, !isParked else { return }
        let frame = window.frame
        let newThickness = edge.isHorizontal ? frame.height : frame.width
        Defaults.setThickness(newThickness, for: edge)
        // Re-snap flush to the edge: resizing the inner edge shifts the origin
        // and the user may have dragged the length, so recompute the full-span
        // frame from the new thickness.
        let screen = screenContaining(frame) ?? activeScreen()
        let snapped = edge.panelFrame(on: screen.visibleFrame, thickness: newThickness)
        window.setFrame(snapped, display: true)
        currentFrame = snapped
    }

    // MARK: - Animation
    //
    // Time-based ease-out cubic, ticking ~120 Hz. Progress derives from elapsed
    // time so slow ticks drop frames instead of stretching the slide.
    private func animate(from start: CGRect,
                         to end: CGRect,
                         completion: (@MainActor () -> Void)? = nil) {
        animationTask?.cancel()
        animationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAnimating = true
            defer { self.isAnimating = false }

            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = -startedAt.timeIntervalSinceNow
                let progress = min(1.0, elapsed / self.animationDuration)
                let eased = 1 - pow(1 - progress, 3)
                self.window.setFrame(self.lerp(start, end, eased), display: true)
                if progress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: self.animationTickNanos)
            }
            if !Task.isCancelled { completion?() }
        }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: a.origin.x + (b.origin.x - a.origin.x) * t,
            y: a.origin.y + (b.origin.y - a.origin.y) * t,
            width: a.size.width + (b.size.width - a.size.width) * t,
            height: a.size.height + (b.size.height - a.size.height) * t
        )
    }

    // MARK: - Geometry helpers

    private func thickness(for edge: ScreenEdge) -> CGFloat {
        Defaults.thickness(for: edge) ?? defaultThickness
    }

    /// Screen the user is working on (mouse cursor's screen).
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    private func screenContaining(_ frame: CGRect?) -> NSScreen? {
        guard let frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}
