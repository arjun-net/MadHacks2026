import SwiftUI

/// Glowing dot with an expanding ripple. Driven by a timeline so it never fights other animations.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 8
    var isAnimating = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            ZStack {
                if isAnimating {
                    Circle()
                        .fill(color.opacity(0.55))
                        .scaleEffect(1 + phase * 1.8)
                        .opacity(1 - phase)
                }
                Circle()
                    .fill(color)
                    .shadow(color: color.opacity(0.9), radius: 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ActivityLevelBadge: View {
    let level: ActivityLevel
    var showsIcon = false

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: level.symbol).font(.system(size: 9, weight: .bold))
            }
            Text(level.title)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(level.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(level.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(level.color.opacity(0.25), lineWidth: 0.5))
        .accessibilityLabel("Activity: \(level.title)")
    }
}

/// Horizontal capsule that reveals the heat ramp up to `intensity`.
struct ActivityBar: View {
    var intensity: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(HeatPalette.linearGradient)
                    .frame(width: proxy.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(height, proxy.size.width * min(1, max(0, intensity))))
                    }
            }
        }
        .frame(height: height)
        .animation(Theme.Motion.smooth, value: intensity)
        .accessibilityHidden(true)
    }
}

/// Smooth mini trend line with a soft gradient fill.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.75
    var showsFill = true
    var showsEndpoint = true

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                if showsFill, points.count > 1 {
                    fillPath(points, size: proxy.size)
                        .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                linePath(points)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if showsEndpoint, let last = points.last {
                    Circle()
                        .fill(color)
                        .frame(width: lineWidth * 2.6, height: lineWidth * 2.6)
                        .shadow(color: color, radius: 3)
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

/// 270° ring gauge painted with the heat ramp.
struct ActivityGauge: View {
    var intensity: Double
    var lineWidth: CGFloat = 10

    private let sweep = 0.75

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: sweep * max(0.02, min(1, intensity)))
                .stroke(
                    AngularGradient(gradient: HeatPalette.gradient, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .shadow(color: HeatPalette.color(at: intensity).opacity(0.55), radius: lineWidth * 0.8)
        }
        .rotationEffect(.degrees(135))
        .padding(lineWidth / 2)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: intensity)
        .accessibilityHidden(true)
    }
}

/// Color key for the map: Quiet → Packed.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Quiet")
            Capsule()
                .fill(HeatPalette.linearGradient)
                .frame(width: 70, height: 6)
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            Text("Packed")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heatmap legend: blue is quiet, red is packed")
    }
}

/// Rounded tile holding an SF Symbol in a level color.
struct AreaIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(color)
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
        Sparkline(values: [0.2, 0.3, 0.28, 0.45, 0.5, 0.62, 0.58, 0.7], color: ActivityLevel.busy.color)
            .frame(width: 120, height: 40)
        ActivityGauge(intensity: 0.68).frame(width: 120, height: 120)
        HeatLegend()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ScreenBackground())
    .preferredColorScheme(.dark)
}
