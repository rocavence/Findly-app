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

    /// Manual override for the Finder window corner radius (set via `defaults write`).
    static var cornerRadiusOverride: CGFloat? {
        let v = UserDefaults.standard.double(forKey: "Findly.cornerRadius")
        return v > 0 ? CGFloat(v) : nil
    }
}
