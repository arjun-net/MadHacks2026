import Foundation

/// Everyone counted in one 2-minute slot.
struct SlotTally: Sendable {
    let points: [Coordinate]
    /// Readings attributed to each tracked area, keyed by area ID.
    let areaCounts: [String: Int]

    var total: Int { points.count }
    static let empty = SlotTally(points: [], areaCounts: [:])
}

/// Headcounts that count as "packed" (intensity 1) for each area and for the whole campus.
struct Capacities: Sendable {
    var area: [String: Double]
    var campus: Double

    /// Scaled by each area's popularity. Used before history has loaded, and for simulated data.
    static func fallback(for campus: Campus, perPopularity: Double = AppConfig.fallbackAreaCapacity) -> Capacities {
        let area = Dictionary(uniqueKeysWithValues: campus.areas.map { ($0.id, max(10, $0.popularity * perPopularity)) })
        return Capacities(area: area, campus: max(30, area.values.reduce(0, +)))
    }

    /// Each area's busiest slot in the history counts as packed.
    static func peaks(of tallies: [Date: SlotTally], campus: Campus) -> Capacities {
        var area: [String: Double] = [:]
        for item in campus.areas {
            let peak = tallies.values.map { $0.areaCounts[item.id] ?? 0 }.max() ?? 0
            area[item.id] = max(10, Double(peak))
        }
        let campusPeak = tallies.values.map(\.total).max() ?? 0
        return Capacities(area: area, campus: max(30, Double(campusPeak)))
    }
}

/// Turns raw server readings into the snapshot and insight models the screens use.
enum ActivityAggregator {
    static let slot = AppConfig.updateInterval
    static let historyLength = 12

    static func slotStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / slot).rounded(.down) * slot)
    }

    static func tally(_ slots: [Date: [Coordinate]], campus: Campus) -> [Date: SlotTally] {
        slots.mapValues { points in
            var counts: [String: Int] = [:]
            for point in points {
                if let id = area(containing: point, in: campus) { counts[id, default: 0] += 1 }
            }
            return SlotTally(points: points, areaCounts: counts)
        }
    }

    /// The tracked area a reading counts for. Where the campus has building outlines, it's the
    /// building the reading is in or near, by the same rule as the pings sent to the server;
    /// elsewhere, the nearest area whose rough footprint (with a small margin) contains it.
    static func area(containing point: Coordinate, in campus: Campus) -> String? {
        if let locator = BuildingLocator.forCampus(campus.id) {
            return locator.buildingID(at: point).flatMap { campus.area(withID: $0)?.id }
        }
        var best: (id: String, distance: Double)?
        for area in campus.areas {
            let distance = area.coordinate.distance(to: point)
            guard distance <= area.radiusMeters * 1.3 else { continue }
            if distance < best?.distance ?? .infinity { best = (area.id, distance) }
        }
        return best?.id
    }

    /// Snapshot for `frame`, with the 12 slots up to it as the trend.
    /// A nil frame (no recent readings) produces an empty snapshot.
    static func snapshot(
        campus: Campus,
        tallies: [Date: SlotTally],
        frame: Date?,
        capacities: Capacities,
        generatedAt: Date,
        replayOf: Date? = nil
    ) -> CampusSnapshot {
        let slots: [Date] = frame.map { frame in
            (0..<historyLength).map { frame.addingTimeInterval(-Double(historyLength - 1 - $0) * slot) }
        } ?? []
        let window = slots.map { tallies[$0] ?? .empty }
        let current = window.last ?? .empty

        let areas = campus.areas.map { area in
            let capacity = capacities.area[area.id] ?? AppConfig.fallbackAreaCapacity
            let history = window.isEmpty ? [0] : window.map { clamp(Double($0.areaCounts[area.id] ?? 0) / capacity) }
            let count = current.areaCounts[area.id] ?? 0
            return AreaActivity(area: area, intensity: history.last ?? 0, estimatedCount: displayCount(count), history: history)
        }
        let campusHistory = window.isEmpty ? [0] : window.map { clamp(Double($0.total) / capacities.campus) }

        return CampusSnapshot(
            campusID: campus.id,
            generatedAt: generatedAt,
            participantCount: Int((Double(current.total) / 10).rounded()) * 10,
            overallIntensity: campusHistory.last ?? 0,
            cells: cells(from: current.points, around: campus.center),
            areas: areas,
            history: campusHistory,
            privacyThreshold: AppConfig.privacyThreshold,
            replayOf: replayOf
        )
    }

    /// Bins readings into ~35 m cells; cells with fewer than the privacy threshold are dropped.
    static func cells(from points: [Coordinate], around origin: Coordinate) -> [DensityCell] {
        let size = AppConfig.aggregationCellMeters
        let probe = origin.offset(eastMeters: 1000, northMeters: 1000)
        let metersPerLat = 1000 / (probe.latitude - origin.latitude)
        let metersPerLng = 1000 / (probe.longitude - origin.longitude)

        var bins: [Int: [Int: Int]] = [:]
        for point in points {
            let row = Int(((point.latitude - origin.latitude) * metersPerLat / size).rounded(.down))
            let column = Int(((point.longitude - origin.longitude) * metersPerLng / size).rounded(.down))
            bins[row, default: [:]][column, default: 0] += 1
        }
        var cells: [DensityCell] = []
        for (row, columns) in bins {
            for (column, count) in columns where count >= AppConfig.privacyThreshold {
                cells.append(DensityCell(
                    coordinate: origin.offset(eastMeters: (Double(column) + 0.5) * size, northMeters: (Double(row) + 0.5) * size),
                    weight: Int((Double(count) * AppConfig.heatWeightPerPerson).rounded())
                ))
            }
        }
        return cells
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Small counts are hidden; larger ones are rounded to the nearest 5.
    static func displayCount(_ value: Int) -> Int? {
        guard value >= AppConfig.minimumDisplayedCount else { return nil }
        return Int((Double(value) / 5).rounded()) * 5
    }
}

/// One stored day of readings (the server's history), replayed at the current time of day.
/// The dataset's timestamps are campus wall-clock times, so 2:30 PM today maps to 14:30 on that day.
struct HistoryDay: Sendable {
    let campusID: String
    /// Start of the dataset day as stored (`AppConfig.historyDay`).
    let start: Date
    let tallies: [Date: SlotTally]
    let capacities: Capacities

    var isEmpty: Bool { tallies.isEmpty }

    /// The same wall-clock time on the dataset day.
    func dataTime(matching date: Date, calendar: Calendar = .current) -> Date {
        start.addingTimeInterval(date.timeIntervalSince(calendar.startOfDay(for: date)))
    }

    /// The latest slot with readings at or before `dataTime`, looking back up to 10 minutes.
    func frame(atOrBefore dataTime: Date) -> Date? {
        var candidate = ActivityAggregator.slotStart(dataTime)
        for _ in 0..<5 {
            if tallies[candidate] != nil { return candidate }
            candidate = candidate.addingTimeInterval(-ActivityAggregator.slot)
        }
        return nil
    }

    func snapshot(for campus: Campus, now: Date = .now) -> CampusSnapshot {
        let dataTime = dataTime(matching: now)
        return ActivityAggregator.snapshot(
            campus: campus,
            tallies: tallies,
            frame: frame(atOrBefore: dataTime),
            capacities: capacities,
            generatedAt: now,
            replayOf: dataTime
        )
    }

    /// Busy times for one area: average activity in each hour of the stored day.
    func hourly(for areaID: String) -> [HourlyValue] {
        let capacity = capacities.area[areaID] ?? AppConfig.fallbackAreaCapacity
        let perHour = Int(3600 / ActivityAggregator.slot)
        return (0..<24).map { hour in
            let counts = (0..<perHour).compactMap { index -> Int? in
                let slot = start.addingTimeInterval(Double(hour) * 3600 + Double(index) * ActivityAggregator.slot)
                return tallies[slot].map { $0.areaCounts[areaID] ?? 0 }
            }
            let average = counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count)
            return HourlyValue(hour: Double(hour), intensity: min(1, average / capacity))
        }
    }

    /// With a single stored day, that day is both the "usual" profile and the only past day.
    func insights(for activity: AreaActivity, now: Date, calendar: Calendar = .current) -> AreaInsights {
        let profile = hourly(for: activity.area.id)
        let typical = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, profile) })

        // Shown as a local calendar date (the stored day's date, not shifted by time zone).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let parts = utc.dateComponents([.year, .month, .day], from: start)
        let displayDate = calendar.date(from: parts) ?? start
        let pastDays = [DayHistory(date: displayDate, hourly: profile)]

        let currentHour = now.fractionalHour
        var today = profile
            .filter { $0.hour + 0.5 < currentHour }
            .map { HourlyValue(hour: $0.hour + 0.5, intensity: $0.intensity) }
        today.append(HourlyValue(hour: currentHour, intensity: activity.intensity))

        return AreaInsights(area: activity.area, generatedAt: now, typicalByWeekday: typical, pastDays: pastDays, today: today)
    }
}
