import Foundation

/// Client for `GET /buildings/counts`: how many people the server placed in each building over
/// its last window (2 minutes). Every building it knows is listed, including empty ones.
struct BuildingCountsAPI: Sendable {
    struct Counts: Sendable, Equatable {
        /// People per building, by the server's building name.
        let byBuilding: [String: Int]
        let total: Int
        let windowMinutes: Int
    }

    /// Read per request, so a server change in Settings > Developer applies right away.
    var baseURL: URL { AppConfig.apiBaseURL }
    var session: URLSession = .shared

    func counts() async throws -> Counts {
        var request = URLRequest(url: baseURL.appending(path: "buildings/counts"))
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw HeatmapAPI.Failure(message: detail ?? "The server returned HTTP \(status).")
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return Counts(byBuilding: body.counts, total: body.total, windowMinutes: body.windowMinutes)
    }

    private struct Body: Decodable {
        let counts: [String: Int]
        let total: Int
        let windowMinutes: Int

        enum CodingKeys: String, CodingKey {
            case counts, total
            case windowMinutes = "window_minutes"
        }
    }

    private struct ErrorBody: Decodable { let detail: String }
}
