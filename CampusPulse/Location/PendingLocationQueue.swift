import Foundation
import os

/// Points that couldn't be delivered (offline, server down), persisted so they survive relaunches.
/// Flushed in a batch with the next reading.
struct PendingLocationQueue {
    /// Oldest points are dropped beyond this (~2.7 days of 2-minute readings).
    static let capacity = 2000

    private let fileURL: URL
    private static let log = Logger(subsystem: "CampusPulse", category: "LocationQueue")

    init(fileURL: URL = PendingLocationQueue.defaultURL) {
        self.fileURL = fileURL
    }

    func load() -> [LocationPoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([LocationPoint].self, from: data)) ?? []
    }

    func save(_ points: [LocationPoint]) {
        let trimmed = Array(points.suffix(Self.capacity))
        do {
            if trimmed.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LocationAPI.encoder.encode(trimmed).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("Couldn't save pending locations: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "pending-locations.json")

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
