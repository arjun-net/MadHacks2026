import Charts
import SwiftUI

struct OverviewCard: View {
    let snapshot: CampusSnapshot
    let participantsText: String
    let activeAreasText: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Side by side normally; stacked at accessibility text sizes.
    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryLayout {
                // The level in words, and which way it's heading. No gauge: the word says it.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Campus is")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(snapshot.level.title)
                        .typeStyle(.metric)
                        .foregroundStyle(snapshot.level.textColor)
                        .contentTransition(.opacity)
                    Text(snapshot.trend.title)
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 22) {
                    metric(value: participantsText, label: "on campus")
                    metric(value: activeAreasText, label: "places busy")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Theme.Colors.rule).frame(height: Theme.Stroke.hairline)
                Text("Last 24 minutes")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.top, 8)
                CampusTrendChart(history: snapshot.history, updatedAt: snapshot.generatedAt)
                    .frame(height: 80)
            }
        }
        .padding(18)
        .card(cornerRadius: Theme.Radius.sm)
        .accessibilityElement(children: .combine)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .typeStyle(.metricSmall)
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label)
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
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
