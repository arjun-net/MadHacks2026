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

/// Tab bar: flush segments with quiet dividers, floating on a soft shadow.
/// The selected segment is filled ink (Day) or press red (Night) and slides between tabs.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var namespace

    private var selectedFill: Color { Theme.Colors.selectionFill }
    private var selectedText: Color { Theme.Colors.onSelection }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Colors.border)
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
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
        .clipShape(Rectangle())
        .paper(cornerRadius: 0, elevated: true)
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
