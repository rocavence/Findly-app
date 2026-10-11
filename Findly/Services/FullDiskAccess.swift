import AppKit

/// Findly browses the whole disk, so it wants Full Disk Access; without it,
/// protected folders can't be opened. There's no prompt for it: the user turns
/// it on in System Settings, and Findly checks.
enum FullDiskAccess {
    /// Opening the user's TCC database needs Full Disk Access, so it's a reliable probe.
    static var isGranted: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(probe.path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// System Settings › Privacy & Security › Full Disk Access. Only when asked, never at launch.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
