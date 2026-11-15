import Charts
import SwiftUI

/// Detail for one hall or building: live reading, usual busy times by weekday,
/// today compared with a normal day, and the past week.
struct AreaDetailScreen: View {
    let areaID: String
    @Bindable var viewModel: ActivityViewModel
    var onShowOnMap: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if let activity = viewModel.activity(for: areaID), let insights = viewModel.insights(for: areaID) {
                content(activity: activity, insights: insights)
            } else {
                ErrorStateView(message: "This area isn't reporting right now.") { Task { await viewModel.refresh() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ScreenBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowOnMap(areaID) } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Show on map")
            }
        }
    }

    private func content(activity: AreaActivity, insights: AreaInsights) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(activity)

                Button { onShowOnMap(areaID) } label: {
                    MapPreviewCard(campus: viewModel.campus, activity: activity)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Show \(activity.area.name) on the map")

                LiveCard(activity: activity, insights: insights)
                PopularTimesSection(insights: insights, liveIntensity: activity.intensity)
                TodayVersusUsualSection(insights: insights)
                PastWeekSection(insights: insights)

                Text("History and usual times are estimates built from anonymous, aggregated activity.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, 4)
            .padding(.bottom, Theme.tabBarClearance + 20)
            .animation(Theme.Motion.smooth, value: activity.intensity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.refresh() }
    }

    private func header(_ activity: AreaActivity) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AreaIconTile(symbol: activity.area.symbol, color: activity.level.color, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.area.name)
                    .typeStyle(.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(activity.area.category.title)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Live

private struct LiveCard: View {
    let activity: AreaActivity
    let insights: AreaInsights

    private var comparison: UsualComparison {
        UsualComparison(live: activity.intensity, typical: insights.typicalNow)
    }

    private var weekdayName: String {
        insights.generatedAt.formatted(.dateTime.weekday(.wide))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        PulsingDot(color: Theme.Colors.live, size: 6)
                        Text("Right now").sectionLabelStyle()
                    }
                    Text(activity.level.title)
                        .typeStyle(.metric)
                        .foregroundStyle(activity.level.color)
                        .contentTransition(.numericText())
                    Text(activity.countLabel)
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Sparkline(values: activity.history, color: activity.level.color, lineWidth: 2)
                    .frame(width: 92, height: 44)
                    .padding(.top, 8)
            }

            HStack(spacing: 6) {
                Image(systemName: comparison.symbol)
                Text(comparison.title)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule())

            Divider().overlay(Color.white.opacity(0.06))

            HStack(alignment: .top, spacing: 0) {
                stat(
                    label: "Usual now",
                    value: ActivityLevel(intensity: insights.typicalNow).title,
                    color: ActivityLevel(intensity: insights.typicalNow).color
                )
                stat(
                    label: "Last \(insights.generatedAt.formatted(.dateTime.weekday(.abbreviated)))",
                    value: insights.lastWeekNow.map { ActivityLevel(intensity: $0).title } ?? "—",
                    color: insights.lastWeekNow.map { ActivityLevel(intensity: $0).color } ?? Theme.Colors.textTertiary
                )
                stat(
                    label: "Usual peak",
                    value: insights.usualPeak(weekday: insights.todayWeekday).map { Formatting.hour($0.hour) } ?? "—",
                    color: Theme.Colors.textPrimary
                )
            }

            if let quiet = insights.quietestLaterToday {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(ActivityLevel.quiet.color)
                    Text("Quietest later today is usually around **\(Formatting.hour(quiet.hour))**.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .font(.system(size: 13))
            }
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.xl)
        .accessibilityElement(children: .combine)
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Popular times

private struct PopularTimesSection: View {
    let insights: AreaInsights
    let liveIntensity: Double

    @State private var weekday: Int?
    @State private var selectedHour: Double?

    private var shownWeekday: Int { weekday ?? insights.todayWeekday }
    private var isToday: Bool { shownWeekday == insights.todayWeekday }
    private var values: [HourlyValue] { insights.typical(weekday: shownWeekday) }
    private var currentHour: Double { Double(Int(insights.generatedAt.fractionalHour)) }

    /// Calendar weekdays starting from the locale's first weekday.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var caption: String {
        if let selectedHour, let value = values.first(where: { $0.hour == selectedHour }) {
            return "\(Formatting.hour(value.hour)): usually \(value.level.title.lowercased())"
        }
        if let peak = insights.usualPeak(weekday: shownWeekday) {
            return "Usually busiest around \(Formatting.hour(peak.hour))"
        }
        return ""
    }

    var body: some View {
        DetailSection(title: "Popular times", trailing: isToday ? "Today" : weekdayName(shownWeekday)) {
            VStack(alignment: .leading, spacing: 14) {
                dayPicker

                Text(caption)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.snappy, value: caption)

                chart
                    .frame(height: 150)
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.lg)
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let selected = day == shownWeekday
                Button {
                    withAnimation(Theme.Motion.snappy) {
                        weekday = day
                        selectedHour = nil
                    }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundStyle(selected ? Theme.Colors.background : Theme.Colors.textSecondary)
                        .background {
                            Capsule()
                                .fill(selected ? Theme.Colors.textPrimary : Color.white.opacity(0.06))
                        }
                        .overlay(alignment: .bottom) {
                            if day == insights.todayWeekday, !selected {
                                Circle().fill(Theme.Colors.live).frame(width: 4, height: 4).offset(y: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekdayName(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: shownWeekday)
    }

    private var chart: some View {
        Chart {
            ForEach(values) { value in
                BarMark(
                    x: .value("Hour", value.hour),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Usual", value.intensity),
                    width: .fixed(8)
                )
                .cornerRadius(3)
                .foregroundStyle(barColor(for: value))
            }

            if isToday {
                // Live reading drawn as a marker over the current hour's bar.
                RuleMark(
                    xStart: .value("Hour", currentHour - 0.42),
                    xEnd: .value("Hour", currentHour + 0.42),
                    y: .value("Live", liveIntensity)
                )
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                .foregroundStyle(Theme.Colors.textPrimary)
                .annotation(position: .top, spacing: 4) {
                    Text("Live")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
            }

            if let selectedHour {
                RuleMark(x: .value("Selected", selectedHour))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Double.self) {
                        Text(Formatting.hour(hour, compact: true))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedHour },
            set: { newValue in selectedHour = newValue.map { min(23, max(0, $0.rounded(.down))) } }
        ))
        .sensoryFeedback(.selection, trigger: selectedHour)
        .accessibilityLabel("Usual activity by hour on \(weekdayName(shownWeekday)). \(caption)")
    }

    /// Starts just below the quietest hour so the shape of the day reads clearly,
    /// like a relative "popular times" chart (there's no y-axis to misread).
    private var yDomain: ClosedRange<Double> {
        let low = values.map(\.intensity).min() ?? 0
        let high = max(values.map(\.intensity).max() ?? 1, liveIntensity)
        return max(0, low - (high - low) * 0.25)...(high * 1.08)
    }

    private func barColor(for value: HourlyValue) -> Color {
        let color = HeatPalette.color(at: value.level.paletteValue)
        if let selectedHour { return value.hour == selectedHour ? color : color.opacity(0.3) }
        if isToday {
            if value.hour == currentHour { return color }
            return value.hour < currentHour ? color.opacity(0.32) : color.opacity(0.7)
        }
        return color.opacity(0.8)
    }

    private func weekdayName(_ day: Int) -> String {
        Calendar.current.weekdaySymbols[day - 1]
    }
}

// MARK: - Today vs usual

private struct TodayVersusUsualSection: View {
    let insights: AreaInsights

    private var typical: [HourlyValue] { insights.typical(weekday: insights.todayWeekday) }

    var body: some View {
        DetailSection(title: "Today so far", trailing: "vs. a usual \(insights.generatedAt.formatted(.dateTime.weekday(.wide)))") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    legend(color: Theme.Colors.textPrimary, dashed: false, label: "Today")
                    legend(color: Theme.Colors.textTertiary, dashed: true, label: "Usual")
                }
                Chart {
                    ForEach(typical) { value in
                        LineMark(
                            x: .value("Hour", value.hour + 0.5),
                            y: .value("Activity", value.intensity),
                            series: .value("Series", "Usual")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    ForEach(insights.today) { value in
                        AreaMark(
                            x: .value("Hour", value.hour),
                            yStart: .value("Base", 0),
                            yEnd: .value("Activity", value.intensity),
                            series: .value("Series", "Today")
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [HeatPalette.color(at: 0.8).opacity(0.35), HeatPalette.color(at: 0.2).opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Hour", value.hour),
                            y: .value("Activity", value.intensity),
                            series: .value("Series", "Today")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    }
                    if let now = insights.today.last {
                        PointMark(x: .value("Hour", now.hour), y: .value("Activity", now.intensity))
                            .symbolSize(70)
                            .foregroundStyle(now.level.color)
                        RuleMark(x: .value("Now", now.hour))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(Color.white.opacity(0.2))
                    }
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                        AxisValueLabel {
                            if let hour = value.as(Double.self) {
                                Text(Formatting.hour(hour, compact: true))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .accessibilityLabel("Today's activity compared with a usual day")
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.lg)
        }
    }

    private func legend(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            .frame(width: 16, height: 2)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}

// MARK: - Past week

private struct PastWeekSection: View {
    let insights: AreaInsights

    @State private var selectedDay: Date?

    private var days: [DayHistory] { insights.pastDays }

    var body: some View {
        DetailSection(title: "Past 7 days", trailing: "Daily peak") {
            VStack(spacing: 0) {
                ForEach(days.reversed()) { day in
                    PastDayRow(day: day, isExpanded: selectedDay == day.date)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Theme.Motion.snappy) {
                                selectedDay = selectedDay == day.date ? nil : day.date
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                    if day.date != days.first?.date {
                        Divider().overlay(Color.white.opacity(0.04))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.lg)
            .sensoryFeedback(.selection, trigger: selectedDay)
        }
    }
}

private struct PastDayRow: View {
    let day: DayHistory
    let isExpanded: Bool

    private var peakIntensity: Double { day.peak?.intensity ?? 0 }
    private var level: ActivityLevel { ActivityLevel(intensity: peakIntensity) }

    private var dayYDomain: ClosedRange<Double> {
        let values = day.hourly.map(\.intensity)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        return max(0, low - (high - low) * 0.25)...high
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.date.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(day.date.formatted(.dateTime.month(.abbreviated).day()) + (day.peak.map { " · \(Formatting.hour($0.hour))" } ?? ""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(width: 92, alignment: .leading)

                ActivityBar(intensity: peakIntensity, height: 5)

                Text(level.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(level.color)
                    .frame(width: 66, alignment: .trailing)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Chart(day.hourly) { value in
                        BarMark(
                            x: .value("Hour", value.hour),
                            yStart: .value("Base", dayYDomain.lowerBound),
                            yEnd: .value("Activity", value.intensity),
                            width: .fixed(6)
                        )
                            .cornerRadius(2)
                            .foregroundStyle(HeatPalette.color(at: value.level.paletteValue).opacity(0.85))
                    }
                    .chartXScale(domain: -0.5...23.5)
                    .chartYScale(domain: dayYDomain)
                    .chartPlotStyle { $0.clipped() }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18]) { value in
                            AxisValueLabel {
                                if let hour = value.as(Double.self) {
                                    Text(Formatting.hour(hour, compact: true))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 70)

                    if let peak = day.peak {
                        Text("Peaked around \(Formatting.hour(peak.hour)) · daytime average was \(ActivityLevel(intensity: day.daytimeAverage).title.lowercased())")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared

private struct DetailSection<Content: View>: View {
    let title: String
    let trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).sectionLabelStyle()
                Spacer()
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

/// Subtle press feedback for full-width rows and cards.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

#Preview("Area detail") {
    let container = PreviewData.container()
    let viewModel = ActivityViewModel(store: container.store)
    NavigationStack {
        AreaDetailScreen(areaID: viewModel.allAreas.first?.id ?? "", viewModel: viewModel)
    }
}
