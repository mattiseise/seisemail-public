import MailCore
import SwiftUI

/// Side peek: the open thread slides in from the right over the list.
struct PeekView: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    let width: CGFloat
    let onResize: (CGFloat) -> Void
    @State private var dragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            VStack(spacing: 0) {
                PeekToolbar(store: store)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                content
            }
            .background(Theme.background)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        if dragStart == nil { dragStart = width }
                        onResize(start - value.translation.width)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    @ViewBuilder
    private var content: some View {
        if let thread = store.openThread {
            let allowImages = app.imagesAllowed(in: thread)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.subject.isEmpty ? "(ei aihetta)" : thread.subject)
                        .font(Theme.font(16, weight: .semibold))
                        .textSelection(.enabled)
                    Spacer()
                    MeetingJoinSlot(thread: thread)
                    if !allowImages, thread.messages.contains(where: { $0.htmlBody != nil }) {
                        Button("Näytä kuvat") { app.remoteContentAllowed.insert(thread.id) }
                            .buttonStyle(.plain)
                            .font(Theme.meta)
                            .foregroundStyle(Theme.accent)
                        if app.settings.app.remoteImages == .allowFromSenders, let sender = app.imageSender(of: thread) {
                            Button("Näytä aina kuvat lähettäjältä \(sender)") { app.trustImages(from: sender) }
                                .buttonStyle(.plain)
                                .font(Theme.meta)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 10)
                ThreadWebView(
                    html: ThreadHTML.document(for: thread, me: store.me, allowRemoteContent: allowImages),
                    allowRemoteContent: allowImages,
                    onAttachment: { action in
                        Task { await AttachmentActions.perform(action, thread: thread, app: app) }
                    },
                    onMailto: { address in
                        guard var draft = app.draft(for: .new) else { return }
                        draft.to = address
                        app.presentCompose(draft)
                    },
                    focusRequest: app.detailFocusRequest,
                    pageZoom: Theme.zoom
                )
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
