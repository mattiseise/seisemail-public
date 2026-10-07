import Foundation

/// What the reading pane does with a navigation. Anything the mail could trigger without a click
/// (iframes, refreshes) is refused unless it is a plain web load that the content blocker governs.
public enum LinkPolicy {
    public enum Decision: Equatable, Sendable {
        case allow, cancel, openInBrowser
        case compose(String)
        case attachment(ThreadHTML.AttachmentAction)
    }

    public static func decide(_ url: URL, isUserClick: Bool, fromMainFrame: Bool) -> Decision {
        if let action = ThreadHTML.attachmentAction(from: url) {
            // Attachment links exist only in our own page, never inside mail content.
            return isUserClick && fromMainFrame ? .attachment(action) : .cancel
        }
        switch url.scheme?.lowercased() {
        case "about":
            return .allow
        case "mailto":
            guard isUserClick else { return .cancel }
            let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            return .compose(address.removingPercentEncoding ?? address)
        case "http", "https":
            if isUserClick { return .openInBrowser }
            return fromMainFrame ? .cancel : .allow
        default:
            return .cancel
        }
    }
}
