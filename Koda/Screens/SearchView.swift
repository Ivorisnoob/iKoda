import KodaCore
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    var query = ""
    var submitted: String?
    var filter: SearchFilter = .all
    private(set) var suggestions: [String] = []
    private(set) var results: LoadState<SearchResults>?
    /// Last launch's moods first, so the tiles are there at once; refreshed once per model.
    private(set) var moods: [Mood] = SearchModel.launchMoods
    private var moodsFresh = false

    private static let launchMoods = Snapshot.load([Mood].self, "moods") ?? []

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
        guard !text.isEmpty, submitted != text else {
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
            if model.submitted != nil, model.query == model.submitted {
                SearchResultsView(model: model)
            } else if !model.query.isEmpty {
                suggestionsList
            } else {
                landing
            }
        }
        .navigationTitle("Search")
        .searchable(text: $model.query, prompt: "Songs, artists, albums or a link")
        .onSubmit(of: .search) { submit(model.query) }
        .onChange(of: model.query) { _, text in
            if text.isEmpty { model.clear() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search by Voice", systemImage: "mic") {
                    resumeAfterVoice = player.wantsToPlay
                    if resumeAfterVoice { player.pause() }
                    listening = true
                }
            }
        }
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
        .task(id: model.query) { await model.suggest(music: app.music) }
        .task { await model.loadMoods(music: app.music) }
    }

    private func submit(_ text: String) {
        // A pasted YouTube link opens what it points at instead of searching for the URL.
        if let link = YouTubeLink(text: text) {
            model.query = ""
            app.openLink(link)
            return
        }
        if app.settings.savesSearchHistory { library.recordSearch(text) }
        Task { await model.search(text, music: app.music) }
    }

    private var suggestionsList: some View {
        List {
            if let link = YouTubeLink(text: model.query) {
                Button { submit(model.query) } label: {
                    Label(link.openTitle, systemImage: "link")
                        .font(.body.weight(.semibold))
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
                            Button("Clear") { library.clearSearches() }.font(.subheadline)
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
                                NavigationLink(value: Route.mood(mood)) { MoodTile(mood: mood) }
                                    .buttonStyle(.plain)
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

/// A colour tile for a mood; the colour comes from its name, so it is the same every time.
struct MoodTile: View {
    let mood: Mood

    private var hue: Double {
        let hash = mood.title.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Double(hash % 360) / 360
    }

    var body: some View {
        Text(mood.title)
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .bottomLeading)
            .background {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.75),
                                        Color(hue: hue + 0.06, saturation: 0.75, brightness: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
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
                    NavigationLink(value: Route.album(album)) {
                        CoverCard(artwork: album.artwork, title: album.title, subtitle: album.cardSubtitle, width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !found.artists.isEmpty {
            ShelfView(title: "Artists") {
                ForEach(found.artists) { artist in
                    NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist, width: 100) }
                        .buttonStyle(.plain)
                }
            }
        }
        if !found.playlists.isEmpty {
            ShelfView(title: "Playlists") {
                ForEach(found.playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist)) {
                        CoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.subtitle, width: 140)
                    }
                    .buttonStyle(.plain)
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
                            Text(artist.name).font(.body).foregroundStyle(.primary)
                            if let subtitle = artist.subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
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
                        .font(.subheadline.weight(.medium))
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
    @Environment(Player.self) private var player

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
    }

    private var header: some View {
        HStack(spacing: 16) {
            if case .artist = item {
                ArtworkView(artwork: item.artwork, size: 84, circle: true)
            } else {
                ArtworkView(artwork: item.artwork, size: 84, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3.bold()).foregroundStyle(.primary).lineLimit(2)
                Text(kind).font(.subheadline).foregroundStyle(.secondary)
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
