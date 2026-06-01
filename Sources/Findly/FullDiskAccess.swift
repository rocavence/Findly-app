import AppKit

/// The drawer browses the whole filesystem, so it wants Full Disk Access —
/// otherwise TCC-protected folders (Desktop, Documents, Downloads, other users'
/// homes …) list as empty and look broken. FDA can't be requested with a
/// programmatic prompt like Accessibility; the user grants it manually in
/// System Settings, so we detect it and guide them there.
enum FullDiskAccess {
    /// Reading the per-user TCC database requires Full Disk Access, so a
    /// successful open is a reliable probe.
    static var isGranted: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(probe.path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// Open System Settings → Privacy & Security → Full Disk Access. Triggered
    /// by the menu item, never automatically, so it can't hijack focus on launch.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
