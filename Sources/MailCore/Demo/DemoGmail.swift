import Foundation
import Synchronization

/// Fork (seisemail): an in-memory Gmail with made-up Finnish mail, for `make screenshots` (README images).
/// Every person, address and message here is invented; no network, no account.
public final class DemoGmail: GmailLabelsAPI, Sendable {
    public static let email = "demo@esimerkki.fi"

    private struct State {
        var threads: [String: MailThread] = [:]
        var labels: [GmailLabelInfo] = []
        var nextLabel = 1
    }

    private let state = Mutex(State())
    /// How long a write takes, so the bulk status line ("Arkistoidaan 7 ketjua…") can be photographed.
    private let writeDelay: Duration

    public init(now: Date = Date(), writeDelay: Duration = .seconds(3)) {
        self.writeDelay = writeDelay
        state.withLock { Self.seed(&$0, now: now) }
    }

    // MARK: Data

    private struct Seed {
        var id: String
        var name: String
        var address: String
        var subject: String
        var minutesAgo: Int
        var labels: [String] = [GmailLabel.inbox]
        var unread = false
        var starred = false
        var replies = 0
        var attachment: String?
        var text: String
    }

    private static func seed(_ s: inout State, now: Date) {
        let system = ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "SENT", "DRAFT", "SPAM", "TRASH", "CHAT"]
        s.labels = system.map { GmailLabelInfo(id: $0, name: $0, kind: .system) }
        func label(_ name: String) -> String {
            if let existing = s.labels.first(where: { $0.name == name }) { return existing.id }
            let info = GmailLabelInfo(id: "Label_\(s.nextLabel)", name: name, kind: .user)
            s.nextLabel += 1
            s.labels.append(info)
            return info.id
        }
        func wake(_ date: Date?) -> [String] {
            let date = date ?? SnoozePresets.date(for: .tomorrow, now: now.addingTimeInterval(86_400))!   // ylihuomenna 8.00
            return [label(SeiseLabels.snoozeMarker), label(SeiseLabels.snoozeTimePrefix + SnoozeTime.encode(date))]
        }
        let tonight = SnoozePresets.date(for: .tonight, now: now)
            ?? SnoozePresets.date(for: .tomorrow, now: now.addingTimeInterval(86_400))
        let seeds: [Seed] = [
            Seed(id: "d01", name: "Aino Virtanen", address: "aino.virtanen@esimerkki.fi",
                 subject: "Tiimipalaveri torstaina klo 10", minutesAgo: 9, unread: true,
                 text: "Hei! Käydään läpi syksyn aikataulut ja jaetaan vastuut. Liity kokoukseen nyt -linkki alla."
                     + "\n\nLiity kokoukseen nyt\nhttps://teams.microsoft.com/l/meetup-join/esimerkki"),
            Seed(id: "d02", name: "Mikko Laine", address: "mikko.laine@esimerkki.fi",
                 subject: "Re: Kurssin materiaalit syksylle", minutesAgo: 34, unread: true, replies: 2,
                 attachment: "materiaalit-syksy.pdf", text: "Liitteenä päivitetyt materiaalit. Katsotko diat 4–7?"),
            Seed(id: "d03", name: "Opintotoimisto", address: "opintotoimisto@esimerkki.fi",
                 subject: "Arviointien määräaika 16.10.", minutesAgo: 62, labels: [GmailLabel.inbox, "IMPORTANT"],
                 unread: true, text: "Muistathan kirjata syksyn ensimmäisen jakson arvioinnit perjantaihin mennessä."),
            Seed(id: "d04", name: "Sari Nieminen", address: "sari.nieminen@esimerkki.fi",
                 subject: "Projektiryhmän tapaaminen", minutesAgo: 140,
                 text: "Nähdään Zoomissa: https://zoom.us/j/1234567890"),
            Seed(id: "d05", name: "Laura Koskinen", address: "laura.koskinen@esimerkki.fi",
                 subject: "Kehityskeskustelu ensi viikolla", minutesAgo: 205, starred: true,
                 text: "Sopiiko tiistai? Linkki: https://meet.google.com/abc-defg-hij"),
            Seed(id: "d06", name: "Kirjasto", address: "kirjasto@esimerkki.fi",
                 subject: "Lainasi erääntyy perjantaina", minutesAgo: 60 * 20,
                 text: "Lainaamasi teos ”Pedagogiikan perusteet” erääntyy perjantaina."),
            Seed(id: "d07", name: "Jussi Heikkinen", address: "jussi.heikkinen@esimerkki.fi",
                 subject: "Kiitos eilisestä!", minutesAgo: 60 * 26, replies: 1,
                 text: "Hyvä työpaja, kiitos vetämisestä. Laitan muistiinpanot jakoon."),
            Seed(id: "d08", name: "Verkkokauppa", address: "noreply@kauppa.esimerkki.fi",
                 subject: "Tilausvahvistus 10482", minutesAgo: 95,
                 labels: [GmailLabel.inbox, label(SeiseLabels.Sorting.notifications)],
                 text: "Kiitos tilauksestasi. Toimitusarvio 2–3 arkipäivää."),
            Seed(id: "d09", name: "Opettajan uutiskirje", address: "uutiskirje@esimerkki.fi",
                 subject: "Lokakuun vinkit tekoälyn käyttöön", minutesAgo: 300,
                 labels: [GmailLabel.inbox, label(SeiseLabels.Sorting.newsletters)], unread: true,
                 text: "Tässä kuussa: viisi tapaa säästää aikaa arvioinnissa."),
            Seed(id: "d10", name: "Antti Järvinen", address: "antti.jarvinen@esimerkki.fi",
                 subject: "Hankehakemuksen luonnos", minutesAgo: 60 * 30, labels: wake(nil),
                 text: "Ehditkö kommentoida luonnosta ennen torstaita?"),
            Seed(id: "d11", name: "Kuntosali", address: "info@sali.esimerkki.fi",
                 subject: "Syksyn ryhmäliikuntakalenteri", minutesAgo: 60 * 50, labels: wake(tonight),
                 text: "Uudet tunnit alkavat maanantaina."),
            Seed(id: "d12", name: "Taloyhtiö", address: "isannointi@esimerkki.fi",
                 subject: "Saunavuorot uusitaan", minutesAgo: 60 * 52,
                 labels: wake(SnoozePresets.date(for: .nextWeek, now: now)),
                 text: "Ilmoitathan toiveesi uusista saunavuoroista."),
            Seed(id: "d13", name: "Tiina Mäkinen", address: "tiina.makinen@esimerkki.fi",
                 subject: "Pikkujoulujen suunnittelu", minutesAgo: 60 * 75,
                 labels: wake(SnoozePresets.date(for: .nextMonth, now: now)),
                 text: "Aloitetaan suunnittelu marraskuussa."),
        ]
        let me = MailAddress(name: nil, email: email)
        for seed in seeds {
            var labels = Set(seed.labels)
            if seed.starred { labels.insert(GmailLabel.starred) }
            let from = MailAddress(name: seed.name, email: seed.address)
            let messages = (0...seed.replies).map { n -> Message in
                let last = n == seed.replies
                var ids = labels
                if last, seed.unread { ids.insert(GmailLabel.unread) }
                let date = now.addingTimeInterval(-Double(seed.minutesAgo * 60 + (seed.replies - n) * 3_600))
                return Message(
                    id: "\(seed.id)-\(n)", threadID: seed.id, from: n % 2 == seed.replies % 2 ? from : me,
                    replyTo: [], to: [n % 2 == seed.replies % 2 ? me : from], cc: [], date: date,
                    subject: n == 0 ? seed.subject.replacingOccurrences(of: "Re: ", with: "") : seed.subject,
                    snippet: String(seed.text.prefix(90)), textBody: seed.text, htmlBody: nil,
                    attachments: last ? seed.attachment.map {
                        [Attachment(messageID: "\(seed.id)-\(n)", partID: "1", attachmentID: "a1", filename: $0,
                                    mimeType: "application/pdf", size: 240_000)]
                    } ?? [] : [],
                    labelIDs: ids, messageIDHeader: "<\(seed.id)-\(n)@esimerkki.fi>", references: nil)
            }
            s.threads[seed.id] = MailThread(id: seed.id, messages: messages)
        }
    }

    // MARK: Search

    /// Enough of Gmail's search for the app's own queries: in:, label:, is:, has:, the meeting-link
    /// terms, and a parenthesised scope. Anything else matches nothing.
    private func matching(_ query: String) -> [String] {
        state.withLock { s in
            let namesByID = Dictionary(s.labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            var scope = query
            var meeting: String?
            if query.hasPrefix("("), let close = query.firstIndex(of: ")") {
                scope = String(query[query.index(after: query.startIndex)..<close])
                meeting = String(query[query.index(after: close)...]).lowercased()
            }
            let tokens = scope.split(whereSeparator: \.isWhitespace).map(String.init)
            return s.threads.values.filter { thread in
                let ids = thread.labelIDs
                let tokensOfLabels = Set(ids.compactMap { namesByID[$0] }.map(SearchSyntax.labelToken))
                let text = thread.messages.compactMap(\.textBody).joined(separator: "\n").lowercased()
                for raw in tokens {
                    let negated = raw.hasPrefix("-")
                    let token = (negated ? String(raw.dropFirst()) : raw).lowercased()
                    let hit: Bool
                    switch token {
                    case "in:inbox": hit = ids.contains("INBOX")
                    case "in:sent": hit = ids.contains("SENT")
                    case "in:drafts": hit = ids.contains("DRAFT")
                    case "in:spam": hit = ids.contains("SPAM")
                    case "in:trash": hit = ids.contains("TRASH")
                    case "in:anywhere": hit = true
                    case "is:unread": hit = ids.contains(GmailLabel.unread)
                    case "is:starred": hit = ids.contains(GmailLabel.starred)
                    case "is:important": hit = ids.contains("IMPORTANT")
                    case "has:attachment": hit = thread.messages.contains { !$0.attachments.isEmpty }
                    default:
                        hit = token.hasPrefix("label:") && tokensOfLabels.contains(String(token.dropFirst(6)))
                    }
                    if hit == negated { return false }
                }
                if !query.lowercased().contains("in:trash"), ids.contains("TRASH") { return false }
                if let meeting {
                    if meeting.contains("liity kokoukseen nyt") || meeting.contains("join the meeting now") {
                        return text.contains("liity kokoukseen nyt") || text.contains("join the meeting now")
                    }
                    if meeting.contains("zoom.us/j") { return text.contains("zoom.us/j") }
                    if meeting.contains("meet.google.com") { return text.contains("meet.google.com") }
                }
                return true
            }
            .sorted { ($0.messages.last?.date ?? .distantPast) > ($1.messages.last?.date ?? .distantPast) }
            .map(\.id)
        }
    }

    // MARK: GmailAPI

    public func profileEmail() async throws -> String { Self.email }

    public func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        let ids = matching(query)
        return ThreadPage(ids: Array(ids.prefix(maxResults)), nextPageToken: nil, estimate: ids.count)
    }

    public func listThreadsOnce(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await listThreads(query: query, pageToken: pageToken, maxResults: maxResults)
    }

    public func threadSummary(id: String, me: String?) async throws -> ThreadSummary {
        guard let t = state.withLock({ $0.threads[id] }), let last = t.messages.last else { throw GmailError.http(404, id) }
        return ThreadSummary(id: id, subject: t.subject, sender: last.from?.displayName ?? "", snippet: last.snippet,
                             date: last.date, labelIDs: t.labelIDs,
                             hasAttachments: t.messages.contains { !$0.attachments.isEmpty },
                             messageCount: t.messages.count, messageIDs: t.messages.map(\.id))
    }

    public func thread(id: String) async throws -> MailThread {
        guard let t = state.withLock({ $0.threads[id] }) else { throw GmailError.http(404, id) }
        return t
    }

    public func modify(threadID: String, add: [String], remove: [String]) async throws {
        try await Task.sleep(for: writeDelay / 6)
        state.withLock { s in
            guard var t = s.threads[threadID] else { return }
            for i in t.messages.indices {
                t.messages[i].labelIDs.formUnion(add)
                t.messages[i].labelIDs.subtract(remove)
            }
            s.threads[threadID] = t
        }
    }

    public func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        try await Task.sleep(for: writeDelay)
        let ids = Set(messageIDs)
        state.withLock { s in
            for (key, var t) in s.threads {
                for i in t.messages.indices where ids.contains(t.messages[i].id) {
                    t.messages[i].labelIDs.formUnion(add)
                    t.messages[i].labelIDs.subtract(remove)
                }
                s.threads[key] = t
            }
        }
    }

    public func trash(threadID: String) async throws {
        try await modify(threadID: threadID, add: ["TRASH"], remove: [GmailLabel.inbox])
    }

    public func untrash(threadID: String) async throws {
        try await modify(threadID: threadID, add: [], remove: ["TRASH"])
    }

    public func send(raw: Data, threadID: String?) async throws {}

    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data { Data() }

    public func inboxUnreadCount() async throws -> Int { try await unreadEstimate(query: "in:inbox") }

    public func unreadEstimate(query: String) async throws -> Int {
        let ids = matching(query)
        return state.withLock { s in ids.filter { s.threads[$0]?.labelIDs.contains(GmailLabel.unread) == true }.count }
    }

    public func sendAsSignatures() async throws -> [SendAsSignature] { [] }

    // MARK: GmailLabelsAPI

    public func listLabels() async throws -> [GmailLabelInfo] { state.withLock { $0.labels } }

    public func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        try state.withLock { s in
            if s.labels.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                throw GmailError.http(409, "Label name exists or conflicts")
            }
            let info = GmailLabelInfo(id: "Label_\(s.nextLabel)", name: name, kind: .user)
            s.nextLabel += 1
            s.labels.append(info)
            return info
        }
    }

    public func deleteLabel(id: String) async throws {
        state.withLock { s in
            s.labels.removeAll { $0.id == id }
            for (key, var t) in s.threads {
                for i in t.messages.indices { t.messages[i].labelIDs.remove(id) }
                s.threads[key] = t
            }
        }
    }

    public func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        let wanted = Set(labelIDs)
        let ids = state.withLock { s in
            s.threads.values.filter { t in
                t.labelIDs.isSuperset(of: wanted) && (includeSpamTrash || !t.labelIDs.contains("TRASH"))
            }.map(\.id).sorted()
        }
        return ThreadPage(ids: Array(ids.prefix(maxResults)), nextPageToken: nil, estimate: ids.count)
    }

    public func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels {
        guard let t = state.withLock({ $0.threads[id] }) else { throw GmailError.http(404, id) }
        return ThreadLabels(threadID: id, messageLabelIDs: t.messages.map(\.labelIDs), historyID: nil)
    }

    public func labelCounts(id: String) async throws -> LabelCounts {
        state.withLock { s in
            let carrying = s.threads.values.filter { $0.labelIDs.contains(id) }
            return LabelCounts(threadsTotal: carrying.count,
                               threadsUnread: carrying.filter { $0.labelIDs.contains(GmailLabel.unread) }.count)
        }
    }
}
