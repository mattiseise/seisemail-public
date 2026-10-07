import Foundation

/// Fork (seisemail): user-chosen text size as a percentage of the design size.
/// Stored as a plain integer; any value decodes, snapped to the nearest step.
public struct TextSize: Hashable, Comparable, Sendable, Codable {
    /// Same ladder as Safari's zoom, from slightly smaller to double.
    public static let steps = [85, 100, 115, 125, 150, 175, 200]
    public static let standard = TextSize(percent: 100)
    public static var all: [TextSize] { steps.map(TextSize.init(percent:)) }

    public let percent: Int

    /// Snaps to the nearest step; a tie goes to the larger one.
    public init(percent: Int) {
        self.percent = Self.steps.min { a, b in
            let da = abs(a - percent), db = abs(b - percent)
            return da == db ? a > b : da < db
        }!
    }

    public var factor: Double { Double(percent) / 100 }
    public var isStandard: Bool { self == .standard }
    public var larger: TextSize? { Self.steps.first { $0 > percent }.map(TextSize.init(percent:)) }
    public var smaller: TextSize? { Self.steps.last { $0 < percent }.map(TextSize.init(percent:)) }

    /// Finnish formatting: "125 %".
    public var label: String { "\(percent) %" }

    /// The settings picker's text: "100 % (oletus)" for the default.
    public var choiceLabel: String { isStandard ? "\(label) (oletus)" : label }

    /// A font size at this text size, rounded to half a point so text stays crisp.
    public func scaled(_ points: Double) -> Double { Self.halfPoints(points * factor) }

    /// A layout metric (row height, column width) that follows the text size, growing at most
    /// `cap` times the design size so wide columns do not crowd out the rest of the window.
    public func metric(_ points: Double, cap: Double = .infinity) -> Double {
        Self.halfPoints(points * min(factor, cap))
    }

    private static func halfPoints(_ value: Double) -> Double { (value * 2).rounded() / 2 }

    public static func < (a: TextSize, b: TextSize) -> Bool { a.percent < b.percent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(percent: try c.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(percent)
    }
}
