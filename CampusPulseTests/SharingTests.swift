import Foundation
import Testing
@testable import CampusPulse

/// Upload schedule, the campus check, the offline queue and the wire format.
struct SharingTests {
    @Test(arguments: [
        ("10:37:30", "10:38:00"),
        ("10:38:00", "10:40:00"),
        ("10:39:59", "10:40:00"),
        ("23:59:10", "00:00:00"),
    ])
    func nextSlotIsTheNextEvenMinute(now: String, expected: String) {
        let date = Self.utc(now)
        let slot = SharingState.nextSlot(after: date)
        #expect(Self.clock(slot) == expected)
        #expect(slot > date)
    }

    @MainActor
    @Test func campusOutlineContainsBuildingsButNotTheLake() {
        let campus = CampusCatalog.madison
        let library = campus.area(withID: "college_library")!.coordinate
        #expect(SharingState.contains(campus.boundary, library))
        #expect(!SharingState.contains(campus.boundary, Coordinate(43.10, -89.42)))
    }

    @Test func queueSurvivesASaveAndKeepsOnlyTheNewest() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PendingLocationQueue(fileURL: url)
        let points = (0..<(PendingLocationQueue.capacity + 5)).map {
            LocationPoint(lat: 43, lng: -89, timestamp: Date(timeIntervalSince1970: Double($0) * 120), deviceID: "ios-test")
        }

        queue.save(points)
        let loaded = queue.load()

        #expect(loaded.count == PendingLocationQueue.capacity)
        #expect(loaded.first == points[5])
        #expect(loaded.last == points.last)

        queue.save([])
        #expect(queue.load().isEmpty)
    }

    @Test func pointEncodesAsTheBackendExpects() throws {
        let point = LocationPoint(lat: 43.0768, lng: -89.4013, timestamp: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "ios-abc")
        let json = try JSONSerialization.jsonObject(with: LocationAPI.encoder.encode(point)) as? [String: Any]

        #expect(json?["device_id"] as? String == "ios-abc")
        #expect(json?["lat"] as? Double == 43.0768)
        #expect((json?["timestamp"] as? String)?.hasPrefix("2027-01-15T08:00:00") == true)
        // Only the location: the server works out the building.
        #expect(json?["building"] == nil)
        #expect(json?.keys.sorted() == ["device_id", "lat", "lng", "timestamp"])
    }

    @Test func queuedPointsFromTheBuildingTaggingBuildStillLoad() throws {
        // Saved by the build that tagged buildings on the phone; the extra key is ignored.
        let old = #"{"lat":43.07,"lng":-89.4,"timestamp":"2026-11-15T05:10:00Z","device_id":"ios-a","building":"Morgridge Hall"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let point = try decoder.decode(LocationPoint.self, from: Data(old.utf8))
        #expect(point.deviceID == "ios-a")
    }

    @Test func developerDayOverrideParsesAsUTCMidnight() {
        #expect(AppConfig.parseDay("2026-01-01") == AppConfig.defaultHistoryDay)
        #expect(AppConfig.parseDay(" 2026-01-02 ") == AppConfig.defaultHistoryDay.addingTimeInterval(86_400))
        #expect(AppConfig.parseDay("Jan 1") == nil)
    }

    // MARK: - Helpers

    private static func utc(_ time: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-11-14T\(time)Z")!
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
