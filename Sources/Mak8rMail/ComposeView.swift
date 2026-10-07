import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// Shows the composer as a bottom-right card, a minimized bar, or a side peek.
struct ComposeHost: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let dock = app.composeDock
        if let session = dock.current {
            Group {
                switch dock.mode {
                case .card:
                    ComposeView(session: session)
                        .frame(width: 520, height: 540)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                        .padding(16)
                case .minimized:
                    MinimizedCompose(session: session)
                        .padding(16)
                case .peek:
                    HStack(spacing: 0) {
                        Hairline(vertical: true)
                        ComposeView(session: session)
                            .background(Theme.background)
                    }
                    .frame(width: 580)
                    .frame(maxHeight: .infinity)
                }
            }
            .id(session.draft.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Collapsed composer: just its title bar in the corner.
private struct MinimizedCompose: View {
    @Environment(AppModel.self) private var app
    let session: ComposeSession

    var body: some View {
        HStack(spacing: 8) {
            Text(session.draft.subject.isEmpty ? "Uusi viesti" : session.draft.subject)
                .font(Theme.emphasis)
                .lineLimit(1)
            Spacer()
            IconButton(symbol: "chevron.up", help: "Palauta") { app.composeDock.mode = .card }
            IconButton(symbol: "xmark", help: "Sulje ja tallenna luonnokseksi") { app.composeDock.dismiss() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: 320, height: 40)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { app.composeDock.mode = .card }
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ComposeSession
    @State private var showBcc = false
    @State private var error: String?
    @State private var importing = false
    @State private var confirmMissingAttachment = false
    @State private var bodySelection: TextSelection?
    @FocusState private var focus: Field?

    private enum Field { case to, body }

    private var draft: Draft {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }

    private var sending: Bool { session.state == .sending }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            VStack(spacing: 0) {
                senderRow
                field("Vastaanottaja", text: $session.draft.to)
                    .focused($focus, equals: .to)
                field("Kopio", text: $session.draft.cc, trailing: showBcc ? nil : AnyView(
                    Button("Piilokopio") { showBcc = true }.buttonStyle(.plain).font(Theme.meta).foregroundStyle(Theme.muted)
                ))
                if showBcc || !draft.bcc.isEmpty { field("Piilokopio", text: $session.draft.bcc) }
                field("Aihe", text: $session.draft.subject)
            }
            TextEditor(text: $session.draft.body, selection: $bodySelection)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focus, equals: .body)
            if !draft.attachments.isEmpty {
                attachmentChips
            }
            Hairline()
            bottomBar
        }
        .foregroundStyle(Theme.text)
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .onAppear {
            focus = draft.to.isEmpty ? .to : .body
            if let failed = app.sendErrors.removeValue(forKey: draft.id) { error = failed }
        }
        .task(id: session.autosaveKey) {
            // Autosave two seconds after the last edit.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            session.autosave()
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(draft.subject.isEmpty ? "Uusi viesti" : draft.subject)
                .font(Theme.emphasis)
                .lineLimit(1)
            Spacer()
            IconButton(symbol: "minus", help: "Pienennä") { app.composeDock.mode = .minimized }
            if app.composeDock.mode == .peek {
                IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Pienempi kortti") { app.composeDock.mode = .card }
            } else {
                IconButton(symbol: "sidebar.right", help: "Laajenna sivupaneeliksi") { app.composeDock.mode = .peek }
            }
            IconButton(symbol: "xmark", help: "Sulje ja tallenna luonnokseksi") { app.composeDock.dismiss() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: Theme.metric(40))
    }

    /// The sending account. Replies stay on the thread's account; a new message can pick another.
    private var senderRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Lähettäjä")
                    .foregroundStyle(Theme.muted)
                    .frame(width: Theme.metric(88, cap: 1.5), alignment: .leading)
                if app.accounts.emails.count > 1, session.draft.threadID == nil {
                    Picker("", selection: Binding(
                        get: { session.draft.account ?? app.me ?? "" },
                        set: { switchAccount(to: $0) }
                    )) {
                        ForEach(app.accounts.emails, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(session.draft.account ?? app.me ?? "")
                }
                Spacer()
                if !signatures.isEmpty || session.draft.signatureID != nil {
                    Picker("Allekirjoitus", selection: Binding(
                        get: { session.draft.signatureID },
                        set: { id in switchSignature(to: signatures.first { $0.id == id }) }
                    )) {
                        Text("Ei allekirjoitusta").tag(UUID?.none)
                        ForEach(signatures) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .fixedSize()
                }
            }
            .font(Theme.body)
            .padding(.horizontal, 16)
            .frame(height: Theme.metric(34))
            Hairline()
        }
    }

    private var accountEmail: String { session.draft.account ?? app.me ?? "" }

    private var signatures: [Signature] { app.settings.account(accountEmail).signatures }

    /// Swaps the signature in the body; an edited one is left alone and the new one goes at the cursor.
    private func switchSignature(to new: Signature?, from account: String? = nil) {
        let oldList = app.settings.account(account ?? accountEmail).signatures
        let old = oldList.first { $0.id == session.draft.signatureID }
        var point: String.Index?
        if case .selection(let range) = bodySelection?.indices {
            point = range.lowerBound.samePosition(in: session.draft.body)
        }
        session.draft.body = SignatureInserter.replace(old, with: new, in: session.draft.body, insertionPoint: point)
        session.draft.signatureID = new?.id
    }

    /// A new message sent from another account takes that account's signature.
    private func switchAccount(to email: String) {
        let previous = accountEmail
        session.draft.account = email
        guard previous != email else { return }
        switchSignature(to: app.settings.account(email).signature(for: .new), from: previous)
    }

    private func field(_ label: String, text: Binding<String>, trailing: AnyView? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(Theme.muted)
                    .frame(width: Theme.metric(88, cap: 1.5), alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                if let trailing { trailing }
            }
            .font(Theme.body)
            .padding(.horizontal, 16)
            .frame(height: Theme.metric(34))
            Hairline()
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(attachment.filename).lineLimit(1)
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .font(Theme.meta)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                if app.settings.app.warnMissingAttachment, AttachmentReminder.shouldWarn(draft) {
                    confirmMissingAttachment = true
                } else {
                    Task { await send() }
                }
            } label: {
                if sending { ProgressView().controlSize(.small) } else { Text("Lähetä") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(sending)
            .help("Lähetä (⌘↩)")
            .confirmationDialog("Mainitsit liitteen, mutta viestissä ei ole liitettä.", isPresented: $confirmMissingAttachment) {
                Button("Lisää liite") { importing = true }
                Button("Lähetä silti") { Task { await send() } }
                Button("Peruuta", role: .cancel) {}
            }
            Button {
                importing = true
            } label: {
                Label("Liite", systemImage: "paperclip")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Lisää liite (⌘⇧A)")
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
            }
            Spacer()
            Button("Hylkää") { app.composeDock.discard() }
                .buttonStyle(.plain)
                .font(Theme.meta)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.metric(48))
    }

    private func addFiles(_ urls: [URL]) {
        let existing = Set(draft.attachments.map(\.id))
        for url in urls where url.isFileURL {
            let item = DraftAttachment.file(url)
            if !existing.contains(item.id) { draft.attachments.append(item) }
        }
    }

    private func send() async {
        error = nil
        do {
            try await app.composeDock.send()
        } catch {
            self.error = AppModel.sendErrorMessage(error)
        }
    }
}
