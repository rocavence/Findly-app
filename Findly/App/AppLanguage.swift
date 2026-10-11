import AppKit

/// The language of the menu, Settings and messages. Takes effect from the next
/// launch (offered as a restart), as in Wunder and Flione. The names are always
/// written in their own language; only "System" is translated.
enum AppLanguage: String, CaseIterable {
    case system
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case es
    case ptBR = "pt-BR"

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .es: "Español"
        case .ptBR: "Português (Brasil)"
        }
    }

    private static let key = "Findly.language"

    static var saved: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .system
    }

    /// The language this launch is running in, to tell whether a restart is due.
    static let launched = saved

    static func save(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Opens a fresh copy of the app, then quits this one.
    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Light, dark, or as the system is — for Findly's own windows.
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let key = "Findly.appearance"

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    static var saved: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .system
    }

    @MainActor static func apply(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: key)
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
