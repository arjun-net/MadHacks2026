import Charts
import SwiftUI

struct PastWeekSection: View {
    let insights: AreaInsights

    @State private var selectedDay: Date?

    private var days: [DayHistory] { insights.pastDays }

    var body: some View {
        DetailSection(title: "Past days", trailing: "Daily peak") {
            VStack(spacing: 0) {
                ForEach(days.reversed()) { day in
                    PastDayRow(day: day, isExpanded: selectedDay == day.date)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Theme.Motion.snappy) {
                                selectedDay = selectedDay == day.date ? nil : day.date
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                    if day.date != days.first?.date {
                        Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.sm)
            .sensoryFeedback(.selection, trigger: selectedDay)
        }
    }
}

struct PastDayRow: View {
    let day: DayHistory
    let isExpanded: Bool

    private var peakIntensity: Double { day.peak?.intensity ?? 0 }
    private var level: ActivityLevel { ActivityLevel(intensity: peakIntensity) }

    private var dayYDomain: ClosedRange<Double> {
        let values = day.hourly.map(\.intensity)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        return max(0, low - (high - low) * 0.25)...high
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.date.formatted(.dateTime.weekday(.wide)))
                        .typeStyle(.rowTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(day.date.formatted(.dateTime.month(.abbreviated).day()) + (day.peak.map { " · \(Formatting.hour($0.hour))" } ?? ""))
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(width: 92, alignment: .leading)

                ActivityBar(intensity: peakIntensity, height: 4)

                Text(level.title)
                    .typeStyle(.badge)
                    .foregroundStyle(level.textColor)
                    .frame(width: 70, alignment: .trailing)

                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Chart(day.hourly) { value in
                        BarMark(
                            x: .value("Hour", value.hour),
                            yStart: .value("Base", dayYDomain.lowerBound),
                            yEnd: .value("Activity", value.intensity),
                            width: .fixed(6)
                        )
                            .cornerRadius(1)
                            .foregroundStyle(value.intensity == day.peak?.intensity ? Theme.Colors.accent : Theme.Colors.accent.opacity(0.45))
                    }
                    .chartXScale(domain: -0.5...23.5)
                    .chartYScale(domain: dayYDomain)
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
                    .frame(height: 70)

                    if let peak = day.peak {
                        Text("Peaked around \(Formatting.hour(peak.hour)) · daytime average was \(ActivityLevel(intensity: day.daytimeAverage).title.lowercased())")
                            .typeStyle(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
