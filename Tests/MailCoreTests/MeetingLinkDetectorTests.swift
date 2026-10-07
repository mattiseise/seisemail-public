import Foundation
import Testing
@testable import MailCore

struct MeetingLinkDetectorTests {
    private func service(_ s: String) -> MeetingService? {
        MeetingLinkDetector.links(inText: s).first?.service
    }

    static func message(_ id: String, text: String? = nil, html: String? = nil) -> Message {
        Message(id: id, threadID: "t", from: nil, replyTo: [], to: [], cc: [], date: .now, subject: "",
                snippet: "", textBody: text, htmlBody: html, attachments: [], labelIDs: [], messageIDHeader: nil, references: nil)
    }

    // MARK: - Join links

    @Test(arguments: [
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM2ZTk4%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%2c%22Oid%22%3a%22def%22%7d", MeetingService.teams),
        ("https://teams.microsoft.com/meet/3712345678901?p=AbCdEf123", .teams),
        ("https://teams.live.com/meet/9876543210123?p=xyz", .teams),
        ("https://zoom.us/j/81234567890?pwd=abc.1", .zoom),
        ("https://us02web.zoom.us/j/81234567890?pwd=abc", .zoom),
        ("https://helsinki.zoom.us/j/612345678", .zoom),
        ("https://zoom.us/my/maija.meikalainen", .zoom),
        ("https://us06web.zoom.us/w/81234567890?tk=x", .zoom),
        ("https://meet.google.com/abc-defg-hij", .googleMeet),
        ("https://meet.google.com/abc-defg-hij?authuser=0&hs=122", .googleMeet),
        ("HTTPS://MEET.GOOGLE.COM/abc-defg-hij", .googleMeet),
        ("meet.google.com/abc-defg-hij", .googleMeet),
        ("Join Zoom Meeting us02web.zoom.us/j/81234567890.", .zoom),
    ])
    func detectsJoinLinks(_ text: String, _ expected: MeetingService) {
        #expect(service(text) == expected)
    }

    @Test(arguments: [
        "https://teams.microsoft.com/l/channel/19%3a123%40thread.tacv2/General?groupId=1",
        "https://teams.microsoft.com/l/chat/0/0?users=a@b.fi",
        "https://teams.microsoft.com/meetingOptions/?organizerId=1&tenantId=2",
        "https://aka.ms/JoinTeamsMeeting?omkt=fi-FI",
        "https://dialin.teams.microsoft.com/abc?id=123",
        "https://zoom.us/download",
        "https://zoom.us/signin",
        "https://explore.zoom.us/en/products/meetings/",
        "https://zoom.us/j/123",
        "https://meet.google.com/",
        "https://meet.google.com/new",
        "https://support.google.com/a/users/answer/9282720",
        "https://tel.meet/abc-defg-hij?pin=1234",
        "Lue lisää osoitteessa zoom.us ja meet.google.com.",
    ])
    func ignoresNonJoinLinks(_ text: String) {
        #expect(service(text) == nil)
    }

    /// Hosts that look like a service, embed it, or smuggle it past a naive check.
    @Test(arguments: [
        "https://zoom.us.evil.example/j/81234567890",
        "https://teams.microsoft.com.evil.example/l/meetup-join/19%3a",
        "https://evil.example/?u=https://zoom.us/j/81234567890",
        "https://evil.example/zoom.us/j/81234567890",
        "https://teams.microsoft.com@evil.example/l/meetup-join/x",
        "https://user:pw@zoom.us/j/81234567890",
        "https://zoom.us:8443/j/81234567890",
        "https://notzoom.us/j/81234567890",
        "https://zoom-us.com/j/81234567890",
        "https://zoom.us./j/81234567890",
        "https://meet.google.com.evil.example/abc-defg-hij",
        "https://meet-google.com/abc-defg-hij",
        "https://gmeet.google.com/abc-defg-hij",
        "https://teams.microsoft.co/l/meetup-join/19%3ameeting_X%40thread.v2/0",
        "https://teams.rnicrosoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0",
        "https://zооm.us/j/81234567890",              // Cyrillic о
        "https://xn--zm-gtba.us/j/81234567890",       // its punycode form
        "https://meet.gооgle.com/abc-defg-hij",       // Cyrillic о
        "javascript:alert(1)//zoom.us/j/81234567890",
        "ftp://zoom.us/j/81234567890",
        // Dot segments: the browser would resolve these to a non-join page on the same host.
        "https://teams.microsoft.com/l/meetup-join/../../dl/launcher/launcher.html?url=x",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0/../../../dl/launcher/launcher.html",
        "https://teams.microsoft.com/meet/3712345678901/../../dl/launcher/launcher.html",
        "https://zoom.us/j/81234567890/%2e%2e/%2e%2e/anything?x=1",
        "https://zoom.us/j/81234567890/%2E%2E/%2E%2E/anything",
        "https://zoom.us/j/81234567890/.%2e/.%2e/anything",
        "https://zoom.us/j/81234567890/./",
        "https://teams.microsoft.com/l/meetup-join/%2e%2e/%2e%2e/dl/launcher/launcher.html",
    ])
    func rejectsLookalikesAndSmuggledHosts(_ text: String) {
        let links = MeetingLinkDetector.links(inText: text)
        // Whatever is found must be a canonical allowlisted host; none of these contain one.
        #expect(links.isEmpty, "\(links)")
    }

    @Test func foreignSchemeYieldsOnlyCanonicalHTTPS() {
        let links = MeetingLinkDetector.links(inText: "javascript:alert('meet.google.com/abc-defg-hij')")
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { $0.url.scheme == "https" && $0.url.host() == "meet.google.com" })
    }

    @Test func httpIsUpgradedFragmentDroppedAndHostLowercased() {
        let link = MeetingLinkDetector.links(inText: "http://Zoom.US/j/81234567890#success").first
        #expect(link?.url.absoluteString == "https://zoom.us/j/81234567890")
    }

    // MARK: - Redirect unwrapping

    @Test func unwrapsSafeLinksAroundTeams() throws {
        let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_X%2540thread.v2%2F0%3Fcontext%3D%257b%257d&data=05%7C02%7C&sdata=abc%3D&reserved=0"
        let link = try #require(MeetingLinkDetector.links(inText: wrapped).first)
        #expect(link.service == .teams)
        #expect(link.url.host() == "teams.microsoft.com")
        #expect(link.url.absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0"))
        #expect(!link.url.absoluteString.contains("safelinks"))
        #expect(!link.url.absoluteString.contains("sdata"))
    }

    @Test func unwrapsTeamsSafeLinksPage() {
        let wrapped = "https://statics.teams.cdn.office.net/evergreen-assets/safelinks/2/atp-safelinks.html?url=https%3A%2F%2Fzoom.us%2Fj%2F81234567890&locale=fi-fi"
        #expect(service(wrapped) == .zoom)
    }

    @Test func unwrapsGoogleRedirectInHTML() throws {
        let html = #"<a href="https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&amp;sa=D&amp;source=calendar&amp;usg=AOvVaw">Liity Google Meetillä</a>"#
        let link = try #require(MeetingLinkDetector.links(inHTML: html).first)
        #expect(link == MeetingLink(service: .googleMeet, url: URL(string: "https://meet.google.com/abc-defg-hij")!))
    }

    @Test func unwrapsProofpointV3() {
        let s = "https://urldefense.com/v3/__https://zoom.us/j/81234567890?pwd=abc__;!!ABC!xyz$"
        #expect(service(s) == .zoom)
    }

    /// Proofpoint v3 swaps characters such as `%` for `*` and stores them base64-encoded after `__;`.
    @Test func unwrapsProofpointV3TeamsLinkWithReplacedCharacters() throws {
        let original = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM2%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d"
        let wrapped = "https://urldefense.com/v3/__https://teams.microsoft.com/l/meetup-join/19*3ameeting_NjM2*40thread.v2/0?context=*7b*22Tid*22*3a*22abc*22*7d__;JSUlJSUlJSUl!!ABC!xyz$"
        let link = try #require(MeetingLinkDetector.links(inText: wrapped).first)
        #expect(link.service == .teams)
        #expect(link.url.absoluteString == original)
        #expect(MeetingLinkDetector.openableURL(for: link) == URL(string: original))
    }

    @Test func unwrapsProofpointV3RunLengthMarkers() throws {
        // "**A" stands for a run of two replaced characters; "QEA" is base64 for "@@".
        let wrapped = "https://urldefense.com/v3/__https://zoom.us/j/81234567890?pwd=a**Ab__;QEA!!ABC!xyz$"
        let link = try #require(MeetingLinkDetector.links(inText: wrapped).first)
        #expect(link.url.absoluteString == "https://zoom.us/j/81234567890?pwd=a@@b")
    }

    @Test(arguments: [
        // Two markers but only one replacement character.
        "https://urldefense.com/v3/__https://teams.microsoft.com/l/meetup-join/19*3ameeting_X*40thread.v2/0__;JQ!!ABC!xyz$",
        // Markers but no replacement characters at all.
        "https://urldefense.com/v3/__https://teams.microsoft.com/l/meetup-join/19*3ameeting_X*40thread.v2/0__;!!ABC!xyz$",
        // Replacement characters left over.
        "https://urldefense.com/v3/__https://teams.microsoft.com/l/meetup-join/19*3ameeting_X%40thread.v2/0__;JSU!!ABC!xyz$",
        // Not base64.
        "https://urldefense.com/v3/__https://teams.microsoft.com/l/meetup-join/19*3ameeting_X%40thread.v2/0__;*!!ABC!xyz$",
    ])
    func brokenProofpointV3IsNotDetected(_ text: String) {
        #expect(MeetingLinkDetector.links(inText: text).isEmpty)
    }

    @Test func doubleWrappedSafeLinksAroundGoogleRedirect() {
        let inner = "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij"
        let s = "https://eur02.safelinks.protection.outlook.com/?url=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&data=1"
        #expect(service(s) == .googleMeet)
    }

    @Test func unwrappingStopsAfterThreeLevels() {
        var s = "https://zoom.us/j/81234567890"
        for _ in 0..<4 {
            s = "https://www.google.com/url?q=" + s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        #expect(service(s) == nil)
        let three = (0..<3).reduce("https://zoom.us/j/81234567890") { url, _ in
            "https://www.google.com/url?q=" + url.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        #expect(service(three) == .zoom)
    }

    @Test(arguments: [
        "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.example%2Fj%2F81234567890",
        "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us.evil.example%2Fj%2F81234567890",
        "https://www.google.com/url?q=javascript:alert(1)",
        "https://safelinks.protection.outlook.com.evil.example/?url=https%3A%2F%2Fzoom.us%2Fj%2F81234567890",
        "https://www.google.com.evil.example/url?q=https://meet.google.com/abc-defg-hij",
    ])
    func wrappersNeverWhitelistTheirTarget(_ text: String) {
        // A fake wrapper is just an unknown host; a real wrapper around an unknown host is rejected.
        #expect(MeetingLinkDetector.links(inText: text).allSatisfy { $0.url.host() != "evil.example" })
        #expect(MeetingLinkDetector.links(inText: text).isEmpty)
    }

    // MARK: - Bodies

    @Test func outlookTeamsInviteHTMLHidesURLBehindText() {
        let html = """
        <div><span>Microsoft Teams <a href="https://aka.ms/JoinTeamsMeeting?omkt=fi-FI">Tarvitsetko apua?</a></span></div>
        <div><a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmE%40thread.v2/0?context=%7b%22Tid%22%3a%221%22%2c%22Oid%22%3a%222%22%7d" target="_blank"><span>Liity kokoukseen nyt</span></a></div>
        <div>Kokouksen tunnus: 312 345 678 901</div>
        <a href="https://teams.microsoft.com/meetingOptions/?organizerId=2&amp;tenantId=1">Kokousasetukset</a>
        """
        let links = MeetingLinkDetector.links(inHTML: html)
        #expect(links.count == 1)
        #expect(links.first?.service == .teams)
    }

    @Test func plainTextAngleBracketsAndTrailingPunctuation() {
        let text = "Join the meeting now<https://teams.microsoft.com/meet/3712345678901?p=AbC>.\nOr Zoom (https://zoom.us/j/81234567890)."
        let links = MeetingLinkDetector.links(inText: text)
        #expect(links.map(\.service) == [.teams, .zoom])
        #expect(links[0].url.absoluteString == "https://teams.microsoft.com/meet/3712345678901?p=AbC")
        #expect(links[1].url.absoluteString == "https://zoom.us/j/81234567890")
    }

    @Test func duplicatesCollapse() {
        let text = "https://meet.google.com/abc-defg-hij ja uudelleen https://meet.google.com/abc-defg-hij"
        #expect(MeetingLinkDetector.links(inText: text).count == 1)
    }

    @Test func newestMessageWins() {
        let thread = MailThread(id: "t", messages: [
            Self.message("1", text: "https://zoom.us/j/81234567890"),
            Self.message("2", text: "Siirretään Meetiin: https://meet.google.com/abc-defg-hij"),
            Self.message("3", text: "Kiitos!"),
        ])
        #expect(MeetingLinkDetector.primaryLink(in: thread)?.service == .googleMeet)
        #expect(MeetingLinkDetector.primaryLink(in: MailThread(id: "t", messages: [Self.message("1", text: "Ei linkkiä")])) == nil)
    }

    // MARK: - Fixtures through MessageParser

    @Test func outlookTeamsInviteWithSafeLinks() throws {
        let thread = MessageParser.thread(try Fixture.thread("thread_full_teams_invite"))
        let link = try #require(MeetingLinkDetector.primaryLink(in: thread))
        #expect(link.service == .teams)
        #expect(link.url.host() == "teams.microsoft.com")
        #expect(link.url.path().hasPrefix("/l/meetup-join/"))
        #expect(MeetingLinkDetector.links(in: thread.messages[0]).count == 1)
    }

    @Test func googleCalendarMeetInvite() throws {
        let thread = MessageParser.thread(try Fixture.thread("thread_full_meet_invite"))
        let link = try #require(MeetingLinkDetector.primaryLink(in: thread))
        #expect(link.service == .googleMeet)
        #expect(link.url.host() == "meet.google.com")
        #expect(link.url.path() == "/abc-defg-hij")
        #expect(MeetingLinkDetector.links(in: thread.messages[0]).allSatisfy { $0.service == .googleMeet })
    }

    @Test func zoomPlainTextInvite() throws {
        let thread = MessageParser.thread(try Fixture.thread("thread_full_zoom_text"))
        let link = try #require(MeetingLinkDetector.primaryLink(in: thread))
        #expect(link == MeetingLink(service: .zoom, url: URL(string: "https://us02web.zoom.us/j/81234567890?pwd=QWxhZGRpbjpvcGVuU2VzYW1l.1")!))
        #expect(MeetingLinkDetector.links(in: thread.messages[0]).count == 1)
    }

    @Test func fixtureSnippetsGiveHints() throws {
        for (name, service) in [("thread_full_teams_invite", MeetingService.teams), ("thread_full_meet_invite", .googleMeet), ("thread_full_zoom_text", .zoom)] {
            let summary = MessageParser.summary(try Fixture.thread(name), me: "matti@example.fi")
            #expect(MeetingLinkDetector.snippetHint(subject: summary.subject, snippet: summary.snippet) == service, "\(name)")
        }
    }

    // MARK: - Snippet hint

    @Test func snippetHintFromURLs() {
        #expect(MeetingLinkDetector.snippetHint(subject: "Kutsu: Tiimipalaveri", snippet: "Liity Google Meetillä meet.google.com/abc-defg-hij Liity puhelimitse") == .googleMeet)
        #expect(MeetingLinkDetector.snippetHint(subject: "Zoom-koulutus", snippet: "Tervetuloa koulutukseen") == nil)
        #expect(MeetingLinkDetector.snippetHint(subject: "Teamsin päivitys", snippet: "Uusi versio teams.microsoft.com sivulla") == nil)
    }

    @Test(arguments: [
        ("Join the meeting now", MeetingService.teams),
        ("________________ Microsoft Teams Need help? Join the meeting now Meeting ID: 312", .teams),
        ("Liity kokoukseen nyt Kokouksen tunnus: 312 345", .teams),
        ("Microsoft Teams -kokous Liity tietokoneella", .teams),
        ("Microsoft Teams meeting Join on your computer", .teams),
        ("Click here to join the meeting", .teams),
        ("Napsauta tätä liittyäksesi kokoukseen", .teams),
        ("Pekka kutsuu sinut Zoom-kokoukseen. Join Zoom Meeting", .zoom),
        ("Sinut on kutsuttu. Join with Google Meet", .googleMeet),
        ("Liity Google Meetillä", .googleMeet),
    ])
    func snippetHintFromInvitePhrases(_ snippet: String, _ expected: MeetingService) {
        #expect(MeetingLinkDetector.snippetHint(subject: "Kutsu", snippet: snippet) == expected)
    }

    /// Conversation about a meeting is not an invite: only template phrases count.
    @Test(arguments: [
        "Pidetäänkö tästä Microsoft Teams -kokous ensi viikolla?",
        "Microsoft Teams meeting cancelled",
        "Muistiinpanot eilisestä Microsoft Teams -kokouksesta liitteenä.",
        "Can we move the Microsoft Teams meeting to Friday?",
    ])
    func snippetHintIgnoresConversationAboutMeetings(_ snippet: String) {
        #expect(MeetingLinkDetector.snippetHint(subject: "Re: budjetti", snippet: snippet) == nil)
    }

    @Test func snippetHintPrefersURLOverPhrase() {
        #expect(MeetingLinkDetector.snippetHint(subject: "", snippet: "Join the meeting now https://zoom.us/j/81234567890") == .zoom)
    }

    // MARK: - Opening

    @Test func openableURLOnlyForAllowlistedHTTPS() throws {
        let link = try #require(MeetingLinkDetector.links(inText: "https://zoom.us/j/81234567890?pwd=x").first)
        #expect(MeetingLinkDetector.openableURL(for: link) == link.url)
        // A hand-built link (never produced by the detector) is refused at the last step too.
        #expect(MeetingLinkDetector.openableURL(for: MeetingLink(service: .zoom, url: URL(string: "http://zoom.us/j/81234567890")!)) == nil)
        #expect(MeetingLinkDetector.openableURL(for: MeetingLink(service: .zoom, url: URL(string: "https://evil.example/j/81234567890")!)) == nil)
        #expect(MeetingLinkDetector.openableURL(for: MeetingLink(service: .teams, url: URL(string: "https://zoom.us/j/81234567890")!)) == nil)
        #expect(MeetingLinkDetector.openableURL(for: MeetingLink(service: .zoom, url: URL(string: "https://www.google.com/url?q=https://zoom.us/j/81234567890")!)) == nil)
    }

    // MARK: - Gmail search (delivery B)

    /// The terms Matti checked against real invites in Gmail on the web on 2026-10-04.
    @Test func searchQueriesUseTheVerifiedTerms() {
        #expect(MeetingLinkDetector.searchQuery(service: .teams, scope: "in:inbox")
            == "(in:inbox) (\"Join the meeting now\" OR \"Liity kokoukseen nyt\")")
        #expect(MeetingLinkDetector.searchQuery(service: .zoom, scope: "in:inbox") == "(in:inbox) \"zoom.us/j\"")
        #expect(MeetingLinkDetector.searchQuery(service: .googleMeet, scope: "in:inbox") == "(in:inbox) \"meet.google.com\"")
    }

    @Test func searchQueryGroupsTheScope() {
        // An OR in the view's own query must not swallow the service terms.
        #expect(MeetingLinkDetector.searchQuery(service: .zoom, scope: " from:a OR from:b ")
            == "(from:a OR from:b) \"zoom.us/j\"")
        #expect(MeetingLinkDetector.searchQuery(service: .zoom, scope: "  ") == "\"zoom.us/j\"")
    }

    // MARK: - Finnish strings

    @Test func finnishLabels() {
        #expect(MeetingService.teams.badgeLabel == "Teams")
        #expect(MeetingService.zoom.badgeLabel == "Zoom")
        #expect(MeetingService.googleMeet.badgeLabel == "Meet")
        #expect(MeetingService.teams.joinTitle == "Liity Teams-kokoukseen")
        #expect(MeetingService.zoom.joinTitle == "Liity Zoom-kokoukseen")
        #expect(MeetingService.googleMeet.joinTitle == "Liity Google Meet -kokoukseen")
        #expect(MeetingService.teams.badgeHelp == "Viestissä on Teams-kokouslinkki")
        #expect(MeetingService.zoom.badgeHelp == "Viestissä on Zoom-kokouslinkki")
        #expect(MeetingService.googleMeet.badgeHelp == "Viestissä on Google Meet -kokouslinkki")
    }
}
