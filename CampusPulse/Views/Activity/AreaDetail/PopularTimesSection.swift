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

    private var caption: String {
        if let selectedHour, let value = values.first(where: { $0.hour == selectedHour }) {
            return "\(Formatting.hour(value.hour)): usually \(value.level.title.lowercased())"
        }
        if let peak = insights.usualPeak(weekday: shownWeekday) {
            return "Usually busiest around \(Formatting.hour(peak.hour))"
        }
        return ""
    }

    var body: some View {
        DetailSection(title: "Popular times", trailing: trailing) {
            VStack(alignment: .leading, spacing: 14) {
                // With one stored day every weekday looks the same, so there's nothing to pick.
                if insights.variesByWeekday {
                    dayPicker
                }

                Text(caption)
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.snappy, value: caption)

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
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Usual", value.intensity),
                    width: .fixed(8)
                )
                .cornerRadius(1)
                // The current hour's usual is the grey part above a quieter-than-usual live bar.
                .foregroundStyle(isToday && value.hour == currentHour ? Theme.Colors.textTertiary.opacity(0.4) : barColor(for: value))
            }

            if isToday {
                // The current hour: the live reading as its own bar over the usual one.
                BarMark(
                    x: .value("Hour", currentHour),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Live", max(liveIntensity, yDomain.lowerBound)),
                    width: .fixed(8)
                )
                .cornerRadius(1)
                .foregroundStyle(selectedHour == nil || selectedHour == currentHour ? Theme.Colors.accent : Theme.Colors.accent.opacity(0.3))

                // Busier than usual: a notch in the live bar where usual would end.
                if liveIntensity > usualNow + 0.02, usualNow > yDomain.lowerBound {
                    RuleMark(
                        xStart: .value("Hour", currentHour - 0.2),
                        xEnd: .value("Hour", currentHour + 0.2),
                        y: .value("Usual", usualNow)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Theme.Colors.paper)
                }

                // Label over the taller of the two, in the headroom `yDomain` keeps for it.
                PointMark(
                    x: .value("Hour", currentHour),
                    y: .value("Top", max(liveIntensity, usualNow))
                )
                .symbolSize(0)
                .annotation(position: .top, spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Text("Live")
                        .typeStyle(.badge)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }

            if let selectedHour {
                RuleMark(x: .value("Selected", selectedHour))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.Colors.ink.opacity(0.5))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
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
        .accessibilityLabel(insights.variesByWeekday ? "Usual activity by hour on \(weekdayName(shownWeekday)). \(caption)" : "Usual activity by hour. \(caption)")
    }

    /// Starts just below the quietest hour so the shape of the day reads clearly,
    /// like a relative "popular times" chart (there's no y-axis to misread). On today, the top
    /// leaves room for the "Live" label over the tallest bar.
    private var yDomain: ClosedRange<Double> {
        let low = values.map(\.intensity).min() ?? 0
        let high = max(values.map(\.intensity).max() ?? 1, isToday ? liveIntensity : 0, 0.01)
        let bottom = max(0, low - (high - low) * 0.25)
        return bottom...(high + (high - bottom) * (isToday ? 0.2 : 0.08))
    }

    private func barColor(for value: HourlyValue) -> Color {
        let color = Theme.Colors.accent
        if let selectedHour { return value.hour == selectedHour ? color : color.opacity(0.3) }
        if isToday {
            if value.hour == currentHour { return color }
            return value.hour < currentHour ? color.opacity(0.32) : color.opacity(0.7)
        }
        return color.opacity(0.8)
    }

    private func weekdayName(_ day: Int) -> String {
        Calendar.current.weekdaySymbols[day - 1]
    }
}
