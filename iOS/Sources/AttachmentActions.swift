import MailCore
import os
import QuickLook
import UIKit

/// Opens an attachment in Quick Look; its share button saves it to Files or sends it on.
@MainActor
enum AttachmentActions {
    private static let log = Logger(subsystem: "fi.mak8r.mail", category: "attachments")

    static func perform(_ action: ThreadHTML.AttachmentAction, thread: MailThread, app: AppModel) async {
        guard let attachment = AttachmentFetch.attachment(for: action, in: thread) else {
            app.store?.toast = AttachmentFetch.message(for: AttachmentFetch.Failure.notFound)
            return
        }
        guard let api = app.api else {
            app.store?.toast = AttachmentFetch.message(for: GmailError.offline)
            return
        }
        do {
            // Cached on disk: opening the same attachment again costs no Gmail quota.
            QuickLookPresenter.shared.show(try await AttachmentFetch.file(for: attachment, api: api))
        } catch {
            log.error("\(attachment.mimeType, privacy: .public) \(attachment.size, privacy: .public) B: \(String(describing: error), privacy: .public)")
            app.store?.toast = AttachmentFetch.message(for: error)
        }
    }
}

@MainActor
final class QuickLookPresenter: NSObject, QLPreviewControllerDataSource {
    static let shared = QuickLookPresenter()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        let controller = QLPreviewController()
        controller.dataSource = self
        topViewController()?.present(controller, animated: true)
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (url ?? URL(fileURLWithPath: "/")) as NSURL }
    }

    private func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
