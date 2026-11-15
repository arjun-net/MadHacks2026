import SwiftUI

/// Expandable bottom sheet floating over the map: campus-wide summary when collapsed,
/// top-5 busiest areas when expanded. Drag or tap to toggle.
struct ActivityPanel: View {
    let snapshot: CampusSnapshot?
    let loadState: LoadState
    @Binding var isExpanded: Bool
    var favoriteAreaIDs: [String] = []
    var onSelectArea: (String) -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @State private var mode: ListMode = .busiest

    /// What the expanded list ranks.
    enum ListMode: String, CaseIterable, Hashable {
        case busiest, quietest, saved

        var title: String {
            switch self {
            case .busiest: "Busiest"
            case .quietest: "Quietest"
            case .saved: "Saved"
            }
        }
    }

    private var modes: [ListMode] {
        favoriteAreaIDs.isEmpty ? [.busiest, .quietest] : ListMode.allCases
    }

    private func rows(for snapshot: CampusSnapshot) -> [AreaActivity] {
        switch modes.contains(mode) ? mode : .busiest {
        case .busiest:
            return snapshot.busiest(Self.rowCount)
        case .quietest:
            // Places worth going to for a quiet hour, not an empty stadium or a dorm.
            let useful: Set<AreaCategory> = [.library, .union, .academic, .dining, .outdoors]
            return Array(snapshot.areasByActivity.reversed().filter { useful.contains($0.area.category) }.prefix(Self.rowCount))
        case .saved:
            let ids = Set(favoriteAreaIDs)
            return Array(snapshot.areasByActivity.filter { ids.contains($0.id) }.prefix(Self.rowCount))
        }
    }

    /// Four rows plus the picker keep the expanded panel clear of the masthead on small phones.
    private static let rowCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.Colors.rule)
                .frame(width: 38, height: 4)
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
        .paper(cornerRadius: Theme.Radius.xl)
        .offset(y: resistedOffset)
        .gesture(dragGesture)
        .animation(Theme.Motion.smooth, value: isExpanded)
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
    }

    // MARK: Summary (always visible)

    private func summary(_ snapshot: CampusSnapshot) -> some View {
        HStack(spacing: 14) {
            ActivityGauge(intensity: snapshot.overallIntensity)

            VStack(alignment: .leading, spacing: 4) {
                (Text("Campus is ")
                    .foregroundStyle(Theme.Colors.ink)
                    + Text(snapshot.level.title.lowercased() + ".")
                    .font(.cpTitleItalic)
                    .foregroundStyle(Theme.Colors.accent))
                    .font(.cpTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.interpolate)

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
                            .foregroundStyle(Theme.Colors.accent)
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
                .foregroundStyle(Theme.Colors.ink)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Collapse activity panel" : "Expand to see busiest areas")
        .accessibilityAddTraits(.isButton)
    }

    private var loadingSummary: some View {
        HStack(spacing: 14) {
            Circle()
                .stroke(Theme.Colors.surfaceStrong, lineWidth: 2)
                .frame(width: 60, height: 60)
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Right now", trailing: snapshot.trend.title, trailingSymbol: snapshot.trend.symbol)
                .padding(.top, 16)

            // Compact chips: the panel has little vertical room over the map.
            PaperSegmentedPicker(title: "Show", options: modes, selection: $mode, label: \.title, height: 34)

            VStack(spacing: 0) {
                let rows = rows(for: snapshot)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, activity in
                    Button {
                        onSelectArea(activity.id)
                    } label: {
                        AreaActivityRow(activity: activity, rank: index + 1)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(RowButtonStyle())
                    if index < rows.count - 1 {
                        Rectangle().fill(Theme.Colors.rule).frame(height: Theme.Stroke.hairline)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.Colors.positive)
                Text("Anonymous & aggregated · spots under \(snapshot.privacyThreshold) hidden")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                Text(Formatting.time(snapshot.generatedAt))
                    .monospacedDigit()
            }
            .typeStyle(.caption)
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
    var isFavorite = false
    var onToggleFavorite: (() -> Void)?
    var onClose: () -> Void
    var onOpenDetails: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AreaIconTile(symbol: activity.area.symbol, color: activity.level.color, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.area.name)
                        .typeStyle(.title3)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("\(activity.area.category.title) · \(activity.countLabel)")
                        .typeStyle(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isFavorite ? Theme.Colors.accent : Theme.Colors.ink)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel(isFavorite ? "Remove from your places" : "Save to your places")
                    .sensoryFeedback(.selection, trigger: isFavorite)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Colors.ink)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
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
                        .typeStyle(.rowTitle)
                        .foregroundStyle(Theme.Colors.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Last 24 min").sectionLabelStyle()
                    Sparkline(values: activity.history, color: activity.level.textColor, lineWidth: 2)
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
                            .typeStyle(.button)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.Colors.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint("Opens \(activity.area.name) on the Activity tab")
            }
        }
        .padding(16)
        .paper(cornerRadius: Theme.Radius.sm, hardShadow: true)
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
    ActivityPanelPreview()
}

#Preview("Panel – Night") {
    ActivityPanelPreview()
        .preferredColorScheme(.dark)
}
