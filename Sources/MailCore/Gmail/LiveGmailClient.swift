import Foundation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "gmail")

public struct LiveGmailClient: GmailAPI {
    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    static let sendURL = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")!

    let auth: AccessTokenProvider
    let transport: HTTPTransport
    let retry: RetryPolicy

    public init(auth: AccessTokenProvider, transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = .standard) {
        self.auth = auth
        self.transport = transport
        self.retry = retry
    }

    public func profileEmail() async throws -> String {
        try await get(ProfileDTO.self, "profile").emailAddress
    }

    public func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await listThreads(query: query, pageToken: pageToken, maxResults: maxResults, retrying: true)
    }

    /// Fork (seisemail): the meeting-badge search backs off by itself after a 403/429; retrying
    /// here first would send 4 requests (40 units) into a quota that is already exhausted.
    public func listThreadsOnce(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await listThreads(query: query, pageToken: pageToken, maxResults: maxResults, retrying: false)
    }

    private func listThreads(query: String, pageToken: String?, maxResults: Int, retrying: Bool) async throws -> ThreadPage {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let dto = try await get(ThreadListDTO.self, "threads", items, retrying: retrying)
        return ThreadPage(ids: dto.threads?.map(\.id) ?? [], nextPageToken: dto.nextPageToken, estimate: dto.resultSizeEstimate ?? 0)
    }

    public func threadSummary(id: String, me: String?) async throws -> ThreadSummary {
        let items = [URLQueryItem(name: "format", value: "metadata")]
            + ["From", "Subject", "Date", "Content-Type"].map { URLQueryItem(name: "metadataHeaders", value: $0) }
        return MessageParser.summary(try await get(GmailThreadDTO.self, "threads/\(id)", items), me: me)
    }

    public func thread(id: String) async throws -> MailThread {
        MessageParser.thread(try await get(GmailThreadDTO.self, "threads/\(id)", [URLQueryItem(name: "format", value: "full")]))
    }

    public func modify(threadID: String, add: [String], remove: [String]) async throws {
        let body = try JSONEncoder().encode(["addLabelIds": add, "removeLabelIds": remove])
        _ = try await perform(request("threads/\(threadID)/modify", method: "POST", body: body, contentType: "application/json"))
    }

    /// Gmail's limit for one `messages.batchModify` call.
    public static let batchModifyLimit = 1_000

    public func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        var start = 0
        while start < messageIDs.count {
            let chunk = Array(messageIDs[start..<min(start + Self.batchModifyLimit, messageIDs.count)])
            let body = try JSONEncoder().encode(BatchModifyDTO(ids: chunk, addLabelIds: add, removeLabelIds: remove))
            _ = try await perform(request("messages/batchModify", method: "POST", body: body, contentType: "application/json"))
            start += chunk.count
        }
    }

    public func trash(threadID: String) async throws {
        _ = try await perform(request("threads/\(threadID)/trash", method: "POST"))
    }

    public func untrash(threadID: String) async throws {
        _ = try await perform(request("threads/\(threadID)/untrash", method: "POST"))
    }

    public func send(raw: Data, threadID: String?) async throws {
        let boundary = "mak8r-\(UUID().uuidString)"
        let metadata = threadID.map { "{\"threadId\":\"\($0)\"}" } ?? "{}"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadata)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = URLRequest(url: Self.sendURL)
        r.httpMethod = "POST"
        r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 300
        // Gmail may have accepted the message before a 5xx; retrying could send it twice.
        _ = try await perform(r, retryServerErrors: false)
    }

    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        let dto = try await get(AttachmentDTO.self, "messages/\(messageID)/attachments/\(attachmentID)")
        guard let data = dto.data.flatMap(Base64URL.decode) else { throw GmailError.decoding }
        return data
    }

    public func inboxUnreadCount() async throws -> Int {
        try await get(LabelDTO.self, "labels/INBOX").threadsUnread ?? 0
    }

    public func unreadEstimate(query: String) async throws -> Int {
        // resultSizeEstimate is rough (often 1–2 when nothing matches): count real ids when they fit on a page.
        let page = try await listThreads(query: "\(query) is:unread", pageToken: nil, maxResults: 100)
        return page.nextPageToken == nil ? page.ids.count : max(page.estimate, page.ids.count)
    }

    public func sendAsSignatures() async throws -> [SendAsSignature] {
        let dto = try await get(SendAsListDTO.self, "settings/sendAs")
        return (dto.sendAs ?? []).map { SendAsSignature(email: $0.sendAsEmail, html: $0.signature ?? "") }
    }

    // MARK: - Plumbing

    func request(_ path: String, _ items: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var c = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { c.queryItems = items }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, _ items: [URLQueryItem] = [], retrying: Bool = true) async throws -> T {
        let data = try await perform(request(path, items), retryServerErrors: retrying, retryRateLimit: retrying)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailError.decoding
        }
    }

    func perform(_ base: URLRequest, retryServerErrors: Bool = true, retryRateLimit: Bool = true) async throws -> Data {
        try await GmailRequestBudget.$current.withValue(GmailRequestBudget()) {
            try await performWithinBudget(base, retryServerErrors: retryServerErrors, retryRateLimit: retryRateLimit)
        }
    }

    private func performWithinBudget(_ base: URLRequest, retryServerErrors: Bool, retryRateLimit: Bool) async throws -> Data {
        var refreshed = false
        var attempt = 0
        var token = try await offlineMapped { try await auth.accessToken() }
        while true {
            var r = base
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(r)
            } catch let error as URLError where Self.offlineCodes.contains(error.code) {
                log.error("offline \(error.code.rawValue, privacy: .public) \(base.url?.path() ?? "", privacy: .public)")
                throw GmailError.offline
            }
            let status = response.statusCode
            if (200..<300).contains(status) { return data }
            log.error("HTTP \(status, privacy: .public) \(base.url?.path() ?? "", privacy: .public) attempt \(attempt, privacy: .public): \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            if status == 401, !refreshed {
                refreshed = true
                token = try await offlineMapped { try await auth.refreshAfterUnauthorized() }
                continue
            }
            // Behind GmailQuotaTransport (every account session) 429s and rate-limit 403s never get
            // here: the transport waits them out or throws GmailError.rateLimited. This branch is
            // for unwrapped clients (sign-in profile lookups).
            // A request whose quota deadline is spent is not resent: it would only fail in the queue.
            if (status == 429 && retryRateLimit) || (status >= 500 && retryServerErrors), attempt < retry.delays.count,
               GmailRequestBudget.current?.isSpent != true {
                try await retry.sleep(retry.delays[attempt])
                attempt += 1
                continue
            }
            throw GmailError.http(status, String(decoding: data.prefix(2000), as: UTF8.self))
        }
    }

    private func offlineMapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw GmailError.offline
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]
}
