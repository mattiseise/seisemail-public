import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.phase == .ready {
            MailboxView()
        } else {
            LoginView()
        }
    }
}
