import Foundation

// Label endpoint DTOs. New names, so upstream's `LabelDTO` stays untouched.

struct LabelResourceDTO: Codable, Sendable {
    var id: String
    var name: String
    var type: String?

    var model: GmailLabelInfo { GmailLabelInfo(id: id, name: name, kind: type == "system" ? .system : .user) }
}

struct LabelListDTO: Codable, Sendable {
    var labels: [LabelResourceDTO]?
}

struct CreateLabelBodyDTO: Encodable, Sendable {
    var name: String
    var labelListVisibility: String
    var messageListVisibility: String

    init(name: String, visibility: LabelVisibility) {
        self.name = name
        self.labelListVisibility = visibility.labelList.rawValue
        self.messageListVisibility = visibility.messageList.rawValue
    }
}

/// `threads.get?format=minimal`: IDs and labels only.
struct ThreadMinimalDTO: Codable, Sendable {
    struct Message: Codable, Sendable {
        var id: String
        var labelIds: [String]?
    }
    var id: String
    var historyId: String?
    var messages: [Message]?
}
