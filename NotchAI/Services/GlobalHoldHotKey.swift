import AppKit
import Carbon.HIToolbox

/// The key to hold for talking to Jarvis, from anywhere (2026-11-01). A Carbon hot key: it reports
/// both pressing and letting go, and needs no Accessibility or Input Monitoring permission.
/// ⌥Space was the first idea, but ChatGPT (installed and running on this Mac) already holds it, so
/// the default is ⌥J (J for Jarvis). Chosen in the `…` menu.
enum JarvisTalkKey: String, CaseIterable, Identifiable {
    case optionJ
    case optionShiftSpace
    case optionSpace
    case off

    static let storeKey = "jarvisTalkKey"
    static let fallback = JarvisTalkKey.optionJ

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionJ: "⌥J"
        case .optionShiftSpace: "⌥⇧Space"
        case .optionSpace: "⌥Space (ChatGPT와 겹칠 수 있음)"
        case .off: "쓰지 않음"
        }
    }

    /// Just the keys, for hints.
    var keys: String {
        switch self {
        case .optionJ: "⌥J"
        case .optionShiftSpace: "⌥⇧Space"
        case .optionSpace: "⌥Space"
        case .off: ""
        }
    }

    /// Carbon key code and modifiers; nil when off.
    var combo: GlobalHoldHotKey.Combo? {
        switch self {
        case .optionJ: .init(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        case .optionShiftSpace: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
        case .optionSpace: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case .off: nil
        }
    }

    static var current: JarvisTalkKey {
        get { UserDefaults.standard.string(forKey: storeKey).flatMap(JarvisTalkKey.init(rawValue:)) ?? fallback }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storeKey) }
    }
}

/// One system-wide hot key with a pressed and a released event.
@MainActor
final class GlobalHoldHotKey {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// The same modifiers as AppKit flags, to check that they are still held.
        var flags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            return flags
        }
    }

    enum Outcome: Equatable {
        case registered
        /// Another app already holds this combination.
        case taken
        case failed(OSStatus)
        case off
    }

    private static let signature: OSType = 0x4E414A56   // 'NAJV'
    private static var handlerInstalled = false
    private static var live: [UInt32: GlobalHoldHotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private(set) var combo: Combo?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        id = Self.nextID
        Self.nextID += 1
    }

    /// Registers `combo` (nil unregisters).
    @discardableResult
    func register(_ combo: Combo?) -> Outcome {
        unregister()
        guard let combo else { return .off }
        Self.installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return status == eventHotKeyExistsErr ? .taken : .failed(status)
        }
        self.ref = ref
        self.combo = combo
        Self.live[id] = self
        return .registered
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        combo = nil
        Self.live[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), globalHoldHotKeyHandler, types.count, &types, nil, nil)
        handlerInstalled = status == noErr
    }

    fileprivate static func dispatch(id: UInt32, pressed: Bool) {
        guard let key = live[id] else { return }
        pressed ? key.onPress() : key.onRelease()
    }
}

/// Carbon calls this on the main thread, from the application's event loop.
private func globalHoldHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let id = hotKey.id
    MainActor.assumeIsolated { GlobalHoldHotKey.dispatch(id: id, pressed: pressed) }
    return noErr
}
