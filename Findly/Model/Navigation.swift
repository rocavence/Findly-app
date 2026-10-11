import Foundation

/// Where the drawer is: the current folder and the Back/Forward history. The
/// one source of truth the toolbar, sidebar, path bar and list all follow.
@MainActor
final class Navigation {
    private(set) var current: URL
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []
    /// Fired after every move.
    var onChange: () -> Void = {}

    init(start: URL) { current = start }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    var parent: URL? {
        let up = current.deletingLastPathComponent()
        return up.path == current.path ? nil : up
    }

    /// Opens a folder; re-opening the current one just refreshes.
    func go(to url: URL) {
        guard url.standardizedFileURL != current.standardizedFileURL else { return onChange() }
        back.append(current)
        forward.removeAll()
        current = url
        onChange()
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
        onChange()
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
        onChange()
    }

    func goUp() {
        if let parent { go(to: parent) }
    }
}
