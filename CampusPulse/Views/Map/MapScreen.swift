import SwiftUI

struct MapScreen: View {
    @Bindable var viewModel: MapViewModel
    var onOpenSharing: () -> Void
    var onOpenAreaDetails: (String) -> Void = { _ in }

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
                    onOpenSharing: onOpenSharing,
                    onSelectArea: { viewModel.select(areaID: $0) }
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
                        AreaFocusCard(
                            activity: focused,
                            isFavorite: viewModel.isFavorite(focused.id),
                            onToggleFavorite: { viewModel.toggleFavorite(focused.id) },
                            onClose: { viewModel.select(areaID: nil) },
                            onOpenDetails: { onOpenAreaDetails(focused.id) }
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(focused.id)
                    } else if viewModel.isHeatmapVisible, viewModel.snapshot?.isEmpty == false {
                        HeatLegend()
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 8)
            .padding(.bottom, Theme.tabBarClearance)
        }
        .animation(Theme.Motion.smooth, value: viewModel.selectedAreaID)
        .animation(Theme.Motion.smooth, value: viewModel.isHeatmapVisible)
        .onChange(of: viewModel.campus.id) { _, _ in viewModel.campusDidChange() }
    }

    /// Newsprint fades at the top and bottom keep floating chrome legible over the map.
    private var edgeScrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.Colors.mapScrim.opacity(0.9), Theme.Colors.mapScrim.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
            Spacer()
            LinearGradient(colors: [Theme.Colors.mapScrim.opacity(0), Theme.Colors.mapScrim.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
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
                .paper(cornerRadius: Theme.Radius.sm)
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if viewModel.loadState == .empty {
            EmptyActivityView(
                threshold: viewModel.snapshot?.privacyThreshold ?? AppConfig.privacyThreshold,
                campusName: viewModel.campus.shortName
            )
            .paper(cornerRadius: Theme.Radius.sm)
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
}

#Preview("Map – Loading") {
    let container = PreviewData.container(preloaded: false)
    MapScreen(
        viewModel: MapViewModel(store: container.store, sharing: container.sharing),
        onOpenSharing: {}
    )
}

#Preview("Map – Night") {
    let container = PreviewData.container()
    MapScreen(
        viewModel: MapViewModel(store: container.store, sharing: container.sharing),
        onOpenSharing: {}
    )
    .preferredColorScheme(.dark)
}
