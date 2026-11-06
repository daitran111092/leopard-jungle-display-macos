import Foundation
import Carbon.HIToolbox
import LJCore

/// Global hot keys via Carbon RegisterEventHotKey. Needs a running AppKit/Carbon event loop.
public final class HotKeys: @unchecked Sendable {
    private let bindings: [Action: [String]]
    private let onAction: @MainActor (Action) -> Void
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var idToAction: [UInt32: Action] = [:]

    /// One binding that could not be registered.
    public struct Failure: Equatable, Sendable, CustomStringConvertible {
        public var action: Action
        public var binding: String
        public var reason: String
        public var description: String { "\(action.rawValue) \"\(binding)\" (\(reason))" }
    }

    /// Every binding of every action fires that action.
    public init(bindings: [Action: [String]], onAction: @escaping @MainActor (Action) -> Void) {
        self.bindings = bindings
        self.onAction = onAction
    }

    deinit { unregister() }

    /// Total number of bindings `register()` tries.
    public var bindingCount: Int { bindings.values.reduce(0) { $0 + $1.count } }

    private static let fKeys: [String: Int] = ["F13": kVK_F13, "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16,
                                               "F17": kVK_F17, "F18": kVK_F18, "F19": kVK_F19]
    private static let navKeys: [String: Int] = ["LEFT": kVK_LeftArrow, "RIGHT": kVK_RightArrow, "UP": kVK_UpArrow,
                                                 "DOWN": kVK_DownArrow, "SPACE": kVK_Space, "RETURN": kVK_Return,
                                                 "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket]

    /// Parses a binding into (virtual key code, Carbon modifiers). Case-insensitive; parts are joined by `+`.
    /// Accepted: `F13`…`F19`, `Shift+F13`…`Shift+F19`, and `Ctrl+Option+{Left,Right,Up,Down,Space,Return,[,]}`
    /// (`Control` / `Opt` / `Alt` aliases, either order). Anything else → nil.
    public static func parse(_ s: String) -> (UInt32, UInt32)? {
        let parts = s.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            let bit: Int
            switch m {
            case "SHIFT": bit = shiftKey
            case "CTRL", "CONTROL": bit = controlKey
            case "OPTION", "OPT", "ALT": bit = optionKey
            default: return nil
            }
            guard mods & UInt32(bit) == 0 else { return nil } // repeated modifier
            mods |= UInt32(bit)
        }
        if let c = fKeys[key], mods == 0 || mods == UInt32(shiftKey) { return (UInt32(c), mods) }
        if let c = navKeys[key], mods == UInt32(controlKey | optionKey) { return (UInt32(c), mods) }
        return nil
    }

    /// Registers every binding of every action; returns the bindings that failed (unparseable or refused by the
    /// system, e.g. a combo another app or macOS already owns).
    public func register() -> [Failure] {
        unregister()
        var failed: [Failure] = []
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = me.idToAction[hk.id] {
                let cb = me.onAction
                DispatchQueue.main.async { MainActor.assumeIsolated { cb(action) } }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            return Action.allCases.flatMap { a in (bindings[a] ?? []).map { Failure(action: a, binding: $0, reason: "no event handler (\(status))") } }
        }

        var nextID: UInt32 = 1
        for action in Action.allCases {
            for text in bindings[action] ?? [] {
                guard let (code, mods) = Self.parse(text) else {
                    failed.append(Failure(action: action, binding: text, reason: "unparseable")); continue
                }
                let id = nextID; nextID += 1
                var ref: EventHotKeyRef?
                let st = RegisterEventHotKey(code, mods, EventHotKeyID(signature: OSType(0x4C4A4B59), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
                if st == noErr, let ref { refs.append(ref); idToAction[id] = action }
                else { failed.append(Failure(action: action, binding: text, reason: "refused (\(st))")) }
            }
        }
        return failed
    }

    public func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        idToAction = [:]
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }
}
