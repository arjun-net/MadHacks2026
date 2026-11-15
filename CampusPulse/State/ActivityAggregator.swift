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

    /// Counts each slot's readings per area by the building the server tagged them with.
    /// Untagged readings still count toward the heat and the campus total.
    /// Readings the server placed in a building the campus doesn't track are left out entirely
    /// (no heat, not in the total); readings outside any building are kept.
    static func tally(_ slots: [Date: [Reading]], campus: Campus) -> [Date: SlotTally] {
        slots.mapValues { readings in
            var counts: [String: Int] = [:]
            var points: [Coordinate] = []
            for reading in readings {
                if let building = reading.building {
                    guard let id = campus.areaID(forBuilding: building) else { continue }
                    counts[id, default: 0] += 1
                }
                points.append(reading.coordinate)
            }
            return SlotTally(points: points, areaCounts: counts)
        }
    }

    /// The server's per-building counts for this campus's buildings, keyed by area ID.
    /// Buildings the campus doesn't track are left out.
    static func areaCounts(fromBuildingCounts byBuilding: [String: Int], campus: Campus) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (building, count) in byBuilding {
            if let id = campus.areaID(forBuilding: building) { counts[id, default: 0] += max(0, count) }
        }
        return counts
    }

    /// Makes the server's building counts the truth for `slot`: each counted building's own
    /// readings in that slot are swapped for `count` readings at the building. Those then
    /// drive both the building's number and its heat (still under the privacy cutoff).
    /// Pass real readings only; simulated ones are added afterwards.
    static func applying(buildingCounts: [String: Int], to slots: [Date: [Reading]], at slot: Date, campus: Campus) -> [Date: [Reading]] {
        guard !buildingCounts.isEmpty else { return slots }
        var result = slots
        var current = (result[slot] ?? []).filter { reading in
            guard let id = reading.building.flatMap(campus.areaID(forBuilding:)) else { return true }
            return buildingCounts[id] == nil
        }
        for (id, count) in buildingCounts where count > 0 {
            guard let area = campus.area(withID: id) else { continue }
            current += Array(repeating: Reading(coordinate: area.coordinate, building: area.id), count: count)
        }
        // Present even when empty, so this slot is the live frame and zero counts show as zero.
        result[slot] = current
        return result
    }

    /// Snapshot for `frame`, with the 12 slots up to it as the trend.
    /// A nil frame (no recent readings) produces an empty snapshot.
    static func snapshot(
        campus: Campus,
        tallies: [Date: SlotTally],
        frame: Date?,
        capacities: Capacities,
        generatedAt: Date
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
            privacyThreshold: AppConfig.privacyThreshold
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
/// The last 24 hours of real readings for one campus: how big each place gets (its busiest
/// slot) and its usual busy times by hour.
struct HistoryDay: Sendable {
    static let length: TimeInterval = 86_400

    let campusID: String
    /// The first slot of the 24 hours.
    let start: Date
    let tallies: [Date: SlotTally]
    let capacities: Capacities

    var isEmpty: Bool { tallies.isEmpty }

    /// The 24 hours ending with the slot `now` is in.
    static func window(endingAt now: Date) -> (start: Date, end: Date) {
        let end = ActivityAggregator.slotStart(now).addingTimeInterval(ActivityAggregator.slot)
        return (end.addingTimeInterval(-length), end)
    }

    /// Busy times for one area: average activity in each hour of the day (local time) over the
    /// 24 hours. A slot with no readings counts as nobody there.
    func hourly(for areaID: String, calendar: Calendar = .current) -> [HourlyValue] {
        let capacity = capacities.area[areaID] ?? AppConfig.fallbackAreaCapacity
        var sums = [Double](repeating: 0, count: 24)
        var slots = [Int](repeating: 0, count: 24)
        for index in 0..<Int(Self.length / ActivityAggregator.slot) {
            let slot = start.addingTimeInterval(Double(index) * ActivityAggregator.slot)
            let hour = calendar.component(.hour, from: slot)
            sums[hour] += Double(tallies[slot]?.areaCounts[areaID] ?? 0)
            slots[hour] += 1
        }
        return (0..<24).map { hour in
            let average = slots[hour] == 0 ? 0 : sums[hour] / Double(slots[hour])
            return HourlyValue(hour: Double(hour), intensity: min(1, average / capacity))
        }
    }

    /// With 24 hours of history, that profile is both the "usual" day and the one past day.
    func insights(for activity: AreaActivity, now: Date, calendar: Calendar = .current) -> AreaInsights {
        let profile = hourly(for: activity.area.id, calendar: calendar)
        let typical = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, profile) })
        let pastDays = [DayHistory(date: calendar.startOfDay(for: start), hourly: profile)]

        let currentHour = now.fractionalHour
        var today = profile
            .filter { $0.hour + 0.5 < currentHour }
            .map { HourlyValue(hour: $0.hour + 0.5, intensity: $0.intensity) }
        today.append(HourlyValue(hour: currentHour, intensity: activity.intensity))

        return AreaInsights(area: activity.area, generatedAt: now, typicalByWeekday: typical, pastDays: pastDays, today: today)
    }
}
