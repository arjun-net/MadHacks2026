import SwiftUI

/// Masthead: a dateline (live, last update, date) over the campus name in display serif,
/// and a one-line summary underneath: how busy campus is and roughly how many people are out
/// on it, and the busiest place (tap to find it on the map). The ranked lists live on the Activity tab.
struct MapHeader: View {
    let campus: Campus
    let snapshot: CampusSnapshot?
    let isRefreshing: Bool
    let sharingStatus: SharingStatus
    var onOpenSharing: () -> Void
    var onSelectArea: (String) -> Void = { _ in }

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
                Rectangle().fill(Theme.Colors.border).frame(height: Theme.Stroke.hairline)
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

            if let snapshot, !snapshot.isEmpty {
                summary(snapshot)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.smooth, value: snapshot?.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, snapshot?.isEmpty == false ? 12 : 14)
        .paper(cornerRadius: Theme.Radius.sm, elevated: true)
    }
}

extension MapHeader {
    fileprivate func summary(_ snapshot: CampusSnapshot) -> some View {
        // Two sides: how busy campus is (level and headcount read as one phrase) on the left,
        // the busiest place on the right. Nothing floats alone in the middle.
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ActivityLevelBadge(level: snapshot.level)
                Text("≈\(Formatting.number(snapshot.participantCount)) on campus")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(snapshot.participantCount)))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Campus is \(snapshot.level.title.lowercased()), about \(snapshot.participantCount) people on campus")

            Spacer(minLength: 12)

            if let top = snapshot.busiest(1).first {
                Button { onSelectArea(top.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.accent)
                        Text(top.area.shortName)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    // Tall enough to tap, without making the row (and the card) taller.
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                    .padding(.vertical, -12)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Busiest: \(top.area.name)")
                .accessibilityHint("Shows it on the map")
            }
        }
        .typeStyle(.caption)
        // As much room above the row (from the rule) as below it (to the card's edge).
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.rule).frame(height: Theme.Stroke.hairline)
        }
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
            // Drawn shorter than the title so the masthead row keeps even space above and below.
            .frame(minHeight: 34)
            .background(status == .off ? Theme.Colors.accentFill : Theme.Colors.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                if status != .off {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(foreground, lineWidth: Theme.Stroke.hairline)
                }
            }
            // Still a 44 pt tap target, reaching past the drawn edges without taking up room.
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .padding(.vertical, -5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Location sharing: \(label)")
        .accessibilityHint("Opens location sharing")
    }
}

/// Vertical paper column of map actions.
struct MapControlStack: View {
    let isHeatmapVisible: Bool
    var is3D = false
    var onRecenter: () -> Void
    var onToggleHeatmap: () -> Void
    var onToggle3D: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            MapControlButton(symbol: "scope", label: "Center on campus", action: onRecenter)
            divider
            MapControlButton(
                symbol: is3D ? "map" : "view.3d",
                label: is3D ? "Show flat map" : "Show 3D map",
                tint: is3D ? Theme.Colors.accent : Theme.Colors.ink,
                action: onToggle3D
            )
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
            .fill(Theme.Colors.border)
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
