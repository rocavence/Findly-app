import AppKit

/// The sidebar's sections and items, read the way Finder shows them:
/// Favorites (from Finder's own list, in its order), iCloud, Locations
/// (this Mac, mounted and network volumes) and Tags.
struct SidebarSection: Equatable {
    enum Kind: String, Equatable { case favorites, icloud, locations, tags }
    let kind: Kind
    var items: [SidebarItem]

    var title: String {
        switch kind {
        case .favorites: String(localized: "Favorites")
        case .icloud: "iCloud"
        case .locations: String(localized: "Locations")
        case .tags: String(localized: "Tags")
        }
    }
}

/// A symbol inside another app's bundle.
struct ProviderSymbol: Equatable, Hashable {
    let name: String
    let bundle: URL

    @MainActor var image: NSImage? {
        Bundle(url: bundle).flatMap { NSImage(symbolName: name, bundle: $0, variableValue: 1) }
    }
}

struct SidebarItem: Equatable, Hashable {
    enum Target: Equatable, Hashable {
        case folder(URL)
        case tag(String)
    }
    let target: Target
    let title: String
    /// SF Symbol Finder uses for standard places; nil uses the item's own icon.
    let symbol: String?
    /// A cloud folder's symbol from its provider's File Provider extension (Dropbox's logo), as Finder shows it.
    var providerSymbol: ProviderSymbol?
    /// Tag colour index (Finder's 0–7), for tags.
    var tagColor: Int = 0
    /// A volume that can be ejected.
    var ejectable = false
    /// For volumes, the kind Settings › Sidebar turns on and off as a whole.
    var volumeKind: VolumeKind?

    enum VolumeKind: String, CaseIterable {
        case internalDisk, externalDisk, server

        var title: String {
            switch self {
            case .internalDisk: String(localized: "Hard Disks")
            case .externalDisk: String(localized: "External Disks")
            case .server: String(localized: "Connected Servers")
            }
        }

        var symbol: String {
            switch self {
            case .internalDisk: "internaldrive"
            case .externalDisk: "externaldrive"
            case .server: "network"
            }
        }

        var key: String { "volume:\(rawValue)" }
    }

    var url: URL? { if case .folder(let u) = target { u } else { nil } }

    /// What Settings › Sidebar stores when this item is turned off.
    var key: String {
        if let volumeKind { return volumeKind.key }
        switch target {
        case .folder(let url): return "folder:\(url.standardizedFileURL.path)"
        case .tag(let name): return "tag:\(name)"
        }
    }
}

enum FinderSidebar {
    /// The sections as shown: without what Settings › Sidebar (or Finder's, when synced) turned off, and without empty sections.
    static func sections() -> [SidebarSection] {
        let all = allSections()
        let hidden = Defaults.syncFinderSidebar ? finderHidden(all) : Defaults.hiddenSidebarItems
        return all.compactMap { section in
            var section = section
            section.items.removeAll { hidden.contains($0.key) }
            return section.items.isEmpty ? nil : section
        }
    }

    /// Everything Finder would show, for Settings › Sidebar to choose from.
    static func allSections() -> [SidebarSection] {
        var sections: [SidebarSection] = []
        let favorites = finderFavorites().compactMap { folderItem($0) }
        sections.append(SidebarSection(kind: .favorites, items: favorites.isEmpty ? builtInFavorites() : favorites))
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: drive.path) {
            sections.append(SidebarSection(kind: .icloud, items: [SidebarItem(target: .folder(drive), title: String(localized: "iCloud Drive"), symbol: "icloud")]))
        }
        sections.append(SidebarSection(kind: .locations, items: locations()))
        let tags = finderTags()
        if !tags.isEmpty { sections.append(SidebarSection(kind: .tags, items: tags)) }
        return sections
    }

    /// The SF Symbol Finder's sidebar uses for a standard folder.
    static func symbol(for url: URL) -> String? {
        let fm = FileManager.default
        func std(_ d: FileManager.SearchPathDirectory) -> String? {
            (try? fm.url(for: d, in: .userDomainMask, appropriateFor: nil, create: false))?.standardizedFileURL.path
        }
        let path = url.standardizedFileURL.path
        switch path {
        case fm.homeDirectoryForCurrentUser.standardizedFileURL.path: return "house"
        case std(.desktopDirectory): return "menubar.dock.rectangle"
        case std(.downloadsDirectory): return "arrow.down.circle"
        case std(.documentDirectory): return "doc"
        case std(.moviesDirectory): return "film"
        case std(.musicDirectory): return "music.note"
        case std(.picturesDirectory): return "photo"
        case "/Applications", "/System/Applications": return "square.grid.2x2"
        case "/": return "internaldrive"
        default: return nil
        }
    }

    private static func folderItem(_ url: URL) -> SidebarItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        return SidebarItem(target: .folder(url), title: name, symbol: symbol(for: url) ?? (isPlainFolder(url) ? "folder" : nil),
                           providerSymbol: providerSymbol(for: url))
    }

    nonisolated(unsafe) private static var providerSymbols: [String: ProviderSymbol?] = [:]

    /// For a folder in ~/Library/CloudStorage, the symbol its app's File Provider extension
    /// gives Finder's sidebar. The app is found by the folder's name ("Dropbox", "GoogleDrive-…").
    private static func providerSymbol(for url: URL) -> ProviderSymbol? {
        let path = url.resolvingSymlinksInPath().path
        guard let range = path.range(of: "/Library/CloudStorage/"),
              let folder = path[range.upperBound...].split(separator: "/").first,
              let provider = folder.split(separator: "-").first.map({ $0.lowercased() }) else { return nil }
        if let cached = providerSymbols[provider] { return cached }
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let app = dirs.lazy.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }.first { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "").lowercased() == provider }
        var found: ProviderSymbol?
        if let plugins = app?.appendingPathComponent("Contents/PlugIns"),
           let appexes = try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            for appex in appexes where appex.pathExtension == "appex" {
                guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                      point.hasPrefix("com.apple.fileprovider"),
                      let icon = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any],
                      let name = icon["CFBundleSymbolName"] as? String else { continue }
                found = ProviderSymbol(name: name, bundle: appex)
                break
            }
        }
        providerSymbols[provider] = found
        return found
    }

    /// Plain folders get Finder's folder symbol; app-branded ones (Dropbox) keep their own icon.
    private static func isPlainFolder(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().path
        return !resolved.contains("/Library/CloudStorage/") && !resolved.contains("/Mobile Documents/")
    }

    private static func builtInFavorites() -> [SidebarItem] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.applicationDirectory, .desktopDirectory, .documentDirectory, .downloadsDirectory]
        var urls = dirs.compactMap { d -> URL? in
            d == .applicationDirectory ? URL(fileURLWithPath: "/Applications") : try? fm.url(for: d, in: .userDomainMask, appropriateFor: nil, create: false)
        }
        urls.append(fm.homeDirectoryForCurrentUser)
        return urls.compactMap { folderItem($0) }
    }

    /// This Mac's disk, then mounted volumes (ejectable ones marked), then network volumes.
    private static func locations() -> [SidebarItem] {
        var items: [SidebarItem] = []
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable ?? true else { continue }
            let name = values.volumeLocalizedName ?? volume.lastPathComponent
            if volume.path == "/" {
                items.insert(SidebarItem(target: .folder(volume), title: name, symbol: "internaldrive", volumeKind: .internalDisk), at: 0)
            } else if values.volumeIsLocal == false {
                items.append(SidebarItem(target: .folder(volume), title: name, symbol: "network", ejectable: true, volumeKind: .server))
            } else {
                let removable = (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false) || values.volumeIsInternal == false
                let kind: SidebarItem.VolumeKind = removable ? .externalDisk : .internalDisk
                items.append(SidebarItem(target: .folder(volume), title: name, symbol: kind.symbol, ejectable: removable, volumeKind: kind))
            }
        }
        return items
    }

    /// Finder's favorite tags, with their colours.
    private static func finderTags() -> [SidebarItem] {
        let defaults = UserDefaults(suiteName: "com.apple.finder")
        guard let names = defaults?.array(forKey: "FavoriteTagNames") as? [String] else { return [] }
        // Finder's built-in tags by their English names (how they're stored) and by this Mac's language.
        var colors = ["Gray": 1, "Green": 2, "Purple": 3, "Blue": 4, "Yellow": 5, "Red": 6, "Orange": 7]
        for (index, label) in NSWorkspace.shared.fileLabels.enumerated() where index > 0 { colors[label] = index }
        return names.filter { !$0.isEmpty }.map { name in
            SidebarItem(target: .tag(name), title: name, symbol: nil, tagColor: colors[name] ?? 0)
        }
    }

    /// Finder's sidebar Favorites from its shared-file-list store (needs Full
    /// Disk Access), in Finder's order. Items without a file bookmark (AirDrop,
    /// Recents) are skipped.
    static func finderFavorites() -> [URL] {
        for root in sharedFileLists("FavoriteItems") {
            guard let items = root["items"] as? [[String: Any]] else { continue }
            var urls: [URL] = []
            var seen = Set<String>()
            for item in items {
                guard let bookmark = item["Bookmark"] as? Data else { continue }
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                      (try? url.checkResourceIsReachable()) == true, seen.insert(url.path).inserted else { continue }
                urls.append(url)
            }
            if !urls.isEmpty { return urls }
        }
        return []
    }

    /// One of Finder's shared-file-list stores, newest format first.
    private static func sharedFileLists(_ list: String) -> [[String: Any]] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        return ["sfl4", "sfl3", "sfl2"].compactMap { ext in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("com.apple.LSSharedFileList.\(list).\(ext)")),
                  let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any]
        }
    }

    /// What Finder's own Settings › Sidebar turns off, as `SidebarItem` keys. Favorites need
    /// nothing here: Finder's list already leaves out what it hides.
    static func finderHidden(_ sections: [SidebarSection]) -> Set<String> {
        var hidden = Set<String>()
        if let volumes = sharedFileLists("FavoriteVolumes").first {
            let props = volumes["properties"] as? [String: Any] ?? [:]
            let prefix = "com.apple.LSSharedFileList.FavoriteVolumes."
            let flags: [(String, SidebarItem.VolumeKind)] = [("ShowHardDrives", .internalDisk), ("ShowEjectableVolumes", .externalDisk), ("ShowNetworkVolumes", .server)]
            for (flag, kind) in flags where (props[prefix + flag] as? Int) == 0 { hidden.insert(kind.key) }
            // iCloud Drive is a special item in the same list; visibility 1 is how Finder marks it hidden.
            let items = volumes["items"] as? [[String: Any]] ?? []
            let drive = items.first { (($0["CustomItemProperties"] as? [String: Any])?["com.apple.LSSharedFileList.SpecialItemIdentifier"] as? String) == "com.apple.LSSharedFileList.IsICloudDrive" }
            if (drive?["visibility"] as? Int) == 1 {
                sections.first { $0.kind == .icloud }?.items.forEach { hidden.insert($0.key) }
            }
        }
        if UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "ShowRecentTags") as? Bool == false {
            sections.first { $0.kind == .tags }?.items.forEach { hidden.insert($0.key) }
        }
        return hidden
    }

    /// Ejects a volume; returns an error message when macOS refuses.
    static func eject(_ url: URL) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
