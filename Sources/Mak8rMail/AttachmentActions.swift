import AppKit
import MailCore
import os
import Quartz

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
            let file = try await AttachmentFetch.file(for: attachment, api: api)
            switch action.kind {
            case .preview:
                QuickLook.shared.show(file)
            case .save:
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.lastPathComponent
                panel.directoryURL = URL.downloadsDirectory
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try Data(contentsOf: file).write(to: url, options: .atomic)
                    } catch {
                        throw AttachmentFetch.Failure.write
                    }
                }
            }
        } catch {
            log.error("\(action.kind.rawValue, privacy: .public) \(attachment.mimeType, privacy: .public) \(attachment.size, privacy: .public) B: \(String(describing: error), privacy: .public)")
            app.store?.toast = AttachmentFetch.message(for: error)
        }
    }
}

@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
