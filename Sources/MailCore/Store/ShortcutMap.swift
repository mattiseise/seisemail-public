import Foundation

public enum MailCommand: String, Sendable, Equatable, Codable, CaseIterable {
    case next, previous, open, back
    case archive, star, trash, markUnread
    case reply, replyAll, forward, compose, search
    case undo
    case toggleCheck, checkAll, markRead
    case snooze                                                     // fork (seisemail)
}

extension MailCommand {
    public var title: String {
        switch self {
        case .next: "Seuraava ketju"
        case .previous: "Edellinen ketju"
        case .open: "Avaa"
        case .back: "Takaisin listaan"
        case .archive: "Arkistoi"
        case .star: "Lisää tai poista tähti"
        case .trash: "Siirrä roskakoriin"
        case .markUnread: "Merkitse lukemattomaksi"
        case .reply: "Vastaa"
        case .replyAll: "Vastaa kaikille"
        case .forward: "Välitä"
        case .compose: "Uusi viesti"
        case .search: "Hae"
        case .undo: "Kumoa"
        case .toggleCheck: "Valitse tai poista valinta"
        case .checkAll: "Valitse kaikki"
        case .markRead: "Merkitse luetuksi"
        case .snooze: "Torkuta"                                     // fork (seisemail)
        }
    }
}

/// Gmail-style single-key shortcuts (spec §3.4). Return, Esc, arrows and ⌘Z are fixed;
/// the rest come from `keys`, which the user can edit.
public struct ShortcutMap: Sendable, Equatable {
    public static let upArrow = "\u{F700}"
    public static let downArrow = "\u{F701}"

    public static let defaults: [String: MailCommand] = [
        "j": .next, "k": .previous, "o": .open, "u": .back,
        "e": .archive, "s": .star, "#": .trash, "U": .markUnread,
        "r": .reply, "a": .replyAll, "f": .forward, "c": .compose, "/": .search,
        "x": .toggleCheck, "I": .markRead,
        "h": .snooze,                                               // fork (seisemail)
    ]

    public static let fixed: [String: MailCommand] = [
        "\r": .open, "\u{1b}": .back, upArrow: .previous, downArrow: .next,
    ]

    /// ⌘Z and ⌘A are fixed; everything else can be rebound.
    public static var editableCommands: [MailCommand] { MailCommand.allCases.filter { $0 != .undo && $0 != .checkAll } }

    public var keys: [String: MailCommand]

    public init(keys: [String: MailCommand] = ShortcutMap.defaults) {
        self.keys = keys
    }

    public static func command(for characters: String, command: Bool, control: Bool, option: Bool) -> MailCommand? {
        ShortcutMap().command(for: characters, command: command, control: control, option: option)
    }

    public func command(for characters: String, command: Bool, control: Bool, option: Bool) -> MailCommand? {
        if command {
            guard !control, !option else { return nil }
            switch characters {
            case "z": return .undo
            case "a": return .checkAll
            default: return nil
            }
        }
        guard !control, !option else { return nil }
        return Self.fixed[characters] ?? keys[characters]
    }

    /// ⌥1…9 switches to the n-th sidebar view. Handled apart from `command(for:)` because the
    /// caller must pass the unmodified character: on a Finnish layout ⌥2 types "@".
    public static func viewIndex(for characters: String, command: Bool, control: Bool, option: Bool) -> Int? {
        guard option, !command, !control, let n = Int(characters), (1...9).contains(n) else { return nil }
        return n
    }

    /// One visible, non-space character that is not a fixed key.
    public static func isAssignable(_ key: String) -> Bool {
        guard key.count == 1, fixed[key] == nil, let scalar = key.unicodeScalars.first else { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false } // function/arrow keys
        return !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
    }

    public func key(for command: MailCommand) -> String? {
        keys.first { $0.value == command }?.key
    }

    /// Binds `key` to `command`. The command's old key is freed; a command that had `key` loses it.
    @discardableResult
    public mutating func assign(_ key: String, to command: MailCommand) -> Bool {
        guard Self.isAssignable(key), Self.editableCommands.contains(command) else { return false }
        keys = keys.filter { $0.value != command }
        keys[key] = command
        return true
    }

    public var unassigned: [MailCommand] {
        Self.editableCommands.filter { key(for: $0) == nil }
    }

    public static func label(for key: String) -> String {
        if key.count == 1, let c = key.first, c.isLetter, c.isUppercase { return "⇧\(c)" }
        return key.uppercased()
    }
}
