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
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 64, height: 64)
                Circle()
                    .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }
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
                .tint(.white)
            Text(message)
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassCapsule()
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
                    .typeStyle(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.Gradients.accent, in: Capsule())
                    .foregroundStyle(.white)
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
                    .typeStyle(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .foregroundStyle(.white)
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
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.09))
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
