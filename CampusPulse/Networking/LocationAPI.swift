import Foundation
import os

/// One location reading as the backend expects it.
struct LocationPoint: Codable, Equatable, Sendable {
    let lat: Double
    let lng: Double
    /// The even-minute slot the reading belongs to (UTC), not the exact fix time.
    let timestamp: Date
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case lat, lng, timestamp
        case deviceID = "device_id"
    }
}

/// Client for the Campus Pulse location API (`AppConfig.apiBaseURL`).
struct LocationAPI: Sendable {
    enum UploadResult: Equatable, Sendable {
        /// 202: delivered; drop from the local queue.
        case accepted
        /// 422: the payload is invalid. Don't retry it.
        case rejected(String)
        /// Network error, 5xx or unexpected status: keep the points and retry later.
        case retryLater
    }

    static let maxBatchSize = 500

    /// Read per request, so a server change in Settings > Developer applies right away.
    var baseURL: URL { AppConfig.apiBaseURL }
    var session: URLSession = .shared

    private static let log = Logger(subsystem: "CampusPulse", category: "LocationAPI")

    /// Sends one point to `/locations`, or several to `/locations/batch` in chunks of 500.
    /// Stops at the first chunk that isn't accepted.
    func send(_ points: [LocationPoint]) async -> UploadResult {
        guard !points.isEmpty else { return .accepted }
        if points.count == 1 {
            return await post(path: "locations", body: points[0])
        }
        var start = 0
        while start < points.count {
            let chunk = Array(points[start..<min(start + Self.maxBatchSize, points.count)])
            let result = await post(path: "locations/batch", body: Batch(points: chunk))
            guard result == .accepted else { return result }
            start += chunk.count
        }
        return .accepted
    }

    /// `GET /health`: true when the server and its store are up.
    func isHealthy() async -> Bool {
        do {
            let (data, response) = try await session.data(from: baseURL.appending(path: "health"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return (try? JSONDecoder().decode(Health.self, from: data))?.store_ok ?? false
        } catch {
            return false
        }
    }

    // MARK: - Private

    private struct Batch: Encodable { let points: [LocationPoint] }
    private struct Health: Decodable { let status: String; let store_ok: Bool }
    private struct ErrorBody: Decodable { let detail: String }

    private func post(path: String, body: some Encodable) async -> UploadResult {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        do {
            request.httpBody = try Self.encoder.encode(body)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return .accepted
            case 422:
                let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
                    ?? String(decoding: data, as: UTF8.self)
                Self.log.error("Location upload rejected (422): \(detail, privacy: .public)")
                return .rejected(detail)
            default:
                Self.log.error("Location upload failed with HTTP \(status); will retry")
                return .retryLater
            }
        } catch {
            Self.log.error("Location upload network error: \(error.localizedDescription, privacy: .public); will retry")
            return .retryLater
        }
    }

    /// ISO-8601 in UTC with a trailing Z and whole seconds, e.g. `2026-11-14T22:34:00Z`.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampString(date))
        }
        return encoder
    }()

    static func timestampString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }
}
