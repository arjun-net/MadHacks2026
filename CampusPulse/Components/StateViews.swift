import SwiftUI

/// Shared layout for loading / empty / error / permission messages.
struct StatusMessageView<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
            VStack(spacing: 6) {
                Text(title)
                    .typeStyle(.title3)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(message)
                    .typeStyle(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: 360)
    }
}

extension StatusMessageView where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}

struct LoadingStateView: View {
    var message = "Mapping campus activity…"

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.Colors.ink)
            Text(message)
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .paper()
    }
}

struct EmptyActivityView: View {
    let threshold: Int
    let campusName: String

    var body: some View {
        StatusMessageView(
            symbol: "person.3.fill",
            tint: Theme.Colors.accent,
            title: "Not enough activity yet",
            message: "Fewer than \(threshold) students are sharing in any one spot at \(campusName), so the heatmap stays hidden to protect privacy. Check back soon."
        )
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        StatusMessageView(
            symbol: "wifi.exclamationmark",
            tint: Theme.Colors.warning,
            title: "Can't load activity",
            message: message
        ) {
            Button(action: retry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .typeStyle(.button)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .foregroundStyle(Theme.Colors.onAccent)
            }
            .buttonStyle(.plain)
        }
    }
}

struct PermissionDeniedView: View {
    var openSettings: () -> Void = {}

    var body: some View {
        StatusMessageView(
            symbol: "location.slash.fill",
            tint: Theme.Colors.danger,
            title: "Location access is off",
            message: "To contribute to the heatmap, allow Campus Pulse to use your location while the app is open. You can still browse campus activity without it."
        ) {
            Button(action: openSettings) {
                Label("Open Settings", systemImage: "gear")
                    .typeStyle(.button)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Theme.Colors.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
                    .foregroundStyle(Theme.Colors.ink)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Skeleton placeholder block.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.Colors.surfaceStrong)
            .frame(width: width, height: height)
            .shimmering()
    }
}

#Preview("States") {
    ScrollView {
        VStack(spacing: 24) {
            LoadingStateView()
            EmptyActivityView(threshold: 5, campusName: "Stanford").card()
            ErrorStateView(message: "Check your connection and try again.", retry: {}).card()
            PermissionDeniedView(openSettings: {}).card()
        }
        .padding()
    }
    .background(ScreenBackground())
}
