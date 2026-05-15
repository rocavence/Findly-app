import AppKit
import ApplicationServices

@MainActor
final class FinderController {
    private let defaultThickness: CGFloat = 480
    private let selfActivationWindow: TimeInterval = 1.0
    private let animationDuration: TimeInterval = 0.22
    private let animationTickNanos: UInt64 = 8_000_000   // ~120 Hz target
    private let axSettleDelayNanos: UInt64 = 80_000_000
    private let offscreenBuffer: CGFloat = 50            // past Finder's native shadow

    private var lastEdge: ScreenEdge?
    private var isParked = true
    private var managedWindowID: Int?
    private var axWindow: AXUIElement?
    private var axObserver: AXObserver?
    private var currentFrame: CGRect?
    private var animationTask: Task<Void, Never>?
    private var lastSelfActivationTime: Date?
    private var isAnimating = false
    private var activationObserverToken: NSObjectProtocol?
    private var finderTerminationToken: NSObjectProtocol?
    private var hotkeyManager: HotkeyManager?

    init() {
        managedWindowID = Defaults.managedWindowID
        lastEdge = Defaults.lastEdge
        requestAccessibilityIfNeeded()
        observeAppActivation()
        observeFinderTermination()
        hotkeyManager = HotkeyManager { [weak self] edge in
            self?.toggle(edge: edge)
        }
    }

    // MARK: - Public

    func toggle(edge: ScreenEdge) {
        if lastEdge == edge, !isParked {
            parkOffscreen(edge: edge)
        } else {
            slideOnscreen(edge: edge)
        }
    }

    func shutdown() {
        hotkeyManager?.shutdown()
        hotkeyManager = nil
        animationTask?.cancel()
        stopObservingFinderWindow()
        if let token = activationObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activationObserverToken = nil
        }
        if let token = finderTerminationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            finderTerminationToken = nil
        }
        if let id = managedWindowID {
            run(FinderScript.close(windowID: id))
        }
        Defaults.managedWindowID = nil
        managedWindowID = nil
        axWindow = nil
    }

    // MARK: - Permission

    private func requestAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - App activation observer

    private func observeAppActivation() {
        activationObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.bundleIdentifier == "com.apple.finder" {
                Task { @MainActor in self?.handleFinderActivated() }
                return
            }
            if app.processIdentifier == NSRunningApplication.current.processIdentifier { return }
            Task { @MainActor in self?.handleOtherAppActivated() }
        }
    }

    private func handleFinderActivated() {
        if let t = lastSelfActivationTime, Date().timeIntervalSince(t) < selfActivationWindow {
            return
        }
        guard isParked else { return }
        slideOnscreen(edge: lastEdge ?? .right)
    }

    private func handleOtherAppActivated() {
        guard let edge = lastEdge, !isParked else { return }
        parkOffscreen(edge: edge)
    }

    private func observeFinderTermination() {
        finderTerminationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.finder" else { return }
            Task { @MainActor in self?.handleFinderTerminated() }
        }
    }

    private func handleFinderTerminated() {
        // Finder always relaunches; our cached window handle is dead. Drop state
        // so the next slideOnscreen creates a fresh window.
        animationTask?.cancel()
        stopObservingFinderWindow()
        axWindow = nil
        managedWindowID = nil
        Defaults.managedWindowID = nil
        currentFrame = nil
        isParked = true
    }

    // MARK: - Slide on / off

    private func slideOnscreen(edge: ScreenEdge) {
        let screen = activeScreen()
        let t = thickness(for: edge)
        let target = edge.panelFrame(on: screen.visibleFrame, thickness: t)
        let start  = currentFrame ?? edge.offscreenFrame(on: screen.frame, thickness: t, buffer: offscreenBuffer)

        guard let windowID = ensureManagedWindow(initialFrame: start) else { return }
        activateAndFrontManagedWindow(windowID: windowID)

        animate(from: start, to: target, windowID: windowID, setupAX: axWindow == nil)
        lastEdge = edge
        Defaults.lastEdge = edge
        isParked = false
        currentFrame = target
    }

    private func parkOffscreen(edge: ScreenEdge) {
        guard let windowID = managedWindowID else { return }
        let screen = screenContaining(currentFrame) ?? activeScreen()
        let t = thickness(for: edge)
        let target = edge.offscreenFrame(on: screen.frame, thickness: t, buffer: offscreenBuffer)
        let start  = currentFrame ?? edge.panelFrame(on: screen.visibleFrame, thickness: t)
        animate(from: start, to: target, windowID: windowID)
        isParked = true
        currentFrame = target
    }

    // MARK: - Screen helpers

    /// Screen the user is currently working on (mouse cursor's screen).
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    /// Screen that contains the center of the given frame.
    private func screenContaining(_ frame: CGRect?) -> NSScreen? {
        guard let frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    // MARK: - Animation
    //
    // Time-based: tick as fast as the OS allows (~120 Hz target). Progress is
    // derived from elapsed time, so slow ticks drop frames instead of dragging
    // the animation out. Always finishes by `animationDuration`.
    private func animate(from start: CGRect,
                         to end: CGRect,
                         windowID: Int,
                         setupAX: Bool = false) {
        animationTask?.cancel()
        animationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAnimating = true
            defer { self.isAnimating = false }

            if setupAX {
                try? await Task.sleep(nanoseconds: self.axSettleDelayNanos)
                self.axWindow = self.findFinderFrontWindow()
                if self.axWindow != nil {
                    self.startObservingFinderWindow()
                }
            }

            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = -startedAt.timeIntervalSinceNow
                let progress = min(1.0, elapsed / self.animationDuration)
                let eased = 1 - pow(1 - progress, 3)
                self.applyBounds(windowID: windowID, frame: self.lerp(start, end, eased))
                if progress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: self.animationTickNanos)
            }
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

    private func thickness(for edge: ScreenEdge) -> CGFloat {
        Defaults.thickness(for: edge) ?? defaultThickness
    }

    // MARK: - Apply bounds (AX first, AppleScript fallback)

    private func applyBounds(windowID: Int, frame: CGRect) {
        if let ax = axWindow {
            if !setAXFrame(ax, frame) {
                axWindow = nil
                stopObservingFinderWindow()
                applyBoundsViaAppleScript(windowID: windowID, frame: frame)
            }
            return
        }
        applyBoundsViaAppleScript(windowID: windowID, frame: frame)
    }

    @discardableResult
    private func setAXFrame(_ window: AXUIElement, _ cocoaFrame: CGRect) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let r = finderRect(from: cocoaFrame, primary: primary)
        var pos = r.origin
        var size = r.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else { return false }
        let r1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        let r2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        return r1 == .success && r2 == .success
    }

    // MARK: - AX window discovery & observers

    private func findFinderFrontWindow() -> AXUIElement? {
        guard let pid = finderPID() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        if let focused = copyAXValue(axApp, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        guard let windows = copyAXValue(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first
    }

    private func startObservingFinderWindow() {
        stopObservingFinderWindow()
        guard let window = axWindow, let pid = finderPID() else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<FinderController>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in controller.handleFinderWindowChanged() }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func stopObservingFinderWindow() {
        guard let observer = axObserver else { return }
        if let window = axWindow {
            AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = nil
    }

    private func handleFinderWindowChanged() {
        if isAnimating { return }
        guard let edge = lastEdge, let window = axWindow,
              let pos = axPosition(of: window), let size = axSize(of: window),
              let primary = NSScreen.screens.first else { return }
        let cocoaY = primary.frame.height - pos.y - size.height
        currentFrame = CGRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
        Defaults.setThickness(edge.isHorizontal ? size.height : size.width, for: edge)
    }

    // MARK: - AX helpers

    private func axPosition(of window: AXUIElement) -> CGPoint? {
        guard let v = copyAXValue(window, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }

    private func axSize(of window: AXUIElement) -> CGSize? {
        guard let v = copyAXValue(window, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &s)
        return s
    }

    private func copyAXValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    private func finderPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    // MARK: - Managed window lifecycle (AppleScript)

    private func ensureManagedWindow(initialFrame: CGRect) -> Int? {
        if let id = managedWindowID, windowExists(id: id) { return id }
        axWindow = nil
        guard let primary = NSScreen.screens.first else { return nil }
        let r = finderRect(from: initialFrame, primary: primary)
        let result = run(FinderScript.createWindow(at: r))
        guard let desc = result, desc.descriptorType != typeNull else { return nil }
        let id = Int(desc.int32Value)
        managedWindowID = id
        Defaults.managedWindowID = id
        return id
    }

    private func windowExists(id: Int) -> Bool {
        run(FinderScript.windowExists(id: id))?.booleanValue ?? false
    }

    private func activateAndFrontManagedWindow(windowID: Int) {
        lastSelfActivationTime = Date()
        run(FinderScript.activateAndFront(windowID: windowID))
    }

    private func applyBoundsViaAppleScript(windowID: Int, frame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let r = finderRect(from: frame, primary: primary)
        run(FinderScript.setBounds(windowID: windowID, rect: r))
    }

    // MARK: - Coordinate conversion
    //
    // Cocoa NSScreen uses bottom-left origin; Finder/AX use top-left origin.

    private func finderRect(from cocoa: CGRect, primary: NSScreen) -> CGRect {
        let top = primary.frame.height - (cocoa.origin.y + cocoa.size.height)
        return CGRect(x: cocoa.origin.x, y: top, width: cocoa.size.width, height: cocoa.size.height)
    }

    // MARK: - AppleScript runner

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let err = error {
            NSLog("Findly AppleScript error: \(err)")
            return nil
        }
        return result
    }
}

// MARK: - AppleScript snippets

private enum FinderScript {
    static func createWindow(at r: CGRect) -> String {
        """
        tell application "System Events" to set visible of process "Finder" to false
        tell application "Finder"
            set newWin to make new Finder window
            set bounds of newWin to {\(Int(r.minX)), \(Int(r.minY)), \(Int(r.maxX)), \(Int(r.maxY))}
            set target of newWin to (path to home folder)
            return id of newWin as integer
        end tell
        """
    }

    static func setBounds(windowID: Int, rect r: CGRect) -> String {
        """
        tell application "Finder"
            try
                set bounds of (first Finder window whose id is \(windowID)) to {\(Int(r.minX)), \(Int(r.minY)), \(Int(r.maxX)), \(Int(r.maxY))}
            end try
        end tell
        """
    }

    static func activateAndFront(windowID: Int) -> String {
        """
        tell application "Finder"
            activate
            try
                set index of (first Finder window whose id is \(windowID)) to 1
            end try
        end tell
        """
    }

    static func windowExists(id: Int) -> String {
        """
        tell application "Finder"
            try
                set _ to first Finder window whose id is \(id)
                return true
            on error
                return false
            end try
        end tell
        """
    }

    static func close(windowID: Int) -> String {
        """
        tell application "Finder"
            try
                close (first Finder window whose id is \(windowID))
            end try
        end tell
        """
    }
}
