import SwiftUI

/// Detail for one hall or building: live reading, usual busy times by weekday,
/// today compared with a normal day, and the past week.
struct AreaDetailScreen: View {
    let areaID: String
    @Bindable var viewModel: ActivityViewModel
    var onShowOnMap: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if let activity = viewModel.activity(for: areaID), let insights = viewModel.insights(for: areaID) {
                content(activity: activity, insights: insights)
            } else {
                ErrorStateView(message: "This area isn't reporting right now.") { Task { await viewModel.refresh() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ScreenBackground())
        .paperNavigationBar(showsRule: false) {
            let isFavorite = viewModel.isFavorite(areaID)
            // Joined like the map controls: one paper strip, a hairline between.
            HStack(spacing: 0) {
                Button {
                    withAnimation(Theme.Motion.snappy) { viewModel.toggleFavorite(areaID) }
                } label: {
                    PaperIconLabel(symbol: isFavorite ? "star.fill" : "star", tint: Theme.Colors.accent)
                }
                .accessibilityLabel(isFavorite ? "Remove from your places" : "Save to your places")
                .sensoryFeedback(.selection, trigger: isFavorite)
                Rectangle().fill(Theme.Colors.border).frame(width: Theme.Stroke.hairline, height: 42)
                Button { onShowOnMap(areaID) } label: {
                    PaperIconLabel(symbol: "map", tint: Theme.Colors.accent)
                }
                .accessibilityLabel("Show on map")
            }
            .buttonStyle(PressableButtonStyle())
            .paper(cornerRadius: Theme.Radius.sm)
        }
    }

    private func content(activity: AreaActivity, insights: AreaInsights) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(activity)

                Button { onShowOnMap(areaID) } label: {
                    MapPreviewCard(campus: viewModel.campus, activity: activity)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Show \(activity.area.name) on the map")

                LiveCard(activity: activity, insights: insights)
                PopularTimesSection(insights: insights, liveIntensity: activity.intensity)
                TodayVersusUsualSection(insights: insights)
                PastWeekSection(insights: insights)

                Text("History and usual times are estimates built from anonymous, aggregated activity.")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 4)
            .padding(.bottom, Theme.tabBarClearance + 20)
            .animation(Theme.Motion.smooth, value: activity.intensity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.refresh() }
    }

    private func header(_ activity: AreaActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerTitle(activity)
            Rectangle()
                .fill(Theme.Colors.sectionRule)
                .frame(height: Theme.Stroke.sectionRule)
        }
    }

    private func headerTitle(_ activity: AreaActivity) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AreaIconTile(symbol: activity.area.symbol, color: activity.level.textColor, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.area.name)
                    .typeStyle(.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(activity.area.category.title)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }
}
