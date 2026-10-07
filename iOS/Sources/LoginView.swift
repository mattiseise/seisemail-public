import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Mak8r Mail")
                .font(.largeTitle.weight(.semibold))
            switch app.phase {
            case .missingConfig:
                Text("OAuth-tunnus puuttuu.")
                    .font(.headline)
                Text("Lisää Google Cloudin iOS-asiakkaan client ID tiedostoon Config/Secrets.xcconfig avaimella GOOGLE_IOS_CLIENT_ID ja käännä uudelleen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .signingIn:
                ProgressView()
                Text("Viimeistele kirjautuminen.")
                    .foregroundStyle(.secondary)
                Button("Peruuta") { app.cancelSignIn() }
            default:
                Text(app.accounts.emails.isEmpty ? "Rauhallinen sähköposti Gmail-tilillesi." : "Kirjaudu uudelleen tilille \(app.accounts.active ?? "").")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Kirjaudu Googlella") { app.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let error = app.signInError {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                let others = app.accounts.emails.filter { $0 != app.accounts.active && !app.expired.contains($0) }
                if !others.isEmpty {
                    VStack(spacing: 6) {
                        Text("tai vaihda tiliin").font(.caption).foregroundStyle(.secondary)
                        ForEach(others, id: \.self) { email in
                            Button(email) { app.switchAccount(email) }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
