import SwiftUI

struct QuietSpotCard: View {
    let activity: AreaActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AreaIconTile(symbol: activity.area.symbol, color: activity.level.textColor, size: 36)
                Spacer()
                ActivityLevelBadge(level: activity.level)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.area.name)
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                Text(activity.area.category.title)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Sparkline(values: activity.history, color: activity.level.textColor, lineWidth: 1.5)
                .frame(height: 24)
        }
        .padding(14)
        .frame(width: 168)
        .card(cornerRadius: Theme.Radius.sm)
        .accessibilityElement(children: .combine)
    }
}

struct CompactAreaRow: View {
    let activity: AreaActivity
    var isFavorite = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.area.symbol)
                .imageScale(.medium)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: 24)
                .overlay(alignment: .topTrailing) {
                    // Saved places get a small star on the icon, so the name keeps its width.
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Colors.accent)
                            .offset(x: 4, y: -4)
                    }
                }
            Text(activity.area.name)
                .typeStyle(.rowTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            ActivityBar(intensity: activity.intensity, height: 4)
                .frame(width: 64)
            Text(activity.level.title)
                .typeStyle(.badge)
                .foregroundStyle(activity.level.textColor)
                .frame(width: 70, alignment: .trailing)
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activity.area.name)\(isFavorite ? ", saved" : ""), \(activity.level.title)")
    }
}
