import Foundation

/// A multi-thread action that is still running or just finished, for the calm status line under
/// the list ("Arkistoidaan 140 ketjua…" → "Arkistoitu 140 ketjua").
public struct BulkStatus: Identifiable, Equatable, Sendable {
    public enum Action: Sendable, Equatable {
        case archive, trash, markRead, markUnread, star, unstar
    }

    public let id: UUID
    public let action: Action
    public let total: Int
    /// Threads with a final answer, successful or not.
    public internal(set) var completed = 0
    public internal(set) var succeeded = 0
    public internal(set) var isFinished = false
    /// ⌘Z was pressed; the action is being taken back.
    public internal(set) var isUndoing = false

    public init(id: UUID = UUID(), action: Action, total: Int) {
        self.id = id
        self.action = action
        self.total = total
    }

    /// 0…1 for a progress bar.
    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }

    public var text: String {
        if isUndoing { return Self.undoingText(action) }
        return isFinished ? Self.doneText(action, count: succeeded) : Self.runningText(action, count: total)
    }

    /// "1 ketju" / "140 ketjua": a numeral other than one takes the partitive.
    private static func threads(_ n: Int) -> String { n == 1 ? "1 ketju" : "\(n) ketjua" }

    static func runningText(_ action: Action, count n: Int) -> String {
        switch action {
        case .archive: "Arkistoidaan \(threads(n))…"
        case .trash: "Siirretään \(threads(n)) roskakoriin…"
        case .markRead: "Merkitään \(threads(n)) \(n == 1 ? "luetuksi" : "luetuiksi")…"
        case .markUnread: "Merkitään \(threads(n)) \(n == 1 ? "lukemattomaksi" : "lukemattomiksi")…"
        case .star: "Lisätään tähti \(n) ketjuun…"
        case .unstar: "Poistetaan tähti \(n) ketjusta…"
        }
    }

    static func undoingText(_ action: Action) -> String {
        switch action {
        case .archive: "Kumotaan arkistointi…"
        case .trash: "Kumotaan roskakoriin siirtäminen…"
        case .markRead: "Kumotaan luetuksi merkitseminen…"
        case .markUnread: "Kumotaan lukemattomaksi merkitseminen…"
        case .star: "Kumotaan tähden lisääminen…"
        case .unstar: "Kumotaan tähden poistaminen…"
        }
    }

    static func doneText(_ action: Action, count n: Int) -> String {
        switch action {
        case .archive: "Arkistoitu \(threads(n))"
        case .trash: "Siirretty \(threads(n)) roskakoriin"
        case .markRead: "Merkitty \(threads(n)) \(n == 1 ? "luetuksi" : "luetuiksi")"
        case .markUnread: "Merkitty \(threads(n)) \(n == 1 ? "lukemattomaksi" : "lukemattomiksi")"
        case .star: "Tähti lisätty \(n) ketjuun"
        case .unstar: "Tähti poistettu \(n) ketjusta"
        }
    }
}
