import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DrawerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DrawerController()
        setupStatusBar()
        FullDiskAccess.promptIfNeeded()
        if ProcessInfo.processInfo.environment["FINDLY_DEBUG_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.controller.toggleDefault()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Findly")

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle Drawer", action: #selector(toggleDrawer), keyEquivalent: "`")
        toggle.keyEquivalentModifierMask = [.command]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        for edge in ScreenEdge.allCases {
            let item = NSMenuItem(
                title: "Snap \(edge.rawValue.capitalized)",
                action: #selector(snap(_:)),
                keyEquivalent: edge.menuKeyEquivalent
            )
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.representedObject = edge.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Findly", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension ScreenEdge {
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
