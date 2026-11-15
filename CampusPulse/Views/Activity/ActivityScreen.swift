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
                Group {
                    if let replay = viewModel.snapshot?.replayOf {
                        Text("Data from \(Formatting.dataDay(replay))")
                    } else {
                        UpdatedAgoText(date: viewModel.snapshot?.generatedAt)
                    }
                }
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            }
            Rectangle()
                .fill(Theme.Colors.ink)
                .frame(height: Theme.Stroke.sectionRule)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ snapshot: CampusSnapshot) -> some View {
        OverviewCard(snapshot: snapshot, participantsText: viewModel.participantsText, activeAreasText: viewModel.activeAreasText)

        if !viewModel.favorites.isEmpty {
            section(title: "Your places", trailing: "Saved") {
                areaList(viewModel.favorites)
            }
        }

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
            areaList(viewModel.allAreas)
        }

        privacyFooter
    }

    private func areaList(_ areas: [AreaActivity]) -> some View {
        VStack(spacing: 0) {
            ForEach(areas) { activity in
                NavigationLink(value: AreaRoute(areaID: activity.id)) {
                    CompactAreaRow(activity: activity, isFavorite: viewModel.isFavorite(activity.id))
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                if activity.id != areas.last?.id {
                    Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .card(cornerRadius: Theme.Radius.sm)
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
                        Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.sm)
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
                    .imageScale(.small)
            }
            .typeStyle(.micro)
            .foregroundStyle(Theme.Colors.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline))
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort areas, currently \(viewModel.sort.title)")
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Theme.Colors.surfaceStrong)
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
                .imageScale(.large)
                .foregroundStyle(Theme.Colors.positive)
            Text("All figures are estimates from anonymous, aggregated data. Counts are rounded, and areas with fewer than \(AppConfig.privacyThreshold) students are never shown.")
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.sm)
    }

    private func section<Content: View>(title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        section(title: title) {
            Text(trailing)
                .typeStyle(.micro)
                .foregroundStyle(Theme.Colors.accent)
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
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Colors.ink)
                    .frame(height: Theme.Stroke.sectionRule)
                HStack {
                    Text(title).sectionLabelStyle()
                        .contentTransition(.opacity)
                    Spacer()
                    trailing()
                }
                .frame(minHeight: 32)
            }
            content()
        }
    }
}

/// Navigation value for an area's detail screen.
struct AreaRoute: Hashable {
    let areaID: String
}

#Preview("Activity") {
    let container = PreviewData.container()
    ActivityScreen(viewModel: ActivityViewModel(store: container.store))
}

#Preview("Activity – Empty") {
    let container = PreviewData.container(campus: CampusCatalog.stanford)
    ActivityScreen(viewModel: ActivityViewModel(store: container.store))
}
