import Foundation
import Testing
@testable import MailCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func thread(_ name: String) throws -> GmailThreadDTO {
        try JSONDecoder().decode(GmailThreadDTO.self, from: data(name))
    }
}
