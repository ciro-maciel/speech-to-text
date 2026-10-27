// Global shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility
// permission. From the Assistant, plus the release event: "Segurar" dictates while the key is
// down, so the app needs to know when it comes up.
import Carbon.HIToolbox
import Foundation

final class HotKeys {
    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: (_ isDown: Bool) -> Void] = [:]

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[id.id]?(isDown) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Returns false when another app already holds the combination.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut, action: @escaping (_ isDown: Bool) -> Void) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: OSType(0x53545458), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        actions[id] = nil
    }

    func isRegistered(id: UInt32) -> Bool { refs[id] != nil }
}
