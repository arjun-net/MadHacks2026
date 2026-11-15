import SwiftUI

/// Floating detail card shown when a building label is tapped.
struct AreaFocusCard: View {
    let activity: AreaActivity
    var isFavorite = false
    var onToggleFavorite: (() -> Void)?
    var onClose: () -> Void
    var onOpenDetails: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AreaIconTile(symbol: activity.area.symbol, color: activity.level.color, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.area.name)
                        .typeStyle(.title3)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("\(activity.area.category.title) · \(activity.countLabel)")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isFavorite ? Theme.Colors.accent : Theme.Colors.ink)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel(isFavorite ? "Remove from your places" : "Save to your places")
                    .sensoryFeedback(.selection, trigger: isFavorite)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Colors.ink)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Close")
            }

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now").sectionLabelStyle()
                    ActivityLevelBadge(level: activity.level, showsIcon: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trend").sectionLabelStyle()
                    Label(activity.trend.shortTitle, systemImage: activity.trend.symbol)
                        .typeStyle(.rowTitle)
                        .foregroundStyle(Theme.Colors.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Last 24 min").sectionLabelStyle()
                    Sparkline(values: activity.history, color: activity.level.textColor, lineWidth: 2)
                        .frame(width: 96, height: 30)
                }
            }

            ActivityBar(intensity: activity.intensity, height: 6)

            if let onOpenDetails {
                Button(action: onOpenDetails) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Busy times & history")
                            .typeStyle(.button)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint("Opens \(activity.area.name) on the Activity tab")
            }
        }
        .padding(16)
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
    }
}

#Preview("Focus card") {
    VStack {
        Spacer()
        AreaFocusCard(activity: PreviewData.snapshot.busiest(1)[0], onClose: {})
    }
    .padding()
    .background(ScreenBackground())
}
