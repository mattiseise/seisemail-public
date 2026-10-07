import MailCore
import SwiftUI

struct ReadingSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Etäkuvat", selection: $settings.app.remoteImages) {
                    Text("Estä aina").tag(RemoteImagesPolicy.block)
                    Text("Näytä luotetuilta lähettäjiltä").tag(RemoteImagesPolicy.allowFromSenders)
                    Text("Näytä aina").tag(RemoteImagesPolicy.always)
                }
                Text("Etäkuvilla lähettäjä voi nähdä, milloin avasit viestin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.app.remoteImages == .allowFromSenders, let me = app.me {
                    let trusted = settings.account(me).trustedImageSenders
                    if trusted.isEmpty {
                        Text("Ei luotettuja lähettäjiä. Lisää lähettäjä viestin ”Näytä aina kuvat lähettäjältä” -painikkeella.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trusted, id: \.self) { sender in
                        HStack {
                            Text(sender)
                            Spacer()
                            Button("Poista") {
                                settings.updateAccount(me) { $0.trustedImageSenders.removeAll { $0 == sender } }
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Merkitse luetuksi", selection: $settings.app.markRead) {
                    Text("Heti").tag(MarkReadPolicy.immediately)
                    Text("2 sekunnin kuluttua").tag(MarkReadPolicy.afterDelay)
                    Text("Ei koskaan").tag(MarkReadPolicy.never)
                }
                Picker("Arkistoinnin jälkeen", selection: $settings.app.afterArchive) {
                    Text("Seuraava viesti").tag(AfterArchive.next)
                    Text("Edellinen viesti").tag(AfterArchive.previous)
                    Text("Takaisin listaan").tag(AfterArchive.list)
                }
                Toggle("Avaa ensimmäinen ketju, kun sovellus käynnistyy", isOn: $settings.app.openFirstThread)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
