import Foundation

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mak8r-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
