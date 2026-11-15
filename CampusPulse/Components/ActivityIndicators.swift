import SwiftUI

/// Live dot with an expanding ripple. Driven by a timeline so it never fights other animations.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 8
    var isAnimating = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion keeps the solid dot and drops the expanding ring.
    private var pulses: Bool { isAnimating && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulses)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            ZStack {
                if pulses {
                    Circle()
                        .fill(color.opacity(0.45))
                        .scaleEffect(1 + phase * 1.8)
                        .opacity(1 - phase)
                }
                Circle()
                    .fill(color)
                    .shadow(color: colorScheme == .dark ? color.opacity(0.8) : .clear, radius: 3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Square, tracked-caps level chip. Text always carries the level word, never color alone.
struct ActivityLevelBadge: View {
    let level: ActivityLevel
    var showsIcon = false

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: level.symbol).font(.system(size: 8.5, weight: .heavy))
            }
            Text(level.title)
                .typeStyle(.badge)
        }
        .foregroundStyle(level == .packed ? Theme.Colors.onAccent : level.textColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background {
            if level == .packed {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Colors.accentFill)
            }
        }
        .overlay {
            if level != .packed {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(level.textColor, lineWidth: 1)
            }
        }
        .accessibilityLabel("Activity: \(level.title)")
    }
}

/// Flat 4pt bar: track in `surfaceStrong`, solid fill in the level's ramp color.
struct ActivityBar: View {
    var intensity: Double
    /// Kept for call sites; the bar is always 4pt.
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.Colors.surfaceStrong)
                Rectangle()
                    .fill(ActivityLevel(intensity: intensity).color)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, intensity))))
            }
        }
        .frame(height: 4)
        .animation(Theme.Motion.smooth, value: intensity)
        .accessibilityHidden(true)
    }
}

/// Mini trend line. Fill only in Night Edition.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.6
    var showsFill = true
    var showsEndpoint = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                if showsFill, colorScheme == .dark, points.count > 1 {
                    fillPath(points, size: proxy.size)
                        .fill(color.opacity(0.12))
                }
                linePath(points)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if showsEndpoint, let last = points.last {
                    Circle()
                        .fill(color)
                        .frame(width: lineWidth * 2.6, height: lineWidth * 2.6)
                        .position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let range = max(maxValue - minValue, 0.08)
        let inset: CGFloat = lineWidth * 1.5
        let usableHeight = size.height - inset * 2
        let step = (size.width - inset * 2) / CGFloat(values.count - 1)
        let midpointOffset = (range - (maxValue - minValue)) / 2
        return values.enumerated().map { index, value in
            let normalized = (value - minValue + midpointOffset) / range
            return CGPoint(
                x: inset + CGFloat(index) * step,
                y: inset + usableHeight * (1 - CGFloat(normalized))
            )
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: mid, control: previous)
                if index == points.count - 1 { path.addLine(to: current) }
            }
        }
    }

    private func fillPath(_ points: [CGPoint], size: CGSize) -> Path {
        var path = linePath(points)
        if let last = points.last, let first = points.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

/// Campus-wide intensity. `.masthead` is a 60pt ink-ringed box with the percentage;
/// `.ring` is a single-color 270° arc for larger layouts (Activity screen).
struct ActivityGauge: View {
    enum Style { case masthead, ring }

    var intensity: Double
    var lineWidth: CGFloat = 10
    var style: Style = .masthead

    private let sweep = 0.75

    var body: some View {
        switch style {
        case .masthead: masthead
        case .ring: ring
        }
    }

    private var masthead: some View {
        VStack(spacing: -2) {
            Text("\(Int((intensity * 100).rounded()))")
                .typeStyle(.metricSmall)
                .foregroundStyle(Theme.Colors.accent)
                .contentTransition(.numericText())
            Text("Pct")
                .typeStyle(.badge)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(width: 60, height: 60)
        .overlay(Circle().strokeBorder(Theme.Colors.borderStrong, lineWidth: 2))
        .animation(Theme.Motion.smooth, value: intensity)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Theme.Colors.surfaceStrong, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            Circle()
                .trim(from: 0, to: sweep * max(0.02, min(1, intensity)))
                .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
        .rotationEffect(.degrees(135))
        .padding(lineWidth / 2)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: intensity)
        .accessibilityHidden(true)
    }
}

/// Color key for the map: Quiet → Packed.
struct HeatLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text("Quiet")
            Capsule()
                .fill(HeatPalette.linearGradient)
                .frame(width: 70, height: 6)
            Text("Packed")
        }
        .typeStyle(.micro)
        .foregroundStyle(Theme.Colors.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .paper()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(colorScheme == .dark
            ? "Heatmap legend: dim is quiet, bright is packed"
            : "Heatmap legend: pale is quiet, dark red is packed")
    }
}

/// Square tile holding an SF Symbol in ink. `color` is kept for call sites but no longer tints.
struct AreaIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Colors.rule, lineWidth: Theme.Stroke.hairline)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
            )
            .frame(width: size, height: size)
    }
}

/// "Updated 12s ago", ticking every second.
struct UpdatedAgoText: View {
    let date: Date?
    var prefix = "Updated"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private func label(now: Date) -> String {
        guard let date else { return "Connecting…" }
        return "\(prefix) \(Formatting.elapsed(since: date, now: now))"
    }
}

#Preview("Indicators") {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            PulsingDot(color: Theme.Colors.live)
            ForEach(ActivityLevel.allCases, id: \.self) { ActivityLevelBadge(level: $0) }
        }
        ActivityBar(intensity: 0.72).frame(width: 200)
        Sparkline(values: [0.2, 0.3, 0.28, 0.45, 0.5, 0.62, 0.58, 0.7], color: ActivityLevel.busy.textColor)
            .frame(width: 120, height: 40)
        ActivityGauge(intensity: 0.68)
        ActivityGauge(intensity: 0.68, style: .ring).frame(width: 120, height: 120)
        HeatLegend()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ScreenBackground())
}
