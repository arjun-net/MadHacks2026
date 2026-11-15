import Foundation
import Observation
import os

/// Activity for the selected campus, from the backend.
/// - `snapshot`: live, from the last few 2-minute slots (the map).
/// - `historySnapshot` / `history`: the server's stored day, replayed at the current time of day
///   (the Activity tab's trends and the area detail screens).
@Observable
@MainActor
final class CampusStore {
    let campuses: [Campus]
    private(set) var campus: Campus

    /// Live activity for the map.
    private(set) var snapshot: CampusSnapshot?
    private(set) var state: LoadState = .idle

    /// Past data for trends.
    private(set) var historySnapshot: CampusSnapshot?
    private(set) var historyState: LoadState = .idle
    private(set) var history: HistoryDay?

    private(set) var isRefreshing = false
    /// Previews run on bundled sample data instead of the network.
    let isPreview: Bool

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let api = HeatmapAPI()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "CampusPulse", category: "CampusStore")

    init(campuses: [Campus], preferences: AppPreferences, initialSnapshot: CampusSnapshot? = nil) {
        self.campuses = campuses
        self.preferences = preferences
        self.campus = campuses.first { $0.id == preferences.selectedCampusID } ?? campuses[0]
        self.isPreview = initialSnapshot != nil
        if let initialSnapshot, initialSnapshot.campusID == campus.id {
            snapshot = initialSnapshot
            historySnapshot = initialSnapshot
            state = initialSnapshot.isEmpty ? .empty : .loaded
            historyState = state
        }
    }

    func start() {
        guard loopTask == nil, !isPreview else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(AppConfig.liveRefreshInterval))
            }
        }
    }

    func refresh() async {
        guard !isPreview, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if history?.campusID != campus.id {
            loadHistory()
        } else if let history {
            updateHistorySnapshot(from: history)
        }
        await refreshLive()
    }

    func select(_ newCampus: Campus) {
        guard newCampus.id != campus.id else { return }
        campus = newCampus
        preferences.selectedCampusID = newCampus.id
        snapshot = nil
        state = .loading
        historySnapshot = nil
        historyState = .loading
        history = nil
        historyTask?.cancel()
        historyTask = nil
        isRefreshing = false
        loopTask?.cancel()
        loopTask = nil
        start()
    }

    // MARK: - Live

    private func refreshLive() async {
        let requested = campus
        if snapshot == nil { state = .loading }
        let now = Date.now
        let currentSlot = ActivityAggregator.slotStart(now)
        let windowStart = currentSlot.addingTimeInterval(-Double(ActivityAggregator.historyLength) * ActivityAggregator.slot)
        do {
            var raw: [Date: [Coordinate]]
            do {
                raw = try await api.points(from: windowStart, to: currentSlot.addingTimeInterval(ActivityAggregator.slot), in: requested.boundaryRect)
            } catch where AppConfig.simulatesLiveData {
                // With simulated data on, the map still works when the server is unreachable.
                Self.log.error("Live heatmap failed, showing simulated data only: \(error.localizedDescription, privacy: .public)")
                raw = [:]
            }
            guard requested.id == campus.id else { return }
            // Simulated crowds have their own fixed building sizes, so levels don't shift when history loads.
            let capacities: Capacities = AppConfig.simulatesLiveData
                ? .fallback(for: requested, perPopularity: AppConfig.simulatedPeakHeadcount)
                : history?.capacities ?? .fallback(for: requested)
            if AppConfig.simulatesLiveData {
                let slots = (0...ActivityAggregator.historyLength).map { windowStart.addingTimeInterval(Double($0) * ActivityAggregator.slot) }
                let simulated = await Task.detached { SimulatedLiveData.points(for: requested, slots: slots, capacities: capacities) }.value
                raw.merge(simulated) { real, fake in real + fake }
            }
            let tallies = await Task.detached { [raw] in ActivityAggregator.tally(raw, campus: requested) }.value
            // Live means a slot with readings in the last few minutes.
            let frame = tallies.keys.filter { $0 >= now.addingTimeInterval(-AppConfig.liveFreshness) }.max()
            let next = ActivityAggregator.snapshot(
                campus: requested,
                tallies: tallies,
                frame: frame,
                capacities: capacities,
                // Stamped with the fetch time so every refresh redraws the map.
                generatedAt: now
            )
            snapshot = next
            state = next.isEmpty ? .empty : .loaded
        } catch {
            Self.log.error("Live heatmap failed: \(error.localizedDescription, privacy: .public)")
            if snapshot == nil { state = .failed(Self.message(for: error)) }
        }
    }

    // MARK: - History

    private func loadHistory() {
        guard historyTask == nil else { return }
        let requested = campus
        let api = api
        if historySnapshot == nil { historyState = .loading }
        historyTask = Task { [weak self] in
            defer { self?.historyTask = nil }
            do {
                let start = AppConfig.historyDay
                let raw = try await api.points(from: start, to: start.addingTimeInterval(86_400), in: requested.boundaryRect, chunks: 4)
                let day = await Task.detached { () -> HistoryDay in
                    let tallies = ActivityAggregator.tally(raw, campus: requested)
                    return HistoryDay(campusID: requested.id, start: start, tallies: tallies, capacities: .peaks(of: tallies, campus: requested))
                }.value
                guard let self, requested.id == self.campus.id else { return }
                self.history = day
                self.updateHistorySnapshot(from: day)
            } catch {
                Self.log.error("History load failed: \(error.localizedDescription, privacy: .public)")
                guard let self, requested.id == self.campus.id, self.historySnapshot == nil else { return }
                self.historyState = .failed(Self.message(for: error))
            }
        }
    }

    private func updateHistorySnapshot(from day: HistoryDay) {
        let next = day.snapshot(for: campus)
        historySnapshot = next
        historyState = next.isEmpty ? .empty : .loaded
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline. Check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach the Campus Pulse server right now."
            case .timedOut: return "The server took too long to respond."
            default: break
            }
        }
        return "Couldn't load activity. \(error.localizedDescription)"
    }
}
