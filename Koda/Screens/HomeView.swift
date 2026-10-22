import KodaCore
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    nonisolated struct Content: Codable, Sendable {
        var quickPicks: [Song] = []
        var quickPicksTitle = "Quick picks"
        var shelves: [Shelf] = []
        /// YouTube Music's chart playlists: global, the listener's region, then its genres or languages.
        /// The one row on Home that isn't built from the listener's own listening.
        var charts: [PlaylistSummary] = []
        var trending: [Song] = []

        /// The shape of a loaded Home, for drawing it redacted while the real one loads.
        static let placeholder: Content = {
            var content = Content()
            content.quickPicks = Song.placeholders(8)
            content.charts = (0..<6).map { PlaylistSummary(id: "placeholder-\($0)", title: "Top 100 Chart") }
            return content
        }()
    }

    /// Songs woven from the radios of what the listener plays most.
    nonisolated struct Mix: Equatable, Codable, Sendable {
        var artists: [String]
        var songs: [Song]
        /// Built from listening; otherwise trending songs for someone new.
        var isPersonal: Bool

        static let placeholder = Mix(artists: ["Artist name", "Artist"], songs: Song.placeholders(3), isPersonal: true)
    }

    private(set) var state: LoadState<Content> = .loading
    private(set) var mix: Mix?
    /// Your Mix is still to come: its card keeps its place, redacted, until it does.
    private(set) var mixPending = true
    /// Portraits for the listener's top artists, by channel id; fetched after the page shows.
    private(set) var artistPhotos: [String: Artwork] = [:]
    /// The listener's most-played artists, as of the last load.
    private(set) var yourArtists: [ArtistRef] = []
    /// When Home last loaded, so a window coming back to it after a long while can refresh it.
    private(set) var loadedAt: Date?
    /// What's shown came from the last launch's snapshot and hasn't been refreshed yet.
    private(set) var isFromSnapshot = false

    /// Home as it was last shown, saved to disk so a cold launch opens on it.
    nonisolated private struct Saved: Codable, Sendable {
        var content: Content
        var mix: Mix?
        var artistPhotos: [String: Artwork]
        var loadedAt: Date
    }

    /// Whose Home this is: each profile's is its own, and so is its snapshot.
    let profile: UUID
    private var snapshotName: String { "home-\(profile.uuidString)" }

    init(profile: UUID) {
        self.profile = profile
        guard let saved = Snapshot.load(Saved.self, "home-\(profile.uuidString)") else { return }
        state = .loaded(saved.content)
        mix = saved.mix
        mixPending = saved.mix == nil
        artistPhotos = saved.artistPhotos
        loadedAt = saved.loadedAt
        isFromSnapshot = true
    }

    /// Nothing shown yet, only last launch's Home, or a Home half an hour old: load it again,
    /// in place, over what's on screen.
    var needsRefresh: Bool {
        state.value == nil || isFromSnapshot || loadedAt.map { Date().timeIntervalSince($0) > 1800 } == true
    }

    func load(music: YouTubeMusic, library: Library) async {
        // Worked out here, not in the view's body: the body is drawn again every few seconds
        // while music plays, as listening time is added, and this ranks every song ever played.
        yourArtists = topArtists(library)
        if state.value == nil { state = .loading }
        if mix == nil { mixPending = true }
        let recent = library.recent
        let taste = Taste(library: library)
        // What the listener asked not to be offered stays out of everything Home suggests.
        let hidden = library.notInterested
        // Home is the listener's own: Your Mix, Quick picks, what they go back to and play. From
        // YouTube it takes only the charts, as one row, and trending songs for someone new.
        async let explore = music.explore()
        async let charts = try? music.chartPlaylists()
        async let picks = quickPicks(music: music, recent: recent)
        do {
            var content = Content()
            let explorePage = try await explore
            content.trending = trending(explorePage).filter { !hidden.hides($0) }
            content.charts = await charts ?? []
            let (title, songs) = await picks
            content.quickPicksTitle = title
            let offered = songs.filter { !hidden.hides($0) }
            content.quickPicks = offered.isEmpty ? content.trending : offered
            state = .loaded(content)
            loadedAt = Date()
            if mix == nil, taste.isEmpty, !content.trending.isEmpty {
                mix = Mix(artists: Array(Set(content.trending.map(Taste.leadArtist))).sorted().prefix(3).map { $0 },
                          songs: content.trending, isPersonal: false)
            }
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.buildMix(music: music, taste: taste, recent: recent, hidden: hidden) }
            group.addTask { await self.loadArtistPhotos(music: music, library: library) }
        }
        // Radios that all failed still leave a card: trending songs, as for someone new.
        if mix == nil, let trending = state.value?.trending, !trending.isEmpty {
            mix = Mix(artists: Array(Set(trending.map(Taste.leadArtist))).sorted().prefix(3).map { $0 }, songs: trending, isPersonal: false)
        }
        withAnimation(.smooth) { mixPending = false }
        if let content = state.value, let loadedAt {
            isFromSnapshot = false
            Snapshot.save(Saved(content: content, mix: mix, artistPhotos: artistPhotos, loadedAt: loadedAt), snapshotName)
        }
    }

    /// Your Mix: a radio from each top artist's favourite song, woven together.
    private func buildMix(music: YouTubeMusic, taste: Taste, recent: [Song], hidden: NotInterested) async {
        guard !taste.isEmpty else { return }
        let radios = await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, seed) in taste.seeds.enumerated() {
                group.addTask { (index, (try? await music.radio(for: seed.id).songs) ?? []) }
            }
            var byIndex: [Int: [Song]] = [:]
            for await (index, songs) in group { byIndex[index] = songs }
            return taste.seeds.indices.map { byIndex[$0] ?? [] }
        }
        // The seeds and the last few songs played are left out, so the mix is something to go on to.
        let skip = Set(taste.seeds.map(\.id) + recent.prefix(10).map(\.id))
        let songs = Taste.weave(radios.map { $0.filter { !hidden.hides($0) } }, excluding: skip)
        guard !songs.isEmpty else { return }
        withAnimation(.smooth) { mix = Mix(artists: Array(taste.artists.prefix(3)), songs: songs, isPersonal: true) }
    }

    private func loadArtistPhotos(music: YouTubeMusic, library: Library) async {
        let ids = yourArtists.compactMap(\.id).filter { artistPhotos[$0] == nil }
        guard !ids.isEmpty else { return }
        let found = await withTaskGroup(of: (String, Artwork?).self) { group in
            for id in ids {
                group.addTask { (id, try? await music.artist(id).artist.artwork) }
            }
            var found: [String: Artwork] = [:]
            for await (id, artwork) in group { if let artwork { found[id] = artwork } }
            return found
        }
        artistPhotos.merge(found) { _, new in new }
    }

    /// The listener's most-played artists that can be opened, strongest first.
    func topArtists(_ library: Library, limit: Int = 10) -> [ArtistRef] {
        let taste = Taste(library: library, maxSeeds: 0)
        var refs: [String: ArtistRef] = [:]
        for stats in library.songStats.values {
            if let ref = stats.song.artists.first, ref.id != nil { refs[ref.name] = ref }
        }
        return taste.artists.compactMap { refs[$0] }.prefix(limit).map { $0 }
    }

    /// Songs like the last one played; with no history yet, nothing (trending fills in).
    private func quickPicks(music: YouTubeMusic, recent: [Song]) async -> (String, [Song]) {
        guard let seed = recent.first, let radio = try? await music.radio(for: seed.id) else { return ("Quick picks", []) }
        let songs = Array(radio.songs.filter { $0.id != seed.id }.prefix(20))
        return ("Quick picks", songs)
    }

    private func trending(_ explore: ShelfPage?) -> [Song] {
        explore?.shelves.first { $0.title == "Trending" }?.items.compactMap {
            if case .song(let s) = $0 { return s }
            return nil
        } ?? []
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    private var model: HomeModel { app.home }

    var body: some View {
        ScrollView {
            Group {
                switch model.state {
                case .loading:
                    // Home's own sections from stand-in content, so loading has the page's shape.
                    LazyVStack(alignment: .leading, spacing: 30) {
                        sections(.placeholder)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .loadingPlaceholder()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.glass)
                    }
                    .frame(minHeight: 400)
                case .loaded(let content):
                    // Moods and genres live on Search, as tiles; Home leads with what is yours.
                    LazyVStack(alignment: .leading, spacing: 30) {
                        sections(content)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .transition(.opacity)
                }
            }
            .animation(.smooth, value: model.state.value == nil)
        }
        .navigationTitle(greeting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
        .refreshable {
            await app.music.clearPageCache()
            await load()
        }
        // A snapshot from the last launch shows at once; the fresh Home replaces it in place.
        .task { if model.needsRefresh { await load() } }
    }

    @ViewBuilder
    private func sections(_ content: HomeModel.Content) -> some View {
        if let mix = model.mix {
            MixHero(mix: mix)
                .padding(.horizontal, 20)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        } else if model.mixPending {
            MixHero(mix: .placeholder)
                .loadingPlaceholder()
                .padding(.horizontal, 20)
        }

        JumpBackIn()

        if !content.quickPicks.isEmpty {
            SongColumnsShelf(title: content.quickPicksTitle, strapline: library.recent.isEmpty ? "Trending now" : "Start with these", songs: content.quickPicks) { index in
                player.play(content.quickPicks, startAt: index)
            }
        }
        if !library.recent.isEmpty {
            ShelfView(title: "Recently played", seeAll: .songs(title: "Recently Played", source: .recent)) {
                ForEach(Array(library.recent.prefix(12).enumerated()), id: \.element.id) { index, song in
                    Button { player.play(Array(library.recent.prefix(50)), startAt: index) } label: {
                        CoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine, width: 140)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenuItems(song: song) } preview: { SongPreview(song: song) }
                }
            }
        }
        let yours = model.yourArtists
        if yours.count >= 3 {
            ShelfView(title: "Your top artists", strapline: "Based on your listening") {
                ForEach(yours, id: \.name) { ref in
                    if let id = ref.id {
                        let artist = ArtistSummary(id: id, name: ref.name, artwork: model.artistPhotos[id])
                        NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist, width: 112) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        if !content.charts.isEmpty {
            ShelfView(title: "Charts", strapline: "Global and near you") {
                ForEach(content.charts) { chart in
                    NavigationLink(value: Route.playlist(chart)) {
                        CoverCard(artwork: chart.artwork, title: chart.title, subtitle: chart.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func play(_ song: Song) {
        player.startRadio(from: song)
    }

    private func load() async {
        await model.load(music: app.music, library: library)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Up late"
        }
    }
}

// MARK: - Your Mix

/// The first thing on Home: the listener's mix as a card in its covers' colours, three
/// of its covers along the top and a button that plays it.
struct MixHero: View {
    let mix: HomeModel.Mix
    @Environment(Player.self) private var player
    /// One palette per cover; the background weaves all three together.
    @State private var palettes = [PaletteModel(), PaletteModel(), PaletteModel()]
    @State private var taps = 0
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var coverSize: CGFloat = 100

    private static let cornerRadius: CGFloat = 26
    private static let padding: CGFloat = 20
    private static let playSize: CGFloat = 52

    private var covers: [Artwork] {
        var seen = Set<URL>()
        return mix.songs.compactMap(\.artwork).filter { seen.insert($0.url(pixels: 120)).inserted }.prefix(3).map { $0 }
    }

    private var title: String { mix.isPersonal ? "Your Mix" : "Start Here" }

    /// A 3×3 mesh from the three covers: the first cover's colours to the top left, the
    /// second's along the top right and right edge, the third's along the bottom and in
    /// the middle, so the card reads as all of them rather than one. Fewer covers repeat.
    private var meshColors: [Color] {
        let count = max(min(covers.count, 3), 1)
        let a = palettes[0].palette.mesh, b = palettes[1 % count].palette.mesh, c = palettes[2 % count].palette.mesh
        return [
            a[0], a[1], b[2],
            a[3], c[4], b[5],
            c[6], c[7], b[8],
        ]
    }
    private var caption: String {
        guard mix.isPersonal else { return "Trending songs to get Koda to know you" }
        switch mix.artists.count {
        case 0: return "Made from what you play"
        case 1: return "\(mix.artists[0]) and more"
        default: return "\(mix.artists.prefix(2).joined(separator: ", ")) and more"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        NavigationLink(value: Route.songList(title: title, subtitle: caption, songs: mix.songs)) {
            VStack(alignment: .leading, spacing: 0) {
                coverRow
                    .padding(.bottom, 24)
                Text(mix.isPersonal ? "Made for you" : "New here")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 16) {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Room for the play button, which sits over the card rather than inside the link.
                    Color.clear.frame(width: Self.playSize, height: Self.playSize)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { MixBackground(colors: meshColors, isAnimating: !reduceMotion) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(PressReporting(isPressed: $isPressed))
        .overlay(alignment: .bottomTrailing) {
            Button {
                taps += 1
                player.play(mix.songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: Self.playSize, height: Self.playSize)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(Self.padding)
            .accessibilityLabel("Play \(title)")
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        }
        // The card and its play button press down together, as one object.
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        .environment(\.colorScheme, .dark)
        .task(id: covers) {
            // The covers are already loaded for the row, so these come from the cache.
            for (index, cover) in covers.enumerated() where index < palettes.count {
                await palettes[index].load(cover)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Up to three covers overlapping left to right, the first on top; empty slots while
    /// there are none, so the card keeps its height.
    @ViewBuilder
    private var coverRow: some View {
        let covers = covers
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: -coverSize * 0.3) {
            if covers.isEmpty {
                // One flat shape, each slot cut out of the one behind it, so the overlaps
                // don't stack translucent grey and shadows into darker patches.
                ForEach(0..<3, id: \.self) { index in
                    shape.fill(.white)
                        .frame(width: coverSize, height: coverSize)
                        .background { shape.padding(-3).blendMode(.destinationOut) }
                        .zIndex(Double(-index))
                }
            } else {
                ForEach(covers.indices, id: \.self) { index in
                    // Opaque under the image, so a cover still loading hides the one behind it.
                    ArtworkView(artwork: covers[index], size: coverSize, cornerRadius: 12)
                        .background(Color(white: 0.22), in: shape)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                        .zIndex(Double(-index))
                }
            }
        }
        .compositingGroup()
        .opacity(covers.isEmpty ? 0.16 : 1)
        .accessibilityHidden(true)
    }
}

/// The mix card's colours, their inner points drifting slowly so the colours move.
private struct MixBackground: View {
    let colors: [Color]
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t * 0.3)) * 0.1, b = Float(cos(t * 0.23)) * 0.1
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + a * 0.6, 0], [1, 0],
                [0, 0.5 + b * 0.6], [0.55 + a, 0.45 + b], [1, 0.5 - a * 0.6],
                [0, 1], [0.5 - b * 0.6, 1], [1, 1],
            ], colors: colors)
        }
        .animation(.easeInOut(duration: 0.8), value: colors)
    }
}

/// Reports the press instead of drawing it, so a view around the button (the mix card
/// with its play button) can press down as a whole.
private struct PressReporting: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in isPressed = pressed }
    }
}

// MARK: - Jump back in

/// Up to eight things the listener keeps going back to, as a row of covers.
struct JumpBackIn: View {
    @Environment(Library.self) private var library

    private static let limit = 8
    private static let width: CGFloat = 156

    enum Item: Identifiable {
        case liked(count: Int, songs: [Song])
        case userPlaylist(UserPlaylist)
        case album(AlbumSummary)
        case playlist(PlaylistSummary)

        var id: String {
            switch self {
            case .liked: "liked"
            case .userPlaylist(let p): "user-\(p.id)"
            case .album(let a): "album-\(a.id)"
            case .playlist(let p): "playlist-\(p.id)"
            }
        }
    }

    private var items: [Item] { Self.items(in: library) }

    /// What the listener keeps going back to, for the phone's row and the Mac's shelf alike.
    static func items(in library: Library) -> [Item] {
        let limit = Self.limit
        var items: [Item] = []
        if !library.liked.isEmpty { items.append(.liked(count: library.liked.count, songs: library.liked)) }
        let playlists = library.userPlaylists.filter { !$0.songs.isEmpty }.sorted { $0.modified > $1.modified }
        items += playlists.prefix(2).map(Item.userPlaylist)
        // Albums of songs played lately, newest first, one each.
        var seenAlbums = Set<String>()
        for song in library.recent {
            guard let album = song.album, seenAlbums.insert(album.id).inserted else { continue }
            items.append(.album(AlbumSummary(id: album.id, title: album.title, artistLine: song.artistLine, artists: song.artists, artwork: song.artwork)))
            if items.count >= limit { break }
        }
        for album in library.albums where items.count < limit && seenAlbums.insert(album.id).inserted {
            items.append(.album(album))
        }
        items += library.playlists.prefix(max(0, limit - items.count)).map(Item.playlist)
        return Array(items.prefix(limit))
    }

    var body: some View {
        let items = items
        if items.count >= 2 {
            ShelfView(title: "Jump back in") {
                ForEach(items) { item in
                    NavigationLink(value: Self.route(item)) { card(item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    static func route(_ item: Item) -> Route {
        switch item {
        case .liked: .songs(title: "Liked Songs", source: .liked)
        case .userPlaylist(let p): .userPlaylist(p.id)
        case .album(let a): .album(a)
        case .playlist(let p): .playlist(p)
        }
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .liked: "Liked Songs"
        case .userPlaylist(let p): p.name
        case .album(let a): a.title
        case .playlist(let p): p.title
        }
    }

    static func subtitle(_ item: Item) -> String? {
        switch item {
        case .liked(let count, _): songCount(count)
        case .userPlaylist(let p): songCount(p.songs.count)
        case .album(let a): a.artistLine.isEmpty ? nil : a.artistLine
        case .playlist(let p): p.subtitle
        }
    }

    /// The item's cover alone, at `size`: liked songs and the listener's playlists as mosaics.
    @ViewBuilder
    static func cover(_ item: Item, size: CGFloat) -> some View {
        switch item {
        case .liked(_, let songs):
            PlaylistMosaic(songs: songs, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.45), in: .circle)
                        .padding(8)
                }
        case .userPlaylist(let p):
            PlaylistMosaic(songs: p.songs, size: size)
        case .album(let a):
            ArtworkView(artwork: a.artwork, size: size, cornerRadius: 10)
        case .playlist(let p):
            ArtworkView(artwork: p.artwork, size: size, cornerRadius: 10)
        }
    }

    @ViewBuilder
    private func card(_ item: Item) -> some View {
        let width = Self.width
        switch item {
        case .liked(let count, let songs):
            // The listener's own liked covers, marked with a heart, rather than a stock colour.
            CoverCard(title: "Liked Songs", subtitle: Self.songCount(count), width: width) {
                PlaylistMosaic(songs: songs, size: width)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.45), in: .circle)
                            .padding(8)
                    }
            }
        case .userPlaylist(let p):
            CoverCard(title: p.name, subtitle: Self.songCount(p.songs.count), width: width) {
                PlaylistMosaic(songs: p.songs, size: width)
            }
        case .album(let a):
            CoverCard(artwork: a.artwork, title: a.title, subtitle: a.artistLine.isEmpty ? nil : a.artistLine, width: width)
        case .playlist(let p):
            CoverCard(artwork: p.artwork, title: p.title, subtitle: p.subtitle, width: width)
        }
    }

    private static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }
}
