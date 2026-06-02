import AppKit

/// The drawer itself: our own window, so making it appear on every Space is a
/// one-line `collectionBehavior` — no CGS gymnastics, no per-Space juggling.
/// Chrome is hidden (transparent titlebar, no traffic lights) but the window
/// stays `.titled + .resizable` so the user can still drag its inner edge to
/// change thickness.
final class DrawerWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // The whole point of switching off Finder: present on every Space,
        // every Desktop, even over fullscreen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isMovable = false              // pinned to its edge; user resizes, not moves
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none      // we drive the slide ourselves
        // Translucent so the drawer's glass material (a backdrop NSVisualEffectView
        // in FileBrowserView) blends with the desktop — the macOS 26 Liquid Glass
        // look. The content panel keeps the file list legible over it.
        isOpaque = false
        backgroundColor = .clear
    }

    // A panel needs to be allowed to become key so the file browser can take
    // keyboard focus (arrow-key navigation, spacebar QuickLook, Enter to open).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
