import SwiftUI
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted after a binding is saved or reset; HotkeyManager re-registers
    /// everything from Defaults. Notification wiring (rather than passing a
    /// DrawerController reference into the settings window) keeps the settings
    /// UI ignorant of who owns the registrations.
    static let findlyHotkeysChanged = Notification.Name("Findly.hotkeysChanged")
    /// Posted while the settings window is capturing a shortcut. HotkeyManager
    /// suspends its registrations for the duration — a registered hotkey is
    /// consumed by Carbon before it ever reaches our local keyDown monitor, so
    /// re-recording a currently-bound combo would otherwise fire the action
    /// instead of being captured.
    static let findlyHotkeyRecordingBegan = Notification.Name("Findly.hotkeyRecordingBegan")
    static let findlyHotkeyRecordingEnded = Notification.Name("Findly.hotkeyRecordingEnded")
}

/// State for the hotkey settings window: current bindings plus the
/// record-next-keystroke flow.
@MainActor
final class HotkeySettingsModel: ObservableObject {
    @Published private(set) var hotkeys: [HotkeyAction: Hotkey]
    @Published private(set) var recordingAction: HotkeyAction?
    private var keyMonitor: Any?

    init() {
        var map: [HotkeyAction: Hotkey] = [:]
        for action in HotkeyAction.allCases { map[action] = Defaults.hotkey(for: action) }
        hotkeys = map
    }

    func hotkey(for action: HotkeyAction) -> Hotkey {
        hotkeys[action] ?? action.defaultHotkey
    }

    func beginRecording(_ action: HotkeyAction) {
        cancelRecording()
        recordingAction = action
        NotificationCenter.default.post(name: .findlyHotkeyRecordingBegan, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRecorded(event)
        }
    }

    func cancelRecording() {
        guard recordingAction != nil else { return }
        stopRecording()
    }

    func reset(_ action: HotkeyAction) {
        cancelRecording()
        Defaults.setHotkey(nil, for: action)
        hotkeys[action] = action.defaultHotkey
        NotificationCenter.default.post(name: .findlyHotkeysChanged, object: nil)
    }

    private func stopRecording() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        recordingAction = nil
        NotificationCenter.default.post(name: .findlyHotkeyRecordingEnded, object: nil)
    }

    /// Consumes every keystroke while recording: Esc cancels, a combo with at
    /// least one of ⌘⌃⌥ and a renderable key saves, anything else beeps.
    private func handleRecorded(_ event: NSEvent) -> NSEvent? {
        guard let action = recordingAction else { return event }
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return nil
        }
        let keyCode = UInt32(event.keyCode)
        let mods = Hotkey.carbonModifiers(from: event.modifierFlags)
        // Require ⌘, ⌃ or ⌥ so plain typing (or ⇧-typing) can't become a
        // global hotkey that steals keystrokes from every app.
        let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        guard mods & required != 0, Hotkey.isKnownKeyCode(keyCode) else {
            NSSound.beep()
            return nil
        }
        let hotkey = Hotkey(keyCode: keyCode, carbonModifiers: mods)
        Defaults.setHotkey(hotkey, for: action)
        hotkeys[action] = hotkey
        stopRecording()
        NotificationCenter.default.post(name: .findlyHotkeysChanged, object: nil)
        return nil
    }
}

/// One row per action: name, current shortcut, Record/Cancel, Reset.
struct HotkeySettingsView: View {
    @ObservedObject var model: HotkeySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                row(for: action)
            }
            Text(NSLocalizedString(
                "Shortcuts must include ⌘, ⌃ or ⌥. Press Esc to cancel recording.",
                comment: "Hotkey settings window: footnote explaining recording rules"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 400)
    }

    @ViewBuilder
    private func row(for action: HotkeyAction) -> some View {
        let isRecording = model.recordingAction == action
        HStack(spacing: 8) {
            Text(action.localizedTitle)
                .frame(width: 130, alignment: .leading)
            Text(isRecording
                 ? NSLocalizedString("Press shortcut…", comment: "Hotkey settings: placeholder while waiting for the user to type a shortcut")
                 : model.hotkey(for: action).displayString)
                .frame(width: 96)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .opacity(isRecording ? 0.9 : 0.5)
                )
            Button(isRecording
                   ? NSLocalizedString("Cancel", comment: "Cancel button")
                   : NSLocalizedString("Record", comment: "Hotkey settings: button that starts capturing a new shortcut")) {
                if isRecording {
                    model.cancelRecording()
                } else {
                    model.beginRecording(action)
                }
            }
            Button(NSLocalizedString("Reset", comment: "Hotkey settings: button that restores an action's built-in shortcut")) {
                model.reset(action)
            }
        }
    }
}
