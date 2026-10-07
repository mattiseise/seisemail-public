import Foundation
import Testing
@testable import MailCore

@Suite struct LinkPolicyTests {
    func decide(_ url: String, click: Bool, mainFrame: Bool = true) -> LinkPolicy.Decision {
        LinkPolicy.decide(URL(string: url)!, isUserClick: click, fromMainFrame: mainFrame)
    }

    @Test func clickedWebLinkOpensInBrowser() {
        #expect(decide("https://example.fi", click: true) == .openInBrowser)
    }

    @Test func automaticWebLoadIsAllowedForBlockerToHandle() {
        #expect(decide("https://tracker.example/p.gif", click: false, mainFrame: false) == .allow)
    }

    @Test func mailtoOnlyOnClick() {
        #expect(decide("mailto:a@b.fi?subject=x", click: true) == .compose("a@b.fi"))
        #expect(decide("mailto:a@b.fi", click: false, mainFrame: false) == .cancel)
    }

    @Test func attachmentLinksOnlyOnClickFromOurPage() {
        let url = "mak8r-attachment://preview/m1/0.1"
        #expect(decide(url, click: true) == .attachment(ThreadHTML.AttachmentAction(kind: .preview, messageID: "m1", partID: "0.1")))
        #expect(decide(url, click: false) == .cancel)
        #expect(decide(url, click: true, mainFrame: false) == .cancel)
    }

    @Test func internalDocumentsAreAllowed() {
        #expect(decide("about:blank", click: false) == .allow)
        #expect(decide("about:srcdoc", click: false, mainFrame: false) == .allow)
    }

    @Test func otherSchemesAreCancelled() {
        #expect(decide("javascript:alert(1)", click: true) == .cancel)
        #expect(decide("file:///etc/passwd", click: true) == .cancel)
    }
}
