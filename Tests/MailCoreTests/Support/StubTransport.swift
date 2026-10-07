import Foundation
import Synchronization
@testable import MailCore

/// Scriptable HTTP transport. The handler receives each request and returns (status, body).
final class StubTransport: HTTPTransport, Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private let handler: Handler
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let (status, data) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var out: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
