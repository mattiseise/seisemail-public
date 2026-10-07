import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct MailStoreFilterTests {
    let api = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    func makeStore() async -> MailStore {
        api.addThread("a")
        api.addThread("m", in: ["in:inbox from:matti"])
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        return store
    }

    @Test func addingFilterNarrowsList() async {
        let store = await makeStore()
        #expect(store.threads.map(\.id) == ["a"])
        await store.addFilter(MailFilter(.from("matti")))
        #expect(store.activeQuery == "in:inbox from:matti")
        #expect(store.threads.map(\.id) == ["m"])
        #expect(store.filtersChanged)
    }

    @Test func emptyChipDoesNotReload() async {
        let store = await makeStore()
        let lists = api.calls.filter { $0.hasPrefix("list") }.count
        await store.addFilter(MailFilter(.from("")))
        #expect(api.calls.filter { $0.hasPrefix("list") }.count == lists)
        #expect(store.draftFilters.count == 1)
    }

    @Test func updateAndRemoveFilter() async {
        let store = await makeStore()
        var chip = MailFilter(.from(""))
        await store.addFilter(chip)
        chip.kind = .from("matti")
        await store.updateFilter(chip)
        #expect(store.threads.map(\.id) == ["m"])
        await store.removeFilter(chip.id)
        #expect(store.draftFilters.isEmpty)
        #expect(store.threads.map(\.id) == ["a"])
        #expect(!store.filtersChanged)
    }

    @Test func saveAndResetFilters() async {
        let store = await makeStore()
        await store.addFilter(MailFilter(.from("matti")))
        store.saveFilters()
        #expect(!store.filtersChanged)
        #expect(ViewsConfigStore(fileURL: viewsStore.fileURL).load()[0].filters.count == 1)

        await store.addFilter(MailFilter(.unread))
        await store.resetFilters()
        #expect(store.draftFilters.count == 1)
        #expect(store.activeQuery == "in:inbox from:matti")
    }

    @Test func saveAsNewViewKeepsOriginal() async {
        let store = await makeStore()
        let inbox = store.views[0].id
        await store.addFilter(MailFilter(.from("matti")))
        store.saveFiltersAsView(name: "Matti")
        #expect(store.views.count == 5)
        #expect(store.views[0].filters.isEmpty)
        #expect(store.views[4].name == "Matti")
        #expect(store.views[4].query == "in:inbox")
        #expect(store.activeViewID == store.views[4].id)
        #expect(!store.filtersChanged)
        await store.selectView(inbox)
        #expect(store.draftFilters.isEmpty)
        #expect(store.threads.map(\.id) == ["a"])
    }

    @Test func switchingViewDropsUnsavedFilters() async {
        let store = await makeStore()
        await store.addFilter(MailFilter(.from("matti")))
        await store.selectView(store.views[1].id)
        await store.selectView(store.views[0].id)
        #expect(store.draftFilters.isEmpty)
    }

    @Test func savedFiltersAreLoadedWithView() async {
        var views = ViewsConfigStore.defaults
        views[0].filters = [MailFilter(.from("matti"))]
        try? viewsStore.save(views)
        let store = await makeStore()
        #expect(store.threads.map(\.id) == ["m"])
        #expect(!store.filtersChanged)
    }

    @Test func searchIgnoresFilters() async {
        let store = await makeStore()
        await store.addFilter(MailFilter(.from("matti")))
        await store.search("lasku")
        #expect(store.activeQuery == "lasku")
    }

    @Test func createViewSelectsIt() async {
        let store = await makeStore()
        await store.createView(name: "Laskut")
        #expect(store.views.last?.name == "Laskut")
        #expect(store.views.last?.query == "in:inbox")
        #expect(store.activeViewID == store.views.last?.id)
    }

    @Test func duplicateViewCopiesFiltersWithNewIDs() async {
        var views = ViewsConfigStore.defaults
        views[0].filters = [MailFilter(.from("matti"))]
        try? viewsStore.save(views)
        let store = await makeStore()
        await store.duplicateView(store.views[0].id)
        #expect(store.views.count == 5)
        #expect(store.views[1].name == "Inbox (kopio)")
        #expect(store.views[1].effectiveQuery == store.views[0].effectiveQuery)
        #expect(store.views[1].id != store.views[0].id)
    }

    @Test func moveViewReorders() async {
        let store = await makeStore()
        let names = store.views.map(\.name)
        await store.moveView(store.views[3].id, before: store.views[0].id)
        #expect(store.views.map(\.name) == [names[3], names[0], names[1], names[2]])
        await store.moveView(store.views[0].id, before: nil)
        #expect(store.views.map(\.name) == [names[0], names[1], names[2], names[3]])
    }

    @Test func editViewRenamesAndDeleteKeepsOne() async {
        let store = await makeStore()
        await store.editView(store.views[1].id) { $0.name = "Tärkeät 2"; $0.icon = "flag" }
        #expect(store.views[1].name == "Tärkeät 2")
        #expect(store.views[1].icon == "flag")
        for view in store.views { await store.deleteView(view.id) }
        #expect(store.views.count == 1)
    }
}
