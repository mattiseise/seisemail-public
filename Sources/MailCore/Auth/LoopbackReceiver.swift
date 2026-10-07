import Foundation
import Network
import Synchronization

/// Minimal HTTP listener on 127.0.0.1 that captures the OAuth redirect.
public final class LoopbackReceiver: Sendable {
    private struct State {
        var listener: NWListener?
        var result: Result<[String: String], Error>?
        var waiter: CheckedContinuation<[String: String], Error>?
        var stopped = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "fi.mak8r.mail.loopback")

    public init() {}

    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        // Resumes exactly once: on .ready (the port), or with an error on .failed, .waiting (no
        // network path yet; the daemon's login falls back to paste-only) and .cancelled (`stop()`
        // before ready). Without the last two a stopped receiver left `start()` hanging.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Mutex(false)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in
                guard resumed.withLock({ done -> Bool in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready: finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): finish(.failure(error))
                case .cancelled: finish(.failure(CancellationError()))
                default: break
                }
            }
            // Registered and started under the lock, so a concurrent `stop()` either comes first (and
            // this throws) or finds the started listener and cancels it (.cancelled above).
            let stopped = state.withLock { s -> Bool in
                if s.stopped { return true }
                s.listener = listener
                listener.start(queue: queue)
                return false
            }
            if stopped {
                listener.cancel()
                finish(.failure(CancellationError()))
            }
        }
    }

    public func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[String: String], Error>? = state.withLock { s in
                if let r = s.result { return r }
                if s.stopped { return .failure(CancellationError()) }
                s.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    public func stop() {
        let (listener, waiter) = state.withLock { s -> (NWListener?, CheckedContinuation<[String: String], Error>?) in
            defer { s.listener = nil; s.waiter = nil; s.stopped = true }
            return (s.listener, s.waiter)
        }
        listener?.cancel()
        waiter?.resume(throwing: CancellationError())
    }

    public static func parseRequestLine(_ line: String) -> [String: String]? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              let items = components.queryItems else { return nil }
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard params["code"] != nil || params["error"] != nil else { return nil }
        return params
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let params = Self.parseRequestLine(firstLine)
            let body = params == nil
                ? "Not found"
                : "<!doctype html><meta charset=utf-8><title>Mak8r Mail</title><body style=\"font:15px -apple-system;padding:40px\"><h2>Mak8r Mail</h2><p>Kirjautuminen valmis. Voit sulkea tämän välilehden.</p>"
            let status = params == nil ? "404 Not Found" : "200 OK"
            let bodyData = Data(body.utf8)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
            if let params { self?.deliver(params) }
        }
    }

    private func deliver(_ params: [String: String]) {
        let waiter = state.withLock { s -> CheckedContinuation<[String: String], Error>? in
            guard s.result == nil else { return nil }
            s.result = .success(params)
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: params)
    }
}
