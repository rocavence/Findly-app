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
    private let toggleHotkeyID: UInt32 = HotkeyAction.toggle.carbonID
    private var notificationTokens: [NSObjectProtocol] = []

    init(handler: @escaping Handler, toggle: (@MainActor () -> Void)? = nil) {
        self.handler = handler
        self.toggleHandler = toggle
        installEventHandler()
        registerHotkeys()
        observeHotkeyChanges()
    }

    /// Drop and re-register every hotkey from Defaults — called after the user
    /// edits a binding in the settings window.
    func reload() {
        unregisterAll()
        registerHotkeys()
    }

    func shutdown() {
        unregisterAll()
        if let h = eventHandlerRef { RemoveEventHandler(h) }
        eventHandlerRef = nil
        for t in notificationTokens { NotificationCenter.default.removeObserver(t) }
        notificationTokens.removeAll()
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

    /// Register every action's binding from Defaults (built-in defaults when
    /// the user hasn't customized: ⌃⌥arrows for the edges, ⌘` for toggle).
    private func registerHotkeys() {
        for action in HotkeyAction.allCases {
            if action == .toggle && toggleHandler == nil { continue }
            let hotkey = Defaults.hotkey(for: action)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: action.carbonID)
            let status = RegisterEventHotKey(
                hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotkeyRefs.append(ref)
            } else {
                NSLog("Findly: failed to register hotkey for \(action.rawValue), status=\(status)")
            }
        }
    }

    private func unregisterAll() {
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
    }

    /// React to the hotkey settings window. While it records a new shortcut we
    /// unregister everything, because Carbon would consume a currently-bound
    /// combo before the recorder's keyDown monitor could capture it.
    private func observeHotkeyChanges() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .findlyHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        notificationTokens.append(center.addObserver(
            forName: .findlyHotkeyRecordingBegan, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unregisterAll() }
        })
        notificationTokens.append(center.addObserver(
            forName: .findlyHotkeyRecordingEnded, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
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
