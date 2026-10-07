import AppKit
import MailCore
import WebKit

/// Routes single-key shortcuts in the main window to the app, unless the user is typing.
@MainActor
final class KeyboardMonitor {
    static let shared = KeyboardMonitor()
    private var token: Any?

    func install(_ app: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak app] event in
            guard let app, Self.isMainWindowKey(app) else { return event }
            // Fork (seisemail): the open snooze menu gets every key first, its date field included.
            if app.seise.isMenuOpen {
                guard app.phase == .ready else { app.seise.closeMenu(); return event }
                return app.seise.handleMenuKey(event) ? nil : event
            }
            guard !Self.isEditingText() else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Arrow keys move through the list, except while the reading pane has focus (they scroll it).
            let readingFocused = NSApp.keyWindow?.firstResponder is WKWebView
            let characters: String = switch event.keyCode {
            case 36, 76: "\r"
            case 53: "\u{1b}"
            case 125 where !readingFocused: ShortcutMap.downArrow
            case 126 where !readingFocused: ShortcutMap.upArrow
            case 125, 126: ""
            default: (flags.contains(.option) ? event.charactersIgnoringModifiers : event.characters) ?? ""
            }
            if let n = ShortcutMap.viewIndex(
                for: characters,
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option)
            ) {
                guard app.phase == .ready else { return event }
                Task { await app.switchView(n) }
                return nil
            }
            guard let command = ShortcutMap(keys: app.settings.app.shortcuts).command(
                for: characters,
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option)
            ) else { return event }
            guard app.phase == .ready else { return event }
            Task { await app.perform(command) }
            return nil
        }
    }

    private static func isMainWindowKey(_ app: AppModel) -> Bool {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return false }
        return window === app.mainWindow
    }

    private static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }
}
