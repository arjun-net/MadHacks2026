import SwiftUI

struct MapScreen: View {
    @Bindable var viewModel: MapViewModel
    var onOpenSharing: () -> Void

    var body: some View {
        ZStack {
            CampusMapView(
                campus: viewModel.campus,
                snapshot: viewModel.snapshot,
                isHeatmapVisible: viewModel.isHeatmapVisible,
                selectedAreaID: viewModel.selectedAreaID,
                recenterToken: viewModel.recenterToken,
                onSelectArea: { viewModel.select(areaID: $0) }
            )
            .ignoresSafeArea()

            edgeScrims

            stateOverlay

            VStack(spacing: 12) {
                MapHeader(
                    campus: viewModel.campus,
                    snapshot: viewModel.snapshot,
                    isRefreshing: viewModel.store.isRefreshing,
                    sharingStatus: viewModel.sharingStatus,
                    onOpenSharing: onOpenSharing
                )

                HStack(alignment: .top) {
                    Spacer()
                    MapControlStack(
                        isHeatmapVisible: viewModel.isHeatmapVisible,
                        onRecenter: viewModel.recenter,
                        onToggleHeatmap: { withAnimation(Theme.Motion.snappy) { viewModel.toggleHeatmap() } }
                    )
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 10) {
                    if let focused = viewModel.selectedActivity {
                        AreaFocusCard(activity: focused) { viewModel.select(areaID: nil) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(focused.id)
                    } else if viewModel.isHeatmapVisible, viewModel.snapshot?.isEmpty == false {
                        HeatLegend()
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }

                    ActivityPanel(
                        snapshot: viewModel.snapshot,
                        loadState: viewModel.loadState,
                        isExpanded: $viewModel.isPanelExpanded,
                        onSelectArea: { viewModel.select(areaID: $0) }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 4)
            .padding(.bottom, Theme.tabBarClearance)
        }
        .animation(Theme.Motion.smooth, value: viewModel.selectedAreaID)
        .animation(Theme.Motion.smooth, value: viewModel.isHeatmapVisible)
        .onChange(of: viewModel.campus.id) { _, _ in viewModel.campusDidChange() }
    }

    /// Soft dark fades at the top and bottom keep floating chrome legible over the map.
    private var edgeScrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if viewModel.showsInitialLoading {
            LoadingStateView()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if case .failed(let message) = viewModel.loadState {
            ErrorStateView(message: message, retry: viewModel.retry)
                .glass(cornerRadius: Theme.Radius.xl)
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if viewModel.loadState == .empty {
            EmptyActivityView(
                threshold: viewModel.snapshot?.privacyThreshold ?? AppConfig.privacyThreshold,
                campusName: viewModel.campus.shortName
            )
            .glass(cornerRadius: Theme.Radius.xl)
            .padding(.horizontal, 24)
            .offset(y: -60)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

#Preview("Map") {
    let container = PreviewData.container()
    MapScreen(
        viewModel: MapViewModel(store: container.store, sharing: container.sharing),
        onOpenSharing: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Map – Loading") {
    let container = PreviewData.container(preloaded: false)
    MapScreen(
        viewModel: MapViewModel(store: container.store, sharing: container.sharing),
        onOpenSharing: {}
    )
    .preferredColorScheme(.dark)
}
