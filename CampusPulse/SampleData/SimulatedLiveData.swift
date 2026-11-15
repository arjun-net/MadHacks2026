import Foundation

/// Fake live readings generated on the device so the map has a crowd to show.
/// They are mixed into what the server returns for display only and are never uploaded.
/// Turn off with `AppConfig.simulatesLiveData`.
enum SimulatedLiveData {
    /// Readings for every 2-minute slot in `slots`, scattered around each campus building and
    /// tagged with it, as the server tags real ones. Walkers between buildings have no building.
    ///
    /// Each building's headcount follows its usual curve for the time of day and weekday.
    /// Past slots are repeatable, so trends don't rewrite themselves; the newest slot gets
    /// fresh variation on every call, and every point lands in a new random spot, so each
    /// refresh looks a little different.
    static func points(for campus: Campus, slots: [Date], capacities: Capacities) -> [Date: [Reading]] {
        let newest = slots.max()
        var result: [Date: [Reading]] = [:]
        var generator = SystemRandomNumberGenerator()

        for slot in slots {
            var points: [Reading] = []
            let slotNumber = Int(slot.timeIntervalSince1970 / ActivityAggregator.slot)
            for (index, area) in campus.areas.enumerated() {
                let usual = SampleActivityData.expectedIntensity(of: area, campus: campus, at: slot)
                var wobble = 1 + 0.12 * noise(slotNumber, index) + 0.06 * noise(slotNumber / 5, index + 97)
                if slot == newest {
                    wobble += Double.random(in: -0.08...0.08, using: &generator)
                }
                let capacity = capacities.area[area.id] ?? AppConfig.fallbackAreaCapacity
                let count = max(0, Int((capacity * usual * wobble).rounded()))
                let spread = area.radiusMeters * 0.35
                for _ in 0..<count {
                    let (east, north) = gaussianPair(&generator)
                    points.append(Reading(coordinate: area.coordinate.offset(eastMeters: east * spread, northMeters: north * spread), building: area.id))
                }
            }
            // A light scatter of people walking between buildings.
            let walkers = points.count / 12
            for _ in 0..<walkers {
                guard let from = campus.areas.randomElement(using: &generator),
                      let to = campus.areas.randomElement(using: &generator) else { break }
                let t = Double.random(in: 0...1, using: &generator)
                points.append(Reading(coordinate: Coordinate(
                    from.coordinate.latitude + (to.coordinate.latitude - from.coordinate.latitude) * t,
                    from.coordinate.longitude + (to.coordinate.longitude - from.coordinate.longitude) * t
                )))
            }
            result[slot] = points
        }
        return result
    }

    /// Two independent standard-normal values (Box–Muller).
    private static func gaussianPair(_ generator: inout SystemRandomNumberGenerator) -> (Double, Double) {
        let u1 = Double.random(in: Double.ulpOfOne...1, using: &generator)
        let u2 = Double.random(in: 0...1, using: &generator)
        let radius = (-2 * log(u1)).squareRoot()
        return (radius * cos(2 * .pi * u2), radius * sin(2 * .pi * u2))
    }

    /// Repeatable pseudo-random value in -1…1.
    private static func noise(_ a: Int, _ b: Int) -> Double {
        let x = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }
}
