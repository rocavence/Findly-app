import Foundation

/// Sorting and grouping, as pure functions of the items and the user's choice.
struct Arrangement: Equatable, Sendable {
    var sort: FileSort = .name
    var ascending = true
    var groupByKind = false

    /// A row in the list: a "Arrange by Kind" header, or an item.
    enum Row: Hashable, Sendable {
        case header(FileCategory)
        case item(FileItem)
    }

    /// Ungrouped: folders first, then by the chosen column. Grouped: kind
    /// sections in Finder's order, each sorted by the chosen column.
    func rows(_ items: [FileItem]) -> [Row] {
        if !groupByKind { return items.sorted(by: ordering(foldersFirst: true)).map(Row.item) }
        var buckets: [FileCategory: [FileItem]] = [:]
        for item in items { buckets[item.category, default: []].append(item) }
        return FileCategory.allCases.flatMap { category -> [Row] in
            guard let group = buckets[category], !group.isEmpty else { return [] }
            return [.header(category)] + group.sorted(by: ordering(foldersFirst: false)).map(Row.item)
        }
    }

    func ordering(foldersFirst: Bool) -> (FileItem, FileItem) -> Bool {
        let sort = sort, ascending = ascending
        return { a, b in
            if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            let primary: ComparisonResult
            switch sort {
            case .name: primary = byName
            case .dateModified: primary = a.date == b.date ? .orderedSame : (a.date < b.date ? .orderedAscending : .orderedDescending)
            case .size: primary = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .kind:
                let ka = a.kind.localizedStandardCompare(b.kind)
                primary = ka == .orderedSame ? (a.category.rawValue == b.category.rawValue ? .orderedSame : (a.category.rawValue < b.category.rawValue ? .orderedAscending : .orderedDescending)) : ka
            }
            if primary != .orderedSame { return ascending ? primary == .orderedAscending : primary == .orderedDescending }
            // Ties always fall back to name, A→Z, so the order is stable.
            return byName == .orderedAscending
        }
    }

    /// Filters by name, case- and accent-insensitively.
    static func filter(_ items: [FileItem], _ text: String) -> [FileItem] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
