import AppKit
import MailCore
import SwiftUI

struct ShortcutSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var recording: MailCommand?
    @State private var rejected: String?
    @State private var monitor: Any?

    private var map: ShortcutMap { ShortcutMap(keys: app.settings.app.shortcuts) }

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutMap.editableCommands, id: \.self) { command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        if map.key(for: command) == nil, recording != command {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help("Komennolla ei ole pikanäppäintä")
                        }
                        Button {
                            recording == command ? stopRecording() : startRecording(command)
                        } label: {
                            Text(recording == command ? "Paina näppäintä…" : map.key(for: command).map(ShortcutMap.label) ?? "—")
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 110)
                        }
                    }
                }
                if let rejected {
                    Text(rejected).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Palauta oletukset") {
                        stopRecording()
                        app.settings.app.shortcuts = ShortcutMap.defaults
                    }
                }
            }
            Section {
                Text("Kiinteät pikanäppäimet: Enter avaa, Esc palaa listaan, nuolet siirtävät valintaa ja ⌘Z kumoaa.")
                Text("⌘-pikanäppäimiä voi muuttaa kohdassa Järjestelmäasetukset → Näppäimistö → Näppäinoikotiet… → Appien oikotiet.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ command: MailCommand) {
        stopRecording()
        recording = command
        rejected = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let key = event.characters ?? ""
            var updated = map
            if flags.isEmpty, updated.assign(key, to: command) {
                app.settings.app.shortcuts = updated.keys
                stopRecording()
            } else {
                rejected = "Paina yhtä merkkinäppäintä ilman ⌘-, ⌃- tai ⌥-näppäintä. Enter, Esc, välilyönti ja nuolet eivät käy."
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
