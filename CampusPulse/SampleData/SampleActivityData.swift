import Foundation

/// Static sample data that drives the UI. There is no backend and no location collection;
/// this only produces believable heat cells and area stats around campus buildings so the
/// screens have something to render. `tick` nudges values so updates animate.
enum SampleActivityData {
    static let peakAreaHeadcount = 170.0
    static let historyLength = 12

    static func snapshot(for campus: Campus, tick: Int = 0, date: Date = .now) -> CampusSnapshot {
        let hour = date.fractionalHour
        let weekday = Calendar.current.component(.weekday, from: date)
        let step = AppConfig.updateInterval / 3600

        let areas: [AreaActivity] = campus.areas.enumerated().map { index, area in
            let history = (0..<historyLength).map { sample in
                let stepsBack = historyLength - 1 - sample
                return intensity(of: area, index: index, campus: campus, weekday: weekday, hour: hour - Double(stepsBack) * step, tick: tick - stepsBack)
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

    /// Average of the live `wobble`, so typical values line up with live ones.
    private static let meanWobble = 0.86

    private static func intensity(of area: CampusArea, index: Int, campus: Campus, weekday: Int, hour: Double, tick: Int) -> Double {
        let h = (hour + 24).truncatingRemainder(dividingBy: 24)
        let t = Double(tick)
        let i = Double(index)
        let wobble = meanWobble + 0.1 * sin(t * 0.85 + i * 1.9) + 0.05 * sin(t * 2.3 + i * 0.7)
        return clamp(baseline(of: area, campus: campus, weekday: weekday, hour: h) * wobble)
    }

    /// Expected activity before any random variation.
    private static func baseline(of area: CampusArea, campus: Campus, weekday: Int, hour: Double) -> Double {
        area.popularity * area.category.demand(atHour: hour) * weekdayFactor(area.category, weekday: weekday) * campus.participationScale
    }

    /// How a category's crowd shifts across the week (`Calendar` weekday: 1 = Sunday … 7 = Saturday).
    static func weekdayFactor(_ category: AreaCategory, weekday: Int) -> Double {
        let isWeekend = weekday == 1 || weekday == 7
        let isFriday = weekday == 6
        switch category {
        case .academic: return isWeekend ? 0.55 : isFriday ? 0.85 : 1.0
        case .library: return weekday == 7 ? 0.75 : weekday == 1 ? 0.95 : isFriday ? 0.85 : 1.0
        case .union: return isFriday ? 1.08 : isWeekend ? 0.9 : 1.0
        case .dining: return isWeekend ? 0.88 : 1.0
        case .recreation: return isWeekend ? 1.08 : weekday == 2 ? 1.1 : 1.0
        case .housing: return isWeekend ? 1.12 : 1.0
        case .athletics: return weekday == 7 ? 1.6 : weekday == 1 ? 1.05 : 0.9
        case .outdoors: return isWeekend ? 1.15 : 1.0
        }
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func displayCount(_ value: Int) -> Int? {
        guard value >= AppConfig.minimumDisplayedCount else { return nil }
        return Int((Double(value) / 5).rounded()) * 5
    }

    // MARK: - History

    /// Typical week, the past seven days and today so far for one area.
    /// Deterministic per area and date, so history doesn't change between refreshes.
    static func insights(for activity: AreaActivity, campus: Campus, date: Date = .now) -> AreaInsights {
        let area = activity.area
        let calendar = Calendar.current
        let hours = (0..<24).map(Double.init)
        let seed = area.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 100_003 }

        var typical: [Int: [HourlyValue]] = [:]
        for weekday in 1...7 {
            typical[weekday] = hours.map { hour in
                HourlyValue(hour: hour, intensity: clamp(baseline(of: area, campus: campus, weekday: weekday, hour: hour + 0.5) * meanWobble))
            }
        }

        func recorded(on day: Date, hour: Double) -> Double {
            let weekday = calendar.component(.weekday, from: day)
            let dayNumber = Int(day.timeIntervalSinceReferenceDate / 86_400)
            let dayVariation = noise(seed, dayNumber, 0) * 0.14
            let hourVariation = noise(seed, dayNumber, Int(hour) + 1) * 0.06
            return clamp(baseline(of: area, campus: campus, weekday: weekday, hour: hour + 0.5) * (meanWobble + dayVariation + hourVariation))
        }

        let startOfToday = calendar.startOfDay(for: date)
        let pastDays: [DayHistory] = (1...7).reversed().compactMap { daysAgo in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday) else { return nil }
            return DayHistory(date: day, hourly: hours.map { HourlyValue(hour: $0, intensity: recorded(on: day, hour: $0)) })
        }

        let now = date.fractionalHour
        var today = hours.filter { $0 + 0.5 < now }.map { HourlyValue(hour: $0 + 0.5, intensity: recorded(on: startOfToday, hour: $0)) }
        today.append(HourlyValue(hour: now, intensity: activity.intensity))

        return AreaInsights(area: area, generatedAt: date, typicalByWeekday: typical, pastDays: pastDays, today: today)
    }

    /// Repeatable pseudo-random value in -1…1.
    private static func noise(_ a: Int, _ b: Int, _ c: Int) -> Double {
        let x = sin(Double(a) * 12.9898 + Double(b) * 78.233 + Double(c) * 37.719) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }
}
