import AppKit
import Carbon.HIToolbox

/// A single global hotkey via the Carbon Hot Key API (works while any app is focused). The action
/// is dispatched to the main queue.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    @discardableResult
    init?(keyCode: Int, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        Self.actions[id] = action
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x41474d52) /* 'AGMR' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            NSLog("AiGrammar hotkey \(id) registration failed: \(status)")
            return nil
        }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let action = GlobalHotKey.actions[hkID.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
