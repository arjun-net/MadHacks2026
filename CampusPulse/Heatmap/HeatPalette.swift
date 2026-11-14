import SwiftUI

/// Single source of truth for the heat color ramp, shared by the map renderer,
/// the legend, gauges and activity badges so colors always agree.
enum HeatPalette {
    struct Stop {
        let location: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    static let stops: [Stop] = [
        Stop(location: 0.00, red: 0.82, green: 0.82, blue: 0.84), // soft white
        Stop(location: 0.30, red: 1.00, green: 0.72, blue: 0.72), // blush
        Stop(location: 0.55, red: 0.96, green: 0.36, blue: 0.36), // light red
        Stop(location: 0.78, red: 0.773, green: 0.020, blue: 0.047), // Badger red
        Stop(location: 1.00, red: 1.00, green: 0.10, blue: 0.12), // hot red
    ]

    static func rgb(at value: Double) -> (red: Double, green: Double, blue: Double) {
        let t = min(1, max(0, value))
        guard let upperIndex = stops.firstIndex(where: { $0.location >= t }) else {
            let last = stops[stops.count - 1]
            return (last.red, last.green, last.blue)
        }
        if upperIndex == 0 {
            return (stops[0].red, stops[0].green, stops[0].blue)
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let f = (t - lower.location) / (upper.location - lower.location)
        return (
            lower.red + (upper.red - lower.red) * f,
            lower.green + (upper.green - lower.green) * f,
            lower.blue + (upper.blue - lower.blue) * f
        )
    }

    static func color(at value: Double) -> Color {
        let c = rgb(at: value)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    static let gradient = Gradient(stops: stops.map {
        Gradient.Stop(color: Color(red: $0.red, green: $0.green, blue: $0.blue), location: $0.location)
    })

    static let linearGradient = LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)

    /// Opacity curve: the faintest density fades fully into the map, the hottest stays slightly translucent.
    static func alpha(at value: Double) -> Double {
        let t = min(1, max(0, value))
        let edge = min(1, t / 0.3)
        let smooth = edge * edge * (3 - 2 * edge)
        return smooth * (0.5 + 0.38 * t)
    }

    /// Number of entries in the lookup table; more levels means smoother gradients (less banding).
    static let lookupLevels = 1024

    /// Premultiplied RGBA lookup table used by the renderer.
    static let lookupTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: lookupLevels * 4)
        for i in 0..<lookupLevels {
            let raw = Double(i) / Double(lookupLevels - 1)
            let t = pow(raw, 0.8) // lift low densities a touch so quiet areas still read
            let c = rgb(at: t)
            let a = alpha(at: raw)
            table[i * 4 + 0] = UInt8((c.red * a * 255).rounded())
            table[i * 4 + 1] = UInt8((c.green * a * 255).rounded())
            table[i * 4 + 2] = UInt8((c.blue * a * 255).rounded())
            table[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        return table
    }()
}
