import Foundation
import MapKit

/// Client for `GET /heatmap`: every reading in a time range, grouped by 2-minute slot.
struct HeatmapAPI: Sendable {
    /// Read per request, so a server change in Settings > Developer applies right away.
    var baseURL: URL { AppConfig.apiBaseURL }
    var session: URLSession = .shared

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Readings keyed by slot time (start inclusive, end exclusive), optionally limited to a map rect.
    func points(from start: Date, to end: Date, in rect: MKMapRect? = nil, limit: Int = 200_000) async throws -> [Date: [Coordinate]] {
        var components = URLComponents(url: baseURL.appending(path: "heatmap"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "start", value: LocationAPI.timestampString(start)),
            URLQueryItem(name: "end", value: LocationAPI.timestampString(end)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let rect, let bbox = Self.bbox(rect) {
            items.append(URLQueryItem(name: "bbox", value: bbox))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw Failure(message: detail ?? "The server returned HTTP \(status).")
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        var result: [Date: [Coordinate]] = [:]
        for (key, points) in body.data {
            guard let date = try? Date(key, strategy: .iso8601) else { continue }
            result[date] = points.map { Coordinate($0.lat, $0.lng) }
        }
        return result
    }

    /// Fetches a long range in parallel chunks so no single response hits the server's point limit.
    func points(from start: Date, to end: Date, in rect: MKMapRect?, chunks: Int) async throws -> [Date: [Coordinate]] {
        let step = end.timeIntervalSince(start) / Double(chunks)
        return try await withThrowingTaskGroup(of: [Date: [Coordinate]].self) { group in
            for index in 0..<chunks {
                let chunkStart = start.addingTimeInterval(step * Double(index))
                let chunkEnd = index == chunks - 1 ? end : start.addingTimeInterval(step * Double(index + 1))
                group.addTask { try await points(from: chunkStart, to: chunkEnd, in: rect) }
            }
            var merged: [Date: [Coordinate]] = [:]
            for try await chunk in group {
                merged.merge(chunk) { $0 + $1 }
            }
            return merged
        }
    }

    // MARK: - Private

    private struct Body: Decodable {
        let data: [String: [Point]]
    }

    private struct Point: Decodable {
        let lat: Double
        let lng: Double
    }

    private struct ErrorBody: Decodable { let detail: String }

    /// `minLng,minLat,maxLng,maxLat`.
    private static func bbox(_ rect: MKMapRect) -> String? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let northWest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let southEast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        // Map points grow eastward and southward, so the top-left corner is the north-west one.
        return [northWest.longitude, southEast.latitude, southEast.longitude, northWest.latitude]
            .map { String(format: "%.6f", $0) }
            .joined(separator: ",")
    }
}
