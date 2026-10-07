import Foundation
import Testing
import WebKit
@testable import MailCore

@Suite struct ThreadHTMLTests {
    func message(_ id: String, text: String? = nil, html: String? = nil, unread: Bool = false, attachments: [MailCore.Attachment] = []) -> Message {
        Message(id: id, threadID: "t", from: MailAddress(name: "Matti <M>", email: "m@x.fi"), replyTo: [],
                to: [MailAddress(name: nil, email: "me@x.fi")], cc: [], date: Date(timeIntervalSince1970: 1_790_322_120),
                subject: "S", snippet: "snip \(id)", textBody: text, htmlBody: html, attachments: attachments,
                labelIDs: unread ? [GmailLabel.unread] : [], messageIDHeader: nil, references: nil)
    }

    func details(_ html: String) -> [String] {
        html.components(separatedBy: "<details").dropFirst().map { String($0) }
    }

    @Test func onlyLastAndUnreadMessagesAreOpen() {
        let thread = MailThread(id: "t", messages: [message("1", text: "a"), message("2", text: "b", unread: true), message("3", text: "c")])
        let parts = details(ThreadHTML.document(for: thread, me: nil))
        #expect(parts.count == 3)
        #expect(!parts[0].hasPrefix(" open"))
        #expect(parts[1].hasPrefix(" open"))
        #expect(parts[2].hasPrefix(" open"))
    }

    @Test func textBodyIsEscapedAndLinkified() {
        let thread = MailThread(id: "t", messages: [message("1", text: "<script>alert(1)</script>\nKatso https://example.fi/a?b=1&c=2 !")])
        let html = ThreadHTML.document(for: thread, me: nil)
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("<a href=\"https://example.fi/a?b=1&amp;c=2\">https://example.fi/a?b=1&amp;c=2</a>"))
    }

    @Test func senderNameIsEscaped() {
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [message("1", text: "x")]), me: nil)
        #expect(html.contains("Matti &lt;M&gt;"))
    }

    @Test func htmlBodyGoesIntoSandboxedSrcdoc() {
        let thread = MailThread(id: "t", messages: [message("1", text: "plain", html: "<p class=\"x\">Hei</p><script>evil()</script>")])
        let html = ThreadHTML.document(for: thread, me: nil)
        #expect(html.contains("<iframe sandbox=\"allow-same-origin allow-popups allow-top-navigation-by-user-activation\""))
        #expect(!html.contains("allow-scripts"))
        #expect(html.contains("srcdoc=\"&lt;p class=&quot;x&quot;&gt;Hei&lt;/p&gt;"))
        #expect(!html.contains("<p class=\"x\">"))
        #expect(!html.contains("plain")) // html preferred over text
    }

    @Test func attachmentLinksUseScheme() {
        let a = Attachment(messageID: "m1", partID: "0.1", attachmentID: "a1", filename: "raportti äö.pdf", mimeType: "application/pdf", size: 2048)
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [message("m1", text: "x", attachments: [a])]), me: nil)
        #expect(html.contains("href=\"mak8r-attachment://preview/m1/0.1\""))
        #expect(html.contains("href=\"mak8r-attachment://save/m1/0.1\""))
        #expect(html.contains("raportti äö.pdf"))
        #expect(html.contains("2 kt"))
    }

    @Test func parsesAttachmentURL() {
        let url = URL(string: "mak8r-attachment://save/m1/0.1")!
        #expect(ThreadHTML.attachmentAction(from: url) == ThreadHTML.AttachmentAction(kind: .save, messageID: "m1", partID: "0.1"))
        #expect(ThreadHTML.attachmentAction(from: URL(string: "https://x.fi")!) == nil)
    }

    @Test func showsMeInsteadOfOwnAddress() {
        var m = message("1", text: "x")
        m.from = MailAddress(name: "Maija", email: "Me@x.fi")
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [m]), me: "me@x.fi")
        #expect(html.contains(">Minä<"))
    }

    @Test func sandboxAllowsLinkPopupsButNotScripts() {
        let thread = MailThread(id: "t", messages: [message("1", html: "<a href=\"https://x.fi\" target=\"_blank\">x</a>")])
        let html = ThreadHTML.document(for: thread, me: nil)
        #expect(html.contains("sandbox=\"allow-same-origin allow-popups allow-top-navigation-by-user-activation\""))
        #expect(!html.contains("allow-scripts"))
        #expect(!html.contains("allow-forms"))
    }

    @Test func linkifyStopsAtEscapedBrackets() {
        #expect(ThreadHTML.linkify(HTMLText.escape("Unsubscribe: <https://x.com/a>")) ==
                "Unsubscribe: &lt;<a href=\"https://x.com/a\">https://x.com/a</a>&gt;")
        #expect(ThreadHTML.linkify(HTMLText.escape("\"https://x.com/q?a=1&b=2\"")) ==
                "&quot;<a href=\"https://x.com/q?a=1&amp;b=2\">https://x.com/q?a=1&amp;b=2</a>&quot;")
    }

    func csp(_ html: String) -> String? {
        guard let r = html.range(of: #"<meta http-equiv="Content-Security-Policy" content=""#) else { return nil }
        return String(html[r.upperBound...].prefix { $0 != "\"" })
    }

    @Test func documentBlocksScriptsAndRemoteContentByDefault() throws {
        let policy = try #require(csp(ThreadHTML.document(for: MailThread(id: "t", messages: [message("1", html: "<p>x</p>")]), me: nil)))
        #expect(policy.contains("script-src 'none'"))
        #expect(policy.contains("img-src data: cid:"))
        #expect(policy.contains("style-src 'unsafe-inline'"))
        #expect(policy.contains("form-action 'none'"))
    }

    @Test func documentAllowsRemoteImagesWhenRequested() throws {
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [message("1", html: "<p>x</p>")]), me: nil, allowRemoteContent: true)
        let policy = try #require(csp(html))
        #expect(policy.contains("script-src 'none'"))
        #expect(!policy.contains("img-src"))
    }

    @Test func senderRowHasInitialAvatar() {
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [message("1", text: "x")]), me: nil)
        #expect(html.contains("<span class=\"avatar\">M</span>"))
    }

    @Test func avatarForMeUsesM() {
        var m = message("1", text: "x")
        m.from = MailAddress(name: nil, email: "me@x.fi")
        let html = ThreadHTML.document(for: MailThread(id: "t", messages: [m]), me: "me@x.fi")
        #expect(html.contains("<span class=\"avatar\">M</span>"))
    }

    @Test func cssUsesAppThemeColours() {
        let css = ThreadHTML.css
        #expect(css.contains("--bg: #FFFFFF") && css.contains("--bg: #0F0F10"))
        #expect(css.contains("--fg: #1F1F1F") && css.contains("--fg: #E6E6E6"))
        #expect(css.contains("--line: #EDEDEB") && css.contains("--line: #242426"))
        #expect(css.contains("--link: #9A5145") && css.contains("--link: #C46A5A"))
    }
}

@MainActor
@Suite struct RemoteContentRulesTests {
    @Test func rulesCompileInWebKit() async throws {
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mak8r-test-\(UUID().uuidString)", encodedContentRuleList: ThreadHTML.remoteContentRules)
        #expect(list != nil)
    }
}
