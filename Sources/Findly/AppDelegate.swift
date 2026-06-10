import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DrawerController!
    private var debugWindow: NSWindow?
    /// "Grant Full Disk Access…" — shown in the menu only while access is missing.
    private var fdaItem: NSMenuItem?
    /// "Launch at Login" — checkmark mirrors the live SMAppService state.
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug/testing: show the browser in an ordinary window, bypassing the
        // sliding drawer, FDA prompt and status bar — so it can be inspected and
        // screenshotted without fighting focus/park behavior.
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_WINDOW"] != nil {
            showDebugWindow()
            return
        }

        controller = DrawerController()
        setupStatusBar()
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.controller.toggleDefault()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    private func showDebugWindow() {
        NSApp.setActivationPolicy(.regular)
        let root: URL
        if let path = ProcessInfo.processInfo.environment["FINDLY_DEBUG_PATH"] {
            root = URL(fileURLWithPath: path)
        } else {
            root = (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Findly (debug)"
        window.contentView = FileBrowserView(root: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Findly")

        let menu = NSMenu()
        menu.delegate = self

        // Disabled label showing the running build, read at runtime so it always
        // matches Info.plist rather than a hardcoded string.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // "Findly %@" rather than "Findly \(version)" so the localized format can
        // reposition the version number for languages that need it.
        let versionTitle = String(format: NSLocalizedString("Findly %@", comment: "Status menu version label, %@ is the version number"), version)
        let versionItem = NSMenuItem(title: versionTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        // Surfaced only while Full Disk Access is missing, so the user can grant
        // it on their own terms instead of System Settings hijacking focus on
        // every launch.
        let fda = NSMenuItem(title: NSLocalizedString("Grant Full Disk Access…", comment: "Status menu item to open System Settings FDA pane"), action: #selector(openFDASettings), keyEquivalent: "")
        fda.target = self
        menu.addItem(fda)
        let fdaSeparator = NSMenuItem.separator()
        menu.addItem(fdaSeparator)
        fda.representedObject = fdaSeparator
        fdaItem = fda

        let toggle = NSMenuItem(title: NSLocalizedString("Toggle Drawer", comment: "Status menu item that shows/hides the drawer"), action: #selector(toggleDrawer), keyEquivalent: "`")
        toggle.keyEquivalentModifierMask = [.command]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        for edge in ScreenEdge.allCases {
            let item = NSMenuItem(
                title: edge.snapMenuTitle,
                action: #selector(snap(_:)),
                keyEquivalent: edge.menuKeyEquivalent
            )
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.representedObject = edge.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let launch = NSMenuItem(title: NSLocalizedString("Launch at Login", comment: "Status menu item to start Findly automatically at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch
        menu.addItem(.separator())
        let quit = NSMenuItem(title: NSLocalizedString("Quit Findly", comment: "Status menu item to quit the app"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func snap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let edge = ScreenEdge(rawValue: raw) else { return }
        controller.toggle(edge: edge)
    }

    @objc private func toggleDrawer() { controller.toggleDefault() }

    @objc private func openFDASettings() { FullDiskAccess.openSettings() }

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    /// Hide the Full Disk Access entry once access is granted, and mirror the
    /// live login-item state (the user may toggle it in System Settings →
    /// General → Login Items behind our back).
    func menuNeedsUpdate(_ menu: NSMenu) {
        let granted = FullDiskAccess.isGranted
        fdaItem?.isHidden = granted
        (fdaItem?.representedObject as? NSMenuItem)?.isHidden = granted
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
    }
}

private extension ScreenEdge {
    /// Localized "Snap …" menu title. A distinct key per edge (rather than
    /// formatting one "Snap %@" template with a translated direction word) so
    /// each language can phrase the whole entry naturally — e.g. 繁體中文 reads
    /// "靠上/靠下/靠左/靠右" with no separate "Snap" verb.
    var snapMenuTitle: String {
        switch self {
        case .top:    return NSLocalizedString("Snap Top", comment: "Status menu item: snap drawer to top edge")
        case .bottom: return NSLocalizedString("Snap Bottom", comment: "Status menu item: snap drawer to bottom edge")
        case .left:   return NSLocalizedString("Snap Left", comment: "Status menu item: snap drawer to left edge")
        case .right:  return NSLocalizedString("Snap Right", comment: "Status menu item: snap drawer to right edge")
        }
    }

    /// Single-character keyEquivalent for arrow keys, displayed in the menu
    /// next to the title.
    var menuKeyEquivalent: String {
        let code: Int
        switch self {
        case .top:    code = NSUpArrowFunctionKey
        case .bottom: code = NSDownArrowFunctionKey
        case .left:   code = NSLeftArrowFunctionKey
        case .right:  code = NSRightArrowFunctionKey
        }
        return String(Character(UnicodeScalar(code)!))
    }
}
