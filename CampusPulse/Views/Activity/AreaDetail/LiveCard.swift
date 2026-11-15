import SwiftUI

struct LiveCard: View {
    let activity: AreaActivity
    let insights: AreaInsights

    private var comparison: UsualComparison {
        UsualComparison(live: activity.intensity, typical: insights.typicalNow)
    }

    private var weekdayName: String {
        insights.generatedAt.formatted(.dateTime.weekday(.wide))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        PulsingDot(color: Theme.Colors.live, size: 6)
                        Text("Right now")
                            .typeStyle(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    Text(activity.level.title)
                        .typeStyle(.metric)
                        .foregroundStyle(activity.level.textColor)
                        .contentTransition(.numericText())
                    Text("\(activity.countLabel) · \(comparison.title.prefix(1).lowercased() + comparison.title.dropFirst())")
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Sparkline(values: activity.history, color: activity.level.textColor, lineWidth: 2)
                    .frame(width: 92, height: 44)
                    .padding(.top, 8)
            }

            Rectangle().fill(Theme.Colors.rule).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                stat(
                    label: "Usual now",
                    value: ActivityLevel(intensity: insights.typicalNow).title,
                    color: ActivityLevel(intensity: insights.typicalNow).textColor
                )
                stat(
                    label: insights.pastDays.first.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "Last week",
                    value: insights.lastWeekNow.map { ActivityLevel(intensity: $0).title } ?? "—",
                    color: insights.lastWeekNow.map { ActivityLevel(intensity: $0).textColor } ?? Theme.Colors.textTertiary
                )
                stat(
                    label: "Usual peak",
                    value: insights.usualPeak(weekday: insights.todayWeekday).map { Formatting.hour($0.hour) } ?? "—",
                    color: Theme.Colors.textPrimary
                )
            }

            if let quiet = insights.quietestLaterToday {
                Text("Quietest later today is usually around \(Formatting.hour(quiet.hour)).")
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.sm)
        .accessibilityElement(children: .combine)
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .typeStyle(.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(value)
                .typeStyle(.title3)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
