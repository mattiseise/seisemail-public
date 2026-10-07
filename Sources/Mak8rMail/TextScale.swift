import MailCore
import SwiftUI

/// Fork (seisemail): adjustable text size on the Mac. Not compiled for iOS (see iOS/project.yml);
/// the iOS app follows Dynamic Type instead.
@MainActor
enum TextScale {
    static let store = TextSizeStore()
}

/// Scaled fonts and metrics. Reading these inside a view's `body` observes the store, so the
/// view redraws when the size changes.
extension Theme {
    @MainActor static var textSize: TextSize { TextScale.store.size }

    /// A system font at the design size `points`, scaled to the current text size.
    @MainActor static func font(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(points), weight: weight)
    }

    /// A font size (icons, badges) at the current text size.
    @MainActor static func scaled(_ points: CGFloat) -> CGFloat {
        CGFloat(textSize.scaled(Double(points)))
    }

    /// A row height or column width that grows with the text, at most `cap` times the design size.
    @MainActor static func metric(_ points: CGFloat, cap: Double = .infinity) -> CGFloat {
        CGFloat(textSize.metric(Double(points), cap: cap))
    }

    /// Page zoom for the reading pane's web view.
    @MainActor static var zoom: CGFloat { CGFloat(textSize.factor) }
}

/// "Suurenna tekstiä" ⌘+, "Pienennä tekstiä" ⌘−, "Tekstin oletuskoko" ⌘0 in the Näkymä menu.
struct TextSizeCommands: View {
    let app: AppModel
    private var store: TextSizeStore { TextScale.store }

    var body: some View {
        Button("Suurenna tekstiä") { change { store.increase() } }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!store.canIncrease)
        Button("Pienennä tekstiä") { change { store.decrease() } }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!store.canDecrease)
        Button("Tekstin oletuskoko") { change { store.reset() } }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(store.size.isStandard)
    }

    private func change(_ action: () -> Void) {
        action()
        app.store?.toast = "Tekstin koko \(store.size.label)"
    }
}

/// The "Tekstin koko" section of the General settings pane.
struct TextSizeSection: View {
    var body: some View {
        Section("Tekstin koko") {
            Picker("Koko", selection: Binding(
                get: { TextScale.store.size },
                set: { TextScale.store.set($0) }
            )) {
                ForEach(TextSize.all, id: \.self) { Text($0.choiceLabel).tag($0) }
            }
            Text("Koskee viestilistaa, sivupalkkia, lukunäkymää ja kirjoitusikkunaa. Pikanäppäimet ⌘+, ⌘− ja ⌘0.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
