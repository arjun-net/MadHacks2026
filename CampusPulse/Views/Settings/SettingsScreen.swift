import SwiftUI

struct SettingsScreen: View {
    @Bindable var viewModel: SettingsViewModel
    let sharingViewModel: LocationSharingViewModel

    @State private var isConfirmingDelete = false

    var body: some View {
        @Bindable var preferences = viewModel.preferences

        NavigationStack {
            Form {
                Section {
                    CampusBanner(campus: viewModel.selectedCampus)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        UniversityPickerView(viewModel: viewModel)
                    } label: {
                        SettingsRow(symbol: "building.columns.fill", color: Theme.Colors.badgerRed, title: "University", value: viewModel.selectedCampus.shortName)
                    }
                } header: {
                    Text("Campus")
                }

                Section {
                    NavigationLink {
                        LocationSharingScreen(viewModel: sharingViewModel)
                    } label: {
                        SettingsRow(
                            symbol: "location.fill",
                            color: Theme.Colors.badgerRed,
                            title: "Location Sharing",
                            value: viewModel.sharingStatusLabel
                        )
                    }

                    HStack {
                        SettingsLabel(symbol: "location.circle.fill", color: Theme.Colors.graphite, title: "Location Access")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.permission.tint)
                                .frame(width: 7, height: 7)
                            Text(viewModel.permission.displayName)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }

                    Toggle(isOn: $preferences.shareOnlyOnCampus) {
                        SettingsLabel(symbol: "mappin.and.ellipse", color: Theme.Colors.graphite, title: "Only Share on Campus")
                    }
                    Toggle(isOn: $preferences.pauseOvernight) {
                        SettingsLabel(symbol: "moon.zzz.fill", color: Theme.Colors.graphite, title: "Pause Overnight")
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("While sharing is on, your rounded location is sent about every 2 minutes. Sharing pauses automatically off campus and between midnight and 6 AM if enabled.")
                }

                Section {
                    Toggle(isOn: $preferences.busyAreaAlerts) {
                        SettingsLabel(symbol: "flame.fill", color: Theme.Colors.badgerRed, title: "Busy Area Alerts")
                    }
                    Toggle(isOn: $preferences.quietSpotAlerts) {
                        SettingsLabel(symbol: "leaf.fill", color: Theme.Colors.graphite, title: "Quiet Study Spots")
                    }
                    Toggle(isOn: $preferences.weeklyRecap) {
                        SettingsLabel(symbol: "calendar", color: Theme.Colors.graphite, title: "Weekly Campus Recap")
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get a heads-up when your favorite places get busy or quiet down.")
                }

                Section {
                    NavigationLink {
                        PrivacyInfoView()
                    } label: {
                        SettingsLabel(symbol: "hand.raised.fill", color: Theme.Colors.graphite, title: "How Your Data Is Protected")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        HStack {
                            SettingsLabel(symbol: "trash.fill", color: .red, title: "Delete My Shared Data")
                            Spacer()
                            if viewModel.isDeletingData { ProgressView() }
                        }
                    }
                    .tint(Theme.Colors.danger)
                    .disabled(viewModel.isDeletingData)
                } header: {
                    Text("Privacy")
                }

                Section {
                    NavigationLink {
                        AboutView(version: viewModel.appVersion)
                    } label: {
                        SettingsLabel(symbol: "info.circle.fill", color: .gray, title: "About Campus Pulse")
                    }
                    LabeledContent {
                        Text(viewModel.appVersion).monospacedDigit()
                    } label: {
                        SettingsLabel(symbol: "number", color: Color(white: 0.35), title: "Version")
                    }
                } header: {
                    Text("About")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ScreenBackground())
            .navigationTitle("Settings")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: Theme.tabBarClearance - 10) }
            .confirmationDialog(
                "Delete your shared data?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Shared Data", role: .destructive) {
                    Task { await viewModel.deleteSharedData() }
                }
            } message: {
                Text("This removes your past contributions from campus activity. It doesn't turn off sharing.")
            }
            .alert(
                viewModel.deletionMessage ?? "",
                isPresented: Binding(
                    get: { viewModel.deletionMessage != nil },
                    set: { if !$0 { viewModel.deletionMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

// MARK: - Rows

struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

struct SettingsLabel: View {
    let symbol: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }
}

struct SettingsRow: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack {
            SettingsLabel(symbol: symbol, color: color, title: title)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}

private struct CampusBanner: View {
    let campus: Campus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Theme.Gradients.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.Colors.accent.opacity(0.5), radius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(campus.name)
                    .font(.cpHeadline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(campus.location)
                    if campus.isPilot {
                        Text("PILOT")
                            .font(.cpMicro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.warning.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
                .font(.cpCaption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.lg)
    }
}

#Preview {
    let container = PreviewData.container()
    SettingsScreen(
        viewModel: SettingsViewModel(store: container.store, preferences: container.preferences, sharing: container.sharing),
        sharingViewModel: LocationSharingViewModel(sharing: container.sharing, store: container.store)
    )
    .preferredColorScheme(.dark)
}
