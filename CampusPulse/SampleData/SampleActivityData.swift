import Foundation

/// Static sample data that drives the UI. There is no backend and no location collection;
/// this only produces believable heat cells and area stats around campus buildings so the
/// screens have something to render. `tick` nudges values so updates animate.
enum SampleActivityData {
    static let peakAreaHeadcount = 170.0
    static let historyLength = 12

    static func snapshot(for campus: Campus, tick: Int = 0, date: Date = .now) -> CampusSnapshot {
        let hour = date.fractionalHour
        let step = AppConfig.updateInterval / 3600

        let areas: [AreaActivity] = campus.areas.enumerated().map { index, area in
            let history = (0..<historyLength).map { sample in
                let stepsBack = historyLength - 1 - sample
                return intensity(of: area, index: index, campus: campus, hour: hour - Double(stepsBack) * step, tick: tick - stepsBack)
            }
            let current = history.last ?? 0
            return AreaActivity(
                area: area,
                intensity: current,
                estimatedCount: displayCount(Int((current * peakAreaHeadcount).rounded())),
                history: history
            )
        }

        let cells = heatCells(for: campus, areas: areas)
        let headcount = areas.reduce(0) { $0 + $1.intensity * peakAreaHeadcount } * 1.2
        let capacity = campus.areas.reduce(0) { $0 + $1.popularity } * peakAreaHeadcount * 0.8
        let campusHistory = (0..<historyLength).map { i in
            min(1, areas.reduce(0) { $0 + $1.history[i] * peakAreaHeadcount } / max(capacity, 1))
        }

        return CampusSnapshot(
            campusID: campus.id,
            generatedAt: date,
            participantCount: Int((headcount / 10).rounded()) * 10,
            overallIntensity: campusHistory.last ?? 0,
            cells: cells,
            areas: areas,
            history: campusHistory,
            privacyThreshold: AppConfig.privacyThreshold
        )
    }

    // MARK: - Shapes

    /// Soft disc of cells around each building, plus faint corridors between nearby buildings.
    private static func heatCells(for campus: Campus, areas: [AreaActivity]) -> [DensityCell] {
        let spacing = 30.0
        var cells: [DensityCell] = []

        for activity in areas {
            let area = activity.area
            let radius = area.radiusMeters * 1.4
            let sigma = area.radiusMeters * 0.6
            let steps = Int(radius / spacing)
            for row in -steps...steps {
                for column in -steps...steps {
                    let east = Double(column) * spacing
                    let north = Double(row) * spacing
                    let distanceSquared = east * east + north * north
                    guard distanceSquared <= radius * radius else { continue }
                    let weight = activity.intensity * 58 * exp(-distanceSquared / (2 * sigma * sigma))
                    guard weight >= Double(AppConfig.privacyThreshold) else { continue }
                    cells.append(DensityCell(
                        coordinate: area.coordinate.offset(eastMeters: east, northMeters: north),
                        weight: Int(weight.rounded())
                    ))
                }
            }
        }

        for (i, a) in areas.enumerated() {
            for b in areas[(i + 1)...] where a.area.coordinate.distance(to: b.area.coordinate) < 450 {
                let busy = min(a.intensity, b.intensity)
                guard busy > 0.35 else { continue }
                let distance = a.area.coordinate.distance(to: b.area.coordinate)
                let count = max(2, Int(distance / 45))
                for k in 1..<count {
                    let t = Double(k) / Double(count)
                    cells.append(DensityCell(
                        coordinate: Coordinate(
                            a.area.coordinate.latitude + (b.area.coordinate.latitude - a.area.coordinate.latitude) * t,
                            a.area.coordinate.longitude + (b.area.coordinate.longitude - a.area.coordinate.longitude) * t
                        ),
                        weight: Int((busy * 16).rounded())
                    ))
                }
            }
        }
        return cells
    }

    private static func intensity(of area: CampusArea, index: Int, campus: Campus, hour: Double, tick: Int) -> Double {
        let h = (hour + 24).truncatingRemainder(dividingBy: 24)
        let t = Double(tick)
        let i = Double(index)
        let wobble = 0.86 + 0.1 * sin(t * 0.85 + i * 1.9) + 0.05 * sin(t * 2.3 + i * 0.7)
        return min(1, max(0, area.popularity * area.category.demand(atHour: h) * wobble * campus.participationScale))
    }

    private static func displayCount(_ value: Int) -> Int? {
        guard value >= AppConfig.minimumDisplayedCount else { return nil }
        return Int((Double(value) / 5).rounded()) * 5
    }
}
