import Foundation
import Testing
@testable import MailCore

@Suite struct LabelDirectoryTests {
    let fake = LabelFakeGmail()

    var listCount: Int { fake.calls.filter { $0 == "list labels" }.count }

    func user(_ id: String, _ name: String) -> GmailLabelInfo {
        GmailLabelInfo(id: id, name: name, kind: .user)
    }

    // MARK: - LabelSnapshot (pure)

    /// Gmail cannot hold both names (LabelFakeGmail.addLabel rejects it); this pins list-order determinism
    /// of the lookup for the TS port, not a reachable Gmail state.
    @Test func exactThenCaseInsensitive() {
        let both = LabelSnapshot(labels: [user("Label_1", "torkku"), user("Label_2", "Torkku")])
        #expect(both.id(forName: "Torkku") == "Label_2")
        #expect(both.id(forName: "torkku") == "Label_1")
        #expect(both.id(forName: "TORKKU") == "Label_1")              // first case-insensitive match in list order
        let lower = LabelSnapshot(labels: [user("Label_1", "torkku")])
        #expect(lower.id(forName: "Torkku") == "Label_1")
        #expect(lower.id(forName: "Torkk") == nil)
    }

    @Test func snapshotLookups() {
        let inbox = GmailLabelInfo(id: "INBOX", name: "INBOX", kind: .system)
        let snap = LabelSnapshot(labels: [inbox, user("Label_1", "Torkku")])
        #expect(snap.labels == [inbox, user("Label_1", "Torkku")])
        #expect(snap.namesByID == ["INBOX": "INBOX", "Label_1": "Torkku"])
        #expect(snap.name(forID: "Label_1") == "Torkku")
        #expect(snap.name(forID: "Label_9") == nil)
        #expect(snap.contains(id: "INBOX"))
        #expect(snap.contains(id: "Label_9") == false)
        #expect(snap.label(id: "Label_1") == user("Label_1", "Torkku"))
        let renamed = snap.inserting(user("Label_1", "Snoozed")).inserting(user("Label_2", "Torkku/x"))
        #expect(renamed.name(forID: "Label_1") == "Snoozed")
        #expect(renamed.labels.filter { $0.id == "Label_1" }.count == 1)
        #expect(renamed.id(forName: "Torkku/x") == "Label_2")
        let removed = renamed.removing(id: "Label_1")
        #expect(removed.contains(id: "Label_1") == false)
        #expect(removed.id(forName: "Snoozed") == nil)
        #expect(removed.namesByID == ["INBOX": "INBOX", "Label_2": "Torkku/x"])
    }

    @Test func nfdNameMatchesNFCConstant() {
        // Gmail may hand back a decomposed "ä"; Swift String equality is canonical (TS must normalise to NFC).
        let snap = LabelSnapshot(labels: [user("Label_3", "Lajittelu/Vaatii toimenpidetta\u{0308}")])
        #expect(snap.id(forName: SeiseLabels.Sorting.needsAction) == "Label_3")
    }

    // MARK: - LabelDirectory

    // MARK: - ensureExisting (the sorting labels Käsiteltävät's query names)

    let sorting = [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications]

    @Test func ensureExistingCreatesMissingLabelsShown() async {
        let directory = LabelDirectory(api: fake)
        let unconfirmed = await directory.ensureExisting(sorting, visibility: .shown)
        #expect(unconfirmed.isEmpty)
        #expect(fake.calls == ["list labels", "label create Lajittelu/Uutiskirjeet", "label create Lajittelu/Ilmoitukset"])
        #expect(fake.visibility(ofLabelNamed: "Lajittelu/Uutiskirjeet") == .shown)
        #expect(fake.visibility(ofLabelNamed: "Lajittelu/Ilmoitukset") == .shown)
    }

    @Test func ensureExistingIsIdempotent() async {
        let directory = LabelDirectory(api: fake)
        _ = await directory.ensureExisting(sorting, visibility: .shown)
        let before = fake.calls.count
        #expect(await directory.ensureExisting(sorting, visibility: .shown).isEmpty)
        #expect(fake.calls.count == before)                              // cached: no request at all
        let fresh = LabelDirectory(api: fake)                            // next launch: one labels.list
        #expect(await fresh.ensureExisting(sorting, visibility: .shown).isEmpty)
        #expect(Array(fake.calls.dropFirst(before)) == ["list labels"])
    }

    @Test func ensureExistingAdoptsAnyCase() async {
        fake.addLabel("lajittelu/uutiskirjeet")
        let directory = LabelDirectory(api: fake)
        #expect(await directory.ensureExisting(sorting, visibility: .shown).isEmpty)
        #expect(fake.calls == ["list labels", "label create Lajittelu/Ilmoitukset"])
    }

    @Test func ensureExistingReportsWhatItCouldNotConfirm() async {
        fake.updateLabels { $0.createErrors["lajittelu/ilmoitukset"] = 400 }         // reserved or invalid
        let directory = LabelDirectory(api: fake)
        let unconfirmed = await directory.ensureExisting(sorting, visibility: .shown)
        #expect(unconfirmed == [SeiseLabels.Sorting.notifications])
        #expect(fake.labelID("Lajittelu/Uutiskirjeet") != nil)
    }

    @Test func ensureExistingOfflineConfirmsNothing() async {
        fake.update { $0.offline = true }
        let directory = LabelDirectory(api: fake)
        #expect(await directory.ensureExisting(sorting, visibility: .shown) == Set(sorting))
    }

    @Test func ensureExistingListsLabelsOnceWhenTheListFails() async {
        fake.update { $0.offline = true }
        let directory = LabelDirectory(api: fake)
        #expect(await directory.ensureExisting(sorting, visibility: .shown) == Set(sorting))
        #expect(fake.calls == ["list labels"])                           // not once per name
    }

    @Test func ensureExistingStopsAtTheFirstOfflineCreate() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        fake.update { $0.offline = true }
        #expect(await directory.ensureExisting(sorting, visibility: .shown) == Set(sorting))
        #expect(fake.calls == ["list labels", "label create Lajittelu/Uutiskirjeet"])
    }

    @Test func firstLoadSharedByConcurrentCallers() async throws {
        fake.updateLabels { $0.listLabelsDelay = .milliseconds(50) }
        let directory = LabelDirectory(api: fake)
        try await withThrowingTaskGroup(of: LabelSnapshot.self) { group in
            for _ in 0..<5 { group.addTask { try await directory.snapshot() } }
            for try await snap in group { #expect(snap.contains(id: "INBOX")) }
        }
        #expect(fake.calls == ["list labels"])
    }

    @Test func snapshotIsCached() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        fake.addLabel("Torkku")
        let snap = try await directory.snapshot()
        #expect(snap.id(forName: "Torkku") == nil)                       // cache, not the server
        #expect(listCount == 1)
        let fresh = try await directory.refresh()
        #expect(fresh.id(forName: "Torkku") == "Label_1")
        #expect(listCount == 2)
    }

    @Test func ensureExistingDoesNotCreate() async throws {
        let id = fake.addLabel("Torkku")
        let directory = LabelDirectory(api: fake)
        #expect(try await directory.ensureID(name: "Torkku", visibility: .shown) == id)
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func ensureCreatesWithVisibility() async throws {
        let directory = LabelDirectory(api: fake)
        let id = try await directory.ensureID(name: "Torkku/20261005T0500Z", visibility: .hidden)
        #expect(id == "Label_1")
        #expect(fake.mutatingCalls == ["label create Torkku/20261005T0500Z"])
        #expect(fake.visibility(ofLabelNamed: "Torkku/20261005T0500Z") == .hidden)
        #expect(try await directory.ensureID(name: "Torkku/20261005T0500Z", visibility: .hidden) == "Label_1")
        #expect(fake.mutatingCalls == ["label create Torkku/20261005T0500Z"])
        #expect(try await directory.snapshot().name(forID: "Label_1") == "Torkku/20261005T0500Z")
        #expect(listCount == 1)                                           // created label went into the cache
    }

    @Test func ensureShownVisibility() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.ensureID(name: "Torkku", visibility: .shown)
        #expect(fake.visibility(ofLabelNamed: "Torkku") == LabelVisibility(labelList: .labelShow, messageList: .show))
    }

    @Test func conflictRelistsAndAdopts() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        let existing = fake.addLabel("Torkku/20261005T0500Z", visibility: .hidden)    // another device, after our list
        let id = try await directory.ensureID(name: "Torkku/20261005T0500Z", visibility: .hidden)
        #expect(id == existing)
        #expect(fake.mutatingCalls == ["label create Torkku/20261005T0500Z"])
        #expect(listCount == 2)
    }

    @Test func conflictAdoptsCaseVariant() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        let existing = fake.addLabel("torkku")
        #expect(try await directory.ensureID(name: "Torkku", visibility: .shown) == existing)
        #expect(fake.mutatingCalls == ["label create Torkku"])
    }

    @Test func caseVariantAdoptedWithoutCreate() async throws {
        let existing = fake.addLabel("torkku")
        let directory = LabelDirectory(api: fake)
        #expect(try await directory.ensureID(name: "Torkku", visibility: .shown) == existing)
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func reservedNameThrows() async {
        fake.updateLabels { $0.createErrors["torkku"] = 400 }
        let directory = LabelDirectory(api: fake)
        await #expect(throws: LabelDirectoryError.createRejected(name: "Torkku", status: 400)) {
            try await directory.ensureID(name: "Torkku", visibility: .shown)
        }
        #expect(fake.mutatingCalls == ["label create Torkku"])
        #expect(listCount == 2)
    }

    @Test func conflictWithoutMatchThrows409() async {
        fake.updateLabels { $0.createErrors["torkku"] = 409 }
        let directory = LabelDirectory(api: fake)
        await #expect(throws: LabelDirectoryError.createRejected(name: "Torkku", status: 409)) {
            try await directory.ensureID(name: "Torkku", visibility: .shown)
        }
    }

    @Test func otherCreateErrorPropagates() async {
        fake.update { $0.failing = ["createLabel"] }
        let directory = LabelDirectory(api: fake)
        await #expect(throws: GmailError.http(500, "fail")) {
            try await directory.ensureID(name: "Torkku", visibility: .shown)
        }
        #expect(listCount == 1)                                           // no re-list for a non-conflict error
    }

    @Test func concurrentEnsureCreatesOnce() async throws {
        let directory = LabelDirectory(api: fake)
        let ids = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 { group.addTask { try await directory.ensureID(name: "Torkku/x", visibility: .hidden) } }
            var out: [String] = []
            for try await id in group { out.append(id) }
            return out
        }
        #expect(ids == Array(repeating: "Label_1", count: 10))
        #expect(fake.mutatingCalls == ["label create Torkku/x"])
        #expect(listCount == 1)
    }

    @Test func unknownIDRefreshesOnceThenRemembered() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot(knowing: ["Label_99"])
        _ = try await directory.snapshot(knowing: ["Label_99"])
        #expect(listCount == 2)                                           // initial load + one refresh, not three
        _ = try await directory.snapshot(knowing: ["Label_99", "INBOX"])
        #expect(listCount == 2)
    }

    @Test func knownIDsDoNotRefresh() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot(knowing: ["INBOX", "UNREAD"])
        _ = try await directory.snapshot(knowing: ["INBOX", "TRASH"])
        #expect(listCount == 1)
    }

    @Test func knowingNewLabelFindsIt() async throws {
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        let id = fake.addLabel("X")
        let snap = try await directory.snapshot(knowing: [id])
        #expect(snap.contains(id: id))
        #expect(snap.name(forID: id) == "X")
        #expect(listCount == 2)
    }

    @Test func deleteRemovesLabelAndCache() async throws {
        let id = fake.addLabel("Torkku/20261005T0400Z")
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        try await directory.delete(id: id)
        #expect(fake.mutatingCalls == ["label delete \(id)"])
        #expect(fake.labelID("Torkku/20261005T0400Z") == nil)
        #expect(try await directory.snapshot().contains(id: id) == false)
        #expect(listCount == 1)
    }

    @Test func deleteTolerates404AndUpdatesCache() async throws {
        let id = fake.addLabel("X")
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        fake.updateLabels { $0.deleteErrors[id] = 404 }
        try await directory.delete(id: id)
        #expect(try await directory.snapshot().contains(id: id) == false)
        #expect(listCount == 1)
    }

    @Test func deleteOtherErrorThrows() async throws {
        let id = fake.addLabel("X")
        let directory = LabelDirectory(api: fake)
        _ = try await directory.snapshot()
        fake.updateLabels { $0.deleteErrors[id] = 500 }
        await #expect(throws: GmailError.http(500, "delete failed")) { try await directory.delete(id: id) }
    }

    @Test func listFailurePropagatesAndRetriesNextTime() async throws {
        fake.update { $0.failing = ["labels"] }
        let directory = LabelDirectory(api: fake)
        await #expect(throws: GmailError.http(500, "fail")) { try await directory.snapshot() }
        fake.update { $0.failing = [] }
        #expect(try await directory.snapshot().contains(id: "INBOX"))
        #expect(listCount == 2)
    }
}
