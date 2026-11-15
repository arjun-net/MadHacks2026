import SwiftUI

struct UniversityPickerView: View {
    let viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var results: [Campus] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return viewModel.campuses }
        return viewModel.campuses.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.shortName.localizedCaseInsensitiveContains(trimmed)
                || $0.location.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField

                if results.isEmpty {
                    noResults
                } else {
                    SettingsSection(
                        title: "Universities",
                        footer: "Campuses marked Coming soon don't have enough people sharing yet. More universities are on the way."
                    ) {
                        ForEach(results) { campus in
                            row(campus)
                            if campus.id != results.last?.id { RowRule() }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 8)
            .padding(.bottom, Theme.tabBarClearance + 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(ScreenBackground(ruled: false))
        .paperNavigationBar("University")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Colors.textSecondary)
            TextField("Search universities", text: $query)
                .typeStyle(.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 46)
        .paper(cornerRadius: Theme.Radius.sm)
        .onTapGesture { isSearchFocused = true }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.cpTitle)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No results for \u{201C}\(query)\u{201D}")
                .typeStyle(.title3)
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("Check the spelling or try a new search.")
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .card(cornerRadius: Theme.Radius.sm)
    }

    private func row(_ campus: Campus) -> some View {
        Button {
            viewModel.select(campus)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "building.columns.fill", color: campus.isAvailable ? Theme.Colors.accent : Theme.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(campus.name)
                            .typeStyle(.headline)
                            .foregroundStyle(campus.isAvailable ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                        if !campus.isAvailable {
                            Text("Coming soon")
                                .typeStyle(.micro)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.textTertiary, lineWidth: Theme.Stroke.hairline))
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    Text(campus.location)
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                if campus.id == viewModel.selectedCampus.id {
                    Image(systemName: "checkmark")
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.vertical, 10)
            .settingsRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!campus.isAvailable)
        .accessibilityAddTraits(campus.id == viewModel.selectedCampus.id ? .isSelected : [])
        .accessibilityHint(campus.isAvailable ? "" : "Coming soon")
    }
}
