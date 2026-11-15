import SwiftUI

struct LocationSharingScreen: View {
    @Bindable var viewModel: LocationSharingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero

                toggleCard

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
        .background(ScreenBackground())
        .navigationTitle("Location Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            SharingBeacon(isActive: viewModel.isActive, tint: viewModel.tint)
                .frame(height: 190)

            VStack(spacing: 6) {
                Text(viewModel.statusTitle)
                    .typeStyle(.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.opacity)
                Text(viewModel.statusSubtitle)
                    .typeStyle(.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Toggle

    private var toggleCard: some View {
        HStack(spacing: 14) {
            Image(systemName: viewModel.isSharingOn ? "location.fill" : "location")
                .imageScale(.large)
                .foregroundStyle(viewModel.isSharingOn ? Theme.Colors.onAccent : Theme.Colors.ink)
                .frame(width: 42, height: 42)
                .background(viewModel.isSharingOn ? Theme.Colors.accentFill : Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(viewModel.isSharingOn ? Color.clear : Theme.Colors.rule, lineWidth: Theme.Stroke.hairline))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text("Share my location")
                    .typeStyle(.title3)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Anonymous · about every 2 min")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            Toggle("Share my location", isOn: $viewModel.isSharingOn)
                .labelsHidden()
                .tint(Theme.Colors.accentFill)
        }
        .padding(16)
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
        .sensoryFeedback(.success, trigger: viewModel.isSharingOn) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.isSharingOn) { _, new in !new }
    }

    // MARK: Status

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatusTile(title: "Status", symbol: "dot.radiowaves.left.and.right", tint: viewModel.tint) {
                HStack(spacing: 8) {
                    PulsingDot(color: viewModel.tint, size: 8, isAnimating: viewModel.isActive)
                    Text(viewModel.statusLabel)
                }
            }

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

            StatusTile(title: "Interval", symbol: "arrow.triangle.2.circlepath", tint: Theme.Colors.accent) {
                Text("~2 minutes")
            }
        }
    }

    // MARK: How it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "How it works")

            HowItWorksStep(number: 1, symbol: "iphone.radiowaves.left.and.right", title: "Your phone checks in",
                           detail: "About every 2 minutes, while sharing is on, the app sends a rounded location, never your exact position.")
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
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Colors.ink)
                    .frame(height: Theme.Stroke.sectionRule)
                HStack {
                    Text("Your privacy").sectionLabelStyle()
                    Spacer()
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Theme.Colors.positive)
                }
                .padding(.top, 8)
            }
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

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
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
                .overlay(Circle().strokeBorder(Theme.Colors.ink, lineWidth: 2))

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(tint)
                Text(title).sectionLabelStyle()
            }
            value()
                .typeStyle(.metricSmall)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(cornerRadius: Theme.Radius.sm)
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
                Image(systemName: symbol)
                    .imageScale(.medium)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
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
