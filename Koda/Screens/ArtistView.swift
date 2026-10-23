import KodaCore
import SwiftUI

struct ArtistView: View {
    let summary: ArtistSummary

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var state: LoadState<ArtistPage> = .loading
    @State private var palette = PaletteModel()
    @State private var pull: CGFloat = 0
    @State private var aboutExpanded = false

    private let heroHeight: CGFloat = 400
    /// One line of the audience text at the current text size.
    @ScaledMetric(relativeTo: .subheadline) private var audienceLineHeight: CGFloat = 20

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    /// The Mac's artist page: a wide banner with the name and what to do over it, top songs in
    /// two columns, then their records, appearances and similar artists as shelves.
    private var macBody: some View {
        let name = state.value?.artist.name ?? summary.name
        return ScrollView {
            VStack(alignment: .leading, spacing: MacMetrics.sectionSpacing) {
                macHero(name: name)
                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    macContent(page)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(name)
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    /// The Mac's artist header. YouTube's banner is a wide image with the portrait pillarboxed
    /// inside, which shows its bars across a wide window; so the Mac draws the artist's own
    /// photo twice instead: blurred into a field of their colours that fills any width and
    /// fades into the page, and sharp, round, beside their name and what to play.
    private func macHero(name: String) -> some View {
        let portrait = state.value?.artist.artwork ?? summary.artwork
        let shape = Circle()
        return ZStack(alignment: .bottomLeading) {
            MacArtistAmbience(artwork: portrait, tint: palette.palette.mesh[4])
            HStack(alignment: .bottom, spacing: 28) {
                ArtworkView(artwork: portrait, size: 196, circle: true)
                    .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Artist")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    if name.isEmpty {
                        Capsule().fill(.primary.opacity(0.12)).frame(width: 260, height: 44).shimmer()
                    } else {
                        Text(name)
                            .font(.system(size: 46, weight: .heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                            .textSelection(.enabled)
                    }
                    Text(state.value?.artist.subtitle ?? " ")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                    HStack(spacing: 10) {
                        let topSongs = state.value?.topSongs ?? []
                        MacPlayButtons(shuffleTitle: "Radio",
                                       play: { if !topSongs.isEmpty { player.play(topSongs) } },
                                       shuffle: { if let first = topSongs.first { player.startRadio(from: first) } })
                            .disabled(topSongs.isEmpty)
                        let saved = library.isSaved(artist: summary.id)
                        Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                            library.toggleSave(state.value?.artist ?? summary)
                        }
                        .buttonStyle(MacIconButtonStyle())
                        .help(saved ? "Remove from Library" : "Add to Library")
                        MacMoreMenu {
                            ShareLink(item: URL(string: "https://music.youtube.com/channel/\(summary.id)")!) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacMetrics.gutter)
            .padding(.bottom, 8)
        }
        .frame(height: 340)
    }

    @ViewBuilder
    private func macContent(_ page: ArtistPage) -> some View {
        if !page.topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MacSectionTitle(title: "Top songs",
                                seeAll: page.allSongsPlaylistId.map { .playlist(PlaylistSummary(id: $0, title: "\(page.artist.name): Songs", artwork: page.banner)) })
                    .padding(.leading, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8, alignment: .top)], spacing: 2) {
                    ForEach(Array(page.topSongs.enumerated()), id: \.element.id) { index, song in
                        MacSongTile(song: song) { player.play(page.topSongs, startAt: index) }
                    }
                }
            }
            .padding(.horizontal, MacMetrics.gutter)
        }
        if !page.albums.isEmpty {
            MacShelf(title: "Albums") { ForEach(page.albums) { MacItemCard(item: .album($0)) } }
        }
        if !page.singles.isEmpty {
            MacShelf(title: "Singles & EPs") { ForEach(page.singles) { MacItemCard(item: .album($0)) } }
        }
        if !page.featuredOn.isEmpty {
            MacShelf(title: "Featured on") { ForEach(page.featuredOn) { MacItemCard(item: .playlist($0)) } }
        }
        if !page.similar.isEmpty {
            MacShelf(title: "Fans also like") { ForEach(page.similar) { MacArtistCard(artist: $0) } }
        }
        if let about = page.description {
            VStack(alignment: .leading, spacing: 10) {
                MacSectionTitle(title: "About")
                Text(about)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(aboutExpanded ? nil : 5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                Button(aboutExpanded ? "Less" : "More") { withAnimation(.snappy) { aboutExpanded.toggle() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, MacMetrics.gutter)
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    content(page)
                }
            }
            .padding(.bottom, 32)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            pull = max(0, -offset)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .revealsTitle(state.value?.artist.name ?? summary.name, after: 340)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(artist: summary.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                    library.toggleSave(state.value?.artist ?? summary)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
        }
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    /// The photo stretches with an overscroll instead of leaving a gap above it.
    private var hero: some View {
        let banner = state.value?.banner ?? summary.artwork
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .bottomLeading) {
                ArtistHeroImage(artwork: banner, preview: summary.artwork, tint: palette.palette.mesh[4],
                                width: width, height: heroHeight + pull)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    let name = state.value?.artist.name ?? summary.name
                    if name.isEmpty {
                        // Opened from a link, the name comes with the page.
                        Capsule().fill(.white.opacity(0.25)).frame(width: 180, height: 34)
                            .shimmer()
                    } else {
                        Text(name)
                            .font(.system(size: 40, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .transition(.opacity)
                    }
                    // A slot one line tall, always there, so the name sits in the same place
                    // before the audience line arrives, after it, and for artists without one.
                    ZStack(alignment: .leading) {
                        if let audience = state.value?.artist.subtitle {
                            Text(audience)
                                .font(.subheadline.weight(.medium))
                                .opacity(0.85)
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .frame(height: audienceLineHeight, alignment: .leading)
                    .animation(.easeOut(duration: 0.25), value: state.value?.artist.subtitle)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .frame(width: width, height: heroHeight + pull)
            .offset(y: -pull)
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private func content(_ page: ArtistPage) -> some View {
        PlayShuffleButtons(shuffleTitle: "Radio",
                           play: { if !page.topSongs.isEmpty { player.play(page.topSongs) } },
                           shuffle: { if let first = page.topSongs.first { player.startRadio(from: first) } })
            .padding(.horizontal, 20)

        if !page.topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Top songs",
                              seeAll: page.allSongsPlaylistId.map { .playlist(PlaylistSummary(id: $0, title: "\(page.artist.name): Songs", artwork: page.banner)) })
                ForEach(Array(page.topSongs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song) { player.play(page.topSongs, startAt: index) }
                }
            }
            .padding(.horizontal, 20)
        }
        if !page.albums.isEmpty {
            ShelfView(title: "Albums") {
                ForEach(page.albums) { album in
                    NavigationLink(value: Route.album(album)) {
                        CoverCard(artwork: album.artwork, title: album.title, subtitle: album.year.map(String.init))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !page.singles.isEmpty {
            ShelfView(title: "Singles & EPs") {
                ForEach(page.singles) { single in
                    NavigationLink(value: Route.album(single)) {
                        CoverCard(artwork: single.artwork, title: single.title,
                                  subtitle: [single.kind?.rawValue, single.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !page.featuredOn.isEmpty {
            ShelfView(title: "Featured on") {
                ForEach(page.featuredOn) { playlist in
                    NavigationLink(value: Route.playlist(playlist)) {
                        CoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !page.similar.isEmpty {
            ShelfView(title: "Fans also like") {
                ForEach(page.similar) { artist in
                    NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist) }
                        .buttonStyle(.plain)
                }
            }
        }
        if let about = page.description {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.title3.bold())
                Text(about)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(aboutExpanded ? nil : 4)
                    .onTapGesture { withAnimation(.snappy) { aboutExpanded.toggle() } }
            }
            .padding(.horizontal, 20)
        }
    }

    private func load() async {
        state = .loading
        do {
            let page = try await app.music.artist(summary.id)
            state = .loaded(page)
            await palette.load(page.banner)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// The artist photo cropped by Google to the hero's shape.
///
/// The immersive banner is served wide with the portrait pillarboxed inside;
/// its `-p` directive crops the full-resolution source to whatever box is
/// asked for, which is sharper than cropping the wide banner here.
/// The artist's banner, loaded progressively: the small photo already on screen elsewhere
/// shows at once, blurred and enlarged, and the sharp banner fades in over it.
private struct ArtistHeroImage: View {
    let artwork: Artwork?
    /// The small photo from the list the artist was opened from, likely cached already.
    let preview: Artwork?
    /// The photo's main colour, for the space while nothing has loaded.
    let tint: Color
    let width: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var previewImage: UIImage?

    private var url: URL? {
        guard let artwork else { return nil }
        let w = Int(width * scale), h = Int(400 * scale)
        let string = artwork.url.absoluteString
        guard string.contains("googleusercontent.com"), let separator = string.lastIndex(of: "=") else { return artwork.url }
        let directives = String(string[separator...]).replacingOccurrences(of: #"w\d+-h\d+"#, with: "w\(w)-h\(h)", options: .regularExpression)
        return URL(string: String(string[..<separator]) + directives)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            if let previewImage, image == nil {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .scaleEffect(1.2)
                    .transition(.opacity)
            }
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .shimmer(image == nil && previewImage == nil)
        .clipped()
        .task(id: preview?.url) {
            guard let url = preview?.url(pixels: 120), image == nil else { return }
            var small = ImagePipeline.shared.cached(url, pixels: 120)
            if small == nil { small = await ImagePipeline.shared.image(url, pixels: 120) }
            guard image == nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { previewImage = small }
        }
        .task(id: url) {
            guard let url else { return }
            let pixels = Int(max(width, 400) * scale)
            if let hit = ImagePipeline.shared.cached(url, pixels: pixels) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(url, pixels: pixels)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// An artist's photo as a field of their colours: enlarged and blurred far past its edges so
/// it fills any width without bars, softened, and faded into the page at the bottom.
private struct MacArtistAmbience: View {
    let artwork: Artwork?
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                tint.opacity(0.5)
                ArtworkView(artwork: artwork, size: 160, cornerRadius: 0, fillsFrame: true)
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 1.6)
                    .blur(radius: 70, opaque: true)
                    .saturation(1.3)
                    .opacity(colorScheme == .dark ? 0.75 : 0.6)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
