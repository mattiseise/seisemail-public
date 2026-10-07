import Foundation

/// Turns Gmail's HTML send-as signatures into plain-text signatures named by address.
public enum GmailSignatureImport {
    /// Signatures to append; addresses without a signature and exact duplicates are skipped.
    public static func newSignatures(from remote: [SendAsSignature], existing: [Signature]) -> [Signature] {
        var known = Set(existing.map { [$0.name, $0.text] })
        var out: [Signature] = []
        for entry in remote {
            let text = HTMLText.plainText(fromHTML: entry.html)
            guard !text.isEmpty, known.insert([entry.email, text]).inserted else { continue }
            out.append(Signature(name: entry.email, text: text))
        }
        return out
    }
}
