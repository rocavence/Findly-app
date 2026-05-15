import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: FinderController!
    private var welcomeController: WelcomeWindowController?
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = FinderController()
        setupStatusBar()

        welcomeController = WelcomeWindowController()
        welcomeController?.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: - Menu

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Findly")

        let menu = NSMenu()
        menu.delegate = self

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        for edge in ScreenEdge.allCases {
            let item = NSMenuItem(
                title: "Snap Finder \(edge.rawValue.capitalized)",
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

    /// Keep the login-item checkmark in sync with the live system state
    /// (the user may have toggled it in System Settings).
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func snap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let edge = ScreenEdge(rawValue: raw) else { return }
        controller.toggle(edge: edge)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let next = sender.state == .off
        if next && !LaunchAtLogin.isInstalledInApplications {
            showInstallToApplicationsAlert()
            return
        }
        if case .failure(let error) = LaunchAtLogin.setEnabled(next) {
            showLoginItemError(error)
        }
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    private func showInstallToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "請先把 Findly 搬進「應用程式」"
        alert.informativeText = """
        Login Item 需要 app 在 /Applications 才能跨重開機持續生效。

        執行 ./Scripts/install.sh 一鍵搬移，或手動把 Findly.app 拖到「應用程式」資料夾後重新開啟。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showLoginItemError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "無法切換 Login Item"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

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
