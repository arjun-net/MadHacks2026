import SwiftUI

/// Masthead: a dateline (live, last update, date) over the campus name in display serif.
struct MapHeader: View {
    let campus: Campus
    let snapshot: CampusSnapshot?
    let isRefreshing: Bool
    let sharingStatus: SharingStatus
    var onOpenSharing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PulsingDot(color: Theme.Colors.live, size: 7)
                Text("Live")
                    .foregroundStyle(Theme.Colors.accent)
                Text("·")
                UpdatedAgoText(date: snapshot?.generatedAt)
                if isRefreshing, snapshot != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 6)
                Text(Formatting.dateline(snapshot?.generatedAt ?? .now))
                    .lineLimit(1)
            }
            .typeStyle(.micro)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Colors.ink).frame(height: Theme.Stroke.hairline)
            }

            HStack(alignment: .center, spacing: 12) {
                Text(campus.shortName)
                    .typeStyle(.masthead)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                SharingStatusPill(status: sharingStatus, action: onOpenSharing)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 14))
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
    }
}

/// Square, tracked-caps sharing button.
struct SharingStatusPill: View {
    let status: SharingStatus
    var action: () -> Void

    private var label: String {
        switch status {
        case .active: "Sharing"
        case .off, .permissionDenied: "Share"
        }
    }

    private var symbol: String {
        switch status {
        case .active: "location.fill"
        case .permissionDenied: "location.slash.fill"
        case .off: "location.fill"
        }
    }

    private var foreground: Color {
        switch status {
        case .active: Theme.Colors.positive
        case .permissionDenied: Theme.Colors.danger
        case .off: Theme.Colors.onAccent
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .typeStyle(.button)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(status == .off ? Theme.Colors.accentFill : Theme.Colors.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                if status != .off {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(foreground, lineWidth: Theme.Stroke.hairline)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Location sharing: \(label)")
        .accessibilityHint("Opens location sharing")
    }
}

/// Vertical paper column of map actions.
struct MapControlStack: View {
    let isHeatmapVisible: Bool
    var onRecenter: () -> Void
    var onToggleHeatmap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MapControlButton(symbol: "scope", label: "Center on campus", action: onRecenter)
            divider
            MapControlButton(
                symbol: isHeatmapVisible ? "flame.fill" : "flame",
                label: isHeatmapVisible ? "Hide heatmap" : "Show heatmap",
                tint: isHeatmapVisible ? Theme.Colors.accent : Theme.Colors.ink,
                action: onToggleHeatmap
            )
        }
        .paper(cornerRadius: Theme.Radius.sm)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colors.ink)
            .frame(width: 46, height: Theme.Stroke.hairline)
    }
}

struct MapControlButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.Colors.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .sensoryFeedback(.impact(weight: .light), trigger: symbol)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}
