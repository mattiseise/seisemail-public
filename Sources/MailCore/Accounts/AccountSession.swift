import Foundation

/// Everything for one Gmail account: sign-in, API client, mail state, inbox monitor and sending.
@MainActor
public final class AccountSession: Identifiable {
    public let email: String
    public let auth: GoogleAuth?
    public let api: GmailAPI
    public let store: MailStore
    public let monitor: InboxMonitor
    public let composer: ComposeController

    public nonisolated var id: String { email }

    public init(email: String, auth: GoogleAuth?, api: GmailAPI, viewsStore: ViewsConfigStore, drafts: DraftStore) {
        self.email = email.lowercased()
        self.auth = auth
        self.api = api
        self.store = MailStore(api: api, viewsStore: viewsStore)
        self.monitor = InboxMonitor(api: api)
        self.composer = ComposeController(api: api, drafts: drafts)
    }

    /// Production wiring: token in the account's own Keychain entry, views in its own file.
    public static func live(email: String, config: OAuthConfig, drafts: DraftStore) -> AccountSession {
        let auth = GoogleAuth(config: config, store: KeychainTokenStore.forAccount(email), transport: URLSessionTransport())
        return AccountSession(
            email: email,
            auth: auth,
            // One quota and cache stack per account: Gmail's per-minute quota is per user.
            api: LiveGmailClient(auth: auth, transport: GmailTransports.live()),
            viewsStore: ViewsConfigStore(fileURL: ViewsConfigStore.url(for: email)),
            drafts: drafts
        )
    }
}
