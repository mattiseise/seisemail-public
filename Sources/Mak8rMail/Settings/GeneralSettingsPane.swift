import MailCore
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Käynnistä sisäänkirjautumisen yhteydessä", isOn: Binding(
                    get: { app.launchAtLogin },
                    set: { app.launchAtLogin = $0 }
                ))
                Toggle("Näytä valikkorivillä", isOn: $settings.app.menuBarIcon)
                Text("Sovellus jää valikkoriville, kun ikkuna suljetaan, ja ilmoittaa uusista viesteistä.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Ilmoitukset") {
                Toggle("Lukemattomien määrä Dockissa", isOn: $settings.app.dockBadge)
                Toggle("Ilmoitusääni", isOn: $settings.app.notificationSound)
                Picker("Ääni", selection: $settings.app.notificationSoundName) {
                    ForEach(AppSettings.notificationSoundChoices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!settings.app.notificationSound)
                .onChange(of: settings.app.notificationSoundName) { _, name in Notifier.play(name) }
                Text("Ilmoitukset voi poistaa käytöstä tileittäin Tilit-välilehdellä.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextSizeSection()
            Section("Inbox 0") {
                Toggle("Päivän kuva Wikimedia Commonsista", isOn: $settings.app.inboxZeroDailyPhoto)
                Text("Hakee Wikimedia Commonsin päivän kuvan kerran päivässä. Kun asetus on pois päältä tai päivän kuva "
                     + "ei sovi, näytetään sovelluksen omia luontokuvia.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Versio", value: MailCoreInfo.version)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
