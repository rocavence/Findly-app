import Testing
import AppKit
import Carbon.HIToolbox
@testable import Findly

@Suite struct HotkeyTests {
    // MARK: - Default fallbacks

    @Test func defaultsMatchBuiltinBindings() {
        #expect(HotkeyAction.toggle.defaultHotkey
                == Hotkey(keyCode: UInt32(kVK_ANSI_Grave), carbonModifiers: UInt32(cmdKey)))
        #expect(HotkeyAction.snapTop.defaultHotkey
                == Hotkey(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(controlKey | optionKey)))
        #expect(HotkeyAction.snapBottom.defaultHotkey.keyCode == UInt32(kVK_DownArrow))
        #expect(HotkeyAction.snapLeft.defaultHotkey.keyCode == UInt32(kVK_LeftArrow))
        #expect(HotkeyAction.snapRight.defaultHotkey.keyCode == UInt32(kVK_RightArrow))
    }

    @Test func carbonIDsKeepExistingScheme() {
        #expect(HotkeyAction.snapTop.carbonID == 1)
        #expect(HotkeyAction.snapBottom.carbonID == 2)
        #expect(HotkeyAction.snapLeft.carbonID == 3)
        #expect(HotkeyAction.snapRight.carbonID == 4)
        #expect(HotkeyAction.toggle.carbonID == 5)
    }

    // MARK: - Defaults persistence

    @Test func defaultsRoundTrip() {
        let action = HotkeyAction.snapLeft
        defer { Defaults.setHotkey(nil, for: action) }

        let custom = Hotkey(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(cmdKey | shiftKey))
        Defaults.setHotkey(custom, for: action)
        #expect(Defaults.hotkey(for: action) == custom)

        // Clearing falls back to the built-in default.
        Defaults.setHotkey(nil, for: action)
        #expect(Defaults.hotkey(for: action) == action.defaultHotkey)
    }

    @Test func unsetActionFallsBackToDefault() {
        let action = HotkeyAction.snapRight
        Defaults.setHotkey(nil, for: action)
        #expect(Defaults.hotkey(for: action) == action.defaultHotkey)
    }

    // MARK: - Display strings

    @Test func displayStringRendersSymbols() {
        #expect(HotkeyAction.toggle.defaultHotkey.displayString == "⌘`")
        #expect(HotkeyAction.snapTop.defaultHotkey.displayString == "⌃⌥↑")
        #expect(HotkeyAction.snapLeft.defaultHotkey.displayString == "⌃⌥←")
        // Modifiers render in the standard macOS order ⌃⌥⇧⌘.
        let all = Hotkey(keyCode: UInt32(kVK_ANSI_F),
                         carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.displayString == "⌃⌥⇧⌘F")
    }

    @Test func displayStringUnknownKeyCode() {
        let unknown = Hotkey(keyCode: 9999, carbonModifiers: UInt32(cmdKey))
        #expect(unknown.displayString == "⌘?")
        #expect(!Hotkey.isKnownKeyCode(9999))
        #expect(Hotkey.isKnownKeyCode(UInt32(kVK_ANSI_Grave)))
    }

    // MARK: - Menu keyEquivalent mapping

    @Test func keyEquivalentMapping() {
        #expect(HotkeyAction.toggle.defaultHotkey.keyEquivalent == "`")
        #expect(HotkeyAction.toggle.defaultHotkey.keyEquivalentModifierMask == [.command])

        let up = HotkeyAction.snapTop.defaultHotkey
        #expect(up.keyEquivalent == String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        #expect(up.keyEquivalentModifierMask == [.control, .option])

        // Letters are lowercased for keyEquivalent (uppercase would imply ⇧).
        let letter = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey))
        #expect(letter.keyEquivalent == "a")

        // Unknown keyCodes degrade to no visible shortcut.
        let unknown = Hotkey(keyCode: 9999, carbonModifiers: UInt32(cmdKey))
        #expect(unknown.keyEquivalent == "")
    }

    // MARK: - Modifier conversion

    @Test func modifierFlagConversionRoundTrip() {
        let flags: NSEvent.ModifierFlags = [.command, .option]
        #expect(Hotkey.carbonModifiers(from: flags) == UInt32(cmdKey | optionKey))

        let hotkey = Hotkey(keyCode: 0, carbonModifiers: UInt32(controlKey | shiftKey))
        #expect(hotkey.keyEquivalentModifierMask == [.control, .shift])
        #expect(Hotkey.carbonModifiers(from: hotkey.keyEquivalentModifierMask) == hotkey.carbonModifiers)
    }
}
