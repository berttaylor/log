import Carbon.HIToolbox

/// System-wide shortcuts: ⌃⌥⌘R starts or stops a recording, ⌃⌥⌘M marks the moment.
/// Carbon's RegisterEventHotKey is still the only way to get one without accessibility access.
enum Hotkeys {
    nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]

    /// Returns false if any shortcut is already taken by another app.
    static func register(_ keys: [(keyCode: Int, action: () -> Void)]) -> Bool {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkeys.actions[id.id]?()
            return noErr
        }, 1, &pressed, nil, nil)
        var ok = true
        for (i, key) in keys.enumerated() {
            let id = UInt32(i + 1)
            actions[id] = key.action
            var ref: EventHotKeyRef?
            ok = RegisterEventHotKey(UInt32(key.keyCode), UInt32(controlKey | optionKey | cmdKey),
                                     EventHotKeyID(signature: OSType(0x4C4F4721), id: id), GetApplicationEventTarget(), 0, &ref) == noErr && ok
        }
        return ok
    }
}
