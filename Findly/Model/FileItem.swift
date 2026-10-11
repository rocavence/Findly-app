import AppKit
import UniformTypeIdentifiers

/// How the list is ordered. The raw value persists in `Defaults`; `columnKey`
/// matches the sortable `NSTableColumn` identifiers.
enum FileSort: String, CaseIterable, Sendable {
    case name, dateModified, size, kind

    var columnKey: String {
        switch self {
        case .name: "name"
        case .dateModified: "date"
        case .size: "size"
        case .kind: "kind"
        }
    }

    init(columnKey: String) {
        self = FileSort.allCases.first { $0.columnKey == columnKey } ?? .name
    }
}

/// Finder's "Arrange by Kind" buckets; the raw value is the display order.
enum FileCategory: Int, CaseIterable, Sendable {
    case folder, application, document, image, audio, movie, archive, other

    var title: String {
        switch self {
        case .folder: String(localized: "Folders")
        case .application: String(localized: "Applications")
        case .document: String(localized: "Documents")
        case .image: String(localized: "Images")
        case .audio: String(localized: "Music")
        case .movie: String(localized: "Movies")
        case .archive: String(localized: "Archives")
        case .other: String(localized: "Other")
        }
    }

    static func of(isFolder: Bool, type: UTType?) -> FileCategory {
        if isFolder { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .content) { return .document }
        return .other
    }
}

/// One file or folder as listed: everything the list shows, read once, off the main thread.
struct FileItem: Hashable, Sendable {
    let url: URL
    let name: String
    /// A folder you can open in the list (packages like .app count as files).
    let isFolder: Bool
    let isPackage: Bool
    let category: FileCategory
    let date: Date
    let size: Int
    let kind: String

    /// Lowercased extension for sharing a generic icon, or nil when the item has its own (folders, packages).
    var iconKey: String? {
        guard !isFolder, !isPackage else { return nil }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    static func == (a: FileItem, b: FileItem) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
