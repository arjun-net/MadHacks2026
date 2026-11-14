import SwiftUI

struct RootView: View {
    let container: AppContainer

    @State private var selectedTab: AppTab = .map
    @State private var isSharingSheetPresented = false
    @State private var mapViewModel: MapViewModel
    @State private var activityViewModel: ActivityViewModel
    @State private var sharingViewModel: LocationSharingViewModel
    @State private var settingsViewModel: SettingsViewModel

    init(container: AppContainer) {
        self.container = container
        _mapViewModel = State(initialValue: MapViewModel(store: container.store, sharing: container.sharing))
        _activityViewModel = State(initialValue: ActivityViewModel(store: container.store))
        _sharingViewModel = State(initialValue: LocationSharingViewModel(sharing: container.sharing, store: container.store))
        _settingsViewModel = State(initialValue: SettingsViewModel(
            store: container.store,
            preferences: container.preferences,
            sharing: container.sharing
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The map stays mounted so its camera and heatmap survive tab switches.
            MapScreen(viewModel: mapViewModel, onOpenSharing: { isSharingSheetPresented = true })
                .accessibilityHidden(selectedTab != .map)

            if selectedTab == .activity {
                ActivityScreen(viewModel: activityViewModel, onShowOnMap: showOnMap)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }

            if selectedTab == .settings {
                SettingsScreen(viewModel: settingsViewModel, sharingViewModel: sharingViewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }

            FloatingTabBar(selection: $selectedTab)
                .padding(.bottom, 4)
                .zIndex(2)
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $isSharingSheetPresented) {
            NavigationStack {
                LocationSharingScreen(viewModel: sharingViewModel)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isSharingSheetPresented = false }
                                .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.background)
            .presentationCornerRadius(32)
        }
        .task {
            container.store.start()
            applyDebugLaunchOptions()
        }
    }

    /// `-screen activity|settings|sharing|panel|denied` jumps straight to a screen (debug builds only).
    private func applyDebugLaunchOptions() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "screen") {
        case "activity": selectedTab = .activity
        case "settings": selectedTab = .settings
        case "sharing": isSharingSheetPresented = true
        case "panel": mapViewModel.isPanelExpanded = true
        case "denied":
            container.sharing.simulate(permission: .denied)
            isSharingSheetPresented = true
        default: break
        }
        #endif
    }

    private func showOnMap(_ areaID: String) {
        withAnimation(Theme.Motion.snappy) { selectedTab = .map }
        mapViewModel.select(areaID: areaID)
    }
}

#Preview {
    RootView(container: PreviewData.container())
        .preferredColorScheme(.dark)
}
