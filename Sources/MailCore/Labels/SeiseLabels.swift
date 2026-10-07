import Foundation

/// Every label name the fork reads or writes (docs/conventions.md). Names are the contract; IDs are per account.
public enum SeiseLabels {
    // System IDs (ID == name) that upstream `GmailLabel` lacks. Not an extension of GmailLabel, so an upstream
    // `GmailLabel.spam` can never collide. Use GmailLabel.inbox/unread/trash directly.
    public static let spam = "SPAM"
    public static let sent = "SENT"
    public static let draft = "DRAFT"
    /// Hangouts/Chat messages; never classified (conventions §2).
    public static let chat = "CHAT"

    // Snooze (conventions §1). Names decided 2026-10-03 (Matti): the marker is also the display parent of the
    // hidden time labels; no separate parent label is created.
    public static let snoozeMarker = "Torkku"
    public static let snoozeTimePrefix = "Torkku/"

    // Sorting (conventions §2).
    public enum Sorting {
        public static let prefix = "Lajittelu/"
        public static let newsletters = "Lajittelu/Uutiskirjeet"
        public static let notifications = "Lajittelu/Ilmoitukset"
        public static let receipts = "Lajittelu/Kuitit"
        public static let people = "Lajittelu/Ihmiset"
        /// NFC in source; the TS port must `.normalize("NFC")` names before comparing.
        public static let needsAction = "Lajittelu/Vaatii toimenpidettä"
        public static let all: [String] = [newsletters, notifications, receipts, people, needsAction]
        /// The daemon's hidden "classified" marker (conventions §2). Deliberately not in `all`: it is no view,
        /// is never propagated as a sorting label and no client shows it.
        public static let classifiedMarker = "Lajittelu/Luokiteltu"
    }
}

public enum LabelListVisibility: String, Sendable, Codable {
    case labelShow, labelShowIfUnread, labelHide
}

public enum MessageListVisibility: String, Sendable, Codable {
    case show, hide
}

/// Both visibility fields sent on `labels.create`.
public struct LabelVisibility: Sendable, Equatable, Hashable {
    public var labelList: LabelListVisibility
    public var messageList: MessageListVisibility

    public init(labelList: LabelListVisibility, messageList: MessageListVisibility) {
        self.labelList = labelList
        self.messageList = messageList
    }

    public static let shown = LabelVisibility(labelList: .labelShow, messageList: .show)
    public static let hidden = LabelVisibility(labelList: .labelHide, messageList: .hide)
}
