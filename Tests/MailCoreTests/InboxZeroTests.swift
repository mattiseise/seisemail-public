import Foundation
import Testing
@testable import MailCore

@Suite struct InboxZeroTests {
    @Test func sortingLabelNames() {
        #expect(SeiseLabels.Sorting.prefix == "Lajittelu/")
        #expect(SeiseLabels.Sorting.all == ["Lajittelu/Uutiskirjeet", "Lajittelu/Ilmoitukset", "Lajittelu/Kuitit",
                                            "Lajittelu/Ihmiset", "Lajittelu/Vaatii toimenpidettä"])
        #expect(SeiseLabels.spam == "SPAM")
        #expect(SeiseLabels.sent == "SENT")
        #expect(SeiseLabels.draft == "DRAFT")
    }

    @Test func labelTokenHyphenatesAndLowercases() {
        #expect(SearchSyntax.labelToken("Lajittelu/Uutiskirjeet") == "lajittelu-uutiskirjeet")
        #expect(SearchSyntax.labelToken("Lajittelu/Vaatii toimenpidettä") == "lajittelu-vaatii-toimenpidettä")
        #expect(SearchSyntax.labelToken("Torkku") == "torkku")
        #expect(SearchSyntax.label("Lajittelu/Kuitit") == "label:lajittelu-kuitit")
    }

    @Test func defaultQueryExact() {
        #expect(InboxZero.defaultQuery == "in:inbox -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset")
        #expect(InboxZero.excludedFromDefault == [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications])
    }

    @Test func sortingViewsMatchConventions() {
        let views = InboxZero.sortingViews
        #expect(views.map(\.labelName) == SeiseLabels.Sorting.all)
        #expect(views.map(\.title) == ["Uutiskirjeet", "Ilmoitukset", "Kuitit", "Ihmiset", "Vaatii toimenpidettä"])
        #expect(views.map(\.query) == [
            "in:inbox label:lajittelu-uutiskirjeet",
            "in:inbox label:lajittelu-ilmoitukset",
            "in:inbox label:lajittelu-kuitit",
            "in:inbox label:lajittelu-ihmiset",
            "in:inbox label:lajittelu-vaatii-toimenpidettä",
        ])
        #expect(InboxZero.sortingQuery("Lajittelu/Kuitit") == "in:inbox label:lajittelu-kuitit")
    }

    @Test func hasPositiveTerm() {
        let cases: [(String?, Bool)] = [
            ("in:inbox", true),
            ("IN:INBOX is:unread", true),
            ("(in:inbox OR is:starred) from:x", true),
            ("{in:inbox is:starred}", true),
            (InboxZero.defaultQuery, true),
            ("  in:inbox  ", true),
            ("-in:inbox", false),
            ("(-in:inbox)", false),
            ("-IN:INBOX foo", false),
            ("is:starred", false),
            ("label:torkku", false),
            ("in:inboxes", false),
            ("subject:in:inbox", false),
            ("", false),
            (nil, false),
        ]
        for (query, expected) in cases {
            #expect(SearchSyntax.hasPositiveTerm(query, "in:inbox") == expected, Comment(rawValue: query ?? "nil"))
        }
    }

    @Test func serverQueryDropsExclusionsOfMissingLabels() {
        let news = SeiseLabels.Sorting.newsletters, notes = SeiseLabels.Sorting.notifications
        let q = InboxZero.defaultQuery
        #expect(InboxZero.serverQuery(q, missingLabels: []) == q)
        #expect(InboxZero.serverQuery(q, missingLabels: [news, notes]) == "in:inbox")
        #expect(InboxZero.serverQuery(q, missingLabels: [news]) == "in:inbox -label:lajittelu-ilmoitukset")
        #expect(InboxZero.serverQuery("in:inbox  -LABEL:Lajittelu-Uutiskirjeet is:unread", missingLabels: [news])
                == "in:inbox is:unread")
        // A positive term stays: without the label nothing matches it, which is the right answer.
        #expect(InboxZero.serverQuery("in:inbox label:lajittelu-uutiskirjeet", missingLabels: [news])
                == "in:inbox label:lajittelu-uutiskirjeet")
        #expect(InboxZero.serverQuery("is:starred", missingLabels: [news, notes]) == "is:starred")
    }

    @Test func snoozedViewQueryFollowsScheme() {
        #expect(SnoozeLabelScheme.standard.viewQuery == "label:torkku")
        #expect(SnoozeLabelScheme(marker: "Snoozed", timePrefix: "Snooze/").viewQuery == "label:snoozed")
    }
}
