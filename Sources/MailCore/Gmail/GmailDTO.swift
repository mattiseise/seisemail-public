import Foundation

public struct GmailThreadDTO: Codable, Sendable {
    public var id: String
    public var historyId: String?
    public var snippet: String?
    public var messages: [GmailMessageDTO]?
}

public struct GmailMessageDTO: Codable, Sendable {
    public var id: String
    public var threadId: String
    public var labelIds: [String]?
    public var snippet: String?
    public var internalDate: String?
    public var payload: GmailPartDTO?
}

public struct GmailPartDTO: Codable, Sendable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeaderDTO]?
    public var body: GmailBodyDTO?
    public var parts: [GmailPartDTO]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GmailHeaderDTO: Codable, Sendable {
    public var name: String
    public var value: String
}

public struct GmailBodyDTO: Codable, Sendable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?
}

struct ThreadListDTO: Codable, Sendable {
    struct Ref: Codable, Sendable { var id: String }
    var threads: [Ref]?
    var nextPageToken: String?
    var resultSizeEstimate: Int?
}

struct BatchModifyDTO: Codable, Sendable {
    var ids: [String]
    var addLabelIds: [String]
    var removeLabelIds: [String]
}

struct LabelDTO: Codable, Sendable {
    var id: String
    var threadsTotal: Int?
    var threadsUnread: Int?
}

struct ProfileDTO: Codable, Sendable {
    var emailAddress: String
    var historyId: String?
}

/// `users.history.list` with `historyTypes=messageAdded`.
struct HistoryListDTO: Codable, Sendable {
    struct Record: Codable, Sendable {
        struct Added: Codable, Sendable {
            struct Ref: Codable, Sendable {
                var id: String
                var threadId: String
                var labelIds: [String]?
            }
            var message: Ref
        }
        var id: String
        var messagesAdded: [Added]?
    }
    var history: [Record]?
    var nextPageToken: String?
    var historyId: String
}

/// `users.messages.list`.
struct MessageListDTO: Codable, Sendable {
    struct Ref: Codable, Sendable {
        var id: String
        var threadId: String?
    }
    var messages: [Ref]?
    var nextPageToken: String?
    var resultSizeEstimate: Int?
}

/// `users.messages.insert` body (JSON form, `raw` base64url) and the part of its answer we use.
struct InsertDTO: Codable, Sendable {
    var raw: String
    var labelIds: [String]
}

struct InsertedMessageDTO: Codable, Sendable {
    var id: String
    var threadId: String?
}

struct AttachmentDTO: Codable, Sendable {
    var data: String?
    var size: Int?
}

struct SendAsListDTO: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var sendAsEmail: String
        var signature: String?
    }
    var sendAs: [Entry]?
}
