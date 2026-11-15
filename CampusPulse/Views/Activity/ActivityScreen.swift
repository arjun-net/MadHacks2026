import Charts
import SwiftUI

struct ActivityScreen: View {
    @Bindable var viewModel: ActivityViewModel
    var onShowOnMap: (String) -> Void = { _ in }

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    switch viewModel.loadState {
                    case .idle:
                        loadingContent
                    case .loading where viewModel.snapshot == nil:
                        loadingContent
                    case .failed(let message) where viewModel.snapshot == nil:
                        ErrorStateView(message: message) { Task { await viewModel.refresh() } }
                            .frame(maxWidth: .infinity)
                            .card(cornerRadius: Theme.Radius.xl)
                    case .empty:
                        EmptyActivityView(
                            threshold: viewModel.snapshot?.privacyThreshold ?? AppConfig.privacyThreshold,
                            campusName: viewModel.campus.shortName
                        )
                        .frame(maxWidth: .infinity)
                        .card(cornerRadius: Theme.Radius.xl)
                        privacyFooter
                    default:
                        if let snapshot = viewModel.snapshot {
                            content(snapshot)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 8)
                .padding(.bottom, Theme.tabBarClearance + 20)
                .animation(Theme.Motion.smooth, value: viewModel.snapshot?.generatedAt)
            }
            .scrollIndicators(.hidden)
            .refreshable { await viewModel.refresh() }
            .background(ScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AreaRoute.self) { route in
                AreaDetailScreen(areaID: route.areaID, viewModel: viewModel, onShowOnMap: onShowOnMap)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulsingDot(color: Theme.Colors.live, size: 7)
                Text(viewModel.campus.name)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .typeStyle(.largeTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                UpdatedAgoText(date: viewModel.snapshot?.generatedAt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ snapshot: CampusSnapshot) -> some View {
        OverviewCard(snapshot: snapshot, participantsText: viewModel.participantsText, activeAreasText: viewModel.activeAreasText)

        FilterBar(
            filters: viewModel.availableFilters,
            selection: $viewModel.filter,
            count: viewModel.count(for:)
        )

        // With only a handful of matches, the ranked sections would just repeat the list.
        if viewModel.allAreas.count > 5 {
            rankedSections
        }

        section(title: viewModel.filter == .all ? "All areas" : viewModel.filter.title) {
            sortMenu
        } content: {
            VStack(spacing: 0) {
                ForEach(viewModel.allAreas) { activity in
                    NavigationLink(value: AreaRoute(areaID: activity.id)) {
                        CompactAreaRow(activity: activity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    if activity.id != viewModel.allAreas.last?.id {
                        Divider().overlay(Color.white.opacity(0.04))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.lg)
        }

        privacyFooter
    }

    @ViewBuilder
    private var rankedSections: some View {
        section(title: "Busiest right now", trailing: "Top 5") {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.busiest.enumerated()), id: \.element.id) { index, activity in
                    NavigationLink(value: AreaRoute(areaID: activity.id)) {
                        AreaActivityRow(activity: activity, rank: index + 1)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityHint("Shows usual busy times and past activity")
                    if index < viewModel.busiest.count - 1 {
                        Divider().overlay(Color.white.opacity(0.04))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.lg)
        }

        section(title: "Quiet spots", trailing: "Good for focus") {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(viewModel.quietSpots) { activity in
                        NavigationLink(value: AreaRoute(areaID: activity.id)) {
                            QuietSpotCard(activity: activity)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $viewModel.sort) {
                ForEach(AreaSort.allCases) { sort in
                    Label(sort.title, systemImage: sort.symbol).tag(sort)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(viewModel.allAreas.count) · \(viewModel.sort.shortTitle)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .accessibilityLabel("Sort areas, currently \(viewModel.sort.title)")
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 280)
                .shimmering()
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBlock(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 160, height: 12)
                        SkeletonBlock(height: 6)
                    }
                }
            }
        }
        .accessibilityLabel("Loading activity")
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Gradients.live)
            Text("All figures are estimates from anonymous, aggregated data. Counts are rounded, and areas with fewer than \(AppConfig.privacyThreshold) students are never shown.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.md)
    }

    private func section<Content: View>(title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        section(title: title) {
            Text(trailing)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textTertiary)
        } content: {
            content()
        }
    }

    private func section<Trailing: View, Content: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).sectionLabelStyle()
                    .contentTransition(.opacity)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 4)
            content()
        }
    }
}

// MARK: - Filters

/// Horizontally scrolling category chips (Study, Dining, …).
private struct FilterBar: View {
    let filters: [AreaFilter]
    @Binding var selection: AreaFilter
    let count: (AreaFilter) -> Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    let selected = filter == selection
                    Button {
                        withAnimation(Theme.Motion.snappy) { selection = filter }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.symbol)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(filter.title)
                                .font(.system(size: 13.5, weight: .semibold))
                            if filter != .all {
                                Text("\(count(filter))")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .opacity(0.55)
                            }
                        }
                        .foregroundStyle(selected ? Theme.Colors.background : Theme.Colors.textSecondary)
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background {
                            Capsule().fill(selected ? Theme.Colors.textPrimary : Color.white.opacity(0.07))
                        }
                        .overlay {
                            Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.title), \(count(filter)) places")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.Spacing.md)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Navigation value for an area's detail screen.
struct AreaRoute: Hashable {
    let areaID: String
}

// MARK: - Overview

private struct OverviewCard: View {
    let snapshot: CampusSnapshot
    let participantsText: String
    let activeAreasText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                ZStack {
                    ActivityGauge(intensity: snapshot.overallIntensity, lineWidth: 11)
                    VStack(spacing: 2) {
                        Image(systemName: snapshot.level.symbol)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(snapshot.level.color)
                            .contentTransition(.symbolEffect(.replace))
                        Text(snapshot.level.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text("\(Int((snapshot.overallIntensity * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: 124, height: 124)

                VStack(alignment: .leading, spacing: 14) {
                    metric(value: participantsText, label: "students sharing", symbol: "person.2.fill")
                    metric(value: activeAreasText, label: "areas active", symbol: "mappin.and.ellipse")
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.trend.symbol)
                        Text(snapshot.trend.title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(snapshot.level.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(snapshot.level.color.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Campus activity").sectionLabelStyle()
                    Spacer()
                    Text("Last 24 min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                CampusTrendChart(history: snapshot.history, updatedAt: snapshot.generatedAt)
                    .frame(height: 96)
            }
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.xl)
    }

    private func metric(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .typeStyle(.metricSmall)
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.numericText())
            Label(label, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

private struct CampusTrendChart: View {
    let history: [Double]
    let updatedAt: Date

    private struct Sample: Identifiable {
        let id: Int
        let minutesAgo: Int
        let value: Double
    }

    private var samples: [Sample] {
        let step = Int(AppConfig.updateInterval / 60)
        return history.enumerated().map { index, value in
            Sample(id: index, minutesAgo: (history.count - 1 - index) * step, value: value)
        }
    }

    /// Zoom the y-axis to the data so small swings are visible, without exaggerating noise.
    private var yDomain: ClosedRange<Double> {
        let low = history.min() ?? 0
        let high = history.max() ?? 1
        let padding = max(0.06, (high - low) * 0.6)
        return max(0, low - padding)...min(1, high + padding)
    }

    var body: some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Minutes ago", -sample.minutesAgo),
                yStart: .value("Baseline", yDomain.lowerBound),
                yEnd: .value("Activity", sample.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [HeatPalette.color(at: 0.8).opacity(0.45), HeatPalette.color(at: 0.2).opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Minutes ago", -sample.minutesAgo),
                y: .value("Activity", sample.value)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .foregroundStyle(
                LinearGradient(
                    colors: [HeatPalette.color(at: 0.3), HeatPalette.color(at: 0.65), HeatPalette.color(at: 0.9)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: -samples.count * 2 + 2 ... 0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { _ in
            VStack {
                Spacer()
                HStack {
                    Text("\((samples.count - 1) * 2)m ago")
                    Spacer()
                    Text("Now")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.textTertiary)
                .offset(y: 16)
            }
        }
        .padding(.bottom, 14)
        .accessibilityLabel("Campus activity over the last 24 minutes")
    }
}

// MARK: - Cards & rows

private struct QuietSpotCard: View {
    let activity: AreaActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AreaIconTile(symbol: activity.area.symbol, color: activity.level.color, size: 36)
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
            Sparkline(values: activity.history, color: activity.level.color, lineWidth: 1.5)
                .frame(height: 24)
        }
        .padding(14)
        .frame(width: 168)
        .card(cornerRadius: Theme.Radius.md)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactAreaRow: View {
    let activity: AreaActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.area.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activity.level.color)
                .frame(width: 24)
            Text(activity.area.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ActivityBar(intensity: activity.intensity, height: 4)
                .frame(width: 64)
            Text(activity.level.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(activity.level.color)
                .frame(width: 66, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activity.area.name), \(activity.level.title)")
    }
}

#Preview("Activity") {
    let container = PreviewData.container()
    ActivityScreen(viewModel: ActivityViewModel(store: container.store))
}

#Preview("Activity – Empty") {
    let container = PreviewData.container(campus: CampusCatalog.stanford)
    ActivityScreen(viewModel: ActivityViewModel(store: container.store))
}
