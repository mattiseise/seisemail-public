import Testing
@testable import MailCore

@Suite struct ShortcutMapTests {
    @Test(arguments: [
        ("j", MailCommand.next), ("k", .previous), ("o", .open), ("\r", .open), ("u", .back), ("\u{1b}", .back),
        ("e", .archive), ("s", .star), ("#", .trash), ("U", .markUnread), ("r", .reply), ("a", .replyAll),
        ("f", .forward), ("c", .compose), ("/", .search), ("x", .toggleCheck), ("I", .markRead), ("h", .snooze),
    ])
    func mapsPlainKeys(key: String, command: MailCommand) {
        #expect(ShortcutMap.command(for: key, command: false, control: false, option: false) == command)
    }

    @Test func modifiersDisableSingleKeyShortcuts() {
        #expect(ShortcutMap.command(for: "e", command: true, control: false, option: false) == nil)
        #expect(ShortcutMap.command(for: "e", command: false, control: true, option: false) == nil)
        #expect(ShortcutMap.command(for: "e", command: false, control: false, option: true) == nil)
    }

    @Test func optionDigitSwitchesView() {
        #expect(ShortcutMap.viewIndex(for: "1", command: false, control: false, option: true) == 1)
        #expect(ShortcutMap.viewIndex(for: "9", command: false, control: false, option: true) == 9)
        #expect(ShortcutMap.viewIndex(for: "0", command: false, control: false, option: true) == nil)
        #expect(ShortcutMap.viewIndex(for: "1", command: true, control: false, option: true) == nil)
        #expect(ShortcutMap.command(for: "1", command: false, control: false, option: true) == nil)
    }

    @Test func checkAllIsNotRebindable() {
        var map = ShortcutMap()
        let checkAll = map.assign("q", to: .checkAll)
        let toggle = map.assign("q", to: .toggleCheck)
        #expect(!checkAll)
        #expect(toggle)
    }

    @Test func commandAChecksAll() {
        #expect(ShortcutMap.command(for: "a", command: true, control: false, option: false) == .checkAll)
    }

    @Test func commandZIsUndo() {
        #expect(ShortcutMap.command(for: "z", command: true, control: false, option: false) == .undo)
    }

    @Test func unknownKeyIsIgnored() {
        #expect(ShortcutMap.command(for: "q", command: false, control: false, option: false) == nil)
        #expect(ShortcutMap.command(for: "E", command: false, control: false, option: false) == nil)
    }

    @Test func customKeysReplaceDefaults() {
        var map = ShortcutMap()
        let assigned = map.assign("x", to: .archive)
        #expect(assigned)
        #expect(map.command(for: "x", command: false, control: false, option: false) == .archive)
        #expect(map.command(for: "e", command: false, control: false, option: false) == nil)
        #expect(map.key(for: .archive) == "x")
    }

    @Test func takingAnotherCommandsKeyUnassignsIt() {
        var map = ShortcutMap()
        let assigned = map.assign("r", to: .archive)
        #expect(assigned)
        #expect(map.command(for: "r", command: false, control: false, option: false) == .archive)
        #expect(map.key(for: .reply) == nil)
        #expect(map.unassigned == [.reply])
    }

    @Test func fixedKeysAlwaysWorkAndCannotBeAssigned() {
        var map = ShortcutMap(keys: [:])
        #expect(map.command(for: "\r", command: false, control: false, option: false) == .open)
        #expect(map.command(for: "\u{1b}", command: false, control: false, option: false) == .back)
        #expect(map.command(for: ShortcutMap.downArrow, command: false, control: false, option: false) == .next)
        #expect(map.command(for: ShortcutMap.upArrow, command: false, control: false, option: false) == .previous)
        #expect(map.command(for: "z", command: true, control: false, option: false) == .undo)
        for key in ["\r", "\u{1b}", ShortcutMap.upArrow, ShortcutMap.downArrow, " ", "ab", "", "\t"] {
            #expect(!ShortcutMap.isAssignable(key))
            let assigned = map.assign(key, to: .archive)
            #expect(!assigned)
        }
        let assigned = map.assign("x", to: .undo)
        #expect(!assigned)
        #expect(ShortcutMap.isAssignable("#"))
        #expect(ShortcutMap.isAssignable("U"))
    }

    @Test func snoozeIsEditable() {
        #expect(ShortcutMap.editableCommands.contains(.snooze))
        #expect(MailCommand.snooze.title == "Torkuta")
        #expect(MailCommand(rawValue: "snooze") == .snooze)
        #expect(ShortcutMap.defaults["h"] == .snooze)
        #expect(ShortcutMap.isAssignable("h"))
    }

    @Test func defaultsAssignEveryEditableCommand() {
        #expect(ShortcutMap().unassigned.isEmpty)
        #expect(Set(ShortcutMap.defaults.values) == Set(ShortcutMap.editableCommands))
        #expect(MailCommand.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
