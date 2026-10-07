import Foundation
import Synchronization

/// Shorthand for an instant given as Unix seconds (values are checked against Python zoneinfo).
func D(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

/// Settable clock for code that takes `now: @Sendable () -> Date`.
final class TestClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) {
        value = Mutex(date)
    }

    var now: Date { value.withLock { $0 } }

    func set(_ date: Date) { value.withLock { $0 = date } }

    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }

    var closure: @Sendable () -> Date { { self.now } }
}
