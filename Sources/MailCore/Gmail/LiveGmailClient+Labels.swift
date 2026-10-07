import Foundation

// Fork (seisemail): label endpoints. They go through `perform`, so they inherit the 401 refresh,
// the 429/5xx retries and the offline mapping. A retried 5xx can surface as 409 on create or 404 on
// delete; LabelDirectory handles both.
extension LiveGmailClient: GmailLabelsAPI {
    public func listLabels() async throws -> [GmailLabelInfo] {
        try await get(LabelListDTO.self, "labels").labels?.map(\.model) ?? []
    }

    public func createLabel(name: String, visibility: LabelVisibility) async throws -> GmailLabelInfo {
        // JSONEncoder writes "/" as "\/", which is valid JSON.
        let body = try JSONEncoder().encode(CreateLabelBodyDTO(name: name, visibility: visibility))
        let data = try await perform(request("labels", method: "POST", body: body, contentType: "application/json"))
        do {
            return try JSONDecoder().decode(LabelResourceDTO.self, from: data).model
        } catch {
            throw GmailError.decoding
        }
    }

    public func deleteLabel(id: String) async throws {
        // 204 with an empty body or 200 with "{}": both fine.
        _ = try await perform(request("labels/\(id)", method: "DELETE"))
    }

    public func listThreadIDs(labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        var items = labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        items.append(URLQueryItem(name: "maxResults", value: String(min(max(maxResults, 1), 500))))
        if includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let dto = try await get(ThreadListDTO.self, "threads", items)
        return ThreadPage(ids: dto.threads?.map(\.id) ?? [], nextPageToken: dto.nextPageToken, estimate: dto.resultSizeEstimate ?? 0)
    }

    public func labelCounts(id: String) async throws -> LabelCounts {
        let dto = try await get(LabelDTO.self, "labels/\(id)")
        return LabelCounts(threadsTotal: dto.threadsTotal ?? 0, threadsUnread: dto.threadsUnread ?? 0)
    }

    public func threadLabels(id: String, fresh: Bool) async throws -> ThreadLabels {
        var r = request("threads/\(id)", [URLQueryItem(name: "format", value: "minimal")])
        // GmailReadCacheTransport bypasses its cache for this policy; GmailEndpoint makes it interactive.
        if fresh { r.cachePolicy = .reloadIgnoringLocalCacheData }
        let data = try await perform(r)
        let dto: ThreadMinimalDTO
        do {
            dto = try JSONDecoder().decode(ThreadMinimalDTO.self, from: data)
        } catch {
            throw GmailError.decoding
        }
        return ThreadLabels(threadID: dto.id, messageLabelIDs: (dto.messages ?? []).map { Set($0.labelIds ?? []) }, historyID: dto.historyId)
    }
}
