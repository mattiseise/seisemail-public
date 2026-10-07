import Foundation

/// Unsent drafts kept locally so nothing typed is lost.
public struct DraftStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL { AppPaths.supportDirectory.appendingPathComponent("drafts", isDirectory: true) }

    public func save(_ draft: Draft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url(for: draft.id), options: .atomic)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func all() -> [Draft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Draft.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
