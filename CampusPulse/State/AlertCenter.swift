import Foundation
import os
import UserNotifications

/// Local notifications behind the Settings switches:
/// - Busy area alerts: a saved place becomes busy.
/// - Quiet study spots: a library or academic building, or a saved place, quiets down.
/// - Weekly recap: Sunday evening, the busiest and quietest places over the last 24 hours.
///
/// Alerts are worked out on the device from each live refresh; nothing is sent anywhere.
@MainActor
final class AlertCenter: NSObject {
    private let preferences: AppPreferences
    private let center = UNUserNotificationCenter.current()

    /// Last seen level per area; the first refresh only records levels, so opening
    /// the app never fires a burst of alerts.
    private var lastLevels: [String: ActivityLevel] = [:]
    private var lastCampusID: String?
    /// When each area last alerted, per kind, to keep one place from repeating itself.
    private var lastAlerted: [String: Date] = [:]
    private static let cooldown: TimeInterval = 60 * 60
    private static let studyCategories: Set<AreaCategory> = [.library, .academic]
    /// Campus and history window the scheduled recap was written for.
    private var recapSource: String?
    private static let recapID = "weekly-recap"
    private static let log = Logger(subsystem: "CampusPulse", category: "Alerts")

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
    }

    var anyLiveAlertsOn: Bool { preferences.busyAreaAlerts || preferences.quietSpotAlerts }

    // MARK: - Permission

    /// Asks for notification permission when a switch is turned on.
    /// Returns false (and the caller turns the switch back off) if the user declines.
    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    // MARK: - Live alerts

    func evaluate(_ snapshot: CampusSnapshot) {
        if snapshot.campusID != lastCampusID {
            lastCampusID = snapshot.campusID
            lastLevels = [:]
        }
        guard !snapshot.isEmpty else { return }
        let favorites = Set(preferences.favoriteAreaIDs)

        for activity in snapshot.areas {
            let level = activity.level
            defer { lastLevels[activity.id] = level }
            guard let previous = lastLevels[activity.id], previous != level else { continue }

            if preferences.busyAreaAlerts, favorites.contains(activity.id), previous < .busy, level >= .busy {
                post(
                    kind: "busy", area: activity,
                    title: "\(activity.area.name) is getting busy",
                    body: "It's \(level.title.lowercased()) right now. \(activity.countLabel.capitalizedFirstLetter)."
                )
            }

            let isStudySpot = Self.studyCategories.contains(activity.area.category)
            if preferences.quietSpotAlerts, isStudySpot || favorites.contains(activity.id),
               previous >= .moderate, level <= .light {
                post(
                    kind: "quiet", area: activity,
                    title: "\(activity.area.name) just quieted down",
                    body: "Now \(level.title.lowercased()), a good time to grab a seat."
                )
            }
        }
    }

    private func post(kind: String, area: AreaActivity, title: String, body: String) {
        let key = "\(kind):\(area.id)"
        if let last = lastAlerted[key], Date.now.timeIntervalSince(last) < Self.cooldown { return }
        lastAlerted[key] = .now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = kind
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { error in
            if let error { Self.log.error("Couldn't post alert: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Weekly recap

    /// Rewrites the recap when the history or campus it describes has changed.
    func refreshRecapIfNeeded(history: HistoryDay?, campus: Campus) {
        let source = "\(campus.id)|\(history?.campusID ?? "-")|\(history?.start.timeIntervalSince1970 ?? 0)|\(preferences.weeklyRecap)"
        guard source != recapSource else { return }
        recapSource = source
        updateWeeklyRecap(history: history, campus: campus)
    }

    /// Schedules (or cancels) the Sunday 6 PM recap. Its text is written now from the last 24 hours,
    /// and rewritten whenever that history or the campus changes.
    func updateWeeklyRecap(history: HistoryDay?, campus: Campus) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.recapID])
        guard preferences.weeklyRecap else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your week on \(campus.shortName)"
        content.body = Self.recapText(history: history, campus: campus)
        content.threadIdentifier = Self.recapID

        var when = DateComponents()
        when.weekday = 1 // Sunday
        when.hour = 18
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        center.add(UNNotificationRequest(identifier: Self.recapID, content: content, trigger: trigger)) { error in
            if let error { Self.log.error("Couldn't schedule recap: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func recapText(history: HistoryDay?, campus: Campus) -> String {
        guard let history, history.campusID == campus.id, !history.isEmpty else {
            return "See which places were busiest this week and when they're usually quiet."
        }
        // Each area's peak hour, relative to its own capacity.
        let peaks = campus.areas.compactMap { area -> (area: CampusArea, peak: HourlyValue)? in
            guard let peak = history.hourly(for: area.id).max(by: { $0.intensity < $1.intensity }) else { return nil }
            return (area, peak)
        }
        guard let busiest = peaks.max(by: { $0.peak.intensity < $1.peak.intensity }) else {
            return "See which places were busiest this week and when they're usually quiet."
        }
        var text = "\(busiest.area.name) was the busiest, peaking around \(Formatting.hour(busiest.peak.hour))."
        let study = peaks.filter { $0.area.category == .library && $0.area.id != busiest.area.id }
        if let calmest = study.min(by: { $0.peak.intensity < $1.peak.intensity }) {
            text += " For a quieter seat, try \(calmest.area.name)."
        }
        return text
    }
}

extension AlertCenter: UNUserNotificationCenterDelegate {
    /// Show alerts as banners even while the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
