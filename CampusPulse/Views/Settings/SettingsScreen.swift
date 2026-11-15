import SwiftUI

struct SettingsScreen: View {
    @Bindable var viewModel: SettingsViewModel
    let sharingViewModel: LocationSharingViewModel

    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var preferences = viewModel.preferences

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    CampusBanner(campus: viewModel.selectedCampus)

                    SettingsSection(title: "Campus") {
                        NavigationLink {
                            UniversityPickerView(viewModel: viewModel)
                        } label: {
                            SettingsRow(symbol: "building.columns.fill", color: Theme.Colors.accent, title: "University", value: viewModel.selectedCampus.shortName)
                        }
                        .buttonStyle(RowButtonStyle())
                    }

                    SettingsSection(
                        title: "Location",
                        footer: "While sharing is on, your location is sent every 2 minutes. Sharing pauses automatically off campus and between midnight and 6 AM if enabled."
                    ) {
                        NavigationLink {
                            LocationSharingScreen(viewModel: sharingViewModel)
                        } label: {
                            SettingsRow(
                                symbol: "location.fill",
                                color: Theme.Colors.accent,
                                title: "Location Sharing",
                                value: viewModel.sharingStatusLabel
                            )
                        }
                        .buttonStyle(RowButtonStyle())
                        RowRule()

                        HStack {
                            SettingsLabel(symbol: "location.circle.fill", color: Theme.Colors.graphite, title: "Location Access")
                            Spacer()
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(viewModel.permission.tint)
                                    .frame(width: 7, height: 7)
                                Text(viewModel.permissionLabel)
                                    .typeStyle(.subheadline)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        .settingsRow()
                        .accessibilityElement(children: .combine)
                        RowRule()

                        Toggle(isOn: $preferences.shareOnlyOnCampus) {
                            SettingsLabel(symbol: "mappin.and.ellipse", color: Theme.Colors.graphite, title: "Only Share on Campus")
                        }
                        .settingsRow()
                        RowRule()
                        Toggle(isOn: $preferences.pauseOvernight) {
                            SettingsLabel(symbol: "moon.zzz.fill", color: Theme.Colors.graphite, title: "Pause Overnight")
                        }
                        .settingsRow()
                    }

                    // The picker is its own bordered box, so it isn't wrapped in a card.
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Display")
                        PaperSegmentedPicker(
                            title: "Appearance",
                            options: Appearance.allCases,
                            selection: $preferences.appearance,
                            label: \.title
                        )
                        Text("Day Edition is the default. Night Edition is easier on the eyes after dark.")
                            .typeStyle(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    SettingsSection(
                        title: "Notifications",
                        footer: "Get a heads-up when your favorite places get busy or quiet down."
                    ) {
                        Toggle(isOn: $preferences.busyAreaAlerts) {
                            SettingsLabel(symbol: "flame.fill", color: Theme.Colors.accent, title: "Busy Area Alerts")
                        }
                        .settingsRow()
                        RowRule()
                        Toggle(isOn: $preferences.quietSpotAlerts) {
                            SettingsLabel(symbol: "leaf.fill", color: Theme.Colors.graphite, title: "Quiet Study Spots")
                        }
                        .settingsRow()
                        RowRule()
                        Toggle(isOn: $preferences.weeklyRecap) {
                            SettingsLabel(symbol: "calendar", color: Theme.Colors.graphite, title: "Weekly Campus Recap")
                        }
                        .settingsRow()
                    }

                    SettingsSection(
                        title: "Privacy",
                        footer: "Readings carry a random ID, never your name or account. Resetting it means future readings can't be linked to past ones."
                    ) {
                        NavigationLink {
                            PrivacyInfoView()
                        } label: {
                            SettingsRow(symbol: "hand.raised.fill", color: Theme.Colors.graphite, title: "How Your Data Is Protected")
                        }
                        .buttonStyle(RowButtonStyle())
                        RowRule()
                        Button(role: .destructive) {
                            isConfirmingReset = true
                        } label: {
                            SettingsLabel(symbol: "arrow.triangle.2.circlepath", color: Theme.Colors.danger, title: "Reset Device ID", titleColor: Theme.Colors.danger)
                                .settingsRow()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }

                    SettingsSection(title: "About") {
                        NavigationLink {
                            AboutView(version: viewModel.appVersion)
                        } label: {
                            SettingsRow(symbol: "info.circle.fill", color: Theme.Colors.graphite, title: "About Campus Pulse")
                        }
                        .buttonStyle(RowButtonStyle())
                        RowRule()
                        HStack {
                            SettingsLabel(symbol: "number", color: Theme.Colors.graphite, title: "Version")
                            Spacer()
                            Text(viewModel.appVersion)
                                .typeStyle(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .settingsRow()
                        .accessibilityElement(children: .combine)
                    }
                }
                .toggleStyle(.paper)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 8)
                .padding(.bottom, Theme.tabBarClearance + 20)
            }
            .scrollIndicators(.hidden)
            .background(ScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "Reset your device ID?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset Device ID", role: .destructive) {
                    viewModel.resetDeviceID()
                }
            } message: {
                Text("Readings sent from now on get a new random ID, and any readings still waiting to send are discarded. Sharing stays on.")
            }
            .alert(
                viewModel.resetMessage ?? "",
                isPresented: Binding(
                    get: { viewModel.resetMessage != nil },
                    set: { if !$0 { viewModel.resetMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    /// Masthead title with a 2pt rule, matching the Activity tab.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .typeStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Theme.Colors.ink)
                .frame(height: Theme.Stroke.sectionRule)
        }
        .padding(.top, 8)
    }
}

// MARK: - Rows

struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .imageScale(.medium)
            .foregroundStyle(color)
            .frame(width: 29, height: 29)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.rule, lineWidth: Theme.Stroke.hairline))
    }
}

struct SettingsLabel: View {
    let symbol: String
    let color: Color
    let title: String
    var titleColor: Color = Theme.Colors.textPrimary

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
                .typeStyle(.body)
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.leading)
        }
    }
}

/// A tappable row that opens another screen: icon, title, optional value, chevron.
struct SettingsRow: View {
    let symbol: String
    let color: Color
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            SettingsLabel(symbol: symbol, color: color, title: title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .settingsRow()
        .contentShape(Rectangle())
    }
}

private struct CampusBanner: View {
    let campus: Campus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "building.columns.fill")
                .imageScale(.large)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 54, height: 54)
                .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(campus.name)
                    .typeStyle(.title3)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                Text(campus.location)
                    .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
        .padding(.trailing, Theme.Shadow.offset.width)
        .padding(.bottom, Theme.Shadow.offset.height)
    }
}

#Preview {
    let container = PreviewData.container()
    SettingsScreen(
        viewModel: SettingsViewModel(store: container.store, preferences: container.preferences, sharing: container.sharing),
        sharingViewModel: LocationSharingViewModel(sharing: container.sharing, store: container.store)
    )
}
