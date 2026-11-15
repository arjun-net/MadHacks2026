import Foundation
import Observation
import os

/// Activity for the selected campus, from the backend.
/// Only real readings: nothing is simulated or replayed.
/// - `snapshot`: live, from the last few 2-minute slots (the map and the Activity tab).
/// - `history`: the last 24 hours, for usual busy times and how big each place gets
///   (the area detail screens). Fetched again every 10 minutes.
/// - Every 15 seconds the server's people-per-building counts (`/buildings/counts`) are pulled.
///   For the campus's tracked buildings they set the current number and heat.
@Observable
@MainActor
final class CampusStore {
    let campuses: [Campus]
    private(set) var campus: Campus

    /// Live activity for the map and the Activity tab.
    private(set) var snapshot: CampusSnapshot?
    private(set) var state: LoadState = .idle

    /// The last 24 hours, for trends.
    private(set) var history: HistoryDay?
    @ObservationIgnored private var historyLoadedAt: Date?

    private(set) var isRefreshing = false
    /// Previews never touch the network; they show the loading state.
    let isPreview: Bool

    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored private let api = HeatmapAPI()
    @ObservationIgnored private let countsAPI = BuildingCountsAPI()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    /// The last live window fetched, kept so new building counts can be applied without refetching.
    @ObservationIgnored private var live: LiveWindow?
    /// The latest building counts for this campus, by area ID.
    @ObservationIgnored private var buildingCounts: (counts: [String: Int], fetchedAt: Date)?
    /// Bumped per rebuild, so a slower, older rebuild can't overwrite a newer one.
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var isInForeground = true
    /// Called after each live refresh (used for busy/quiet alerts).
    @ObservationIgnored var onLiveUpdate: ((CampusSnapshot) -> Void)?
    private static let log = Logger(subsystem: "CampusPulse", category: "CampusStore")

    init(campuses: [Campus], preferences: AppPreferences, isPreview: Bool = false) {
        self.campuses = campuses
        self.preferences = preferences
        // A campus saved before it was marked "Coming soon" falls back to one with data.
        // (Previews may show an unavailable campus, to exercise its empty state.)
        self.campus = campuses.first { $0.id == preferences.selectedCampusID && ($0.isAvailable || isPreview) }
            ?? campuses.first(where: \.isAvailable) ?? campuses[0]
        self.isPreview = isPreview
    }

    func start() {
        guard !isPreview else { return }
        if loopTask == nil {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    let interval = self?.isInForeground == false ? AppConfig.updateInterval : AppConfig.liveRefreshInterval
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
        // Only while the app is open: in the background nobody is looking at the counts.
        if countsTask == nil, isInForeground {
            countsTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshBuildingCounts()
                    try? await Task.sleep(for: .seconds(AppConfig.buildingCountsInterval))
                }
            }
        }
    }

    private func stopLoops() {
        loopTask?.cancel()
        loopTask = nil
        countsTask?.cancel()
        countsTask = nil
    }

    /// Refreshes right away on returning to the app. In the background the loop stops,
    /// unless alerts are on, in which case it checks every 2 minutes (the app only keeps
    /// running in the background while location sharing is on).
    func setForeground(_ foreground: Bool) {
        guard !isPreview, foreground != isInForeground else { return }
        isInForeground = foreground
        stopLoops()
        isRefreshing = false
        if foreground || preferences.busyAreaAlerts || preferences.quietSpotAlerts {
            start()
        }
    }

    func refresh() async {
        guard !isPreview, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let historyIsStale = historyLoadedAt.map { Date.now.timeIntervalSince($0) > AppConfig.historyRefreshInterval } ?? true
        if history?.campusID != campus.id || historyIsStale {
            loadHistory()
        }
        await refreshLive()
    }

    func select(_ newCampus: Campus) {
        guard newCampus.id != campus.id, newCampus.isAvailable else { return }
        campus = newCampus
        preferences.selectedCampusID = newCampus.id
        reload()
    }

    /// Drops everything loaded and starts over (after the server changes).
    func reload() {
        snapshot = nil
        state = .loading
        history = nil
        historyLoadedAt = nil
        historyTask?.cancel()
        historyTask = nil
        live = nil
        buildingCounts = nil
        isRefreshing = false
        stopLoops()
        start()
    }

    // MARK: - Live

    /// One fetched live window: the server's readings, by slot.
    private struct LiveWindow {
        let campus: Campus
        let readings: [Date: [Reading]]
        let capacities: Capacities
    }

    private func refreshLive() async {
        let requested = campus
        if snapshot == nil { state = .loading }
        let now = Date.now
        let currentSlot = ActivityAggregator.slotStart(now)
        let windowStart = currentSlot.addingTimeInterval(-Double(ActivityAggregator.historyLength) * ActivityAggregator.slot)
        do {
            let readings = try await api.points(from: windowStart, to: currentSlot.addingTimeInterval(ActivityAggregator.slot), in: requested.boundaryRect)
            guard requested.id == campus.id else { return }
            live = LiveWindow(campus: requested, readings: readings, capacities: history?.capacities ?? .fallback(for: requested))
            await rebuildLive(notify: true)
        } catch {
            Self.log.error("Live heatmap failed: \(error.localizedDescription, privacy: .public)")
            if snapshot == nil { state = .failed(Self.message(for: error)) }
        }
    }

    // MARK: - Building counts

    private func refreshBuildingCounts() async {
        let requested = campus
        do {
            let counts = try await countsAPI.counts()
            guard requested.id == campus.id else { return }
            let mapped = ActivityAggregator.areaCounts(fromBuildingCounts: counts.byBuilding, campus: requested)
            buildingCounts = (mapped, .now)
            await rebuildLive(notify: false)
        } catch {
            // Keep showing the last counts until they go stale.
            Self.log.error("Building counts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Building counts recent enough to show, or nil.
    private var freshBuildingCounts: [String: Int]? {
        guard let buildingCounts, Date.now.timeIntervalSince(buildingCounts.fetchedAt) <= AppConfig.buildingCountsFreshness,
              !buildingCounts.counts.isEmpty else { return nil }
        return buildingCounts.counts
    }

    /// Builds the live snapshot from the last fetched window, with the latest building counts
    /// as the current numbers for their buildings.
    private func rebuildLive(notify: Bool) async {
        guard let live, live.campus.id == campus.id else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let now = Date.now
        let counts = freshBuildingCounts ?? [:]
        let tallies = await Task.detached { () -> [Date: SlotTally] in
            let raw = ActivityAggregator.applying(
                buildingCounts: counts, to: live.readings, at: ActivityAggregator.slotStart(now), campus: live.campus
            )
            return ActivityAggregator.tally(raw, campus: live.campus)
        }.value
        guard generation == rebuildGeneration, live.campus.id == campus.id else { return }
        // Live means a slot with readings in the last few minutes.
        let frame = tallies.keys.filter { $0 >= now.addingTimeInterval(-AppConfig.liveFreshness) }.max()
        let next = ActivityAggregator.snapshot(
            campus: live.campus,
            tallies: tallies,
            frame: frame,
            capacities: live.capacities,
            // Stamped with the build time so every update redraws the map.
            generatedAt: now
        )
        snapshot = next
        state = next.isEmpty ? .empty : .loaded
        if notify { onLiveUpdate?(next) }
    }

    // MARK: - History

    private func loadHistory() {
        guard historyTask == nil else { return }
        let requested = campus
        let api = api
        historyTask = Task { [weak self] in
            defer { self?.historyTask = nil }
            do {
                let window = HistoryDay.window(endingAt: .now)
                let raw = try await api.points(from: window.start, to: window.end, in: requested.boundaryRect, chunks: 4)
                let day = await Task.detached { () -> HistoryDay in
                    let tallies = ActivityAggregator.tally(raw, campus: requested)
                    return HistoryDay(campusID: requested.id, start: window.start, tallies: tallies, capacities: .peaks(of: tallies, campus: requested))
                }.value
                guard let self, requested.id == self.campus.id else { return }
                self.history = day
                self.historyLoadedAt = .now
            } catch {
                // Trends stay as they were (or hidden) until the next try.
                Self.log.error("History load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
