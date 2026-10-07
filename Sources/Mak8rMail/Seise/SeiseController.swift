import AppKit
import MailCore
import Observation
import SwiftUI

/// Fork (seisemail): snooze holders and the wake loop, the `h` menu, migrations, the daily counter.
@MainActor @Observable
final class SeiseController {
    struct OpenMenu {
        var model: SnoozeMenuModel
        let email: String
        let target: SnoozeTarget
        weak var store: MailStore?
    }

    /// Owner decisions (Q5, Q8). Phase 1 has no settings UI for them.
    @ObservationIgnored let presetSettings = SnoozePresetSettings.standard
    @ObservationIgnored let wakeLabelsOutsideTorkku = true

    let snooze = SnoozeCoordinator(wakerEnabled: !UserDefaults.standard.bool(forKey: "seiseWakerDisabled"))
    let counter = DailyCounterStore(file: SettingsFile(fileURL: DailyCounterStore.defaultURL))
    /// Weeks with Inbox 0, for the streak on the Inbox 0 photo.
    let streak = InboxZeroStreakStore(file: SettingsFile(fileURL: InboxZeroStreakStore.defaultURL))
    /// Inbox 0 photo: the picture of the day, else the photos in the app bundle (Resources/InboxZero).
    @ObservationIgnored let photos = DailyPhotoStore(
        cacheDirectory: AppPaths.cacheDirectory.appendingPathComponent("inbox0", isDirectory: true),
        bundled: BundledPhotos(directory: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/InboxZero")),
        userAgent: "seisemail/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") "
            + "(personal mail client; https://github.com/mattiseise/seisemail)")
    private(set) var menu: OpenMenu?
    @ObservationIgnored private var mainWindow: @MainActor () -> NSWindow? = { nil }
    @ObservationIgnored private var isCurrent: @MainActor (AccountSession) -> Bool = { _ in true }
    @ObservationIgnored private let migrations = SeiseMigrations(stateFile: SettingsFile(fileURL: SeiseMigrationState.defaultURL))

    /// `isCurrent`: the session is still AppModel's for its account (a sign-in may have replaced it meanwhile).
    func configure(settings: SettingsStore, mainWindow: @escaping @MainActor () -> NSWindow?,
                   isCurrent: @escaping @MainActor (AccountSession) -> Bool,
                   isExpired: @escaping @MainActor (String) -> Bool,
                   onSignInExpired: @escaping @MainActor (String) -> Void) {
        self.mainWindow = mainWindow
        self.isCurrent = isCurrent
        migrations.migrateShortcuts(settings)
        snooze.isPaused = isExpired
        snooze.onSignInExpired = onSignInExpired
    }

    func migrateViews(for email: String) {
        migrations.migrateViews(email: email, store: ViewsConfigStore(fileURL: ViewsConfigStore.url(for: email)))
    }

    /// One account's launch (`SnoozeCoordinator.launch`). The daily-counter hook comes first: an archive made while
    /// the counts still load is counted, so its undo is symmetric. Then the sorting labels Käsiteltävät excludes
    /// (created if missing, labels.list 1 + create 5 each; the first load waits for them at most the launch
    /// grace), the store's first load, and the launch wake pass before the loop (mail woken at launch does not
    /// notify, Q3). A replaced session (sign-in during launch) only loads: it must not take the live one's slot.
    func start(_ session: AccountSession) async {
        let counter = self.counter
        session.store.onActivity = { counter.record($0) }
        await snooze.launch(session, isCurrent: { self.isCurrent(session) })
        await refreshSummary(email: session.email)
    }

    // MARK: Snoozed counts (sidebar Torkku, Inbox 0, menu bar)

    func summary(email: String?) -> SnoozeSummary? {
        email.flatMap { snooze.account(email: $0)?.summary }
    }

    func totalSnoozed(emails: [String]) -> Int {
        emails.reduce(0) { $0 + (summary(email: $1)?.total ?? 0) }
    }

    /// 1–3 quota units (SnoozeSummary.load). After launch and each snooze, and with the 60 s refresh, which also
    /// covers wake passes, undo and changes made on other devices.
    func refreshSummary(email: String) async {
        await snooze.account(email: email)?.refreshSummary()
    }

    func accountRemoved(_ email: String) {
        snooze.detach(email: email)
        if menu?.email == email { closeMenu() }
    }

    // MARK: Rows

    func wakeLabel(for thread: ThreadSummary, in store: MailStore, email: String?) -> String? {
        guard let email, wakeLabelsOutsideTorkku
                || SearchSyntax.hasPositiveTerm(store.activeQuery, SnoozeLabelScheme.standard.viewQuery) else { return nil }
        return snooze.account(email: email)?.rowLabel(for: thread.labelIDs, now: Date())
    }

    func reloadNames(knowing ids: Set<String>, email: String?) async {
        guard let email else { return }
        await snooze.account(email: email)?.reloadNames(knowing: ids)
    }

    // MARK: The `h` menu

    var isMenuOpen: Bool { menu != nil }

    func openMenu(session: AccountSession?) {
        guard menu == nil, let session, let target = session.store.snoozeTarget,
              snooze.account(email: session.email) != nil else { return }          // nothing selected: silent, like `e`
        if textFieldHasFocus() { mainWindow()?.makeFirstResponder(nil) }          // row menu from the search field
        menu = OpenMenu(model: SnoozeMenuModel(now: Date(), targetCount: target.threadIDs.count, settings: presetSettings),
                        email: session.email, target: target, store: session.store)
    }

    func closeMenu() {
        menu = nil
    }

    /// From KeyboardMonitor while the menu is open. true = consumed.
    func handleMenuKey(_ event: NSEvent) -> Bool {
        guard menu != nil else { return false }
        // A click or ⌘F/⌘N moved focus to the sidebar search or the compose card: the key is theirs, the card goes.
        if textFieldHasFocus() { closeMenu(); return false }
        guard let key = SnoozeKeyRouter.key(for: event) else {                     // ⌘/⌃ combinations
            closeMenu()                                                             // ⌘F, ⌘N, ⌘Z: the command runs
            return false
        }
        return handle(key)
    }

    /// A key for the open menu (also ScreenshotDirector's way in). true = consumed.
    @discardableResult
    func handle(_ key: SnoozeMenuKey) -> Bool {
        guard var open = menu else { return false }
        let action = open.model.handle(key, now: Date())
        menu = open
        return perform(action)
    }

    /// A text input in the main window has focus. The card has no text fields of its own (the calendar and the
    /// time are drawn by the card and fed by `SnoozeMenuModel`); the filter chips' date pickers live in popovers.
    private func textFieldHasFocus() -> Bool {
        guard let responder = mainWindow()?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }       // field editor, compose body
        return responder is NSTextField
    }

    func choose(_ index: Int) {
        guard var open = menu else { return }
        let action = open.model.choose(index)
        menu = open
        _ = perform(action)
    }

    /// "Oma aika" by mouse: a day, a time chip, the month arrows.
    func selectDay(_ day: Int) { menu?.model.selectDay(day) }
    func setTime(minutes: Int) { menu?.model.setTime(minutes: minutes) }
    func showMonth(by offset: Int) { menu?.model.showMonth(by: offset) }

    /// The picker that has the keyboard, kept in step with clicks so tab goes to the other one.
    var customField: SnoozeMenuModel.CustomField {
        get { menu?.model.customField ?? .day }
        set { if menu?.model.customField != newValue { menu?.model.customField = newValue } }
    }

    private func perform(_ action: SnoozeMenuAction) -> Bool {
        switch action {
        case .consumed: return true
        case .passThrough: return false
        case .close: closeMenu(); return true
        case .snooze(let date):
            guard let open = menu else { return true }
            closeMenu()
            Task { await confirm(date, open) }
            return true
        }
    }

    private func confirm(_ date: Date, _ open: OpenMenu) async {
        guard let store = open.store, let account = snooze.account(email: open.email) else { return }
        guard store.snoozeTarget == open.target else {
            store.toast = "Valinta muuttui, joten viestejä ei torkutettu"
            return
        }
        let done = await store.snooze(until: date, using: account.service)
        guard done > 0 else { return }                                  // the store already showed a failure toast
        if done == open.target.threadIDs.count {
            store.toast = SnoozeText.successToast(count: done, wakeAt: SnoozeTime.ceilToMinute(date), now: Date())
        }
        await account.reloadNames()                                     // ensureID inserted the new time label: no network
        await account.refreshSummary()
    }
}
