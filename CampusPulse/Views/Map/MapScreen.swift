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

            if viewModel.is3D {
                Campus3DMapView(
                    campus: viewModel.campus,
                    snapshot: viewModel.snapshot,
                    isHeatmapVisible: viewModel.isHeatmapVisible,
                    selectedAreaID: viewModel.selectedAreaID,
                    recenterToken: viewModel.recenterToken,
                    onSelectArea: { viewModel.select(areaID: $0) }
                )
                .id(viewModel.campus.id)
                .ignoresSafeArea()
                .transition(.opacity)
            }

            edgeScrims

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
                        is3D: viewModel.is3D,
                        onRecenter: viewModel.recenter,
                        onToggleHeatmap: { withAnimation(Theme.Motion.snappy) { viewModel.toggleHeatmap() } },
                        onToggle3D: { withAnimation(Theme.Motion.smooth) { viewModel.toggle3D() } }
                    )
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 10) {
                    statusBar
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
        .animation(Theme.Motion.smooth, value: viewModel.loadState)
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

    /// Loading, empty and error messages as a slim bar at the bottom, never over the middle of
    /// the map: a card there swallowed pinches, so the map couldn't be zoomed until it went away.
    /// Only the error bar takes touches (for Try again).
    @ViewBuilder
    private var statusBar: some View {
        if viewModel.showsInitialLoading {
            MapStatusBar(text: "Loading campus activity…", showsProgress: true)
                .allowsHitTesting(false)
                .transition(.opacity)
        } else if case .failed(let message) = viewModel.loadState {
            MapStatusBar(text: message, isError: true, onRetry: viewModel.retry)
                .transition(.opacity)
        } else if viewModel.loadState == .empty, viewModel.selectedActivity == nil {
            MapStatusBar(text: "Not enough people sharing at \(viewModel.campus.shortName) to show crowds yet.")
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// One line of map status over the bottom of the map.
private struct MapStatusBar: View {
    let text: String
    var showsProgress = false
    var isError = false
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small).tint(Theme.Colors.ink)
            } else if isError {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.Colors.warning)
            }
            Text(text)
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRetry {
                Button("Try again", action: onRetry)
                    .typeStyle(.button)
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, onRetry == nil ? 12 : 2)
        .paper(cornerRadius: Theme.Radius.sm)
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
