import AppKit
import SwiftUI
import ApplicationServices

@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private var pollTimer: Timer?

    /// Shows the welcome window unless Accessibility is already granted.
    func showIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        present()
        startPolling()
    }

    private func present() {
        let view = WelcomeView(
            openSettings: { [weak self] in self?.openAccessibilitySettings() },
            dismiss:      { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = "Findly"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        window = nil
    }
}

private struct WelcomeView: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)

            VStack(spacing: 6) {
                Text("Welcome to Findly")
                    .font(.title2).bold()
                Text("把 Finder 視窗釘在螢幕邊上隨叫隨到。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    icon: "accessibility",
                    title: "輔助使用權限（必要）",
                    body: "讓 Findly 流暢地控制 Finder 視窗位置，達到 60–120Hz 動畫。"
                )
                permissionRow(
                    icon: "applescript",
                    title: "Apple Events for Finder",
                    body: "建立並切換 Findly 管理的 Finder 視窗。系統會在第一次召喚時詢問。"
                )
            }
            .padding(.horizontal, 4)

            Text("授予「輔助使用」後此視窗會自動關閉。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("稍後再說", action: dismiss)
                Button("打開系統設定") { openSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 460)
    }

    private func permissionRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
