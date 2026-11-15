import Charts
import SwiftUI

struct PopularTimesSection: View {
    let insights: AreaInsights
    let liveIntensity: Double

    @State private var weekday: Int?
    @State private var selectedHour: Double?

    private var shownWeekday: Int { weekday ?? insights.todayWeekday }
    private var isToday: Bool { shownWeekday == insights.todayWeekday }
    private var values: [HourlyValue] { insights.typical(weekday: shownWeekday) }
    private var currentHour: Double { Double(Int(insights.generatedAt.fractionalHour)) }
    /// What's usual for the current hour on the shown day.
    private var usualNow: Double { values.first { $0.hour == currentHour }?.intensity ?? 0 }

    /// Calendar weekdays starting from the locale's first weekday.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var trailing: String {
        guard insights.variesByWeekday else { return "Typical day" }
        return isToday ? "Today" : weekdayName(shownWeekday)
    }

    /// The line over the chart, as on Google Maps: live status for today; the tapped hour's
    /// usual; otherwise when it's usually busiest.
    @ViewBuilder
    private var statusLine: some View {
        if let selectedHour, let value = values.first(where: { $0.hour == selectedHour }) {
            HStack(spacing: 8) {
                Text(Formatting.hour(value.hour))
                    .typeStyle(.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Usually \(value.level.title.lowercased())")
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        } else if isToday {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    PulsingDot(color: Theme.Colors.live, size: 6)
                    Text("Live")
                        .typeStyle(.badge)
                        .foregroundStyle(Theme.Colors.accent)
                }
                Text(ActivityLevel(intensity: liveIntensity).title)
                    .typeStyle(.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(liveComparison)
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        } else if let peak = insights.usualPeak(weekday: shownWeekday) {
            Text("Usually busiest around \(Formatting.hour(peak.hour))")
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    /// "Usually light", or "Busier than usual" when the live level is above the usual one.
    private var liveComparison: String {
        switch UsualComparison(live: liveIntensity, typical: usualNow) {
        case .busier: "Busier than usual"
        case .quieter, .usual: "Usually \(ActivityLevel(intensity: usualNow).title.lowercased())"
        }
    }

    private var accessibilitySummary: String {
        if let selectedHour { return "\(Formatting.hour(selectedHour)): usually \(ActivityLevel(intensity: values.first { $0.hour == selectedHour }?.intensity ?? 0).title.lowercased())" }
        if isToday { return "Live: \(ActivityLevel(intensity: liveIntensity).title). \(liveComparison)." }
        return insights.usualPeak(weekday: shownWeekday).map { "Usually busiest around \(Formatting.hour($0.hour))" } ?? ""
    }

    var body: some View {
        DetailSection(title: "Popular times", trailing: trailing) {
            VStack(alignment: .leading, spacing: 14) {
                // With one stored day every weekday looks the same, so there's nothing to pick.
                if insights.variesByWeekday {
                    dayPicker
                }

                statusLine
                    .frame(minHeight: 22, alignment: .leading)
                    .animation(Theme.Motion.snappy, value: selectedHour)

                chart
                    .frame(height: 150)
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.sm)
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let selected = day == shownWeekday
                Button {
                    withAnimation(Theme.Motion.snappy) {
                        weekday = day
                        selectedHour = nil
                    }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .typeStyle(.button)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundStyle(selected ? Theme.Colors.onSelection : Theme.Colors.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(selected ? Theme.Colors.selectionFill : Theme.Colors.paper)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.borderStrong, lineWidth: Theme.Stroke.hairline)
                        }
                        .overlay(alignment: .bottom) {
                            if day == insights.todayWeekday, !selected {
                                Circle().fill(Theme.Colors.live).frame(width: 4, height: 4).offset(y: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekdayName(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: shownWeekday)
    }

    private var chart: some View {
        Chart {
            ForEach(values) { value in
                BarMark(
                    x: .value("Hour", value.hour),
                    yStart: .value("Base", 0),
                    yEnd: .value("Usual", value.intensity),
                    width: .fixed(8)
                )
                .cornerRadius(1)
                .foregroundStyle(barColor(for: value))
            }

            if isToday {
                // As on Google Maps: the live bar in full color over the hour's usual (pale).
                BarMark(
                    x: .value("Hour", currentHour),
                    yStart: .value("Base", 0),
                    // A sliver even when it's empty, so you can see where now is.
                    yEnd: .value("Live", max(liveIntensity, yTop * 0.025)),
                    width: .fixed(8)
                )
                .cornerRadius(1)
                .foregroundStyle(selectedHour == nil || selectedHour == currentHour ? Theme.Colors.accent : Theme.Colors.accent.opacity(0.35))

                // Busier than usual: a notch in the live bar where usual ends.
                if liveIntensity > usualNow + yTop * 0.03, usualNow > 0 {
                    RuleMark(
                        xStart: .value("Hour", currentHour - 0.2),
                        xEnd: .value("Hour", currentHour + 0.2),
                        y: .value("Usual", usualNow)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Theme.Colors.paper)
                }
            }

            if let selectedHour {
                RuleMark(x: .value("Selected", selectedHour))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.Colors.ink.opacity(0.5))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...yTop)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [3, 6, 9, 12, 15, 18, 21]) { value in
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        Text(Formatting.hour(hour, compact: true))
                            .typeStyle(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedHour },
            set: { newValue in selectedHour = newValue.map { min(23, max(0, $0.rounded(.down))) } }
        ))
        .sensoryFeedback(.selection, trigger: selectedHour)
        .accessibilityLabel(insights.variesByWeekday ? "Usual activity by hour on \(weekdayName(shownWeekday)). \(accessibilitySummary)" : "Usual activity by hour. \(accessibilitySummary)")
    }

    /// Bars start at zero, so heights compare directly (live against usual, hour against hour).
    private var yTop: Double {
        let high = max(values.map(\.intensity).max() ?? 0, isToday ? liveIntensity : 0)
        return high > 0 ? high * 1.06 : 1
    }

    /// Usual bars all share one pale tint (as on Google Maps), so the live bar is the only
    /// strong one. A tapped hour is picked out instead.
    private func barColor(for value: HourlyValue) -> Color {
        let color = Theme.Colors.accent
        if let selectedHour { return value.hour == selectedHour ? color.opacity(0.75) : color.opacity(0.18) }
        return isToday ? color.opacity(0.3) : color.opacity(0.75)
    }

    private func weekdayName(_ day: Int) -> String {
        Calendar.current.weekdaySymbols[day - 1]
    }
}
