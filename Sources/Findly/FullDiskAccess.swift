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

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shown once per launch while access is missing. No-op once granted.
    @MainActor
    static func promptIfNeeded() {
        guard !isGranted else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Findly 需要「完整磁碟取用權限」"
        alert.informativeText = """
        要瀏覽所有資料夾（桌面、文件、下載…），請在「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」中把 Findly 打開，然後重新啟動。
        """
        alert.addButton(withTitle: "打開系統設定")
        alert.addButton(withTitle: "稍後")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }
}
