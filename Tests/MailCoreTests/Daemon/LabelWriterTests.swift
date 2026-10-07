import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// `LabelWriter` (§5): names → IDs (marker hidden, others shown), one add-only `threads.modify`, never an empty
/// one (V6), and the conventions §0 retry-once on 400/404.
@Suite struct LabelWriterTests {
    let fake = SyncFakeGmail()
    let marker = "Lajittelu/Luokiteltu"
    let uutiskirjeet = "Lajittelu/Uutiskirjeet"

    func writer(_ directory: LabelDirectory? = nil) -> (LabelWriter, LabelDirectory) {
        let directory = directory ?? LabelDirectory(api: fake)
        return (LabelWriter(api: fake, directory: directory), directory)
    }

    /// Thread t1 with one incoming newsletter message, as read fresh.
    func newsletterThread() async throws -> ThreadHeaders {
        fake.deliver("t1", from: "Uutiset <uutiset@lehti.fi>", subject: "Viikon uutiset", headers: ["List-Unsubscribe": "<mailto:x>"])
        return try await fake.threadHeaders(id: "t1", headers: ["From", "Subject", "List-Unsubscribe"])
    }

    static let classify = SortingDecision.classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: [])
    static let same: @Sendable (ThreadHeaders, LabelSnapshot) -> SortingDecision = { _, _ in classify }

    func modifyCalls() -> [String] { fake.calls.filter { $0.hasPrefix("modify ") } }

    @Test(arguments: [SortingDecision.propagate(addNames: []), .unmatched, .manualKept, .deferredAutoReply, .ignore("vanha")])
    func nothingToWriteMakesNoCall(_ d: SortingDecision) async throws {
        let thread = try await newsletterThread()
        fake.resetCalls()
        let (w, _) = writer()
        let added = try await w.apply(d, thread: thread, redecide: Self.same)
        #expect(added.isEmpty)
        #expect(fake.writes.isEmpty)
    }

    @Test func classifyCreatesMissingLabelsWithTheRightVisibility() async throws {
        let thread = try await newsletterThread()
        let (w, _) = writer()
        _ = try await w.apply(Self.classify, thread: thread, redecide: Self.same)
        #expect(fake.labels.visibility(ofLabelNamed: marker) == .hidden)
        #expect(fake.labels.visibility(ofLabelNamed: uutiskirjeet) == .shown)
        #expect(fake.labelNames(of: "t1").isSuperset(of: [uutiskirjeet, marker]))
        let modifies = modifyCalls()
        #expect(modifies.count == 1)
        #expect(modifies.first?.hasSuffix(" -") == true)                  // add only, nothing removed
        #expect(fake.writes.last?.hasPrefix("modify t1 ") == true)
    }

    @Test func classifyUsesExistingLabelsCaseInsensitively() async throws {
        let existing = fake.labels.addLabel("lajittelu/uutiskirjeet")
        let markerID = fake.labels.addLabel(marker, visibility: .hidden)
        let thread = try await newsletterThread()
        fake.resetCalls()
        let (w, _) = writer()
        _ = try await w.apply(Self.classify, thread: thread, redecide: Self.same)
        #expect(!fake.calls.contains { $0.hasPrefix("label create") })
        #expect(modifyCalls().count == 1)
        let add = Set(modifyCalls()[0].split(separator: " ")[2].dropFirst().split(separator: ",").map(String.init))
        #expect(add == [existing, markerID])
    }

    @Test func propagateAddsOnlyTheMissingNames() async throws {
        let k = fake.labels.addLabel("Lajittelu/Kuitit")
        let m = fake.labels.addLabel(marker, visibility: .hidden)
        let thread = try await newsletterThread()
        fake.resetCalls()
        let (w, _) = writer()
        _ = try await w.apply(.propagate(addNames: ["Lajittelu/Kuitit", marker]), thread: thread, redecide: Self.same)
        #expect(modifyCalls().count == 1)
        let parts = modifyCalls()[0].split(separator: " ", omittingEmptySubsequences: false)
        #expect(Set(parts[2].dropFirst().split(separator: ",").map(String.init)) == [k, m])
        #expect(parts[3] == "-")
    }

    /// conventions §0: a stale ID (label deleted and recreated elsewhere) → refresh, re-read fresh, re-decide,
    /// resend once with the new IDs.
    @Test func staleLabelIDIsRetriedOnceWithFreshIDs() async throws {
        fake.labels.addLabel(marker, visibility: .hidden)
        fake.labels.addLabel(uutiskirjeet)
        let directory = LabelDirectory(api: fake)
        try await directory.refresh()
        fake.labels.deleteLabelServerSide(uutiskirjeet)
        let fresh = fake.labels.addLabel(uutiskirjeet)
        let thread = try await newsletterThread()
        fake.resetCalls()
        let (w, _) = writer(directory)
        _ = try await w.apply(Self.classify, thread: thread, redecide: Self.same)
        #expect(modifyCalls().count == 2)
        #expect(fake.calls.contains("list labels"))                       // directory refreshed
        #expect(fake.calls.contains("thread headers t1"))                 // re-read fresh before the resend
        #expect(modifyCalls().last?.contains(fresh) == true)
        #expect(fake.labelNames(of: "t1").isSuperset(of: [uutiskirjeet, marker]))
    }

    @Test func sameChangeAfterA400IsNotResent() async throws {
        fake.labels.addLabel(marker, visibility: .hidden)
        fake.labels.addLabel(uutiskirjeet)
        let thread = try await newsletterThread()
        fake.labels.updateLabels { $0.forcedModifyStatus = 400 }
        fake.resetCalls()
        let (w, _) = writer()
        await #expect(throws: GmailError.self) {
            _ = try await w.apply(Self.classify, thread: thread, redecide: Self.same)
        }
        #expect(modifyCalls().count == 1)
    }

    @Test func redecisionAfterA400CanDropTheWrite() async throws {
        // Matti removed the label meanwhile: the fresh re-read decides `.manualKept` and nothing is resent.
        fake.labels.addLabel(marker, visibility: .hidden)
        fake.labels.addLabel(uutiskirjeet)
        let directory = LabelDirectory(api: fake)
        try await directory.refresh()
        fake.labels.deleteLabelServerSide(uutiskirjeet)
        fake.labels.addLabel(uutiskirjeet)
        let thread = try await newsletterThread()
        fake.resetCalls()
        let (w, _) = writer(directory)
        let added = try await w.apply(Self.classify, thread: thread, redecide: { _, _ in .manualKept })
        #expect(added.isEmpty)
        #expect(modifyCalls().count == 1)
    }

    @Test func goneThreadIsNotAnError() async throws {
        fake.labels.addLabel(marker, visibility: .hidden)
        fake.labels.addLabel(uutiskirjeet)
        let thread = try await newsletterThread()
        fake.removeThread("t1")
        fake.resetCalls()
        let (w, _) = writer()
        let added = try await w.apply(Self.classify, thread: thread, redecide: Self.same)
        #expect(added.isEmpty)
        #expect(modifyCalls().count == 1)
    }
}
