import MailCore
import SwiftUI

/// Fork (seisemail): "Oma aika" in the `h` card, drawn in the app's own style instead of AppKit's date pickers.
/// All state is SnoozeMenuModel's: the keys come through KeyboardMonitor, the mouse through `actions`.
struct SnoozeCustomTime: View {
    /// The mouse's way into the model (SeiseController in the app).
    struct Actions {
        var selectDay: (Int) -> Void
        var setTime: (Int) -> Void
        var showMonth: (Int) -> Void
        var focusTime: () -> Void
    }

    let model: SnoozeMenuModel
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.metric(10)) {
            SnoozeCalendar(model: model, actions: actions)
            Hairline()
            timeRow
            TimelineView(.everyMinute) { ctx in
                let ok = if case .ok = model.customCheck(now: ctx.date) { true } else { false }
                Text(model.customPreview(now: ctx.date))
                    .font(Theme.meta.monospacedDigit())
                    .foregroundStyle(ok ? Theme.muted : Theme.accent)
            }
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Button { actions.focusTime() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: Theme.scaled(11))).foregroundStyle(Theme.muted)
                    Text(model.timeText)
                        .font(Theme.font(15, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                    if model.customField == .time, !model.timeEntry.isEmpty {
                        Rectangle().fill(Theme.accent).frame(width: 1.5, height: Theme.metric(15))   // typing
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: Theme.metric(30))
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(model.customField == .time ? Theme.accent : Theme.line, lineWidth: model.customField == .time ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Kellonaika \(model.timeText)")
            Spacer(minLength: 8)
            ForEach(SnoozeMenuModel.timeChoices, id: \.self) { minutes in
                TimeChip(minutes: minutes, selected: minutes == model.customMinutes) { actions.setTime(minutes) }
            }
        }
    }
}

private struct TimeChip: View {
    let minutes: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(String(format: "%d.%02d", minutes / 60, minutes % 60))
                .font(Theme.meta.monospacedDigit().weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
                .padding(.horizontal, 7)
                .frame(height: Theme.metric(24))
                .background(selected ? Theme.checked : hovering ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Month grid, Monday first, with ISO week numbers ("vk"), as Finns read calendars.
struct SnoozeCalendar: View {
    let model: SnoozeMenuModel
    let actions: SnoozeCustomTime.Actions
    private static let weekdays = FinnishTime.weekdays

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(model.monthTitle).font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "chevron.left", help: "Edellinen kuukausi") { actions.showMonth(-1) }
                    .disabled(!model.canShowPreviousMonth)
                    .opacity(model.canShowPreviousMonth ? 1 : 0.35)
                IconButton(symbol: "chevron.right", help: "Seuraava kuukausi") { actions.showMonth(1) }
            }
            .padding(.bottom, 2)
            HStack(spacing: 0) {
                Text("vk").frame(width: Theme.metric(26))
                ForEach(Self.weekdays, id: \.self) { Text($0).frame(maxWidth: .infinity) }
            }
            .font(Theme.font(10.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .frame(height: Theme.metric(20))
            ForEach(model.calendarWeeks) { week in
                HStack(spacing: 2) {
                    Text("\(week.number)")
                        .font(Theme.font(10).monospacedDigit())
                        .foregroundStyle(Theme.muted.opacity(0.7))
                        .frame(width: Theme.metric(24))
                    ForEach(week.cells) { cell in
                        DayCell(cell: cell, keyboard: model.customField == .day) { actions.selectDay(cell.day) }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let cell: CalendarCell
    /// The calendar has the keyboard: the chosen day gets a focus ring.
    let keyboard: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(cell.dayOfMonth)")
                .font(Theme.font(12.5, weight: cell.isSelected || cell.isToday ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.metric(28))
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    if cell.isToday, !cell.isSelected {
                        RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                    }
                }
                .padding(2)
                .overlay {
                    if cell.isSelected, keyboard {
                        RoundedRectangle(cornerRadius: Theme.radius + 2).stroke(Theme.accent.opacity(0.35), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.isPast)
        .onHover { hovering = $0 && !cell.isPast }
        .accessibilityLabel(label)
        .accessibilityAddTraits(cell.isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if cell.isSelected { return .white }
        if cell.isPast { return Theme.muted.opacity(0.35) }
        if cell.isToday { return Theme.accent }
        return cell.inMonth ? Theme.text : Theme.muted.opacity(0.6)
    }

    private var background: Color {
        if cell.isSelected { return Theme.accent }
        return hovering ? Theme.hover : .clear
    }

    private var label: String {
        cell.label + (cell.isToday ? ", tänään" : "") + (cell.isPast ? ", mennyt" : "")
    }
}
