import SwiftUI

/// Switch: a squared track with a quiet border and a paper knob; filled red when on.
struct PaperToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            PaperSwitch(isOn: configuration.isOn)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.Motion.snappy) { configuration.isOn.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
        .sensoryFeedback(.selection, trigger: configuration.isOn)
    }
}

private struct PaperSwitch: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
        ZStack(alignment: isOn ? .trailing : .leading) {
            shape
                .fill(isOn ? Theme.Colors.accentFill : Theme.Colors.surfaceStrong)
                .overlay(shape.strokeBorder(Theme.Colors.borderStrong, lineWidth: Theme.Stroke.hairline))
            RoundedRectangle(cornerRadius: Theme.Radius.sm - 1, style: .continuous)
                .fill(Theme.Colors.paper)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm - 1, style: .continuous).strokeBorder(Theme.Colors.borderStrong, lineWidth: Theme.Stroke.hairline))
                .frame(width: 24, height: 24)
                .padding(3)
        }
        .frame(width: 52, height: 30)
        .accessibilityHidden(true)
    }
}

extension ToggleStyle where Self == PaperToggleStyle {
    static var paper: PaperToggleStyle { PaperToggleStyle() }
}

/// Segmented control drawn as joined chips; the selected one is filled (ink by day, red by night).
struct PaperSegmentedPicker<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var height: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let selected = option == selection
                Button {
                    withAnimation(Theme.Motion.snappy) { selection = option }
                } label: {
                    Text(label(option))
                        .typeStyle(.button)
                        .foregroundStyle(selected ? Theme.Colors.onSelection : Theme.Colors.ink)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(selected ? Theme.Colors.selectionFill : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
                if index < options.count - 1 {
                    Rectangle().fill(Theme.Colors.borderStrong).frame(width: Theme.Stroke.hairline)
                }
            }
        }
        .background(Theme.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Colors.borderStrong, lineWidth: Theme.Stroke.hairline))
        .frame(minHeight: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A grouped settings section: small caps header, a card of rows, and an optional footnote.
/// Header and footnote line up with the row text inside the card. Put a `RowRule()` between rows.
/// `boxed: false` leaves the content uncarded (for a control that's already a box, like a picker).
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    var boxed = true
    @ViewBuilder var content: Content

    /// Matches the rows' horizontal padding, so header, text and footnote share one left edge.
    static var textInset: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.cpMicro)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, Self.textInset)
                .accessibilityAddTraits(.isHeader)

            if boxed {
                VStack(spacing: 0) {
                    content
                }
                .card(cornerRadius: Theme.Radius.sm)
            } else {
                content
            }

            if let footer {
                Text(footer)
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.textInset)
                    .padding(.top, 2)
            }
        }
    }
}

/// Hairline between rows in a card, inset to line up with row titles.
struct RowRule: View {
    var inset: CGFloat = 55

    var body: some View {
        Rectangle().fill(Theme.Colors.rule).frame(height: 1).padding(.leading, inset)
    }
}

/// Padding and minimum height shared by every settings row.
extension View {
    func settingsRow() -> some View {
        padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}
