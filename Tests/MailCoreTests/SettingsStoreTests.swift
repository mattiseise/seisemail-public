import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct SettingsStoreTests {
    let dir = makeTempDir()

    func makeStore() -> SettingsStore {
        let dir = self.dir
        return SettingsStore(
            appFile: SettingsFile(fileURL: dir.appendingPathComponent("settings.json")),
            accountFile: { SettingsFile(fileURL: dir.appendingPathComponent("settings-\($0.lowercased()).json")) }
        )
    }

    @Test func defaults() {
        let s = AppSettings()
        #expect(s.undoSendSeconds == 10)
        #expect(s.warnMissingAttachment)
        #expect(s.remoteImages == .block)
        #expect(s.markRead == .immediately)
        #expect(s.afterArchive == .next)
        #expect(s.openFirstThread == false)
        #expect(s.notificationSound && s.dockBadge && s.menuBarIcon)
        #expect(s.shortcuts == ShortcutMap.defaults)
        let a = AccountSettings()
        #expect(a.signatures.isEmpty && a.defaultForNew == nil && a.defaultForReplies == nil)
        #expect(a.notificationsEnabled)
        #expect(a.trustedImageSenders.isEmpty)
    }

    @Test func missingFileGivesDefaultsAndWritesNothing() {
        let store = makeStore()
        #expect(store.app == AppSettings())
        #expect(store.account("x@y.fi") == AccountSettings())
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
    }

    @Test func changesAreSavedAndReloaded() {
        let store = makeStore()
        store.app.undoSendSeconds = 20
        store.app.remoteImages = .always
        let sig = Signature(name: "Lyhyt", text: "Maija")
        store.updateAccount("Maija@Example.fi") { $0.signatures = [sig]; $0.defaultForNew = sig.id }
        let reloaded = makeStore()
        #expect(reloaded.app.undoSendSeconds == 20)
        #expect(reloaded.app.remoteImages == .always)
        #expect(reloaded.account("maija@example.fi").signatures == [sig])
        #expect(reloaded.account("MAIJA@EXAMPLE.FI").signature(for: .new) == sig)
    }

    @Test func partialAndUnknownFieldsFallBackPerField() throws {
        let json = #"{"undoSendSeconds": 5, "remoteImages": "sometimes", "futureField": true}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = makeStore()
        #expect(store.app.undoSendSeconds == 5)
        #expect(store.app.remoteImages == .block)
        #expect(store.app.dockBadge == true)
    }

    @Test func brokenFileIsNotOverwrittenUntilChanged() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: url)
        let store = makeStore()
        #expect(store.app == AppSettings())
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
        store.app.dockBadge = false
        #expect(makeStore().app.dockBadge == false)
    }

    @Test func danglingDefaultSignatureIsNone() {
        var a = AccountSettings()
        a.signatures = [Signature(name: "A", text: "a")]
        a.defaultForReplies = UUID()
        #expect(a.signature(for: .reply) == nil)
    }

    @Test func trustedSendersIgnoreCase() {
        var a = AccountSettings()
        a.trustedImageSenders = ["uutiset@example.fi"]
        #expect(a.trustsImages(from: "Uutiset@Example.FI"))
        #expect(!a.trustsImages(from: "muu@example.fi"))
    }
}
