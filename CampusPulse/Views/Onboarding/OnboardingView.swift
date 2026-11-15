import SwiftUI

/// First launch: what the app does and what it collects, before iOS asks for location access.
struct OnboardingView: View {
    var onShare: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    masthead

                    VStack(alignment: .leading, spacing: 18) {
                        point(symbol: "map.fill", title: "A live crowd map",
                              detail: "See how busy libraries, unions and dining halls are before you walk over.")
                        point(symbol: "chart.bar.xaxis", title: "Busy times",
                              detail: "Check when a place usually fills up and when it quiets down.")
                        point(symbol: "star.fill", title: "Your places",
                              detail: "Save the spots you use and get a heads-up when they get busy or quiet.")
                    }

                    sharingCard
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            buttons
        }
        .background(ScreenBackground())
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Campus Pulse")
                .typeStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Theme.Colors.sectionRule)
                .frame(height: Theme.Stroke.sectionRule)
            Text("Know how busy campus is, before you go.")
                .typeStyle(.title3)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func point(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .typeStyle(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Plain statement of what's sent, right before the system prompt.
    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.Colors.positive)
                Text("What sharing means").sectionLabelStyle()
            }
            Text("The map is built from students who share. While sharing is on, your phone sends its location every 2 minutes with no ID, name or account.")
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Only crowds are shown: spots with fewer than \(AppConfig.privacyThreshold) people never appear. You can pause sharing, keep it to campus, or turn it off anytime in Settings.")
                .typeStyle(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(cornerRadius: Theme.Radius.sm)
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button(action: onShare) {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                    Text("Share my location")
                }
                .typeStyle(.button)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("iOS will ask for location access next")

            Button(action: onSkip) {
                Text("Just browse for now")
                    .typeStyle(.button)
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.Colors.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.rule).frame(height: 1)
        }
    }
}

#Preview {
    OnboardingView(onShare: {}, onSkip: {})
}
