import Foundation

/// Decodes RFC 2047 encoded words in a header value.
///
/// Senders often split a multi-byte character across two adjacent encoded words
/// (`=?UTF-8?B?UMM=?= =?UTF-8?B?pGl2w6Q=?=` is "Päivä"). Decoding each word on its own
/// turns the halves into Latin-1 garbage ("PÃ¤ivÃ¤"), so the bytes of adjacent words that
/// share a charset are joined and decoded together. The run is flushed when the charset
/// changes or real text appears between two words. Whitespace between adjacent encoded
/// words is dropped (RFC 2047 §6.2). A word that cannot be decoded is kept as raw text,
/// together with the whitespace around it.
enum RFC2047Decoder {
    static func decode(_ header: String) -> String {
        guard header.contains("=?") else { return header }
        var result = ""
        var pending: (charset: String, bytes: Data)?
        var rest = Substring(header)

        func flush() {
            if let run = pending {
                result += Charset.string(from: run.bytes, charset: run.charset)
                pending = nil
            }
        }

        while let match = rest.firstMatch(of: /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/) {
            let between = rest[rest.startIndex..<match.range.lowerBound]
            let charset = normalizedCharset(String(match.1))
            if let bytes = bytes(encoding: String(match.2), text: String(match.3)) {
                // Whitespace is dropped only between two words that both decode.
                let adjacent = pending != nil && between.allSatisfy(\.isWhitespace)
                if !adjacent {
                    flush()
                    result += between
                }
                if let run = pending, run.charset == charset {
                    pending?.bytes.append(bytes)
                } else {
                    flush()
                    pending = (charset, bytes)
                }
            } else {
                flush()
                result += between
                result += rest[match.range]
            }
            rest = rest[match.range.upperBound...]
        }
        flush()
        result += rest
        return result
    }

    /// Lowercased charset name without an RFC 2231 language suffix (`UTF-8*fi` → `utf-8`).
    private static func normalizedCharset(_ raw: String) -> String {
        let name = raw.split(separator: "*", maxSplits: 1).first.map(String.init) ?? raw
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func bytes(encoding: String, text: String) -> Data? {
        if encoding.uppercased() == "B" {
            var base64 = text.filter { !$0.isWhitespace }
            if base64.count % 4 != 0 {
                base64 += String(repeating: "=", count: 4 - base64.count % 4)
            }
            return Data(base64Encoded: base64)
        }
        return QuotedPrintable.decode(text.replacingOccurrences(of: "_", with: " "))
    }
}
