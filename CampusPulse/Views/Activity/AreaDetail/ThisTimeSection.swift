import Charts
import SwiftUI

/// "Around 2:30 PM": how busy the building is right now against the same time on past weeks'
/// same weekday, and on the other days this week. Drawn from a `BuildingStory`.
struct ThisTimeSection: View {
    let state: BuildingStoryState
    var onRetry: () -> Void = {}

    var body: some View {
        switch state {
        case .loaded(let story):
            DetailSection(title: "Around \(timeText(story))", trailing: "\(weekdayText(story.current.date, story, style: .wide))s") {
                StoryCard(story: story)
            }
        case .loading:
            DetailSection(title: "This time of day", trailing: "") {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .card(cornerRadius: Theme.Radius.sm)
            }
        case .failed(let message):
            DetailSection(title: "This time of day", trailing: "") {
                VStack(spacing: 10) {
                    Text("Couldn't load past weeks. \(message)")
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
}

// MARK: - Card

private struct StoryCard: View {
    let story: BuildingStory

    /// One bar per past same weekday (oldest first), then today.
    private struct Bar: Identifiable {
        let id: Date
        let label: String
        let devices: Int?
        let isToday: Bool
    }

    private var bars: [Bar] {
        story.sameWeekdayOldestFirst.map {
            // Short numeric dates ("10/18"): nine "Oct 18"s don't fit side by side.
            Bar(id: $0.date, label: $0.date.formatted(dayFormat(.defaultDigits)), devices: $0.devices, isToday: false)
        } + [Bar(id: story.current.date, label: "Today", devices: story.current.devices, isToday: true)]
    }

    private var maxDevices: Double {
        Double(max(1, (bars.compactMap(\.devices) + [Int(story.usualDevices ?? 0)]).max() ?? 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            chart
            if !story.thisWeek.isEmpty {
                Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                thisWeek
            }
            Text("Location reports within \(story.windowMinutes) minutes of \(timeText(story)). Phones report every 2 minutes, so these compare days rather than count people.")
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.sm)
    }

    // MARK: Headline

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(countText(story.current.devices))
                    .typeStyle(.metric)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text("reports now")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 8)
            comparison
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var comparison: some View {
        let weekday = weekdayText(story.current.date, story, style: .wide)
        if let devices = story.current.devices, let baseline = story.baseline, baseline.value > 0 {
            let ratio = Double(devices) / baseline.value
            let usual = baseline.value
            let against = baseline.basis == .sameWeekday ? "a usual \(weekday)" : "other days this week"
            let (symbol, text, color): (String, String, Color) = switch ratio {
            case 1.25...: ("arrow.up.right", ratio >= 1.95 ? "\(ratio.formatted(.number.precision(.fractionLength(0...1))))× \(against)" : "Busier than \(against)", Theme.Colors.danger)
            case ..<0.8: ("arrow.down.right", "Quieter than \(against)", Theme.Colors.positive)
            default: ("equal", "About \(against)", Theme.Colors.textSecondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Label(text, systemImage: symbol)
                    .typeStyle(.badge)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.trailing)
                Text(baseline.basis == .sameWeekday ? "Usually ~\(Int(usual.rounded()))" : "Week avg ~\(Int(usual.rounded()))")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        } else {
            Text("No past \(weekday)s yet")
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // MARK: Same weekday, past weeks

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(
                    x: .value("Day", bar.label),
                    // Days without data get a faint stub, so the gap reads as "no data" not "empty".
                    y: .value("Devices", bar.devices.map(Double.init) ?? maxDevices * 0.04),
                    width: .ratio(0.62)
                )
                .cornerRadius(2)
                .foregroundStyle(barColor(bar))
                .annotation(position: .top, spacing: 3) {
                    if bar.devices == nil {
                        Text("–")
                            .typeStyle(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
            if let usual = story.usualDevices {
                RuleMark(y: .value("Usual", usual))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Usual")
                            .typeStyle(.badge)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
            }
        }
        .chartYScale(domain: 0...(maxDevices * 1.15))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .typeStyle(.badge)
                            .foregroundStyle(label == "Today" ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    }
                }
            }
        }
        .frame(height: 130)
        .accessibilityLabel(accessibilitySummary)
    }

    private func barColor(_ bar: Bar) -> Color {
        if bar.isToday { return Theme.Colors.accent }
        return bar.devices == nil ? Theme.Colors.rule : Theme.Colors.accent.opacity(0.35)
    }

    private var accessibilitySummary: String {
        let past = story.sameWeekdayOldestFirst.map { day in
            "\(day.date.formatted(dayFormat(.wide))): \(day.devices.map(String.init) ?? "no data")"
        }
        return (["Today: \(countText(story.current.devices))"] + past).joined(separator: ", ")
    }

    // MARK: This week

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This week at \(timeText(story))")
                .typeStyle(.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
            HStack(spacing: 0) {
                ForEach(story.thisWeek.filter { $0.date != story.current.date } + [story.current]) { day in
                    let isToday = day.date == story.current.date
                    VStack(spacing: 3) {
                        Text(weekdayText(day.date, story, style: .abbreviated))
                            .typeStyle(.badge)
                            .foregroundStyle(isToday ? Theme.Colors.accent : Theme.Colors.textTertiary)
                        Text(countText(day.devices))
                            .typeStyle(.rowTitle)
                            .foregroundStyle(isToday ? Theme.Colors.accent : Theme.Colors.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func dayFormat(_ month: Date.FormatStyle.Symbol.Month) -> Date.FormatStyle {
        Date.FormatStyle(timeZone: story.timeZone).month(month).day()
    }
}

// MARK: - Formatting

/// Counts under the app's display minimum aren't shown exactly, as elsewhere in the app.
func countText(_ devices: Int?) -> String {
    guard let devices else { return "–" }
    return devices < AppConfig.minimumDisplayedCount ? "<\(AppConfig.minimumDisplayedCount)" : "\(devices)"
}

func timeText(_ story: BuildingStory) -> String {
    story.moment.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: story.timeZone))
}

func weekdayText(_ date: Date, _ story: BuildingStory, style: Date.FormatStyle.Symbol.Weekday) -> String {
    date.formatted(Date.FormatStyle(timeZone: story.timeZone).weekday(style))
}
