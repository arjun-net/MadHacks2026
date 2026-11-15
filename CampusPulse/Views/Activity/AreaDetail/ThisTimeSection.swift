import Charts
import SwiftUI

/// "Around 2:30 PM": how busy the building is right now against what's usual, with a bar for each
/// of the last 7 days at this time (or, switched, each past week's same weekday). Drawn from a
/// `BuildingStory`, plus the past days' stories for the last 7 days.
struct ThisTimeSection: View {
    let state: BuildingStoryState
    /// The last 7 days' counts at this time, oldest first (from the past-days stories). Empty
    /// until they load; the story's own days this week stand in meanwhile.
    var recentDays: [BuildingStory.Day] = []
    var onRetry: () -> Void = {}

    var body: some View {
        switch state {
        case .loaded(let story):
            DetailSection(title: "Around \(timeText(story))", trailing: weekdayText(story.current.date, story, style: .wide)) {
                StoryCard(story: story, recentDays: recentDays.isEmpty ? story.thisWeek.filter { $0.date < story.current.date } : recentDays)
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
    let recentDays: [BuildingStory.Day]

    /// Which days the bars are.
    enum Range: Hashable {
        /// The last 7 days, then today.
        case recent
        /// Past weeks' same weekday, then today.
        case sameWeekday
    }

    @State private var range: Range = .recent

    /// One bar per day (oldest first), then today.
    private struct Bar: Identifiable {
        let id: Date
        let label: String
        let devices: Int?
        let isToday: Bool
    }

    private var bars: [Bar] {
        let past: [Bar] = switch range {
        case .recent:
            recentDays.suffix(7).map {
                Bar(id: $0.date, label: weekdayText($0.date, story, style: .abbreviated), devices: $0.devices, isToday: false)
            }
        case .sameWeekday:
            story.sameWeekdayOldestFirst.map {
                // Short numeric dates ("10/18"): nine "Oct 18"s don't fit side by side.
                Bar(id: $0.date, label: $0.date.formatted(dayFormat(.defaultDigits)), devices: $0.devices, isToday: false)
            }
        }
        return past + [Bar(id: story.current.date, label: "Today", devices: story.current.devices, isToday: true)]
    }

    /// The dashed line: what's usual, when there's a usual to draw.
    private var rule: (value: Double, label: String)? {
        guard let baseline = story.baseline else { return nil }
        return (baseline.value, baseline.basis == .sameWeekday ? "Usual" : "Week avg")
    }

    private var maxDevices: Double {
        Double(max(1, (bars.compactMap(\.devices) + [Int(rule?.value ?? 0)]).max() ?? 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            Rectangle().fill(Theme.Colors.rule).frame(height: 1)
            rangePicker
            chart
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
                Text("reports, today")
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

    // MARK: Chart

    private var rangePicker: some View {
        let weekday = weekdayText(story.current.date, story, style: .wide)
        return HStack(spacing: 18) {
            rangeButton("Last 7 days", .recent)
            rangeButton("Past \(weekday)s", .sameWeekday)
            Spacer(minLength: 0)
        }
        .sensoryFeedback(.selection, trigger: range)
    }

    private func rangeButton(_ title: String, _ value: Range) -> some View {
        let isSelected = range == value
        return Button {
            withAnimation(Theme.Motion.snappy) { range = value }
        } label: {
            Text(title)
                .typeStyle(.badge)
                .foregroundStyle(isSelected ? Theme.Colors.ink : Theme.Colors.textTertiary)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? Theme.Colors.accent : .clear).frame(height: 2)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

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
            if let rule {
                RuleMark(y: .value("Usual", rule.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(rule.label)
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
        bars.reversed().map { bar in
            let name = bar.isToday ? "Today" : bar.id.formatted(Date.FormatStyle(timeZone: story.timeZone).weekday(.wide).month(.wide).day())
            return "\(name): \(bar.devices.map(String.init) ?? "no data")"
        }
        .joined(separator: ", ")
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
