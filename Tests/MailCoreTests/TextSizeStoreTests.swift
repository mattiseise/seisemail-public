import Foundation
import Testing
@testable import MailCore

@MainActor @Suite struct TextSizeStoreTests {
    /// A private defaults domain per test; removed again so test runs leave nothing behind.
    final class Defaults {
        let suite = "fi.mak8r.mail.tests.textsize-\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: suite)! }
        deinit { UserDefaults().removePersistentDomain(forName: suite) }
    }

    final class Flag: @unchecked Sendable { var fired = false }

    @Test func missingValueStartsAtStandardAndWritesNothing() {
        let d = Defaults()
        let store = TextSizeStore(defaults: d.defaults)
        #expect(store.size == .standard)
        store.reset()
        store.set(.standard)
        #expect(d.defaults.object(forKey: TextSizeStore.key) == nil)
    }

    @Test func stepsPersistAndClampAtEnds() {
        let d = Defaults()
        let store = TextSizeStore(defaults: d.defaults)
        store.increase(); store.increase()
        #expect(store.size.percent == 125)
        #expect(d.defaults.integer(forKey: TextSizeStore.key) == 125)
        #expect(TextSizeStore(defaults: d.defaults).size.percent == 125)
        for _ in 0..<10 { store.increase() }
        #expect(store.size.percent == 200)
        #expect(!store.canIncrease)
        for _ in 0..<10 { store.decrease() }
        #expect(store.size.percent == 85)
        #expect(!store.canDecrease)
        store.reset()
        #expect(TextSizeStore(defaults: d.defaults).size == .standard)
    }

    @Test func noOpSetDoesNotNotifyOrWrite() {
        let d = Defaults()
        d.defaults.set(150, forKey: TextSizeStore.key)
        let store = TextSizeStore(defaults: d.defaults)
        let flag = Flag()
        withObservationTracking { _ = store.size } onChange: { flag.fired = true }
        // A stray value written behind the store's back shows whether set() wrote again.
        d.defaults.set(175, forKey: TextSizeStore.key)
        store.set(TextSize(percent: 150))
        #expect(!flag.fired)
        #expect(d.defaults.integer(forKey: TextSizeStore.key) == 175)
        store.increase()
        #expect(flag.fired)
        #expect(d.defaults.integer(forKey: TextSizeStore.key) == 175)
        #expect(store.size.percent == 175)
    }

    @Test(arguments: [(130, 125), (400, 200), (-3, 85), (99, 100)])
    func storedValueSnapsToStep(stored: Int, expected: Int) {
        let d = Defaults()
        d.defaults.set(stored, forKey: TextSizeStore.key)
        #expect(TextSizeStore(defaults: d.defaults).size.percent == expected)
    }

    @Test func nonNumericStoredValueFallsBack() {
        let d = Defaults()
        d.defaults.set("huge", forKey: TextSizeStore.key)
        #expect(TextSizeStore(defaults: d.defaults).size == .standard)
        d.defaults.set(137.6, forKey: TextSizeStore.key)
        #expect(TextSizeStore(defaults: d.defaults).size.percent == 150)
    }

    @Test func resetToStandardRemovesTheValue() {
        let d = Defaults()
        let store = TextSizeStore(defaults: d.defaults)
        store.increase()
        #expect(d.defaults.object(forKey: TextSizeStore.key) != nil)
        store.reset()
        #expect(d.defaults.object(forKey: TextSizeStore.key) == nil)
        #expect(store.size == .standard)
    }
}
