import Testing
@testable import MailCore

@Suite struct ListEmptyStateTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var threadsEmpty = true
        var needsSignIn = false
        var load: ListLoadState
        var isOffline = false
        var kind: ListViewKind
        var expected: ListEmptyState

        var testDescription: String {
            "empty=\(threadsEmpty) signIn=\(needsSignIn) \(load) offline=\(isOffline) \(kind) → \(expected)"
        }
    }

    static let kinds: [ListViewKind] = [.inboxZero, .snoozed, .other]

    static let cases: [Case] = {
        let loads: [ListLoadState] = [.notLoaded, .loaded, .failed]
        var all: [Case] = []
        for load in loads {
            for kind in kinds {
                for offline in [false, true] {
                    // Not empty → none, whatever else holds.
                    all.append(Case(threadsEmpty: false, load: load, isOffline: offline, kind: kind, expected: .none))
                }
                // needsSignIn: LoginView takes over.
                all.append(Case(needsSignIn: true, load: load, isOffline: true, kind: kind, expected: .none))
            }
        }
        for kind in kinds {
            // Not loaded yet → loading, offline or not.
            all.append(Case(load: .notLoaded, isOffline: false, kind: kind, expected: .loading))
            all.append(Case(load: .notLoaded, isOffline: true, kind: kind, expected: .loading))
            // Failed → offline or failed, never an inbox-zero message.
            all.append(Case(load: .failed, isOffline: true, kind: kind, expected: .offline))
            all.append(Case(load: .failed, isOffline: false, kind: kind, expected: .failed))
        }
        // Loaded and empty → by kind; the offline flag does not change it.
        for offline in [false, true] {
            all.append(Case(load: .loaded, isOffline: offline, kind: .inboxZero, expected: .inboxZero))
            all.append(Case(load: .loaded, isOffline: offline, kind: .snoozed, expected: .snoozedEmpty))
            all.append(Case(load: .loaded, isOffline: offline, kind: .other, expected: .empty))
        }
        return all
    }()

    @Test(arguments: cases)
    func resolves(_ c: Case) {
        #expect(ListEmptyState.resolve(threadsEmpty: c.threadsEmpty, needsSignIn: c.needsSignIn, load: c.load,
                                       isOffline: c.isOffline, kind: c.kind) == c.expected)
    }
}
