import Carbon
import MentorCore

/// Registers one global hotkey with Carbon. Needs no permission.
@MainActor
final class HotKeyCenter {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D4E_5452 // "MNTR"

    /// Registers the hotkey, replacing any previous one. Returns false when the
    /// combination is unusable or another app already holds it.
    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()
        guard hotKey.isUsable else { return false }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: HotKeyCenter.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, HotKeyCenter.carbonModifiers(hotKey.modifiers), id,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard id.signature == HotKeyCenter.signature else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                center.onPress?()
            }
            return noErr
        }, 1, &spec, userData, &handlerRef)
    }

    static func carbonModifiers(_ modifiers: HotKey.Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
