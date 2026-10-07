#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#endif
import MailCore
import SwiftUI
import WebKit

/// Shows a rendered thread. Mail scripts are blocked by the iframe sandbox and the document's CSP
/// (see ThreadHTML); remote loads are blocked by the CSP and a content rule list unless allowed.
struct ThreadWebView: PlatformViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    let onAttachment: (ThreadHTML.AttachmentAction) -> Void
    let onMailto: (String) -> Void
    var focusRequest = 0
    /// Scales the whole rendered thread (text size setting on the Mac); 1 on iOS.
    var pageZoom: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Must be on: WebKit does not load srcdoc iframes otherwise (mail bodies would be blank).
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        #if os(iOS)
        config.userContentController.addUserScript(WKUserScript(source: Self.viewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.dataDetectorTypes = [.link, .phoneNumber]
        #endif
        config.userContentController.addUserScript(WKUserScript(source: Self.resizeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onAttachment = onAttachment
        coordinator.onMailto = onMailto
        #if os(macOS)
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            webView.window?.makeFirstResponder(webView)
        }
        #endif
        // Before the reload guard: a zoom change alone must not reload the thread.
        // The refit does not rely on the zoom firing a resize event.
        if webView.pageZoom != pageZoom {
            webView.pageZoom = pageZoom
            webView.evaluateJavaScript("window.mak8rFitAll && window.mak8rFitAll()")
        }
        guard coordinator.loadedHTML != html || coordinator.loadedRemote != allowRemoteContent else { return }
        coordinator.loadedHTML = html
        coordinator.loadedRemote = allowRemoteContent
        let html = self.html
        let allowRemote = allowRemoteContent
        Task { @MainActor in
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            if !allowRemote, let rules = await RemoteContentBlocker.ruleList() {
                controller.add(rules)
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        var loadedRemote = false
        var focusRequest = 0
        var onAttachment: (ThreadHTML.AttachmentAction) -> Void = { _ in }
        var onMailto: (String) -> Void = { _ in }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let decision = LinkPolicy.decide(
                url,
                isUserClick: action.navigationType == .linkActivated,
                fromMainFrame: action.sourceFrame.isMainFrame
            )
            switch decision {
            case .allow:
                return .allow
            case .cancel:
                return .cancel
            case .openInBrowser:
                ThreadWebView.openExternally(url)
                return .cancel
            case .compose(let address):
                onMailto(address)
                return .cancel
            case .attachment(let attachment):
                onAttachment(attachment)
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                ThreadWebView.openExternally(url)
            }
            return nil
        }
    }

    @MainActor
    static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Fits the thread to the phone's width; the rendered document is written for a desktop window.
    static let viewportScript = """
    (function () {
      var m = document.createElement('meta');
      m.name = 'viewport';
      m.content = 'width=device-width, initial-scale=1';
      document.head.appendChild(m);
    })();
    """

    /// Sizes each mail iframe to its content. The root's scrollHeight never drops below the
    /// iframe's own height, so the iframe is collapsed before measuring (otherwise it could grow
    /// but never shrink, e.g. after a smaller page zoom); the page's scroll position is kept.
    static let resizeScript = """
    (function () {
      function fit(f) {
        try {
          var d = f.contentDocument;
          if (d && d.documentElement) {
            var x = window.scrollX, y = window.scrollY;
            f.style.height = '0px';
            f.style.height = d.documentElement.scrollHeight + 'px';
            if (window.scrollX !== x || window.scrollY !== y) { window.scrollTo(x, y); }
          }
        } catch (e) {}
      }
      function all() { document.querySelectorAll('iframe.html').forEach(fit); }
      window.mak8rFitAll = all;
      document.querySelectorAll('iframe.html').forEach(function (f) {
        f.addEventListener('load', function () { fit(f); setTimeout(function () { fit(f); }, 300); setTimeout(function () { fit(f); }, 1500); });
      });
      document.addEventListener('toggle', function () { setTimeout(all, 0); }, true);
      window.addEventListener('resize', all);
      all();
    })();
    """
}

@MainActor
enum RemoteContentBlocker {
    private static var cached: WKContentRuleList?

    static func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mak8r-block-remote-v2", encodedContentRuleList: ThreadHTML.remoteContentRules)
        cached = list
        return list
    }
}
