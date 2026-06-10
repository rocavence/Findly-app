import AppKit
import ServiceManagement

/// Register/unregister the app as a login item via SMAppService (macOS 13+).
/// The registration only persists across reboots when the app runs from
/// /Applications (or ~/Applications) — `toggle()` refuses with an alert from a
/// dev-build path instead of silently half-working.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the running bundle lives somewhere login-item registration
    /// actually sticks.
    private static var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
    }

    /// Flip the login-item state; called from the status menu item.
    static func toggle() {
        if isEnabled {
            try? SMAppService.mainApp.unregister()
            return
        }
        guard isInstalled else {
            // Menu-bar app: there's no key window, so bring ourselves forward
            // or the alert appears behind whatever the user is doing.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Move Findly to the Applications folder first", comment: "Launch-at-login alert title shown when the app runs outside /Applications")
            alert.informativeText = NSLocalizedString("Launch at Login only persists when Findly runs from the Applications folder. Move Findly.app there, relaunch it, and try again.", comment: "Launch-at-login alert body shown when the app runs outside /Applications")
            alert.runModal()
            return
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Findly: failed to register login item: \(error)")
        }
    }
}
