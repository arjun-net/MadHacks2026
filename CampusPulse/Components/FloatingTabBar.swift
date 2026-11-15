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

/// Newspaper tab bar: flush square segments with ink dividers and a hard offset shadow.
/// The selected segment is filled ink (Day) or press red (Night) and slides between tabs.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme

    private var selectedFill: Color { colorScheme == .dark ? Theme.Colors.accentFill : Theme.Colors.ink }
    private var selectedText: Color { colorScheme == .dark ? Theme.Colors.onAccent : Theme.Colors.paper }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Colors.ink)
                        .frame(width: Theme.Stroke.hairline)
                }
                let isSelected = tab == selection
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(height: 18)
                        Text(tab.title)
                            .typeStyle(.tab)
                    }
                    .foregroundStyle(isSelected ? selectedText : Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if isSelected {
                            Rectangle()
                                .fill(selectedFill)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
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
    FloatingTabBarPreview()
}
