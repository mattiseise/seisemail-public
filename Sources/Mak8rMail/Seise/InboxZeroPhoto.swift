import AppKit
import MailCore
import SwiftUI

/// Fork (seisemail): the Inbox 0 photo (DailyPhotoStore: Wikimedia Commons' picture of the day, else a bundled
/// photo), edge to edge. `overlay` gets the shown photo's credit, which CC BY/BY-SA require on the page. Without
/// any photo the Sinihetki night gradient shows.
struct InboxZeroPhoto<Overlay: View>: View {
    let store: DailyPhotoStore
    let day: Int
    let daily: Bool
    @ViewBuilder let overlay: (PhotoCredit?) -> Overlay
    @State private var shown: Shown?

    private struct Shown {
        var photo: InboxPhoto
        var image: NSImage
    }

    private struct Key: Hashable {
        var day: Int
        var daily: Bool
    }

    private static var night: LinearGradient { LinearGradient(
        colors: [Color(red: 0x15 / 255, green: 0x1B / 255, blue: 0x30 / 255),     // pinta-2
                 Color(red: 0x08 / 255, green: 0x0B / 255, blue: 0x16 / 255)],    // pohja
        startPoint: .top, endPoint: .bottom) }

    var body: some View {
        Color.clear
            .background(Self.night)
            .overlay {
                if let shown {
                    Image(nsImage: shown.image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .overlay { overlay(shown?.photo.credit) }
            .task(id: Key(day: day, daily: daily)) {
                await show(store.photo(day: day, daily: daily))
                if daily, await store.refresh(day: day) { await show(store.photo(day: day)) }
            }
    }

    /// Reads the file off the main thread; keeps the current photo if the new one does not load.
    private func show(_ photo: InboxPhoto?) async {
        guard let photo else { shown = nil; return }
        guard shown?.photo != photo else { return }
        let url = photo.fileURL
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { shown = Shown(photo: photo, image: image) }
    }
}

/// "Kuva: <tekijä> · <lisenssi>" in a corner of the photo: the author links to the Commons file page, the licence
/// to its deed. The title and the note of changes (BY-SA) show on hover.
struct PhotoCreditLine: View {
    let credit: PhotoCredit

    var body: some View {
        HStack(spacing: 4) {
            link("Kuva: \(credit.artist)", credit.sourceURL)
            Text("·")
            link(credit.license, credit.licenseURL)
        }
        .font(Theme.font(11))
        .foregroundStyle(.white.opacity(0.75))
        .tint(.white.opacity(0.75))
        .lineLimit(1)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        .help([credit.title, credit.modified].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
    }

    @ViewBuilder private func link(_ text: String, _ address: String) -> some View {
        if let url = URL(string: address), url.scheme == "https" || url.scheme == "http" {
            Link(text, destination: url)
        } else {
            Text(text)
        }
    }
}
