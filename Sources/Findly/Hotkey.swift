import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut in Carbon's vocabulary (virtual keyCode +
/// modifier bits), since RegisterEventHotKey is what ultimately consumes it.
/// Conversions to AppKit (menu keyEquivalents) and to display symbols live
/// here so the menu, the settings window and the registration all agree.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Human-readable form, modifiers in the standard macOS order ⌃⌥⇧⌘.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Hotkey.keyTable[keyCode]?.display ?? "?")
    }

    /// Single-character string for NSMenuItem.keyEquivalent (arrows map to the
    /// AppKit function-key scalars). Empty when the keyCode isn't in our table,
    /// which simply leaves the menu item without a visible shortcut.
    var keyEquivalent: String {
        Hotkey.keyTable[keyCode]?.equivalent ?? ""
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    /// Whether we can render this keyCode (recording rejects keys we couldn't
    /// show in the menu or the settings window).
    static func isKnownKeyCode(_ code: UInt32) -> Bool {
        keyTable[code] != nil
    }

    /// Pragmatic keyCode lookup covering letters, digits, arrows and common
    /// punctuation — enough for realistic hotkeys without UCKeyTranslate.
    /// `display` is what the settings window shows; `equivalent` is the
    /// NSMenuItem.keyEquivalent string (lowercase letters, function-key
    /// scalars for arrows).
    private static let keyTable: [UInt32: (display: String, equivalent: String)] = {
        var t: [UInt32: (display: String, equivalent: String)] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        for (code, name) in letters { t[UInt32(code)] = (name, name.lowercased()) }
        let digits: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        for (code, name) in digits { t[UInt32(code)] = (name, name) }
        let punctuation: [(Int, String)] = [
            (kVK_ANSI_Grave, "`"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
        ]
        for (code, name) in punctuation { t[UInt32(code)] = (name, name) }
        let arrows: [(Int, String, Int)] = [
            (kVK_UpArrow, "↑", NSUpArrowFunctionKey),
            (kVK_DownArrow, "↓", NSDownArrowFunctionKey),
            (kVK_LeftArrow, "←", NSLeftArrowFunctionKey),
            (kVK_RightArrow, "→", NSRightArrowFunctionKey),
        ]
        for (code, glyph, fn) in arrows {
            t[UInt32(code)] = (glyph, String(Character(UnicodeScalar(fn)!)))
        }
        t[UInt32(kVK_Space)] = ("Space", " ")
        t[UInt32(kVK_Return)] = ("↩", "\r")
        t[UInt32(kVK_Tab)] = ("⇥", "\t")
        return t
    }()
}

/// The five hotkey-able actions. Raw values double as the Defaults key suffix
/// ("Findly.hotkey.<rawValue>"); carbonID keeps the existing EventHotKeyID
/// scheme (1–4 = snap edges, 5 = toggle) so HotkeyManager's dispatch is
/// unchanged.
enum HotkeyAction: String, CaseIterable {
    case toggle
    case snapTop, snapBottom, snapLeft, snapRight

    var carbonID: UInt32 {
        switch self {
        case .snapTop: return 1
        case .snapBottom: return 2
        case .snapLeft: return 3
        case .snapRight: return 4
        case .toggle: return 5
        }
    }

    /// Built-in binding used until the user customizes one (and after Reset).
    var defaultHotkey: Hotkey {
        switch self {
        case .toggle:     return Hotkey(keyCode: UInt32(kVK_ANSI_Grave), carbonModifiers: UInt32(cmdKey))
        case .snapTop:    return Hotkey(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(controlKey | optionKey))
        case .snapBottom: return Hotkey(keyCode: UInt32(kVK_DownArrow), carbonModifiers: UInt32(controlKey | optionKey))
        case .snapLeft:   return Hotkey(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(controlKey | optionKey))
        case .snapRight:  return Hotkey(keyCode: UInt32(kVK_RightArrow), carbonModifiers: UInt32(controlKey | optionKey))
        }
    }

    static func forEdge(_ edge: ScreenEdge) -> HotkeyAction {
        switch edge {
        case .top: return .snapTop
        case .bottom: return .snapBottom
        case .left: return .snapLeft
        case .right: return .snapRight
        }
    }

    /// Row label in the hotkey settings window. Reuses the status-menu keys so
    /// both surfaces stay worded identically in every language.
    var localizedTitle: String {
        switch self {
        case .toggle:     return NSLocalizedString("Toggle Drawer", comment: "Status menu item that shows/hides the drawer")
        case .snapTop:    return NSLocalizedString("Snap Top", comment: "Status menu item: snap drawer to top edge")
        case .snapBottom: return NSLocalizedString("Snap Bottom", comment: "Status menu item: snap drawer to bottom edge")
        case .snapLeft:   return NSLocalizedString("Snap Left", comment: "Status menu item: snap drawer to left edge")
        case .snapRight:  return NSLocalizedString("Snap Right", comment: "Status menu item: snap drawer to right edge")
        }
    }
}
