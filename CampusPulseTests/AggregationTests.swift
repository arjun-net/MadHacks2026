import Foundation
import Testing
@testable import CampusPulse

/// Turning raw readings into what the screens show: which building a reading belongs to,
/// the privacy cutoff, rounding, and levels.
struct AggregationTests {
    let campus = CampusCatalog.madison
    var library: CampusArea { campus.area(withID: "college-library")! }

    @Test func readingOnABuildingCountsForIt() {
        let point = library.coordinate.offset(eastMeters: 5, northMeters: -5)
        #expect(ActivityAggregator.area(containing: point, in: campus) == "college-library")
    }

    @Test func readingFarFromEveryBuildingCountsForNone() {
        let lakeMiddle = Coordinate(43.10, -89.42)
        #expect(ActivityAggregator.area(containing: lakeMiddle, in: campus) == nil)
    }

    @Test func cellsBelowThePrivacyThresholdAreDropped() {
        let threshold = AppConfig.privacyThreshold
        let crowd = Array(repeating: library.coordinate, count: threshold)
        let tooFew = Array(repeating: campus.area(withID: "van-hise")!.coordinate, count: threshold - 1)

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
        let points = Array(repeating: library.coordinate, count: 44)
        let tallies = ActivityAggregator.tally([frame: points], campus: campus)

        let snapshot = ActivityAggregator.snapshot(
            campus: campus, tallies: tallies, frame: frame,
            capacities: .fallback(for: campus), generatedAt: frame
        )

        #expect(snapshot.participantCount == 40)
        #expect(snapshot.activity(for: "college-library")?.estimatedCount == 45)
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
