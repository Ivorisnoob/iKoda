import KodaCore
import SwiftUI

// MARK: - Browse

/// Browse on the Mac: recent searches to pick up again, then every mood and genre as tiles.
/// Search itself lives in the sidebar's field, where it is on every page.
struct MacBrowseView: View {
    let search: SearchModel
    let submit: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        MacPage {
            MacPageTitle(title: "Browse")
            if !library.searches.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        MacSectionTitle(title: "Recent searches")
                        Spacer()
                        Button("Clear") { library.clearSearches() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(library.searches.prefix(12), id: \.self) { query in
                            Button { submit(query) } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { library.removeSearch(query) }
                            }
                        }
                    }
                }
                .padding(.horizontal, MacMetrics.gutter)
            }
            if search.moods.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    MacSectionTitle(title: "Moods & genres")
                        .padding(.horizontal, MacMetrics.gutter)
                    MacGrid(items: search.moods, minimum: 200) { mood, _ in
                        NavigationLink(value: Route.mood(mood)) {
                            MacMoodTile(mood: mood)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Browse")
        .task { await search.loadMoods(music: app.music) }
    }
}

/// A mood's colour tile, lifting a little under the pointer.
private struct MacMoodTile: View {
    let mood: Mood
    @State private var hovering = false

    var body: some View {
        MoodTile(mood: mood)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 10 : 4, y: hovering ? 6 : 2)
            .scaleEffect(hovering ? 1.02 : 1)
            .onHover { over in withAnimation(.spring(response: 0.3, dampingFraction: 1)) { hovering = over } }
    }
}

/// Lays its children left to right and wraps them, like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Search results

/// Search results on the Mac: the filter as a segmented control, and for All the top result
/// beside its songs, then albums, artists and playlists as shelves.
struct MacSearchResultsView: View {
    @Bindable var model: SearchModel
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var width: CGFloat = 1000

    var body: some View {
        MacPage(spacing: 32) {
            MacPageTitle(title: model.submitted ?? "Search", subtitle: "Results for") {
                Picker("Show", selection: $model.filter) {
                    ForEach(SearchFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let results = model.results {
                AsyncContent(state: results, retry: { await model.run(music: app.music) }) { found in
                    if found.isEmpty {
                        ContentUnavailableView.search(text: model.submitted ?? "")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        content(found)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: model.filter) { Task { await model.run(music: app.music) } }
    }

    @ViewBuilder
    private func content(_ found: SearchResults) -> some View {
        switch model.filter {
        case .all: all(found)
        case .songs: MacTrackList(songs: found.songs + found.videos) { player.startRadio(from: (found.songs + found.videos)[$0]) }
        case .albums: MacGrid(items: found.albums) { album, side in MacItemCard(item: .album(album), width: side) }
        case .playlists: MacGrid(items: found.playlists) { playlist, side in MacItemCard(item: .playlist(playlist), width: side) }
        case .artists: MacGrid(items: found.artists, minimum: MacMetrics.artistCard) { artist, side in MacArtistCard(artist: artist, width: side) }
        }
    }

    @ViewBuilder
    private func all(_ found: SearchResults) -> some View {
        let songs = Array(found.songs.prefix(found.top == nil ? 8 : 4))
        // Side by side when there's room for both; the top result above the songs when not.
        let wide = width > 820
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            if let top = found.top {
                VStack(alignment: .leading, spacing: 12) {
                    MacSectionTitle(title: "Top result")
                    MacTopResult(item: top, songs: found.topSongs)
                }
                .frame(width: wide ? 380 : nil)
                .frame(maxWidth: wide ? nil : 520, alignment: .leading)
            }
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    MacSectionTitle(title: "Songs")
                        .padding(.leading, 6)
                    VStack(spacing: 2) {
                        ForEach(songs) { song in
                            MacSongTile(song: song) { player.startRadio(from: song) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MacMetrics.gutter)

        if !found.albums.isEmpty {
            MacShelf(title: "Albums") { ForEach(found.albums) { MacItemCard(item: .album($0)) } }
        }
        if !found.artists.isEmpty {
            MacShelf(title: "Artists") { ForEach(found.artists) { MacArtistCard(artist: $0) } }
        }
        if !found.playlists.isEmpty {
            MacShelf(title: "Playlists") { ForEach(found.playlists) { MacItemCard(item: .playlist($0)) } }
        }
        if !found.videos.isEmpty {
            MacShelf(title: "Videos") { ForEach(found.videos) { MacItemCard(item: .song($0)) } }
        }
    }
}

/// The first result as a large card, its songs under it when YouTube offers some.
private struct MacTopResult: View {
    let item: MusicItem
    let songs: [Song]
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let route = Route(item) {
                    NavigationLink(value: route) { card }
                } else if case .song(let song) = item {
                    Button { player.startRadio(from: song) } label: { card }
                }
            }
            .buttonStyle(.plain)
            if !songs.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                        MacSongTile(song: song) { player.play(songs, startAt: index) }
                    }
                }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .artist = item {
                ArtworkView(artwork: item.artwork, size: 112, circle: true)
            } else {
                ArtworkView(artwork: item.artwork, size: 112, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title.bold()).lineLimit(2)
                Text(kind).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(hovering ? 0.09 : 0.05), in: .rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
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

// MARK: - Library grids

/// Saved albums, playlists or artists as a grid that fills the window, sortable from the toolbar.
struct MacLibraryGrid: View {
    enum Kind { case albums, playlists, artists }
    let kind: Kind
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @AppStorage("koda.library.sort") private var sort: LibrarySort = .recent

    private var title: String {
        switch kind {
        case .albums: "Albums"
        case .playlists: "Playlists"
        case .artists: "Artists"
        }
    }

    var body: some View {
        MacPage(spacing: 24) {
            MacPageTitle(title: title, subtitle: "Library") {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            switch kind {
            case .albums:
                if library.albums.isEmpty {
                    empty("No Albums", "square.stack", "Add albums with the + button on their pages.")
                } else {
                    MacGrid(items: sortedAlbums) { album, side in MacItemCard(item: .album(album), width: side) }
                }
            case .playlists:
                if library.playlists.isEmpty && library.userPlaylists.isEmpty {
                    empty("No Playlists", "music.note.list", "Make one with New Playlist in the sidebar, or add playlists with the + button on their pages.")
                } else {
                    if !library.userPlaylists.isEmpty {
                        MacSectionTitle(title: "Your Playlists")
                            .padding(.horizontal, MacMetrics.gutter)
                        MacGrid(items: sortedUserPlaylists) { playlist, side in
                            NavigationLink(value: Route.userPlaylist(playlist.id)) {
                                MacCoverCard(title: playlist.name,
                                             subtitle: playlist.songs.count == 1 ? "1 song" : "\(playlist.songs.count) songs",
                                             width: side,
                                             onPlay: playlist.songs.isEmpty ? nil : { player.play(playlist.songs) }) {
                                    PlaylistMosaic(songs: playlist.songs, size: side, cornerRadius: 10)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !library.playlists.isEmpty {
                        MacSectionTitle(title: "Saved Playlists")
                            .padding(.horizontal, MacMetrics.gutter)
                            .padding(.top, library.userPlaylists.isEmpty ? 0 : 12)
                        MacGrid(items: sortedPlaylists) { playlist, side in MacItemCard(item: .playlist(playlist), width: side) }
                    }
                }
            case .artists:
                if library.artists.isEmpty {
                    empty("No Artists", "music.mic", "Add artists with the + button on their pages.")
                } else {
                    MacGrid(items: sortedArtists, minimum: MacMetrics.artistCard) { artist, side in MacArtistCard(artist: artist, width: side) }
                }
            }
        }
        .navigationTitle(title)
    }

    private func empty(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
            .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var sortedAlbums: [AlbumSummary] {
        switch sort {
        case .recent: library.albums
        case .title: library.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: library.albums.sorted {
            let order = $0.artistLine.localizedStandardCompare($1.artistLine)
            return order == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : order == .orderedAscending
        }
        }
    }

    private var sortedPlaylists: [PlaylistSummary] {
        switch sort {
        case .recent: library.playlists
        case .title, .artist: library.playlists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var sortedUserPlaylists: [UserPlaylist] {
        switch sort {
        case .recent: library.userPlaylists.sorted { $0.modified > $1.modified }
        case .title, .artist: library.userPlaylists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var sortedArtists: [ArtistSummary] {
        sort == .recent ? library.artists : library.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
