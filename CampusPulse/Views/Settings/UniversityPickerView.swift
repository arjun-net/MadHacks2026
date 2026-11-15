import SwiftUI

struct UniversityPickerView: View {
    let viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
        List {
            Section {
                ForEach(results) { campus in
                    Button {
                        viewModel.select(campus)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "building.columns.fill", color: campus.isPilot ? Theme.Colors.graphite : Theme.Colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(campus.name)
                                        .typeStyle(.headline)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    if campus.isPilot {
                                        Text("PILOT")
                                            .typeStyle(.micro)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .overlay(Rectangle().strokeBorder(Theme.Colors.warning, lineWidth: Theme.Stroke.hairline))
                                            .foregroundStyle(Theme.Colors.warning)
                                    }
                                }
                                Text(campus.location)
                                    .typeStyle(.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            Spacer()
                            if campus.id == viewModel.selectedCampus.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                    }
                }
            } footer: {
                Text("Don't see your school? Campus Pulse is rolling out to more universities soon.")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .listRowBackground(Theme.Colors.paper)
            .listRowSeparatorTint(Theme.Colors.rule)
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle("University")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search universities")
    }
}
