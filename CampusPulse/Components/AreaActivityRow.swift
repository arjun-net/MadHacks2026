import SwiftUI

/// One campus area: icon, name, level, intensity bar, rounded count and recent trend.
struct AreaActivityRow: View {
    let activity: AreaActivity
    var rank: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(width: 14)
            }
            AreaIconTile(symbol: activity.area.symbol, color: activity.level.color)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(activity.area.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ActivityLevelBadge(level: activity.level)
                }
                HStack(spacing: 8) {
                    ActivityBar(intensity: activity.intensity, height: 5)
                    Text(activity.countLabel)
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            Sparkline(values: activity.history, color: activity.level.color, lineWidth: 1.5)
                .frame(width: 44, height: 26)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank.map { "Number \($0), " } ?? "")\(activity.area.name), \(activity.level.title), \(activity.countLabel), \(activity.trend.title)")
    }
}

#Preview {
    let snapshot = PreviewData.snapshot
    VStack(spacing: 16) {
        ForEach(Array(snapshot.busiest(5).enumerated()), id: \.element.id) { index, activity in
            AreaActivityRow(activity: activity, rank: index + 1)
        }
    }
    .padding()
    .background(ScreenBackground())
    .preferredColorScheme(.dark)
}
