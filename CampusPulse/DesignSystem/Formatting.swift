import Foundation

enum Formatting {
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "just now", "42s ago", "3m ago", "1h ago".
    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        default: return "\(seconds / 3600)h ago"
        }
    }

    /// Newspaper dateline: "SAT · NOV 14".
    /// A moment in the stored dataset, whose timestamps are campus wall-clock times: "Jan 1, 2:30 PM".
    static func dataDay(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.timeZone = .gmt
        return date.formatted(style)
    }

    static func dateline(_ date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(weekday) · \(day)".uppercased()
    }

    /// "3 PM", "12 AM", or "3a" when `compact`.
    static func hour(_ hour: Double, compact: Bool = false) -> String {
        let h = ((Int(hour) % 24) + 24) % 24
        let display = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? (compact ? "a" : " AM") : (compact ? "p" : " PM")
        return "\(display)\(suffix)"
    }

    /// "1:42" countdown.
    static func countdown(until date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension Date {
    /// Hour of day as a fraction, e.g. 14.5 for 2:30 PM.
    var fractionalHour: Double {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: self)
        return Double(components.hour ?? 0)
            + Double(components.minute ?? 0) / 60
            + Double(components.second ?? 0) / 3600
    }
}
