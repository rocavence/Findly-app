import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    typealias Handler = @MainActor (ScreenEdge) -> Void

    private let handler: Handler
    private let toggleHandler: (@MainActor () -> Void)?
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private let signature: OSType = 0x46_4e_44_4c // 'FNDL'
    private let toggleHotkeyID: UInt32 = 5

    init(handler: @escaping Handler, toggle: (@MainActor () -> Void)? = nil) {
        self.handler = handler
        self.toggleHandler = toggle
        installEventHandler()
        registerHotkeys()
    }

    func shutdown() {
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let h = eventHandlerRef { RemoveEventHandler(h) }
        eventHandlerRef = nil
    }

    fileprivate func dispatch(id: UInt32) {
        if id == toggleHotkeyID {
            toggleHandler?()
            return
        }
        guard let edge = HotkeyManager.edges[safe: Int(id) - 1] else { return }
        handler(edge)
    }

    private static let edges: [ScreenEdge] = [.top, .bottom, .left, .right]

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, userData, &eventHandlerRef)
    }

    private func registerHotkeys() {
        // ⌃⌥ + ↑/↓/←/→ → top/bottom/left/right
        let mods = UInt32(controlKey | optionKey)
        let keys: [(UInt32, UInt32)] = [
            (UInt32(kVK_UpArrow),    1),
            (UInt32(kVK_DownArrow),  2),
            (UInt32(kVK_LeftArrow),  3),
            (UInt32(kVK_RightArrow), 4),
        ]
        for (keyCode, id) in keys {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotkeyRefs.append(ref)
            } else {
                NSLog("Findly: failed to register hotkey id=\(id), status=\(status)")
            }
        }

        // ⌘` → toggle the drawer on its last-used edge.
        if toggleHandler != nil {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: toggleHotkeyID)
            let status = RegisterEventHotKey(
                UInt32(kVK_ANSI_Grave), UInt32(cmdKey), hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotkeyRefs.append(ref)
            } else {
                NSLog("Findly: failed to register ⌘` toggle hotkey, status=\(status)")
            }
        }
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    Task { @MainActor in manager.dispatch(id: id) }
    return noErr
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
