import AppKit

/// The menu-bar app: the drawer, its shortcuts and the status menu. Settings
/// is built when opened and released when closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var drawer: DrawerController?
    private var statusItem: NSStatusItem?
    private let updates = UpdateChecker()
    private var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        Defaults.migrate()
        AppAppearance.apply(.saved)

        #if DEBUG
        if let item = ProcessInfo.processInfo.environment["FINDLY_SELFTEST"] {
            SelfTest.run(item)
            return
        }
        #endif

        drawer = DrawerController()
        setUpStatusItem()
        updates.checkIfDue()
        #if DEBUG
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drawer?.toggleDefault() }
            if ProcessInfo.processInfo.environment["FINDLY_DEBUG_AUTOPARK"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.drawer?.park() }
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        drawer?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        drawer?.toggleDefault()
        return true
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Drawn 0.5pt lower so it sits on the menu bar's optical centre.
        let glyph = Icon.nsImage(.sidebarRightBold, size: 18)
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            glyph.draw(in: rect.offsetBy(dx: 0, dy: -0.5))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Findly"
        item.button?.image = icon
        // Click opens the drawer; right-click (or Control-click) shows the menu.
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.delegate = self
        statusItem = item
    }

    private let statusMenu = NSMenu()

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Attached only while open, so the next left click goes back to toggling.
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            drawer?.toggleDefault()
        }
    }

    func showSettings(_ page: SettingsPage = .general) {
        if settings == nil {
            let model = SettingsModel(updates: updates) { [weak self] in self?.drawer?.hotkeyFailures ?? [] }
            model.resetSize = { [weak self] in self?.drawer?.resetSize() }
            let window = SettingsWindow(model: model)
            window.onClose = { [weak self] in self?.settings = nil }
            settings = window
        }
        settings?.show(page)
    }

    @objc private func toggleDrawer() { drawer?.toggleDefault() }

    @objc private func snap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = ScreenEdge(rawValue: raw) else { return }
        drawer?.toggle(edge: edge)
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openPermissions() { showSettings(.permissions) }
    @objc private func openUpdate() { NSWorkspace.shared.open(updates.available?.page ?? UpdateChecker.releases) }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt each time it opens, so shortcuts, access and updates are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult func add(_ title: String, _ action: Selector?, hotkey: HotkeyAction? = nil, key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            if let hotkey {
                let h = Defaults.hotkey(for: hotkey)
                item.keyEquivalent = h.keyEquivalent
                item.keyEquivalentModifierMask = h.keyEquivalentModifierMask
            }
            return item
        }
        if let release = updates.available {
            add(String(localized: "Findly \(release.version) Is Available…"), #selector(openUpdate))
            menu.addItem(.separator())
        }
        if !FullDiskAccess.isGranted {
            add(String(localized: "Turn On Full Disk Access…"), #selector(openPermissions))
            menu.addItem(.separator())
        }
        add(String(localized: "Toggle Drawer"), #selector(toggleDrawer), hotkey: .toggle)
        menu.addItem(.separator())
        for edge in ScreenEdge.allCases {
            let action = HotkeyAction.forEdge(edge)
            add(action.localizedTitle, #selector(snap(_:)), hotkey: action).representedObject = edge.rawValue
        }
        menu.addItem(.separator())
        add(String(localized: "Settings…"), #selector(openSettings), key: ",")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: String(localized: "Quit Findly"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }
}
