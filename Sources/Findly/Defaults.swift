import Foundation

enum Defaults {
    static var managedWindowID: Int? {
        get { UserDefaults.standard.object(forKey: "Findly.managedWindowID") as? Int }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: "Findly.managedWindowID") }
            else { UserDefaults.standard.removeObject(forKey: "Findly.managedWindowID") }
        }
    }

    static var lastEdge: ScreenEdge? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "Findly.lastEdge") else { return nil }
            return ScreenEdge(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "Findly.lastEdge") }
    }

    static func thickness(for edge: ScreenEdge) -> CGFloat? {
        let v = UserDefaults.standard.double(forKey: "Findly.thickness.\(edge.rawValue)")
        return v > 0 ? CGFloat(v) : nil
    }

    static func setThickness(_ value: CGFloat, for edge: ScreenEdge) {
        UserDefaults.standard.set(Double(value), forKey: "Findly.thickness.\(edge.rawValue)")
    }

    // MARK: - File browser sorting / grouping

    static var sortKey: FileSort {
        get { FileSort(rawValue: UserDefaults.standard.string(forKey: "Findly.sortKey") ?? "") ?? .name }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Findly.sortKey") }
    }

    static var sortAscending: Bool {
        get { (UserDefaults.standard.object(forKey: "Findly.sortAscending") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "Findly.sortAscending") }
    }

    static var groupByKind: Bool {
        get { UserDefaults.standard.bool(forKey: "Findly.groupByKind") }
        set { UserDefaults.standard.set(newValue, forKey: "Findly.groupByKind") }
    }

    /// Manual override for the Finder window corner radius (set via `defaults write`).
    static var cornerRadiusOverride: CGFloat? {
        let v = UserDefaults.standard.double(forKey: "Findly.cornerRadius")
        return v > 0 ? CGFloat(v) : nil
    }

    /// POSIX path the managed window was last viewing. Used to restore the
    /// folder when we close the window on a Space change and recreate it
    /// on the user's new Space.
    static var savedTargetPath: String? {
        get { UserDefaults.standard.string(forKey: "Findly.savedTargetPath") }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: "Findly.savedTargetPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "Findly.savedTargetPath")
            }
        }
    }
}
