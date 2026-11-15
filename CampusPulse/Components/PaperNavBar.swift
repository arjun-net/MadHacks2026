import SwiftUI
import UIKit

/// The app's own navigation bar, in place of the system one (glass bubbles in the system font):
/// a squared paper back button, a serif title, and paper action buttons on the right.
/// Apply with `.paperNavigationBar(...)`; it hides the system bar.
struct PaperNavBar<Trailing: View>: View {
    var title: String?
    var showsBack = true
    var showsRule = true
    @ViewBuilder var trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .typeStyle(.title3)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 64)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                if showsBack {
                    PaperIconButton(symbol: "chevron.left", label: "Back") { dismiss() }
                }
                Spacer(minLength: 0)
                trailing
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            if showsRule {
                Rectangle().fill(Theme.Colors.rule).frame(height: Theme.Stroke.hairline)
            }
        }
        .background(Theme.Colors.background.opacity(showsRule ? 1 : 0))
    }
}

/// A square paper button holding one symbol, sized like the map controls.
struct PaperIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.Colors.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PaperIconLabel(symbol: symbol, tint: tint)
                .paper(cornerRadius: Theme.Radius.sm)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Symbol sized and framed for a paper icon button.
struct PaperIconLabel: View {
    let symbol: String
    var tint: Color = Theme.Colors.ink

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
    }
}

/// A paper text button in the tracked caps button face, e.g. "Done".
struct PaperTextButton: View {
    let title: String
    var tint: Color = Theme.Colors.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .typeStyle(.button)
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
                .paper(cornerRadius: Theme.Radius.sm)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

extension View {
    /// Replaces the system navigation bar with `PaperNavBar`.
    /// `showsRule: false` gives a see-through bar for screens with their own masthead.
    func paperNavigationBar<Trailing: View>(
        _ title: String? = nil,
        showsBack: Bool = true,
        showsRule: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            PaperNavBar(title: title, showsBack: showsBack, showsRule: showsRule, trailing: trailing)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// With the system bar hidden, UIKit turns off the edge swipe back; turn it back on.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
