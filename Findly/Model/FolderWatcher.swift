import CoreServices
import Foundation

/// Watches folders with FSEvents and reports which of them changed, batched
/// and on the main thread, so the list updates the rows that changed.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var watched: Set<String> = []
    private let onChange: @MainActor (Set<String>) -> Void

    init(onChange: @escaping @MainActor (Set<String>) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching exactly these folders (restarting only if the set changed).
    func watch(_ folders: Set<URL>) {
        let paths = Set(folders.map { ($0.resolvingSymlinksInPath().path as NSString).standardizingPath })
        guard paths != watched else { return }
        stop()
        watched = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []).prefix(count)
            // An event names the folder whose contents changed. FSEvents watches whole
            // subtrees, so drop changes deeper down (a busy ~/Library would otherwise
            // reload the list several times a second).
            let folders = Set(changed.map { ($0 as NSString).standardizingPath }).intersection(watcher.watched)
            guard !folders.isEmpty else { return }
            let handler = watcher.onChange
            Task { @MainActor in handler(folders) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, Array(paths) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watched = []
    }
}
