import KodaCore
import SwiftUI

/// How a lyrics card is backed.
enum LyricsCardStyle: String, CaseIterable, Identifiable {
    /// The cover's colours as a soft mesh.
    case colors
    /// The cover itself, blurred and darkened.
    case cover
    /// Near black, for lines that should stand alone.
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .colors: "Colours"
        case .cover: "Cover"
        case .dark: "Dark"
        }
    }
}

/// Pick a few lines of a song and share them as a card, on a sheet in the song's colours.
struct LyricsShareSheet: View {
    let lines: [LyricLine]
    let song: Song

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var selected: Set<Int>
    @State private var style: LyricsCardStyle = .colors
    @State private var cover: UIImage?
    @State private var palette = PaletteModel()
    @State private var rendered: UIImage?
    @State private var limitHit = 0
    /// The card's natural height at preview width, measured as it lays out.
    @State private var cardHeight: CGFloat = 0
    @State private var copied = 0
    /// The line the sheet was opened from, which the list starts on.
    private let startLine: Int

    static let maxLines = 6

    init(lines: [LyricLine], song: Song, startingAt id: Int) {
        // Lines with words only; the "♪" placeholders of instrumental gaps are not lyrics.
        self.lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        self.song = song
        startLine = id
        _selected = State(initialValue: [id])
    }

    private var chosen: [LyricLine] { lines.filter { selected.contains($0.id) } }

    var body: some View {
        Group {
            if Platform.isMac { macBody } else { phoneBody }
        }
        .task {
            if let url = song.artwork?.url(pixels: 600) { cover = await ImagePipeline.shared.image(url, pixels: 600) }
            await palette.load(song.artwork)
            render()
        }
        .onChange(of: selected) { render() }
        .onChange(of: style) { render() }
        .sensoryFeedback(.warning, trigger: limitHit)
    }

    private var hint: some View {
        Text(selected.count >= Self.maxLines ? "Up to \(Self.maxLines) lines" : "Click lines to add or remove them")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.65))
            .contentTransition(.opacity)
            .animation(.smooth, value: selected.count >= Self.maxLines)
    }

    /// The Mac's: the card and its style on the left, the song's lines on the right, and the
    /// buttons along the foot as a Mac sheet has them.
    private var macBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 22) {
                preview(maxHeight: 430)
                stylePicker
            }
            .frame(width: 400)
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                hint.padding(.horizontal, 32).padding(.top, 18)
                linePicker
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.18))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Image", systemImage: "doc.on.doc") {
                    UIPasteboard.general.image = rendered
                    copied += 1
                }
                .disabled(rendered == nil)
                .keyboardShortcut("c", modifiers: .command)
                .sensoryFeedback(.success, trigger: copied)
                shareButton
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
        .background { backdrop }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 640)
        // Sized to the layout above rather than the standard form sheet, which is phone-narrow.
        .presentationSizing(.fitted)
    }

    private var phoneBody: some View {
        NavigationStack {
            GeometryReader { geometry in
            VStack(spacing: 18) {
                preview(maxHeight: geometry.size.height * 0.42)

                stylePicker

                Text(selected.count >= Self.maxLines ? "Up to \(Self.maxLines) lines" : "Tap lines to add or remove them")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: selected.count >= Self.maxLines)

                linePicker
            }
            }
            .background { backdrop }
            .navigationTitle("Share Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    shareButton
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.clear)
    }

    // MARK: Parts

    /// The card as it will look, shrunk to fit its share of the sheet: however many long
    /// lines are chosen, the list under it keeps its room and stays scrollable.
    private func preview(maxHeight: CGFloat) -> some View {
        let scale = cardHeight > maxHeight ? maxHeight / cardHeight : 1
        return LyricsCard(lines: chosen.map(\.text), song: song, cover: cover, palette: palette.palette, style: style)
            .frame(width: 300)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            .scaleEffect(scale, anchor: .top)
            .frame(height: cardHeight > 0 ? cardHeight * scale : nil, alignment: .top)
            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
            .padding(.top, 8)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: selected)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: scale)
            .animation(.smooth(duration: 0.3), value: style)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Card preview")
    }

    /// The song's colours behind the whole sheet, so it feels like part of the player.
    private var backdrop: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5, 0.5], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: palette.palette.mesh)
        .overlay(Color.black.opacity(0.35))
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.6), value: palette.palette)
    }

    private var stylePicker: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(LyricsCardStyle.allCases) { option in
                    let isOn = option == style
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { style = option }
                    } label: {
                        HStack(spacing: 8) {
                            swatch(option)
                                .frame(width: 22, height: 22)
                                .clipShape(.circle)
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isOn ? .regular.tint(.white.opacity(0.28)).interactive() : .regular.interactive(), in: .capsule)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .sensoryFeedback(.selection, trigger: isOn)
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ option: LyricsCardStyle) -> some View {
        switch option {
        case .colors:
            LinearGradient(colors: [palette.palette.mesh[0], palette.palette.mesh[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cover:
            // Cropped in an overlay, so a wide video frame can't widen the swatch.
            Color.gray.overlay { if let cover { Image(uiImage: cover).resizable().scaledToFill() } }.clipped()
        case .dark:
            Color(white: 0.1)
        }
    }

    /// The song's lines in the lyrics' own type; chosen lines sit on glass.
    private var linePicker: some View {
        ScrollViewReader { proxy in
        ScrollView {
            GlassEffectContainer(spacing: 4) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        let isOn = selected.contains(line.id)
                        Button {
                            toggle(line.id)
                        } label: {
                            Text(line.text)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white.opacity(isOn ? 1 : 0.45))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(isOn ? .regular.interactive() : .identity, in: .rect(cornerRadius: 18, style: .continuous))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .sensoryFeedback(.selection, trigger: isOn)
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        // Opens on the line that was long-pressed, not the top of the song.
        .task {
            await Task.yield()
            proxy.scrollTo(startLine, anchor: .center)
        }
        }
        .scrollIndicators(.hidden)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                     .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var shareButton: some View {
        if let rendered {
            let image = Image(uiImage: rendered)
            ShareLink(item: image, preview: SharePreview("\(song.title) · \(song.artistLine)", image: image)) {
                Label(Platform.isMac ? "Share…" : "Share Card", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, Platform.isMac ? 0 : 24)
            }
        } else {
            ProgressView()
        }
    }

    private func toggle(_ id: Int) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if selected.contains(id) {
                // At least one line stays chosen; a card with no words is nothing to share.
                if selected.count > 1 { selected.remove(id) }
            } else if selected.count < Self.maxLines {
                selected.insert(id)
            } else {
                limitHit += 1
            }
        }
    }

    /// Drawn once per change, once the cover has loaded: the renderer takes a single
    /// picture and does not wait for images to arrive.
    private func render() {
        let card = LyricsCard(lines: chosen.map(\.text), song: song, cover: cover, palette: palette.palette, style: style)
            .frame(width: 360)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(displayScale, 3)
        rendered = renderer.uiImage
    }
}

/// The card itself: the song at the top, its lines large, a small Koda mark at the foot.
struct LyricsCard: View {
    let lines: [String]
    let song: Song
    let cover: UIImage?
    let palette: Palette
    var style: LyricsCardStyle = .colors

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.white.opacity(0.15))
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(song.artistLine).font(.footnote).opacity(0.75).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 25, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("Koda")
            }
            .font(.caption.weight(.bold))
            .opacity(0.6)
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .colors:
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: palette.mesh)
            .overlay(Color.black.opacity(0.12))
        case .cover:
            // The cover is an overlay, so its own size (wider for a video) never sizes the card.
            Color.black
                .overlay {
                    if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 28)
                            .scaleEffect(1.3)
                    }
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .clipped()
        case .dark:
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
