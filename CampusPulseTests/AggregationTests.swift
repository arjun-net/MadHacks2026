import Foundation
import Testing
@testable import CampusPulse

/// Turning raw readings into what the screens show: which building a reading belongs to,
/// the privacy cutoff, rounding, and levels.
struct AggregationTests {
    let campus = CampusCatalog.madison
    var library: CampusArea { campus.area(withID: "college_library")! }

    /// Buildings come from the server's tag on each reading, never from the coordinates.
    @Test func readingsCountForTheBuildingTheServerTaggedThemWith() {
        let slot = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = [
            // The server stores full names; older rows hold ids.
            Reading(coordinate: Coordinate(43.073141, -89.407074), building: "Morgridge Hall (College of Computing & AI)"),
            Reading(coordinate: Coordinate(43.07328, -89.40690), building: "morgridge_hall"),
            // Untagged: counts toward the heat and the total, but no building,
            // even when the coordinates sit right on one.
            Reading(coordinate: library.coordinate),
            // A building this campus doesn't track.
            Reading(coordinate: Coordinate(43.0764, -89.3996), building: "Memorial Union"),
        ]
        let tally = ActivityAggregator.tally([slot: readings], campus: campus)[slot]!
        #expect(tally.areaCounts == ["morgridge_hall": 2])
        #expect(tally.total == 4)
    }

    @Test func buildingTagsMatchByNameOrID() {
        #expect(campus.areaID(forBuilding: "College Library (Helen C. White Hall)") == "college_library")
        #expect(campus.areaID(forBuilding: "college_library") == "college_library")
        #expect(campus.areaID(forBuilding: "College Library") == nil)
        #expect(campus.areas.count == 20)
    }

    /// `/buildings/counts` lists every building it knows; only this campus's 20 are kept.
    @Test func buildingCountsKeepOnlyTrackedBuildings() {
        let counts = ActivityAggregator.areaCounts(fromBuildingCounts: [
            "Morgridge Hall (College of Computing & AI)": 7,
            "College Library (Helen C. White Hall)": 0,
            "Memorial Union": 12,
        ], campus: campus)
        #expect(counts == ["morgridge_hall": 7, "college_library": 0])
    }

    /// Server counts replace a building's own readings in the current slot; others are untouched.
    @Test func buildingCountsSetTheCurrentNumberAndHeat() {
        let slot = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = slot.addingTimeInterval(-ActivityAggregator.slot)
        let morgridge = campus.area(withID: "morgridge_hall")!
        let real: [Date: [Reading]] = [
            slot: [
                Reading(coordinate: morgridge.coordinate, building: morgridge.name),
                Reading(coordinate: library.coordinate, building: library.name),
                Reading(coordinate: library.coordinate, building: library.name),
                Reading(coordinate: Coordinate(43.07, -89.40)),
            ],
            earlier: [Reading(coordinate: morgridge.coordinate, building: morgridge.name)],
        ]

        let raw = ActivityAggregator.applying(
            buildingCounts: ["morgridge_hall": 6, "college_library": 0], to: real, at: slot, campus: campus
        )
        let tally = ActivityAggregator.tally(raw, campus: campus)

        #expect(tally[slot]?.areaCounts == ["morgridge_hall": 6])
        // Six at Morgridge plus the untagged reading.
        #expect(tally[slot]?.total == 7)
        // Earlier slots keep their readings for the trend.
        #expect(tally[earlier]?.areaCounts == ["morgridge_hall": 1])
        // Six people at one building clears the privacy cutoff, so it shows as heat.
        let cells = ActivityAggregator.cells(from: tally[slot]!.points, around: campus.center)
        #expect(cells.count == 1)
    }

    /// Zero counts still make the current slot the live one, so buildings drop to zero.
    @Test func zeroBuildingCountsStillMakeALiveSlot() {
        let slot = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = ActivityAggregator.applying(buildingCounts: ["morgridge_hall": 0], to: [:], at: slot, campus: campus)
        #expect(raw[slot] == [])
    }

    @Test func activityTabTakesTheLiveReadingForCountedBuildings() {
        let frame = ActivityAggregator.slotStart(Date(timeIntervalSince1970: 1_800_000_000))
        let replayReadings = Array(repeating: Reading(coordinate: library.coordinate, building: library.name), count: 40)
        let replay = ActivityAggregator.snapshot(
            campus: campus, tallies: ActivityAggregator.tally([frame: replayReadings], campus: campus), frame: frame,
            capacities: .fallback(for: campus), generatedAt: frame
        )
        let live = ActivityAggregator.snapshot(
            campus: campus, tallies: ActivityAggregator.tally([frame: []], campus: campus), frame: frame,
            capacities: .fallback(for: campus), generatedAt: frame
        )

        let merged = replay.withCurrentReadings(from: live, for: ["college_library"])

        #expect(merged.activity(for: "college_library")?.intensity == 0)
        #expect(merged.activity(for: "college_library")?.estimatedCount == nil)
        #expect(merged.activity(for: "college_library")?.history.count == ActivityAggregator.historyLength)
    }

    @Test func cellsBelowThePrivacyThresholdAreDropped() {
        let threshold = AppConfig.privacyThreshold
        let crowd = Array(repeating: library.coordinate, count: threshold)
        let tooFew = Array(repeating: campus.area(withID: "morgridge_hall")!.coordinate, count: threshold - 1)

        let cells = ActivityAggregator.cells(from: crowd + tooFew, around: campus.center)

        #expect(cells.count == 1)
        #expect(cells.first?.weight == Int((Double(threshold) * AppConfig.heatWeightPerPerson).rounded()))
    }

    @Test(arguments: [(9, nil), (10, 10), (12, 10), (13, 15), (77, 75)] as [(Int, Int?)])
    func smallCountsAreHiddenAndOthersRoundToFive(raw: Int, shown: Int?) {
        #expect(ActivityAggregator.displayCount(raw) == shown)
    }

    @Test func snapshotCountsTheFrameAndRoundsParticipants() {
        let frame = ActivityAggregator.slotStart(Date(timeIntervalSince1970: 1_800_000_000))
        let readings = Array(repeating: Reading(coordinate: library.coordinate, building: library.name), count: 44)
        let tallies = ActivityAggregator.tally([frame: readings], campus: campus)

        let snapshot = ActivityAggregator.snapshot(
            campus: campus, tallies: tallies, frame: frame,
            capacities: .fallback(for: campus), generatedAt: frame
        )

        #expect(snapshot.participantCount == 40)
        #expect(snapshot.activity(for: "college_library")?.estimatedCount == 45)
        #expect(snapshot.history.count == ActivityAggregator.historyLength)
        // Under 30 people campus-wide is treated as not enough to show.
        #expect(snapshot.isEmpty == false)
    }

    @Test func noRecentFrameMeansAnEmptySnapshot() {
        let snapshot = ActivityAggregator.snapshot(
            campus: campus, tallies: [:], frame: nil,
            capacities: .fallback(for: campus), generatedAt: .now
        )
        #expect(snapshot.isEmpty)
        #expect(snapshot.participantCount == 0)
    }

    @Test(arguments: [(0.0, ActivityLevel.quiet), (0.39, .light), (0.4, .moderate), (0.79, .busy), (1.0, .packed)])
    func intensityMapsToLevel(intensity: Double, level: ActivityLevel) {
        #expect(ActivityLevel(intensity: intensity) == level)
    }
}

/// The stored day replayed at the current time of day.
struct HistoryDayTests {
    let campus = CampusCatalog.madison
    let start = AppConfig.defaultHistoryDay

    @Test func wallClockTimeMapsOntoTheStoredDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 14, minute: 31))!
        let day = HistoryDay(campusID: campus.id, start: start, tallies: [:], capacities: .fallback(for: campus))

        let mapped = day.dataTime(matching: now, calendar: calendar)

        #expect(mapped == start.addingTimeInterval(14 * 3600 + 31 * 60))
    }

    @Test func frameLooksBackUpToTenMinutes() {
        let slot = start.addingTimeInterval(10 * 3600)
        let tallies = [slot: SlotTally(points: [], areaCounts: [:])]
        let day = HistoryDay(campusID: campus.id, start: start, tallies: tallies, capacities: .fallback(for: campus))

        #expect(day.frame(atOrBefore: slot.addingTimeInterval(9 * 60)) == slot)
        #expect(day.frame(atOrBefore: slot.addingTimeInterval(11 * 60)) == nil)
    }

    @Test func oneStoredDayDoesNotVaryByWeekday() {
        let day = HistoryDay(campusID: campus.id, start: start, tallies: [:], capacities: .fallback(for: campus))
        let activity = AreaActivity(area: campus.areas[0], intensity: 0.5, estimatedCount: nil, history: [0.5])

        let insights = day.insights(for: activity, now: .now)

        #expect(insights.variesByWeekday == false)
    }
}
