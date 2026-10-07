import Foundation
import MailCore
import Synchronization

/// The bottom layer of the daemon's transport stack (`… → quota → probe → URLSession`). It sees every
/// send, retries included, and records:
/// - the clock skew against Gmail's `Date` response header (D15: cleanup only with |skew| ≤ 120 s);
/// - the priced units sent in the last minute (status and the per-tick log line).
public final class ProbeTransport: HTTPTransport, Sendable {
    private struct State {
        var skew: (seconds: Double, measuredAt: Date)?
        var sends: [(at: Date, units: Int)] = []
        var totalUnits = 0
    }

    private let base: any HTTPTransport
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    public init(base: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date) {
        self.base = base
        self.now = now
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let units = GmailQuotaPrice.units(for: request)
        if let units {
            let at = now()
            state.withLock { s in
                s.sends.removeAll { at.timeIntervalSince($0.at) >= 60 }
                s.sends.append((at, units))
                s.totalUnits += units
            }
        }
        let (data, response) = try await base.send(request)
        if let header = response.value(forHTTPHeaderField: "Date"), let serverDate = Self.parseHTTPDate(header) {
            let at = now()
            state.withLock { $0.skew = (at.timeIntervalSince(serverDate), at) }
        }
        return (data, response)
    }

    /// Local clock minus Gmail's, from the latest response. The header has whole seconds, so ±1 s is noise.
    public var skew: (seconds: Double, measuredAt: Date)? {
        state.withLock { $0.skew }
    }

    public var unitsLastMinute: Int {
        let at = now()
        return state.withLock { s in s.sends.filter { at.timeIntervalSince($0.at) < 60 }.reduce(0) { $0 + $1.units } }
    }

    /// Every unit sent since creation (per-tick deltas for the log).
    public var totalUnits: Int {
        state.withLock { $0.totalUnits }
    }

    /// Whether cleanup may run (D15): a measurement within `maxAge` with |skew| ≤ `limit`.
    public func skewAllowsCleanup(now: Date, limit: Double = 120, maxAge: TimeInterval = 600) -> Bool {
        guard let skew else { return false }
        return now.timeIntervalSince(skew.measuredAt) <= maxAge && abs(skew.seconds) <= limit
    }

    /// RFC 7231 IMF-fixdate, e.g. `Tue, 06 Oct 2026 06:14:02 GMT`.
    public static func parseHTTPDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 6, parts[5] == "GMT",
              let day = Int(parts[1]), let year = Int(parts[3]),
              let month = months.firstIndex(of: String(parts[2])).map({ $0 + 1 }) else { return nil }
        let hms = parts[4].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hms[0], minute: hms[1], second: hms[2]))
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
