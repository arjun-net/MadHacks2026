import SwiftUI

struct LocationSharingScreen: View {
    @Bindable var viewModel: LocationSharingViewModel
    /// Set when shown as a sheet: the bar gets a Done button instead of Back.
    var onDone: (() -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero

                toggleCard

                if viewModel.needsAlwaysPermission {
                    backgroundCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if viewModel.isPermissionDenied {
                    PermissionDeniedView()
                        .frame(maxWidth: .infinity)
                        .card(cornerRadius: Theme.Radius.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                statusGrid

                howItWorks

                privacyCard
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.tabBarClearance + 20)
            .animation(Theme.Motion.smooth, value: viewModel.status)
        }
        .scrollIndicators(.hidden)
        .background(ScreenBackground(ruled: false))
        .paperNavigationBar("Location Sharing", showsBack: onDone == nil) {
            if let onDone {
                PaperTextButton(title: "Done", action: onDone)
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.statusTitle)
                .typeStyle(.title)
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.opacity)
            Text(viewModel.statusSubtitle)
                .typeStyle(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    // MARK: Toggle

    private var toggleCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share my location")
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Anonymous · about every 2 min")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            // The title beside it is the visible label; the custom style draws whatever label it's given.
            Toggle(isOn: $viewModel.isSharingOn) { EmptyView() }
                .toggleStyle(.paper)
                .fixedSize()
                .accessibilityLabel("Share my location")
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.sm)
        .sensoryFeedback(.success, trigger: viewModel.isSharingOn) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.isSharingOn) { _, new in !new }
    }

    // MARK: Background

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep sharing when the app is closed")
                        .typeStyle(.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Right now sharing stops once you swipe the app away. Allowing location access **Always** lets it keep checking in every 2 minutes.")
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                if viewModel.canPromptForAlways {
                    viewModel.requestAlwaysPermission()
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text(viewModel.canPromptForAlways ? "Allow Always" : "Open Settings")
                    .typeStyle(.button)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.sm)
    }

    // MARK: Status

    private var statusGrid: some View {
        VStack(spacing: 0) {
            StatusTile(title: "Status", symbol: "dot.radiowaves.left.and.right", tint: viewModel.tint) {
                HStack(spacing: 8) {
                    PulsingDot(color: viewModel.tint, size: 8, isAnimating: viewModel.isActive)
                    Text(viewModel.statusLabel)
                }
            }

            RowRule(inset: 16)
            StatusTile(title: "Last update", symbol: "checkmark.circle", tint: Theme.Colors.accent) {
                if let last = viewModel.lastUpdateAt, viewModel.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Formatting.elapsed(since: last, now: context.date).capitalizedFirst)
                            .monospacedDigit()
                    }
                } else {
                    Text("Not yet")
                }
            }

            RowRule(inset: 16)
            StatusTile(title: "Next update", symbol: "timer", tint: Theme.Colors.accent) {
                if let next = viewModel.nextUpdateAt, viewModel.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 8) {
                            CountdownRing(
                                progress: 1 - max(0, next.timeIntervalSince(context.date)) / viewModel.updateInterval
                            )
                            .frame(width: 18, height: 18)
                            Text("in \(Formatting.countdown(until: next, now: context.date))")
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text("—")
                }
            }

            RowRule(inset: 16)
            // Readings that couldn't be sent yet (offline or server down); they go out automatically.
            StatusTile(title: "Waiting to send", symbol: "tray.full", tint: viewModel.pendingCount > 0 ? Theme.Colors.warning : Theme.Colors.accent) {
                Text(viewModel.pendingCount == 0 ? "None" : "\(viewModel.pendingCount)")
                    .monospacedDigit()
            }
        }
        .card(cornerRadius: Theme.Radius.sm)
    }

    // MARK: How it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "How it works")

            HowItWorksStep(number: 1, symbol: "iphone.radiowaves.left.and.right", title: "Your phone checks in",
                           detail: "Every 2 minutes, while sharing is on, the app sends your current location with a random ID for this install.")
            HowItWorksStep(number: 2, symbol: "square.grid.3x3.fill", title: "Combined with everyone else",
                           detail: "Check-ins are grouped into ~\(Int(AppConfig.aggregationCellMeters)) m cells and counted together.")
            HowItWorksStep(number: 3, symbol: "map.fill", title: "Only crowds appear",
                           detail: "The map shows how busy each area is. Cells with fewer than \(AppConfig.privacyThreshold) students are left out.", isLast: true)
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.sm)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Your privacy")
            ForEach(PrivacyContent.principles.prefix(4)) { item in
                PrivacyPoint(symbol: item.symbol, title: item.title, detail: item.detail, tint: Theme.Colors.positive)
            }
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.sm)
    }
}

// MARK: - Pieces

/// Glowing location beacon with radiating rings while sharing is active.
struct SharingBeacon: View {
    let isActive: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// With Reduce Motion the rings hold still at evenly spaced sizes instead of radiating.
    private var radiates: Bool { isActive && !reduceMotion }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !radiates)) { context in
                let time = radiates ? context.date.timeIntervalSinceReferenceDate : 0.4
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (time / 2.6 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(tint.opacity(0.6), lineWidth: 1.5)
                            .frame(width: 190, height: 190)
                            .scaleEffect(0.38 + 0.62 * phase)
                            .opacity(isActive ? (1 - phase) * 0.9 : 0)
                    }
                }
            }

            Circle()
                .strokeBorder(Theme.Colors.rule, lineWidth: Theme.Stroke.hairline)
                .frame(width: 140, height: 140)

            Circle()
                .fill(isActive ? Theme.Colors.accentFill : Theme.Colors.surfaceStrong)
                .frame(width: 84, height: 84)
                .overlay(Circle().strokeBorder(Theme.Colors.borderStrong, lineWidth: 2))

            Image(systemName: isActive ? "location.fill" : "location.slash.fill")
                .font(.cpTitle)
                .foregroundStyle(isActive ? Theme.Colors.onAccent : Theme.Colors.ink)
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(Theme.Motion.smooth, value: isActive)
        .accessibilityHidden(true)
    }
}

private struct StatusTile<Value: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var value: () -> Value

    /// One label/value row of the status list (`symbol` and `tint` are kept for call sites).
    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .typeStyle(.body)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: 8)
            value()
                .typeStyle(.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

private struct CountdownRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Colors.surfaceStrong, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct HowItWorksStep: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text("\(number)")
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 24, height: 24)
                if !isLast {
                    Rectangle()
                        .fill(Theme.Colors.rule)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

#Preview("Sharing – Off") {
    let container = PreviewData.container()
    NavigationStack {
        LocationSharingScreen(viewModel: LocationSharingViewModel(sharing: container.sharing, store: container.store))
    }
}

#Preview("Sharing – Denied") {
    let container = PreviewData.container(permission: .denied)
    NavigationStack {
        LocationSharingScreen(viewModel: LocationSharingViewModel(sharing: container.sharing, store: container.store))
    }
}
