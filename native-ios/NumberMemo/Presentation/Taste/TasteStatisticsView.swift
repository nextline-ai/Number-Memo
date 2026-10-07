import SwiftUI
import Charts

struct TastePeriodNavigation: View {
    let period: TastePeriod
    @Binding var offset: Int
    let timeZone: String
    var latestOffset = 0
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: timeZone) ?? .gmt; return value }
    private var label: String {
        guard let interval = period.interval(offset: offset, now: Date(), timeZone: timeZone) else { return "" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.language); formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(period == .month ? "yMMMM" : "MMMd")
        if period == .month { return formatter.string(from: interval.start) }
        return formatter.string(from: interval.start) + " – " + formatter.string(from: interval.end.addingTimeInterval(-1))
    }
    var body: some View {
        HStack(spacing: 8) {
            Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel(L10n.text("Previous Period"))
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                Text(label).font(.headline)
                if offset == 0 { Text(L10n.text("In progress")).font(.caption).foregroundStyle(.secondary) }
                else if offset < latestOffset { Button(L10n.text(period == .week ? "Back to this week" : "Latest recap")) { offset = latestOffset }.font(.caption) }
            }.multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(offset >= latestOffset).accessibilityLabel(L10n.text("Next Period"))
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}

struct TasteStatisticsView: View {
    let snapshot: TasteSnapshot
    let period: TastePeriod
    let timeZone: String
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: timeZone) ?? .gmt; return value }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TasteSurface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text("Newly saved works")).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "heart.fill").foregroundStyle(TastePresentation.accent).accessibilityHidden(true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(snapshot.saves.formatted()).font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                        if let previous = snapshot.previousSaves {
                            let change = snapshot.saves - previous
                            Text((change > 0 ? "+" : "") + String(change))
                                .font(.subheadline.bold()).foregroundStyle(TastePresentation.accent)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(TastePresentation.accent.opacity(0.1), in: Capsule())
                                .accessibilityLabel(L10n.text("Change from previous period: %@", String(change)))
                        }
                    }
                    if let previous = snapshot.previousSaves {
                        Text(L10n.text("%@ saved in the previous period", String(previous))).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(spacing: 20) {
                        metric("Active days", value: snapshot.activity.count, icon: "calendar")
                        Spacer()
                        metric("Searches", value: snapshot.searches, icon: "magnifyingglass")
                        Spacer(minLength: 0)
                    }
                }
            }
            if !snapshot.activity.isEmpty, let interval = snapshot.period {
                TasteSurface {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(L10n.text("Your activity")).font(.headline)
                        Chart(snapshot.activity.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            BarMark(x: .value(L10n.text("Date"), entry.key, unit: .day), y: .value(L10n.text("Saved"), entry.value))
                                .foregroundStyle(TastePresentation.accent.gradient).cornerRadius(4)
                        }
                        .chartXScale(domain: interval.start...interval.end)
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: period == .month ? 7 : 1)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
                        .frame(height: 170).accessibilityLabel(L10n.text("Saved works over time"))
                    }
                }
            }
        }
    }
    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text(title), systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}
