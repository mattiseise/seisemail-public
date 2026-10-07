import Foundation

public enum RemoteImagesPolicy: String, Codable, Sendable, CaseIterable { case block, allowFromSenders, always }
public enum MarkReadPolicy: String, Codable, Sendable, CaseIterable { case immediately, afterDelay, never }
public enum AfterArchive: String, Codable, Sendable, CaseIterable { case next, previous, list }
public enum SignatureUse: Sendable { case new, reply }

public struct Signature: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// App-wide settings (`settings.json`). Decoding is per-field lenient: a missing or invalid
/// field keeps its default, so older and newer files both load.
public struct AppSettings: Codable, Equatable, Sendable {
    public var undoSendSeconds = 10
    public var warnMissingAttachment = true
    public var remoteImages = RemoteImagesPolicy.block
    public var markRead = MarkReadPolicy.immediately
    public var afterArchive = AfterArchive.next
    public var openFirstThread = false
    public var notificationSound = true
    /// macOS system sound (in /System/Library/Sounds) played for new mail.
    public var notificationSoundName = "Glass"
    public var dockBadge = true
    public var menuBarIcon = true
    /// Inbox 0 shows Wikimedia Commons' picture of the day (one request a day); off = only the bundled photos.
    public var inboxZeroDailyPhoto = true
    public var shortcuts = ShortcutMap.defaults

    public static let undoSendChoices = [0, 5, 10, 20]
    public static let notificationSoundChoices = ["Glass", "Ping", "Pop", "Tink", "Purr", "Blow", "Bottle", "Hero", "Morse", "Submarine", "Funk", "Frog", "Basso", "Sosumi"]

    public init() {}

    public static var defaultURL: URL { AppPaths.supportDirectory.appendingPathComponent("settings.json") }

    private enum CodingKeys: String, CodingKey {
        case undoSendSeconds, warnMissingAttachment, remoteImages, markRead, afterArchive
        case openFirstThread, notificationSound, notificationSoundName, dockBadge, menuBarIcon, inboxZeroDailyPhoto, shortcuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        undoSendSeconds = c.lenient(.undoSendSeconds) ?? d.undoSendSeconds
        warnMissingAttachment = c.lenient(.warnMissingAttachment) ?? d.warnMissingAttachment
        remoteImages = c.lenient(.remoteImages) ?? d.remoteImages
        markRead = c.lenient(.markRead) ?? d.markRead
        afterArchive = c.lenient(.afterArchive) ?? d.afterArchive
        openFirstThread = c.lenient(.openFirstThread) ?? d.openFirstThread
        notificationSound = c.lenient(.notificationSound) ?? d.notificationSound
        notificationSoundName = c.lenient(.notificationSoundName) ?? d.notificationSoundName
        dockBadge = c.lenient(.dockBadge) ?? d.dockBadge
        menuBarIcon = c.lenient(.menuBarIcon) ?? d.menuBarIcon
        inboxZeroDailyPhoto = c.lenient(.inboxZeroDailyPhoto) ?? d.inboxZeroDailyPhoto
        shortcuts = c.lenient(.shortcuts) ?? d.shortcuts
    }
}

/// Per-account settings (`settings-<email>.json`).
public struct AccountSettings: Codable, Equatable, Sendable {
    public var signatures: [Signature] = []
    public var defaultForNew: Signature.ID?
    public var defaultForReplies: Signature.ID?
    public var notificationsEnabled = true
    public var trustedImageSenders: [String] = []

    public init() {}

    public static func url(for email: String) -> URL {
        AppPaths.supportDirectory.appendingPathComponent("settings-\(email.lowercased()).json")
    }

    /// The default signature for new messages or replies; nil if unset or deleted.
    public func signature(for use: SignatureUse) -> Signature? {
        let id = use == .new ? defaultForNew : defaultForReplies
        return signatures.first { $0.id == id }
    }

    public func trustsImages(from email: String) -> Bool {
        trustedImageSenders.contains { $0.caseInsensitiveCompare(email) == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey {
        case signatures, defaultForNew, defaultForReplies, notificationsEnabled, trustedImageSenders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AccountSettings()
        signatures = c.lenient(.signatures) ?? d.signatures
        defaultForNew = c.lenient(.defaultForNew)
        defaultForReplies = c.lenient(.defaultForReplies)
        notificationsEnabled = c.lenient(.notificationsEnabled) ?? d.notificationsEnabled
        trustedImageSenders = c.lenient(.trustedImageSenders) ?? d.trustedImageSenders
    }
}

extension KeyedDecodingContainer {
    /// The value if present and valid; nil otherwise, never throws.
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
