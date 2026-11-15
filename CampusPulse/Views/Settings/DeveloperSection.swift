import SwiftUI

#if DEBUG
/// Debug builds only: point the app at a new server (the Cloudflare tunnel URL changes on
/// every restart) or another stored day, without rebuilding.
struct DeveloperSection: View {
    var onApply: () -> Void

    @State private var serverURL = UserDefaults.standard.string(forKey: AppConfig.Overrides.apiBaseURL) ?? ""
    @State private var historyDay = UserDefaults.standard.string(forKey: AppConfig.Overrides.historyDay) ?? ""
    @State private var health: Health = .unknown

    private enum Health: Equatable {
        case unknown, checking, ok, failed

        var label: String {
            switch self {
            case .unknown: "Not checked"
            case .checking: "Checking…"
            case .ok: "Connected"
            case .failed: "Unreachable"
            }
        }

        var color: Color {
            switch self {
            case .ok: Theme.Colors.positive
            case .failed: Theme.Colors.danger
            case .unknown, .checking: Theme.Colors.textTertiary
            }
        }
    }

    private var urlIsValid: Bool {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let url = URL(string: trimmed) else { return false }
        return (url.scheme == "https" || url.scheme == "http") && url.host() != nil
    }

    private var dayIsValid: Bool {
        historyDay.trimmingCharacters(in: .whitespaces).isEmpty || AppConfig.parseDay(historyDay) != nil
    }

    var body: some View {
        SettingsSection(
            title: "Developer",
            footer: "Debug builds only. Leave a field empty to use the built-in value."
        ) {
            field(title: "Server", placeholder: AppConfig.defaultAPIBaseURL.absoluteString, text: $serverURL, isValid: urlIsValid)
                .keyboardType(.URL)
            RowRule(inset: 14)
            field(title: "Stored day", placeholder: "2026-01-01", text: $historyDay, isValid: dayIsValid)
                .keyboardType(.numbersAndPunctuation)
            RowRule(inset: 14)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(health.color).frame(width: 7, height: 7)
                    Text(health.label)
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Button("Apply") { apply() }
                    .typeStyle(.button)
                    .foregroundStyle(urlIsValid && dayIsValid ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .disabled(!urlIsValid || !dayIsValid)
                    .frame(minHeight: 44)
            }
            .settingsRow()
        }
        .task { await checkHealth() }
    }

    private func field(title: String, placeholder: String, text: Binding<String>, isValid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .typeStyle(.micro)
                .foregroundStyle(isValid ? Theme.Colors.textTertiary : Theme.Colors.danger)
            TextField(placeholder, text: text)
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
        .padding(.vertical, 10)
        .settingsRow()
    }

    private func apply() {
        let defaults = UserDefaults.standard
        let url = serverURL.trimmingCharacters(in: .whitespaces)
        let day = historyDay.trimmingCharacters(in: .whitespaces)
        if url.isEmpty { defaults.removeObject(forKey: AppConfig.Overrides.apiBaseURL) } else { defaults.set(url, forKey: AppConfig.Overrides.apiBaseURL) }
        if day.isEmpty { defaults.removeObject(forKey: AppConfig.Overrides.historyDay) } else { defaults.set(day, forKey: AppConfig.Overrides.historyDay) }
        onApply()
        Task { await checkHealth() }
    }

    private func checkHealth() async {
        health = .checking
        health = await LocationAPI().isHealthy() ? .ok : .failed
    }
}
#endif
