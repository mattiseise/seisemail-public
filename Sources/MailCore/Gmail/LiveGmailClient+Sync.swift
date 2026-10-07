import Foundation

// Fork (seisemail): the daemon's endpoints. They go through `get`/`perform`, so they inherit the
// 401 refresh, the 429/5xx retries and the offline mapping.
extension LiveGmailClient: GmailSyncAPI {
    public func profile() async throws -> GmailProfile {
        let dto = try await get(ProfileDTO.self, "profile")
        guard let historyID = dto.historyId else { throw GmailError.decoding }
        return GmailProfile(email: dto.emailAddress, historyID: historyID)
    }

    public func history(startHistoryID: String, pageToken: String?, maxResults: Int) async throws -> HistoryPage {
        var items = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "maxResults", value: String(min(max(maxResults, 1), 500))),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let dto: HistoryListDTO
        do {
            dto = try await get(HistoryListDTO.self, "history", items)
        } catch let error where GmailFailure.isNotFound(error) {
            throw GmailSyncError.historyExpired
        }
        let records = dto.history ?? []
        let added = records.flatMap { record in
            (record.messagesAdded ?? []).map {
                AddedMessage(id: $0.message.id, threadID: $0.message.threadId, labelIDs: $0.message.labelIds.map(Set.init))
            }
        }
        return HistoryPage(added: added, lastRecordID: records.last?.id, historyID: dto.historyId,
                           nextPageToken: dto.nextPageToken)
    }

    public func threadHeaders(id: String, headers: [String]) async throws -> ThreadHeaders {
        var r = request("threads/\(id)", Self.metadataItems(headers))
        // Decides a write: never from the read cache (conventions §0, docs/gmail-quota.md §5).
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await perform(r)
        let dto: GmailThreadDTO
        do {
            dto = try JSONDecoder().decode(GmailThreadDTO.self, from: data)
        } catch {
            throw GmailError.decoding
        }
        return ThreadHeaders(threadID: dto.id, historyID: dto.historyId, messages: (dto.messages ?? []).map(Self.headerMessage))
    }

    public func listMessageIDs(query: String, pageToken: String?, maxResults: Int) async throws -> MessageIDPage {
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "maxResults", value: String(min(max(maxResults, 1), 500)))]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let dto = try await get(MessageListDTO.self, "messages", items)
        return MessageIDPage(ids: dto.messages?.map(\.id) ?? [], nextPageToken: dto.nextPageToken)
    }

    public func messageHeaders(id: String, headers: [String]) async throws -> HeaderMessage {
        Self.headerMessage(try await get(GmailMessageDTO.self, "messages/\(id)", Self.metadataItems(headers)))
    }

    public func insertMessage(raw: Data, labelIDs: [String]) async throws -> String {
        let body = try JSONEncoder().encode(InsertDTO(raw: Base64URL.encode(raw), labelIds: labelIDs))
        // Like send: Gmail may have stored the message before a 5xx; a retry could insert it twice.
        let data = try await perform(request("messages", method: "POST", body: body, contentType: "application/json"),
                                     retryServerErrors: false)
        do {
            let inserted = try JSONDecoder().decode(InsertedMessageDTO.self, from: data)
            return inserted.threadId ?? inserted.id
        } catch {
            throw GmailError.decoding
        }
    }

    static func metadataItems(_ headers: [String]) -> [URLQueryItem] {
        [URLQueryItem(name: "format", value: "metadata")] + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
    }

    static func headerMessage(_ dto: GmailMessageDTO) -> HeaderMessage {
        var headers: [String: [String]] = [:]
        for h in dto.payload?.headers ?? [] {
            headers[h.name.lowercased(), default: []].append(h.value)
        }
        let date = dto.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return HeaderMessage(id: dto.id, labelIDs: Set(dto.labelIds ?? []), internalDate: date, headers: headers)
    }
}
