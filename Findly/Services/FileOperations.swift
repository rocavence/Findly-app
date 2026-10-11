import Foundation

/// Rename, trash, copy and move, with errors worded for the drawer's notice.
enum FileOperations {
    enum RenameError: LocalizedError, Equatable {
        case empty, slash, taken(String)

        var errorDescription: String? {
            switch self {
            case .empty: String(localized: "A name can't be empty.")
            case .slash: String(localized: "A name can't contain “/” or “:”.")
            case .taken(let name): String(localized: "“\(name)” is already taken. Choose a different name.")
            }
        }
    }

    /// Checks a new name before renaming; nil when it's fine (or unchanged).
    static func validate(_ name: String, for url: URL) -> RenameError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") { return .slash }
        if trimmed == url.lastPathComponent { return nil }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // Allow case-only renames on case-insensitive volumes.
        if FileManager.default.fileExists(atPath: target.path), trimmed.lowercased() != url.lastPathComponent.lowercased() {
            return .taken(trimmed)
        }
        return nil
    }

    @discardableResult
    static func rename(_ url: URL, to name: String) throws -> URL {
        if let error = validate(name, for: url) { throw error }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != url.lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if trimmed.lowercased() == url.lastPathComponent.lowercased() {
            // Case-only change: hop through a temporary name.
            let temp = url.deletingLastPathComponent().appendingPathComponent(".findly-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: temp)
            try FileManager.default.moveItem(at: temp, to: target)
        } else {
            try FileManager.default.moveItem(at: url, to: target)
        }
        return target
    }

    /// Moves items to the Trash; returns the ones that couldn't be.
    static func trash(_ urls: [URL]) -> [URL] {
        urls.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }
    }

    enum Transfer: Sendable { case copy, move }

    /// Copies or moves items into a folder off the main thread, never
    /// overwriting (a clash gets a numbered name).
    /// Returns the items that failed.
    @concurrent
    static func transfer(_ sources: [URL], to folder: URL, _ kind: Transfer) async -> [URL] {
        let fm = FileManager.default
        var failed: [URL] = []
        for source in sources {
            let sameFolder = source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
            if kind == .move, sameFolder { continue }
            let target = uniqueDestination(for: source.lastPathComponent, in: folder, copySuffix: kind == .copy && sameFolder)
            do {
                if kind == .move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
            } catch {
                failed.append(source)
            }
        }
        return failed
    }

    /// A free name in `folder`: "name 2", or "name copy" / "name copy 2" when duplicating in place.
    static func uniqueDestination(for name: String, in folder: URL, copySuffix: Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func url(_ stem: String) -> URL { folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)") }
        var candidate = url(copySuffix ? String(localized: "\(base) copy") : base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url(copySuffix ? String(localized: "\(base) copy \(n)") : "\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// Whether two items are on the same volume (Finder moves within one, copies across).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let va, let vb else { return true }
        return va.isEqual(vb)
    }
}
