import Foundation
import UniformTypeIdentifiers

/// Opening and saving attachments: an on-disk cache (a repeat open costs 0 quota units), safe
/// file names and a Finnish message for each kind of failure.
public enum AttachmentFetch {
    public enum Failure: Error, Equatable, Sendable {
        /// The message has no such attachment, or it has neither data nor an id.
        case notFound
        /// The file could not be written.
        case write
    }

    public static var defaultDirectory: URL {
        AppPaths.cacheDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// The attachment a link in the rendered thread points at.
    public static func attachment(for action: ThreadHTML.AttachmentAction, in thread: MailThread) -> Attachment? {
        thread.messages.first { $0.id == action.messageID }?.attachments.first { $0.partID == action.partID }
    }

    /// `<directory>/<messageID>/<partID>/<file name>`: one folder per part, so two attachments with
    /// the same name in one message never overwrite each other.
    public static func cacheURL(for attachment: Attachment, in directory: URL) -> URL {
        directory
            .appendingPathComponent(safeComponent(attachment.messageID, fallback: "viesti"), isDirectory: true)
            .appendingPathComponent(safeComponent(attachment.partID, fallback: "root"), isDirectory: true)
            .appendingPathComponent(fileName(for: attachment))
    }

    /// The cached file, downloading it only when it is missing or its size is wrong.
    public static func file(for attachment: Attachment, api: GmailAPI, directory: URL = defaultDirectory) async throws -> URL {
        let url = cacheURL(for: attachment, in: directory)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           attachment.size > 0 ? size == attachment.size : size > 0 {
            return url
        }
        let data: Data
        if let inline = attachment.inlineData {
            data = inline
        } else if let id = attachment.attachmentID {
            data = try await api.attachmentData(messageID: attachment.messageID, attachmentID: id)
        } else {
            throw Failure.notFound
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.write
        }
        return url
    }

    /// A name that is safe on disk and opens in the right app: NFC, no path separators or control
    /// characters, no leading dots, and an extension from the MIME type when the name lacks one.
    public static func fileName(for attachment: Attachment) -> String {
        var name = attachment.filename.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "liite" }

        let current = (name as NSString).pathExtension
        let knownExtension = !current.isEmpty && UTType(filenameExtension: current)?.isDynamic == false
        if !knownExtension, let ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return truncated(name, maxBytes: 200)
    }

    public static func message(for error: Error) -> String {
        switch error {
        case GmailError.rateLimited:
            "Liitteen lataus epäonnistui: Gmailin pyyntöraja on täynnä. Yritä uudelleen minuutin päästä."
        case GmailError.offline:
            "Liitettä ei voitu ladata – ei verkkoyhteyttä."
        case GmailError.decoding:
            "Liitteen sisältö oli viallinen."
        case Failure.notFound, GmailError.http(404, _):
            "Liitettä ei löytynyt viestistä."
        case Failure.write:
            "Liitteen tallennus epäonnistui."
        case GmailError.http(let code, _):
            "Liitteen lataus epäonnistui (Gmail-virhe \(code))."
        default:
            "Liitteen lataus epäonnistui"
        }
    }

    private static func safeComponent(_ value: String, fallback: String) -> String {
        var s = value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? fallback : s
    }

    /// Keeps the extension and cuts the base so the name fits common file systems.
    private static func truncated(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        while base.utf8.count + suffix.utf8.count > maxBytes, !base.isEmpty { base.removeLast() }
        return base + suffix
    }
}
