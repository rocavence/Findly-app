import Foundation

/// Reads a folder's contents into `FileItem`s. Runs off the main thread.
enum DirectoryReader {
    enum Failure: Error, Equatable {
        /// macOS won't let Findly in (usually Full Disk Access).
        case noPermission
        case missing
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey, .localizedTypeDescriptionKey,
        .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
    ]

    /// The folder's items. Each is unique by full path, so `report.pdf` and
    /// `report.docx` both appear; only the merged Applications view drops a
    /// system folder that repeats one by name (Utilities).
    static func read(_ url: URL, showHidden: Bool = false) throws(Failure) -> [FileItem] {
        var items: [FileItem] = []
        var seenPaths = Set<String>()
        var seenNames = Set<String>()
        for (index, dir) in sources(for: url).enumerated() {
            let resolved = dir.resolvingSymlinksInPath()
            let contents: [URL]
            switch list(resolved, showHidden: showHidden) {
            case .success(let urls): contents = urls
            case .failure(let failure):
                if index > 0 { continue }   // a missing /System/Applications is no reason to fail
                throw failure
            }
            for child in contents {
                guard let item = item(for: child) else { continue }
                if index > 0, seenNames.contains(item.name) { continue }
                guard seenPaths.insert(child.standardizedFileURL.path).inserted else { continue }
                seenNames.insert(item.name)
                items.append(item)
            }
        }
        return items
    }

    /// The folder's children, or why they can't be read.
    private static func list(_ dir: URL, showHidden: Bool) -> Result<[URL], Failure> {
        do {
            return .success(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                        options: showHidden ? [] : [.skipsHiddenFiles]))
        } catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return .failure(.missing) }
            return .failure(.noPermission)
        }
    }

    static func item(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // A symlink (e.g. ~/Dropbox → CloudStorage) is classified by its target.
        let target = (values.isSymbolicLink ?? false)
            ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .localizedTypeDescriptionKey]))
            : values
        let isPackage = target?.isPackage ?? false
        let isFolder = (target?.isDirectory ?? false) && !isPackage
        return FileItem(
            url: url,
            name: values.localizedName ?? url.lastPathComponent,
            isFolder: isFolder,
            isPackage: isPackage,
            category: .of(isFolder: isFolder, type: target?.contentType),
            date: values.contentModificationDate ?? .distantPast,
            size: values.fileSize ?? 0,
            kind: target?.localizedTypeDescription ?? (isFolder ? String(localized: "Folder") : "")
        )
    }

    /// Folders whose contents make up a view: Applications also shows /System/Applications, as Finder does.
    static func sources(for url: URL) -> [URL] {
        url.standardizedFileURL.path == "/Applications" ? [url, URL(fileURLWithPath: "/System/Applications")] : [url]
    }

    /// Whether `url` opens as a folder in the list (following symlinks; packages don't).
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }
}
