import SwiftUI

/// "Past days": each of the last week's days at this time of day, and whether the building was
/// busier or quieter than usual for that weekday. Drawn from one `BuildingStory` per day.
struct PastDaysSection: View {
    let state: PastDaysState
    var onRetry: () -> Void = {}

    var body: some View {
        switch state {
        case .partial(let days) where days.contains(where: { $0.current.hasData }):
            DetailSection(title: "Past days", trailing: "Around \(timeText(days[0]))") {
                PastDaysCard(days: days, isLoading: true)
            }
        case .loaded(let days):
            DetailSection(title: "Past days", trailing: days.first.map { "Around \(timeText($0))" } ?? "") {
                if days.contains(where: { $0.current.hasData }) {
                    PastDaysCard(days: days, isLoading: false)
                } else {
                    message("No past data for this building yet. Days will fill in as the history builds up.")
                }
            }
        case .loading, .partial:
            DetailSection(title: "Past days", trailing: "") {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .card(cornerRadius: Theme.Radius.sm)
            }
        case .failed(let error):
            DetailSection(title: "Past days", trailing: "") {
                VStack(spacing: 10) {
                    Text("Couldn't load past days. \(error)")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again", action: onRetry)
                        .typeStyle(.button)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .card(cornerRadius: Theme.Radius.sm)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .typeStyle(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity)
            .card(cornerRadius: Theme.Radius.sm)
    }
}

// MARK: - Card

private struct PastDaysCard: View {
    let days: [BuildingStory]
    /// More days are still loading.
    let isLoading: Bool

    /// Bars share one scale: the biggest count or usual among the days.
    private var scale: Double {
        let values = days.compactMap { $0.current.devices.map(Double.init) } + days.compactMap { $0.baseline?.value }
        return max(1, values.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(ActivityViewModel.pastDayCount - days.count) more days…")
                            .typeStyle(.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                } else {
                    Text(summary)
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)

            ForEach(days, id: \.current.date) { day in
                Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                PastDayRow(day: day, scale: scale)
            }

            Rectangle().fill(Theme.Colors.rule).frame(height: 1)
            Text(footnote)
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        .card(cornerRadius: Theme.Radius.sm)
    }

    private var footnote: String {
        let window = days.first?.windowMinutes ?? 15
        let usual = days.contains { $0.baseline?.basis == .thisWeek }
            ? "The tick marks the usual for that weekday, or that week's other days while there are no past weeks to go on."
            : "The tick marks the usual for that weekday."
        return "Location reports within \(window) minutes of this time. \(usual)"
    }

    /// "Busier than usual on 2 of the last 7 days, quieter on 1."
    private var summary: String {
        let comparisons = days.map(\.comparison)
        let compared = comparisons.filter { [.busier, .quieter, .usual].contains($0) }.count
        let busier = comparisons.filter { $0 == .busier }.count
        let quieter = comparisons.filter { $0 == .quieter }.count
        guard compared > 0 else { return "Not enough past weeks yet to say what's usual." }
        let of = "of the last \(days.count) days"
        switch (busier, quieter) {
        case (0, 0): return "About as busy as usual on every day with data."
        case (_, 0): return "Busier than usual on \(busier) \(of)."
        case (0, _): return "Quieter than usual on \(quieter) \(of)."
        default: return "Busier than usual on \(busier) \(of), quieter on \(quieter)."
        }
    }
}

private struct PastDayRow: View {
    let day: BuildingStory
    let scale: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(weekdayText(day.current.date, day, style: .wide))
                    .typeStyle(.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(day.current.date.formatted(Date.FormatStyle(timeZone: day.timeZone).month(.abbreviated).day()))
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                CountBar(devices: day.current.devices, usual: day.baseline?.value, scale: scale, color: day.comparison.color)
                Text(detail)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            ComparisonBadge(comparison: day.comparison)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "140 reports · usually ~104" (or "week avg ~104" without past weeks).
    private var detail: String {
        guard let devices = day.current.devices else { return "No data" }
        let here = "\(Formatting.number(devices)) reports"
        guard let baseline = day.baseline else { return here }
        let label = baseline.basis == .sameWeekday ? "usually" : "week avg"
        return "\(here) · \(label) ~\(Int(baseline.value.rounded()))"
    }

    private var accessibilityText: String {
        let date = day.current.date.formatted(Date.FormatStyle(timeZone: day.timeZone).weekday(.wide).month(.wide).day())
        return "\(date): \(detail). \(day.comparison.title)"
    }
}

/// The day's count as a bar, with a tick at what's usual.
private struct CountBar: View {
    let devices: Int?
    let usual: Double?
    let scale: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.Colors.surfaceStrong).frame(height: 4)
                if let devices {
                    Rectangle()
                        .fill(color)
                        .frame(width: max(2, width * min(1, Double(devices) / scale)), height: 4)
                }
                if devices != nil, let usual {
                    Rectangle()
                        .fill(Theme.Colors.ink)
                        .frame(width: 2, height: 10)
                        .offset(x: min(width - 2, max(0, width * min(1, usual / scale) - 1)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}

private struct ComparisonBadge: View {
    let comparison: BusyComparison

    var body: some View {
        if let symbol = comparison.symbol {
            Label(comparison.shortTitle, systemImage: symbol)
                .typeStyle(.badge)
                .foregroundStyle(comparison.color)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        } else {
            Text(comparison.shortTitle)
                .typeStyle(.badge)
                .foregroundStyle(comparison.color)
        }
    }
}

extension BusyComparison {
    var shortTitle: String {
        switch self {
        case .busier: "Busier"
        case .quieter: "Quieter"
        case .usual: "As usual"
        case .noHistory, .noData: "–"
        }
    }

    var title: String {
        switch self {
        case .busier: "Busier than usual"
        case .quieter: "Quieter than usual"
        case .usual: "About as busy as usual"
        case .noHistory: "Nothing to compare with yet"
        case .noData: "No data"
        }
    }

    var symbol: String? {
        switch self {
        case .busier: "arrow.up.right"
        case .quieter: "arrow.down.right"
        case .usual: "equal"
        case .noHistory, .noData: nil
        }
    }

    var color: Color {
        switch self {
        case .busier: Theme.Colors.danger
        case .quieter: Theme.Colors.positive
        case .usual: Theme.Colors.textSecondary
        case .noHistory, .noData: Theme.Colors.textTertiary
        }
    }
}
