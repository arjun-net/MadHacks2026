import SwiftUI

struct PrivacyPoint: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = Theme.Colors.accent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

enum PrivacyContent {
    struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    static let principles: [Item] = [
        Item(symbol: "person.crop.circle.badge.xmark", title: "You're never a dot on the map",
             detail: "The heatmap shows combined density only. No one, including us, sees an individual student."),
        Item(symbol: "square.grid.3x3.fill", title: "Rounded before it leaves your phone",
             detail: "Your location is snapped to a ~\(Int(AppConfig.aggregationCellMeters)) m grid cell on device before it's sent."),
        Item(symbol: "eye.slash.fill", title: "Small groups stay hidden",
             detail: "Any spot with fewer than \(AppConfig.privacyThreshold) students is removed from the map entirely, and small counts are never shown."),
        Item(symbol: "clock.arrow.circlepath", title: "No location history",
             detail: "The app never displays where anyone has been. Only the current, combined picture is shown."),
        Item(symbol: "hand.raised.fill", title: "Opt-in, off anytime",
             detail: "Sharing is off until you turn it on, and pauses the moment you switch it off."),
    ]
}
