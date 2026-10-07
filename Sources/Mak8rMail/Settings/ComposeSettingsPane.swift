import MailCore
import SwiftUI

struct ComposeSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Lähetyksen perumisaika", selection: $settings.app.undoSendSeconds) {
                    ForEach(AppSettings.undoSendChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Pois" : "\(seconds) s").tag(seconds)
                    }
                }
                Text("Lähetetyn viestin voi perua näin monen sekunnin ajan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Varoita, jos liite puuttuu", isOn: $settings.app.warnMissingAttachment)
                Text("Kysyy ennen lähettämistä, jos viestissä mainitaan liite, mutta liitettä ei ole.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Allekirjoitukset asetetaan tileittäin Tilit-välilehdellä.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
