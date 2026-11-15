import SwiftUI

/// Opaque paper card with a quiet hairline. Replaces glass everywhere.
/// `elevated` marks floating chrome (masthead, tab bar): it gets a deeper soft shadow.
struct PaperBackground<S: InsettableShape>: ViewModifier {
    var shape: S
    var elevated: Bool = false
    var softShadow: Bool = true

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Theme.Colors.paper))
            .overlay(shape.strokeBorder(Theme.Colors.border, lineWidth: Theme.Stroke.hairline))
            .shadow(
                color: elevated || softShadow ? Theme.Colors.softShadow : .clear,
                radius: elevated ? 16 : 12,
                x: 0,
                y: elevated ? 6 : -4
            )
    }
}

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            // With Reduce Motion the skeleton stays still; the placeholder shape alone says "loading".
            TimelineView(.animation(paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, Theme.Colors.ink.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: -proxy.size.width * 0.6 + proxy.size.width * 1.6 * phase)
                }
            }
            .mask(content)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Paper card: paper fill, quiet hairline, small corners.
    func paper(cornerRadius: CGFloat = Theme.Radius.sm, elevated: Bool = false) -> some View {
        modifier(PaperBackground(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), elevated: elevated))
    }

    /// Legacy name; now a paper surface. `tint` is ignored.
    func glass(cornerRadius: CGFloat = Theme.Radius.lg, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(PaperBackground(
            shape: RoundedRectangle(cornerRadius: min(cornerRadius, Theme.Radius.sm), style: .continuous),
            softShadow: shadow
        ))
    }

    /// Legacy name; now a square paper chip. `tint` is ignored.
    func glassCapsule(tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(PaperBackground(shape: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous), softShadow: shadow))
    }

    /// Paper without any shadow, for cards on scrolling screens.
    func card(cornerRadius: CGFloat = Theme.Radius.lg) -> some View {
        modifier(PaperBackground(
            shape: RoundedRectangle(cornerRadius: min(cornerRadius, Theme.Radius.xl), style: .continuous),
            softShadow: false
        ))
    }

    func shimmering() -> some View {
        modifier(Shimmer())
    }

    /// Small, tracked, uppercase section label.
    func sectionLabelStyle() -> some View {
        self
            .font(.cpMicro)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.ink)
    }
}

/// Newspaper section header: 2pt rule on top, tracked caps label, optional red kicker on the right.
struct SectionHeader: View {
    let title: String
    var trailing: String?
    var trailingSymbol: String?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Colors.sectionRule)
                .frame(height: Theme.Stroke.sectionRule)
            HStack(spacing: 8) {
                Text(title).sectionLabelStyle()
                Spacer(minLength: 8)
                if let trailing {
                    HStack(spacing: 4) {
                        if let trailingSymbol {
                            Image(systemName: trailingSymbol)
                                .font(.system(size: 9.5, weight: .heavy))
                        }
                        Text(trailing)
                    }
                    .font(.cpMicro)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Flat newsprint page background. Day mode adds a faint ruled-paper texture.
struct ScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.Colors.background
            if colorScheme == .light {
                Canvas { context, size in
                    var y: CGFloat = 28
                    var path = Path()
                    while y < size.height {
                        path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                        y += 28
                    }
                    context.fill(path, with: .color(Theme.Colors.rule.opacity(0.35)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
