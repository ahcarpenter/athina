import Carbon
import AthinaCore

/// Registers Athina's global hotkeys with Carbon, which needs no permission
/// and reports both the press and the release of a registered combination.
/// The release is what makes push-to-talk possible without Input Monitoring:
/// Carbon delivers `kEventHotKeyReleased` for a hotkey it registered, so the
/// app hears the key go up without watching keyboard events at all.
@MainActor
final class HotKeyCenter {
    /// One registration each; the raw value is the Carbon hotkey id.
    enum Slot: UInt32, CaseIterable {
        case pause = 1
        case pushToTalk = 2
    }

    var onPress: ((Slot) -> Void)?
    var onRelease: ((Slot) -> Void)?

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D4E_5452 // "MNTR"

    /// Registers the hotkey for the slot, replacing any previous one; nil
    /// unregisters it. Returns false when the combination is unusable, not
    /// set, or another app already holds it.
    @discardableResult
    func register(_ hotKey: HotKey?, for slot: Slot) -> Bool {
        unregister(slot)
        guard let hotKey, hotKey.isUsable else { return false }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: HotKeyCenter.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, HotKeyCenter.carbonModifiers(hotKey.modifiers), id,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[slot] = ref
        return true
    }

    func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }

    func unregisterAll() {
        for slot in Slot.allCases { unregister(slot) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard id.signature == HotKeyCenter.signature, let slot = Slot(rawValue: id.id) else { return noErr }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if released {
                    center.onRelease?(slot)
                } else {
                    center.onPress?(slot)
                }
            }
            return noErr
        }, specs.count, &specs, userData, &handlerRef)
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
