import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Whether the app is registered to start at login. Reflects the live
    /// system state, which may have been toggled by the user in System Settings.
    @MainActor static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// SMAppService records the app's path at registration time. Outside of
    /// `/Applications` the system may refuse to honor it across reboots.
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix("/System/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    @MainActor @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            NSLog("Findly: failed to toggle login item — \(error)")
            return .failure(error)
        }
    }
}
