import SwiftUI

/// One campus area: rank, name, level and rounded count, and the recent trend.
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
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.area.shortName)
                    .typeStyle(.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    ActivityLevelBadge(level: activity.level)
                    Text("·").foregroundStyle(Theme.Colors.textTertiary)
                    Text(activity.countLabel)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
                .typeStyle(.caption)
            }
            Spacer(minLength: 8)

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
