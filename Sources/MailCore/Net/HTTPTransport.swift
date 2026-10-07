import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum FormEncoding {
    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

public struct RetryPolicy: Sendable {
    public var delays: [Duration]
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(delays: [Duration], sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.delays = delays
        self.sleep = sleep
    }

    /// 0.5 s, 1 s, 2 s plus up to 250 ms jitter.
    public static let standard = RetryPolicy(
        delays: [.milliseconds(500), .seconds(1), .seconds(2)],
        sleep: { try await Task.sleep(for: $0 + .milliseconds(Int.random(in: 0...250))) }
    )
}
