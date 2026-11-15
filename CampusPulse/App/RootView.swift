import SwiftUI

struct RootView: View {
    let container: AppContainer

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .map
    @State private var isSharingSheetPresented = false
    @State private var isOnboardingPresented: Bool
    @State private var mapViewModel: MapViewModel
    @State private var activityViewModel: ActivityViewModel
    @State private var sharingViewModel: LocationSharingViewModel
    @State private var settingsViewModel: SettingsViewModel

    init(container: AppContainer) {
        self.container = container
        _isOnboardingPresented = State(initialValue: !container.preferences.hasOnboarded && !container.store.isPreview)
        _mapViewModel = State(initialValue: MapViewModel(store: container.store, sharing: container.sharing))
        _activityViewModel = State(initialValue: ActivityViewModel(store: container.store))
        _sharingViewModel = State(initialValue: LocationSharingViewModel(sharing: container.sharing, store: container.store))
        _settingsViewModel = State(initialValue: SettingsViewModel(
            store: container.store,
            preferences: container.preferences,
            sharing: container.sharing,
            alerts: container.alerts
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The map stays mounted so its camera and heatmap survive tab switches.
            MapScreen(
                viewModel: mapViewModel,
                onOpenSharing: { isSharingSheetPresented = true },
                onOpenAreaDetails: openAreaDetails
            )
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
        // A building picked on the map is likely to be opened next: start on its history.
        .onChange(of: mapViewModel.selectedAreaID) { _, areaID in
            if let areaID { activityViewModel.prefetch(areaID: areaID) }
        }
        .sheet(isPresented: $isSharingSheetPresented) {
            LocationSharingScreen(viewModel: sharingViewModel, onDone: { isSharingSheetPresented = false })
                .safeAreaPadding(.top, 12) // clear of the drag indicator
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.background)
            .presentationCornerRadius(Theme.Radius.xl)
        }
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView(
                onShare: { finishOnboarding(sharing: true) },
                onSkip: { finishOnboarding(sharing: false) }
            )
        }
        .task {
            container.store.start()
            applyDebugLaunchOptions()
        }
        .onChange(of: scenePhase) { _, phase in
            // Only active/background matter; inactive is a brief transition (app switcher, alerts).
            guard phase != .inactive else { return }
            container.store.setForeground(phase == .active)
            if phase == .active { Task { await container.sharing.flushPending() } }
        }
    }

    /// `-screen activity|settings|sharing|denied|onboarding|detail` jumps straight to a screen (debug builds only).
    private func applyDebugLaunchOptions() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "screen") {
        case "activity": selectedTab = .activity
        case "settings": selectedTab = .settings
        case "sharing": isSharingSheetPresented = true
        case "onboarding": isOnboardingPresented = true
        case "detail": openAreaDetails(mapViewModel.campus.areas.first?.id ?? "")
        case "denied":
            container.sharing.simulate(permission: .denied)
            isSharingSheetPresented = true
        default: break
        }
        #endif
    }

    /// Sharing asks iOS for location access right after the intro closes.
    private func finishOnboarding(sharing: Bool) {
        container.preferences.hasOnboarded = true
        isOnboardingPresented = false
        container.sharing.setEnabled(sharing)
    }

    private func openAreaDetails(_ areaID: String) {
        activityViewModel.path = [AreaRoute(areaID: areaID)]
        withAnimation(Theme.Motion.snappy) { selectedTab = .activity }
    }

    private func showOnMap(_ areaID: String) {
        withAnimation(Theme.Motion.snappy) { selectedTab = .map }
        mapViewModel.select(areaID: areaID)
    }
}

#Preview {
    RootView(container: PreviewData.container())
}
