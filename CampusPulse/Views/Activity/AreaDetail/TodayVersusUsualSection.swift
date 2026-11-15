import Charts
import SwiftUI

struct TodayVersusUsualSection: View {
    let insights: AreaInsights

    private var typical: [HourlyValue] { insights.typical(weekday: insights.todayWeekday) }

    var body: some View {
        DetailSection(
            title: "Today so far",
            trailing: insights.variesByWeekday ? "vs. a usual \(insights.generatedAt.formatted(.dateTime.weekday(.wide)))" : "vs. a usual day"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    legend(color: Theme.Colors.accent, dashed: false, label: "Today")
                    legend(color: Theme.Colors.textTertiary, dashed: true, label: "Usual")
                }
                Chart {
                    ForEach(typical) { value in
                        LineMark(
                            x: .value("Hour", value.hour + 0.5),
                            y: .value("Activity", value.intensity),
                            series: .value("Series", "Usual")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    ForEach(insights.today) { value in
                        AreaMark(
                            x: .value("Hour", value.hour),
                            yStart: .value("Base", 0),
                            yEnd: .value("Activity", value.intensity),
                            series: .value("Series", "Today")
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.Colors.accent.opacity(0.12), Theme.Colors.accent.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Hour", value.hour),
                            y: .value("Activity", value.intensity),
                            series: .value("Series", "Today")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(Theme.Colors.accent)
                    }
                    if let now = insights.today.last {
                        PointMark(x: .value("Hour", now.hour), y: .value("Activity", now.intensity))
                            .symbolSize(70)
                            .foregroundStyle(Theme.Colors.accent)
                        RuleMark(x: .value("Now", now.hour))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(Theme.Colors.rule)
                    }
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                        AxisGridLine().foregroundStyle(Theme.Colors.rule)
                        AxisValueLabel {
                            if let hour = value.as(Double.self) {
                                Text(Formatting.hour(hour, compact: true))
                                    .typeStyle(.caption)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .accessibilityLabel("Today's activity compared with a usual day")
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.sm)
        }
    }

    private func legend(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            .frame(width: 16, height: 2)
            Text(label)
                .typeStyle(.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}
