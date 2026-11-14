import SwiftUI

/// Floating top bar: live indicator, campus name, and sharing status.
struct MapHeader: View {
    let campus: Campus
    let snapshot: CampusSnapshot?
    let isRefreshing: Bool
    let sharingStatus: SharingStatus
    var onOpenSharing: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    PulsingDot(color: Theme.Colors.live, size: 7)
                    Text("LIVE")
                        .typeStyle(.micro)
                        .foregroundStyle(Theme.Colors.live)
                    Text("·")
                        .foregroundStyle(Theme.Colors.textTertiary)
                    UpdatedAgoText(date: snapshot?.generatedAt)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if isRefreshing, snapshot != nil {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.Colors.textSecondary)
                    }
                }
                Text(campus.shortName)
                    .typeStyle(.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            SharingStatusPill(status: sharingStatus, action: onOpenSharing)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .glass(cornerRadius: Theme.Radius.lg)
    }
}

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
        case .off: "location"
        }
    }

    private var tint: Color {
        switch status {
        case .active: Theme.Colors.live
        case .permissionDenied: Theme.Colors.danger
        case .off: .white
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(tint.opacity(status == .off ? 0.1 : 0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Location sharing: \(label)")
        .accessibilityHint("Opens location sharing")
    }
}

/// Vertical glass column of map actions.
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
                tint: isHeatmapVisible ? HeatPalette.color(at: 0.85) : .white,
                action: onToggleHeatmap
            )
        }
        .glass(cornerRadius: 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 26, height: 0.5)
    }
}

struct MapControlButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white
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
