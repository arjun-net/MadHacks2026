import Foundation
import Observation
import os

/// Activity for the selected campus, from the backend.
/// - `snapshot`: live, from the last few 2-minute slots (the map).
/// - `historySnapshot`: the Activity tab's reading, the same as the map's.
/// - `history`: the last 24 hours of readings, for usual busy times and how big each place gets
///   (the area detail screens). Fetched again every 10 minutes.
/// - Every 15 seconds the server's people-per-building counts (`/buildings/counts`) are pulled.
///   For the campus's tracked buildings they set the current number and heat on the map, and the
///   current reading on the Activity tab.
@Observable
@MainActor
final class CampusStore {
    let campuses: [Campus]
    private(set) var campus: Campus

    /// Live activity for the map.
    private(set) var snapshot: CampusSnapshot?
    private(set) var state: LoadState = .idle

    /// The Activity tab's reading (the live one) and the last 24 hours, for trends.
    private(set) var historySnapshot: CampusSnapshot?
    private(set) var historyState: LoadState = .idle
    private(set) var history: HistoryDay?
    @ObservationIgnored private var historyLoadedAt: Date?

    private(set) var isRefreshing = false
    /// Previews run on bundled sample data instead of the network.
    let isPreview: Bool

    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored private let api = HeatmapAPI()
    @ObservationIgnored private let countsAPI = BuildingCountsAPI()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    /// The last live window fetched, kept so new building counts can be applied without refetching.
    @ObservationIgnored private var live: LiveWindow?
    /// The latest building counts for this campus, by area ID.
    @ObservationIgnored private var buildingCounts: (counts: [String: Int], total: Int, fetchedAt: Date)?
    /// Bumped per rebuild, so a slower, older rebuild can't overwrite a newer one.
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var isInForeground = true
    /// Called after each live refresh (used for busy/quiet alerts).
    @ObservationIgnored var onLiveUpdate: ((CampusSnapshot) -> Void)?
    private static let log = Logger(subsystem: "CampusPulse", category: "CampusStore")

    init(campuses: [Campus], preferences: AppPreferences, initialSnapshot: CampusSnapshot? = nil) {
        self.campuses = campuses
        self.preferences = preferences
        // A campus saved before it was marked "Coming soon" falls back to one with data.
        // (Previews may show an unavailable campus, to exercise its empty state.)
        self.campus = campuses.first { $0.id == preferences.selectedCampusID && ($0.isAvailable || initialSnapshot != nil) }
            ?? campuses.first(where: \.isAvailable) ?? campuses[0]
        self.isPreview = initialSnapshot != nil
        if let initialSnapshot, initialSnapshot.campusID == campus.id {
            snapshot = initialSnapshot
            historySnapshot = initialSnapshot
            state = initialSnapshot.isEmpty ? .empty : .loaded
            historyState = state
        }
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
        if AppConfig.usesBuildingCounts, countsTask == nil, isInForeground {
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
        if !AppConfig.simulatesActivityData, history?.campusID != campus.id || historyIsStale {
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

    /// Drops everything loaded and starts over (after the server or stored day changes).
    func reload() {
        snapshot = nil
        state = .loading
        historySnapshot = nil
        historyState = .loading
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

    /// One fetched live window: real readings from the server and simulated ones, by slot.
    private struct LiveWindow {
        let campus: Campus
        let windowStart: Date
        let real: [Date: [Reading]]
        let simulated: [Date: [Reading]]
        let capacities: Capacities
    }

    private func refreshLive() async {
        let requested = campus
        if snapshot == nil { state = .loading }
        let now = Date.now
        let currentSlot = ActivityAggregator.slotStart(now)
        let windowStart = currentSlot.addingTimeInterval(-Double(ActivityAggregator.historyLength) * ActivityAggregator.slot)
        do {
            let real: [Date: [Reading]]
            do {
                real = try await api.points(from: windowStart, to: currentSlot.addingTimeInterval(ActivityAggregator.slot), in: requested.boundaryRect)
            } catch where AppConfig.simulatesLiveData {
                // With simulated data on, the map still works when the server is unreachable.
                Self.log.error("Live heatmap failed, showing simulated data only: \(error.localizedDescription, privacy: .public)")
                real = [:]
            }
            guard requested.id == campus.id else { return }
            // Simulated crowds have their own fixed building sizes, so levels don't shift when history loads.
            let capacities: Capacities = AppConfig.simulatesLiveData
                ? .fallback(for: requested, perPopularity: AppConfig.simulatedPeakHeadcount)
                : history?.capacities ?? .fallback(for: requested)
            var simulated: [Date: [Reading]] = [:]
            if AppConfig.simulatesLiveData {
                let slots = (0...ActivityAggregator.historyLength).map { windowStart.addingTimeInterval(Double($0) * ActivityAggregator.slot) }
                simulated = await Task.detached { SimulatedLiveData.points(for: requested, slots: slots, capacities: capacities) }.value
            }
            guard requested.id == campus.id else { return }
            live = LiveWindow(campus: requested, windowStart: windowStart, real: real, simulated: simulated, capacities: capacities)
            await rebuildLive(notify: true)
        } catch {
            Self.log.error("Live heatmap failed: \(error.localizedDescription, privacy: .public)")
            if snapshot == nil { state = .failed(Self.message(for: error)) }
            if historySnapshot == nil { historyState = state }
        }
    }

    // MARK: - Building counts

    private func refreshBuildingCounts() async {
        let requested = campus
        do {
            let counts = try await countsAPI.counts()
            guard requested.id == campus.id else { return }
            let mapped = ActivityAggregator.areaCounts(fromBuildingCounts: counts.byBuilding, campus: requested)
            buildingCounts = (mapped, counts.total, .now)
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

    /// The counts endpoint's total (rows matched to any of the 87 buildings in the last 2
    /// minutes), or nil when the counts are stale.
    private var freshCampusTotal: Int? {
        guard let buildingCounts, Date.now.timeIntervalSince(buildingCounts.fetchedAt) <= AppConfig.buildingCountsFreshness else { return nil }
        return buildingCounts.total
    }

    /// Builds the live snapshot from the last fetched window, with the latest building counts
    /// as the current numbers for their buildings, then refreshes the Activity tab's reading.
    private func rebuildLive(notify: Bool) async {
        guard let live, live.campus.id == campus.id else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let now = Date.now
        let counts = freshBuildingCounts ?? [:]
        let tallies = await Task.detached { () -> [Date: SlotTally] in
            var raw = ActivityAggregator.applying(
                buildingCounts: counts, to: live.real, at: ActivityAggregator.slotStart(now), campus: live.campus
            )
            raw.merge(live.simulated) { real, fake in real + fake }
            return ActivityAggregator.tally(raw, campus: live.campus)
        }.value
        guard generation == rebuildGeneration, live.campus.id == campus.id else { return }
        // Live means a slot with readings in the last few minutes.
        let frame = tallies.keys.filter { $0 >= now.addingTimeInterval(-AppConfig.liveFreshness) }.max()
        // "On campus" counts every row in the newest 2-minute slot: other buildings and rows with
        // no building included. (`/buildings/counts`' total leaves out rows with no building, so
        // it's only the fallback before the slot's readings arrive.)
        let latestSlot = live.real.keys.filter { $0 >= now.addingTimeInterval(-AppConfig.liveFreshness) }.max()
        let campusTotal = latestSlot.map { (live.real[$0]?.count ?? 0) + (live.simulated[$0]?.count ?? 0) } ?? freshCampusTotal
        let next = ActivityAggregator.snapshot(
            campus: live.campus,
            tallies: tallies,
            frame: frame,
            capacities: live.capacities,
            // Stamped with the build time so every update redraws the map.
            generatedAt: now,
            campusTotal: campusTotal
        )
        snapshot = next
        state = next.isEmpty ? .empty : .loaded
        historySnapshot = next
        historyState = state
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
