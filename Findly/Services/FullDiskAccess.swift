import AppKit

/// Findly browses the whole disk, so it wants Full Disk Access; without it,
/// protected folders can't be opened. There's no prompt for it: the user turns
/// it on in System Settings, and Findly checks.
enum FullDiskAccess {
    /// Folders only Full Disk Access can read. Any one that exists and opens means it's on.
    /// The TCC database alone isn't enough: newer macOS keeps it closed even with access.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = ["Library/Safari", "Library/Mail", "Library/Containers/com.apple.stocks",
                      "Library/Application Support/com.apple.TCC/TCC.db"].map { home.appendingPathComponent($0).path }
        for path in probes {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil { return true }
            } else {
                let fd = open(path, O_RDONLY)
                if fd >= 0 { close(fd); return true }
            }
        }
        return false
    }

    /// System Settings › Privacy & Security › Full Disk Access. Only when asked, never at launch.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
