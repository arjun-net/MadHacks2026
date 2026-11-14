import SwiftUI

enum ActivityLevel: Int, CaseIterable, Comparable, Sendable {
    case quiet, light, moderate, busy, packed

    init(intensity: Double) {
        switch intensity {
        case ..<0.2: self = .quiet
        case ..<0.4: self = .light
        case ..<0.6: self = .moderate
        case ..<0.8: self = .busy
        default: self = .packed
        }
    }

    static func < (lhs: ActivityLevel, rhs: ActivityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .quiet: "Quiet"
        case .light: "Light"
        case .moderate: "Moderate"
        case .busy: "Busy"
        case .packed: "Packed"
        }
    }

    var subtitle: String {
        switch self {
        case .quiet: "Plenty of space"
        case .light: "A few people around"
        case .moderate: "Steady crowd"
        case .busy: "Getting crowded"
        case .packed: "Very crowded"
        }
    }

    var symbol: String {
        switch self {
        case .quiet: "leaf.fill"
        case .light: "figure.walk"
        case .moderate: "person.2.fill"
        case .busy: "person.3.fill"
        case .packed: "flame.fill"
        }
    }

    /// Position on the heat ramp, so levels match the map exactly.
    var paletteValue: Double {
        switch self {
        case .quiet: 0.1
        case .light: 0.42
        case .moderate: 0.62
        case .busy: 0.8
        case .packed: 1.0
        }
    }

    var color: Color { HeatPalette.color(at: paletteValue) }
}

enum ActivityTrend: Sendable {
    case rising, steady, falling

    init(history: [Double]) {
        guard history.count >= 4, let last = history.last else {
            self = .steady
            return
        }
        let previous = history.suffix(4).dropLast()
        let baseline = previous.reduce(0, +) / Double(previous.count)
        let delta = last - baseline
        if delta > 0.03 { self = .rising } else if delta < -0.03 { self = .falling } else { self = .steady }
    }

    var title: String {
        switch self {
        case .rising: "Getting busier"
        case .steady: "Holding steady"
        case .falling: "Quieting down"
        }
    }

    var shortTitle: String {
        switch self {
        case .rising: "Rising"
        case .steady: "Steady"
        case .falling: "Easing"
        }
    }

    var symbol: String {
        switch self {
        case .rising: "arrow.up.right"
        case .steady: "arrow.right"
        case .falling: "arrow.down.right"
        }
    }
}
