import KodaCore
import SwiftUI

// MARK: - Artists

/// Round portraits to pick from, the way Apple Music asks; a pick is ringed and ticked, and brings
/// a few artists like it in right after it. Search finds anyone the grid doesn't show.
struct TasteArtistsPage: View {
    @Bindable var taste: TasteModel
    let next: () -> Void
    let skip: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 98, maximum: 128), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OnboardingHeader(title: "Pick Artists You Love",
                                 detail: "Choose a few. Each one brings others like them.")
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $taste.query, prompt: "Find an Artist")
        .task(id: taste.query) { await taste.search() }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                if !taste.picked.isEmpty {
                    Text(taste.picked.count == 1 ? "1 artist picked" : "\(taste.picked.count) artists picked")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                OnboardingButton(taste.picked.isEmpty ? "Skip Artists" : "Continue", action: next)
            }
            .animation(.snappy, value: taste.picked.count)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip Setup", action: skip)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        if !taste.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if taste.results.isEmpty, !taste.isSearching {
                ContentUnavailableView.search(text: taste.query)
            } else {
                grid(taste.results)
            }
        } else if taste.isLoadingArtists, taste.grid.isEmpty {
            grid(ArtistSummary.tastePlaceholders)
                .loadingPlaceholder()
        } else if taste.artistsFailed {
            ContentUnavailableView {
                Label("Couldn't Load Artists", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection, or search for artists you know.")
            } actions: {
                Button("Try Again") { Task { await taste.retry() } }
                    .buttonStyle(.glass)
            }
        } else {
            grid(taste.grid)
        }
    }

    private func grid(_ artists: [ArtistSummary]) -> some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(artists, id: \.id) { artist in
                TasteArtistCell(artist: artist, isPicked: taste.isPicked(artist)) {
                    withAnimation(.snappy(duration: 0.25)) { taste.toggle(artist) }
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

private struct TasteArtistCell: View {
    let artist: ArtistSummary
    let isPicked: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 92

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ArtworkView(artwork: artist.artwork, size: size, circle: true)
                    .frame(width: size, height: size)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(-6)
                            .opacity(isPicked ? 1 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isPicked {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(.background).padding(2))
                                .offset(x: 4, y: 4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(isPicked ? 0.92 : 1)
                    .padding(6)
                Text(artist.name)
                    .font(.subheadline.weight(isPicked ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isPicked)
        .accessibilityLabel(artist.name)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityHint(isPicked ? "Double-tap to remove." : "Double-tap to pick.")
    }
}

extension ArtistSummary {
    /// The grid's shape while the first artists load.
    static let tastePlaceholders = (0..<12).map { ArtistSummary(id: "placeholder-\($0)", name: "Artist Name") }
}

// MARK: - Genres

struct TasteGenresPage: View {
    let taste: TasteModel
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                OnboardingHeader(title: "And a Few Genres",
                                 detail: "Pick what you'd like more of.")
                ChipFlow(spacing: 10) {
                    ForEach(TasteProfile.genres, id: \.self) { genre in
                        GenreChip(title: genre, isOn: taste.genres.contains(genre)) {
                            withAnimation(.snappy(duration: 0.2)) { taste.toggle(genre: genre) }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom) {
            OnboardingButton(taste.genres.isEmpty ? "Skip Genres" : "Continue", action: next)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip Setup", action: skip)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GenreChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Lays its children out in rows, wrapping to the next when one is full, centred: chips.
nonisolated struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Deck

/// A short deck of songs to keep or skip, each playing a few seconds as it comes up. Swipe right
/// or tap ✓ to keep, left or ✕ to skip (it won't be suggested), ♥ to keep and like it. On the
/// Mac, ← and → answer.
struct TasteDeckPage: View {
    let taste: TasteModel
    let preview: TastePreview
    let next: () -> Void
    let skip: () -> Void
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    @State private var answers = 0

    private static let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 22) {
            OnboardingHeader(title: "Keep What You Like",
                             detail: "Swipe right to keep a song, left to skip it.")
            Spacer(minLength: 0)
            if taste.isLoadingDeck || (taste.deck.isEmpty && taste.current == nil && answers == 0) {
                ProgressView("Finding songs for you…")
                    .frame(maxHeight: .infinity)
            } else if let card = taste.current {
                Text("\(taste.deckIndex + 1) of \(taste.deck.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                cards(top: card)
                controls
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip Setup", action: skip)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(preview.isMuted ? "Unmute" : "Mute", systemImage: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    preview.isMuted.toggle()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact(weight: .light), trigger: answers)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { answer(.skip); return .handled }
        .onKeyPress(.rightArrow) { answer(.keep); return .handled }
        .task {
            await taste.buildDeck()
            if taste.deck.isEmpty { next() } else { preview.play(taste.current?.song, pausing: player) }
        }
        .onChange(of: taste.deckIndex) {
            guard let card = taste.current else {
                preview.stop()
                next()
                return
            }
            preview.play(card.song, pausing: player)
        }
        .onDisappear { preview.stop() }
    }

    private func cards(top card: TasteModel.Card) -> some View {
        ZStack {
            if taste.deck.indices.contains(taste.deckIndex + 1) {
                DeckCardView(card: taste.deck[taste.deckIndex + 1], state: .waiting)
                    .scaleEffect(0.94)
                    .offset(y: 14)
                    .opacity(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            DeckCardView(card: card, state: preview.playingID == card.id ? (preview.isLoading ? .loading : .playing) : .waiting)
                .overlay(alignment: .topLeading) { stamp("checkmark", .green).opacity(Double(max(0, drag.width) / Self.threshold)) }
                .overlay(alignment: .topTrailing) { stamp("xmark", .red).opacity(Double(max(0, -drag.width) / Self.threshold)) }
                .offset(drag)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width / 22)), anchor: .bottom)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let width = value.predictedEndTranslation.width
                            if width > Self.threshold * 1.4 || value.translation.width > Self.threshold {
                                fly(.keep, toward: 1)
                            } else if width < -Self.threshold * 1.4 || value.translation.width < -Self.threshold {
                                fly(.skip, toward: -1)
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero }
                            }
                        }
                )
                .id(card.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .identity))
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Keep") { answer(.keep) }
                .accessibilityAction(named: "Skip") { answer(.skip) }
                .accessibilityAction(named: "Love") { answer(.love) }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            DeckButton(systemImage: "xmark", label: "Skip", tint: .secondary) { answer(.skip) }
            DeckButton(systemImage: "heart.fill", label: "Love", tint: .pink, large: true) { answer(.love) }
            DeckButton(systemImage: "checkmark", label: "Keep", tint: .green) { answer(.keep) }
        }
    }

    private func stamp(_ systemImage: String, _ color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(color, in: .circle)
            .padding(18)
            .accessibilityHidden(true)
    }

    /// The card follows the swipe off the screen, then the answer moves the deck on.
    private func fly(_ answer: TasteModel.Answer, toward direction: CGFloat) {
        withAnimation(.smooth(duration: 0.22)) {
            drag = CGSize(width: direction * 700, height: drag.height + 60)
        } completion: {
            self.answer(answer)
        }
    }

    private func answer(_ answer: TasteModel.Answer) {
        guard taste.current != nil else { return }
        answers += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = .zero }
        withAnimation(.snappy) { taste.answer(answer) }
    }
}

private struct DeckCardView: View {
    enum Phase { case waiting, loading, playing }
    let card: TasteModel.Card
    let state: Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ArtworkView(artwork: card.song.artwork, size: 600, cornerRadius: 22, fillsFrame: true) }
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        switch state {
                        case .loading: ProgressView()
                        case .playing: Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
                        case .waiting: EmptyView()
                        }
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
                    .padding(12)
                    .opacity(state == .waiting ? 0 : 1)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.reason.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Text(card.song.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text(card.song.artistLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 34, style: .continuous))
    }
}

private struct DeckButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: large ? 28 : 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: large ? 72 : 60, height: large ? 72 : 60)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}
