import Charts
import SwiftUI

struct OverviewCard: View {
    let snapshot: CampusSnapshot
    let participantsText: String
    let activeAreasText: String

    /// The ring grows with Dynamic Type so the percentage and level stay inside it.
    @ScaledMetric(relativeTo: .title) private var gaugeSize: CGFloat = 124
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Side by side normally; stacked at accessibility text sizes so the stats keep their width.
    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(spacing: 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryLayout {
                ZStack {
                    ActivityGauge(intensity: snapshot.overallIntensity, lineWidth: 8, style: .ring)
                    VStack(spacing: 0) {
                        Image(systemName: snapshot.level.symbol)
                            .imageScale(.small)
                            .foregroundStyle(snapshot.level.textColor)
                            .contentTransition(.symbolEffect(.replace))
                        Text("\(Int((snapshot.overallIntensity * 100).rounded()))%")
                            .typeStyle(.metric)
                            .foregroundStyle(Theme.Colors.accent)
                            .contentTransition(.numericText())
                        Text(snapshot.level.title)
                            .typeStyle(.badge)
                            .foregroundStyle(Theme.Colors.textPrimary)
                    }
                }
                .frame(width: gaugeSize, height: gaugeSize)

                VStack(alignment: .leading, spacing: 14) {
                    metric(value: participantsText, label: "students sharing", symbol: "person.2.fill")
                    metric(value: activeAreasText, label: "areas active", symbol: "mappin.and.ellipse")
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.trend.symbol)
                        Text(snapshot.trend.title)
                    }
                    .typeStyle(.badge)
                    .foregroundStyle(snapshot.level.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(snapshot.level.textColor, lineWidth: Theme.Stroke.hairline))
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Campus activity", trailing: "Last 24 min")
                CampusTrendChart(history: snapshot.history, updatedAt: snapshot.generatedAt)
                    .frame(height: 96)
            }
        }
        .padding(18)
        .paper(cornerRadius: Theme.Radius.sm)
    }

    private func metric(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .typeStyle(.metricSmall)
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.numericText())
            Label(label, systemImage: symbol)
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

struct CampusTrendChart: View {
    let history: [Double]
    let updatedAt: Date

    private struct Sample: Identifiable {
        let id: Int
        let minutesAgo: Int
        let value: Double
    }

    private var samples: [Sample] {
        let step = Int(AppConfig.updateInterval / 60)
        return history.enumerated().map { index, value in
            Sample(id: index, minutesAgo: (history.count - 1 - index) * step, value: value)
        }
    }

    /// Zoom the y-axis to the data so small swings are visible, without exaggerating noise.
    private var yDomain: ClosedRange<Double> {
        let low = history.min() ?? 0
        let high = history.max() ?? 1
        let padding = max(0.06, (high - low) * 0.6)
        return max(0, low - padding)...min(1, high + padding)
    }

    var body: some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Minutes ago", -sample.minutesAgo),
                yStart: .value("Baseline", yDomain.lowerBound),
                yEnd: .value("Activity", sample.value)
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
                x: .value("Minutes ago", -sample.minutesAgo),
                y: .value("Activity", sample.value)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .foregroundStyle(Theme.Colors.accent)
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: -samples.count * 2 + 2 ... 0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { _ in
            VStack {
                Spacer()
                HStack {
                    Text("\((samples.count - 1) * 2)m ago")
                    Spacer()
                    Text("Now")
                }
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .offset(y: 16)
            }
        }
        .padding(.bottom, 14)
        .accessibilityLabel("Campus activity over the last 24 minutes")
    }
}
