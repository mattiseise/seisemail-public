import Foundation

/// RFC 2047 encoded-words in mail headers.
public enum EncodedWords {
    public static func decode(_ header: String) -> String {
        RFC2047Decoder.decode(header)
    }

    /// Encodes non-ASCII text as space-separated UTF-8 encoded words; ASCII passes through.
    public static func encode(_ text: String) -> String {
        encodeWords(text).joined(separator: " ")
    }

    /// Bytes per encoded word: `=?UTF-8?B?` + 56 base64 characters + `?=` is 68 characters,
    /// so even the first word after `Subject: ` fits a 78-character line (RFC 2047 §2 allows 75).
    static let maxBytesPerWord = 42

    /// Non-ASCII text as UTF-8 base64 encoded words of at most `bytesPerWord` bytes (68
    /// characters by default) each, split on Unicode scalar boundaries so no word ends in the
    /// middle of a character. Text is normalized to NFC first: macOS file names are NFD,
    /// which other clients show as "a¨". ASCII text is returned as a single unencoded
    /// element unless `force` is set.
    public static func encodeWords(_ text: String) -> [String] {
        encodeWords(text, bytesPerWord: maxBytesPerWord)
    }

    static func encodeWords(_ text: String, bytesPerWord: Int, force: Bool = false) -> [String] {
        guard force || text.unicodeScalars.contains(where: { !$0.isASCII }) else { return [text] }
        var words: [String] = []
        var chunk = Data()
        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
            chunk.removeAll()
        }
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if chunk.count + bytes.count > bytesPerWord { flush() }
            chunk.append(bytes)
        }
        flush()
        return words
    }
}

enum QuotedPrintable {
    static func decode(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "="), i + 2 < bytes.count {
                let hex = String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self)
                if let value = UInt8(hex, radix: 16) {
                    out.append(value)
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }
}
