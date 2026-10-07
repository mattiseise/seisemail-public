import Foundation

/// JSON coding for the daemon's files: ISO 8601 dates in UTC with milliseconds (reads them without, too),
/// pretty-printed with sorted keys so diffs and `cat` stay readable.
public enum DaemonJSON {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(withFraction))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? withFraction.parse(text) { return date }
            if let date = try? withoutFraction.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return d
    }

    /// Rounds to whole milliseconds, the precision the files keep (so a value equals its round trip).
    public static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
