import SwiftUI

/// Horizontally scrolling category chips (Study, Dining, …).
struct FilterBar: View {
    let filters: [AreaFilter]
    @Binding var selection: AreaFilter
    let count: (AreaFilter) -> Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    let selected = filter == selection
                    Button {
                        withAnimation(Theme.Motion.snappy) { selection = filter }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.symbol)
                                .imageScale(.small)
                            Text(filter.title)
                            if filter != .all {
                                Text("\(count(filter))")
                                    .monospacedDigit()
                                    .opacity(0.7)
                            }
                        }
                        .typeStyle(.button)
                        .foregroundStyle(selected ? Theme.Colors.onSelection : Theme.Colors.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(selected ? Theme.Colors.selectionFill : Theme.Colors.paper)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.borderStrong, lineWidth: Theme.Stroke.hairline)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.title), \(count(filter)) places")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.Spacing.md)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
