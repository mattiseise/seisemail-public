import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct AccountSessionTests {
    @Test func sessionUsesItsOwnViewsFileAndAPI() async {
        let api = FakeGmail()
        api.addThread("a")
        let viewsURL = makeTempDir().appendingPathComponent("views-a@x.fi.json")
        let session = AccountSession(email: "A@x.fi", auth: nil, api: api,
                                     viewsStore: ViewsConfigStore(fileURL: viewsURL),
                                     drafts: DraftStore(directory: makeTempDir()))
        #expect(session.email == "a@x.fi")
        #expect(session.id == "a@x.fi")
        await session.store.start()
        #expect(session.store.threads.map(\.id) == ["a"])
        #expect(FileManager.default.fileExists(atPath: viewsURL.path))
    }
}
