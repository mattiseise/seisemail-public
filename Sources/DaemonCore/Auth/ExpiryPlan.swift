import Foundation
import MailCore

/// Expiry warnings and needsLogin reminders (design §8.3). Pure.
public enum ExpiryPlan {
    /// `refreshTokenExpiresAt ?? consentedAt + 7 d − 10 min`.
    public static func expiresAt(_ token: StoredToken) -> Date { token.expiresAt }

    /// Hours of `warnHours` that are due (`now ≥ expiresAt − h`) and not yet in `warned`, largest first.
    public static func dueWarnings(now: Date, expiresAt: Date, warnHours: [Int], warned: [Int]) -> [Int] {
        Array(Set(warnHours)).sorted(by: >).filter { h in
            !warned.contains(h) && now >= expiresAt.addingTimeInterval(-Double(h) * 3_600)
        }
    }

    /// Whether the daily reminder (at `hour`:00 Helsinki) is due: the latest such boundary is after the
    /// last notice. The first notice comes at once when needsLogin starts, so `lastNotifiedAt` is set.
    public static func reminderDue(now: Date, lastNotifiedAt: Date?, hour: Int, timeZone: TimeZone = SnoozePresets.helsinki) -> Bool {
        guard let lastNotifiedAt else { return true }
        let boundary = DaemonSchedule.lastDailyBoundary(before: now, hour: hour, timeZone: timeZone)
        return lastNotifiedAt < boundary && boundary <= now
    }
}
