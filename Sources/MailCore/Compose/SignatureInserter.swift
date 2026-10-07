import Foundation

/// Puts a plain-text signature (`-- \n<text>`) into a draft body or swaps it for another.
public enum SignatureInserter {
    public static func block(_ signature: Signature) -> String { "-- \n" + signature.text }

    /// Replaces the first untouched copy of `old` with `new`. If `old` is not found as-is
    /// (edited, or none), nothing is removed and `new` is inserted at `insertionPoint`
    /// (end of body when nil).
    public static func replace(_ old: Signature?, with new: Signature?, in body: String, insertionPoint: String.Index?) -> String {
        if old == new { return body }
        if let old, let range = untouchedRange(of: block(old), in: body) {
            var lower = range.lowerBound
            if new == nil {
                while lower > body.startIndex, body[body.index(before: lower)] == "\n" {
                    lower = body.index(before: lower)
                }
            }
            return body.replacingCharacters(in: lower..<range.upperBound, with: new.map(block) ?? "")
        }
        guard let new else { return body }
        let point = insertionPoint ?? body.endIndex
        var out = body
        out.insert(contentsOf: "\n\n" + block(new), at: point)
        return out
    }

    /// First copy of `block` that ends the body or a line; one followed by more typed text counts as edited.
    private static func untouchedRange(of block: String, in body: String) -> Range<String.Index>? {
        var searchStart = body.startIndex
        while let range = body.range(of: block, range: searchStart..<body.endIndex) {
            if range.upperBound == body.endIndex || body[range.upperBound] == "\n" { return range }
            searchStart = body.index(after: range.lowerBound)
        }
        return nil
    }
}
