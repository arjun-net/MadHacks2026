import SwiftUI

/// Expandable bottom sheet floating over the map: campus-wide summary when collapsed,
/// top-5 busiest areas when expanded. Drag or tap to toggle.
struct ActivityPanel: View {
    let snapshot: CampusSnapshot?
    let loadState: LoadState
    @Binding var isExpanded: Bool
    var onSelectArea: (String) -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 38, height: 5)
                .padding(.top, 9)
                .padding(.bottom, 12)

            Group {
                if let snapshot, !snapshot.isEmpty {
                    summary(snapshot)
                } else if loadState == .empty {
                    emptySummary
                } else {
                    loadingSummary
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            if isExpanded, let snapshot, !snapshot.isEmpty {
                expandedContent(snapshot)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 24)),
                        removal: .opacity.combined(with: .offset(y: 12))
                    ))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .glass(cornerRadius: Theme.Radius.xl)
        .offset(y: resistedOffset)
        .gesture(dragGesture)
        .animation(Theme.Motion.smooth, value: isExpanded)
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
    }

    // MARK: Summary (always visible)

    private func summary(_ snapshot: CampusSnapshot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                ActivityGauge(intensity: snapshot.overallIntensity, lineWidth: 6)
                Image(systemName: snapshot.level.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(snapshot.level.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Campus is")
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(snapshot.level.title.lowercased())
                        .foregroundStyle(snapshot.level.color)
                        .contentTransition(.interpolate)
                }
                .font(.system(size: 19, weight: .bold))

                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("≈ \(Formatting.number(snapshot.participantCount)) students sharing")
                        .contentTransition(.numericText(value: Double(snapshot.participantCount)))
                }
                .typeStyle(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)

                if let top = snapshot.busiest(1).first {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(top.level.color)
                        Text("Busiest: \(top.area.shortName)")
                            .lineLimit(1)
                    }
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Collapse activity panel" : "Expand to see busiest areas")
        .accessibilityAddTraits(.isButton)
    }

    private var loadingSummary: some View {
        HStack(spacing: 14) {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 6)
                .frame(width: 50, height: 50)
                .padding(3)
                .shimmering()
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 150, height: 16)
                SkeletonBlock(width: 190, height: 10)
                SkeletonBlock(width: 110, height: 10)
            }
            Spacer()
        }
        .accessibilityLabel("Loading campus activity")
    }

    private var emptySummary: some View {
        HStack(spacing: 14) {
            AreaIconTile(symbol: "eye.slash.fill", color: Theme.Colors.accent, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for more students")
                    .typeStyle(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Activity appears once enough people share.")
                    .typeStyle(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Expanded

    private func expandedContent(_ snapshot: CampusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.top, 16)

            HStack {
                Text("Busiest right now").sectionLabelStyle()
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: snapshot.trend.symbol)
                    Text(snapshot.trend.title)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
            }

            VStack(spacing: 14) {
                ForEach(Array(snapshot.busiest(5).enumerated()), id: \.element.id) { index, activity in
                    Button {
                        onSelectArea(activity.id)
                    } label: {
                        AreaActivityRow(activity: activity, rank: index + 1)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.Colors.live.opacity(0.8))
                Text("Anonymous & aggregated · spots under \(snapshot.privacyThreshold) hidden")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                Text(Formatting.time(snapshot.generatedAt))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Colors.textTertiary)
            .padding(.top, 2)
        }
    }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                if projected < -50, !isExpanded { isExpanded = true }
                else if projected > 50, isExpanded { isExpanded = false }
            }
    }

    /// Rubber-band: follow the finger loosely in the direction that makes sense.
    private var resistedOffset: CGFloat {
        let raw = dragOffset
        if isExpanded {
            return raw > 0 ? raw * 0.35 : raw * 0.08
        } else {
            return raw < 0 ? raw * 0.12 : raw * 0.05
        }
    }

    private func toggle() {
        guard snapshot.map({ !$0.isEmpty }) == true else { return }
        isExpanded.toggle()
    }
}

/// Floating detail card shown when a building label is tapped.
struct AreaFocusCard: View {
    let activity: AreaActivity
    var onClose: () -> Void
    var onOpenDetails: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AreaIconTile(symbol: activity.area.symbol, color: activity.level.color, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.area.name)
                        .typeStyle(.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Text("\(activity.area.category.title) · \(activity.countLabel)")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Close")
            }

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now").sectionLabelStyle()
                    ActivityLevelBadge(level: activity.level, showsIcon: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trend").sectionLabelStyle()
                    Label(activity.trend.shortTitle, systemImage: activity.trend.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Last 24 min").sectionLabelStyle()
                    Sparkline(values: activity.history, color: activity.level.color, lineWidth: 2)
                        .frame(width: 96, height: 30)
                }
            }

            ActivityBar(intensity: activity.intensity, height: 6)

            if let onOpenDetails {
                Button(action: onOpenDetails) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Busy times & history")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint("Opens \(activity.area.name) on the Activity tab")
            }
        }
        .padding(16)
        .glass(cornerRadius: Theme.Radius.lg, tint: activity.level.color)
    }
}

private struct ActivityPanelPreview: View {
    @State var expanded = true
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            AreaFocusCard(activity: PreviewData.snapshot.busiest(1)[0], onClose: {})
            ActivityPanel(snapshot: PreviewData.snapshot, loadState: .loaded, isExpanded: $expanded, onSelectArea: { _ in })
        }
        .padding()
        .background(ScreenBackground())
    }
}

#Preview("Panel") {
    ActivityPanelPreview().preferredColorScheme(.dark)
}
