import Foundation
import os

private let log = Logger(subsystem: "fi.mak8r.mail", category: "charset")

/// Turns the raw bytes of a body part or encoded word into text.
///
/// Real mail is messy: Outlook/Exchange bodies are UTF-8 with the odd stray windows-1252
/// byte (a no-break space or an en dash pasted from Word), and some senders label valid
/// UTF-8 as `iso-8859-1`. Decoding either strictly sends the whole body down a Latin-1
/// path and every "ä" becomes "Ã¤". The rules here:
///
/// 1. No charset, a UTF-8 label or an unknown label: lenient UTF-8. Valid sequences stay
///    UTF-8 and only the stray bytes are read as windows-1252 (`utf8Lenient`).
/// 2. A Western single-byte label (`iso-8859-1`/`-15`, `windows-1252`, `us-ascii`, …) over
///    bytes that are clearly UTF-8 (`UTF8Scan.looksLikeUTF8`): lenient UTF-8. Other
///    single-byte charsets (`iso-8859-2`, `windows-1250`, KOI8, …) are always read as
///    declared: their letters form valid-looking UTF-8 pairs too often ("Ó" + "Ł").
/// 3. `iso-8859-1`, `latin1` and `us-ascii` are read as windows-1252, as browsers do
///    (`label`), so €, – and curly quotes do not become invisible C1 control characters.
/// 4. Any other label goes to Foundation; if that fails, lenient UTF-8.
///
/// Every fallback writes a debug line (subsystem `fi.mak8r.mail`, category `charset`) so a
/// problem mail can be found on a real account without spending API quota.
enum Charset {
    static func string(from data: Data, charset declared: String?, messageID: String? = nil) -> String {
        let name = declared.map(label) ?? ""
        let foundation = name.isEmpty ? nil : foundationEncoding(name)

        if name.isEmpty || isUTF8(name) || foundation == nil {
            if let s = String(data: data, encoding: .utf8) { return s }
            let scan = UTF8Scan(data)
            report("invalid UTF-8 bytes read as windows-1252", declared: declared, scan: scan, messageID: messageID)
            return utf8Lenient(data)
        }

        if isWestern(name) {
            let scan = UTF8Scan(data)
            if scan.looksLikeUTF8 {
                report("single-byte label over UTF-8", declared: declared, scan: scan, messageID: messageID)
                return utf8Lenient(data)
            }
            if name == "windows-1252" { return windows1252(data) }
        }

        if let foundation, let s = String(data: data, encoding: foundation) { return s }
        report("declared charset failed", declared: declared, scan: UTF8Scan(data), messageID: messageID)
        return utf8Lenient(data)
    }

    // MARK: Labels

    /// Normalized charset label. `iso-8859-1`, `latin1` and `us-ascii` mean windows-1252,
    /// which is a superset that also defines 0x80–0x9F (WHATWG Encoding Standard).
    static func label(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(["\"", "'"])).lowercased()
        return windows1252Labels.contains(name) ? "windows-1252" : name
    }

    private static let windows1252Labels: Set<String> = [
        "iso-8859-1", "iso8859-1", "iso_8859-1", "iso_8859-1:1987", "iso88591", "latin1", "l1", "cp819", "ibm819",
        "iso-ir-100", "csisolatin1", "us-ascii", "ascii", "ansi_x3.4-1968", "iso646-us", "us", "cp1252", "x-cp1252",
        "windows-1252",
    ]

    private static func isUTF8(_ name: String) -> Bool {
        name == "utf-8" || name == "utf8" || name == "unicode-1-1-utf-8"
    }

    /// windows-1252 and ISO-8859-15: uppercase accented letters are the only UTF-8 lead
    /// bytes that commonly occur, and they are rarely followed by a symbol from 0x80–0xBF.
    private static func isWestern(_ name: String) -> Bool {
        name == "windows-1252" || ["iso-8859-15", "iso8859-15", "iso_8859-15", "latin-9", "latin9", "l9"].contains(name)
    }

    private static func foundationEncoding(_ name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: Decoders

    /// UTF-8 that tolerates stray bytes: well-formed sequences decode as UTF-8 and each
    /// byte outside one is read as windows-1252.
    static func utf8Lenient(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let bytes = [UInt8](data)
        var out = String()
        out.reserveCapacity(bytes.count)
        var runStart = 0
        var i = 0
        while i < bytes.count {
            if let length = UTF8Scan.sequenceLength(bytes, at: i) {
                i += length
                continue
            }
            if runStart < i { out += String(decoding: bytes[runStart..<i], as: UTF8.self) }
            out.unicodeScalars.append(windows1252Scalar(bytes[i]))
            i += 1
            runStart = i
        }
        if runStart < bytes.count { out += String(decoding: bytes[runStart...], as: UTF8.self) }
        return out
    }

    static func windows1252(_ data: Data) -> String {
        var out = String.UnicodeScalarView()
        for byte in data { out.append(windows1252Scalar(byte)) }
        return String(out)
    }

    /// 0x80–0x9F per windows-1252; the five bytes it leaves undefined become U+FFFD.
    private static let windows1252High: [UInt32] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ]

    private static func windows1252Scalar(_ byte: UInt8) -> Unicode.Scalar {
        if (0x80...0x9F).contains(byte) {
            return Unicode.Scalar(windows1252High[Int(byte - 0x80)]) ?? "\u{FFFD}"
        }
        return Unicode.Scalar(byte)
    }

    private static func report(_ reason: String, declared: String?, scan: UTF8Scan, messageID: String?) {
        log.debug("\(reason, privacy: .public): declared=\(declared ?? "-", privacy: .public) multibyte=\(scan.multiByte) invalid=\(scan.invalid) message=\(messageID ?? "-", privacy: .private)")
    }
}

/// Counts well-formed multi-byte UTF-8 sequences and bytes that are not part of one.
struct UTF8Scan {
    var multiByte = 0
    /// Three- and four-byte sequences, a subset of `multiByte`.
    var long = 0
    var invalid = 0

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if let length = Self.sequenceLength(bytes, at: i) {
                if length > 1 { multiByte += 1 }
                if length > 2 { long += 1 }
                i += length
            } else {
                invalid += 1
                i += 1
            }
        }
    }

    /// Clearly UTF-8: at least two multi-byte sequences (or one of three or four bytes) and
    /// at most one invalid byte per four of them. Each "ä"/"ö" of real Latin-1 text is an
    /// invalid byte, but an uppercase letter followed by a symbol occasionally forms a valid
    /// pair ("Ä–" is C4 96, the UTF-8 for "Ė"), so one two-byte sequence is not enough.
    var looksLikeUTF8: Bool {
        (multiByte >= 2 || long >= 1) && invalid * 4 <= multiByte
    }

    /// Length of the well-formed UTF-8 sequence starting at `i` (RFC 3629 table), or nil.
    static func sequenceLength(_ b: [UInt8], at i: Int) -> Int? {
        let lead = b[i]
        if lead < 0x80 { return 1 }
        func cont(_ k: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            i + k < b.count && range.contains(b[i + k])
        }
        switch lead {
        case 0xC2...0xDF: return cont(1) ? 2 : nil
        case 0xE0: return cont(1, 0xA0...0xBF) && cont(2) ? 3 : nil
        case 0xE1...0xEC, 0xEE...0xEF: return cont(1) && cont(2) ? 3 : nil
        case 0xED: return cont(1, 0x80...0x9F) && cont(2) ? 3 : nil
        case 0xF0: return cont(1, 0x90...0xBF) && cont(2) && cont(3) ? 4 : nil
        case 0xF1...0xF3: return cont(1) && cont(2) && cont(3) ? 4 : nil
        case 0xF4: return cont(1, 0x80...0x8F) && cont(2) && cont(3) ? 4 : nil
        default: return nil
        }
    }
}
