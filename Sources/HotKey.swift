import AppKit
import Carbon

enum HotKey {
    static let modifierKeys: [Int: String] = [
        kVK_Shift: "Left ⇧", kVK_RightShift: "Right ⇧",
        kVK_Control: "Left ⌃", kVK_RightControl: "Right ⌃",
        kVK_Option: "Left ⌥", kVK_RightOption: "Right ⌥",
        kVK_Command: "Left ⌘", kVK_RightCommand: "Right ⌘",
    ]
    private static var refs: [EventHotKeyRef] = []
    private static var monitors: [Any] = []
    private static var detector = DoubleTap()
    private static var action: (TextAction) -> Void = { _ in }

    static func install(_ handler: @escaping (TextAction) -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == OSType(0x5459_5044),
                  let index = Int(exactly: id.id), TextAction.allCases.indices.contains(index) else { return noErr }
            HotKey.action(TextAction.allCases[index])
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    static func register() -> Bool {
        unregister()
        let defaults = UserDefaults.standard
        var success = true
        var modifierActions: [Int: TextAction] = [:]
        for (index, operation) in TextAction.allCases.enumerated() {
            let code = defaults.integer(forKey: operation.hotkeyCodeKey)
            let mods = defaults.integer(forKey: operation.hotkeyModsKey)
            if modifierKeys[code] != nil {
                if modifierActions[code] != nil { success = false }
                else { modifierActions[code] = operation }
                continue
            }
            guard let key = UInt32(exactly: code), let modifiers = UInt32(exactly: mods) else {
                success = false
                continue
            }
            let id = EventHotKeyID(signature: OSType(0x5459_5044), id: UInt32(index))
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else { success = false }
        }
        if !modifierActions.isEmpty {
            let bindings = modifierActions
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown]
            let handle = { (event: NSEvent) in
                if let key = detector.feed(event), let operation = bindings[key] { action(operation) }
            }
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle),
                NSEvent.addLocalMonitorForEvents(matching: mask) { handle($0); return $0 },
            ].compactMap { $0 }
            success = success && !monitors.isEmpty
        }
        return success
    }

    static func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detector = DoubleTap()
    }
}

struct DoubleTap {
    private var down: Int?
    private var downAt: TimeInterval = 0
    private var last: Int?
    private var lastAt: TimeInterval = 0

    mutating func feed(_ event: NSEvent) -> Int? {
        feed(event.type == .flagsChanged ? Int(event.keyCode) : nil, event.modifierFlags, at: event.timestamp)
    }

    mutating func feed(_ key: Int?, _ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Int? {
        let held = flags.intersection([.control, .option, .shift, .command])
        guard let key, HotKey.modifierKeys[key] != nil else {
            (down, last) = (nil, nil)
            return nil
        }
        if held.isEmpty {
            let tapped = down == key && time - downAt < 0.3 ? key : nil
            down = nil
            if let tapped, tapped == last, time - lastAt < 0.4 {
                last = nil
                return tapped
            }
            (last, lastAt) = (tapped, time)
        } else if down == nil, [.control, .option, .shift, .command].contains(held) {
            (down, downAt) = (key, time)
        } else {
            (down, last) = (nil, nil)
        }
        return nil
    }
}
