import KodaCore
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    /// YouTube Music's catalogue, or the listener's own library, as Music's two search scopes.
    enum Scope: Hashable {
        case catalog, library
    }

    var query = ""
    var submitted: String?
    var filter: SearchFilter = .all
    var scope: Scope = .catalog
    private(set) var suggestions: [String] = []
    private(set) var results: LoadState<SearchResults>?
    /// Last launch's moods first, so the tiles are there at once; refreshed once per model.
    private(set) var moods: [Mood] = SearchModel.launchMoods
    private var moodsFresh = false

    private static let launchMoods = Snapshot.load([Mood].self, "moods") ?? []

    /// Two covers from each mood's own page, for its tile, as Music's category tiles carry art;
    /// asked for as tiles come into view, one page at a time, and kept between launches.
    private(set) var moodCovers: [String: [Artwork]] = SearchModel.launchCovers
    private var coversAsked: Set<String> = []
    private var coverQueue: Task<Void, Never>?
    private static let launchCovers = Snapshot.load([String: [Artwork]].self, "mood-covers") ?? [:]

    func loadCovers(for mood: Mood, music: YouTubeMusic) async {
        guard moodCovers[mood.id] == nil, coversAsked.insert(mood.id).inserted else { return }
        let previous = coverQueue
        let task = Task { [weak self] in
            await previous?.value
            guard let page = try? await music.mood(mood) else { return }
            var covers: [Artwork] = []
            for item in page.shelves.flatMap(\.items) where covers.count < 2 {
                switch item {
                case .playlist(let playlist): if let art = playlist.artwork { covers.append(art) }
                case .album(let album): if let art = album.artwork { covers.append(art) }
                default: break
                }
            }
            guard let self, !covers.isEmpty else { return }
            withAnimation(.smooth) { self.moodCovers[mood.id] = covers }
            Snapshot.save(self.moodCovers, "mood-covers")
        }
        coverQueue = task
        await task.value
    }

    func loadMoods(music: YouTubeMusic) async {
        guard !moodsFresh, let explore = try? await music.explore() else { return }
        let fresh = explore.moods.filter { $0.browseId != "FEmusic_home" }
        moodsFresh = true
        guard !fresh.isEmpty else { return }
        if fresh != moods { moods = fresh }
        Snapshot.save(fresh, "moods")
    }

    func suggest(music: YouTubeMusic) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard scope == .catalog, !text.isEmpty, submitted != text else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let found = try? await music.suggestions(text) else { return }
        guard query.trimmingCharacters(in: .whitespaces) == text else { return }
        suggestions = Array(found.prefix(8))
    }

    func search(_ text: String, music: YouTubeMusic) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        submitted = trimmed
        suggestions = []
        await run(music: music)
    }

    func run(music: YouTubeMusic) async {
        guard let submitted else { return }
        let filter = filter
        results = .loading
        do {
            let found = try await music.search(submitted, filter: filter)
            guard self.submitted == submitted, self.filter == filter else { return }
            results = .loaded(found)
        } catch {
            guard self.submitted == submitted, self.filter == filter else { return }
            results = .failed(error.friendlyMessage)
        }
    }

    func clear() {
        submitted = nil
        results = nil
        filter = .all
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var model = SearchModel()
    @State private var listening = false
    /// Music playing when voice search began, to pick up again after it.
    @State private var resumeAfterVoice = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.scope == .library, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                LibrarySearchResults(query: model.query)
            } else if model.submitted != nil, model.query == model.submitted {
                SearchResultsView(model: model)
            } else if !model.query.isEmpty {
                suggestionsList
            } else {
                landing
            }
        }
        .navigationTitle("Search")
        .searchable(text: $model.query, prompt: model.scope == .library ? "Your Library" : "Songs, artists, albums or a link")
        .searchScopes($model.scope, activation: .onSearchPresentation) {
            Text("YouTube Music").tag(SearchModel.Scope.catalog)
            Text("Your Library").tag(SearchModel.Scope.library)
        }
        .onSubmit(of: .search) { submit(model.query) }
        .onChange(of: model.query) { _, text in
            if text.isEmpty { model.clear() }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search by Voice", systemImage: "mic") {
                    resumeAfterVoice = player.wantsToPlay
                    if resumeAfterVoice { player.pause(from: "voice search") }
                    listening = true
                }
            }
        }
        #endif
        .sheet(isPresented: $listening, onDismiss: {
            if resumeAfterVoice { player.resume() }
            resumeAfterVoice = false
        }) {
            VoiceSearchSheet { text in
                model.query = text
                submit(text)
            }
            .appEnvironment(app)
        }
        .task(id: [model.query, model.scope == .library ? "library" : ""]) { await model.suggest(music: app.music) }
        .task { await model.loadMoods(music: app.music) }
    }

    private func submit(_ text: String) {
        // A pasted YouTube link opens what it points at instead of searching for the URL.
        if let link = YouTubeLink(text: text) {
            model.query = ""
            app.openLink(link)
            return
        }
        // The library's matches are already showing as you type.
        guard model.scope == .catalog else { return }
        if app.settings.savesSearchHistory { library.recordSearch(text) }
        Task { await model.search(text, music: app.music) }
    }

    private var suggestionsList: some View {
        List {
            if let link = YouTubeLink(text: model.query) {
                Button { submit(model.query) } label: {
                    Label(link.openTitle, systemImage: "link")
                        .font(.scaled(.body).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ForEach(model.suggestions, id: \.self) { suggestion in
                Button { submit(suggestion) } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !library.searches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SectionHeader(title: "Recent")
                            Spacer()
                            Button("Clear") { library.clearSearches() }.font(.scaled(.subheadline))
                        }
                        ForEach(library.searches.prefix(8), id: \.self) { query in
                            Button { submit(query) } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                    Text(query).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { library.removeSearch(query) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                if !model.moods.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Moods & genres")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(model.moods) { mood in
                                NavigationLink(value: Route.mood(mood)) { MoodTile(mood: mood, covers: model.moodCovers[mood.id] ?? []) }
                                    .buttonStyle(.plain)
                                    .task { await model.loadCovers(for: mood, music: app.music) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

/// A colour tile for a mood, as Music's category tiles: its name at the top, two covers from
/// its playlists tucked into the corner. The colour comes from its name, so it is the same every
/// time; the covers arrive over it without moving anything.
struct MoodTile: View {
    let title: String
    var covers: [Artwork] = []
    /// A mood's tile keeps room for covers from the start, so its name never rewraps when they come.
    private var holdsCovers = false

    init(mood: Mood, covers: [Artwork] = []) {
        title = mood.title
        self.covers = covers
        holdsCovers = true
    }

    init(title: String) { self.title = title }

    private var hue: Double {
        let hash = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Double(hash % 360) / 360
    }

    var body: some View {
        Text(title)
            .font(.scaled(.headline))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .padding(14)
            .padding(.trailing, holdsCovers ? 40 : 0)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.75),
                                        Color(hue: hue + 0.06, saturation: 0.75, brightness: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay(alignment: .bottomTrailing) {
                if !covers.isEmpty {
                    ZStack {
                        if covers.count > 1 {
                            ArtworkView(artwork: covers[1], size: 52, cornerRadius: 6)
                                .rotationEffect(.degrees(-10))
                                .offset(x: -30, y: 6)
                                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        }
                        ArtworkView(artwork: covers[0], size: 62, cornerRadius: 6)
                            .rotationEffect(.degrees(14))
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                    .offset(x: 12, y: 14)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }
            }
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }
}

struct SearchResultsView: View {
    @Bindable var model: SearchModel
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FilterChips(selection: $model.filter)
                    .onChange(of: model.filter) { Task { await model.run(music: app.music) } }
                if let results = model.results {
                    AsyncContent(state: results, retry: { await model.run(music: app.music) }) { found in
                        if found.isEmpty {
                            ContentUnavailableView.search(text: model.submitted ?? "")
                        } else {
                            content(found)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func content(_ found: SearchResults) -> some View {
        switch model.filter {
        case .all: allResults(found)
        case .songs: songList(found.songs + found.videos)
        case .albums: grid(found.albums.map(MusicItem.album))
        case .artists: artistList(found.artists)
        case .playlists: grid(found.playlists.map(MusicItem.playlist))
        }
    }

    @ViewBuilder
    private func allResults(_ found: SearchResults) -> some View {
        if let top = found.top {
            TopResultCard(item: top, songs: found.topSongs)
                .padding(.horizontal, 20)
        }
        if !found.songs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Songs")
                ForEach(Array(found.songs.prefix(5).enumerated()), id: \.element.id) { _, song in
                    SongRow(song: song) { player.startRadio(from: song) }
                }
            }
            .padding(.horizontal, 20)
        }
        if !found.albums.isEmpty {
            ShelfView(title: "Albums") {
                ForEach(found.albums) { album in
                    ItemCard(item: .album(album), width: 140) { _ in }
                }
            }
        }
        if !found.artists.isEmpty {
            ShelfView(title: "Artists") {
                ForEach(found.artists) { artist in
                    ItemCard(item: .artist(artist), width: 125) { _ in }
                }
            }
        }
        if !found.playlists.isEmpty {
            ShelfView(title: "Playlists") {
                ForEach(found.playlists) { playlist in
                    ItemCard(item: .playlist(playlist), width: 140) { _ in }
                }
            }
        }
        if !found.videos.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Videos")
                ForEach(found.videos.prefix(4)) { song in
                    SongRow(song: song) { player.startRadio(from: song) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func songList(_ songs: [Song]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                SongRow(song: song) { player.startRadio(from: song) }
            }
        }
        .padding(.horizontal, 20)
    }

    private func artistList(_ artists: [ArtistSummary]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(artists) { artist in
                NavigationLink(value: Route.artist(artist)) {
                    HStack(spacing: 14) {
                        ArtworkView(artwork: artist.artwork, size: 56, circle: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.scaled(.body)).foregroundStyle(.primary)
                            if let subtitle = artist.subtitle {
                                Text(subtitle).font(.scaled(.subheadline)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private func grid(_ items: [MusicItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(items) { item in
                ItemCard(item: item, width: 160) { player.startRadio(from: $0) }
            }
        }
        .padding(.horizontal, 20)
    }
}

private struct FilterChips: View {
    @Binding var selection: SearchFilter

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { filter in
                    let selected = filter == selection
                    Button(filter.title) { selection = filter }
                        .font(.scaled(.subheadline).weight(.medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(selected ? .accentColor : .secondary)
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension SearchFilter {
    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }
}

/// The first result, large, with the songs YouTube offers alongside it.
private struct TopResultCard: View {
    let item: MusicItem
    let songs: [Song]
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    /// An artist's Apple Music portrait, moving in their circle when Apple has one.
    @State private var apple: AppleArtist?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Top result")
            if let route = Route(item) {
                NavigationLink(value: route) { header }
                    .buttonStyle(.plain)
            } else if case .song(let song) = item {
                Button { player.startRadio(from: song) } label: { header }
                    .buttonStyle(.plain)
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song) { player.play(songs, startAt: index) }
            }
        }
        .task(id: item.id) {
            // The songs offered beside the artist are theirs: enough to find their Apple artist.
            guard case .artist(let artist) = item, app.settings.animatedArt != .off else { return }
            apple = await app.appleArtist(artist, titles: songs.map(\.title))
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if case .artist(let artist) = item {
                ArtworkView(artwork: item.artwork, size: 84, circle: true)
                    .overlay { MotionLoop(covers: apple?.motion, shape: .square).clipShape(.circle) }
                    .zoomSource(.artist(artist), shape: RoundedRectangle(cornerRadius: 42))
            } else {
                ArtworkView(artwork: item.artwork, size: 84, cornerRadius: 10)
                    .zoomSource(Route(item))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.scaled(.title3).bold()).foregroundStyle(.primary).lineLimit(2)
                Text(kind).font(.scaled(.subheadline)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect)
    }

    private var kind: String {
        switch item {
        case .artist(let a): ["Artist", a.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .album(let a): a.cardSubtitle
        case .playlist(let p): ["Playlist", p.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .song(let s): ["Song", s.artistLine].joined(separator: " · ")
        }
    }
}

extension YouTubeLink {
    /// The row offered when a link is pasted into search.
    var openTitle: String {
        switch self {
        case .song: "Play Song from Link"
        case .album: "Open Album from Link"
        case .playlist: "Open Playlist from Link"
        case .artist: "Open Artist from Link"
        }
    }
}
