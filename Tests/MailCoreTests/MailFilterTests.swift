import Foundation
import Testing
@testable import MailCore

@Suite struct MailFilterTests {
    func q(_ filters: MailFilter...) -> String { MailFilter.query(base: "in:inbox", filters) }

    @Test func noFiltersKeepsBase() {
        #expect(MailFilter.query(base: "in:inbox", []) == "in:inbox")
    }

    @Test func textFilters() {
        #expect(q(MailFilter(.from("matti"))) == "in:inbox from:matti")
        #expect(q(MailFilter(.from("Matti Meikäläinen"))) == "in:inbox from:\"Matti Meikäläinen\"")
        #expect(q(MailFilter(.to("anna@x.fi"))) == "in:inbox {to:anna@x.fi cc:anna@x.fi}")
        #expect(q(MailFilter(.subject("lasku"))) == "in:inbox subject:lasku")
        #expect(q(MailFilter(.contains("tarjous 2026"))) == "in:inbox \"tarjous 2026\"")
    }

    @Test func quotesInValueAreDropped() {
        #expect(q(MailFilter(.subject("\"a b\""))) == "in:inbox subject:\"a b\"")
    }

    @Test func emptyTextAddsNothing() {
        #expect(q(MailFilter(.from("  "))) == "in:inbox")
    }

    @Test func negation() {
        #expect(q(MailFilter(.from("matti"), negated: true)) == "in:inbox -from:matti")
        #expect(q(MailFilter(.to("a"), negated: true)) == "in:inbox -{to:a cc:a}")
        #expect(q(MailFilter(.unread, negated: true)) == "in:inbox -is:unread")
    }

    @Test func toggles() {
        #expect(q(MailFilter(.unread), MailFilter(.starred)) == "in:inbox is:unread is:starred")
        #expect(q(MailFilter(.read)) == "in:inbox is:read")
        #expect(q(MailFilter(.important)) == "in:inbox is:important")
        #expect(q(MailFilter(.calendarInvite)) == "in:inbox filename:ics")
    }

    @Test func attachments() {
        #expect(q(MailFilter(.attachment(nil))) == "in:inbox has:attachment")
        #expect(q(MailFilter(.attachment(.pdf))) == "in:inbox filename:pdf")
        #expect(q(MailFilter(.attachment(.image))).hasPrefix("in:inbox {filename:jpg "))
        #expect(q(MailFilter(.attachment(nil), negated: true)) == "in:inbox -has:attachment")
    }

    @Test func dates() {
        #expect(q(MailFilter(.date(.lastDays(7)))) == "in:inbox newer_than:7d")
        #expect(q(MailFilter(.date(.lastDays(30)), negated: true)) == "in:inbox older_than:30d")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let a = utc.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let b = utc.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let between = MailFilter.query(base: "in:inbox", [MailFilter(.date(.between(after: a, before: b)))], calendar: utc)
        #expect(between == "in:inbox after:2026/01/05 before:2026/02/01")
        let outside = MailFilter.query(base: "in:inbox", [MailFilter(.date(.between(after: a, before: b)), negated: true)], calendar: utc)
        #expect(outside == "in:inbox {before:2026/01/05 after:2026/02/01}")
        let onlyAfter = MailFilter.query(base: "x", [MailFilter(.date(.between(after: a, before: nil)))], calendar: utc)
        #expect(onlyAfter == "x after:2026/01/05")
    }

    @Test func baseWithOrIsGrouped() {
        let query = MailFilter.query(base: "category:promotions OR category:updates", [MailFilter(.unread)])
        #expect(query == "(category:promotions OR category:updates) is:unread")
    }

    @Test func viewEffectiveQueryAndLegacyDecoding() throws {
        var view = MailView(name: "Matti", query: "in:inbox")
        view.filters = [MailFilter(.from("matti"))]
        #expect(view.effectiveQuery == "in:inbox from:matti")

        let data = try JSONEncoder().encode([view])
        #expect(try JSONDecoder().decode([MailView].self, from: data) == [view])

        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Inbox","query":"in:inbox"}]"#
        let decoded = try JSONDecoder().decode([MailView].self, from: Data(legacy.utf8))
        #expect(decoded[0].filters.isEmpty)
        #expect(decoded[0].effectiveQuery == "in:inbox")
    }
}
