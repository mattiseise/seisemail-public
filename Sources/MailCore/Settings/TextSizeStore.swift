import Foundation
import Observation

/// Fork (seisemail): the current text size. Views read `size` (observed); menu commands and
/// Settings change it.
///
/// Per device, in UserDefaults like the window layout (`peekFraction`, `sidebarVisible`), and kept
/// out of `AppSettings` so a size change does not invalidate everything that observes settings.
@MainActor @Observable
public final class TextSizeStore {
    public static let key = "textSizePercent"

    @ObservationIgnored private let defaults: UserDefaults

    public private(set) var size: TextSize

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = Self.load(from: defaults)
    }

    public var canIncrease: Bool { size.larger != nil }
    public var canDecrease: Bool { size.smaller != nil }

    public func increase() { size.larger.map(set) }
    public func decrease() { size.smaller.map(set) }
    public func reset() { set(.standard) }

    /// Writes and notifies only on a real change, so no-op sets do not redraw every view.
    public func set(_ new: TextSize) {
        guard new != size else { return }
        size = new
        if new.isStandard {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(new.percent, forKey: Self.key)
        }
    }

    /// Any number snaps to a step; anything else (a string, a broken plist edit) is the default.
    private static func load(from defaults: UserDefaults) -> TextSize {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return .standard }
        let value = number.doubleValue
        guard value.isFinite else { return .standard }
        return TextSize(percent: Int(max(-1000, min(1000, value)).rounded()))
    }
}
