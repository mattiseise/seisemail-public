import Foundation

/// The fork's two views (phase 1 design D6): ordinary, editable user views with fixed IDs.
public enum SeiseViews {
    public static let inboxZeroID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    public static let snoozedID = UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!

    /// "Käsiteltävät", InboxZero.defaultQuery, icon "tray.full" (Q1)
    public static var inboxZero: MailView {
        MailView(id: inboxZeroID, name: "Käsiteltävät", query: InboxZero.defaultQuery, icon: "tray.full")
    }

    /// "Torkku", SnoozeLabelScheme.standard.viewQuery ("label:torkku"), icon "moon.zzz"
    public static var snoozed: MailView {
        MailView(id: snoozedID, name: "Torkku", query: SnoozeLabelScheme.standard.viewQuery, icon: "moon.zzz")
    }

    /// [inboxZero] + ViewsConfigStore.defaults + [snoozed], for "Palauta oletukset" on the Mac.
    public static var defaults: [MailView] {
        [inboxZero] + ViewsConfigStore.defaults + [snoozed]
    }

    /// Inserts inboxZero at 0 and appends snoozed, each unless a view with its ID or an equal query exists
    /// (lowercased, whitespace runs collapsed). Never reorders, renames or removes. nil = unchanged.
    public static func adding(to views: [MailView]) -> [MailView]? {
        var result = views
        var changed = false
        if !views.contains(where: { matches($0, inboxZero) }) {
            result.insert(inboxZero, at: 0)
            changed = true
        }
        if !views.contains(where: { matches($0, snoozed) }) {
            result.append(snoozed)
            changed = true
        }
        return changed ? result : nil
    }

    /// The empty-state kind of a saved view: the fork's fixed ID first, then a query equivalent to the fork
    /// view's (the same normalisation as `adding`), so pre-existing and duplicated views count too
    /// (Matti's decision 4.10.2026). Searches and changed chips are ruled out by `MailStore.listViewKind`.
    public static func kind(of view: MailView) -> ListViewKind {
        if view.id == inboxZeroID { return .inboxZero }
        if view.id == snoozedID { return .snoozed }
        let query = normalized(view.query)
        if query == normalized(inboxZero.query) { return .inboxZero }
        if query == normalized(snoozed.query) { return .snoozed }
        return .other
    }

    private static func matches(_ view: MailView, _ fork: MailView) -> Bool {
        view.id == fork.id || normalized(view.query) == normalized(fork.query)
    }

    private static func normalized(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
