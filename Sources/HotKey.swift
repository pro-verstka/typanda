import AppKit
import Carbon

enum HotKey {
    static let modifierKeys: [Int: String] = [
        kVK_Shift: "Left ⇧", kVK_RightShift: "Right ⇧",
        kVK_Control: "Left ⌃", kVK_RightControl: "Right ⌃",
        kVK_Option: "Left ⌥", kVK_RightOption: "Right ⌥",
        kVK_Command: "Left ⌘", kVK_RightCommand: "Right ⌘",
    ]
    private static var ref: EventHotKeyRef?
    private static var monitors: [Any] = []
    private static var detector = DoubleTap()
    private static var action: () -> Void = {}

    static func install(_ handler: @escaping () -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action()
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    static func register() -> Bool {
        unregister()
        let defaults = UserDefaults.standard
        let code = defaults.integer(forKey: Prefs.hotkeyCode)
        let mods = defaults.integer(forKey: Prefs.hotkeyMods)

        if modifierKeys[code] != nil {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown]
            let handle = { (event: NSEvent) in if detector.feed(event) == code { action() } }
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle),
                NSEvent.addLocalMonitorForEvents(matching: mask) { handle($0); return $0 },
            ].compactMap { $0 }
            return !monitors.isEmpty
        }

        guard let key = UInt32(exactly: code), let modifiers = UInt32(exactly: mods) else { return false }
        let id = EventHotKeyID(signature: OSType(0x5459_5044), id: 1)
        return RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
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
