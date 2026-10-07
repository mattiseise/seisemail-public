import MailCore
import SwiftUI

// Fork (seisemail): the Inbox 0 overlays (InboxZeroView in ThreadList+Seise.swift).

/// Darkens the middle (the streak) and the bottom edge (the status) just enough for white text.
struct InboxZeroScrims: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.12)                                       // the whole photo a touch calmer
                RadialGradient(colors: [.black.opacity(0.45), .black.opacity(0)], center: .center,
                               startRadius: 0, endRadius: min(geo.size.width, geo.size.height) * 0.55)
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.6),
                                       .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "INBOX 0 -PUTKI", a hairline, the number of weeks in a thin large face, "VIIKKOA".
struct InboxZeroStreakBadge: View {
    let weeks: Int

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.height * 0.38, geo.size.width * 0.4, 230)
            VStack(spacing: Theme.metric(8)) {
                Text(InboxZeroText.streakTitle.uppercased())
                    .font(Theme.font(12, weight: .semibold)).tracking(3)
                Rectangle().frame(width: 32, height: 1).opacity(0.6)
                Text("\(weeks)")
                    .font(.system(size: size, weight: .light).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(InboxZeroText.weeks(weeks).uppercased())
                    .font(Theme.font(12, weight: .semibold)).tracking(3)
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.55), radius: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -geo.size.height * 0.04)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(InboxZeroText.streakLabel(weeks))
    }
}
