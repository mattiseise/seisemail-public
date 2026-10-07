import AppKit
import MailCore

/// Fork (seisemail): maps a key event to the `h` menu's keys.
enum SnoozeKeyRouter {
    /// nil = give the event back untouched (⌘ and ⌃ combinations: ⌘Q, ⌘W, ⌘1…9).
    static func key(for event: NSEvent) -> SnoozeMenuKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return nil }
        switch event.keyCode {
        case 36, 76: return .enter
        case 53: return .escape
        case 48: return .tab                                                // also ⇧⇥: there are two fields
        case 123: return .left
        case 124: return .right
        case 51, 117: return .backspace                                     // ⌫ and ⌦
        case 125: return .down
        case 126: return .up
        default:
            guard !flags.contains(.option), let c = event.charactersIgnoringModifiers else { return .other }
            if let n = Int(c), (0...9).contains(n) { return .digit(n) }      // number row and keypad
            if c == "j" { return .down }
            if c == "k" { return .up }
            return .other
        }
    }
}
