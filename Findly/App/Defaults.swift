import Foundation

/// Every stored preference, under "Findly.*" keys.
enum Defaults {
    private static var store: UserDefaults { .standard }

    /// Drops keys older versions wrote and moves per-edge sizes to per-axis ones.
    static func migrate() {
        for key in ["Findly.managedWindowID", "Findly.cornerRadius", "Findly.savedTargetPath", "Findly.sidebarOrder", "NSTableView Columns v3 FindlyList"] {
            store.removeObject(forKey: key)
        }
        for (axis, edges) in [("width", ["right", "left"]), ("height", ["bottom", "top"])] {
            let old = edges.map { store.double(forKey: "Findly.thickness.\($0)") }.first { $0 > 0 }
            if store.double(forKey: "Findly.size.\(axis)") <= 0, let old { store.set(old, forKey: "Findly.size.\(axis)") }
            edges.forEach { store.removeObject(forKey: "Findly.thickness.\($0)") }
        }
    }

    // MARK: Drawer

    /// The edge the toggle shortcut opens on: the last one used, unless a default edge is set.
    static var lastEdge: ScreenEdge? {
        get { store.string(forKey: "Findly.lastEdge").flatMap(ScreenEdge.init) }
        set { store.set(newValue?.rawValue, forKey: "Findly.lastEdge") }
    }

    /// A fixed edge for the toggle shortcut; nil means "where it was last".
    static var defaultEdge: ScreenEdge? {
        get { store.string(forKey: "Findly.defaultEdge").flatMap(ScreenEdge.init) }
        set { store.set(newValue?.rawValue, forKey: "Findly.defaultEdge") }
    }

    /// Width when docked left or right, height when docked top or bottom.
    static func size(for edge: ScreenEdge) -> CGFloat? {
        let v = store.double(forKey: "Findly.size.\(edge.isHorizontal ? "height" : "width")")
        return v > 0 ? CGFloat(v) : nil
    }

    static func setSize(_ value: CGFloat, for edge: ScreenEdge) {
        store.set(Double(value), forKey: "Findly.size.\(edge.isHorizontal ? "height" : "width")")
    }

    static func resetSizes() {
        store.removeObject(forKey: "Findly.size.width")
        store.removeObject(forKey: "Findly.size.height")
    }

    /// Slide away when another app comes to the front. On by default.
    static var autoPark: Bool {
        get { store.object(forKey: "Findly.autoPark") as? Bool ?? true }
        set { store.set(newValue, forKey: "Findly.autoPark") }
    }

    /// The mouse's side buttons go Back and Forward. On by default.
    static var mouseNavEnabled: Bool {
        get { store.object(forKey: "Findly.mouseNavEnabled") as? Bool ?? true }
        set { store.set(newValue, forKey: "Findly.mouseNavEnabled") }
    }

    /// The folder the drawer showed last, reopened at launch.
    static var lastFolder: URL? {
        get { store.string(forKey: "Findly.lastFolder").map { URL(fileURLWithPath: $0) } }
        set { store.set(newValue?.path, forKey: "Findly.lastFolder") }
    }

    // MARK: List

    static var arrangement: Arrangement {
        get {
            Arrangement(sort: FileSort(rawValue: store.string(forKey: "Findly.sortKey") ?? "") ?? .name,
                        ascending: store.object(forKey: "Findly.sortAscending") as? Bool ?? true,
                        groupByKind: store.bool(forKey: "Findly.groupByKind"))
        }
        set {
            store.set(newValue.sort.rawValue, forKey: "Findly.sortKey")
            store.set(newValue.ascending, forKey: "Findly.sortAscending")
            store.set(newValue.groupByKind, forKey: "Findly.groupByKind")
        }
    }

    static var showHidden: Bool {
        get { store.bool(forKey: "Findly.showHidden") }
        set { store.set(newValue, forKey: "Findly.showHidden") }
    }

    /// Size, Kind and Date column widths as the user dragged them.
    static var columnWidths: [String: CGFloat] {
        get { (store.dictionary(forKey: "Findly.columnWidths") as? [String: Double] ?? [:]).mapValues { CGFloat($0) } }
        set { store.set(newValue.mapValues { Double($0) }, forKey: "Findly.columnWidths") }
    }

    // MARK: Sidebar

    /// Sidebar items turned off in Settings › Sidebar, by `SidebarItem.key`.
    static var hiddenSidebarItems: Set<String> {
        get { Set(store.stringArray(forKey: "Findly.sidebar.hidden") ?? []) }
        set { store.set(newValue.sorted(), forKey: "Findly.sidebar.hidden") }
    }

    /// Shows what Finder's own Settings › Sidebar shows, re-read every time the drawer opens.
    static var syncFinderSidebar: Bool {
        get { store.bool(forKey: "Findly.sidebar.syncFinder") }
        set { store.set(newValue, forKey: "Findly.sidebar.syncFinder") }
    }

    /// Sidebar sections folded shut. Tags start folded, since Finder's list is long.
    static var collapsedSidebarSections: Set<String> {
        get { Set(store.stringArray(forKey: "Findly.sidebar.collapsed") ?? ["tags"]) }
        set { store.set(newValue.sorted(), forKey: "Findly.sidebar.collapsed") }
    }

    // MARK: Hotkeys

    /// The user's binding for an action, or its default.
    static func hotkey(for action: HotkeyAction) -> Hotkey {
        guard let dict = store.dictionary(forKey: hotkeyKey(action)),
              let keyCode = dict["keyCode"] as? Int, let modifiers = dict["modifiers"] as? Int else {
            return action.defaultHotkey
        }
        return Hotkey(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
    }

    /// nil goes back to the default.
    static func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        if let hotkey {
            store.set(["keyCode": Int(hotkey.keyCode), "modifiers": Int(hotkey.carbonModifiers)], forKey: hotkeyKey(action))
        } else {
            store.removeObject(forKey: hotkeyKey(action))
        }
    }

    private static func hotkeyKey(_ action: HotkeyAction) -> String { "Findly.hotkey.\(action.rawValue)" }
}
