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
                            SettingsIcon(symbol: "building.columns.fill", color: campus.isPilot ? Theme.Colors.graphite : Theme.Colors.badgerRed)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(campus.name)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    if campus.isPilot {
                                        Text("PILOT")
                                            .font(.cpMicro)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.Colors.warning.opacity(0.2), in: Capsule())
                                            .foregroundStyle(Theme.Colors.warning)
                                    }
                                }
                                Text(campus.location)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            Spacer()
                            if campus.id == viewModel.selectedCampus.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                    }
                }
            } footer: {
                Text("Don't see your school? Campus Pulse is rolling out to more universities soon.")
            }
        }
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle("University")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search universities")
    }
}
