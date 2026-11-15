import SwiftUI

struct PrivacyPoint: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = Theme.Colors.positive

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.rule, lineWidth: Theme.Stroke.hairline))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .typeStyle(.body)
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
        Item(symbol: "person.crop.circle.badge.questionmark", title: "No name attached",
             detail: "Check-ins carry a random ID for this install, never your name, email or account."),
        Item(symbol: "eye.slash.fill", title: "Small groups stay hidden",
             detail: "Any spot with fewer than \(AppConfig.privacyThreshold) students is removed from the map entirely, and small counts are never shown."),
        Item(symbol: "clock.arrow.circlepath", title: "No location history",
             detail: "The app never displays where anyone has been. Only the current, combined picture is shown."),
        Item(symbol: "hand.raised.fill", title: "Off anytime",
             detail: "Sharing starts once you allow location access, and stops the moment you switch it off."),
    ]
}
