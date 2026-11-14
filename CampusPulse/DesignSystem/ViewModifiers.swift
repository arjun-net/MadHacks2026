import SwiftUI

/// Frosted, softly lit surface used for every floating element.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var shadow: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [(tint ?? .white).opacity(tint == nil ? 0.05 : 0.14), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay { shape.strokeBorder(Theme.Gradients.glassStroke, lineWidth: 1) }
            .shadow(color: .black.opacity(shadow ? 0.38 : 0), radius: 22, x: 0, y: 12)
    }
}

/// Opaque card used on scrolling screens (cheaper than material, reads better over gradients).
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Gradients.glassStroke, lineWidth: 1)
            }
    }
}

struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.14), .clear],
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
    func glass(cornerRadius: CGFloat = Theme.Radius.lg, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, shadow: shadow))
    }

    func glassCapsule(tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(GlassBackground(shape: Capsule(style: .continuous), tint: tint, shadow: shadow))
    }

    func card(cornerRadius: CGFloat = Theme.Radius.lg) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }

    func shimmering() -> some View {
        modifier(Shimmer())
    }

    /// Small, tracked, uppercase section label.
    func sectionLabelStyle() -> some View {
        self
            .font(.cpMicro)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.textTertiary)
    }
}

/// Deep background with soft aurora glows, shared by the non-map screens.
struct ScreenBackground: View {
    var body: some View {
        ZStack {
            Theme.Colors.background
            Circle()
                .fill(Theme.Colors.accent.opacity(0.30))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: -150, y: -320)
            Circle()
                .fill(Theme.Colors.accentSecondary.opacity(0.22))
                .frame(width: 380, height: 380)
                .blur(radius: 130)
                .offset(x: 170, y: -180)
            Circle()
                .fill(HeatPalette.color(at: 0.85).opacity(0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 140)
                .offset(x: 120, y: 420)
        }
        .ignoresSafeArea()
    }
}
