import SwiftUI
import UIKit

/// Single source of truth for the heat color ramp, shared by the map renderer,
/// the legend, gauges and activity badges so colors always agree.
/// Single-hue sequential ramps: on cream the hottest value is darkest; on dark it's brightest.
enum HeatPalette {
    struct Stop {
        let location: Double
        let red: Double
        let green: Double
        let blue: Double

        init(location: Double, hex: UInt32) {
            self.location = location
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }
    }

    /// Light: sand → amber → brick → Badger red → oxblood.
    static let lightStops: [Stop] = [
        Stop(location: 0.00, hex: 0xF3DFB3),
        Stop(location: 0.30, hex: 0xE9A55A),
        Stop(location: 0.60, hex: 0xD3542E),
        Stop(location: 0.85, hex: 0x9B0000),
        Stop(location: 1.00, hex: 0x5A0008),
    ]

    /// Dark: ember → brick → orange → amber → cream-hot.
    static let darkStops: [Stop] = [
        Stop(location: 0.00, hex: 0x4A1A12),
        Stop(location: 0.30, hex: 0x9B2A1A),
        Stop(location: 0.60, hex: 0xD3542E),
        Stop(location: 0.85, hex: 0xE9A55A),
        Stop(location: 1.00, hex: 0xF6E2B8),
    ]

    static func stops(for style: UIUserInterfaceStyle) -> [Stop] {
        style == .dark ? darkStops : lightStops
    }

    static func rgb(at value: Double, style: UIUserInterfaceStyle) -> (red: Double, green: Double, blue: Double) {
        let stops = stops(for: style)
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

    /// Adaptive ramp color: resolves against the light or dark ramp per trait collection.
    static func uiColor(at value: Double) -> UIColor {
        UIColor { traits in
            let c = rgb(at: value, style: traits.userInterfaceStyle)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        }
    }

    static func color(at value: Double) -> Color {
        Color(uiColor: uiColor(at: value))
    }

    /// Adaptive gradient (each stop resolves per appearance). Light and dark ramps share locations.
    static let gradient = Gradient(stops: lightStops.map {
        Gradient.Stop(color: color(at: $0.location), location: $0.location)
    })

    static let linearGradient = LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)

    /// Opacity curve: the faintest density fades fully into the map, the hottest stays slightly translucent.
    /// Light mode runs a little lighter so the cream map shows through.
    static func alpha(at value: Double, style: UIUserInterfaceStyle) -> Double {
        let t = min(1, max(0, value))
        let edge = min(1, t / 0.3)
        let smooth = edge * edge * (3 - 2 * edge)
        return smooth * ((style == .dark ? 0.5 : 0.45) + 0.38 * t)
    }

    /// Number of entries in the lookup table; more levels means smoother gradients (less banding).
    static let lookupLevels = 1024

    private static let lightTable = makeLookupTable(style: .light)
    private static let darkTable = makeLookupTable(style: .dark)

    /// Premultiplied RGBA lookup table used by the renderer.
    static func lookupTable(for style: UIUserInterfaceStyle) -> [UInt8] {
        style == .dark ? darkTable : lightTable
    }

    private static func makeLookupTable(style: UIUserInterfaceStyle) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: lookupLevels * 4)
        for i in 0..<lookupLevels {
            let raw = Double(i) / Double(lookupLevels - 1)
            let t = pow(raw, 0.8) // lift low densities a touch so quiet areas still read
            let c = rgb(at: t, style: style)
            let a = alpha(at: raw, style: style)
            table[i * 4 + 0] = UInt8((c.red * a * 255).rounded())
            table[i * 4 + 1] = UInt8((c.green * a * 255).rounded())
            table[i * 4 + 2] = UInt8((c.blue * a * 255).rounded())
            table[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        return table
    }
}
