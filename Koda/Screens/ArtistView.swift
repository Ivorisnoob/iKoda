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
    /// The loop rests while the portrait is scrolled out of sight.
    @State private var portraitOnScreen = true
    /// Whether Apple's moving portrait is what shows, so the colours behind it come from it.
    @State private var loopShowing = false

    /// Most of the width, as Music gives an album's cover, and none of it under the toolbar.
    private let portraitSize: CGFloat = 264
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
        .task { if apple == nil { apple = await app.motionArtwork.knownArtist(summary.id) } }
        .task { if state.value == nil { await load() } }
        .task(id: summary.id) { listening = ArtistListening(artistID: summary.id, library: library) }
    }

    /// The Mac's artist header. YouTube's banner is a wide image with the portrait pillarboxed
    /// inside, which shows its bars across a wide window; so the Mac draws the artist's own
    /// photo twice instead: blurred into a field of their colours that fills any width and
    /// fades into the page, and sharp, round, beside their name and what to play.
    private func macHero(name: String) -> some View {
        let portrait = state.value?.artist.artwork ?? summary.artwork
        return ZStack(alignment: .bottomLeading) {
            MacArtistAmbience(artwork: portrait, tint: palette.palette.mesh[4])
            HStack(alignment: .bottom, spacing: 28) {
                ArtistPortrait(artwork: portrait, motion: apple?.motion, isPlaying: portraitOnScreen, size: 196)
                    .onScrollVisibilityChange(threshold: 0.05) { portraitOnScreen = $0 }
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
                    Text(audience ?? " ")
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
                        LibraryToggleButton(isSaved: library.isSaved(artist: summary.id)) {
                            library.toggleSave(state.value?.artist ?? summary)
                        }
                        .buttonStyle(MacIconButtonStyle())
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
        if let latest = latestRelease(page) {
            LatestReleaseCard(album: latest.album, line: latest.line)
                .frame(maxWidth: CGFloat(560).scaled, alignment: .leading)
                .padding(.horizontal, MacMetrics.gutter)
        }
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
        if let listening {
            ArtistListeningCard(name: page.artist.name, listening: listening)
                .frame(maxWidth: CGFloat(560).scaled, alignment: .leading)
                .padding(.horizontal, MacMetrics.gutter)
        }
        if !page.albums.isEmpty {
            MacShelf(title: "Albums") { ForEach(page.albums) { MacItemCard(item: .album($0)) } }
        }
        if !page.singles.isEmpty {
            MacShelf(title: "Singles & EPs") { ForEach(page.singles) { MacItemCard(item: .album($0)) } }
        }
        if !page.videos.isEmpty {
            VideoShelf(title: "Videos", videos: page.videos)
        }
        if !page.livePerformances.isEmpty {
            VideoShelf(title: "Live performances", videos: page.livePerformances)
        }
        if !page.playlists.isEmpty {
            MacShelf(title: "Playlists") { ForEach(page.playlists) { MacItemCard(item: .playlist($0)) } }
        }
        if !page.featuredOn.isEmpty {
            MacShelf(title: "Featured on") { ForEach(page.featuredOn) { MacItemCard(item: .playlist($0)) } }
        }
        if !page.similar.isEmpty {
            MacShelf(title: "Fans also like") { ForEach(page.similar) { MacArtistCard(artist: $0) } }
        }
        if let about = apple?.bio ?? page.description {
            // Apple's biography in the serif Apple sets long reading in, with its facts beside
            // it; YouTube's description as it was when Apple has none.
            let bio = apple?.bio == nil ? nil : apple
            VStack(alignment: .leading, spacing: 10) {
                MacSectionTitle(title: "About")
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ArtistBio.attributed(about))
                            .font(.scaled(.body))
                            .fontDesign(bio == nil ? .default : .serif)
                            .foregroundStyle(bio == nil ? .secondary : .primary)
                            .lineSpacing(bio == nil ? 0 : 2)
                            .lineLimit(aboutExpanded ? nil : 5)
                            .textSelection(.enabled)
                        Button(aboutExpanded ? "Less" : "More") { withAnimation(.snappy) { aboutExpanded.toggle() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    if let bio { ArtistFacts(artist: bio).padding(.top, 2) }
                }
                if bio != nil {
                    Text("Biography from Apple Music")
                        .font(.scaled(.footnote))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, MacMetrics.gutter)
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                stage
                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    content(page)
                }
            }
            .padding(.bottom, 32)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, overscroll in
            pull = overscroll
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .revealsTitle(state.value?.artist.name ?? summary.name, after: 330)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryToggleButton(isSaved: library.isSaved(artist: summary.id)) {
                    library.toggleSave(state.value?.artist ?? summary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    PinMenuItem(pin: .artist(summary))
                    ShareLink(item: URL(string: "https://music.youtube.com/channel/\(summary.id)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        #endif
        // The colours behind the portrait are the portrait's own: YouTube's photo, or Apple's
        // moving one once that is what shows.
        .task(id: ambienceArtwork?.url) { await palette.load(ambienceArtwork) }
        // Known from an earlier visit, the moving portrait is there from the first frame.
        .task { if apple == nil { apple = await app.motionArtwork.knownArtist(summary.id) } }
        .task { if state.value == nil { await load() } }
        .task(id: summary.id) { listening = ArtistListening(artistID: summary.id, library: library) }
    }

    private var ambienceArtwork: Artwork? {
        let photo = state.value?.artist.artwork ?? summary.artwork
        return loopShowing ? apple?.still(.square, pixels: 200) ?? photo : photo
    }

    /// "238M monthly audience · 40.2M subscribers".
    private var audience: String? {
        let parts = [state.value?.artist.subtitle, state.value?.subscribers.map { "\($0) subscribers" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The top of the page, as Music lays out a record's: the artist large and round in the
    /// middle (Apple's moving portrait over their photo when there is one), their name and
    /// audience under it, then Play and Radio. It all sits below the toolbar, so the bar's soft
    /// edge never covers a face, on a field of the portrait's own colours that runs up under the
    /// bars and past a pull, and melts into the page with no edge. A pull grows the portrait.
    private var stage: some View {
        let name = state.value?.artist.name ?? summary.name
        let topSongs = state.value?.topSongs ?? []
        return VStack(spacing: 0) {
            ArtistPortrait(artwork: state.value?.artist.artwork ?? summary.artwork, motion: apple?.motion,
                           isPlaying: portraitOnScreen, size: portraitSize) { loopShowing = $0 }
                .scaleEffect(1 + min(pull, 240) / 900, anchor: .bottom)
                .onScrollVisibilityChange(threshold: 0.05) { portraitOnScreen = $0 }
                .padding(.top, 12)
            VStack(spacing: 4) {
                if name.isEmpty {
                    // Opened from a link, the name comes with the page.
                    Capsule().fill(.primary.opacity(0.12)).frame(width: 180, height: 34)
                        .shimmer()
                } else {
                    Text(name)
                        .font(.scaledSystem(size: 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .accessibilityAddTraits(.isHeader)
                        .transition(.opacity)
                }
                // A slot one line tall, always there, so the name sits in the same place
                // before the audience line arrives, after it, and for artists without one.
                ZStack {
                    if let audience {
                        AudienceLine(text: audience)
                            .transition(.opacity)
                    }
                }
                .frame(height: audienceLineHeight)
                .animation(.easeOut(duration: 0.25), value: audience)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            PlayShuffleButtons(shuffleTitle: "Radio",
                               play: { if !topSongs.isEmpty { player.play(topSongs) } },
                               shuffle: { if let first = topSongs.first { player.startRadio(from: first) } })
                .disabled(topSongs.isEmpty)
                .padding(.horizontal, 20)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .background { ArtistAmbience(palette: palette.palette) }
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
            // The iPhone's colours follow whichever portrait shows (`ambienceArtwork`).
            if Platform.isMac { await palette.load(page.artist.artwork ?? page.banner) }
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
            if Platform.isMac {
                MacSectionTitle(title: "You & \(name)", subtitle: "Your listening")
            } else {
                SectionHeader(title: "You & \(name)", strapline: "Your listening")
            }
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
                        if Platform.isMac {
                            MacSongTile(song: stats.song) { player.play(songs, startAt: index) }
                        } else {
                            SongRow(song: stats.song, subtitle: stats.plays == 1 ? "1 play" : "\(stats.plays) plays") {
                                player.play(songs, startAt: index)
                            }
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
        if Platform.isMac {
            MacShelf(title: title) { cards }
        } else {
            ShelfView(title: title) { cards }
        }
    }

    private var cards: some View {
        let width = CGFloat(260).scaled
        return ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
            Button { player.play(videos, startAt: index) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear
                        .frame(width: width, height: width * 9 / 16)
                        .overlay { ArtworkView(artwork: video.artwork, size: width, cornerRadius: 12, fillsFrame: true) }
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
                .frame(width: width, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu { SongMenuItems(song: video) } preview: { SongPreview(song: video) }
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

/// The artist's photo, large and round, with Apple's moving portrait over it once it plays.
struct ArtistPortrait: View {
    let artwork: Artwork?
    let motion: MotionArtwork.Covers?
    var isPlaying = true
    let size: CGFloat
    /// Told whether the moving portrait is what shows.
    var onShow: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ArtworkView(artwork: artwork, size: size, circle: true)
            .overlay {
                MotionLoop(covers: motion, shape: .square, isPlaying: isPlaying, onShow: onShow)
                    .clipShape(.circle)
            }
            // A hairline keeps the circle's edge where the photo and the colours behind it meet.
            .overlay(Circle().strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.4), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.2), radius: 28, y: 14)
            .accessibilityHidden(true)
    }
}

/// "238M monthly audience · 40.2M subscribers", its figures rolling up from zero as the line
/// first appears; with Reduce Motion it simply shows.
private struct AudienceLine: View {
    let text: String
    @State private var shown: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Every digit a zero to start with, so the line keeps its length while it counts.
        Text(shown ?? (reduceMotion ? text : String(text.map { $0.isNumber ? "0" : $0 })))
            .font(.scaled(.subheadline).weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
            .accessibilityLabel(text)
            .task(id: text) {
                guard !reduceMotion else {
                    shown = text
                    return
                }
                if shown != nil { shown = String(text.map { $0.isNumber ? "0" : $0 }) }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.smooth(duration: 0.9)) { shown = text }
            }
    }
}

/// The colours behind the top of an artist's page: the portrait's own 3×3 colours as a mesh,
/// reaching up under the bars and past a pull, and fading into the page under the buttons
/// so the page has no edge anywhere.
private struct ArtistAmbience: View {
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme

    /// How far the colours reach above the page: the bars, and a pull.
    private static let above: CGFloat = 420
    /// And below the buttons, for a fade long enough not to read as a line.
    private static let below: CGFloat = 140

    /// The palette is deepened for white text, which suits dark mode; under light mode's dark
    /// text the same hues go pale, or the wash reads as a dull grey.
    private var colors: [Color] {
        guard colorScheme == .light else { return palette.mesh }
        return palette.mesh.map { color in
            guard let hsb = color.hsb else { return color }
            return Color(hue: hsb.hue, saturation: min(hsb.saturation, 0.45) * 0.6, brightness: 0.97)
        }
    }

    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5, 0.5], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: colors)
        .opacity(colorScheme == .dark ? 0.85 : 1)
        .mask {
            VStack(spacing: 0) {
                Color.black.frame(height: Self.above)
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.38),
                    .init(color: .black.opacity(0.55), location: 0.66),
                    .init(color: .black.opacity(0.18), location: 0.85),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .padding(.top, -Self.above)
        .padding(.bottom, -Self.below)
        .animation(.easeInOut(duration: 0.8), value: palette)
        .allowsHitTesting(false)
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
