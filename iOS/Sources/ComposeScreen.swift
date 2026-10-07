import MailCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer as a full-height sheet. Closing it keeps the message as a draft.
struct ComposeScreen: View {
    @Environment(AppModel.self) private var app
    @Bindable var session: ComposeSession
    @State private var showCcBcc = false
    @State private var error: String?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmMissingAttachment = false
    @State private var confirmDiscard = false
    @State private var bodySelection: TextSelection?
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject, body }

    private var draft: Draft {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }

    private var sending: Bool { session.state == .sending }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    senderRow
                    field("Vastaanottaja", text: $session.draft.to, focused: .to, keyboard: .emailAddress)
                    if showCcBcc || !draft.cc.isEmpty || !draft.bcc.isEmpty {
                        field("Kopio", text: $session.draft.cc, focused: .cc, keyboard: .emailAddress)
                        field("Piilokopio", text: $session.draft.bcc, focused: .bcc, keyboard: .emailAddress)
                    }
                    field("Aihe", text: $session.draft.subject, focused: .subject, keyboard: .default)
                    if let error {
                        Text(error)
                            .font(Theme.meta)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    if !draft.attachments.isEmpty { attachmentChips }
                    TextEditor(text: $session.draft.body, selection: $bodySelection)
                        .font(Theme.body)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 320)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .focused($focus, equals: .body)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .foregroundStyle(Theme.text)
            .navigationTitle(draft.subject.isEmpty ? "Uusi viesti" : draft.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .tint(Theme.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Sulje") { app.composeDock.dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                if app.settings.app.warnMissingAttachment, AttachmentReminder.shouldWarn(draft) {
                    confirmMissingAttachment = true
                } else {
                    Task { await send() }
                }
            } label: {
                if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            }
            .disabled(sending)
            .accessibilityLabel("Lähetä")
            .confirmationDialog("Mainitsit liitteen, mutta viestissä ei ole liitettä.", isPresented: $confirmMissingAttachment, titleVisibility: .visible) {
                Button("Lisää liite") { importing = true }
                Button("Lähetä silti") { Task { await send() } }
                Button("Peruuta", role: .cancel) {}
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { importing = true } label: { Image(systemName: "paperclip") }
                .accessibilityLabel("Lisää liite")
            PhotosPicker(selection: $photoItems, matching: .images) {
                Image(systemName: "photo")
            }
            .accessibilityLabel("Lisää kuva")
            if !showCcBcc, draft.cc.isEmpty, draft.bcc.isEmpty {
                Button("Kopio") { showCcBcc = true; focus = .cc }
            }
            Spacer()
            Button(role: .destructive) { confirmDiscard = true } label: { Image(systemName: "trash") }
                .accessibilityLabel("Hylkää")
                .confirmationDialog("Hylätäänkö viesti?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Hylkää", role: .destructive) { app.composeDock.discard() }
                }
        }
    }

    /// The sending account and signature. Replies stay on the thread's account; a new message can pick another.
    private var senderRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Lähettäjä")
                    .foregroundStyle(Theme.muted)
                    .frame(width: 96, alignment: .leading)
                if app.accounts.emails.count > 1, session.draft.threadID == nil {
                    Picker("", selection: Binding(
                        get: { session.draft.account ?? app.me ?? "" },
                        set: { switchAccount(to: $0) }
                    )) {
                        ForEach(app.accounts.emails, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else {
                    Text(accountEmail).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !signatures.isEmpty || session.draft.signatureID != nil {
                    Menu {
                        Picker("Allekirjoitus", selection: Binding(
                            get: { session.draft.signatureID },
                            set: { id in switchSignature(to: signatures.first { $0.id == id }) }
                        )) {
                            Text("Ei allekirjoitusta").tag(UUID?.none)
                            ForEach(signatures) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    } label: {
                        Image(systemName: "signature")
                    }
                    .accessibilityLabel("Allekirjoitus")
                }
            }
            .font(Theme.body)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
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

    private func field(_ label: String, text: Binding<String>, focused: Field, keyboard: UIKeyboardType) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 96, alignment: .leading)
                TextField("", text: text)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                    .autocorrectionDisabled(keyboard == .emailAddress)
                    .focused($focus, equals: focused)
            }
            .font(Theme.body)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
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
                    .padding(.vertical, 6)
                    .background(Theme.selected, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Picked files live outside the sandbox and are readable only for a moment, so they are
    /// copied next to the draft; the message is built from the copies when it is sent.
    private var attachmentDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("outgoing/\(draft.id.uuidString)", isDirectory: true)
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try attach(copyOf: url)
            } catch {
                self.error = "Liitteen lisäys epäonnistui: \(url.lastPathComponent)"
            }
        }
    }

    private func attach(copyOf url: URL) throws {
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let copy = attachmentDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        append(.file(copy))
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
                let number = draft.attachments.count + 1
                let url = attachmentDirectory.appendingPathComponent("Kuva \(number).\(ext)")
                try data.write(to: url, options: .atomic)
                append(.file(url))
            } catch {
                self.error = "Kuvan lisäys epäonnistui"
            }
        }
    }

    private func append(_ item: DraftAttachment) {
        if !draft.attachments.contains(where: { $0.id == item.id }) { draft.attachments.append(item) }
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
