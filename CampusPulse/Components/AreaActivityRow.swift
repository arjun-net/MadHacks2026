import SwiftUI

/// One campus area: icon, name, level, intensity bar, rounded count and recent trend.
struct AreaActivityRow: View {
    let activity: AreaActivity
    var rank: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .typeStyle(.rank)
                    .foregroundStyle(rank == 1 ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .frame(width: 22)
            }
            AreaIconTile(symbol: activity.area.symbol, color: activity.level.color)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(activity.area.name)
                        .typeStyle(.rowTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                        // Shrinks a little before truncating, so "Memorial Library" fits beside the badge.
                        .minimumScaleFactor(0.8)
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

            Sparkline(values: activity.history, color: activity.level.textColor)
                .frame(width: 44, height: 26)
        }
        .frame(minHeight: 52)
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
}
