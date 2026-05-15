import ServiceManagement

enum LaunchAtLogin {
    /// Whether the app is registered to start at login.
    /// `SMAppService.mainApp.status == .enabled` reflects the live system state,
    /// which may have been toggled by the user in System Settings.
    @MainActor static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @MainActor static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Findly: failed to toggle login item — \(error)")
        }
    }
}
