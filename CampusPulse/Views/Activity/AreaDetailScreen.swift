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
                    .typeStyle(.caption)
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
        VStack(alignment: .leading, spacing: 12) {
            headerTitle(activity)
            Rectangle()
                .fill(Theme.Colors.ink)
                .frame(height: Theme.Stroke.sectionRule)
        }
    }

    private func headerTitle(_ activity: AreaActivity) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AreaIconTile(symbol: activity.area.symbol, color: activity.level.textColor, size: 52)
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
                        .foregroundStyle(activity.level.textColor)
                        .contentTransition(.numericText())
                    Text(activity.countLabel)
                        .typeStyle(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Sparkline(values: activity.history, color: activity.level.textColor, lineWidth: 2)
                    .frame(width: 92, height: 44)
                    .padding(.top, 8)
            }

            HStack(spacing: 6) {
                Image(systemName: comparison.symbol)
                Text(comparison.title)
            }
            .typeStyle(.badge)
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))

            Rectangle().fill(Theme.Colors.rule).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                stat(
                    label: "Usual now",
                    value: ActivityLevel(intensity: insights.typicalNow).title,
                    color: ActivityLevel(intensity: insights.typicalNow).textColor
                )
                stat(
                    label: insights.pastDays.first.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "Last week",
                    value: insights.lastWeekNow.map { ActivityLevel(intensity: $0).title } ?? "—",
                    color: insights.lastWeekNow.map { ActivityLevel(intensity: $0).textColor } ?? Theme.Colors.textTertiary
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
                        .foregroundStyle(Theme.Colors.positive)
                    Text("Quietest later today is usually around **\(Formatting.hour(quiet.hour))**.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .typeStyle(.subheadline)
            }
        }
        .padding(18)
        .paper(cornerRadius: Theme.Radius.sm)
        .accessibilityElement(children: .combine)
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .typeStyle(.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(value)
                .typeStyle(.title3)
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
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.snappy, value: caption)

                chart
                    .frame(height: 150)
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.sm)
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
                        .typeStyle(.button)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundStyle(selected ? Theme.Colors.paper : Theme.Colors.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(selected ? Theme.Colors.ink : Theme.Colors.paper)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline)
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
                .cornerRadius(1)
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
                        .typeStyle(.badge)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }

            if let selectedHour {
                RuleMark(x: .value("Selected", selectedHour))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.Colors.ink.opacity(0.5))
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
                            .typeStyle(.caption)
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
        let color = Theme.Colors.accent
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
                    legend(color: Theme.Colors.accent, dashed: false, label: "Today")
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
                                colors: [Theme.Colors.accent.opacity(0.12), Theme.Colors.accent.opacity(0)],
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
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(Theme.Colors.accent)
                    }
                    if let now = insights.today.last {
                        PointMark(x: .value("Hour", now.hour), y: .value("Activity", now.intensity))
                            .symbolSize(70)
                            .foregroundStyle(Theme.Colors.accent)
                        RuleMark(x: .value("Now", now.hour))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(Theme.Colors.rule)
                    }
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: 0...1)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                        AxisGridLine().foregroundStyle(Theme.Colors.rule)
                        AxisValueLabel {
                            if let hour = value.as(Double.self) {
                                Text(Formatting.hour(hour, compact: true))
                                    .typeStyle(.caption)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .accessibilityLabel("Today's activity compared with a usual day")
            }
            .padding(16)
            .card(cornerRadius: Theme.Radius.sm)
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
                .typeStyle(.micro)
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
        DetailSection(title: "Past days", trailing: "Daily peak") {
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
                        Rectangle().fill(Theme.Colors.rule).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .card(cornerRadius: Theme.Radius.sm)
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
                        .typeStyle(.rowTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(day.date.formatted(.dateTime.month(.abbreviated).day()) + (day.peak.map { " · \(Formatting.hour($0.hour))" } ?? ""))
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(width: 92, alignment: .leading)

                ActivityBar(intensity: peakIntensity, height: 4)

                Text(level.title)
                    .typeStyle(.badge)
                    .foregroundStyle(level.textColor)
                    .frame(width: 70, alignment: .trailing)

                Image(systemName: "chevron.down")
                    .imageScale(.small)
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
                            .cornerRadius(1)
                            .foregroundStyle(value.intensity == day.peak?.intensity ? Theme.Colors.accent : Theme.Colors.accent.opacity(0.45))
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
                                        .typeStyle(.caption)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 70)

                    if let peak = day.peak {
                        Text("Peaked around \(Formatting.hour(peak.hour)) · daytime average was \(ActivityLevel(intensity: day.daytimeAverage).title.lowercased())")
                            .typeStyle(.caption)
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
            SectionHeader(title: title, trailing: trailing)
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
