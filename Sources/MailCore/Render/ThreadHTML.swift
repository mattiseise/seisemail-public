import Foundation

/// Renders a thread as one HTML document. Mail HTML lives in sandboxed srcdoc iframes without
/// `allow-scripts`, and a Content-Security-Policy (inherited by those iframes) forbids scripts and,
/// unless allowed, remote images, fonts and media. WebKit only loads srcdoc iframes when page
/// JavaScript is enabled, so these two layers — not the WKWebView setting — keep mail scripts off.
public enum ThreadHTML {
    public static let attachmentScheme = "mak8r-attachment"

    /// WKContentRuleList blocking remote loads; a second layer under the CSP.
    /// WebKit's url-filter regex does not support disjunctions, so each scheme is its own rule.
    public static let remoteContentRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#

    static func contentSecurityPolicy(allowRemoteContent: Bool) -> String {
        var directives = ["script-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"]
        if !allowRemoteContent {
            directives += ["img-src data: cid:", "style-src 'unsafe-inline'", "font-src 'none'", "media-src 'none'"]
        }
        return directives.joined(separator: "; ")
    }

    public struct AttachmentAction: Equatable, Sendable {
        public enum Kind: String, Sendable { case preview, save }
        public var kind: Kind
        public var messageID: String
        public var partID: String
    }

    public static func attachmentAction(from url: URL) -> AttachmentAction? {
        guard url.scheme == attachmentScheme, let host = url.host(), let kind = AttachmentAction.Kind(rawValue: host) else { return nil }
        let parts = url.path().split(separator: "/", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count == 2 else { return nil }
        return AttachmentAction(kind: kind, messageID: parts[0], partID: parts[1])
    }

    public static func document(for thread: MailThread, me: String?, timeZone: TimeZone = .current, allowRemoteContent: Bool = false) -> String {
        let lastIndex = thread.messages.indices.last
        let body = thread.messages.enumerated().map { index, message in
            render(message, open: index == lastIndex || message.isUnread, me: me, timeZone: timeZone)
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemoteContent: allowRemoteContent))"><meta name="color-scheme" content="light dark"><style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }

    private static func render(_ m: Message, open: Bool, me: String?, timeZone: TimeZone) -> String {
        let isMe = me.map { m.from?.matches($0) ?? false } ?? false
        let name = isMe ? "Minä" : (m.from?.displayName ?? "Tuntematon")
        let address = isMe ? "" : (m.from.map { "&lt;\(HTMLText.escape($0.email))&gt;" } ?? "")
        var meta: [String] = []
        if !m.to.isEmpty { meta.append("Vastaanottaja: \(HTMLText.escape(m.to.map(\.displayName).joined(separator: ", ")))") }
        if !m.cc.isEmpty { meta.append("Kopio: \(HTMLText.escape(m.cc.map(\.displayName).joined(separator: ", ")))") }

        let content: String
        if let html = m.htmlBody {
            content = "<iframe sandbox=\"allow-same-origin allow-popups allow-top-navigation-by-user-activation\" class=\"html\" scrolling=\"no\" srcdoc=\"\(HTMLText.escape(html))\"></iframe>"
        } else {
            content = "<div class=\"text\">\(linkify(HTMLText.escape(m.textBody ?? m.snippet)))</div>"
        }

        let attachments = m.attachments.isEmpty ? "" : "<ul class=\"attachments\">" + m.attachments.map { a in
            let path = "\(pathComponent(a.messageID))/\(pathComponent(a.partID))"
            return "<li><span class=\"clip\">📎</span> <span class=\"name\">\(HTMLText.escape(a.filename))</span> <span class=\"size\">\(formatSize(a.size))</span> "
                + "<a href=\"\(attachmentScheme)://preview/\(path)\">Esikatsele</a> · <a href=\"\(attachmentScheme)://save/\(path)\">Tallenna</a></li>"
        }.joined() + "</ul>"

        return """
        <details\(open ? " open" : "") class="msg"><summary><span class="avatar">\(HTMLText.escape(String(name.prefix(1)).uppercased()))</span><span class="from">\(HTMLText.escape(name))</span> <span class="addr">\(address)</span><span class="date">\(ComposeFactory.finnishDate(m.date, timeZone: timeZone))</span><div class="snippet">\(HTMLText.escape(m.snippet))</div></summary>
        <div class="meta">\(meta.joined(separator: " · "))</div>\(content)\(attachments)</details>
        """
    }

    private static func pathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    static func linkify(_ escaped: String) -> String {
        escaped.replacing(/https?:\/\/(?:[^\s<>"&]|&amp;)+/) { match -> String in
            var url = String(match.0)
            var trailing = ""
            while let last = url.last, ".,!?;:)".contains(last) {
                trailing = String(last) + trailing
                url.removeLast()
            }
            return "<a href=\"\(url)\">\(url)</a>\(trailing)"
        }
    }

    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) t" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) kt" }
        return String(format: "%.1f Mt", Double(bytes) / 1_048_576).replacingOccurrences(of: ".", with: ",")
    }

    static let css = """
    :root { color-scheme: light dark; --fg: #1F1F1F; --muted: #8C8C8C; --line: #EDEDEB; --bg: #FFFFFF; --link: #9A5145; --chip: #EBEBE9; }
    @media (prefers-color-scheme: dark) { :root { --fg: #E6E6E6; --muted: #7D7D7D; --line: #242426; --bg: #0F0F10; --link: #C46A5A; --chip: #232325; } }
    html, body { margin: 0; background: var(--bg); color: var(--fg); font: 13.5px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; }
    body { padding: 4px 24px 40px; }
    a { color: var(--link); }
    details.msg { border-bottom: 1px solid var(--line); padding: 14px 0; }
    details.msg:last-child { border-bottom: none; }
    summary { list-style: none; cursor: default; }
    summary::-webkit-details-marker { display: none; }
    .avatar { display: inline-flex; align-items: center; justify-content: center; width: 24px; height: 24px; border-radius: 6px; background: var(--chip); color: var(--muted); font-size: 11px; font-weight: 600; margin-right: 10px; vertical-align: middle; }
    .from { font-weight: 500; }
    .addr { color: var(--muted); font-size: 12px; }
    .date { float: right; color: var(--muted); font-size: 12px; }
    .snippet { color: var(--muted); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin: 2px 0 0 36px; }
    details[open] .snippet { display: none; }
    .meta { color: var(--muted); font-size: 12px; margin: 0 0 16px 36px; }
    .text { white-space: pre-wrap; word-wrap: break-word; }
    iframe.html { width: 100%; border: 0; min-height: 60px; background: #fff; border-radius: 6px; display: block; }
    ul.attachments { list-style: none; padding: 0; margin: 14px 0 0; font-size: 13px; }
    ul.attachments li { padding: 6px 10px; border: 1px solid var(--line); border-radius: 6px; margin-top: 6px; }
    .size { color: var(--muted); margin-right: 8px; }
    """
}
