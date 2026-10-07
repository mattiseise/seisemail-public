import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Mak8r Mail")
                .font(.largeTitle.weight(.semibold))
            switch app.phase {
            case .missingConfig:
                Text("OAuth-tunnukset puuttuvat.")
                    .font(.headline)
                Text("Kopioi Config/Secrets.example.xcconfig tiedostoksi Config/Secrets.xcconfig, täytä Google Cloudin Desktop app -tunnukset ja aja `make app` uudelleen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            case .signingIn:
                ProgressView()
                Text("Viimeistele kirjautuminen selaimessa.")
                    .foregroundStyle(.secondary)
                Button("Peruuta") { app.cancelSignIn() }
            default:
                Text(app.accounts.emails.isEmpty ? "Rauhallinen sähköposti Gmail-tilillesi." : "Kirjaudu uudelleen tilille \(app.accounts.active ?? "").")
                    .foregroundStyle(.secondary)
                Button("Kirjaudu Googlella") { app.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                if let error = app.signInError {
                    Text(error).foregroundStyle(.red)
                }
                let others = app.accounts.emails.filter { $0 != app.accounts.active && !app.expired.contains($0) }
                if !others.isEmpty {
                    VStack(spacing: 6) {
                        Text("tai vaihda tiliin").font(.caption).foregroundStyle(.secondary)
                        ForEach(others, id: \.self) { email in
                            Button(email) { app.switchAccount(email) }.buttonStyle(.link)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
