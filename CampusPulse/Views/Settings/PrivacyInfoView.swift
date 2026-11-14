import SwiftUI

struct PrivacyInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.Gradients.live)
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
                .card(cornerRadius: Theme.Radius.lg)

                VStack(alignment: .leading, spacing: 10) {
                    Text("What we store").sectionLabelStyle()
                    bullet("Rounded grid cell and timestamp for each check-in, kept only long enough to compute the live map.")
                    bullet("Your campus selection and app preferences, on this device.")
                    Text("What we never store").sectionLabelStyle().padding(.top, 8)
                    bullet("Your exact coordinates, movement trails, or location history.")
                    bullet("Your name, contacts, or anything that links check-ins to you.")
                }
                .padding(18)
                .card(cornerRadius: Theme.Radius.lg)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 12)
            .padding(.bottom, Theme.tabBarClearance)
        }
        .background(ScreenBackground())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 5, height: 5)
                .offset(y: -2)
            Text(text)
                .font(.system(size: 14))
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
                    Text("Reading the map").sectionLabelStyle()
                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                        HStack(spacing: 12) {
                            AreaIconTile(symbol: level.symbol, color: level.color, size: 32)
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
                .card(cornerRadius: Theme.Radius.lg)

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
        .background(ScreenBackground())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// App mark: concentric heat rings on a deep gradient tile.
struct AppGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.02)], startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [HeatPalette.color(at: 1), HeatPalette.color(at: 0.65), HeatPalette.color(at: 0.3).opacity(0.6), .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.42
                    ))
                    .frame(width: size * 0.84, height: size * 0.84)
                    .blur(radius: size * 0.04)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: HeatPalette.color(at: 0.8).opacity(0.35), radius: 20)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview("Privacy") {
    NavigationStack { PrivacyInfoView() }.preferredColorScheme(.dark)
}

#Preview("About") {
    NavigationStack { AboutView(version: "1.0 (1)") }.preferredColorScheme(.dark)
}
