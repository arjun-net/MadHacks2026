import SwiftUI

struct PrivacyInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.cpLargeTitle)
                        .foregroundStyle(Theme.Colors.positive)
                    Text("Built for crowds, not individuals")
                        .typeStyle(.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Campus Pulse answers one question: how busy is each part of campus right now? It's designed so it can't answer \"where is a specific student?\"")
                        .typeStyle(.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PrivacyContent.principles) { item in
                        PrivacyPoint(symbol: item.symbol, title: item.title, detail: item.detail)
                    }
                }
                .padding(18)
                .card(cornerRadius: Theme.Radius.sm)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "What we store")
                    bullet("Your location and a timestamp for each check-in, sent every 2 minutes while sharing is on, with a random ID for this install.")
                    bullet("Your campus selection and app preferences, on this device.")
                    SectionHeader(title: "What we never store").padding(.top, 8)
                    bullet("Your name, email, contacts, or account. Check-ins carry only the random install ID.")
                }
                .padding(18)
                .card(cornerRadius: Theme.Radius.sm)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 12)
            .padding(.bottom, Theme.tabBarClearance)
        }
        .background(ScreenBackground(ruled: false))
        .paperNavigationBar("Privacy")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Rectangle()
                .fill(Theme.Colors.accent)
                .frame(width: 5, height: 5)
                .offset(y: -2)
            Text(text)
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AboutView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    AppGlyph()
                        .frame(width: 96, height: 96)
                    Text("Campus Pulse")
                        .typeStyle(.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Version \(version)")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("See where campus is buzzing, and where it's calm, in real time. Powered entirely by students who choose to share, anonymously.")
                        .typeStyle(.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Reading the map")
                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                        HStack(spacing: 12) {
                            AreaIconTile(symbol: level.symbol, color: level.textColor, size: 32)
                            Text(level.title)
                                .typeStyle(.headline)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                            Text(level.subtitle)
                                .typeStyle(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .padding(18)
                .card(cornerRadius: Theme.Radius.sm)

                VStack(spacing: 4) {
                    Text("Made with ♥ at MadHacks 2026")
                    Text("Map data © OpenStreetMap contributors")
                }
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.tabBarClearance)
        }
        .background(ScreenBackground(ruled: false))
        .paperNavigationBar("About")
    }
}

/// The app icon, with iOS's rounded-corner shape.
struct AppGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            Image("AppMark")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
                .shadow(color: Theme.Colors.softShadow, radius: 10, x: 0, y: 4)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview("Privacy") {
    NavigationStack { PrivacyInfoView() }
}

#Preview("About") {
    NavigationStack { AboutView(version: "1.0 (1)") }
}
