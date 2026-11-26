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
    /// Apple Music's artist, once matched: moving portrait, biography, colours, newest release.
    @State private var apple: AppleArtist?
    @State private var listening: ArtistListening?
    /// The loop rests while the hero is scrolled out of sight.
    @State private var heroOnScreen = true
    @Environment(\.colorScheme) private var colorScheme

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
                        .font(.scaled(.caption).weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    if name.isEmpty {
                        Capsule().fill(.primary.opacity(0.12)).frame(width: 260, height: 44).shimmer()
                    } else {
                        Text(name)
                            .font(.scaledSystem(size: 46, weight: .heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                            .textSelection(.enabled)
                    }
                    Text(state.value?.artist.subtitle ?? " ")
                        .font(.scaled(.title3))
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
                            PinMenuItem(pin: .artist(summary))
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
                    .font(.scaled(.body))
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
            VStack(alignment: .leading, spacing: 30) {
                hero
                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    content(page)
                }
            }
            .padding(.bottom, 32)
            // The portrait's colour washes the top of the page under it and fades out; it scrolls
            // with the page, so it stays under the hero's edge.
            .background(alignment: .top) {
                LinearGradient(colors: [tint.opacity(colorScheme == .dark ? 0.3 : 0.2), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 560)
                    .padding(.top, heroHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, overscroll in
            pull = overscroll
        }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .revealsTitle(state.value?.artist.name ?? summary.name, after: 340)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(artist: summary.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                    library.toggleSave(state.value?.artist ?? summary)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    if let first = state.value?.topSongs.first {
                        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(from: first) }
                    }
                    PinMenuItem(pin: .artist(summary))
                    ShareLink(item: URL(string: "https://music.youtube.com/channel/\(summary.id)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        #endif
        .task { await palette.load(summary.artwork) }
        // Known from an earlier visit, the moving portrait is there from the first frame.
        .task { if apple == nil { apple = await app.motionArtwork.knownArtist(summary.id) } }
        .task { if state.value == nil { await load() } }
        .task(id: summary.id) { listening = ArtistListening(artistID: summary.id, library: library) }
    }

    /// What the page is tinted with: the portrait's own colour from Apple when it has a real
    /// one, else the colour of YouTube's photo.
    private var tint: Color { apple?.tint ?? palette.palette.accent }

    /// "238M monthly audience · 40.2M subscribers".
    private var audience: String? {
        let parts = [state.value?.artist.subtitle, state.value?.subscribers.map { "\($0) subscribers" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The artist's photo, or Apple's moving portrait over it, edge to edge under the status
    /// bar. It stretches with an overscroll instead of leaving a gap above it, drifts up slower
    /// than the page and darkens a little as it goes, and the loop rests once it's out of sight.
    private var hero: some View {
        let banner = state.value?.banner ?? summary.artwork
        let topSongs = state.value?.topSongs ?? []
        return GeometryReader { geometry in
            let width = geometry.size.width
            let height = heroHeight + pull
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    ArtistHeroImage(artwork: banner, preview: summary.artwork, tint: palette.palette.mesh[4],
                                    width: width, height: height)
                    MotionLoop(covers: apple?.motion, shape: .square, isPlaying: heroOnScreen)
                        .frame(width: width, height: height)
                        .clipped()
                }
                .visualEffect { content, proxy in
                    let scrolled = max(0, -proxy.frame(in: .scrollView(axis: .vertical)).minY)
                    return content
                        .offset(y: scrolled * 0.4)
                        .brightness(-min(0.25, scrolled / 1600))
                }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        let name = state.value?.artist.name ?? summary.name
                        if name.isEmpty {
                            // Opened from a link, the name comes with the page.
                            Capsule().fill(.white.opacity(0.25)).frame(width: 180, height: 34)
                                .shimmer()
                        } else {
                            Text(name)
                                .font(.scaledSystem(size: 40, weight: .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .transition(.opacity)
                        }
                        // A slot one line tall, always there, so the name sits in the same place
                        // before the audience line arrives, after it, and for artists without one.
                        ZStack(alignment: .leading) {
                            if let audience {
                                Text(audience)
                                    .font(.scaled(.subheadline).weight(.medium))
                                    .opacity(0.85)
                                    .lineLimit(1)
                                    .transition(.opacity)
                            }
                        }
                        .frame(height: audienceLineHeight, alignment: .leading)
                        .animation(.easeOut(duration: 0.25), value: audience)
                    }
                    Spacer(minLength: 0)
                    Button("Play", systemImage: "play.fill") {
                        if !topSongs.isEmpty { player.play(topSongs) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.scaled(.title2))
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.extraLarge)
                    .disabled(topSongs.isEmpty)
                    .accessibilityLabel("Play \(summary.name)")
                }
                .foregroundStyle(.white)
                // Over a photo, so the glass and the text are drawn for a dark backdrop in either appearance.
                .environment(\.colorScheme, .dark)
                .padding(20)
            }
            .frame(width: width, height: height)
            .clipped()
            .offset(y: -pull)
        }
        .frame(height: heroHeight)
        .onScrollVisibilityChange(threshold: 0.05) { heroOnScreen = $0 }
    }

    @ViewBuilder
    private func content(_ page: ArtistPage) -> some View {
        if let latest = latestRelease(page) {
            LatestReleaseCard(album: latest.album, line: latest.line)
                .padding(.horizontal, 20)
        }
        if !page.topSongs.isEmpty {
            SongColumnsShelf(title: "Top songs",
                             seeAll: page.allSongsPlaylistId.map { .playlist(PlaylistSummary(id: $0, title: "\(page.artist.name): Songs", artwork: page.banner)) },
                             songs: page.topSongs) { index in
                player.play(page.topSongs, startAt: index)
            }
        }
        if let listening {
            ArtistListeningCard(name: page.artist.name, listening: listening)
                .padding(.horizontal, 20)
        }
        if !page.albums.isEmpty {
            ShelfView(title: "Albums") {
                ForEach(page.albums) { album in
                    ItemCard(item: .album(album), subtitle: album.year.map(String.init) ?? "Album") { _ in }
                }
            }
        }
        if !page.singles.isEmpty {
            ShelfView(title: "Singles & EPs") {
                ForEach(page.singles) { single in
                    ItemCard(item: .album(single),
                             subtitle: [single.kind?.rawValue, single.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")) { _ in }
                }
            }
        }
        if !page.videos.isEmpty {
            VideoShelf(title: "Videos", videos: page.videos)
        }
        if !page.livePerformances.isEmpty {
            VideoShelf(title: "Live performances", videos: page.livePerformances)
        }
        if !page.playlists.isEmpty {
            ShelfView(title: "Playlists") {
                ForEach(page.playlists) { ItemCard(item: .playlist($0)) { _ in } }
            }
        }
        if !page.featuredOn.isEmpty {
            ShelfView(title: "Featured on") {
                ForEach(page.featuredOn) { ItemCard(item: .playlist($0)) { _ in } }
            }
        }
        if !page.similar.isEmpty {
            ShelfView(title: "Fans also like") {
                ForEach(page.similar) { ItemCard(item: .artist($0), width: 150) { _ in } }
            }
        }
        if let about = apple?.bio ?? page.description {
            ArtistAboutCard(name: page.artist.name, text: about, apple: apple?.bio == nil ? nil : apple)
                .padding(.horizontal, 20)
        }
    }

    /// Their newest release, dated to the day when Apple knows it; YouTube alone gives only a
    /// year, so then only one from this year or last counts as news.
    private func latestRelease(_ page: ArtistPage) -> (album: AlbumSummary, line: String)? {
        let releases = page.singles + page.albums
        let thisYear = Calendar.current.component(.year, from: .now)
        if let latest = apple?.latest, let date = latest.date, date > Date.now.addingTimeInterval(-400 * 86400),
           let album = releases.first(where: { MotionArtworkCatalog.sameRelease($0.title, latest.title) }) {
            return (album, [album.kind?.rawValue ?? (latest.isSingle ? "Single" : "Album"), Self.releaseDay(date)].joined(separator: " · "))
        }
        // Each shelf lists its newest first; a single wins a tie with an album from the same year.
        guard let newest = [page.singles.first, page.albums.first].compactMap({ $0 }).max(by: { ($0.year ?? 0) < ($1.year ?? 0) }),
              let year = newest.year, year >= thisYear - 1 else { return nil }
        return (newest, [newest.kind?.rawValue, String(year)].compactMap { $0 }.joined(separator: " · "))
    }

    /// "Yesterday", "2 weeks ago", "Out July 17" for one announced ahead, else the date.
    private static func releaseDay(_ date: Date) -> String {
        if date > .now { return "Out " + date.formatted(.dateTime.month(.wide).day()) }
        if Date.now.timeIntervalSince(date) < 45 * 86400 { return date.formatted(.relative(presentation: .named)).capitalizedFirst }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private func load() async {
        state = .loading
        do {
            let page = try await app.music.artist(summary.id)
            state = .loaded(page)
            await palette.load(page.banner)
            let found = await app.appleArtist(page.artist, page: page)
            if found != apple { withAnimation(.smooth) { apple = found } }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private extension String {
    /// "2 weeks ago" → "2 weeks ago"; "yesterday" → "Yesterday".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// What the listener has played by an artist, from Koda's own counts.
struct ArtistListening: Equatable {
    var plays: Int
    var seconds: TimeInterval
    var since: Date
    /// Their most played songs by the artist, most first.
    var top: [SongStats]

    /// Nil until they've played the artist a few times; a single play says nothing yet.
    init?(artistID: String, library: Library) {
        let mine = library.songStats.values.filter { stats in stats.song.artists.contains { $0.id == artistID } }
        let plays = mine.reduce(0) { $0 + $1.plays }
        guard plays >= 3, let since = mine.map(\.firstPlayed).min() else { return nil }
        self.plays = plays
        seconds = mine.reduce(0) { $0 + $1.seconds }
        self.since = since
        top = Array(mine.sorted { $0.plays > $1.plays }.prefix(3))
    }
}

/// "You & The Weeknd": how much the listener has played them, since when, and their own top
/// three of the artist's songs.
private struct ArtistListeningCard: View {
    let name: String
    let listening: ArtistListening
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "You & \(name)", strapline: "Your listening")
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(listening.plays == 1 ? "1 play" : "\(listening.plays) plays")
                        .font(.scaled(.title).bold())
                        .monospacedDigit()
                    Text(detail)
                        .font(.scaled(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Divider()
                VStack(spacing: 0) {
                    let songs = listening.top.map(\.song)
                    ForEach(Array(listening.top.enumerated()), id: \.element.song.id) { index, stats in
                        SongRow(song: stats.song, subtitle: stats.plays == 1 ? "1 play" : "\(stats.plays) plays") {
                            player.play(songs, startAt: index)
                        }
                    }
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    /// "Since March 2025 · 18 hours".
    private var detail: String {
        let since = "Since " + listening.since.formatted(.dateTime.month(.wide).year())
        guard listening.seconds >= 60 else { return since }
        let time = Duration.seconds(listening.seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1))
        return since + " · " + time
    }
}

/// Their newest release as a card of its own above everything else, as Music shows it.
private struct LatestReleaseCard: View {
    let album: AlbumSummary
    let line: String

    var body: some View {
        NavigationLink(value: Route.album(album)) {
            HStack(spacing: 14) {
                ArtworkView(artwork: album.artwork, size: 96, cornerRadius: 10)
                    .zoomSource(.album(album))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest release")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(album.title)
                        .font(.scaled(.title3).bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(line)
                        .font(.scaled(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.scaled(.subheadline).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { CollectionMenuItems(item: .album(album)) } preview: { CollectionPreview(item: .album(album), subtitle: line) }
    }
}

/// Music videos or live performances: wide frames in a row, playing as songs do.
private struct VideoShelf: View {
    let title: String
    let videos: [Song]
    @Environment(Player.self) private var player

    var body: some View {
        ShelfView(title: title) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                Button { player.play(videos, startAt: index) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .frame(width: 260, height: 146)
                            .overlay { ArtworkView(artwork: video.artwork, size: 260, cornerRadius: 12, fillsFrame: true) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(video.title)
                                .font(.scaled(.subheadline).weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(video.artistLine)
                                .font(.scaled(.footnote))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 260, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu { SongMenuItems(song: video) } preview: { SongPreview(song: video) }
            }
        }
    }
}

/// About: Apple Music's editorial biography when the artist is matched there (set in the
/// serif Apple uses for long reading), else YouTube's description, with where they're from and
/// when they were born or formed. A tap opens all of it.
private struct ArtistAboutCard: View {
    let name: String
    let text: String
    /// Set when the text is Apple's biography; its facts come with it.
    let apple: AppleArtist?
    @Environment(AppModel.self) private var app
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")
            Button { showsAll = true } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ArtistBio.attributed(text))
                        .font(.scaled(.body))
                        .fontDesign(.serif)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                    if let apple { ArtistFacts(artist: apple) }
                    Text("More")
                        .font(.scaled(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole biography")
        }
        .sheet(isPresented: $showsAll) {
            ArtistBioSheet(name: name, text: text, apple: apple)
                .appEnvironment(app)
        }
    }
}

/// Where they're from, when they were born or formed, their genre.
private struct ArtistFacts: View {
    let artist: AppleArtist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let origin = artist.origin { Label(origin, systemImage: "mappin.and.ellipse") }
            if let born = artist.bornOrFormedLine { Label(born, systemImage: "calendar") }
            if let genre = artist.genre { Label(genre, systemImage: "music.note") }
        }
        .font(.scaled(.subheadline))
        .foregroundStyle(.secondary)
        .labelStyle(FactLabelStyle())
    }

    private struct FactLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon.frame(width: 18)
                configuration.title
            }
        }
    }
}

/// The whole biography, over the artist's square portrait.
private struct ArtistBioSheet: View {
    let name: String
    let text: String
    let apple: AppleArtist?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let still = apple?.still(.square, pixels: 900) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { ArtworkView(artwork: still, size: 360, cornerRadius: 16, fillsFrame: true) }
                    }
                    Text(name)
                        .font(.scaled(.largeTitle).bold())
                    if let apple { ArtistFacts(artist: apple) }
                    Text(ArtistBio.attributed(text))
                        .font(.scaled(.body))
                        .fontDesign(.serif)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                    if apple != nil {
                        Text("Biography from Apple Music")
                            .font(.scaled(.footnote))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private enum ArtistBio {
    /// Apple's biography is Markdown (its italics kept); YouTube's is plain text, which reads the same.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
    @State private var image: PlatformImage?
    @State private var previewImage: PlatformImage?

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
                Image(platformImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .scaleEffect(1.2)
                    .transition(.opacity)
            }
            if let image {
                Image(platformImage: image).resizable().scaledToFill().transition(.opacity)
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
