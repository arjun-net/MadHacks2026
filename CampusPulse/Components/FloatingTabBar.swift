import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case map, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map.fill"
        case .activity: "chart.bar.xaxis"
        case .settings: "gearshape.fill"
        }
    }
}

/// Floating glass tab bar with a sliding selection pill.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 20)
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Theme.Colors.accent.opacity(0.55), Theme.Colors.accentSecondary.opacity(0.4)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                                .shadow(color: Theme.Colors.accent.opacity(0.45), radius: 10)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
        .glassCapsule()
        .frame(maxWidth: 320)
        .padding(.horizontal, 40)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct FloatingTabBarPreview: View {
    @State var tab: AppTab = .map
    var body: some View {
        ZStack(alignment: .bottom) {
            ScreenBackground()
            FloatingTabBar(selection: $tab)
        }
    }
}

#Preview {
    FloatingTabBarPreview().preferredColorScheme(.dark)
}
